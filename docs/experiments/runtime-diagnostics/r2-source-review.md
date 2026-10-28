**Verdict: source accepted. No actionable findings in Source, tests or the experiment.** I reviewed only the immutable r2 snapshot and made no edits or runs (no builds, Bash, network or Git), so I haven't verified the SHAs. Source acceptance is separate from full41, the full workflow, native acceptance and Release.

## The P2 fix is structurally sound
- **The change:** `RotatingLogFile.swift:184-199` now enqueues `queue.async { drainPending() }` inside `admission.withLockedValue`, on the branch that sets `draining` and enters the group.
- **Why that closes the race:** `close()` sets its latch under that same lock (`:220`) before `queue.sync` (`:221`). So any admission that queued a drain block did so before the latch, and the serial queue runs that block ahead of close's join.
- **Records admitted while a drain is already running** need no new block. That running loop is already ahead of the join, it can't receive anything new after the latch, and it loops until pending is empty.
- **No new hazard under the lock:** enqueueing runs no callback, and the block only takes the lock later, on the queue. The reentrant failure path is safe: the store logs back into the same writer from inside `drainPending`, where `draining` is true, so nothing is enqueued.
- **Nothing else moved:** `close()` is unchanged, and there's no new queue, capacity, registry or retirement path. The Source diff matches the manifest; only this file's hunk changed (+2 lines).

## Tests
- **Retained concurrent test** (`testConcurrentWritesAndCloseAccountForEveryRecord`, patch `:1909-1961`): the custody assertions are the right invariants:
  - pending is 0 when close returns;
  - failed is 0 afterwards;
  - nothing is written after close;
  - written + dropped equals attempts;
  - dropped is at least the 400 writes made after close;
  - the file's line count equals written.

  Its label is honest: it is not a deterministic regression for the original microsecond-wide race. Its sensitivity rests on the widened 20 ms control, which failed with a positive fact (pending 314, late failed 314, accounting short by 314). The two earlier passes are correctly kept as non-witnesses. A fast machine stays well under the 1 MiB rotation threshold: the control run made about 5.3k attempts at roughly 25 bytes each, against about 40k lines needed.
- **Control-owner held drain** (patch `:2113-2212`):
  - `DrainEntryWitness` forwards `minLevel`, `statistics`, `logImpl`, `flush` and `drain` to the real `AppLogStore`.
  - The test acts only after the drain has been entered. It asserts no drain has returned and no synchronous flush happened, and keeps the bound at `writerWait` (2 s, not weakened).
  - The old blocking line was put back temporarily as a control. The test failed at the unwrap because the drain was never entered, with one synchronous flush recorded. That makes this a causal witness, not a timing proxy.
  - The `defer` release covers every exit; the extra semaphore signal at the end is harmless.
- **Ready file** (`testTheReadyFileHoldsTheReadinessStatus`): it now claims only the file's content. `executableName` is the constant at `RuntimeHost.swift:654`, and the doc states that ordering rests on `markReady` awaiting the write.
- **Timer coverage:** the `RecordDrainWaiterTests` and `SnapshotArtifactWriterTests` cases are now in the focused filter rather than duplicated. That's correct.
- **No leftovers:** no `TEMP-CONTROL` text and no `logger.flush(timeout:` remain in Sources or Tests. `RuntimeHost.swift:1003` is `report.logger = await drainLogger(until: cap)`, and `drainLogger` (`:1009-1020`) matches r1. The only matches are inside the experiment (`Probe.swift:2760` is the post-release flush) and the unrelated existing `HelperClientDeadlineTests.swift:352`.

## Prior clarification still holds
`RuntimeHostLifecycle`, `RuntimeQuitFlush`, `RuntimeClientQuit` and `AppState`'s Quit are unchanged. The caller's 10 s wait is bounded, host custody after expiry is the documented behaviour, and the one-slot retired-timer `busy` is covered compositionally.

## Experiment (not compiled or run; no figures accepted)
- **Default run intact:** `run.py` `MODES` is unchanged, which with `TRIALS` gives the default 31 runs. The logger modes are only accepted through `--modes`, three trials each. `Probe.swift:4137-4139` strips `-nosampler` and accepts `logger-held` through `latencyModes`.
- **No bypass:**
  - The real host, framed clients, scratch root and fakes are used.
  - Every destination admission goes through the authoritative `diagnosticDestinationGuard(.appLog, …, writerLeaseFile:)`. The hold only adds a wait, with a 60 s safety bound whose expiry fails the mode.
  - Gate refusals are checked to be empty.
- **Positive witnesses:**
  - the hold was reached exactly once;
  - the host entered its drain;
  - measurements were taken while the drain was still in flight;
  - the Stop physically completed (listener closed, fake proxy cleared);
  - `report.logger` is `timedOut` and kept separate from `allConfirmed`;
  - after release, nothing was dropped or failed;
  - the typed `timed_out` host fact was persisted exactly once.
- **Interpretation:** the 2 s drain wait is reported as deliberate, separately from latency, and stage memory is labelled as whole-probe, not app RAM.
- **Cleanup:** the hold is released first on both the error path and `release()`. The writer is closed before the scratch root is removed. Output stays within the label whitelist that `run.py` audits.

## Material proof limits
- The P2 regression proof is structural plus a widened-window control. The retained test is a stress invariant, not a deterministic reproducer.
- **The probe's logger is a probe-local `ProbeFileLogger`, not `AppLogStore`** (the probe can't link the app target). It has no counter folding, no console or `os_log` output and no UI hand-off. Its `statistics` reset when the writer is swapped. Release figures from it measure the host plus the kernel file writer, not the app store's costs.
- **Two probe checks can fail spuriously if the host logs during the narrow windows; they cannot pass falsely:**
  - `logger.firstWriterWroteEveryLine`: a line handed during the swap in `freshWriter` is dropped.
  - `logger.fileHoldsTheWrittenBytes`: the counters and the file size are read non-atomically.

  If either fails, check for concurrent logging before calling it loss.
- **Still to come:** the r2 full workflow, the Release probe execution, AppKit native terminate-later timing, real-helper teardown and shipping resource measurements.