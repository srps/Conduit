# 0002: Daemon-first runtime ownership

- Date: 2026-06-21
- Decision: accepted (owner, 2026-06-21, design document in commit 8bee0bd)
- Implementation: partial
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

The proxy runtime runs inside the SwiftUI app. An AppKit termination, force-quit, update or UI crash tears down the listeners that serve the machine. The privileged helper survives, but it only performs root-only side effects. See [`design-daemon-first-control-plane.md`](../design-daemon-first-control-plane.md), committed with the initial public release (8bee0bd).

## Decision

- The runtime runs in `ConduitDaemon`, a user-session LaunchAgent that needs no visible UI.
- The app, the menu bar and `pmctl` are clients of one versioned control plane.
- The privileged helper stays narrow; it never becomes the proxy daemon.
- `pm-proxy` stays side-effect-free.
- The in-process runtime in `AppState` is a dev-only fallback once the app is a client, and is removed from production before 1.0 (ROADMAP Next 3).

## Alternatives

- Keep the runtime in the app: traffic stops whenever the UI does.
- Run the runtime in the root helper: root would own the user's Keychain, Kerberos, CFNetwork PAC and session network state.

## Consequences

- Two runtime hosts exist until the app becomes a client. [0001](0001-one-runtime-host.md) bounds that cost by converging them on one `RuntimeHost`.
- The daemon needs a LaunchAgent lifecycle, a production control socket and its own recovery evidence before it can serve the machine.

## Invariants and verification

- Force-quitting the app does not interrupt HTTP, SOCKS5, DNS, local PAC, transparent proxy or tunnel traffic. This is the design's acceptance test and has not run against a production daemon.
- `pm-proxy` makes no machine changes; CI runs it headless.
- The control protocol keeps stable error codes and versioning (`ControlProtocolTests`).

## Implementation evidence

- [`ConduitDaemon`](../../Sources/ConduitDaemon/ConduitDaemon.swift) and [`DaemonRuntimeHost`](../../Sources/ConduitDaemon/DaemonRuntimeHost.swift) host the runtime over the same managers as the app.
- [`ControlProtocol`](../../Sources/ConduitShared/ControlProtocol.swift), [`DaemonClient`](../../Sources/ConduitShared/DaemonClient.swift) and [`pmctl`](../../Sources/pmctl/PMCtl.swift) exist; [`ControlProtocolTests`](../../Tests/ConduitTests/ControlProtocolTests.swift) and [`DaemonRuntimeHostTests`](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift) cover them over `FakeMachine`.
- ROADMAP Next 1 and 2 are partial; Next 3 (the app adopts the client) has not started.

Does not prove: that the daemon serves a real machine. The production control socket, LaunchAgent install and upgrade, and crash restart are not built, and logged-in-user Keychain, Kerberos and CFNetwork behaviour in the daemon is unvalidated (ROADMAP Next 2).

## Open questions

None beyond the ROADMAP Next 1 to 3 items.
