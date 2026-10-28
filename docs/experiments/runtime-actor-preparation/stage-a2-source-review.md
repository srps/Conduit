I accept StageA2 with the limits below. No P0, P1 or P2 issues: the Source is correct for the contract you described, where the owner calls the adapter serially and callbacks arrive concurrently. There are three P3 test-quality items and one doc nit. This is still MainActor preparation, not acceptance of the whole-actor move.

## A1 findings, checked against A2
| A1 finding | A2 status |
|---|---|
| P1: reprobe tests that fire weren't in the runs | **Closed.** VPNReprobeRecovery and the ConnectivityProbeSupersession reprobe case are in both ZFzM5n (normal) and Q5sH02 (strict). |
| P1: strict marker left behind | **Still open.** The manifest says `runtime-actor-strict-pool` exists again (created for Q5sH02). Unlink it before Full41, or that run is strict. |
| P2: coalesce test couldn't tell old code from new | **Closed.** The replacement test detects the bug: XURVaD, with the guard removed, failed both causal assertions (`SnapshotCoalescingTests.swift:224,231`, log `[emit, held, emit, rearmed, emit, probe]`). The third XURVaD failure was the fixture's re-arm XCTFail, not the guard. |
| P3: re-arm while a call is held | **Closed, by tickets.** An unheld take issues no ticket, so it can't wake the held call. A release after a re-arm frees the oldest held call and does not pre-release the new arm. `testARearmWhileACallIsHeldHandsTheHoldOn` checks both. |
| P3: `recordedExcept` unused | **Removed.** |
| P3: older tests could pass without anything being held | **Closed for the three harnesses** with a sticky teardown assertion. Locally created holds are not covered (your listed limit). |
| P3: comments | **Fixed:** `LaunchRecovery.swift:38-42` and `RuntimeHost.swift:571-572`. |

**Ticket deviation: I agree with it.** `DaemonRuntimeHostTests.swift:3737-3740` arms for the next call while the first is held, and that is legitimate: arming after the release would race the serial platform queue. FIFO tickets handle it exactly, so an XCTFail policy on re-arm would be wrong.

## #260 NetworkMonitor: correct
- **Fresh monitor per start:** each `start()` builds a new `NWPathMonitor` and debouncer and bumps the generation, all in one locked step. `start(queue:)` runs outside the lock (`NetworkMonitor.swift:62-78`).
- **Repeats are no-ops:** a start while one is active does nothing. A stop bumps the generation only if something was active, and cancels the debouncer and monitor outside the lock (`:81-89`).
- **Deliveries:** the generation check and the read of `onChange` happen in one locked step, and the callback is called outside the lock (`:93-96`). That guard is necessary, not decorative: a cancelled monitor's handler can still `signal()` the old debouncer after its `cancel()`, and the generation check drops that report.
- **Lifetime:** there is no retain cycle. The debouncer holds a weak `self`, and `deinit` cancels whatever is still active.
- **Host contract:** `startObservers` runs on every Start that brings a module up (`RuntimeHostLifecycle.swift:306-309`), so the idempotent start also fixes a latent double start of the same monitor. The stop runs only once every module is down (`:739-743`). A report claimed just before a stop can still reach the host. That was already true and the protocol documents it.

## Remaining P3 items
1. **Teardown no longer frees every held call.** `release()` now frees only the oldest ticket (`HeldCall.swift:181-190`), but the harness teardowns call it once (`DaemonRuntimeHostTests.swift:1756`, `RuntimeHostInteractiveTests.swift:174`, `AppStateHarnessTests.swift:172`). In A1, one release freed every waiter. If a failing test leaves two calls held at once, teardown's stop can hang instead of the test failing. That needs a hand-over with the second call held on a different queue, which is possible with unnamed arms but impossible with named `.platform-work` arms. Fix: release in teardown until `isHolding` is false, or add a small drain that sets `released = issued` and clears the matcher.
2. **The coalesce test can fail falsely under load, and the false failure looks like a broken guard.**
   - The probe is queued from the test task only after block 1 resumes it (`SnapshotCoalescingTests.swift:218-223`).
   - If that resumption takes more than about 100 ms, timer 2's hop lands before the probe. That is plausible on the strict one-thread pool.
   - The log would then be `[…, rearmed, emit, probe]`, exactly the guard-removed control's log.
   - Fix: queue the probe with `DispatchQueue.main.async` inside block 1, after the 400 ms wait. Main then runs block 2, the stale hop and the probe in that order, before timer 2 is armed, so the order is deterministic.
3. **NetworkMonitorTests can pass without the restart reporting.**
   - `afterStop` is read straight after `stop()` (`NetworkMonitorTests.swift:31,51`). A report claimed before the stop can append afterwards and satisfy the restart check on its own.
   - The 9uYlww baseline shows this didn't happen there, but the test can't rule it out. A short settle before reading `afterStop` closes it.
   - The `start(); start()` at `:45-46` doesn't show the second start is a no-op: two live monitors would also pass. Treat that as a limit, not something to fix.

## Doc nit (parent)
`Sources/ProxyKernel/AGENTS.md:24` says the timer handlers "run on utility queues". The coalesce timer is on `.global(qos: .userInitiated)`, and an immediate emit (not a Stop) is what invalidates its hop.

## Exact limits of this acceptance
- The NetworkMonitor generation guard for late reports is checked by reading the code, not by a test. The real monitor tests read the machine path read-only and depend on the initial report after start (5 s bound).
- The relay (30 s) and DNS-health (30 s) timers have no test that fires them.
- The coalesce witness and the mixed-priority witness both treat main as the owner, so both must be redone for Stage B.
- The teardown pool assertion covers the three harness holds only.
- Not covered: RuntimeActor, any parked-owner framed client, fairness counts, TSan, Release capture, and native, real-machine, VPN or helper evidence.

ZFzM5n (643 tests) and Q5sH02 (39 tests) are focused-run evidence; Full41 is still to come.