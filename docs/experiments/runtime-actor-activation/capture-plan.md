# Off-owner collection capture: implementation plan (read-only design)

Status: **plan only.** No Source, test or script was edited, and nothing was built or run. The R4 Source (`c8547b7`, PR 261) stays frozen until the parent reviews this plan and releases it.

Inputs: the R4 optimized results (`runtime-actor-stageb-r4-optimized/`), `runtime-actor-stageb-r4-resource-review.md`, `runtime-collection-off-owner-review-clarification.md`, and the current Source as read in this session.

## 1. Goal and the bounds that stay fixed

Today a page that needs a capture projects every row inside one RuntimeActor turn (`RuntimeServiceCore.pageSource` → `captureCurrent` → `owner.projectedRows`, `RuntimeServiceCore.swift:546-590`). With 10,000 rows that turn lasts 0.48–0.63 s, and status reads and Stop wait for all of it. That breaks 0031's "short owner turns" and 0038's "Stop/status independent under pressure".

The fix:
- **On the owner, in the page's own turn:** take the exact projection input, start (or join) one shared projection flight, and park the page on the existing wait gate.
- **Off the owner:** do the pure, expensive projection.
- **On the owner again:** commit the result to the ledger in one short turn, then wake the parked pages.

Fixed, with no new values:
- the 0038 profile (10,000 rows, 4 MiB per capture, 8 MiB retained, 2 row sets and 4 proofs per kind, 60 s age);
- read-lane capacity, request deadlines and wire budgets;
- the wire protocol and reply shapes;
- no latency SLO, throttle or new capacity.

## 2. The shape

### 2.1 Owner protocol: a same-turn row source (internal; replaces one method)
`ControlCommandOwner.projectedRows(for:within:) -> ControlProjection` (`ControlCommandOwner.swift:77`) becomes:

```swift
/// The projection input of one collection, frozen in this owner turn: the same turn whose `snapshot()` named the revision and total.
/// The returned job is pure and touches no owner state, so it may run off the owner. Called only after the service has checked the
/// snapshot's exact total against the row bound.
func rowSource(for kind: ControlCollectionKind) -> RuntimeRowSource

/// A frozen, pure projection job. It is async so that a test owner can suspend inside it without holding a thread.
typealias RuntimeRowSource = @Sendable (ControlRowBudget) async -> ControlProjection
```

- **`RuntimeHost`** (`RuntimeHostControlOwner.swift:188`): it captures only that kind's kernel source value. For `.activeConnections` that is `orchestrator.snapshot.activeConnections`, an O(1) copy-on-write retain. It returns `{ budget in RuntimeSnapshotControlProjection.projectRows(kind, from: frozenValue, within: budget) }`.
  - The projection takes the whole `ProxyOrchestratorSnapshot` today. Either keep passing the snapshot (also an O(1) retain, but it pins a little more state) or add one internal overload per kind. Implementation picks the overload if it adds no array copy.
- **`FakeCommandOwner`** (`RuntimeServiceFixtures.swift:345`): `projectionOverride` becomes async, so a test can hold a flight by awaiting its own continuation. That is a fixture change, not a production hook.
- **Not changed:** public or package access, and the `RuntimeSnapshotControlProjection` row and sort code. The sort (`:101-106`) moves off the owner with the projection.

### 2.2 Service: one shared flight across all kinds (no registry, no queue)
`RuntimeServiceCore` gains one optional record, `private var captureFlight: RuntimeCaptureFlight?`, in a small new internal file `RuntimeCaptureFlight.swift`. It holds:
- `kind`, `revision` (R), `total`, and `startedAt` (`timing.now()` in the start turn);
- `waiters`: `(token: RuntimeWaiterToken, wake: @Sendable () -> Void, resolution: RuntimeCaptureWaitBox)` entries. Each read-lane reservation contributes at most one entry, so there are at most `readLaneCapacity` (a `precondition`). No new capacity.

There is no second flight, no queue of pending kinds and no per-kind table.

`pageSource` keeps every existing branch. Only `.needsCapture` changes:
1. **Unchanged early refusals, before anything is frozen:**
   - incarnation;
   - the held-proof total check;
   - `offset <= reference.totalCount`;
   - `total <= collectionRowCapacity`, else `retentionBudgetExceeded` with the exact total. For `.tunnelDNSHosts` the count comes from the snapshot reference, as today.

   An oversized collection is never frozen, sorted or projected.
2. **No flight running:** call `owner.rowSource(for: kind)` in this turn and record `{kind, R, total, startedAt}`. Start the job with `Task.detached(priority: .utility)`. It is detached so that it does **not** inherit RuntimeActor isolation; it runs on the cooperative pool and never on PlatformWork. The job ends with `scheduling.hop { [weak core] in core?.finishCapture(flightID, projection) }`. Return `.awaitingCapture(waitBox)`.
3. **A flight for the same kind is running:** join it and return `.awaitingCapture(waitBox)`. The page will be answered with that flight's R.
4. **A flight for another kind is running:** park on it with a `retry` resolution. When it ends, the page's round runs again and starts its own flight.

The new `RuntimePageSource` case is `.awaitingCapture(RuntimeCaptureWaitBox)`. It is internal; the transport parks on it.

`finishCapture(flightID, projection)` runs in one owner turn and completes all state before any wake:
- **Service shut down** (`ingress` closed by `hostDidShutDown`): nothing is committed and each waiter resolves `retry`. After shutdown a page that would need a capture is refused (§4.4).
- **`.rows`:** call `collections.capture(kind, revision: R, total: total, rows:, encodedBytes:, capturedAt: startedAt, at: now)`. Each result maps to a waiter resolution:
  - `stored`: `bound(R)`;
  - `overBudget`: answer `.unavailable(.retentionBudgetExceeded, knownTotal: total)`;
  - `countOrKindMismatch`: deliver `.projectionCountMismatch` once, and answer `.internalFailure`;
  - `invariantFailure`: deliver `.collectionAccountingMismatch` once, and answer `.internalFailure`.
- **`.overBudget`:** answer `.unavailable(.retentionBudgetExceeded, knownTotal: total)`.
- **`.internalFailure`:** deliver `.projectionNotEncodable` once, and answer `.internalFailure`.
- **Waiters of another kind** resolve `retry`.
- **Then** clear `captureFlight`, which releases the frozen value and the rows, take the waiters out, and call every `wake()`. This is the pattern of `wakeWaiters` (`:916-921`).

A woken page round reads its box first:
- `answer(x)`: that closed answer, exactly once.
- `bound(R)`: run the existing ledger `decision` with the cursor set to R:
  - R still current: `.current` (today's result);
  - R superseded: `.stale(revision: R, rows:)`, i.e. `staleRevision(current: R′)`, the existing reply;
  - R evicted or expired since the commit: the existing `.expired` or `.notCaptured`, which are honest.

  Offsets are checked as each branch checks them today.
- `retry`: run `pageSource` again from the top.

### 2.3 Transport: reuse the stream pull's park and wake (`RuntimeInMemoryTransport.swift:572-605`)
- The page attempt becomes `RuntimeWaitOutcome?`. On `.awaitingCapture` it installs one registration and returns nil, which parks the gate. `answer(_:)` passes the gate through for `.readPage` only.
- `installRegistration` is generalized to take `park(token, wake) -> RuntimeParkResult` and `release(token)` closures. Stream pulls pass the subscriber table's; pages pass the flight's.
  - The `ticket.begin(.waiterCleanup)` and `gate.park { … scheduling.hop { release; ticket.end(.waiterCleanup) } }` logic is shared, so there is no second copy of the cleanup path.
  - The flight's `park` answers `.subscriberGone` when the flight has already ended; the round then re-runs as `retry`.
- Deadline and cancellation are the gate's own. A parked page expires as `notSent`: `deadlineExpired`, or the typed budget refusal. The cleanup hop removes its entry from the flight. The flight continues.

## 3. Custody

### Encoded bytes: the same peak as today
- Today: up to 8 MiB retained, plus up to one 4 MiB capture being projected before the ledger evicts anything (`RuntimeServiceCore.swift:567-569`, `RuntimeCollectionLedger.swift:193-210`).
- `RuntimeServiceLimits` already charges that one-capture staging term inside `retainedByteCeiling` (`collectionTotal = retained + proofs + collectionByteCapacity`, `RuntimeServiceLimits.swift:272-278`).
- One shared flight keeps at most one projection in progress, so the encoded peak is unchanged. Only its *duration* grows, to the flight's lifetime.
- The projection still stops at the first row past 4 MiB.
- There is no reservation and no eager eviction. Per-kind flights would add up to 4 MiB per kind, so they are excluded.

### Objects: separate, documented and measured, not claimed in the encoded budget
- The flight holds the frozen collection storage. After the kernel's next mutation that is one older `[ActiveConnectionInfo]` buffer that today would already have been released.
- It also holds the Swift row values built during projection.
- Both are released at commit, failure, shutdown skip, or when the service is gone (the job holds the core weakly).
- 0038 states that the byte accounts are not a RAM bound. Measuring RSS with one held flight belongs to the parent's resource lane (the existing opt-in probes).

### Array copies
- The freeze is an O(1) retain.
- The projection's existing sort copy and row array are unchanged and now happen off the owner.
- No extra whole-array copy is added. Implementation must not map or filter the source before `budget.measure`, which accepts any `Sequence`.

### Ledger order
- Commits are serialized by the single flight, and `capturedAt = startedAt` increases in start order.
- So the ledger's "oldest capture first" ordering and cross-kind eviction (`:79, 188-201, 273-283`) still hold.

## 4. Revision and page semantics

### 4.1 Same-turn freeze (required)
- R, `total` and the frozen source are taken in the one `pageSource` turn whose `owner.snapshot()` named them, with no suspension in between.
- So the rows are exactly R's, as today.
- Revisions never repeat (`RuntimeHostControlOwner.swift:80-90`), so a proof of R committed after R′ appeared cannot conflict with a later reference.

### 4.2 Audit of the stale-capture claim
- **What the resource review got right:** committed rows of a superseded R are correct and storable. The ledger stores any revision, and its doc ("a kind's current revision") becomes "the revision named in the start turn".
- **What does not fit as written:** a parked cursor-less first page that simply re-decides after the commit gets `.needsCapture` again (`RuntimeCollectionLedger.swift:146-150`).
- **Why that matters:**
  - `activeConnections` takes a new revision whenever the store differs, including per-connection byte counters (`ProxyStatus.swift:262-264`).
  - Under traffic, a 10,000-row flight therefore almost always finishes behind the current revision.
  - Re-deciding would loop until the page's deadline. The observer would then report "could not be read", a new user-visible failure.
- **The fix is the `bound(R)` resolution in §2.2.** Each waiter is answered from the flight it joined, through the existing decision table with cursor R.

### 4.3 Contract clarification to record (parent docs; no new wire response, no owner decision per the clarification review)
- The ledger rule "a nil cursor reads the current revision" gains one case: a page whose own capture committed a revision that has since been superseded is answered with that revision's rows, as `staleRevision(current: R′)`.
- The client already handles a stale first page as "not current, read again" (`RuntimeObserver.swift:294-298, 438`).
- **Unchanged limit, now wider:** a complete list still won't display under churn faster than one pass. The window grows from paging time to capture plus paging time. Changing that would be a product decision and is not part of this plan.

### 4.4 Shutdown
- `hostDidShutDown` leaves a running flight to finish. Its completion commits nothing and wakes its waiters with `retry`.
- After shutdown, a page that hits retained rows is served as today. A page that would need a new capture is refused with the existing `.unavailable(.notCaptured, knownTotal: nil)` and starts no flight.
- Today such a page would capture inline. Answering `notCaptured` instead is the one behaviour change after Quit (point B in §8).

### 4.5 Capture age
- `capturedAt` is the flight's start instant, so proof age still measures from the capture and is not extended by the flight's duration.
- `RuntimeCollectionLedger.capture` gains an explicit `capturedAt:`, separate from the `at:` instant that drives `releaseExpired`.

## 5. Executor, scheduling and clock
- **Executor:**
  - `Task.detached(priority: .utility)`, on the cooperative pool.
  - Not PlatformWork, where helper calls of up to 40 s could queue ahead of it.
  - Not a task that inherits the actor, which would put it back on the owner.
  - `.utility` is not a policy and makes no QoS claim.
- **Commit:** through the existing `scheduling.hop`, so a test's scheduler sees it.
- **Clock:**
  - `startedAt`, the commit's `now`, and every waiter deadline use the injected `RuntimeServiceTiming`.
  - The flight itself has no timer. It is bounded CPU work: a 10,000-row bound, checked before the freeze, and a 4 MiB byte bound, checked during the projection.
- **Strict one-thread pool:**
  - The production 10,000-row projection still serializes with the owner, so that measurement stays inconclusive by design.
  - The causal tests below use a suspending fake job, which holds no thread, so they are deterministic under strict too.

## 6. Files (implementation scope once released)

| File | Change |
|---|---|
| `Sources/ConduitRuntime/ControlCommandOwner.swift` | `rowSource(for:)` and `RuntimeRowSource` replace `projectedRows` |
| `Sources/ConduitRuntime/RuntimeHostControlOwner.swift` | same-turn freeze; the doc of `RuntimeHostCollections` (`:93-94`) |
| `Sources/ConduitRuntime/RuntimeCaptureFlight.swift` (new, internal) | the flight record, its bounded waiters, and `RuntimeCaptureWaitBox` |
| `Sources/ConduitRuntime/RuntimeServiceCore.swift` | `.needsCapture` → start or join; `finishCapture`; the shutdown skip; post-shutdown refusal; the new `.awaitingCapture` source case |
| `Sources/ConduitRuntime/RuntimeCollectionLedger.swift` | explicit `capturedAt:`; doc of the revision rule (§4.3) |
| `Sources/ConduitRuntime/RuntimeInMemoryTransport.swift` | optional page attempt; generalized `installRegistration` |
| `Tests/ConduitTests/RuntimeServiceFixtures.swift` | async `projectionOverride` |
| `Tests/ConduitTests/RuntimeActorFairnessTests.swift` | flipped capture test, and the new causal tests (in the correction, focused and strict filters) |

Not touched: wire types, ConduitShared, the app observer, pm-proxy, the profile, decision records and docs (the parent's).

## 7. Causal tests (no timing number asserted; suspending fake jobs; no FIFO assumption)
All in `RuntimeActorFairnessTests`, at service level, with `FakeCommandOwner` and an async held job unless noted.

1. **Flipped measurement:** the existing 10,000-row production-projection test. When status and Stop are issued inside the projection, assert `statusAt < exited` and `stopAt < exited` on a normal pool. When they could not be issued inside it (one-thread pool), report inconclusive, as today.
2. **Held flight, control answered:**
   - Hold the job.
   - A status read answers and a Stop is admitted, both while the job is provably held.
   - Release it: the page is answered `.current` and whole.
   - Under strict too.
3. **Churn:**
   - Hold the job for R, then advance the fake owner's snapshot to R′.
   - Release: the parked first page is answered with R's rows, `staleRevision(current: R′)`, and does not time out.
   - The next first page starts a new flight.
4. **Join:** two same-kind first pages during one flight. The fake counts one job invocation, and both pages are answered with R.
5. **Different kind waits:**
   - A kind-B page during A's flight does not start B's job until A has committed.
   - At most one job is ever running (the fake keeps a max-concurrency counter).
   - B is answered afterwards.
6. **Spent request:**
   - A parked page's deadline passes during the held flight. It is answered `deadlineExpired` as notSent (the typed budget refusal when the budget was the bound).
   - The read-lane slot returns after the cleanup hop.
   - After release the flight still commits, and a new first page is served from the ledger with no second job invocation.
7. **Shutdown:**
   - `hostDidShutDown` while the job is held, then release.
   - Proof count is unchanged (no commit) and the waiter is refused `notCaptured`.
   - A page with retained rows is still served after shutdown.
8. **Service gone:** drop the composition while the job is held, then release. Nothing commits and nothing traps (weak core). The gate ends by deadline or cancellation.
9. **Capture age:** with an injected clock, start at t0 and release at t0 + d. The proof's `capturedAt` is t0, and expiry is measured from t0.
10. **Closed answers:** for each of `overBudget`, `internalFailure` and count mismatch at commit:
    - every waiter receives the closed answer once;
    - the fault is delivered once;
    - the job is invoked once, so there is no re-flight loop.
11. **Early refusal:** a total over the row bound is refused as `retentionBudgetExceeded` with its exact total, and the owner's `rowSource` is never called.
12. **Existing suites unchanged:** host page tests, collection ledger tests, stale and expired tests, profile sizing, and pm-sim `runtime-host-effects`. The host path goes through the flight.

## 8. Decisions to surface
- **Owner decisions:** none, provided the plan keeps one shared flight, the 0038 bounds and deadlines unchanged, and §4.3 recorded as a contract clarification.
- **For the parent to confirm before code (not owner policy):**
  - **A.** Record §4.3 in the docs or decision records.
  - **B.** After `hostDidShutDown`, a page that needs a new capture answers `.unavailable(.notCaptured)` instead of capturing inline. The alternative is `.failure(.internalFailure)`; I recommend `notCaptured` because it is honest that nothing was captured.
  - **C.** The `RuntimeRowSource` signature is async, only so that fakes can suspend; production does synchronous CPU work inside it.
- **Needs an owner decision, and is not proposed:** per-kind flights, reserving budget, throttling observer refreshes, changing when a complete list displays under churn, or any latency number.

## 9. Limits stated up front
- Under the strict one-thread pool the production projection still serializes with the owner. Fairness there stays inconclusive.
- **Object memory:**
  - while a flight runs, one older collection storage and the row values stay alive; this is outside the encoded ledger;
  - the extra object memory relative to today is at most that one older collection storage, kept alive after the kernel has moved on;
  - the parent should measure it.
- **Parked pages still hold read-lane slots, as queued pages do today.** Four concurrent parked pages could make a fifth read, a status read included, `transportBusy`. Stop has its own lane and is unaffected. The app's observer issues one page at a time. No lane capacity is added.
- **Churn:** a complete list still doesn't display under churn faster than one pass (§4.3). Repeated passes keep costing one projection each, now off the owner. No throttle is proposed.
- **pm-sim:** the causal fairness witness is in XCTest with a fake owner. pm-sim exercises the production path through the flight but asserts no timing.
