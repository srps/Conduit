Review checkpoint: after wait injection, bounded recording and task teardown registration. The parent subsequently moved file-hold release registration before early throwing setup, closing limitation 2 below. Verification results are recorded separately.

# Review: client-quit no-stream fallback, deterministic final read

Scope: the current uncommitted state of `Sources/ConduitShared/PrivateConfiguration/RuntimeClientQuit.swift` and
`Tests/ConduitTests/RuntimeHostControlOwnerTests.swift`, read as final code, plus the author report. I read the root and `ConduitShared` AGENTS
files, `HeldCall.swift` (HeldCall, HeldStateFileRead, LockedSlot), `RuntimeDeadline.after`, and the store read paths in
`ConfigurationStore`/`ConfigurationStoreIO`/`VerifiedConfigurationFileReplacement`. I did not build, run, use git or edit anything in the repo.

## Verdict: ACCEPT (no material defects)

## Production

- The one new seam is the last parameter, `sleep:`, which is package-level and stdlib-typed. Its default `Task.sleep(until:clock: .continuous)`
  is the same call the code made before, so behaviour under cancellation is unchanged too. It is stored privately in `SettlementWaiter`, and only
  `keepCaller` uses it.
- `ContinuousClock.now < instant`, the 200 ms reserve, the single deadline, every lookup's deadline and the cancellation→`false` mapping are all
  unchanged.
- Nothing became public. No new dependency, no module-direction change, no new clock type, no wire or policy change.
- Every other caller (AppState, pm-sim, RuntimeActorPlacementTests, RuntimeHostControlStreamTests, the docs Probe) passes arguments by label
  with no trailing closure, so they all keep the default.

## Test fixture `HeldQuitSleep`

- **Exactly-once resume:** the continuation is stored under the lock, and whichever side takes it first clears it: `release()` or `onCancel`.
  - A cancel that lands before the store is caught by the `Task.isCancelled` check under the same lock. The cancel flag is set before
    `onCancel` runs, so either the body sees the flag or `onCancel` sees the stored waiter.
  - A release that comes before the call is caught by `released`.
  - No double resume and no lost wakeup.
- **Bounded recording:** at most two instants are recorded. A third call throws before anything is appended, and `keepCaller` maps that to
  `false`. Production makes at most two calls, so this path cannot be reached.
- **Second call:** it uses the real clock, bounded by `began + 10 s`, so a mutated routine still ends.
- `requested == [finalRead]` is exact: `RuntimeDeadline.after` is `now.advanced(by: total)`, and Instant arithmetic is exact.

## Store handover

- `HeldCall.arm` while a call is held hands the hold on, and `release()` frees the oldest ticket (the prior update's platform read).
- **Refused-subscription test:** the next matching read is the preferences save's pre-read of `plan.preferences.path`.
  - `observeAndDecode`, which reads all three files, is reached only from `load`.
  - The coupled commit reads the preferences file only when legacy preference values must be carried (author assumption 1).
- **Stream-ends-early test:** the runtime path is first read by the declared save's pre-read, provided the latch revoked the prior update's
  runtime write (assumption 2; the first owner test asserts `.notAttempted(.superseded)` for the same setup).
- **If either assumption is wrong, the tests fail; they cannot pass falsely.** The wrong operation would be held, the routine could never reach
  the held sleep, and the bounded waits fail. The result assertions would also contradict it: configuration `.settled`/`.persisted` in one
  test, prior settled in the other.

## Does this remove the timing lottery?

Yes.

- **Before:** the outcome depended on two races that are not deterministic:
  - the host's end against the routine's lookups;
  - the real-clock wake at 9.8 s plus a 200 ms wire window, on a loaded runner. The 10.836 s return fits a late wake or a late final read.
- **Now the order is forced:**
  1. The save is held.
  2. Both of the routine's Quit lookups see it pending.
  3. The routine parks in the held sleep, and the test asserts `quitEnded == false` at that point.
  4. The save is released.
  5. The test waits until `quitEnded`, `pendingAdmissions == 0` and `pendingOperationCount == 0`. That makes the Quit's separately reported
     settlement observable, not just its end.
  6. The sleep is released while roughly 9 s of wire budget remain.
- **The only real-time dependence left** is a liveness bound: everything must happen before `began + 9.8 s`. It is asserted with a clear
  message (`XCTAssertLessThan(now, finalRead)`), and the total was not extended.
- **The final settled Quit is read by the routine's real final lookup.** Deleting that lookup makes both tests fail on a semantic assertion
  after about 10 s.

## Assertions and cleanup

- **Assertions that still carry weight:**
  - refused test: prior receipt `.notAttempted(.superseded)` and handed to the producer, configuration `.persisted`;
  - stream test: prior settled and handed to the producer;
  - both tests: Quit `.settled`/`completed == .quit`, proxy down (Stop/teardown), custody input released, final files on disk, and
    `observationFailure` (`.wire(.subscriberLimit)` in one, `.streamClosed(.resyncRequired)` in the other).
- **Cleanup on every path:**
  - the helper's catch path releases both holds, then cancels and joins the task;
  - the per-test `defer` releases both holds;
  - `addTeardownBlock` (registered right after the Task) releases both, cancels and awaits. It runs before `tearDown()`/`harness.tearDown()`.
  - Every wait is bounded: `waitUntilReached(within: 10 s)`, `eventually` (about 10 s), and the routine's own 10 s deadline.
- The real-clock held-teardown test and the expired-budget test are unchanged.

## Limitations (non-blocking)

1. The held save's step is now always `.unsettled`, so its receipt is no longer asserted; only the on-disk file is. A cheap optional
   addition: assert `composition.service.operationLookup(...)` is `.finished(... .persisted ...)` after the end condition, as
   the revoked-save test does at line 1193.
2. Pre-existing, not introduced here: an `XCTUnwrap` throw after the prior update's read is parked, but before the `defer` is registered (the
   `XCTUnwrap` lines 1478 and 1481–1482), leaves that PlatformWork read held. `harness.tearDown()` does not `releaseAll` the injected
   `HeldStateFileRead`. In practice this is unreachable, because the baselines exist.
3. Author assumptions 1 and 2 were checked by reading only. They fail safe, as above.
4. `HeldCall` lets a matching call on the cooperative pool through instead of holding it. Store steps run on PlatformWork, so the hold applies
   here, but this test does not assert `takenOnCooperativePool`.
5. Compile, Swift 6 isolation of the `sleep:` closure literal, TSan, stress and the skip-final-read mutation are the parent's to confirm.
