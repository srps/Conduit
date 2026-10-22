# 0003: Thin AppState harness over FakeMachine

- Date: 2026-09-05
- Decision: accepted (owner, 2026-09-05, #16)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

`AppState`'s lifecycle composition (start and stop, ownership guards, termination cleanup, the failed-start revert, VPN handling) ran only in the app, and four of the bugs fixed in #14 and #15 lived there. It had no harness (#16).

## Decision

- `AppState` takes its platform seams as optional parameters with production defaults: runtime environment, privilege client, command runner, home directory, resolver directory and login-item manager.
- No `Dependencies` struct and no protocol per manager. The roadmap moved listener and platform ownership into the daemon before 1.0, so the parameters were meant to be cheap to delete.
- Scenarios run a real orchestrator over `FakeMachine` on ephemeral ports and assert on the machine and the journal file, never on `AppState` internals, so they port to `DaemonRuntimeHost`.
- A lifecycle rule added to one host lands in the other. Where the daemon cannot express it yet, its twin scenario is a strict `XCTExpectFailure` naming what the migration still has to bring over.

## Alternatives

A `Dependencies` type with a protocol per manager. It would be a larger seam to build and later remove, for a runtime that was expected to leave `AppState`.

## Consequences

- Lifecycle bugs in `AppState` can be reproduced headless, and the `--dev` instance (#24) reuses the same composition.
- The premise that the in-process runtime is about to disappear changed with [0001](0001-one-runtime-host.md) on 2026-10-21. The harness rule still holds.
- A default seam can leak to the real machine. Six daemon-host tests left out the home directory and command runner, and a local `swift test` stripped the developer's shell environment block and launchd proxy variables (#189). Since #190, `AppState` and `DaemonRuntimeHost` take `homeDirectory` and `commandRunner` without defaults, so a test that leaves them out does not compile.

## Invariants and verification

- Harness scenarios assert on `FakeMachine` and the journal, not on `AppState` state.
- No test touches the real system proxy, login Keychain or installed helper through these seams.

## Implementation evidence

- [`AppStateHarnessTests`](../../Tests/ConduitTests/AppStateHarnessTests.swift) and [`DaemonRuntimeHostTests`](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift) run both hosts over one [`FakeMachine`](../../Sources/PlatformMac/PlatformFakes.swift).
- The rules live in [`Sources/Conduit/AGENTS.md`](../../Sources/Conduit/AGENTS.md) and [`Sources/ConduitDaemon/AGENTS.md`](../../Sources/ConduitDaemon/AGENTS.md).

Does not prove: that `FakeMachine` answers like a real Mac. Notification and network-path integrations stay real in the harness.

## Open questions

None.
