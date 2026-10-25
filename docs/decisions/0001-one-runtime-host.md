# 0001: One runtime host for the app and the daemon

- Date: 2026-10-21
- Decision: superseded (owner, 2026-10-21, #186 option B)
- Implementation: planned
- Validation: none
- Supersedes: 0004
- Superseded by: 0031

## Context

[0031](0031-incremental-runtime-development-single-activation.md) replaces this
record, preserving its shared-runtime/module/isolation direction while selecting
incremental host development followed by one final AppState activation. The
historical decision and evidence below are retained.

`AppState` is both the SwiftUI model and a complete runtime host. `DaemonRuntimeHost` is a second complete runtime host. Both grew in parallel: on 2026-10-21 they were 2,347 and 1,325 lines, and 26 of the daemon host's 38 function names also exist in `AppState` (#186). Fixes have to land twice (#165), and AppState's runtime half runs on the main actor, which is why #47 exists.

[0004](0004-staged-host-policy-sharing.md) shared policy between the hosts piece by piece. Six weeks on, the in-process runtime is still the production path and the sharing had not kept up with features written twice.

## Decision

Converge AppState's runtime half and `DaemonRuntimeHost` on one host-neutral `RuntimeHost`, in stages (#186):

1. Define the runtime interface AppState needs. It behaves like the wire even in process: every call is async; commands, snapshots and events are `Codable` `ControlProtocol` values; failures are the protocol's stable error codes; state arrives only through bounded, cancellable subscriptions. The default is an in-process host serving `ControlProtocol` over an in-memory transport.
2. Extract `RuntimeHost` from `DaemonRuntimeHost` with no behaviour change.
3. Move AppState's runtime half onto it, one lifecycle at a time (DNS, tunnels, proxy), deleting the AppState copy at each step.
4. Move `RuntimeHost` off the main actor. This closes what is left of #47 and meets #79's acceptance list.
5. Merge the twin fake-machine host suites into one `RuntimeHost` suite plus thin host-specific suites.
6. Later, under ROADMAP Next 3, swap the in-process host for `DaemonClient`.

`AppState` keeps only UI concerns. Host differences (AppKit termination budget, daemon exit, credential-store seam) stay explicit parameters.

## Alternatives

- **A. Keep the current plan** ([0004](0004-staged-host-policy-sharing.md)): cheapest now, but duplication keeps growing and #47 is solved in code that will later be deleted.
- **C. Finish daemon-first first:** cleanest end state, but the largest product change, and daemon Keychain, Kerberos and CFNetwork behaviour is not yet validated ([0002](0002-daemon-first-ownership.md)).

## Consequences

- One host instead of two, so a runtime fix lands once.
- ROADMAP Next 3 becomes a transport swap rather than an AppState rewrite.
- The thin harness rule ([0003](0003-thin-appstate-harness.md)) still holds. Its premise that the in-process runtime is about to disappear no longer does.
- #79's acceptance list becomes the checklist for stages 2 and 3.

## Invariants and verification

- After stage 3, no runtime lifecycle, reconciler or observer code remains in `AppState` or `DaemonRuntimeHost`, apart from host-specific parameters.
- `AppState` reads runtime state only through the snapshot and event interface.
- `swift.yml`, `pm-sim all` and `perf-gate.sh` pass at every stage, with both host suites green until they merge.
- A stage that needs an in-process shortcut around the interface breaks the design.

## Implementation evidence

None yet. Stage 1 comes first.

## Open questions

- Target placement was open in this record and is now settled by [0013](0013-runtime-module-isolation.md): ConduitRuntime owns the host; broad kernel target splitting is not a prerequisite. Client/stream refinements are in [0014](0014-runtime-client-stream.md), persistence policy in [0015](0015-save-before-apply.md).
- Whether the in-memory `ControlProtocol` transport costs too much is settled in stage 1.
