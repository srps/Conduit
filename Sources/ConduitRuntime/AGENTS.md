# ConduitRuntime

The shared runtime host, `RuntimeHost` (decision 0031, carrying forward 0013). `ConduitDaemon` and the app compose it. The app holds framed clients rather than live runtime collaborators. RuntimeHost shares RuntimeActor with the whole control-owner cluster (0031); UI and client presentation remain MainActor, and blocking effects stay on the injected physical workers. The global actor supplies isolation only; each host owns its resources explicitly.

- Runtime lifecycle/store policy has one implementation here. Add actual-host/client tests over explicitly injected `FakeMachine` effects and a meaningful `pm-sim` witness for new behavior. App tests cover the thin client and UI composition; do not duplicate runtime policy there.
- The host never exits the process. A terminal stop calls the `terminalExit` the entry point injected. `ConduitDaemon` passes `exit(0)`, and tests pass a hook they can observe.
- The host is built from a `StateRootSession` (decision 0028), which carries the root's lease and resolved paths. It has no initializer that takes a raw `RuntimeEnvironment`, so every writer the host owns is under the lease.
- The reported process start comes through `init` (`startedAt`), rather than an executable global. Existing process metadata reads are unchanged.
- Machine effects go through `PlatformMac` protocols, including `NetworkPathObserving`. This target imports no `Network`, AppKit or SwiftUI.
- `Conduit`, `ConduitDaemon`, the test target and `pm-sim` may depend on this target. `pm-sim` is limited to headless actual-host scenarios with explicitly injected effects and owned scratch state (decision 0033); it may not use production adapter defaults. `ConduitUpdater` must not gain a dependency on it.
- Members are internal for `@testable` tests. Mark a member `package` only when app/daemon production composition needs it, a package protocol requires matching conformance access, or the production lifecycle/reload facade is required by the scoped `pm-sim` scenarios (0033). Store/workflow internals remain internal; add no public test hooks.
