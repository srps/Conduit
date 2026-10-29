# ProxyKernel

The portable product library: proxy, PAC routing engine, DNS forwarding, tunnels, runtime events and the protocols other targets implement. Types default to `package` access.

## Boundaries

- Import only Foundation, Dispatch, the NIO modules, Darwin/Glibc, `ConduitShared`'s grammar types (including the neutral `JSONByteCursor` lexical mechanics), its neutral `SecretBytes` container (decision 0018; `ProxyKernel` keeps a typealias to it) and its neutral resource ceilings and check values (`DomainResourceLimits`, `DomainResourceField`, `DomainResourceViolation`, `DomainResourceCheck` and the `ConfigurationResourceSource` protocol; decision 0021, the only control-free value set `ConfigResourceLimits.swift` reads, with no control DTO. The kernel adapter there maps `ProxyConfig` storage and holds no limit, order or violation) and Foundation-only `RuntimeEvents` domain values. Apple platform frameworks (`Security`, `GSS`, `CryptoKit`, `SystemConfiguration`, `Network`, `os`, `AppKit`, `SwiftUI` and the like) belong in `ProxyAuth`, `ProxyPAC` or `PlatformMac` behind a protocol, even though Linux portability is not a current goal. CI enforces the allowlist with [`scripts/check-kernel-imports.py`](../../scripts/check-kernel-imports.py), which asks the compiler for each file's imports in debug and release; linking alone cannot enforce it. `Support/ProcessUnavailable.swift` makes naming `Process` a compile error, and the same script rejects a qualified `Foundation.Process` in the built object.
- No machine side effects: no `Process`, `networksetup`, env files, `/etc/resolver`, login items or helper calls. Those live in `PlatformMac` behind a protocol.
- One identity per configuration component: `ConfigurationComponent` (`Support/ConfigurationFileSchema.swift`) and the legacy fallback text (`ConfigurationLegacyFallback`, `Support/ProxyConfigPersistence.swift`) are defined once here. The verified store in `ConduitRuntime` uses them and adds no second enum or string.
- Persistence paths come from `Support/RuntimeEnvironment.swift`, not from ambient process state. Keep it about files and locations. `PM_CONFIG_DIR` is read only at the executable boundary.

## Event loop and connections

- Don't block the NIO event loop with auth, DNS, Keychain, file I/O or other system work. Hop off the loop; a handler does no synchronous work over 1 ms.
- Validate every port to 0–65535 before the `UInt16` cast in `TCPRelay` and `UDPRelay`.
- Keep `SNIParser` hostname validation per label (RFC 952), never a whole-string check. `SNIParserTests` backs this with a property test.
- Reuse the one `ProxyAuthenticator` that `CONNECTHandler` and `ConnectionPool` cache for every challenge round of a handshake; never call the provider again on a later 407. Upstream proxy auth is stateful per connection, and a new instance breaks multi-leg SPNEGO and NTLM.
- Preserve the real hostname on proxied TLS tunnels for SNI and certificate validation. Don't design flows that make clients use `localhost`.
- Close active upstream channels (in-use pooled connections, dedicated CONNECT tunnels) only on explicit shutdown or a confirmed VPN transition. Control-plane transitions (listener recycle, config restart, direct-mode flip, VPN flap) use `ConnectionPool.closeAll(scope: .allButDedicated)` or `.idleOnly`: macOS keeps TCP state across a flap, and closing the channel destroys a stream the kernel would have resumed. Process exit and a user toggle-off pass `.all`. A confirmed transition (`ProxyOrchestrator.handleVPNStateChange`, never `.reasserting`) closes only sockets whose path it removed, at once and again as routes settle, so clients reconnect instead of stalling (#148, #156): every outbound socket a routing decision opens registers with the orchestrator's one `OutboundSocketRegistry` once connected, a socket whose local address is gone or whose peer the kernel now reaches through another interface is closed (at registration and by each sweep), and a disconnect whose probe routes DIRECT also closes every upstream socket. Judge sockets by their path (`SocketPathChecking`), never by when they were routed: no request carries a routing generation. Never sweep a pool with `closeAll` for a VPN transition, never build a second registry in the runtime, and let a flap hold pending sweeps. A handler that awaits before its routing phase checks the routing generation first, so a stale verdict never sweeps a newer routing's sockets. See `docs/design-vpn-flap-resilience.md`.

## ProxyOrchestrator

- Per-request callbacks (`onConnectionOpened`, `onConnectionClosed`, `onRequestCompleted`, `dnsForwarder.onMetrics`, tunnel counts) go through `emitSnapshotCoalesced()`. State transitions (`mutateSnapshot`, lifecycle, VPN changes, errors, auth outcomes) go through `emitSnapshotImmediate()`. A counter on the immediate path brings back the burst that flooded the main actor at 50+ req/s; a transition on the coalesced path adds up to 100 ms of UI lag. See the "Snapshot emission throttle" section of `Proxy/ProxyOrchestrator.swift`.
- `ProxyOrchestrator` shares `@RuntimeActor` with the runtime control-owner cluster (0031). Its `DispatchSource` handlers run on global dispatch queues and hop to that owner under a captured generation. Repeating sources admit at most one pending owner hop; cancellation, replacement or an immediate snapshot emission invalidates the affected older hop. Preserve uptime scheduling.

## DNS and tunnels

- DNS intercept and the transparent proxy stay coupled through `DNSForwardingHandler` and `ProxyOrchestrator`: intercept rules live in the handler, and `TransparentTCPProxy` starts and stops with the forwarder.
- `TunnelDNSResponder` stays self-contained; don't couple the tunnel DNS override to the general forwarder.
