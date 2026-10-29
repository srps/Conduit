# Off-owner capture fairness (R5): independent Source review

**I accept R5.** I found no new causal defect, and all five plan amendments plus the exact known-total change are implemented. This was a bounded read of the about-ten-file patch, done before your session wall; I built and ran nothing. I can only read files in this session, so please save this response separately.

## Flight state, custody and closure ownership
- **One shared flight across kinds:** `captureFlight: RuntimeCaptureFlight?` (`RuntimeServiceCore.swift:163`), with identity by object. That keeps the one capture staging term `RuntimeServiceLimits` already charges.
- **The detached job holds only what it needs:** `job`, which closes over the frozen `orchestrator.snapshot` and `kind`, never the host (`RuntimeHostControlOwner.swift:188-193`); `budget`; `scheduling`; the `flight` object; and the service weakly (`RuntimeServiceCore.swift:612-621`). After shutdown or the service's release, it frees these when its CPU work ends. At most one such job can be orphaned, because no flight starts after shutdown.
- **Same-turn freeze:** `owner.snapshot()` (`:551`) and `owner.rowSource` (`:612`) run in one synchronous turn, so the rows are exactly R's.
- **A dropped flight never commits:** `finishCapture` returns at once unless `captureFlight === flight` (`:629`).
- **Shutdown, as you preferred:** in one turn it sets `captureClosed`, ends the flight with `retry`, sets it to nil, then wakes (`:470-479`). Retained rows still serve; a needed capture answers `notCaptured` with the reference's exact total (`:597`).
- **Commit:** age is measured from `startedAt` (`:636`; `RuntimeCollectionLedger.swift:172, 207`). Every closed refusal carries `flight.total` (`:641, 653`). Each fault is delivered once per flight (`:645-656`). All state is complete before any wake (`:658`).

## Park, cancel and deadline races
- **Spent gate before parking:** `.ticketReleased` releases the wait at once (`RuntimeInMemoryTransport.swift:423-426`).
- **Gate resolved while or after parking:** the single shared `installRegistration` (`:638-671`) runs a cleanup hop that releases by token and only then returns the read-lane slot. So the `waits.count < readLaneCapacity` precondition (`RuntimeServiceCore.swift:604`) can't count a dead wait.
- **Late cleanup of an ended flight** is a no-op on any newer flight (`RuntimeCaptureFlight.swift:72-75`).
- **Wakes run only after `end()` has removed the waits** (`:79-88`), which matches `serviceReleased: true`.
- **The `.subscriberGone` re-read** (`RuntimeInMemoryTransport.swift:427-429`) can't happen within the start turn; it is defensive only. The `.awaitingCapture` answer at `:433-435` is unreachable and closed.

## Stale answers and duplicated paths
- `.revision(R)` re-runs the same `pageSource` with cursor R (`RuntimeServiceCore.swift:528-546`). That is amendment 1: one decision path, so there is no second copy.
- There is still one registration path and one projection path. The only new production state is the flight record.
- **Core introspection:** `captureFlightWaitCount` is internal and read-only.

## Tests and fixtures
- **The flipped measurement** asserts `statusAt < exited` and `stopAt < exited`, and stays inconclusive when the requests were issued after the projection (`RuntimeActorFairnessTests.swift:258-263`). The controls (`F8pg8R` failing on the old source, then 52 passing) support it.
- **The async fake** (`RuntimeServiceFixtures.swift:344-354`) is fixture-only.
- **Causal tests** cover each planned case (`RuntimeActorFairnessTests.swift:409-665`):
  - control answered while a flight is held;
  - churn answered as a stale read, not a timeout;
  - same-kind pages joining one flight;
  - another kind waiting for the flight;
  - a page that ends while the flight is held, with the flight still committing;
  - shutdown waking at once, with no old commit;
  - capture age measured from the start;
  - late cleanup leaving a newer flight intact;
  - a closed answer reaching every page once;
  - a total past the row bound refused before any flight.

## Limits (no new policy)
- The strict one-thread pool still serializes the production projection.
- One frozen snapshot plus its row objects is object custody outside the encoded ledger.
- Parked pages can make a fifth read `transportBusy`, while Stop keeps its own lane.
- A complete list still won't display under churn faster than one pass.
- `ledger.capture`'s `capturedAt: nil` default serves only direct ledger callers.
- I did not review pm-sim's internals beyond the flight path.

**Carried forward:** full41 is the parent's gate. #250 and #118 remain.