# Off-owner collection capture: shape clarification (read-only)

**Short answer:** the off-owner shape works within existing semantics, provided it uses one shared flight across all kinds and two small contract clarifications. No owner decision is needed. I can only read files here, so please save this as its own report, separate from the earlier ones.

## 1. Custody: one shared flight across kinds, not one per kind
- **Today's peak already exceeds 8 MiB transiently.** `captureCurrent` builds up to one capture's rows (≤4 MiB encoded) before `collections.capture` evicts anything (`RuntimeServiceCore.swift:567-569`). The ledger charges only stored row sets against 8 MiB (`RuntimeCollectionLedger.swift:193-210`). So the encoded peak today is 8 MiB retained plus up to 4 MiB being projected. It is not true that "everything is charged inside 8 MiB", and the plan should not claim it.
- **Per-kind flights would add up to 4 MiB per in-flight kind.** That breaks the selected 4 MiB / 8 MiB profile in spirit and needs owner review.
- **One shared flight across kinds keeps exactly today's peak**, with no change to 0038. Only the duration of the in-flight custody grows.
- **It also preserves ledger order.** The ledger assumes proofs are ordered by capture time (`:79`, and eviction at `:188-201, 273-283`). One flight serializes commits in start order; parallel flights could break that order.
- **Reservation is not an option.** Reserving 4 MiB at flight start would evict retained rows early, expiring pages that clients are mid-way through. That is a behaviour change.

## 2. Sorting and cost of the snapshot copy
- **The kernel doesn't sort.** `ActiveConnectionStore.ordered` is insertion order with swap-remove (`ProxyStatus.swift:197-240`). The sort happens inside `projectRows` (`RuntimeSnapshotControlProjection.swift:101-106`), so it moves off-owner with the projection.
- **No locks are involved.** `orchestrator.snapshot` is an owner-isolated value. Taking it is an O(1) copy-on-write retain (`RuntimeHostControlOwner.swift:158, 188-189`).
- **No new owner cost.** The revision tracker already keeps the kernel's own storage as `source` (`:74, 88`), so the first kernel mutation after any snapshot read already pays the O(n) buffer copy today.
- **Existing cost, not part of this plan:** minting a revision compares `ordered` arrays (`ProxyStatus.swift:262-264`), which is O(n) whenever the storage differs. That runs on every `snapshot()` (`RuntimeHostControlOwner.swift:167`).

## 3. Committing an older revision after the snapshot changed
- **References stay compatible.** Revision numbers never repeat: the tracker increments on any change and never goes back (`RuntimeHostControlOwner.swift:80-90`). So a committed proof for R with R's own total can never conflict with a later reference. The total check in `pageSource` (`RuntimeServiceCore.swift:530-533`) applies only to the current revision.
- **Required: take the projection input in the same owner turn that named R.** Today the rows are R's because `snapshot()` and `projectedRows` run in one turn. Off-owner, the job must capture `orchestrator.snapshot` in that same `pageSource` turn and carry R and its total from that turn's reference.
- **Required: decide what a parked first page receives.** A parked page with no cursor, waking after R committed while the current revision is R′, would hit `.needsCapture` again (`RuntimeCollectionLedger.swift:146-150`). Under churn faster than one capture, that loops until the page's deadline, and the observer then reports "could not be read". That is a new user-visible failure.
- **Minimal fix:** answer that waiter with R's rows and status `staleRevision(current: R′)`. This is the existing reply shape (`RuntimeServiceCore.swift:541`). The client already accepts a stale status on any page, the first included (`RuntimeObserver.swift:438`), and handles it as "not current, read again" (`:294-298`). That is exactly what churn during paging produces today.
  - **Contract clarification to record (no owner decision):** the ledger's internal rule that a cursor-less request reads only the current revision gains one case. A first page whose own capture committed a superseded revision is answered with that revision, marked stale.
  - **Why no owner decision:** no decision selects that rule, and 0014 asks only to "preserve totals and explicit continuation/staleness" (`:40`).
- **Recommended: set `capturedAt` from the start turn's clock** (`RuntimeCollectionLedger.swift:205`). Proof age then still measures from the capture, rather than being extended by the flight's duration.
- **Unchanged limit:** a complete list still won't display under churn faster than one pass. Off-owner capture widens that window from paging time alone to capture plus paging. Changing it would be a product decision.

## 4. Minimal existing interfaces (no registry, queue or public API)
- **Owner protocol:** `ControlCommandOwner.projectedRows(for:within:)` (`ControlCommandOwner.swift:77`) becomes a same-turn row source. It returns a `@Sendable (ControlRowBudget) -> ControlProjection` that closes over the value taken in that turn. `RuntimeHost` (`RuntimeHostControlOwner.swift:188-189`) and `FakeCommandOwner.projectionOverride` adapt to it. The protocol is internal.
- **Park and wake:** reuse what stream pulls use.
  - The page attempt returns nil after `gate.park(_:)`, covered by `ticket.begin(.waiterCleanup)`. The flight's completion calls `gate.wake()`, which re-runs the round (`RuntimeTransportGate.swift:342-389`; the pattern is in `RuntimeInMemoryTransport.swift:572-605`).
  - The only new state is the single flight's own record: kind, revision, total, start instant, and parked `(token, wake)` entries.
  - Parked entries are bounded by the existing read-lane capacity, because a lane is reserved before the attempt runs. No new capacity is added.
- **Joining:** a page for the same kind joins the running flight and gets R's rows, current or stale. A page for another kind parks on the flight, wakes when it ends, and starts its own flight.
- **Cancel and deadline:** the gate's park-end cleanup hops to the owner and removes that waiter's token. The flight is not cancelled: its sync projection runs to completion, and the single flight bounds the waste.
- **Shutdown:** if the service has shut down, the completion hop skips the commit and wakes the waiters, whose rounds then refuse.
- **Executor:** a CPU task on the cooperative pool. Not PlatformWork, where helper calls of up to 40 s could queue ahead of it. On the strict one-thread pool, owner and projection serialize, and that stays inconclusive by design.
- **One path for every kind.** Small kinds also go through the flight, at the cost of a few hops, rather than keeping a second inline path.

## 5. Object custody versus encoded custody
- **Encoded:** unchanged, per §1.
- **Objects:** the flight holds one kernel snapshot value, dominated by the `activeConnections` storage, plus the Swift row objects it builds. These are outside the encoded ledger. 0038 already says byte accounts are not a RAM bound (`:64-65`).
- **Extra relative to today:** at most one old collection storage, kept alive after the tracker has moved on to a newer revision. Release it on commit, failure or shutdown.

## 6. Test that becomes causal
Flip `RuntimeActorFairnessTests.swift:262` so that status and Stop issued during the projection are answered before it exits (`statusAt < exited`) under a normal pool. Add:
- the churn case: a waiter answered stale with R, not left to time out;
- a different kind waiting behind the flight;
- a waiter's deadline expiring while the flight still commits.

## Owner decision
- **None needed** if the plan keeps: one shared flight, the 0038 bounds unchanged, deadlines unchanged, and the stale answer above (recorded as a contract clarification).
- **Needed before code** if the plan uses per-kind flights, reserves budget, throttles refreshes, or changes when a complete list displays under churn.