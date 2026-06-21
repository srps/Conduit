# AGENTS.md

> **Project:** Conduit - a macOS-native corporate proxy manager (vendor-neutral) written in Swift 6.2+ on SwiftNIO + AppKit/SwiftUI. The product is the **menu-bar proxy with real upstream failover and full Kerberos/NTLM/PAC/SOCKS5/tunnel coverage** that nobody else on macOS ships.
>
> **Core constraints:** daily-driver reliability on macOS, structured observability over log-grepping, side-effect-free headless runtime for tests and CI. See `[docs/roadmap-v2.md](./docs/roadmap-v2.md)` for the product plan and `[docs/STYLE.md](./docs/STYLE.md)` for engineering discipline.

This file is the shared contract between human and AI contributors. If a rule here can be enforced by a linter, a test, or a type - move it there and delete it from here.

## Toolchain

The default `swift` / `xcodebuild` on this machine may point at Command Line Tools and fail with `no such module 'XCTest'`. Always use Xcode's toolchain explicitly.


| Intent                         | Command                                                                            | Notes                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Build                          | `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift build`     | Authority: `Package.swift`                                                      |
| Test                           | `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcrun swift test`      | 1,100+ tests across `Tests/ConduitTests/`                                    |
| Isolated headless runtime      | `pm-proxy --state-dir /tmp/pm-test-XXXX --port 0 --dns-port 0 --status-interval 2` | Emits NDJSON `ready` then periodic `status` snapshots; zero system side effects |
| Simulator / fault-injection    | `swift run pm-sim <scenario>`                                                      | Scenarios live in `Sources/pm-sim/`                                             |
| Standalone DNS forwarder       | `swift run pm-dns --port 5353 --verbose`                                           | Local DoH forwarder, no proxy                                                   |
| App bundle (debug)             | `./bundle-app.sh`                                                                  | Builds `Conduit.app` in-tree                                               |
| App bundle (release + install) | `./bundle-app.sh --release --install`                                              | Installs to `/Applications`                                                     |
| Privileged helper (re)install  | `sudo ./install-helper.sh`                                                         | **Required whenever helper code changes**                                       |
| Privileged helper uninstall    | `sudo ./uninstall-helper.sh`                                                       |                                                                                 |


`PM_CONFIG_DIR` is a boundary-level compatibility shortcut; Core code uses `RuntimeEnvironment`, not ambient process state.

## Architecture

Current package shape:

- `Sources/ProxyKernel/` - portable product library: proxy, PAC routing engine, DNS forwarding, tunnels, logging value types, kernel-side abstractions. Foundation + Dispatch + NIO* only; no Apple-specific frameworks. (Formerly `Sources/ConduitCore/`; renamed during the module split.)
- `Sources/ProxyControlBridge/` - thin adapter target for mapping kernel snapshots/results into `ConduitShared` control-protocol DTOs. Depends on `ProxyKernel` + `ConduitShared`; keeps wire-contract types out of `ProxyKernel`.
- `Sources/ProxyAuth/` - auth crypto: NTLM (CommonCrypto) + Kerberos / Negotiate (GSS) authenticators + the shared `credentialBasedAuthenticatorProvider` factory. Depends on `ProxyKernel`.
- `Sources/ProxyPAC/` - PAC evaluation: `CFPACEvaluator` (CFNetwork-backed, Safari-parity). Depends on `ProxyKernel`.
- `Sources/PlatformMac/` - macOS-specific glue: Keychain, networksetup wrappers, SMAppService, SCDynamicStore VPN observer, NWPathMonitor, helper-XPC client, `/etc/resolver` writer. Depends on `ProxyKernel` + `ConduitShared`.
- `Sources/Conduit/` - SwiftUI app and `AppState` orchestrator. Views stay thin.
- `Sources/ConduitHelper/` - privileged LaunchDaemon helper. Only privileged ops belong here.
- `Sources/ConduitShared/` - app↔helper wire contract. Extend the shared protocol rather than inventing ad-hoc IPC.
- `Sources/pm-proxy/` - headless proxy/DNS/tunnel CLI for isolated and CI testing.
- `Sources/pm-sim/` - fault-injection harness (fake client / origin / upstream proxy / scenarios). Every new runtime behaviour adds a scenario before it ships.
- `Sources/pm-dns/` - standalone DoH DNS forwarder CLI.

`Sources/ProxyKernel/Support/RuntimeEnvironment.swift` is the narrow DI boundary for persistence paths - keep it focused on files and locations. Kernel types default to `package` access unless wider visibility is required.

Deeper diagrams live in `[docs/architecture.md](./docs/architecture.md)`; don't inline them here.

## Design Invariants

These are judgment calls the toolchain cannot (yet) enforce. Encoded as **NEVER / ASK / ALWAYS** for scannability.

### NEVER

- **Never import Apple frameworks into `Sources/ProxyKernel/`.** The import fence: `ProxyKernel` may import only `Foundation`, `Dispatch`, `NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOConcurrencyHelpers`. `GSS`, `Security`, `JavaScriptCore`, `CommonCrypto`, `SMAppService`, `UserNotifications`, `SystemConfiguration`, `Network`, `ServiceManagement`, `Combine`, `AppKit`, `SwiftUI`, and `CFNetwork` helpers belong in `ProxyAuth`, `ProxyPAC`, or `PlatformMac`. The build is the test - `Sources/ProxyKernel/` doesn't link those frameworks, so a stray `import` is a compile error, not a review failure.
- **Never block the NIO event loop** with auth, DNS, Keychain, file I/O, or other system work. Hop off the loop first; NIO handlers must do no synchronous work > 1 ms.
- **Never let `pm-proxy` touch the host.** It must stay side-effect-free: no system proxy, no shell env file, no `/etc/resolver`, no login items, no privileged helper calls. This is what makes it safe for agents and CI.
- **Never log a credential, cookie, bearer token, or `Proxy-Authorization` payload.** Credentials crossing module boundaries should be opaque (`SecretBytes` once it lands); log sinks mask `Authorization` / `Proxy-Authorization` values.
- **Never weaken `SNIParser` hostname validation** to a whole-string check. Per-label RFC 952 is the contract, and there's a property test backing it.
- **Never pass port values to `TCPRelay` / `UDPRelay` / the helper without 0–65535 validation** before the BSD-socket `UInt16` cast. Both relays and the helper IPC enforce this.
- **Never revert `NegotiateAuthenticator`'s lazy NTLM fallback to eager loading.** The Keychain is only read when Kerberos actually fails. Eager loading prompts users who never needed NTLM in the first place.
- **Never swallow an error silently.** Either recover (with a structured event explaining how) or surface (with a structured event explaining why). Catch-and-continue without an event is banned.
- **Never couple tunnel DNS override to the general DNS forwarder.** `TunnelDNSResponder` is intentionally self-contained.
- **Never close active upstream channels (in-use pooled connections or dedicated CONNECT tunnels) outside of explicit shutdown.** Control-plane transitions (listener recycle, config-driven restart, direct-mode flip, VPN flap) must use `ConnectionPool.closeAll(scope: .allButDedicated)` or `.idleOnly`. Only terminal teardown (process exit, user toggle-off) may pass `.all`. macOS preserves TCP state across VPN transitions and the kernel resumes delivery on path return - proactively closing channels destroys streams the kernel was perfectly capable of keeping alive. See `docs/design-vpn-flap-resilience.md`.

### ASK

- **Ask before adding a new top-level dependency** to `Package.swift`. The only direct dependency is SwiftNIO (remote SwiftPM, `apple/swift-nio`) + Apple frameworks; `swift-collections` / `swift-system` come in transitively via SwiftNIO.
- **Ask before widening `package` access to `public`**, or before exposing a concrete type across a target boundary where a protocol exists.
- **Ask before introducing an unbounded collection, queue, cache, or timer.** Every pool, queue, cache, and buffer has a fixed capacity in config. Unbounded growth is a bug (see `RuntimeEventLog`, `maxConnections`, `inboundConnectionMaxLimit` for the pattern).
- **Ask before changing the helper XPC/IPC surface** in `ConduitShared`. It's a versioned contract with installed daemons in the field.
- **Ask before landing a new `TODO` / `FIXME` / `XXX`.** Triage it into an issue or delete the branch; don't accumulate.

### ALWAYS

- **Always emit a `RuntimeEvent` first** for any routing / auth / failover / health / config decision. Log lines are derived from events, not the other way around. Events are the contract with the UI, `pmctl` (forthcoming), the `pm-sim` agent harness, and the chaos demo.
- **Always route per-request orchestrator callbacks through `emitSnapshotCoalesced()`; only state-transition callsites use `emitSnapshotImmediate()`.** Per-request bursts (50+ req/s) flooded the MainActor before this split shipped (see `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift` "Snapshot emission throttle" section). The two paths are deliberate: state transitions (`mutateSnapshot`, lifecycle, vpn changes, errors, auth outcome) need to fire instantly so the UI's immediate-tier fields update without lag; counter-tier mutations (`onConnectionOpened`, `onConnectionClosed`, `onRequestCompleted`, `dnsForwarder.onMetrics`, `tunnelForwarder` count) get throttled to ≤10 Hz because the adapter re-coalesces published values at 1 Hz anyway. Mis-routing a counter-tier callsite through `emitSnapshotImmediate()` re-introduces the burst-storm bug; mis-routing a state-transition through `emitSnapshotCoalesced()` adds up to 100 ms of UI lag on visible state changes.
- **Always reuse the same `ProxyAuthenticator` instance** across challenge rounds of one handshake. Upstream proxy auth is stateful per connection; re-creating the authenticator breaks multi-leg SPNEGO/NTLM.
- **Always dispatch `DispatchSource` timers in `ProxyOrchestrator` to `.main`.** `ProxyOrchestrator` is `@MainActor`; Swift 6 enforces isolation at runtime.
- **Always preserve the real hostname on proxied TLS tunnels** for SNI and certificate validation. Don't design flows that require clients to use `localhost` as the hostname.
- **Always route side effects behind a protocol.** `networksetup`, env files, `/etc/resolver`, login items, and the privileged helper are called only from `PlatformMac`-scoped code, never from `ProxyKernel`. Direct `Process.launch` from Core is a review failure.
- **Always validate at the boundary, trust inside.** `ProxyConfig` is validated at parse time (`ConfigValidation.swift`). Network input is validated in NIO handlers. Inside Core, assertions catch bugs, not user errors.
- **Always derive observability from `ProxyOrchestratorSnapshot` + structured event streams.** The UI mirrors the daemon; it doesn't reinvent state.
- **Always prefer extending an existing strategy / manager** over adding another mode flag or `if` branch in `AppState` and view code.
- **Always keep DNS intercept + transparent proxy coupled** via `DNSForwardingHandler` and `ProxyOrchestrator`. Intercept rules live in the handler; `TransparentTCPProxy` starts/stops with the forwarder.
- **Always use `CanonicalJSON.encoder()` / `CanonicalJSON.decoder()`** for any JSON that crosses the daemon's external boundary as a file (`events.ndjson`, `audit.ndjson`, `snapshot.json`, the `ready` file) or a stdout NDJSON stream. The factory standardises `dateEncodingStrategy = .secondsSince1970` so every emitted timestamp is a Unix-epoch `Double` directly readable by Splunk / Datadog / `jq` / `date -r` - pre-canonicalisation, the project's mix of `JSONEncoder()` defaults emitted Apple reference-date Doubles that downstream consumers mis-interpreted by 31 years. In-process round-trips (helper IPC, control protocol, Keychain payload envelope) may keep using `JSONEncoder()` / `JSONDecoder()` since no external consumer parses those.

## Version Control

This repo uses `[jj](https://github.com/jj-vcs/jj)` (Jujutsu) colocated with git (`.jj/` alongside `.git/`). jj imports/exports refs on every command - don't run `jj git import` / `export` manually. Prefer `jj` for mutations; `git` / `gh` for read-only inspection.

- Commit: edit → `jj describe -m "message"` → `jj new`. No staging area.
- Advance a bookmark onto the commit just described: `jj bookmark advance <name>` (≥ 0.39; falls back to `jj b set <name> -r @-`).
- Push: `jj git push --bookmark <name>` (auto-tracks since 0.38; add `--allow-new` on first push or set `git.push-new-bookmark = true`).
- Undo anything: `jj undo` or `jj op restore <op-id>` (`jj op undo` was removed in 0.39).

## References

- `[docs/roadmap-v2.md](./docs/roadmap-v2.md)` - product plan, pillars, phases, research archive.
- `[docs/STYLE.md](./docs/STYLE.md)` - full engineering discipline (bounded everything, assert invariants, structured events first, validate at the boundary, no silent failures, explicit resource lifetime, side-effects behind protocols, security-first, deterministic where possible). This file carries the judgment layer; `STYLE.md` carries the full discipline.
- `[docs/architecture.md](./docs/architecture.md)` - module graph and daemon/client shape.
- `[docs/design-module-split.md](./docs/design-module-split.md)` - the executable plan for the `ConduitCore` → `ProxyKernel`/`ProxyAuth`/`ProxyPAC`/`PlatformMac` split. File-by-file destination map, the protocol surface inventory (`LogSink`, `CredentialProvider`, `PacEvaluator`, `PrivilegeClient`, `ProxyAuthenticator`, `VPNStatusObserving`, `TunnelResolverApplying`; `PlatformIntegration` deferred), and the staged migration sequence. Read before editing `Package.swift` target dependencies, before adding new files to `Sources/ProxyKernel/`, or before introducing a cross-target call.
- `[docs/design-vpn-flap-resilience.md](./docs/design-vpn-flap-resilience.md)` - the VPN flap resilience feature (Phases 1–7, shipped). Source of the `VPNObservedState` / `VPNStatusObserving` / `ConnectionPool.CloseScope` patterns this codebase reaches for whenever a side-effecting OS subsystem needs to be modelled behind a protocol with an injectable fake.
- `[docs/design-tunnel-dns-override.md](./docs/design-tunnel-dns-override.md)`
- `[docs/design-dns-intercept-transparent-proxy.md](./docs/design-dns-intercept-transparent-proxy.md)`
- Deep subsystem details belong in `docs/` or scoped rules, not here.

