# Verification: protected app log (issue #233), 2026-10-25

Scope: the app's file log writer moved to `ProxyKernel`, with the guard, the `log` sink, the IO transition events, the shared event log, the weak store forwarder, and the state-root lease URL. This is a focused slice, not the full workflow. The parent runs the full `swift.yml` and `pm-sim all` after the source freeze.

## Parent's original proof (executed before this slice)

`actual-log-collision-probe/main.swift` compiled the original archive writer in a scratch harness. Its output, `before-result.txt`, shows the four collisions corrupt the protected config: `active-symlink`, `active-hardlink`, `archive1-target` and `archive2-target` (`confirmed_collisions=4/4`). Original source SHA256 `bcaa55e19d4e701bf53020dbce3bd9edde2641da32be2c89ccea29e2d21c898c`. Probe SHA256 `4de7f3f9403d8f6f3e36477c8891131cbaf476ca9bdcd3096d291a5d235ddb9b`. That was the physical writer only, not the app composition.

## Focused wrapper run (passed)

`bash /private/tmp/conduit-runtime-stage1-20261024/verify-log-protection.sh`, exit 0 on the final run.

- `swift build`: complete.
- `swift test --filter 'RotatingLogFile|LoggingTests|DiagnosticDestination|DiagnosticWriterLease|AppStateHarness|DaemonRuntimeHost|RecordFileDestination|BoundedRecordWriter'`: 235 tests, 0 failures.
- `check-kernel-imports.py`: passed (107 Swift files).
- `check-event-catalogue.py`: passed (217 event names; `docs/events.md` matches product sources).
- `check-decisions.py --require-history` and `test-decisions.py`: passed; the decisions fixtures pass 4 variants and reject 49 mutations.
- `pm-sim protected-app-log`: PASS, 15 assertions.
- `pm-sim diagnostic-destinations` (the wrapper's name for `diagnostic-destination-guard`): PASS, 9 checks.
- `pm-sim protected-snapshot-artifacts`: PASS.

## Failed runs before the final pass

1. The first wrapper run (`b8gy7etj2`) built, then failed to compile `Tests/ConduitTests/RotatingLogFileProtectionTests.swift:279`. `details.first` was a `String??` compared to `String?`. The fix was `compactMap` before the prefix check. This was a test-only fix. Its logs were overwritten by the next run.
2. I started an extra, unintended wrapper invocation after that failure. It exited 1 before the fix, so it reproduced the same compile failure. I didn't run it deliberately, and I should not have.
3. The next run (`b24sr53ky`) passed after the fix.

## New tests

- `RotatingLogFileProtectionTests` (13 tests): the four collisions, the latch with no further admit calls, event-first publication, the active directory and archive directory refusals, a FIFO refusal (no reader, nonblocking open, so it cannot hang), a symlink to an admitted file, descriptor flags (`O_APPEND`, `O_NONBLOCK`, `O_CLOEXEC`), a single failed close with no reopen, and store release.
- `DiagnosticWriterLeaseProtectionTests` (2 tests): an adopted guard refuses a lock alias and the lock keeps its bytes; a non-adopting composer does not protect the lock.
- `DiagnosticDestinationGuardTests`: the `.appLog` exclusion set and its admit behaviour.
- `RotatingLogFileTests`, `LoggingTests`: updated to the new constructors. Existing append, reopen, archive and oversized-line expectations are unchanged.
- `AppStateHarnessTests.testAnAppLogAliasOfTheConfigIsRefusedThroughTheCompositionEventLog`: a real `AppState` with a hardlinked log path refuses the write, and the refusal lands in `state.eventLog`.

## Counts and limits

- Source files changed or added: `ProxyKernel/Support/RotatingLogFile.swift` (new, the one archive implementation), `RecordFileDestinationGuard.swift` (the `appLog` sink), `ProxyControlBridgeProtectedDiagnosticResources.swift`, `AppLogStore.swift`, `AppState.swift`, `StateRootSession.swift`, `RuntimeHost.swift`, `pm-sim/ProtectedLogScenarios.swift` (new), `pm-sim/Main.swift`.
- Test files changed or added: `RotatingLogFileTests.swift`, `LoggingTests.swift`, `RotatingLogFileProtectionTests.swift` (new), `DiagnosticDestinationGuardTests.swift`, `AppStateHarnessTests.swift`, `DiagnosticWriterLeaseProtectionTests.swift` (new).
- Docs: `docs/events.md`, `docs/design-protected-runtime-artifacts.md`, this note.
- The old `Sources/Conduit/App/RotatingLogFile.swift` was reduced to a placeholder by me and then removed by the parent. It is not recreated.

Not proved by this run:

- The #47 pending-write queue remains unbounded. The main thread still blocks on `queue.sync` flush and close.
- Infinite Settings toggles are not bounded across their lifetime.
- Physical disk IO is not bounded.
- A non-cooperating process that retargets a path between an admit and a write is not excluded.
- Full `swift.yml` and `pm-sim all` are not run here; the parent runs them after the freeze.
- Hosted CI and installed-app behaviour are not verified.


## Independent review and red cleanup witnesses

Independent Claude source review confirmed hidden close errors in abandoned opens
and after an existing IO-failure streak. Its separate recovery-log ownership
finding was withdrawn after tracing the failed-start, pre-host exit path.
No global event-log owner or new persistence path is selected.

A tests-only phase first ran 244 tests with 31 failures: four expected missing
cleanup assertions and 27 newly visible daemon fixture removal failures. That
run included an audit test using reflection; that test was removed to retain
ADR0003's private AppState boundary. Logs are archived at
`/private/tmp/conduit-runtime-stage1-20261024/log-protection-checks-red-first/`.
One failed fixture contained only snapshot.json and was removable with ordinary
permissions after the process ended; this suggested outstanding diagnostic work.
The daemon harness now explicitly owns its host and awaits stop/flush before
releasing authority and removing its directory. This is fixture lifetime work,
not proof of globally bounded production shutdown.

The final tests-only red run compiled successfully and ran **243 tests, four
failures**, all the expected missing close-cleanup assertions; daemon tests ran
57 cases with zero failures and no scratch cleanup errors. Actual app-log and
host events/snapshot/recovery lock-alias assertions pass, including byte/inode
preservation and a second writer remaining busy. Audit composition is source-
reviewed plus guarded-sink coverage; it has no reflected or new testing accessor.
The descriptor-flag witness now inspects fcntl on the actual opened descriptor.
Source SHA256: `8e9155453d2e4b332d2b9e6e16914ab6d258e016c752b236743ff30bb513e7b1`. Logs:
`/private/tmp/conduit-runtime-stage1-20261024/log-protection-checks-red-final/`.
The wrapper stopped at the expected test failure, so later static/simulator
checks did not run. Product source was unchanged in this phase.

## Close-cleanup correction (final run)

Product change, all in owned files:

- `ProxyKernel/Support/RotatingLogFile.swift`: a failed close is never retried and retires the writer. Its errno is captured once and held as one pending fact. Each caller publishes its primary result first, then the fact: an explicit `close()` or a rotation's release publishes `log_file_failed` `stage=close` when no streak is latched, then `observability.log_file_cleanup_unconfirmed` `stage=close code=<errno>`; an abandoned open publishes its validation failure, then the fact; a guard refusal at the opened descriptor publishes the one gate refusal, then the fact; a writer released with its descriptor open publishes the fact while an owner of the event log and of the logger still exists; once both are gone, no observer is guaranteed to receive it. The fact is independent of the failure streak, so a close during a streak is reported too.
- The initializer asserts `maxBytes > 0` and `archives >= 1`. The `max(archives, 1)` normalization is removed. Production and fixtures pass only the defaults or positive values.
- `pm-sim/ProtectedLogScenarios.swift`: the 15 behavioural checks run in a body function. The owned UUID root is then removed explicitly, and `scratch root removed` is one more assertion (16 in total). Nothing is removed by `defer`. A body failure and a removal failure are both reported.
- `docs/events.md` has the new catalogue row. The design doc's reporting, close and not-claimed text is rewritten to match the code.
- Daemon harness: a second `makeHost` throws before anything is built.

Failed build before the correction (archived at `log-protection-checks-phase-b-compile-failure`):
`Sources/pm-sim/ProtectedLogScenarios.swift:39:97` passed the `CleanupCode` struct where `Int` was expected. Nothing after the build ran. The fix reads `failure.code` in both places, and the final run below is the first to include it.

Final wrapper run: exit 0, with `set -e` kept. It completed as `bx21wzsh2`, and the output contains `PASS: focused log/writer protection checks` and `[exited with code 0]`. After that run the only change was a comment in `RotatingLogFile.swift`'s `deinit` and matching doc text, which now says the close fact is not guaranteed to reach an observer once both the event-log owner and the logger owner are gone. No code changed. The earlier "Focused wrapper run (passed)" section above is historical and is superseded by this one.

- `swift build`: complete.
- `swift test --filter 'RotatingLogFile|LoggingTests|DiagnosticDestination|DiagnosticWriterLease|AppStateHarness|DaemonRuntimeHost|RecordFileDestination|BoundedRecordWriter'`: **243 tests, 0 failures**. This includes the three close-uncertainty witnesses, which now pass with the cleanup fact asserted, and the DaemonRuntimeHost cases with zero scratch-cleanup errors.
- `check-kernel-imports.py`: passed (107 Swift files).
- `check-event-catalogue.py`: passed (218 event names; `docs/events.md` matches the product sources).
- `check-decisions.py --require-history` and `test-decisions.py`: passed (4 variants, 49 mutations rejected, 5 history changes judged).
- `pm-sim protected-app-log`: PASS, 16 assertions (the original 15 plus `scratch root removed`).
- `pm-sim diagnostic-destination-guard`: PASS, 9 checks.
- `pm-sim protected-snapshot-artifacts`: PASS, 10 assertions.

Logs: `log-protection-checks/` (the live directory for this run; the parent archives it).

Limits, stated exactly:

- The three extra paths that now report cleanup are: an abandoned open whose close fails, a refusal at the opened descriptor whose close fails, and a close during an existing write-failure streak. The healthy explicit-close witness is the only one that existed before, and it still passes.
- Not bounded: the #47 pending-write queue, `queue.sync` flush and close on the main thread, Settings toggles across their lifetime, and physical disk IO.
- The pre-open kind check judges only the path it observes. A path swapped after that check, or a device open that blocks, is not bounded. The guard narrows the retarget window and does not close it.
- The composed audit path is source-reviewed only, through the existing guarded-sink tests. There is no reflected or testing accessor for AppState's private orchestrator.
- Portability: the file still calls `Darwin.open`, `Darwin.write` and `Darwin.close` under a `#if canImport(Darwin)` import. Linux compilation is not claimed and was not checked.
- Full `swift.yml` and `pm-sim all` are not run here; the parent runs them.
- Hosted CI and installed-app behaviour are not verified.
- The source SHA256 was not recomputed in this phase.


## Final scoped source review

Independent Claude review of the frozen corrected source found no blocking
defects in close-uncertainty publication, guard ordering, constructor invariants,
actual composition witnesses or explicit simulator cleanup. This was source
reading, not execution; the parent owns full workflow and native evidence.
The review also narrowed the cleanup claim: the harness-owned daemon cases
reported zero cleanup errors. Standalone historical host fixtures still use
best-effort removal outside that harness, so their quiescence is not established.
AppState harness log draining remains a #47/#118 fixture follow-up; the review
identified a possible late write, not a reproduced new failure.


## Parent final workflow and native handoff finding

All **39** local workflow checks passed on stable relevant-source SHA256
`136c9732c4019f19bf3301ac0e28274ad61f9a61196bcb4e3826579c7a17deb6`,
starting at `e26ead55d038a210de5f730081435da3ad1ec43e`. Full XCTest ran
**3,258 tests, two skipped, zero failures**; all **99 simulator records** passed.
The existing proxy performance gate passed and is not a whole-app/log-queue or
maximum-configuration memory measurement. Logs:
`/private/tmp/conduit-runtime-stage1-20261024/log-protection-full-gates/`.
Subsequent edits are documentation only. Hosted PR checks remain required.

An actual rebuilt ad-hoc native dev bundle was launched with a scratch
log/config hardlink. Configuration bytes and the linked inode stayed intact,
and FakeMachine/preview/DNS window startup logged, but the expected background
warning did not reach captured stderr during the run. This is NOT a successful
native refusal-delivery assertion. The installed serving process stayed intact.

The parent isolated an inherited startup regression from PR #236: calling
SwiftUI/AppKit main from the new async main occupies the main executor. Two
bounded native AppKit probes use identical run loops and three-second global
watchdogs. Synchronous main executes queued dispatch-main and MainActor callbacks;
async main executes neither before its watchdog. The app sample places
NSApplicationMain under ConduitMain's async task. Evidence:
`/private/tmp/conduit-runtime-stage1-20261024/mainloop-probes/` and
`log-protection-native.json`, `log-protection-native-sample.txt` in the same
parent directory. [Issue #237](https://github.com/srps/Conduit/issues/237) tracks
the separate entry-handoff correction and native callback regression. This is a
release blocker, independent of the guarded physical writer. No release-ready
or complete installed-app behavior claim follows from this log checkpoint.
