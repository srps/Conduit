**Verdict: accepted once one test-only fix is made.** The new driver fixes the hang without missed wakes, lock inversions or polling. One new test can still hang on a regression instead of failing; that needs a guard and a reordering, not a timeout. Everything else is a limit to document. I checked the four snapshot files and the patch against `manifest.json`: the production module diff is empty, so f3 is unchanged.

## Required fix

**`RuntimeManualSchedulerTests.testACancelledDriverEndsItsWaitingCallAsCancelled` must fail rather than hang.**
- **The problem:** it runs `page.cancel()`, then `await page.result`, and only then `held.open()`. If either the driver's cancel propagation or the product's handling of a cancelled parked page regresses, the call never ends. The driver then stays parked in a checked continuation, and `page.result` never returns. That is the same kind of hang that stalled the full workflow.
- **The fix, using the pattern test 1 already has, with no timeout or retry:**
  1. After `await held.untilHeld()`, add `guard harness.scheduling.hasWaitingDriver else { held.open(); return XCTFail(...) }`.
  2. Then `page.cancel()`, then `held.open()`, then `let result = await page.result`.
- **Why it stays deterministic when everything works:**
  - `page.cancel()` synchronously runs the driver's cancellation handler, which cancels the call. That synchronously runs the transport gate's handler, which marks the wait `.cancelled`; the first outcome wins.
  - The test doesn't suspend between the cancel and the open, so the job's commit hop can't run before that.
  - So the result is still `.notSent(.cancelled)`.
- **What a regression now produces:**
  - An old-style polling helper fails at the guard.
  - A helper without its cancel handler, or a product whose cancellation doesn't detach the page, gets the commit hop driven and answers with rows. The existing "a cancelled page is not answered" assertion then fails.
- **What can still hang:** only a genuine product hang, where the call neither ends on cancel nor completes after the commit. Any test would hang on that.

## Checked and correct

- **No missed wake:** `untilHopQueued` checks the queue and `ended` and registers its continuation in a single locked step. Both `hop()` and `wakeDriver()` take that same lock before resuming. The call's `defer` sets `ended` before calling `wakeDriver()`. If `ended` flips between the driver's check and its registration, the later `wakeDriver()` still finds the registered continuation.
- **Lock order:** the only nesting is the scheduler lock, then the `ended` box lock, through the `ended()` closure. The `defer` takes the box lock and releases it before taking the scheduler lock. `hop()` never touches the box. So no inversion.
- **One driver at a time:** every current `runCall`/`runDrainingCall` caller awaits its call before starting another, and each new test has one driver per harness. So the `precondition` can't fire in the current suite.
- **Hop cap:** `ran` accumulates across loop passes through `drainAll(limit: limit - ran)`, and the guard comes before a drain. So there is no unbounded loop and no busy spin: an empty queue re-registers and suspends.
- **Cancellation:** the driver's cancel handler cancels the unstructured call task, which doesn't inherit cancellation by itself. The handler also fires if the driver is cancelled before it reaches the handler.
- **No false waiting-driver result in test 1:** the driver registers in the same RuntimeActor turn as its drain. The test can only resume after the driver suspends, so the `hasWaitingDriver` check can't be falsely negative.
- **Test 1's causality:** no hops are pending while the job is held. The driver is suspended without polling, and the late commit hop raises `queuedHopCount`. The page answers two current rows, and nothing is left queued.
- **Driver starvation:** the driver no longer yields-polls, so the low-priority projection job gets a thread. That was the root cause of the stall.
- **`readHosts`:** only a `RuntimeClientError` becomes `.failure`. `ManualDriveExhausted`, `CancellationError` and fixture errors now surface as themselves instead of being turned into `.unexpectedReply`. The five assertions are unchanged.
- **Failed control:** the 2HrEh6 log shows the single expected `XCTAssertTrue` failure at the temporary test's line 76 ("the late commit hop is run by the driver"), ending in 1.8 s without hanging. The other 14 fairness tests pass. The control witnesses the defect, not the final test's exact assertion, since the final test uses API the old fixture lacks. Say so in the record.
- **Compatibility patch:** unchanged; it only renames `Self.` to the concrete class.

## Limits to document (not required fixes)

1. **`runCall` drains only once.** After its first wait it drains once and awaits `call.value`. A call that needs a hop queued later from outside the owner still hangs; that's its contract. As before, it also assumes it starts with an empty queue. A leftover hop makes the first wait return immediately, and the drain can run before the new call has queued its own hop. The old `awaitState` behaved the same way, and no current test leaves hops queued before a `runCall`. Write this assumption into the doc comment.
2. **`harness.page()` still polls** (4 rounds of up to 10,000 yields; used at `RuntimeCollectionLedgerTests.swift:285`). It can't hang, but it can fail spuriously if the low-priority job doesn't queue its hop in time. A yielding RuntimeActor task can starve that job, especially on a one-thread pool. If the expanded 72-test strict run includes that test, its result is the evidence. Otherwise track it as a follow-up. Don't replace it with an unbounded wait, which would trade a spurious failure for a hang.
3. **The `ended` closure must not take the scheduler lock.** `NSLock` isn't recursive, so a future caller passing, e.g., `{ scheduling.pendingCount > 0 }` would deadlock. Add a one-line doc note.
4. **Late cleanup:** after `ManualDriveExhausted` or a cancel, the call or projection job can outlive the test and queue a hop on its own, now-discarded harness. Each harness is separate, so this can't affect other tests.
5. **Using two drivers on one harness** now crashes the test process through the `precondition` instead of hanging. That's acceptable as a misuse guard, and it's loud.
6. **Strict runs:** the new tests aren't in the strict filter, and the author didn't run strict. That is covered by your expanded strict-72 run and the full workflow, not by this review.

After the required fix, I'd accept this fixture for the full workflow. Production Source f3 stays unchanged and accepted.