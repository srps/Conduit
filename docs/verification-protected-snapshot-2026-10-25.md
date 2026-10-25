# Protected snapshot diagnostics: verification note (2026-10-25)

Status: frozen local source checkpoint on `codex/protected-runtime-artifacts`, all 39 local workflow checks passed, before hosted PR checks. Not released. The source/test/script/resource fingerprint is `386563164e1b4e9f063d9d4209f27a8fd9896a49d07f1d1e35b36cb6dd073aec`; documentation is excluded. The serving app and helper were not changed.

## What this covers

This is the carried-forward diagnostic protection that [0020](decisions/0020-canonical-runtime-writer-root.md) and [0028](decisions/0028-fixed-writable-state-filenames.md) require of `snapshot.json`. A configuration that is the snapshot destination, or an alias of it, keeps its bytes. The refusal latches once. The runtime keeps serving and does not reject startup.

It does not implement fixed writable names. Startup naming enforcement is still planned. Both decisions keep their existing statuses: 0020 is superseded, and 0028 is `planned`.

Rotating app logs remain unfinished under [#233](https://github.com/srps/Conduit/issues/233). Existing audit/events destination protection came from PR226; this slice reuses its guard and changes their drain reporting without claiming a new complete log-protection proof.

## Implementation

- `Sources/ProxyKernel/Support/SnapshotArtifactWriter.swift`: the writer, its protocol and factory, the statistics, and the flush outcome.
- `Sources/ProxyKernel/Support/RecordDrainWaiter.swift`: the shared, non-blocking drain waiter.
- `Sources/ProxyKernel/Support/DiagnosticFlush.swift`: the single diagnostic phase, with one absolute 6 s deadline and at most one events confirmation beyond the first events wait.
- `Sources/ProxyKernel/Abstractions/RecordFileDestinationGuard.swift`: `RecordFileDiagnosticSink.snapshot` and `RecordFileDestinationGate.perform`.
- `Sources/ProxyControlBridge/ProxyControlBridgeProtectedDiagnosticResources.swift`: the snapshot writer excludes only its own resource.
- RuntimeHost and pm-proxy submit snapshots. Readiness and process-exit boundaries await the phase, including the explicit flush after the daemon's nonterminal stop in `--exit-after-ready --start-runtime`.

## Bounds

- Steady state holds one value being written and one pending. A superseded pending value is released after the lock, so up to three values can be alive for a moment. This is not a size bound. No raw or encoded size ceiling is selected. Encoded sizes are measured (`lastEncodedBytes`, `maxEncodedBytes`).
- Generations never wrap. At the last one the writer closes with `generation_exhausted`.
- A latched refusal skips encoding. Later attempts are counted as refused, and the gate emits its event once.
- One reservation at a time in the waiter: one notify and one timer. It is released only when both acknowledge.
- The phase budget is 6 s, with a 2 s cap per wait. There is one events confirmation beyond the first events wait, spent early or after a late snapshot event, never both.
- Ordinary `startRuntime`, `reloadConfiguration` and ordinary `stopRuntime` submit the snapshot and continue. They do not wait on the diagnostic phase. Readiness and process-exit boundaries await it, including the daemon's explicit flush after the nonterminal stop on the exit-after-ready path.

## Test and check results

The exact wrapper `bash /private/tmp/conduit-runtime-stage1-20261024/verify-protected-artifacts.sh` passed. It ran 141 focused tests, zero failures; kernel imports, event catalogue and decision checks; `pm-sim bounded-writers`; and the dedicated `pm-sim protected-snapshot-artifacts` scenario with ten structured assertions. Earlier counts were superseded. This is focused evidence, not all workflow gates.

The parent reran the same wrapper after adding the shared marker's derived warning log: 141 tests and both scenarios still pass. The zero-budget test checks that warning through the recording sink.

The tests include actual `fcntl(F_GETFD)` verification of `FD_CLOEXEC`, held timer-body cleanup and caller completion, cancellation before/after registration, lifetime release, refused/failed/dropped-output confirmation, cleanup latching through an injected file-effect seam, and real scratch path/identity guards. FakeMachine host tests cover the final-stop/explicit-flush sequence used by the daemon entry point and a deferred older snapshot notification. The real `ConduitDaemon --start-runtime` was never launched.

The parent ran the actual built `pm-proxy` in four owned scratch cases. Direct-path, symlink and hardlink configuration collisions all kept the original bytes, emitted one refusal and exited zero. The normal destination wrote a valid final stopped snapshot (873 bytes in this empty-workload fixture) with no refusal; this size is a measured point, not a maximum. Binary SHA-256 `cafe8674d4aba6f93f1ac9087d887cd1340efb78ab9e2a743d8759b484099ed3` was unchanged through the run. Local results: `/private/tmp/pm-snap-guard-9ry28xss/result.json`; the earlier initial witness is separate. No VPN, serving app, helper or machine setting was used or changed.

The timer uses `Task.sleep(until:clock:)` with the continuous clock. Apple documents that [ContinuousClock progresses through system sleep](https://developer.apple.com/documentation/swift/continuousclock/continuous), while [DispatchTime uptime excludes sleep](https://developer.apple.com/documentation/dispatch/dispatchtime). The former dispatch-timer conversion did not preserve that deadline meaning. No real system-sleep experiment was performed; the machine was never put to sleep for this test.


## Full workflow checkpoint

The parent ran all 39 checks corresponding to `.github/workflows/swift.yml` on source commit
`f6487113b1dc7e437ffc120421a9abb243809107`. All passed. The source fingerprint above
was identical before and after the run; only documentation changed afterwards.

- Full XCTest: 3,037 tests, two skipped, zero failures.
- `pm-sim all`: all 97 structured result records passed, including the dedicated protected-snapshot scenario.
- Import, event, decisions/history and regression checks, notices, packaging, signing identity, signed/unsigned updater,
  Kerberos-worker, security/redaction, routing/wire, DNS-shutdown and status-stream checks passed.
- Existing proxy performance gate: wall 10.235 s, maximum RSS 34,799,616 bytes, CPU 105.16%.
  This is that proxy workload, not the client service, the maximum configuration or a whole-app RAM bound.

Logs: `/private/tmp/conduit-runtime-stage1-20261024/protected-artifact-full-gates/`.
Independent subscription-backed Claude source review found and prompted fixes for exit-after-ready flushing,
false drain confirmation, sleep-clock semantics, cleanup accumulation and stale snapshot notification.
A final scoped static recheck found no further actionable findings. It did not execute tests.
Hosted Swift/CodeQL and actual PR review results remain separate checks.

## Not proved

- Startup naming enforcement. [0028](decisions/0028-fixed-writable-state-filenames.md) remains planned.
- Power-loss durability, readback, or that a successful queue drain proves every record persisted after a physical write failure. Queue statistics are separate from physical outcome.
- Confirmation after a recorded loss. A drained queue is only a queue fact. A confirmation requires the writer's drop and failure counters to be zero, including history from before the phase. A loss earlier in the process keeps later confirmations unconfirmed. That conservatism is accepted and documented.
- Cleanup beyond the writer's lifetime. A writer latches after an orphaned temporary or an uncertain close and creates no further temporary files. This does not bound leftovers across crashes or relaunches.
- Physical cancellation of a write in progress, readback, or durability after power loss. A failed write reports its stage and errno, and a failed cleanup reports `leftTemporary`. Those are the only write, close and unlink facts claimed.
- Protection against a non-cooperating process that retargets a path between the guard's check and the rename.
- The whole-shutdown bound, which stays with [#47](https://github.com/srps/Conduit/issues/47). The logger's own 2 s flush still blocks the caller.
- AppState/RuntimeHost convergence and the app rotating-log path. The app has no separate snapshot-file writer; its DevLaunch path inventory is not a snapshot output.
- Real-machine behaviour on the owner's deployment storage.
