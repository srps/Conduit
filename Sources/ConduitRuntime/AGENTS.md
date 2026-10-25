# ConduitRuntime

The shared runtime host, `RuntimeHost` (decision 0031, carrying forward 0013). `ConduitDaemon` runs it today. `AppState` still runs its own twin: develop and verify DNS, tunnels and proxy incrementally here, then activate AppState once and delete its replaced runtime/save paths together.

- Twin rule: a lifecycle rule added to one host must also land in the other, until the app adopts `RuntimeHost`. Add the scenario to `Tests/ConduitTests/DaemonRuntimeHostTests.swift` over the same `FakeMachine`. Where the host cannot express it yet, add a strict `XCTExpectFailure` naming what the migration still has to bring over.
- The host never exits the process. A terminal stop calls the `terminalExit` the entry point injected. `ConduitDaemon` passes `exit(0)`, and tests pass a hook they can observe.
- The host is built from a `StateRootSession` (decision 0028), which carries the root's lease and resolved paths. It has no initializer that takes a raw `RuntimeEnvironment`, so every writer the host owns is under the lease.
- The reported process start comes through `init` (`startedAt`), rather than an executable global. Existing process metadata reads are unchanged.
- Machine effects go through `PlatformMac` protocols, including `NetworkPathObserving`. This target imports no `Network`, AppKit or SwiftUI.
- `ConduitDaemon`, the test target and `pm-sim` may depend on this target. `pm-sim` is limited to headless actual-host scenarios with explicitly injected effects and owned scratch state (decision 0033); it may not use production adapter defaults. `ConduitUpdater` must not gain a dependency on it, and neither may the app until it adopts the host.
- Members are internal for `@testable` tests. Mark a member `package` only when `ConduitDaemon` needs it, a package protocol requires matching conformance access, or the production lifecycle/reload facade is required by the scoped `pm-sim` scenarios (0033). Store/workflow internals remain internal; add no public test hooks.
