# Runtime service engine: checkpoint (2026-10-25)

Status: **M1, M3, the Phase 3 request envelope, and the focused correction slice pass the 216-test wrapper. Independent review found remaining D2 enclosing-transaction fault windows and documentation overclaims; these are queued for correction before this slice can ship.** The engine is still partial: **M2 is NOT IMPLEMENTED** (observation models, snapshot coalescing, retained pages, replay and control-log models). This is not an engine-complete, PR-ready or release claim. Local checkpoint only. No RuntimeHost, AppState, Store, helper, v1 or private-wire edits. Production host adoption is not part of this revision.

Branch: `codex/runtime-service-engine`, base `3195be6` plus `482caf8`. The local checkpoint will be rebased onto merged store PR 232 before further source work.

## Verification record

Latest run: the exact wrapper `bash /private/tmp/conduit-runtime-stage1-20261024/verify-runtime-service.sh` printed `PASS: runtime-service focused checks`. Logs are under `/private/tmp/conduit-runtime-stage1-20261024/runtime-service-checks/`.

- `swift build`: no warnings from the runtime-service files. One warning is in `Tests/ConduitTests/ConfigRuntimeRangeRefusalTests.swift` (main-actor `group` mutated from a nonisolated context). That file is outside this slice and was not edited here.
- `swift test`, filter `RuntimeService|ControlService|AdmissionLedger|Subscription|Replay|ControlTransport|ControlCollectionRetention|FramedRuntimeClient|RuntimeClient|ControlRuntime|RuntimeSnapshotProjection`: **216 tests, 0 failures** (211 before this slice).
  - Added in this slice: `RuntimeServiceWorkTests` 19 → 23 (outcome-fault witness, request-cap delta, exact ceiling, maximal-frame boundary) and `RuntimeServiceLifetimeTests` 11 → 12 (parked closure released after the gate lock). No other suite changed count.
- Imports fence, event catalogue, decisions check and decisions tests: PASS. `pm-sim framed-runtime-client` and `pm-sim runtime-service-wire`: PASS (the script runs under `set -e`).
- The probe test in the lifetime suite was **not run against the pre-fix gate** in this slice, because the slice's verification was limited to the one wrapper. Its ability to fail on the old code rests on reading the path (see Gaps).

## Bounded models: actual explored counts

Unchanged in this slice: the alphabets are the same, so the counts are the same.

- **Wait model** (`WaitAction`, 9 actions): exhaustive over every sequence of depth 1 to 4, **7,380 sequences, all agree** (9 + 81 + 729 + 6,561). Then **150 seeded walks of 40 actions** (SplitMix64, seeds 1 to 150). Budget 25,000: not reached.
- **Work model** (`WorkAction`, 12 actions): exhaustive over depth 1 to 4, **22,620 sequences, all agree** (12 + 144 + 1,728 + 20,736). Then **150 seeded walks of 40 actions**. Budget 25,000: not reached.
- **Join and reject are qualified: `.dns` only.** The model submits a proxy stop but never joins or rejects it. Adding `.joinStop(.proxy)` and `.rejectStop(.proxy)` would make the exhaustive depth-4 enumeration 41,370 sequences, past the 25,000 budget. So the proxy join and reject paths have no model witness. The admission suite covers joining for dns; rejection coverage must be verified separately.
- Independence limit: the wait reference's park and wake ordering is written from the design rule "begin the next hop before the waiter part ends". It is partly derived from the rule the code follows, so it is not independent evidence for that ordering. The work reference is written from the supersession, drop, slot and capacity rules.

## Focused correction slice (2026-10-25)

### D1: payload release after the gate lock

- `RuntimeWaitGate.resolve` moves the spent payloads (the round's closure and the typed refusal) out under the lock into a local, and it releases them after the unlock. The payloads are released before the timer is cancelled and before the caller resumes. The local is retained explicitly through the unlock with `withExtendedLifetime`, then released with an explicit assignment.
- The refusal is now cleared at resolution as well. It is kept until resolution, because a round that parks can return the wait to open on a wake.
- `runRound` runs the claim and the attempt in a helper, `runClaimedAttempt`, so the round's own local closure is gone when the helper returns. The gate is then the only holder.
- Test seam: `RuntimeWaitGate.isLockFreeForTesting` tries the lock. It never waits, so a regression fails the test and cannot hang it.
- Witness `testTheParkedClosureIsReleasedAfterTheGateLockIsFreeAndBeforeTheCallerResumes`: the round parks, so the gate holds the closure, and the deadline ends the wait. The probe's destructor records `isLockFreeForTesting`. The test asserts `true` and asserts the caller's outcome is `.failed(.notSent(.deadlineExpired))`.
- The earlier witness `testAResolvedWaitReleasesItsCapturedRequestWhileItsHeldTimerKeepsTheLane` is unchanged. It checks that payload release does not free the lane while the timer holds it.

### D2: outcome fault staged as data, delivered last

- `settleLogically` now stages the retained form as pure data first (`stageRetained`). Then it runs the whole transaction: the operation is marked settled, the candidate is cleared, the outcome is stored, the control entry is appended, the waiters wake and retention is swept. Only then does it call `owner.serviceFault(.outcomeNotEncodable)`, if one was staged.
- The outcome measure is a fault-injection seam: `RuntimeServiceCore.init(measureOutcome:)`, default `RuntimeServiceCore.measureRetained`. The current codec encodes every outcome, so the production path cannot reach the fault without the seam. Provenance: the seam is internal, and only test harnesses substitute it.
- The fault path no longer uses the `try?` size helper. A `do/catch` stages the closed case, and the error text is not kept.
- Reentrant witness `testAnOutcomeEncodeFaultReachesTheOwnerOnlyAfterTheSettlementIsComplete`: the fake owner's fault hook reads the service and sees the replacement outcome already retained, zero pending operations, and the fault recorded before the callback.
- The submit path is unchanged in ordering. A command that fails to encode records nothing and fences nothing, so the owner call there is already coherent.
- Host limit: the production host's `serviceFault` implementation (the event emitter) remains an adoption step. This slice does not weaken the event-before-publishing outcome rule, and the canonical host emitter is still the adoption gate.

### Custody accounting: lane reservation

Derivation. Each reservation holds the following at its peak, counted in encoded payload bytes.

| Custody item | Holder | Live across the await? | Bound |
| --- | --- | --- | --- |
| Request frame (the `Data` parameter of `exchange` or `openStream`) | the caller's call | yes, for the whole call | `maxRequestBytes`. A larger frame is refused in the front door before any reservation. |
| Decoded message (`ControlRuntimeMessage`, captured by the round) | the round closure, then the local in `exchange` | yes | `maxRequestBytes`, as the encoded size. This is not the in-memory size. |
| Typed refusal (`boundRefusal`) | the gate, until resolution | yes, because a parked round can return to open | `maxReplyBytes` |
| Produced answer (reply, first frame or page) | the round's result, handed to the caller | at peak, together with the refusal | `maxReplyBytes` |

Per reservation: **`2 × maxRequestBytes + 2 × maxReplyBytes`**. Lanes: `laneCount ×` that. A stream pull carries no request, and its produced frame is within the same bound.

Prompt release. The round's closure and the refusal are released at resolution, after the lock and before the caller resumes. The request frame cannot be released by the service, because the caller owns it, so it is counted for the whole call. The decoded message local in `exchange` and `openStream` lives until the function returns. It is counted in the bound, and no earlier release is claimed.

Not claimed: exact RAM, the in-memory size of the decoded value, and optimizer release timing. The bound is the encoded payload that the service can hold at once.

Outside the budget: caller-held stream handles, including the first frames of refused opens and budget refusals, which the caller holds after the service has released them. Process memory. Those are stated as limits.

Fixture values (test values, not policy): `maxRequestBytes` 4,096 and `maxReplyBytes` 65,536. `laneCount` is 7: two ordinary, two read, and one stop per each of the three `ControlModule` cases. Per reservation: 139,264 bytes. Lane term: 974,848 bytes, up from 946,176 under the old single-request formula. The request-cap delta is `(2 × laneCount + operationCapacity) × 4,096`, which is 90,112 bytes for the 8-operation fixture.

### Limits and product tests updated

- `RuntimeServiceLimits`: `perReservation` is `checkedSum([maxRequestBytes, maxRequestBytes, maxReplyBytes, maxReplyBytes])`. The lane documentation states the custody items above.
- `testTheRetainedByteBudgetIsTheExactSumOfEveryTerm`: the lane term is `laneCount × (2 × maxRequestBytes + 2 × maxReplyBytes)`.
- `testDoublingTheReplyCapChangesTheBudgetByItsReservationAndFirstFrameTermsOnly`: unchanged in formula. The reply coefficient is still 2 per reservation plus one per subscriber.
- `testDoublingTheRequestCapChangesTheBudgetByItsCustodyTermsOnly` (new).
- `testTheCeilingAcceptsExactlyTheBudgetAndRefusesOneByteLess` (new): the ceiling is inclusive.
- `testAMaximalEventFrameFitsTheSmallestAcceptedReplyCapExactly` (new): the record is sized to exactly `maxEventBytes`, at the maximal cursor. The frame at its exact size is accepted at that cap and refused at one byte less, by the codec and by construction. The measured overhead is exact for a maximal event, not an over-estimate. That is asserted, not hard-coded.
- Ceiling values are fixture values. No shipping default was added.

## Wire and budget envelope (unchanged in this slice)

- The request envelope is `ControlRuntimeRequest { budget, call }`, with the six calls unchanged. Zero is a valid budget, answered pre-admission with the typed refusal. The receiver deadline is `min(caller absolute, arrival + budget)`.
- The byte budget is an exact checked sum of the encoded payload terms. A configuration whose budget exceeds the owner's ceiling is refused at construction. A reply cap too small for one maximal event is refused at construction.
- `maxRequestBytes` and `maxReplyBytes` are the server's frame caps. A caller can narrow them, never widen them.

## What the current source does (seams)

- `RuntimeOwnerScheduling.swift`: `RuntimeOwnerScheduling.hop(_:)` is the one dispatch seam. Tests use a finite manual FIFO.
- `RuntimeServiceLimits.swift`: validated limits with no shipping values. `retainedByteBudget` is the checked sum of alias partitions, the operation table, outcomes, the ring, the control log, the ingress, the collections, the transport's lane reservations, and subscribers' first frames.
- `RuntimeAliasTable.swift`: request aliases as their own component, with per-partition bounds, oldest-first eviction and expiry. An alias keeps a fingerprint of the encoded command, not the body.
- `ControlCommandOwner.swift`: `startEffect` receives the command at launch. `ControlEffectReport` carries `settled` (logical) and `quiesced` (physical). `serviceFault(_:)` receives a closed `ControlServiceFault` with no body and no error text.
- `RuntimeServiceCore.swift` (facade): composes the alias table, the operation table, the observation log, subscribers, parked waits and captures. Stop slots: one active and one queued per module. Ordinary capacity is released only by quiescence.
- `RuntimeTransportGate.swift`: `RuntimeLaneTicket` with named parts (`hop`, `timer`, `waiterCleanup`). The slot releases after every part ends, and the release callback runs outside every lock. `RuntimeWaitGate` is one caller wait with one timer and any number of owner rounds.
- `RuntimeInMemoryTransport.swift`: the request is decoded once and the lane is classified from the decoded envelope. Typed registration, pull-start and release results. A stream `end` frame releases the subscriber in the same owner turn.

## Witnesses (current)

- Stream end is terminal (`testAStreamEndReleasesTheSubscriberInTheSameOwnerTurn`).
- Held timer keeps the lane, not the payload (`testAResolvedWaitReleasesItsCapturedRequestWhileItsHeldTimerKeepsTheLane`).
- Parked closure released after the gate lock and before the caller resumes (`testTheParkedClosureIsReleasedAfterTheGateLockIsFreeAndBeforeTheCallerResumes`), new.
- Dropped framed subscription (`testADroppedFramedSubscriptionReleasesItsSubscriberWithoutACancel`).
- Evicted accepted alias (`testAnEvictedAcceptedAliasAnswersNotRecordedAndAFreshRetryIsFencedAgain`): the selected best-effort contract. No exactly-once promise survives eviction, and no retry is replayed blindly.
- Encoding faults: command (`testAnEncodeFailureIsReportedAsATypedFaultWithItsOriginAndNoBody`) and outcome, with the reentrant witness above.
- Exact budget, reply-cap delta, request-cap delta, exact ceiling, ceiling refusal, reply cap that carries one event, and the exact maximal-frame boundary.
- Registration resolved before park (`testARegistrationResolvedBeforeItParksKeepsItsReservationUntilItsCleanupRuns`).
- Open cancelled after registration (`testAnOpenCancelledAfterItsSubscriberRegisteredRemovesIt`), gate-level.

## Gaps, stated plainly

- No transport-level open-abandonment witness. The open's attempt and its finish are one owner turn, so a concurrent expiry can only land from another thread during that turn. The gate-level witness covers the abandon path.
- The refusal-encode failure path (`notSent(invalidReply)`) is code-only. With the fixture caps a refusal is always smaller than its request, so no test reaches it.
- The outcome-encode fault is reachable only through the measure seam, because the current codec encodes every outcome.
- The parked-closure probe was not shown to fail against the pre-fix gate in this slice. The brief limited verification to one wrapper. Its meaning rests on the path: before this change, a parked wait's gate was the closure's only holder, and `resolve` released the closure inside the lock. A revert run would settle it.
- The work model's join and reject are `.dns` only (see Bounded models).
- `ControlRuntimeStream` has no deinit, and its drop obligation is not written down. The framed client's own drop path is tested. A raw caller that drops a stream without cancel holds one subscriber slot until `subscriberLimit`.
- The tests wait on observable state with fixed limits (`awaitState`, `runCall`). They do not sleep, and they are not timing proofs.
- Encoded payload accounting is not a process-memory guarantee. Caller-held stream handles are outside the budget.
- A missed owner quiescence holds ordinary capacity and the module's stop slot permanently, with no watchdog. That is the cost of physical quiescence. No test makes that state observable.

## History of the counterexamples (corrected)

Three counterexamples were found while the models were being built. The artifacts record each one as a model or replay-harness error:

1. The replay's round parked without beginning the waiter part.
2. The reference ended the waiter part before it began the next round's hop, so it saw a released reservation.
3. The replay's wake skipped the registration removal that the service's own wake performs.

Separately, the current production code has these hop-count and registration properties. They are listed as code properties, not as defects that were reproduced:

- `RuntimeLaneTicket` counts hop parts. A round that queues the next round begins the next hop before the current one ends, so two hops can be live at once, and the slot holds until both end.
- `installRegistration` begins the waiter-cleanup part before the registration exists. A resolution that lands before the park queues the cleanup, and the part holds until that cleanup runs.

**Attribution is unresolved.** An earlier phase-2 writer response also reported one real production hop-count ticket defect. A search of `docs/` and the run directory found no artifact that shows it, and an independent review of the run directory checked the same. So this checkpoint makes no attribution. The earlier statement "none of the counterexamples were production defects" is withdrawn as a proof. The artifacts do not establish whether either production property above was an observed failure.

## Independent correction review

A read-only Claude review after the focused writer froze confirmed D1 lock-free release, exact boundary tests and the revised accounting formula. It found two remaining fault callback windows: superseding a queued stop calls settlement before installing the replacement, and quiescing an unsettled operation calls settlement before releasing physical capacity. Those encode faults require the injected seam with today's codec, but the enclosing transaction must still finish before reporting. Correct both and add reentrant witnesses before adoption. It also found a release comment stronger than actual in-attempt lifetimes, and an accounting comment excluding the request buffer despite counting it. These remain correction work, not passing evidence.

## M2: proposal, not implemented

M2 is not implemented. The final review of this proposal comes before any M2 code. Decisions in this section come from the parent's direction.

Principles:

- Collection revisions are the owner's `ControlCollectionRevision` (an opaque `ControlOrdinal`). The service compares them **by equality only**. It assumes no ordering, no density and no range. `ControlOrdinal`'s `Comparable` is not removed.
- No second lifecycle or collection revision namespace. The service never invents a revision.
- Proof is bounded and exact. A captured revision is retained as a proof record: the revision, the exact total from `ControlCollectionReference.totalCount` in the same owner turn, and capture and last-served times. Rows are optional.
- Outcomes by page request, against the owner's current revision `C` and a proof table for the kind:
  - cursor revision equals `C`: serve the current capture. Over budget means the whole capture is `unavailable` (budget), with no truncation.
  - cursor revision is an older captured revision with its rows retained: `staleRevision` with rows.
  - cursor revision has a proof, but its rows were evicted (known row-eviction proof): `expiredRevision`.
  - no proof, forgotten proof or never captured: `notCaptured`. Unknown or unproven is never a false expiry.
- A proof eviction is `notCaptured`, not `expired`. No unbounded tombstones are kept.
- One producer path on the wire. The canonical no-rows reply is the top-level `ControlPageReply.unavailable(kind, reason, knownTotal?)`. The service must not emit both a nested `page.status.expiredRevision` and a top-level `unavailable` for the same case. An old decode case may stay for compatibility, but it is documented as not produced.

Components and API sketch (internal, fixture values only):

```swift
/// Bounded proof for one captured revision. Equality-only key. No ordering is assumed.
struct RuntimeCaptureProof {
    let revision: ControlCollectionRevision   // owner-issued, opaque
    let total: ControlCount                   // exact, from the same owner turn's snapshot reference
    let capturedAt: ContinuousClock.Instant
    var lastServedAt: ContinuousClock.Instant?
    var rows: ControlProjectedRows?           // nil after row eviction; the proof stays
}

/// Per kind: at most `proofCapacityPerKind` proofs, and at most `rowRetentionPerKind` retained row sets.
/// Charged in the budget: proofCapacityPerKind × kinds × fixed proof bytes, plus the retained row bytes.
struct RuntimeCollectionLedger {
    mutating func capture(kind: ControlCollectionKind, proof: RuntimeCaptureProof) -> Bool   // false: over budget
    func decision(kind: ControlCollectionKind, cursor: ControlCollectionRevision?, current: ControlCollectionRevision) -> RuntimePageDecision
}
```

Owner projection and count:

- Use the snapshot's existing exact total (`ControlCollectionReference.totalCount`, read in the same owner turn) as the count preflight. Do not add a second count accessor or a second data path.
- The owner's bounded projection accepts a row count and byte budget. It stops building once over budget and returns an over-budget result, so the whole capture is `unavailable`, and no array is built to learn its size.
- Bridge fix: `RuntimeSnapshotControlProjection.swift` at `:272` and `:300` builds `tunnelDNSHostRows(...)` in full only to take `.count`. It takes the direct count instead. This is a `ProxyControlBridge` change and is part of the M2 implementation, not of this slice.

Subscription and publication:

- One subscription table owns cursors, parked waiters, the last-seen snapshot generation per subscriber, and the sticky terminal state.
- The buffered first frame stays in the existing `RuntimeStreamHandle`. It is not duplicated into the table.
- One latest safe DTO slot per incarnation, with a private delivery generation for coalescing (`RuntimeCounter.successor`, exhausted by counter). The generation is internal delivery state. It is not a lifecycle authority. The slot keeps the owner's wire stamp and revisions unchanged.
- Snapshot encoding happens per pull, under the frame limit. It is not one global encode. The byte budget counts the retained DTO. It is not a CPU bound.
- Publication: `ownerDidChange()` or `refresh()` runs in one owner turn. It captures the snapshot, updates the latest slot, and wakes subscribers whose last-seen generation is behind.
- Baseline: the snapshot, the event high water and the registration are captured in one owner turn, as now.
- The page read may refuse for budget or expiry even when the scalar reference identifies the current revision. The owner's stamp is not rewritten, and no placeholder revision is invented to report cache availability.

Reference comments: the retention comments must state that no retention lease is promised. Eviction is best-effort, bounded, and reported as `notCaptured` or `expiredRevision` only with proof.

Model and tests (planned, not built):

- An M2 reference model over capture, row eviction, proof eviction, page read by revision, publish, subscribe, park and wake, and terminal. Compare the page decision and the subscriber state after each action. Exhaustive to depth 4, then seeded walks, with a finite budget.
- Tests: over-budget capture is whole `unavailable` with no truncation; stale-with-rows; expired after row eviction; `notCaptured` after proof eviction and for a never-captured revision; a single producer for each reply shape; coalescing (many publishes, one latest generation delivered to each subscriber); sticky terminal; baseline atomicity in one turn.

Open questions for the parent:

1. The per-kind proof capacity and row retention are fixture values. Which shipping values does the owner choose? Not decided here.
2. Does the old nested `expiredRevision` decode case stay after the producer is unified? Recommended: keep the decode, and document that nothing produces it.
3. The bridge's direct-count change lands in M2, not in this slice. Confirm.

## Remaining M2 pending items

- Count and the page-reply shape are settled in the proposal above, pending parent review.
- No M2 code is written. The next step is the parent's review of this proposal.
