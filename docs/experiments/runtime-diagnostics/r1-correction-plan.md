# r1 correction plan (production frozen until release; nothing applied)

## P2: admitted write lost across close (RotatingLogFile)

**Change, one line moved.** In `RotatingLogFile.write`, call `queue.async { [self] in drainPending() }` inside the
`admission.withLockedValue` closure, on the branch that sets `draining = true` and enters the group, instead of after the lock. That
call only enqueues. No callback, I/O or publication happens under the lock. The drain block takes the lock itself, later, on the queue.
`close()` sets `closed` under the same lock and then calls `queue.sync`. So every record admitted before the latch has its drain block
queued ahead of close's sync block, by FIFO on the one serial queue. That makes both docs true structurally:
- `close()`'s "admitted writes are still written";
- `AppLogStore`'s "the queue is empty once close returns".

There is no new queue, capacity, registry or retirement path. Trim the `schedule` return.

**Witnesses.**
1. **Retained concurrent custody test** in `RotatingLogFileProtectionTests`, with no hook:
   - several writer threads each write K fixed lines;
   - main closes the writer mid-burst; then all threads are joined.
   - Assert, right after `close()` returns: `pendingRecords == 0`.
   - After the join: `failedRecords == 0`, `written + dropped == threads × K`, `pendingRecords == 0`, and the file's line count is
     `written`.

   This is a stress assertion and does not deterministically reproduce the race window on the old code; I'll say so in its doc.
2. **Isolated instrumented baseline, not retained:**
   1. In the release window, temporarily add a `usleep(1_000)` between the unlock and the old out-of-lock `queue.async`.
   2. Run only that test. Expect it to fail: pending > 0 at close return, or written + dropped < total.
   3. Keep the log, revert the instrumentation, and apply the fix.
   4. The same test passes.

   This shows the custody assertion discriminates. The structural lock argument is the proof.
3. The existing close test stays as it is (a write held in storage across close).

## P3a: held host-drain test phase (RuntimeHostControlOwnerTests)

Replace the 200 ms sleep with a test-local forwarding `LogSink` around the real `AppLogStore`, in the test file only:
- it forwards `logImpl`, `minLevel` and `statistics`;
- `flush(timeout:)` records that it was entered, then forwards;
- `drain(until:)` records its entry instant, then forwards.

The test waits, bounded, for the drain entry. Then it drives the framed status read and Stop admission, and asserts:
- both were answered before `drainEntered + DiagnosticFlushPhase.writerWait`. The 2 s bound is not weakened;
- the drain had still not returned at that point;
- `report.logger == .timedOut`;
- the typed host fact, and the Stop settling.

**Control.** In the release window, temporarily restore the old `logger.flush(timeout: 2)` in `flushEvents` and run that one test.
Expected result:
- the drain is never entered (the witness records only `flush`), so the bounded wait fails;
- the status read lands only after the blocking flush, so the window assertion fails too.

Keep the log, then revert. If the control's failure mode differs, I report it as it was.

## P3b: ready-file test (DaemonRuntimeHostTests)

There is no cheap decisive ordering seam: the snapshot writer's guard and `platformWork` are not injectable from the daemon harness,
and adding one only for this would be a hook. So I'll rename the test to `testTheReadyFileHoldsTheReadinessStatus`, keep the
decode/`processID` assertions, add `executableName == "ConduitDaemon"`, and drop the mtime `<=` claim. The ordering rests on the
`await writeReadyFile()` before `writeSnapshotFile`, a structural proof the review accepted.

## P3c: single timer slot `busy`, already covered; I'm adding no duplicate

- `RecordDrainWaiterTests.testDrainedCallerReturnsWhileAHeldTimerBodyKeepsCapacityBusyUntilItEnds` (`:153`): a drained caller's retired
  timer body makes the next wait `busy` until it ends. This is the exact single-slot case.
- `RecordDrainWaiterTests.testCancelAfterRegistrationKeepsNotifyHeldThenReturnsBusyUntilCleanup` (`:83`).
- `SnapshotArtifactWriterTests.testTimedOutWaitIsBusyUntilPhysicalCleanupFrees` (`:185`).
- `RotatingLogFileProtectionTests.testAHeldFileDropsExactly…`: the timed-out notify gives `busy`.
- The app-level held tail records `busy` after the host's timed-out wait.

Neither `RecordDrainWaiterTests` nor `SnapshotArtifactWriterTests` is in the wrapper filter; the parent may add them to the focused run.
In production, a transient `busy` after a drained wait becomes `log_flush_unconfirmed busy`. That is honest under the selected
single-slot custody, and nothing retries.

## Noted, not changed

The artifact phase keeps its own 6 s `DiagnosticFlushPhase` inside the quit's 10 s. It predates this change and falls under decision
0039. The logger drain is cut to the quit deadline. The app tail is cut to the app's same deadline, so the app's total stays bounded
by its 10 s whatever the artifact phase spends. No Quit refactor.

## After release

1. Apply P2, P3a and P3b, with their temporary baseline/control runs.
2. Run the fixed wrapper, plus `RecordDrainWaiterTests`/`SnapshotArtifactWriterTests` if the parent adds them.
3. Freeze Source, update the manifest, and hand over for full41 and independent re-review.
