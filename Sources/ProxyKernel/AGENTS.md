# ProxyKernel

The portable product library: proxy, PAC routing engine, DNS forwarding, tunnels, runtime events and the protocols other targets implement. Types default to `package` access.

## Boundaries

- Import only Foundation, Dispatch, the NIO modules, Darwin/Glibc and `ConduitShared`'s grammar types. Apple platform frameworks (`Security`, `GSS`, `CryptoKit`, `SystemConfiguration`, `Network`, `os`, `AppKit`, `SwiftUI` and the like) belong in `ProxyAuth`, `ProxyPAC` or `PlatformMac` behind a protocol, even though Linux portability is not a current goal. The build does not catch a stray import; #77 adds the CI check.
- No machine side effects: no `Process`, `networksetup`, env files, `/etc/resolver`, login items or helper calls. Those live in `PlatformMac` behind a protocol.
- Persistence paths come from `Support/RuntimeEnvironment.swift`, not from ambient process state. Keep it about files and locations. `PM_CONFIG_DIR` is read only at the executable boundary.

## Event loop and connections

- Don't block the NIO event loop with auth, DNS, Keychain, file I/O or other system work. Hop off the loop; a handler does no synchronous work over 1 ms.
- Validate every port to 0–65535 before the `UInt16` cast in `TCPRelay` and `UDPRelay`.
- Keep `SNIParser` hostname validation per label (RFC 952), never a whole-string check. `SNIParserTests` backs this with a property test.
- Preserve the real hostname on proxied TLS tunnels for SNI and certificate validation. Don't design flows that make clients use `localhost`.
- Close active upstream channels (in-use pooled connections, dedicated CONNECT tunnels) only on explicit shutdown. Control-plane transitions (listener recycle, config restart, direct-mode flip, VPN flap) use `ConnectionPool.closeAll(scope: .allButDedicated)` or `.idleOnly`; only process exit or a user toggle-off passes `.all`. macOS keeps TCP state across a VPN transition, and closing the channel destroys a stream the kernel would have resumed. See `docs/design-vpn-flap-resilience.md`.

## ProxyOrchestrator

- Per-request callbacks (`onConnectionOpened`, `onConnectionClosed`, `onRequestCompleted`, `dnsForwarder.onMetrics`, tunnel counts) go through `emitSnapshotCoalesced()`. State transitions (`mutateSnapshot`, lifecycle, VPN changes, errors, auth outcomes) go through `emitSnapshotImmediate()`. A counter on the immediate path brings back the burst that flooded the main actor at 50+ req/s; a transition on the coalesced path adds up to 100 ms of UI lag. See the "Snapshot emission throttle" section of `Proxy/ProxyOrchestrator.swift`.
- `ProxyOrchestrator` is `@MainActor`, so its `DispatchSource` timers are created on `.main`.

## DNS and tunnels

- DNS intercept and the transparent proxy stay coupled through `DNSForwardingHandler` and `ProxyOrchestrator`: intercept rules live in the handler, and `TransparentTCPProxy` starts and stops with the forwarder.
- `TunnelDNSResponder` stays self-contained; don't couple the tunnel DNS override to the general forwarder.
