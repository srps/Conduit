# ProxyKernel

The portable product library: proxy, PAC routing engine, DNS forwarding, tunnels, runtime events and the protocols other targets implement. Types default to `package` access.

## Boundaries

- Import only Foundation, Dispatch, the NIO modules, Darwin/Glibc and `ConduitShared`'s grammar types. Apple platform frameworks (`Security`, `GSS`, `CryptoKit`, `SystemConfiguration`, `Network`, `os`, `AppKit`, `SwiftUI` and the like) belong in `ProxyAuth`, `ProxyPAC` or `PlatformMac` behind a protocol, even though Linux portability is not a current goal. CI enforces the allowlist with [`scripts/check-kernel-imports.py`](../../scripts/check-kernel-imports.py), which asks the compiler for each file's imports in debug and release; linking alone cannot enforce it. `Support/ProcessUnavailable.swift` makes naming `Process` a compile error, and the same script rejects a qualified `Foundation.Process` in the built object.
- No machine side effects: no `Process`, `networksetup`, env files, `/etc/resolver`, login items or helper calls. Those live in `PlatformMac` behind a protocol.
- Persistence paths come from `Support/RuntimeEnvironment.swift`, not from ambient process state. Keep it about files and locations. `PM_CONFIG_DIR` is read only at the executable boundary.

## Event loop and connections

- Don't block the NIO event loop with auth, DNS, Keychain, file I/O or other system work. Hop off the loop; a handler does no synchronous work over 1 ms.
- Validate every port to 0–65535 before the `UInt16` cast in `TCPRelay` and `UDPRelay`.
- Keep `SNIParser` hostname validation per label (RFC 952), never a whole-string check. `SNIParserTests` backs this with a property test.
- Reuse the one `ProxyAuthenticator` that `CONNECTHandler` and `ConnectionPool` cache for every challenge round of a handshake; never call the provider again on a later 407. Upstream proxy auth is stateful per connection, and a new instance breaks multi-leg SPNEGO and NTLM.
- Preserve the real hostname on proxied TLS tunnels for SNI and certificate validation. Don't design flows that make clients use `localhost`.
- Close active upstream channels (in-use pooled connections, dedicated CONNECT tunnels) only on explicit shutdown or a confirmed VPN transition. Control-plane transitions (listener recycle, config restart, direct-mode flip, VPN flap) use `ConnectionPool.closeAll(scope: .allButDedicated)` or `.idleOnly`: macOS keeps TCP state across a flap, and closing the channel destroys a stream the kernel would have resumed. Process exit and a user toggle-off pass `.all`. A confirmed transition (`ProxyOrchestrator.handleVPNStateChange`, never `.reasserting`) closes only what it stranded, at once, so clients reconnect instead of stalling (#148): any disconnect first closes channels whose local address is no longer assigned (before the connectivity probe), a disconnect that then routes DIRECT closes every remaining upstream channel, and a reconnect closes the DIRECT tunnels `DirectTunnelRegistry` recorded as dialed while the VPN was confirmed down (the VPN state, not the direct-mode cause). A direct dial captures `DirectTunnelRegistry.beginDial()` before it starts and passes it to `register`; a pool dial captures the pool's epoch at acquisition. Either way a sweep that ran mid-dial still applies on completion (`TransitionSweeps`). VPN-transition sweeps on a pool go through `closeConnections(migrating:)`, never `closeAll`, so in-flight dials are judged by them and exchanges on swept connections fail locally instead of retrying upstream. A handler that awaits before sweeping checks the VPN transition generation first, so a stale verdict never sweeps a newer routing's channels. See `docs/design-vpn-flap-resilience.md`.

## ProxyOrchestrator

- Per-request callbacks (`onConnectionOpened`, `onConnectionClosed`, `onRequestCompleted`, `dnsForwarder.onMetrics`, tunnel counts) go through `emitSnapshotCoalesced()`. State transitions (`mutateSnapshot`, lifecycle, VPN changes, errors, auth outcomes) go through `emitSnapshotImmediate()`. A counter on the immediate path brings back the burst that flooded the main actor at 50+ req/s; a transition on the coalesced path adds up to 100 ms of UI lag. See the "Snapshot emission throttle" section of `Proxy/ProxyOrchestrator.swift`.
- `ProxyOrchestrator` is `@MainActor`, so its `DispatchSource` timers are created on `.main`.

## DNS and tunnels

- DNS intercept and the transparent proxy stay coupled through `DNSForwardingHandler` and `ProxyOrchestrator`: intercept rules live in the handler, and `TransparentTCPProxy` starts and stops with the forwarder.
- `TunnelDNSResponder` stays self-contained; don't couple the tunnel DNS override to the general forwarder.
