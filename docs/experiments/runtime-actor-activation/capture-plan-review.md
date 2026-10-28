# Off-owner capture plan: pre-implementation review

**I accept the plan, with five amendments, and none needs an owner decision.** It stays within the 0038 bounds, deadlines, wire protocol and lane capacities, and adds no public API, test hook, registry, budget, throttle or latency SLO. I can only read files in this session, so please save this as its own report.

## The three points you asked me to confirm

**A. A first page answered with its own stale R uses an existing shape. Confirmed.** It is `.rows(revision: R, status: .staleRevision(current: R′))` (`RuntimeServiceCore.swift:541`). The client accepts a stale status on any page (`RuntimeObserver.swift:438`) and handles it as "not current, read again" (`:294-298`). R's committed proof carries R's own total, and revision numbers are never reused (`RuntimeHostControlOwner.swift:80-90`), so no conflicting reference can appear.
- **Amendment 1: implement `bound(R)` by re-running `pageSource` as if the request carried cursor R.** Don't call the ledger's `decision` directly. That one path also re-checks incarnation, a now-unavailable reference, and the offset. The waiter then gets exactly what an ordinary cursor-R request gets today: current, stale, expired or not captured.
- The contract note in plan §4.3 then simplifies to: "a first page that waited on its own capture is answered as a request for that capture's revision".

**B. After shutdown, a page needing a new capture answers `notCaptured`, and retained rows still serve. Accepted, with your simpler shutdown (amendment 2).**
- **It fits the lifecycle.** `hostDidShutDown` is one synchronous owner turn, `ingress.close()` then `wakeWaiters()` (`RuntimeServiceCore.swift:463-466`). It is reached from the Quit's end (`RuntimeHostLifecycle.swift:1021-1022`) and from a composition built after the Quit ended (`RuntimeHostControlOwner.swift:625-627`).
- **In that same turn:**
  1. set a private `captureClosed` flag on the core;
  2. take the flight's waiters and set `captureFlight = nil`;
  3. wake them after that state is complete, as `wakeWaiters` does (`:916-921`).
- **Use a core-local flag, not an ingress change.** The ingress exposes only `isClosedAndDrained` (`RuntimeIngress.swift:73-80`), which also mixes in the drain.
- **The old job's completion becomes a no-op.** `finishCapture(id, …)` checks `captureFlight?.id == id` and drops anything else, so an old result never commits. The job holds only its frozen value and a weak core, which it frees when its CPU work ends. After shutdown no new flight can start, so at most one orphaned job exists.
- **Woken waiters re-run `pageSource`:** retained rows still serve, and anything needing a capture answers `.unavailable(.notCaptured, knownTotal: nil)`.
- This deletes the plan's "commit nothing at completion" branch (§2.2 and §4.4).

**C. An async, frozen, pure job with an internal alias. Accepted.**
- **The async signature is justified.** It lets fakes suspend without holding a pool thread, which keeps the causal tests deterministic under strict. Production does synchronous CPU work inside it. The protocol is internal and its shape doesn't change production behaviour, so this is not a test hook.
- **Amendment 3: freeze the whole `orchestrator.snapshot` value.** It is an O(1) copy-on-write retain. Don't add per-kind overloads, so `projectRows` stays untouched.
- The closure captures only that value and `kind`, never `self` or the orchestrator.

## Other checks
- **Custody, confirmed in the code.** `RuntimeServiceLimits` already budgets one capture's staging bytes beside the retained total (`:272-278`). One shared flight across kinds therefore stays within the existing encoded-byte ceiling; per-kind flights would exceed it.
  - **Amendment 4:** update that comment from "coexist in one owner turn" to "coexist for the one shared capture flight".
- **Capture age and ledger order:**
  - with `capturedAt = startedAt` and flights serialized, every commit's capture time is at least the previous one's, so the ledger's oldest-first ordering and cross-kind eviction still hold;
  - a flight that outlasted the 60 s retention age would commit rows already logically expired, and its waiters would get an honest `.expired(total)`; no special case is needed.
- **Waiter cleanup races:**
  - remove waiters by their unique token from whatever flight is current, so a late cleanup for an ended flight is a no-op and never touches a newer flight's waiter;
  - wake only after removal, matching `wake()` with `serviceReleased: true`;
  - the plan's `.subscriberGone` path can't occur within the start turn, so keep it only as a defensive retry.
- **Bounded retries:** `retry` comes only from a different-kind wait or from shutdown, and no flight starts after shutdown, so retries can't loop.
- **Amendment 5: a flight identity.** An `Int` generation or the record's object identity, checked at commit. Both shutdown handling and replacement safety depend on it.
- **Read lanes:** parked pages hold read slots, so four parked pages make a fifth read `transportBusy`. Stop has its own lane, and the app's observer pages one request at a time.
  - Today a status read issued during a capture waits out the whole turn; after this change it answers unless all read slots are parked. That is strictly better for the app.
  - Several concurrent clients could see busy reads. Record that as a limit; don't add capacity.
- **No new public API or production test hook:** `RuntimeCaptureFlight`, `.awaitingCapture`, `rowSource` and the generalized `installRegistration` are all internal. The only async override is in the test fixture.

## Test amendments
- **Test 7 (shutdown):** call `hostDidShutDown` while the job is held. The waiter is refused `notCaptured` immediately, before release. After release, the proof count is unchanged and nothing traps. A page with retained rows is still served, and the fake records no second job invocation after shutdown.
- **New:** a waiter of an ended flight expires after a new flight has started. Its cleanup leaves the new flight's waiters intact.
- **Test 3 (churn):** assert the stale answer arrives through the cursor-R path from amendment 1.

**Status:** the R4 all41 and TSan results remain historical evidence for the accepted core. Fairness stays blocked until this plan is implemented and its causal tests pass.