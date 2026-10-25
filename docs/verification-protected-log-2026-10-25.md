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
