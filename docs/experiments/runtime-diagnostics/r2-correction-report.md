The r1 corrections are in and the focused wrapper is green: run `runtime-actor-prep-focused-QVlsTD` exited 0 with 568 tests and 0 failures, now including `RecordDrainWaiterTests` and `SnapshotArtifactWriterTests`. All three sims passed, as did the checks and `git diff --check`. Source is frozen again, and the marker file is empty, so the default run is restored. The manifest is at `/private/tmp/conduit-runtime-stage1-20261024/runtime-diagnostic-r1-correction-manifest.json`.

**P2: lost write across close**
- **Fix:** in `RotatingLogFile.write`, `queue.async { drainPending() }` now runs inside the admission lock. It only enqueues; nothing is called back or written under the lock. That puts every accepted record's drain ahead of `close()` on the one serial queue. No other Source changed.
- **Retained test:** `testConcurrentWritesAndCloseAccountForEveryRecord`. Eight paced writer threads run while main closes the writer, and each writes 50 more after the close.
  - When `close()` returns, nothing is pending.
  - After the threads finish, nothing failed and nothing was written after the close.
  - Written + dropped equals every attempt, and the file holds exactly the written lines.
- **Temporary control:** the old out-of-lock enqueue with a 20 ms widened gap, plus a stderr line reporting what `close()` left pending.
  - The first two attempts passed with no stderr line. The close kept landing while a drain was already running, so neither run is evidence either way.
  - The test then closes at an observed moment when records are pending but nothing is being written. With that, the control failed exactly as the review described: `pending=314 draining=true` when close returned, those 314 then counted as failed, and written + dropped came to 4,948 of 5,262.
  - Both temporary edits are removed. The fixed code passes in 0.18 s.
- **Limit:** without the widened gap the old race is microseconds wide, so the retained test is a custody check under stress, not a deterministic regression. The proof is the lock ordering.

**P3a: held host-drain test**
- **Witness:** the 200 ms sleep is gone. A test-local forwarding sink around the real `AppLogStore` records synchronous flushes and the moment the host enters its drain.
- **Assertions:** status and Stop must both be answered within 2 s of drain entry, while the drain is still held, with no synchronous flush. The 2 s bound is unchanged.
- **Control:** with the old blocking `logger.flush(timeout: 2)` restored, the test failed because the host never entered the drain and the witness saw 1 synchronous flush (14.2 s run). After restoring the production line it passes in 2.1 s, and that line is identical to before.

**P3b: ready-file test**
- Renamed to `testTheReadyFileHoldsTheReadinessStatus`.
- The unsupported modification-time ordering claim is gone; the doc now says the order rests on the `await`, not on anything the test observes.
- It asserts the file decodes, plus `processID` and `executableName == "ConduitDaemon"`.

**P3c:** single-slot `busy` is already covered by the cited `RecordDrainWaiterTests` and `SnapshotArtifactWriterTests` cases, both of which passed in this run. I added no duplicate.

This round changed `RotatingLogFile.swift` (the fix only), `RotatingLogFileProtectionTests`, `RuntimeHostControlOwnerTests` and `DaemonRuntimeHostTests`. No `TEMP-CONTROL`, temporary `usleep` or blocking flush remains in Sources or Tests. The `logger-held` probe experiment is written but not yet compiled or run.

Next is your r2 full workflow and the independent re-review; after that, the Release probe with `--modes logger-held logger-held-nosampler`.