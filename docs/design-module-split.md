# Design: ConduitCore → ProxyKernel / ProxyAuth / ProxyPAC / PlatformMac

> **Archived historical design doc.** This document records the design and as-shipped history of the ConduitCore → ProxyKernel / ProxyAuth / ProxyPAC / PlatformMac module split. By the time the rename step (Step 5) shipped, `Sources/ConduitCore/` had become `Sources/ProxyKernel/`; the six existing protocol files were reorganized into `Sources/ProxyKernel/Abstractions/`. Build green, 730 tests pass. The "Problem" + "Current State (audit)" + "Target Module Graph" + per-pillar prose below describe **the pre-split state** that motivated the design — preserved verbatim because they explain why each decision was made. The step-by-step sections describe what actually shipped under each step (with explicit "Deviations from the plan" subsections where reality differed). Forward references to `Sources/ConduitCore/...` in the historical prose mean "the pre-rename path of what is now `Sources/ProxyKernel/...`". **Note on identifiers:** vendor-specific names were neutralized for the public release — where a type or file appears with a generic name (e.g. `CorporateDefaults`), the original in git history used a vendor-specific name; treat these as scrubbed placeholders, not literal historical filenames.

## Problem

`Sources/ConduitCore/` is one SPM target with 56 files and ~13K LOC. It mixes:

- Pure-Swift / SwiftNIO logic (`ConnectionPool`, `HTTPProxyHandler`, `LocalProxyServer`, `DNSWireFormat`, `NoProxyMatcher`) that has no Apple-framework dependency.
- Auth crypto (`NTLMAuth.swift` → `import CommonCrypto`; `KerberosAuth.swift` → `import GSS`).
- PAC evaluation (`PACResolver.swift` → `import JavaScriptCore`).
- macOS system integration (`SystemProxyManager`, `SystemDNSManager`, `EnvironmentManager`, `LoginItemManager` → `ServiceManagement`, `KeychainStore` → `Security`, `NotificationManager` → `UserNotifications`, `NetworkMonitor` → `Network`, `VPNStatusMonitor` → `SystemConfiguration`, `CommandRunner` → `Process`).

The consequences today:

1. **Any consumer of `ConduitCore` drags in every Apple framework.** `pm-proxy`, `pm-sim`, `pm-dns`, and `pm-tunnel` link the entire framework set even though they exercise none of the macOS-only paths.
2. **The "what's portable?" question has no answer at the file level.** A new contributor opening `Sources/ConduitCore/Network/` cannot tell which files are pure NIO and which are macOS-bound; the file headers don't say, the directory layout doesn't say, and the only indicator is reading every `import` line.
3. **Testing the kernel without the platform requires runtime gymnastics.** `pm-sim` works because it picks types carefully; nothing prevents accidental coupling on the next change.
4. **The import fence in `AGENTS.md` exists but is unenforceable.** The fence is asserted ("ProxyKernel may import only Foundation, Dispatch, NIO*"), but `ProxyKernel` doesn't yet exist as a target — the rule has no compiler to lean on.
5. **Every subsequent roadmap item compounds the cost.** The roadmap's `JavaScriptCore → CFNetwork` PAC swap, the `pm-proxy` daemonization with control socket, the UI re-shape, and the `CorporateDefaults` externalization — each one is shaped by which target the relevant types live in. Doing them before the split bakes today's monolith into the change.

This document is the executable plan for the module-split items in `[roadmap-v2.md](roadmap-v2.md)` (§2.2 + §2.4). The roadmap describes the target shape in three paragraphs of prose; this doc lists every file, every callsite that crosses the new boundaries, every protocol that has to be introduced, and every phase boundary at which the build must stay green.

## Goals

In priority order:

1. **The build enforces the import fence.** After the split, `import GSS` in a `ProxyKernel` file is a compiler error, not a review failure. `pm-proxy` linking `PlatformMac` is a `Package.swift` change that has to be reviewed, not an oversight that goes unnoticed for months.
2. `**pm-proxy` and `pm-sim` link `ProxyKernel` (+ `ProxyAuth`) only — no `PlatformMac`.** The headless daemon's "I touch nothing on the host" guarantee in `AGENTS.md` becomes a build-time invariant.
3. **No behaviour change.** All 721 existing tests pass at every phase boundary. No user-visible surface moves; NDJSON snapshots, log lines, config schema, control flows are byte-identical.
4. **Each phase is independently shippable.** A reviewer can land the first step without the second; a bisect can land on any commit without leaving the build red.
5. **Cross-target callsites go through protocols, not concrete types.** Same pattern the codebase already uses for `ProxyAuthenticator`, `PrivilegeClient`, and `VPNStatusObserving` — extended to credentials, PAC, and platform integration.
6. **The split surfaces, not hides, the abstractions that don't exist yet.** `CredentialProvider`, `PacEvaluator`, and `LogSink` are not new product features — they are the seams the current code is missing. The split is the moment to introduce them.

## Non-Goals

- **No CFNetwork PAC swap.** That's a later roadmap item (`[roadmap-v2.md](roadmap-v2.md)` §2.5, the CFNetwork PAC evaluator), and it changes a concrete impl after the target exists. Doing it during the split conflates "move file" with "rewrite logic" and makes either change impossible to revert independently.
- **No `CorporateDefaults` → `Resources/Presets/example-corp.json`.** That's the OSS-prep vendor-preset externalization (`[roadmap-v2.md](roadmap-v2.md)` §2.9). The split moves `CorporateDefaults.swift` from `ProxyKernel` to `PlatformMac` (so the kernel ships vendor-neutral); the JSON externalization is a separate, later move.
- **No `SecretBytes`.** That's a later roadmap item (`[roadmap-v2.md](roadmap-v2.md)` §2.5, the opaque credential type). It's an opaque-bytes type that replaces `String` at credential boundaries — the boundaries (what crosses target lines as a credential) are identified by the split, but introducing the type is later work.
- **No `ProxyOrchestrator.startProxy()` decomposition.** That's a separate cleanup (`[roadmap-v2.md](roadmap-v2.md)` §2.4 #5), a STYLE rule-5 cleanup. Mixing it with the split would obscure both diffs.
- **No `pm-tunnel`-the-LaunchAgent or `pmctl`.** Those are the later control-plane work. The split is a precondition (the daemon binary must not link `PlatformMac`) but doesn't ship the daemon promotion itself.
- **No new functional capability.** This is pure structural refactoring. If the split adds a feature, the feature is escaping its phase.
- **No `NotificationSink` protocol introduction yet.** `NotificationManager` is currently invoked **only from `AppState`** (the SwiftUI app), never from `ConduitCore` itself. It moves directly to `PlatformMac` (or stays an app-level concern) without a kernel-side protocol — YAGNI. A protocol gets introduced the day the kernel needs to fire user-visible notifications, not before.

## Current State (audit)

### Pillar one: `AppLogStore` is everywhere

The single biggest blocker. Today `AppLogStore` (a `@MainActor`-isolated `ObservableObject` from `Combine`) is taken as an init parameter by **21+ kernel-bound types**: `HTTPProxyHandler`, `CONNECTHandler`, `ConnectionPool`, `LocalProxyServer`, `SOCKS5Server`, `TunnelForwarder` (3 sites), `TunnelDNSResponder` (2 sites), `TransparentTCPProxy` (2 sites), `LocalDNSForwarder` (2 sites), `UpstreamProber`, `DirectConnectDetector`, `AutoRecovery`, `PACRoutingEngine`, `ProxyOrchestrator`. It is also taken (optionally) by `EnvironmentManager`, `LoginItemManager`, `SystemDNSManager`, `SystemProxyManager`, `TunnelResolverManager` — i.e. by every PlatformMac-bound type too, which is fine.

`AppLogStore` cannot live in `ProxyKernel`:

- `Combine` is on the import fence's deny list. `import Combine` is the import that brings `ObservableObject` and `@Published` into scope.
- `@MainActor` requires AppKit/Foundation runloop dispatch; the kernel must be runnable from `pm-proxy` on a thread without a main runloop.
- Conceptually: a ring-buffered `ObservableObject` is a *UI* concern. The kernel emits log entries; the UI buffers, filters, and renders them.

Solution shape (detailed in Modules below): introduce `LogSink` in `ProxyKernel/Abstractions/`. The 21 callsites take `any LogSink` (or a concrete `LogSink` if dynamic dispatch hurts hot-path latency — measure first). `AppLogStore` moves to `Sources/Conduit/App/` and conforms to `LogSink` via its existing `nonisolated bridge(_:_:category:)` method.

`LogEntry`, `LogLevel`, `LogCategory` (Foundation-only `Codable` value types) stay in `ProxyKernel/Models/Logging.swift`.

### Pillar two: `Process` shellouts are concentrated

Only one file in the current Core does `Process()`: `Support/CommandRunner.swift`. It is called by `SystemProxyManager`, `EnvironmentManager`, `SystemDNSManager`, `PrivilegeClient`, and `VPNDNSDetector` — all of which move to `PlatformMac` anyway. So `CommandRunner` moves with them; nothing in `ProxyKernel` will need a shellout helper after the split.

STYLE rule "PlatformMac is the only target allowed to shell out via `Process`" becomes a build-time invariant: `import Foundation` doesn't expose `Process` differently on different targets, but the concrete `CommandRunner` enum simply isn't visible from `ProxyKernel`.

### Pillar three: `PrivilegeClient.swift` is a protocol *and* a concrete

`Sources/ConduitCore/System/PrivilegeClient.swift` (277 LOC) holds both:

- The `package protocol PrivilegeClient: Sendable` — already shaped correctly for `ProxyKernel/Abstractions/`.
- A concrete impl (XPC client to `ConduitHelper`) — calls `CommandRunner.runPrivilegedShellScript(...)` and uses `osascript` fallbacks.

The split is mechanical: protocol → `ProxyKernel/Abstractions/PrivilegeClient.swift`; concrete → `PlatformMac/HelperPrivilegeClient.swift`. The kernel sees only the protocol; `PlatformMac` provides the impl; `pm-proxy` ships a no-op stub (or `nil` where the API allows) so the headless daemon never escalates.

### Pillar four: `ConfigDefaults.swift` is one file with two providers

Today `Sources/ConduitCore/Models/ConfigDefaults.swift` contains:

- `protocol ConfigDefaultsProvider` — kernel.
- `struct GenericDefaults: ConfigDefaultsProvider` — kernel (vendor-neutral).
- `struct CorporateDefaults: ConfigDefaultsProvider` — should be `PlatformMac` (vendor-specific preset; later OSS-prep work moves it to a JSON resource).
- `enum LegacyConfigMigration` — kernel (Foundation-only `Codable` migration helper).

`CorporateDefaults` uses `NSUserName()` and `ProcessInfo.processInfo.hostName`, both Foundation-clean — so technically it could live in `ProxyKernel`. The reason to move it is **branding**, not import-fence: an open-source `ProxyKernel` shipping a vendor-specific preset by default is wrong shape regardless of imports.

### Pillar five: `RuntimeEnvironment.userDefault()` references macOS-conventional paths

`Sources/ConduitCore/Support/RuntimeEnvironment.swift` calls `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` to resolve `~/Library/Application Support/Conduit`. This is Foundation-clean (compiles on Linux), and Foundation's `applicationSupportDirectory` correctly resolves to `~/.local/share/Conduit` on Linux per XDG. So `**RuntimeEnvironment` stays in `ProxyKernel`** — it's our existing DI seam for persistence paths. Plan-B Linux/Windows builds either accept the Foundation-default path or override via `RuntimeEnvironment.isolated(stateDirectory:)`.

The static factory `RuntimeEnvironment.userDefault()` does carry an implicit macOS assumption (the directory name matches our bundle conventions). That's fine — call sites that want platform-conventional paths use `userDefault()`, headless tests use `isolated(_:)`, and CI uses `--state-dir` to bypass discovery entirely.

### Pillar six: `pm-proxy` already lives at the fence

The single most important finding: `pm-proxy` does not directly reference any of `SystemProxyManager`, `SystemDNSManager`, `EnvironmentManager`, `LoginItemManager`, `KeychainStore`, `NotificationManager`, `VPNStatusMonitor`, `NetworkMonitor`, `CommandRunner`, `CredentialManager`, or `AppLogStore`. It uses `ProxyOrchestrator` + `RuntimeEnvironment` + `GenericDefaults` + the headless logging shim built into `PMProxy.swift`.

This means the work-shape for the split is much narrower than feared: the `PlatformMac` types are reached only **through `ProxyOrchestrator`'s init parameters and `AppState`'s wiring**, not via direct callsites in the four binaries that should stay platform-clean. Once the orchestrator stops needing concrete `AppLogStore` and concrete `TunnelResolverManager.resolverPort`, `pm-proxy`'s build dependency on `PlatformMac` can be dropped — and the dependency removal itself is the test that the fence is correct (achieved at the PlatformMac-move step).

`pm-sim` is in the same shape. `Harness.swift` and the scenarios import `ConduitCore` only; once split, they import `ProxyKernel` + `ProxyAuth` (the latter for `MockAuthenticator` to conform to `ProxyAuthenticator`).

### Pillar seven: `NotificationManager` is already app-only

`NotificationManager` (UserNotifications, `UNUserNotificationCenter`) is created and held by `AppState` (`Sources/Conduit/App/AppState.swift:37`) — never instantiated or referenced inside `ConduitCore`. So it moves to `PlatformMac` with no protocol seam needed. The `NotificationSink` abstraction listed in `[roadmap-v2.md](roadmap-v2.md)` (§2.2) is a future-proof slot, deferred until kernel code wants to fire a notification.

## Target Module Graph

The shape below was the design target; the migration steps progressively realized it. After the rename step the diagram describes the actual on-disk layout (`Sources/ProxyKernel/`, `Sources/ProxyAuth/`, `Sources/ProxyPAC/`, `Sources/PlatformMac/`). Three deviations from the original target are noted inline (CorporateDefaults stayed kernel; PlatformIntegration deferred to the later control-plane work; LogSink lands in the final abstractions step).

```
Package.swift
│
├── ProxyKernel                     (Foundation, Dispatch, NIO* only)
│   ├── Models/                     ProxyConfig, ConfigSections, ConfigValidation, ConfigDiff,
│   │                               ProxyStatus, UpstreamProxy, RuntimeEvent (+ RuntimeEventLog),
│   │                               LogEntry / LogLevel / LogCategory (value types only),
│   │                               ConfigDefaults (only GenericDefaults + Provider protocol +
│   │                               LegacyConfigMigration)
│   ├── Proxy/                      LocalProxyServer, HTTPProxyHandler, CONNECTHandler,
│   │                               ConnectionPool, ProxyOrchestrator, SOCKS5Server,
│   │                               NoProxyMatcher, ProtocolDetector, ProxyAuthenticator (protocol),
│   │                               MetadataBlocklist, DirectModeCause, PACRoutingEngine
│   ├── Network/                    AutoRecovery, DirectConnectDetector, HealthChecker,
│   │                               UpstreamProber, DNSWireFormat, LocalDNSForwarder,
│   │                               TCPRelay, UDPRelay, VPNObservedState, VPNStatusObserving
│   ├── Tunnels/                    TunnelForwarder, TunnelDNSResponder, TransparentTCPProxy
│   ├── Support/                    RuntimeEnvironment, ErrorFormatting, TCPKeepalive,
│   │                               ProxyConfigPersistence (file-only, no Keychain)
│   ├── Security/                   ProxyCredentials, CredentialManagerError,
│   │                               InMemoryCredentialProvider (kernel value types +
│   │                               headless-daemon default)
│   └── Abstractions/               CredentialProvider (narrow → later widened),
│                                   PacEvaluator + PacScriptEvaluating,
│                                   LogSink, PrivilegeClient (reorg from System/),
│                                   ProxyAuthenticator (reorg from Proxy/),
│                                   VPNStatusObserving (reorg from Network/),
│                                   TunnelResolverApplying
│                                   (PlatformIntegration deferred to the later control-plane
│                                   work — see "New Abstractions § PlatformIntegration
│                                   (deferred)")
│
├── ProxyAuth                       (+ GSS, CommonCrypto)
│   ├── NTLMAuth.swift              (CommonCrypto for MD4 / HMAC-MD5)
│   ├── KerberosAuth.swift          (GSS.framework bridge)
│   └── (NegotiateAuthenticator currently inside Sources/Conduit/App/ —
│        moves here in a follow-up if not in this phase; see "What we don't move")
│
├── ProxyPAC                        (+ JavaScriptCore — until the later CFNetwork swap)
│   └── PACResolver.swift           (JS engine, conforms to PacEvaluator)
│
├── PlatformMac                     (+ Security, SMAppService, UserNotifications,
│   │                                  SystemConfiguration, Network)
│   ├── KeychainStore.swift                 (concrete CredentialProvider impl)
│   ├── CredentialManager.swift             (in-memory + Keychain coordinator)
│   ├── NotificationManager.swift           (UserNotifications)
│   ├── SystemProxyManager.swift            (networksetup wrapper)
│   ├── SystemDNSManager.swift              (networksetup wrapper)
│   ├── EnvironmentManager.swift            (shell env file)
│   ├── LoginItemManager.swift              (SMAppService)
│   ├── HelperPrivilegeClient.swift         (XPC to ConduitHelper — concrete)
│   ├── ActivationPreflight.swift           (permissions probe; uses SystemProxyManager)
│   ├── TunnelResolverManager.swift         (/etc/resolver via helper)
│   ├── VPNDNSDetector.swift                (scutil parser)
│   ├── VPNStatusMonitor.swift              (SCDynamicStore)
│   ├── NetworkMonitor.swift                (NWPathMonitor)
│   ├── CommandRunner.swift                 (Process wrapper)
│   ├── DNSManager.swift                    (DNS validation helpers; uses Foundation-only
│   │                                        regex but conceptually a platform concern —
│   │                                        keep with the rest of the System/ family)
│   └── CorporateDefaults.swift                 (intentionally NOT moved during the PlatformMac-move
│                                            step — stays kernel-side until the later JSON
│                                            externalization; see the PlatformMac-move deviations.
│                                            Originally planned as CorporatePreset.swift in PlatformMac.)
│
│   (No PlatformMacIntegration.swift — the composite was on the original plan but
│    deferred to the later control-plane work alongside the PlatformIntegration protocol.)
│
├── ConduitShared              (existing — wire contract for app↔helper IPC, untouched)
│
└── ProxyApp / pm-proxy / pm-sim / pm-dns / pm-tunnel / ConduitHelper
                                    (executable targets; target dependencies updated per
                                     §"Target dependency matrix" below)
```

### Target dependency matrix


| Target               | ProxyKernel | ProxyAuth | ProxyPAC | PlatformMac | ConduitShared | NIO* |
| -------------------- | ----------- | --------- | -------- | ----------- | ------------------ | ---- |
| `ProxyKernel`        | —           | —         | —        | —           | —                  | ✓    |
| `ProxyAuth`          | ✓           | —         | —        | —           | —                  | —    |
| `ProxyPAC`           | ✓           | —         | —        | —           | —                  | —    |
| `PlatformMac`        | ✓           | —         | —        | —           | ✓                  | —    |
| `pm-proxy`           | ✓           | ✓         | ✓        | —           | —                  | —    |
| `pm-sim`             | ✓           | ✓         | —        | —           | —                  | ✓    |
| `pm-dns`             | ✓           | —         | —        | —           | —                  | —    |
| `pm-tunnel`          | ✓           | ✓         | —        | —           | —                  | —    |
| `pm-vpn-check`       | ✓           | —         | —        | ✓           | —                  | ✓    |
| `pm-auth-check`      | ✓           | —         | —        | —           | —                  | —    |
| `ConduitHelper` | ✓           | —         | —        | —           | ✓                  | —    |
| `ProxyApp`           | ✓           | ✓         | ✓        | ✓           | ✓                  | —    |
| `ConduitTests`  | ✓           | ✓         | ✓        | ✓           | ✓                  | ✓    |


The `pm-proxy` row is the load-bearing one: dropping its `PlatformMac` dependency is the build-time test that the kernel doesn't sneak a platform import back in.

`pm-sim` keeps its existing `ProxyAuth` dependency for `MockAuthenticator`'s conformance to `ProxyAuthenticator` (which moves with `ProxyAuth`'s caller surface staying in `ProxyKernel/Abstractions/`); it **does not** depend on `ProxyPAC` because no scenario currently exercises real PAC evaluation.

`pm-tunnel` depends on `ProxyAuth` after the ProxyAuth-move step (constructs `NTLMAuthenticator` / `NegotiateAuthenticator` inline); see that step's shipped notes.

`pm-vpn-check` constructs `VPNStatusMonitor` directly as a diagnostic CLI — by design it exercises the SCDynamicStore production code path, so it links `PlatformMac` rather than mocking through a protocol. `pm-auth-check` uses `import GSS` at the executable level without referencing any concrete type from `ProxyAuth` or `PlatformMac`; it stays `ConduitCore`-only.

## File-by-File Audit

Every file in `Sources/ConduitCore/`, with its destination and the reason. Files marked **(stays kernel)** require no move; files marked **(splits)** become two files; everything else moves wholesale.

### Models/


| File                     | Destination | Reason                                                                                                         |
| ------------------------ | ----------- | -------------------------------------------------------------------------------------------------------------- |
| `ConfigDefaults.swift`   | **splits**  | `ConfigDefaultsProvider` + `GenericDefaults` + `LegacyConfigMigration` → Kernel; `CorporateDefaults` → PlatformMac |
| `ConfigDiff.swift`       | Kernel      | Foundation                                                                                                     |
| `ConfigSections.swift`   | Kernel      | Foundation; `PlatformIntegrationConfig` is a value type — interpretation lives in PlatformMac                  |
| `ConfigValidation.swift` | Kernel      | Foundation                                                                                                     |
| `ProxyConfig.swift`      | Kernel      | Foundation                                                                                                     |
| `ProxyStatus.swift`      | Kernel      | Foundation; carries the new Phase 7 flap telemetry fields                                                      |
| `RuntimeEvent.swift`     | Kernel      | Foundation + NIOConcurrencyHelpers                                                                             |
| `UpstreamProxy.swift`    | Kernel      | Foundation                                                                                                     |


### Proxy/


| File                        | Destination         | Reason                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CONNECTHandler.swift`      | Kernel              | Foundation + NIO; takes `LogSink` post-split                                                                                                                                                                                                                                                                                                                                                |
| `ConnectionPool.swift`      | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `DirectModeCause.swift`     | Kernel              | Foundation                                                                                                                                                                                                                                                                                                                                                                                 |
| `HTTPProxyHandler.swift`    | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `KerberosAuth.swift`        | **ProxyAuth**       | `import GSS`                                                                                                                                                                                                                                                                                                                                                                               |
| `LocalProxyServer.swift`    | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `MetadataBlocklist.swift`   | Kernel              | Foundation                                                                                                                                                                                                                                                                                                                                                                                 |
| `NTLMAuth.swift`            | **ProxyAuth**       | `import CommonCrypto`                                                                                                                                                                                                                                                                                                                                                                      |
| `NoProxyMatcher.swift`      | Kernel              | Foundation                                                                                                                                                                                                                                                                                                                                                                                 |
| `PACResolver.swift`         | **ProxyPAC**        | `import JavaScriptCore`                                                                                                                                                                                                                                                                                                                                                                    |
| `PACRoutingEngine.swift`    | Kernel              | Foundation; talks to a `PacEvaluator` (post-split protocol) instead of `PACResolver` concrete                                                                                                                                                                                                                                                                                              |
| `ProtocolDetector.swift`    | Kernel              | NIOCore                                                                                                                                                                                                                                                                                                                                                                                    |
| `ProxyAuthenticator.swift`  | Kernel/Abstractions | Already a protocol; concrete impls live in ProxyAuth                                                                                                                                                                                                                                                                                                                                       |
| `ProxyOrchestrator.swift`   | Kernel              | Foundation + NIO; *takes `LogSink` (not `AppLogStore`), `CredentialProvider` (not `CredentialManager` directly; introduced narrow, later widened), `PacEvaluator` (not `PACResolver`). Does **not** take `PlatformIntegration` — that protocol was deferred to the later control-plane work because the orchestrator never grew the cross-target need; AppState owns every platform side-effect call site today.** |
| `SOCKS5Server.swift`        | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `TransparentTCPProxy.swift` | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `TunnelDNSResponder.swift`  | Kernel              | Foundation + NIO                                                                                                                                                                                                                                                                                                                                                                           |
| `TunnelForwarder.swift`     | Kernel              | Foundation + NIO; the `TunnelResolverManager.resolverPort` reference becomes a kernel constant or a `PlatformIntegration` query — see "Open seam: `TunnelForwarder` ↔ resolver port" below                                                                                                                                                                                                    |


### Network/


| File                          | Destination         | Reason                                                                                                |
| ----------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------- |
| `AutoRecovery.swift`          | Kernel              | Foundation; takes `LogSink`                                                                           |
| `DirectConnectDetector.swift` | Kernel              | Foundation + NIO                                                                                      |
| `DNSWireFormat.swift`         | Kernel              | Darwin (libc); also compiles on Linux as `Glibc`/`Musl` if Plan B activates                           |
| `HealthChecker.swift`         | Kernel              | Foundation + NIOConcurrencyHelpers                                                                    |
| `LocalDNSForwarder.swift`     | Kernel              | Foundation + NIO                                                                                      |
| `NetworkMonitor.swift`        | **PlatformMac**     | `import Network` (NWPathMonitor)                                                                      |
| `TCPRelay.swift`              | Kernel              | Foundation                                                                                            |
| `UDPRelay.swift`              | Kernel              | Foundation                                                                                            |
| `UpstreamProber.swift`        | Kernel              | Foundation + NIO                                                                                      |
| `VPNDNSDetector.swift`        | **PlatformMac**     | Calls `CommandRunner.run(...)` (Process); also conceptually `scutil` parsing is macOS-bound           |
| `VPNObservedState.swift`      | Kernel              | Foundation; the value type the orchestrator reacts to                                                 |
| `VPNStatusMonitor.swift`      | **PlatformMac**     | `import SystemConfiguration`; the file already carries a header comment marking the relocation intent |
| `VPNStatusObserving.swift`    | Kernel/Abstractions | Already a protocol; `FakeVPNStatusObserver` stays for tests/sim                                       |


### Security/


| File                      | Destination     | Reason                                                                                          |
| ------------------------- | --------------- | ----------------------------------------------------------------------------------------------- |
| `CredentialManager.swift` | **PlatformMac** | Composes Keychain + in-memory; gets a `CredentialProvider` protocol slot in Kernel/Abstractions |
| `KeychainStore.swift`     | **PlatformMac** | `import Security`                                                                               |


### Support/


| File                           | Destination     | Reason                                                                                                                                                                                                                      |
| ------------------------------ | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CommandRunner.swift`          | **PlatformMac** | Wraps `Process`. STYLE: only PlatformMac shells out                                                                                                                                                                   |
| `ErrorFormatting.swift`        | Kernel          | Foundation + NIOCore                                                                                                                                                                                                        |
| `Logging.swift`                | **splits**      | Value types (`LogEntry`/`LogLevel`/`LogCategory`) → `Kernel/Models/Logging.swift`; `AppLogStore` → `Sources/Conduit/App/AppLogStore.swift` (the SwiftUI app); `LogSink` protocol → `Kernel/Abstractions/LogSink.swift` |
| `NotificationManager.swift`    | **PlatformMac** | `import UserNotifications`; only invoked from `AppState`, no kernel callers                                                                                                                                                 |
| `ProxyConfigPersistence.swift` | Kernel          | Foundation                                                                                                                                                                                                                  |
| `RuntimeEnvironment.swift`     | Kernel          | Foundation; persistence-path DI seam (see Pillar five)                                                                                                                                                                      |
| `TCPKeepalive.swift`           | Kernel          | Darwin + NIOCore                                                                                                                                                                                                            |


### System/


| File                          | Destination     | Reason                                                                                             |
| ----------------------------- | --------------- | -------------------------------------------------------------------------------------------------- |
| `ActivationPreflight.swift`   | **PlatformMac** | Calls `SystemProxyManager`; permissions probe is a platform concern                                |
| `DNSManager.swift`            | **PlatformMac** | Foundation-only API surface, but conceptually part of the System/ family — keep co-located         |
| `EnvironmentManager.swift`    | **PlatformMac** | Writes `~/.zshrc` / `~/.zprofile` / `~/.config/environment.d/`                                     |
| `LoginItemManager.swift`      | **PlatformMac** | `import ServiceManagement`                                                                         |
| `PrivilegeClient.swift`       | **splits**      | Protocol → `Kernel/Abstractions/`; helper-XPC concrete → `PlatformMac/HelperPrivilegeClient.swift` |
| `SystemDNSManager.swift`      | **PlatformMac** | `networksetup` wrapper; uses `PrivilegeClient`                                                     |
| `SystemProxyManager.swift`    | **PlatformMac** | `networksetup` wrapper                                                                             |
| `TunnelResolverManager.swift` | **PlatformMac** | Writes `/etc/resolver/`* via helper                                                                |


### Summary

- 36 files stay in **ProxyKernel** (most as-is; 1 splits — `ConfigDefaults.swift` and `Logging.swift` keep parts in Kernel).
- 2 files move to **ProxyAuth** (`NTLMAuth.swift`, `KerberosAuth.swift`).
- 1 file moves to **ProxyPAC** (`PACResolver.swift`).
- 17 files move to **PlatformMac** (the 12 `System/` + `Security/` files plus the 5 currently-in-Network/ macOS-bound files: `NetworkMonitor`, `VPNStatusMonitor`, `VPNDNSDetector`, `NotificationManager`, `CommandRunner`).
- 3 new files in **Kernel/Abstractions** across the split: `CredentialProvider.swift` (introduced narrow, later widened), `PacEvaluator.swift` (contains `PacEvaluator` + `PacScriptEvaluating`), `LogSink.swift`. Plus `TunnelResolverApplying.swift` which lives next door. The four pre-existing protocol files (`PrivilegeClient.swift`, `ProxyAuthenticator.swift`, `VPNStatusObserving.swift`) move into the same directory at the rename/reorganization step.
- 0 new files in **PlatformMac** for protocol composites. The original plan listed `PlatformMacIntegration.swift` (the composite that would conform to `PlatformIntegration`); both the protocol and the composite are deferred to the later control-plane work. PlatformMac instead grows individual conformers (`CredentialManager: CredentialProvider`, `HelperPrivilegeClient: PrivilegeClient`, `VPNStatusMonitor: VPNStatusObserving`, `TunnelResolverManager: TunnelResolverApplying`) without an aggregating type.

## New Abstractions

The split introduces three new protocols (`LogSink`, widened `CredentialProvider`, `PacEvaluator` + `PacScriptEvaluating`) plus one terminal carrier protocol (`TunnelResolverApplying`, shipped with the PlatformMac move). All sit in `ProxyKernel/Abstractions/` after the rename/reorganization step. Naming and shape match existing protocols (`ProxyAuthenticator`, `PrivilegeClient`, `VPNStatusObserving`).

A fourth protocol — `PlatformIntegration` — was on the original plan but is **deferred to the later control-plane work** based on evidence gathered after the PlatformMac move. See "PlatformIntegration (deferred)" below for why.

### `LogSink`

The shape locks in the perf characteristics from a later design review: a `minLevel` query lets the call site skip the entire interpolation when filtered out; the convenience extension makes that idiomatic; the protocol's required surface stays one method.

```swift
// ProxyKernel/Abstractions/LogSink.swift

package protocol LogSink: Sendable {
    /// Lower bound for which levels are worth constructing a message for.
    /// Implementations gate this on their loudest enabled output (e.g.
    /// `AppLogStore` returns `min(minStderrLevel, minBufferedLevel)`).
    var minLevel: LogLevel { get }

    /// Called from any thread / any actor. Implementations decide their own
    /// threading: `ConsoleLogSink` writes inline; `AppLogStore` hops to
    /// MainActor for its ring buffer. Implementations MUST NOT assume the
    /// calling thread.
    func log(_ level: LogLevel, _ message: String, category: LogCategory)
}

extension LogSink {
    /// Convenience for the frequent NIO call site pattern: skip the entire
    /// log call (including String interpolation) when filtered out at the sink.
    @inlinable
    package func log(
        _ level: LogLevel,
        category: LogCategory = .general,
        _ message: @autoclosure () -> String
    ) {
        guard level >= minLevel else { return }
        log(level, message(), category: category)
    }
}
```

Two stock implementations (`Sources/ProxyKernel/Support/StandardLogSinks.swift`):

```swift
package struct ConsoleLogSink: LogSink {
    package let minLevel: LogLevel
    package init(minLevel: LogLevel = .notice) { self.minLevel = minLevel }
    package func log(_ level: LogLevel, _ message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        FileHandle.standardError.write(Data((entry.formatted() + "\n").utf8))
    }
}

package struct DiscardingLogSink: LogSink {
    package init() {}
    /// Set to a level past .error so the @autoclosure extension always
    /// short-circuits. Tests / pm-sim that wire DiscardingLogSink pay zero
    /// per-call cost — not even the message interpolation runs.
    package var minLevel: LogLevel { .error }
    package func log(_: LogLevel, _: String, category _: LogCategory) {}
}
```

`AppLogStore` (in `Sources/Conduit/App/AppLogStore.swift` after the abstractions step) conforms via its existing nonisolated `bridge` method:

```swift
extension AppLogStore: LogSink {
    package nonisolated var minLevel: LogLevel {
        // Slightly racy — readers may see a transient older value during a
        // settings edit. Acceptable: minLevel is a hint, not a contract.
        min(minStderrLevel, minBufferedLevel)
    }
    package nonisolated func log(_ level: LogLevel, _ message: String, category: LogCategory) {
        bridge(level, message, category: category)
    }
}
```

The 15 kernel files (~21 init params + stored properties) change `AppLogStore` → `any LogSink`. Test sites that want to assert log output use `RecordingLogSink` (mirrors the existing `RecordingPrivilegeClient` pattern).

**Performance**: `any LogSink` introduces ~1–2 ns of existential dispatch per call. The bigger wins come elsewhere — the `@autoclosure` defers message interpolation when filtered out (saves the dominant per-`.debug`-line cost in production), and `ConsoleLogSink` writes synchronously instead of paying `AppLogStore.bridge`'s unconditional `Task { @MainActor in ... }` allocation per call. Under `pm-sim multi-100`, headless daemons stop scheduling thousands of MainActor tasks per second on a runloop they don't even use.

If profiling later shows witness-table dispatch as material (>2% in `pm-sim multi-100`), the targeted call sites can switch to a generic `<L: LogSink>` parameter. Until then, `any` everywhere — no premature monomorphization.

### `CredentialProvider` (introduced narrow, later widened)

The narrow initial shape — one method, `ProxyConfig`-keyed — was a deliberate transitional state. A later step widens it to per-upstream credentialing with optional returns:

```swift
// ProxyKernel/Abstractions/CredentialProvider.swift (widened shape)

package protocol CredentialProvider: Sendable {
    /// Return saved credentials for `upstream`. Returns `nil` (not throws) when
    /// none exist — that's the common case during Kerberos-only handshakes
    /// where the caller falls back without ceremony. Throws only for actual
    /// storage failures (Keychain ACL denial, decode failure, etc.).
    func credentials(for upstream: UpstreamProxy) throws -> ProxyCredentials?

    /// Persist `credentials` for `upstream`. Idempotent overwrite.
    func setCredentials(_ credentials: ProxyCredentials, for upstream: UpstreamProxy) throws
}
```

`ProxyCredentials` is the existing kernel value type (Foundation-only `Equatable` struct, in `Sources/ProxyKernel/Security/ProxyCredentials.swift` after the PlatformMac move).

Three conformers after widening:

- `CredentialManager` (PlatformMac) — Keychain-backed; derives storage key as `"\(upstream.host):\(upstream.port)|\(domain)|\(username)"` from the active config's identity fields plus the upstream address. Lazy migration from the old ProxyConfig-keyed entries on first access (one-time, per-credential, emits `auth.credential_migration` event).
- `InMemoryCredentialProvider` (kernel) — `NIOLockedValueBox<[UpstreamProxy: ProxyCredentials]>`-backed; default-constructed empty store returns nil for everything (preserves today's "no creds, fall back to Kerberos" behavior).
- A future `FileCredentialProvider` for `pm-proxy --credentials-file` is a natural next step but explicitly out of scope for the abstractions step.

The protocol is **storage-agnostic** — the `UpstreamProxy` parameter is a `Hashable` value type; conformers pick their own key shape. The kernel makes no assumption about whether keys are derived (Keychain) or used directly (in-memory).

### `PacEvaluator` + `PacScriptEvaluating`

```swift
// ProxyKernel/Abstractions/PacEvaluator.swift (current shape)

package protocol PacEvaluator: Sendable {
    func fetchPAC(from url: URL) async throws -> String
    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating
    func routeChain(for directives: String) -> [PACRoute]
}

package protocol PacScriptEvaluating: Sendable {
    func resolveProxyChain(for url: URL) throws -> [String]
}
```

Two protocols, not one, because `PACRoutingEngine` caches the evaluator (long-lived per PAC script) across multiple route lookups. Collapsing into one protocol would force re-fetch + re-parse on every route lookup. See "What the ProxyPAC move taught us" for the full rationale.

This is the seam that the later CFNetwork swap targets. Today's `PACResolver` is JavaScriptCore-backed; that work introduces `CFPACEvaluator` (CoreFoundation `CFNetworkExecuteProxyAutoConfigurationURL`) as a second `PacEvaluator` impl. Both can coexist behind a feature flag for one release; the kernel never knows which impl is wired.

The lingering smell is that `fetchPAC` lives on the same protocol as `makeEvaluator` — fetch and evaluation are different lifetimes. Worth considering a future split into `PacFetcher` + `PacEvaluatorFactory` when the second PAC implementation lands and we have two impls to compare. **Don't pre-emptively split now** — the second-impl evidence is what determines whether the split earns its keep.

### `TunnelResolverApplying`

Three-method protocol (`cleanupStale`, `applyAll`, `removeAll`) extracted during the PlatformMac move because `TunnelForwarder` (kernel) stored the concrete `TunnelResolverManager` (PlatformMac). Same shape as the ProxyAuth move's `authenticatorProvider` and the ProxyPAC move's `PacEvaluator`. The conformer is `TunnelResolverManager`; the test seam is a no-op fake added on demand.

### `PlatformIntegration` (deferred to the later control-plane work)

The original plan introduced a composite `PlatformIntegration` protocol at the rename step with eight methods:

```swift
// REJECTED after the PlatformMac move. Preserved here as the rationale for why the composite
// is wrong shape today, not as the shape we'll eventually ship.
package protocol PlatformIntegration: Sendable {
    func applySystemProxy(config: ProxyConfig) async throws
    func clearSystemProxy() async throws
    func applySystemDNS(config: ProxyConfig) async throws
    func clearSystemDNS() async throws
    func applyEnvironmentVariables(config: ProxyConfig) throws
    func clearEnvironmentVariables() throws
    func setLoginItemEnabled(_ enabled: Bool) throws
    var activationPreflight: ActivationPreflight { get }
}
```

The evidence gathered after the PlatformMac move cuts three ways:

1. **The orchestrator never grew the cross-target need.** `ProxyOrchestrator` references zero `PlatformMac` concretes; `AppState` owns every platform side-effect call site (~30 references in `AppState.swift`). The composite would be a god protocol whose only consumer is `AppState`, which already links `PlatformMac` directly.
2. **The pm-proxy parity argument doesn't hold.** The original justification was "make pm-proxy's no-side-effects guarantee a build-time invariant." But pm-proxy already has that guarantee — it doesn't construct any platform managers, doesn't take a `PlatformIntegration` parameter, and the `Package.swift` fence enforces no PlatformMac link. The no-op composite would be ceremony with no caller.
3. **ISP gets violated badly at the composite level.** A consolidated `PlatformIntegration` with the eight planned methods (plus the DNS-specific lifecycle: `saveCurrentDNS`, `restoreIfNeeded`, `startRelay`, `probeLiveness`, `reconcile`, `hasSavedState`, `isApplied`, `isCleared`) would have ~12+ methods. Most kernel callers would need 0–2; the composite forces them to depend on all 12.

`PlatformIntegration` re-enters the plan when **the later control-plane work** lands and the orchestrator (or a new `DaemonHost` type) needs to drive platform side-effects on `pmctl reload` commands. At that point the protocol shape is determined by real callers, not speculation. The shape may end up per-concern (`SystemProxyApplying` + `SystemDNSApplying` + ...) instead of composite — a decision for that work. The seam slot is reserved; the protocol isn't introduced.

### Why no `NotificationSink` (yet)

`NotificationManager` is invoked **only** from `AppState`. Kernel code never fires user-visible notifications today. Introducing a `NotificationSink` protocol now would be a placeholder with one no-op call site — the moment there is a kernel reason for it (e.g. the roadmap's "Connection audit log" emitting a "your VPN flapped" toast), the protocol gets added then. Same YAGNI argument that defers `PlatformIntegration`.

### Protocol surface inventory (final shape)

Eight protocols in `Sources/ProxyKernel/Abstractions/`. Method counts and caller counts kept honest — wide protocols invite spaghetti.


| Protocol                       | Methods                               | Kernel callers                                       | Conformers                                                                                    | Introduced                       |
| ------------------------------ | ------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------- |
| `LogSink`                      | 1 (+1 ext, +1 prop)                   | 15 files (~21 init params)                           | `AppLogStore`, `ConsoleLogSink`, `DiscardingLogSink`, `RecordingLogSink`                      | abstractions step                |
| `CredentialProvider` (widened) | 2                                     | 1 (`AuthenticatorFactory`)                           | `CredentialManager` (Keychain), `InMemoryCredentialProvider`, future `FileCredentialProvider` | introduced narrow, later widened |
| `PacEvaluator`                 | 3                                     | 1 (`PACRoutingEngine`)                               | `PACResolver`, future `CFPACEvaluator`                                                        | ProxyPAC move                    |
| `PacScriptEvaluating`          | 1                                     | 1 (`PACRoutingEngine.jsEvaluator`)                   | `PACScriptEvaluator`                                                                          | ProxyPAC move                    |
| `PrivilegeClient`              | 2 (execute, status)                   | 2 (orchestrator relay calls, AppState helper status) | `HelperPrivilegeClient`, `AppleScriptPrivilegeClient`, `RecordingPrivilegeClient`             | pre-split, surfaced at PlatformMac move |
| `ProxyAuthenticator`           | stateful per-handshake                | 4 NIO handlers                                       | `NTLMAuthenticator`, `KerberosAuthenticator`, `NegotiateAuthenticator`, `MockAuthenticator`   | pre-split                        |
| `VPNStatusObserving`           | 2 (setOnChange, start)                | 1 (`AppState`)                                       | `VPNStatusMonitor`, `FakeVPNStatusObserver`                                                   | pre-split                        |
| `TunnelResolverApplying`       | 3 (cleanupStale, applyAll, removeAll) | 1 (`TunnelForwarder`)                                | `TunnelResolverManager`, future no-op for tests                                               | PlatformMac move                 |


**No protocol exceeds 3 required methods.** No protocol has more than ~15 callers. The "21-method `PlatformIntegration` god protocol" antipattern is avoided by deferring rather than shipping.

## Open seam: `TunnelForwarder` ↔ resolver port (resolved during the PlatformMac move)

Pre-move audit: `Sources/ConduitCore/Proxy/TunnelForwarder.swift` called `dnsResponder.start(host: "127.0.0.1", port: TunnelResolverManager.resolverPort)` — and `TunnelResolverManager` lives in PlatformMac post-split. Two options were considered:

1. **Make `resolverPort` a kernel constant.** Move the numeric literal (15053) to `ProxyKernel/Models/TunnelResolverPort.swift`; leave `TunnelResolverManager` to *consume* the constant for its `/etc/resolver` file generation.
2. **Inject the port via `PlatformIntegration`.** Cleaner separation but adds a wiring path for a value that has zero variance across builds.

**Resolved with option 1.** `Sources/ConduitCore/Models/TunnelResolverPort.swift` was added (a `package enum TunnelResolverPort { static let port = 15053 }` declaration); `TunnelForwarder` reads the kernel constant; `TunnelResolverManager` (in PlatformMac) reads the same constant for its file generation.

The PlatformMac-move audit also surfaced two additional "kernel file references PlatformMac type" cases not in the original count — `TunnelForwarder.resolverManager: TunnelResolverManager?` (resolved via the new `TunnelResolverApplying` protocol) and `ProxyOrchestrator.startTCPRelay` downcasting to `HelperToolPrivilegeClient` (resolved by routing through `PrivilegeClient.execute(_:values:)` only). See that step's deviations §2 + §4.

## Migration Phases

The split is sequenced as six small phases, each independently buildable and testable. Every phase ends with `swift build` + `swift test` green. Every phase is one PR; a reviewer can land the first step without the second ever existing.

### Step 1 — Add new target directories, no behavior change

**Goal**: the four new SPM targets exist; they're populated with type aliases / re-exports so `import ProxyKernel` and `import ConduitCore` are interchangeable.

Tasks:

1. Create `Sources/ProxyKernel/`, `Sources/ProxyAuth/`, `Sources/ProxyPAC/`, `Sources/PlatformMac/` directories.
2. Each directory gets one stub file with one `package` typealias (e.g. `Sources/ProxyKernel/Stub.swift` with `package typealias _ProxyKernelStub = Int`) so SPM doesn't reject empty targets.
3. `Package.swift` adds the four new `.target(...)` declarations. `ConduitCore` keeps all its files; the four new targets are empty stubs that depend on nothing.
4. `Package.swift` declares the four targets as products (or not — internal targets are fine). No executable adds them to `dependencies` yet.

Exit: `swift build` green; `swift test` green; the new targets exist in the build graph.

### Step 2 — Move `ProxyAuth` files (shipped)

The advertised shape ("smallest-footprint move — two files, one import each") was wrong. Moving `NTLMAuth.swift` and `KerberosAuth.swift` to `ProxyAuth` without preparation creates an SPM-fatal dependency cycle:

- `ProxyAuth → ConduitCore` is required for the moved files to see the value types (`ProxyCredentials`) and protocol (`ProxyAuthenticator`) they reference.
- `ConduitCore → ProxyAuth` would then be required for two pre-existing callsites in the kernel that reference concrete NTLM/Negotiate types: `ProxyOrchestrator.makeAuthenticatorProvider` (a private static factory, three call sites) and `CredentialManager.savePassword(_:for:)` (calls `NTLMAuth.ntHash(for: password)`).
- SPM rejects the cycle. The honest task list is therefore refactor-first, move-second.

Tasks (as shipped):

1. **Refactor `ProxyOrchestrator` to stop constructing concrete authenticators.** Add a new init parameter `authenticatorProvider: (@Sendable (String) throws -> ProxyAuthenticator)? = nil`; store it; replace the three `Self.makeAuthenticatorProvider(...)` call sites with the stored closure; delete the static helper. When the caller does not inject a factory, the default closure throws a new kernel-side `ProxyAuthenticatorNotConfiguredError` — tests that never hit an upstream 407 are unaffected. The existing `credentialManager` init parameter is kept for source compatibility but no longer read inside the orchestrator; a later step removes it entirely when `CredentialProvider` lands.
2. **Refactor `CredentialManager.savePassword(_ password: String, for:)` out of the package API.** Delete the String-taking overload; keep `saveHash(_ hash: Data, for:)`. The one caller (`AppState.savePassword(_:)`) now computes `NTLMAuth.ntHash(for: password)` itself because it already links `ProxyAuth`. This is a minor breaking change to the `CredentialManager` package surface; the repo has exactly one caller.
3. **Introduce `Sources/ProxyAuth/AuthenticatorFactory.swift`** with one package function: `credentialBasedAuthenticatorProvider(configProvider:credentialManager:)`. It reproduces the pre-move `ProxyConfig.authMode`-driven factory (NTLMv2 direct, or Negotiate with NTLM fallback) and is the single source of truth for that logic — both `AppState` and `pm-proxy` call it. Not mentioned in the original plan; needed because otherwise the factory would be duplicated in both binaries.
4. `git mv Sources/ConduitCore/Proxy/NTLMAuth.swift Sources/ProxyAuth/`; add `import ConduitCore` at top.
5. `git mv Sources/ConduitCore/Proxy/KerberosAuth.swift Sources/ProxyAuth/`; add `import ConduitCore` at top.
6. Delete the first step's `Sources/ProxyAuth/Stub.swift`.
7. `Package.swift`: `ProxyAuth.dependencies = ["ConduitCore"]`. `pm-proxy`, `pm-sim`, `pm-tunnel`, `Conduit` (app), and the test target gain `ProxyAuth`. `pm-dns`, `pm-vpn-check`, `pm-auth-check`, `ConduitHelper` do **not** — they reference none of the moved types. (The design doc originally listed `pm-sim` as gaining `ProxyAuth` for `MockAuthenticator` conformance. In practice `MockAuthenticator` conforms to `ProxyAuthenticator` (kernel), not the concrete auth types — but we keep the dep to match the target-matrix's advertised shape and to leave the door open for scenarios that exercise real auth.)
8. Update callers of `ProxyOrchestrator.init(...)` that relied on the removed internal factory: `AppState` and `pm-proxy` now construct the factory via `credentialBasedAuthenticatorProvider(...)` and inject it as `authenticatorProvider:`. Both add a private `NIOLockedValueBox<ProxyConfig>` mirror (parallels AppState's existing `vpnFlapWindowBox`) so the factory closure can read the live config from NIO event loops without hopping to MainActor; `$config` sink / SIGHUP handler keep the box current. `pm-tunnel` already had its own local factory — it just gains `import ProxyAuth`.
9. Tests that reference concrete auth types gain `@testable import ProxyAuth`: `NTLMAuthTests`, `ProxyAuthenticatorTests`, `AuthHandshakeIntegrationTests`, `ConnectionPoolTests`, `ConnectTimeoutTests`, `CircuitBreakerWindowTests`, `UpstreamFailoverTests`, `VPNTransitionTableTests` (eight files).

Exit (as verified):

- `swift build` green; `swift test` runs 730 tests, 3 skipped, 0 failures.
- `rg '^import GSS|^import CommonCrypto' Sources/ConduitCore` → 0 matches.
- `rg 'NTLMAuthenticator|NTLMAuth\.|KerberosAuthenticator|NegotiateAuthenticator|SystemGSSTokenProvider|GSSTokenProvider' Sources/ConduitCore` → 0 matches (this is the stronger invariant: the kernel references neither the types nor the functions of the moved target).

What the ProxyAuth move taught us that carries into the later steps:

- The pattern "concrete `Foo` in kernel target A, protocol or wrapper in target B, callers outside" recurs at every split. Each move requires first identifying every kernel-side construction of the concrete type and re-routing it through an injected factory or protocol. "Move the file" is always the last, mechanical step — never the first.
- When the pre-split code stores a `SomeConcrete = SomeConcrete()` at the top of the orchestrator for later injection into sub-objects (as `pacResolver`, `credentialManager`, or any future case), the stored property has to be removed (not just re-routed) — otherwise the orchestrator's own scope still references the concrete type.
- Callers that held concrete types for non-orchestrator reasons (e.g. `AppState.pacResolver` for the Settings "Test PAC URL" feature) are separate call sites from orchestrator wiring; they need their own `import` update.
- `@testable import <NewTarget>` is the right pattern for tests — matches what they already do for `ConduitCore` and sidesteps any `package` vs `internal` confusion.

### Step 3 — Move `ProxyPAC` file (shipped)

Same *cycle pattern* as the ProxyAuth move, slightly larger scope because the file that moves also defines two kernel-consumed value types and because the evaluator type leaks into the kernel (not just the resolver). All tasks landed as designed; one carryover bookmarks `CommandRunner` work for the PlatformMac move.

Pre-split audit of `Sources/ConduitCore/Proxy/PACResolver.swift`:

- `package enum PACResolverError: Error` — Foundation-only; consumed by `PACRoutingEngine.refresh()`. Stays kernel.
- `package enum PACRoute: Equatable` — Foundation-only; return type of `PACRoutingEngine.routeChain(...)` and the type `HTTPProxyHandler` / `SOCKS5Server` branch on. Stays kernel.
- `package final class PACScriptEvaluator` — `import JavaScriptCore`; stored as `PACRoutingEngine.jsEvaluator: PACScriptEvaluator?` (kernel reference to a JSC type). Moves to ProxyPAC, but kernel needs a protocol seam for the stored property.
- `package final class PACResolver` — `import JavaScriptCore` transitively (via `PACScriptEvaluator`). Moves to ProxyPAC.

Kernel-side construction sites of the concrete types (same pattern as the ProxyAuth move's `makeAuthenticatorProvider`):

- `ProxyOrchestrator.swift:315` — `private let pacResolver = PACResolver()` (stored, passed only to the lazy-init `PACRoutingEngine`).
- `PACRoutingEngine.swift:31` — `init(..., resolver: PACResolver = PACResolver(), ...)` — default argument.
- `PACRoutingEngine.swift:23` — `private var jsEvaluator: PACScriptEvaluator?` — stored property holding a JSC-bound concrete.
- `PACRoutingEngine.swift:71` — constructs the evaluator via `resolver.makeEvaluator(pacScript:)`.

App- and pm-proxy-level construction sites (outside the kernel — legal to keep, need `import ProxyPAC`):

- `AppState.swift:60` — `private let pacResolver = PACResolver()` plus usage at `:613–614` for the Settings "Test PAC URL" feature. This caller exists for reasons unrelated to orchestrator wiring; it survives the move with an added `import ProxyPAC`.

Tasks (in order):

1. **Extract kernel-bound value types to a new file** `Sources/ConduitCore/Proxy/PACTypes.swift` (keeps Foundation-only: `PACRoute`, `PACResolverError`). Leaves `PACResolver.swift` carrying only the JSC-bound classes + helpers.
2. **Introduce two protocols in `Sources/ConduitCore/Proxy/PacEvaluator.swift`** (Kernel today; moves to `Kernel/Abstractions/` at the rename/reorganization step). One file, two types:
  - `package protocol PacScriptEvaluating: Sendable` — exposes `func resolveProxyChain(for url: URL) throws -> [String]`. This is what `PACRoutingEngine.jsEvaluator` stores post-move.
  - `package protocol PacEvaluator: Sendable` — exposes `fetchPAC(from:)`, `makeEvaluator(pacScript:) -> any PacScriptEvaluating`, `routeChain(for:)`. This is what `PACRoutingEngine.resolver` stores post-move.
  - Two protocols instead of one because the evaluator has a lifecycle: fetch a script string (async), construct a stateful evaluator over it (sync), reuse the evaluator across routing calls, and occasionally parse raw directive strings into `PACRoute`s. Collapsing these into a single method would force `PACRoutingEngine` to refetch the script on every route lookup.
3. **Refactor `PACRoutingEngine`**:
  - `private let resolver: PACResolver` → `private let resolver: any PacEvaluator`.
  - `private var jsEvaluator: PACScriptEvaluator?` → `private var jsEvaluator: (any PacScriptEvaluating)?`.
  - `init(..., resolver: PACResolver = PACResolver(), ...)` — the default argument is removed. `PACResolver()` can no longer be constructed from the kernel; callers must inject. (Parallels the ProxyAuth move's deletion of `ProxyOrchestrator.makeAuthenticatorProvider`.)
4. **Refactor `ProxyOrchestrator`**:
  - Delete `private let pacResolver = PACResolver()` stored property.
  - Add init parameter `pacEvaluator: (any PacEvaluator)? = nil`.
  - `pacRoutingEngine` becomes `(PACRoutingEngine)?` (optional lazy) — constructed only when `pacEvaluator != nil`. When the caller does not supply an evaluator, PAC routing is disabled for that orchestrator instance; all downstream consumers (`HTTPProxyHandler`, `SOCKS5Server`, `LocalProxyServer`) already accept `pacRoutingEngine: PACRoutingEngine?`, so nothing downstream changes.
5. **Move the file**: `git mv Sources/ConduitCore/Proxy/PACResolver.swift Sources/ProxyPAC/`; add `import ConduitCore` at top; conform `PACResolver: PacEvaluator`, `PACScriptEvaluator: PacScriptEvaluating`. Delete `Sources/ProxyPAC/Stub.swift`.
6. `**Package.swift`**: `ProxyPAC.dependencies = ["ConduitCore"]`. `Conduit` (app), `pm-proxy`, and the test target gain `ProxyPAC`. `pm-sim` does **not** — no scenario currently exercises real PAC and the cost of the unused dep outweighs future-proofing (the earlier decision to add `pm-sim → ProxyAuth` for parity with the target matrix is not repeated here; that reasoning was `MockAuthenticator` conforming to a moving protocol, which doesn't recur for PAC). `pm-dns`, `pm-tunnel`, `pm-vpn-check`, `pm-auth-check`, `ConduitHelper` do **not** need it.
7. **Update callers**:
  - `AppState.init` constructs `PACResolver()` and passes it as `pacEvaluator:` to `ProxyOrchestrator.init`. AppState also keeps its own `pacResolver` stored for the Settings "Test PAC URL" flow — that callsite just gains `import ProxyPAC`.
  - `pm-proxy` constructs `PACResolver()` and passes it — preserves today's behaviour where a pm-proxy launched with `config.pacRoutingEnabled = true` resolves PAC scripts. (A later step may replace this with a `nil` pacEvaluator plus a `--no-pac` flag once `pm-proxy` becomes a headless daemon with tightened surface; not this step's concern.)
  - `pm-proxy/PMProxy.swift` already imports `ProxyAuth` and `NIOConcurrencyHelpers` from the ProxyAuth move — the PAC addition is one more `import ProxyPAC` and one more `PACResolver()` line.
8. **Tests**: `PACResolverTests.swift` and `PACRoutingEngineTests.swift` gain `@testable import ProxyPAC`. The latter's existing `PACRoutingEngine(..., resolver: ...)` test sites lose the default argument — call sites must pass a resolver explicitly (was already the common case; the audit confirms no test relied on the `PACResolver()` default).

Exit criteria (as verified):

- `swift build` green; `swift test` runs 730 tests, 3 skipped, 0 failures (same count as the ProxyAuth move — this step changed no behaviour).
- `rg '^import JavaScriptCore' Sources/ConduitCore` → 0 matches.
- `rg 'PACResolver\(|PACScriptEvaluator\(' Sources/ConduitCore` → the only remaining match is a comment in `PACRoutingEngine.swift` describing the *removed* default argument (historical note, not a code dependency). 0 constructions.

Non-goals for this step:

- No CFNetwork PAC swap. `PACResolver` still uses JavaScriptCore. The swap is a later roadmap item (`[roadmap-v2.md](roadmap-v2.md)` §2.5, the CFNetwork PAC evaluator); the `PacEvaluator` protocol created here is the seam it lands behind.
- No collapsing PAC fetch + evaluate lifecycle into a single method. That is tempting for API cleanliness but would force `PACRoutingEngine` to re-fetch on every route lookup and defeats the existing caching. If a future rewrite lifts the cache into the `PacEvaluator` impl, the two-protocol shape can fold into one.

What the ProxyPAC move taught us that carries into the later steps:

- **Pre-split value-type extraction is cheaper than post-hoc.** Moving `PACRoute` + `PACResolverError` into a separate kernel-side file *before* touching `PACResolver.swift` kept the concrete file's move mechanical. The `ConfigDefaults.swift` split at the PlatformMac move is the same shape — do the `CorporateDefaults` extraction before the move, not during.
- **Two protocols, not one, when the kernel stores both a factory and its product.** The first instinct was a single `PacEvaluator` protocol; the kernel actually stores `PACRoutingEngine.jsEvaluator: PACScriptEvaluator?` as a long-lived cached evaluator between fetches, so collapsing the factory + product into one method would force re-fetch + re-parse on every routing call. The PlatformMac move has the same pattern at `PrivilegeClient` (one stored protocol) but not at the other System* managers — that step should audit for stored-product cases before assuming "one protocol per moving file".
- `**any`-typed stored properties cost nothing at the callsite.** `PACRoutingEngine.resolver: any PacEvaluator` and `jsEvaluator: (any PacScriptEvaluating)?` compile and test identically to the prior concrete versions. Existential dispatch on a per-route-lookup call site is below measurement noise; don't pre-optimize.
- `**pm-sim` target-matrix parity is case-by-case.** The ProxyAuth move added `pm-sim → ProxyAuth` because `MockAuthenticator` conforms to the moved protocol. The ProxyPAC move did **not** add `pm-sim → ProxyPAC` because no scenario exercises PAC and no test double conforms to the moved protocols. The rule: add the dep when a sim-side type depends on a post-move kernel protocol, not by default.

Carryovers to resolve during the PlatformMac move:

- `**Sources/ProxyPAC/PACResolver.swift:287–308` calls `CommandRunner.run(...)` in `fetchWithCurl`** (the ATS-forbidden `http://` PAC URL fallback). Today's dep graph is `ProxyPAC → ConduitCore → CommandRunner` (in-target), which compiles. The PlatformMac move relocates `CommandRunner` to `PlatformMac`; `ProxyPAC` does not depend on `PlatformMac`.
**Resolution: use the existing `insecureFetcher:` init parameter — do not introduce a new protocol.** `PACResolver.init` already accepts `insecureFetcher: (@Sendable (URL) async throws -> String)? = nil` and falls back to `Self.fetchWithCurl` only when nil. The PlatformMac move changes the default to a URLSession-only fetcher (or throws for `http://` URLs) and deletes `fetchWithCurl` from `PACResolver`. `AppState` (links `PlatformMac`) wraps a `CurlPACFetcher` free function around `CommandRunner.run` and passes it as the `insecureFetcher` argument when constructing its `PACResolver()`. `pm-proxy` injects nothing (accepts the URLSession-only default — per-host ATS exceptions are the modern answer and the headless daemon shouldn't shell out to curl anyway).
Earlier drafts of this doc proposed a `PACFetcher` protocol for this; discarded because the init-closure seam already exists, and a net-new protocol adds a maintenance surface for a capability the code already has.

### Step 4 — Move `PlatformMac` files (shipped)

The bulk of the move. 16 files across `Security/`, `System/`, `Network/`, `Support/`, including one file-split that shipped (`PrivilegeClient.swift`) and one that did not (`ConfigDefaults.swift` — `CorporateDefaults` stayed kernel-side; see deviations). This is the step that makes `pm-proxy`'s `Package.swift` drop `PlatformMac` from its dependency list — **the build itself is now the test that the import fence is correct**.

Same refactor-first / move-second pattern as the ProxyAuth + ProxyPAC moves, scaled up: more constructions to untangle, more stored properties to re-type through protocols, and more cross-target callsites in `AppState`. Applied rigorously, the per-file move stays mechanical; applied lazily, it stalls on a cycle discovery three files in.

#### Pre-audit: kernel-side construction sites of `PlatformMac`-bound types

Kernel today stores or constructs (not just takes-as-parameter) the following types that this step moves to `PlatformMac`. Each is a refactor-first site — the kernel needs an abstraction or the construction has to move out before the file moves:

- `**ProxyOrchestrator.credentialManager: CredentialManager`** — the ProxyAuth move kept this as an accepted-but-unused init parameter to avoid a call-site change at that point. This step drops the parameter (it's unused anyway); the `CredentialProvider` protocol comes in alongside. The net is: remove the store and the init param entirely, forcing any caller that passed one (today: `AppState`, `pm-tunnel`) to stop doing so.
- `**CredentialManager`** (itself, in `Sources/ConduitCore/Security/`) — moves to `PlatformMac` wholesale. Currently depended on by `ProxyOrchestrator` (see above), `AppState`, `pm-proxy`, `pm-tunnel`. Post-move, `pm-proxy` and `pm-tunnel` need either `PlatformMac` (which breaks the `pm-proxy` exit criterion) or an in-memory/no-op `CredentialProvider`. For this step specifically, `pm-proxy` and `pm-tunnel` drop their `CredentialManager` constructions and inject nothing — `credentialBasedAuthenticatorProvider` needs a different credential source (see "pm-proxy + pm-tunnel consequences" below).
- `**ProxyOrchestrator.privilegeClient: PrivilegeClient?**` — already a protocol today (`package protocol PrivilegeClient: Sendable`); this step's task is the file-split (protocol stays in Kernel, XPC impl renamed and moved to PlatformMac). No kernel construction of the concrete; `AppState` constructs `HelperToolPrivilegeClient` and passes it as the protocol. Clean.
- `**TunnelForwarder.resolverPort` reference** — `Sources/ConduitCore/Proxy/TunnelForwarder.swift` references `TunnelResolverManager.resolverPort` (a `static let` = 15053) to configure the tunnel DNS responder. `TunnelResolverManager` moves to `PlatformMac`. The "open seam" decision (see §"Open seam: `TunnelForwarder` ↔ resolver port" above): **move the constant** to a new kernel file `Sources/ConduitCore/Models/TunnelResolverPort.swift`; `TunnelResolverManager` (in `PlatformMac`) reads the same constant for its `/etc/resolver` file generation. Smallest correct change.
- `**AppState.systemConduit` / `systemDNSManager` / `environmentManager` / `loginItemManager` / `networkMonitor` / `vpnStatusMonitor` / `notificationManager` / `dnsManager` / `credentialManager` / `HelperToolPrivilegeClient` / `ActivationPreflight`** — AppState is in the app target and is the single biggest consumer of `PlatformMac` types. It gains one `import PlatformMac` (or is already expected to via the app's target deps) and calls the concrete types directly. No refactor needed at the AppState boundary itself; the `PlatformIntegration` composite was on the original plan to land at the rename step, but later review deferred the composite to the control-plane work once it became clear no kernel caller exists today (see "New Abstractions § PlatformIntegration (deferred)"). AppState's direct calls into the System* concretes are the long-term shape.
- `**ConfigDefaults.swift: CorporateDefaults*`* — one kernel-consumed struct (`GenericDefaults`) + one vendor-specific struct (`CorporateDefaults`) + one kernel-only migration helper (`LegacyConfigMigration`). `pm-proxy` references `GenericDefaults.shared.makeConfig()` in `--minimal` mode — stays kernel. `CorporateDefaults` is used by `AppState` for first-run defaults; moves to `PlatformMac/CorporatePreset.swift` and `AppState` references it under its new name via `import PlatformMac`. Per the ProxyPAC-move lesson, the split is pre-move (extract first, move second).

#### Carryovers from the ProxyPAC move

- `**Sources/ProxyPAC/PACResolver.swift: fetchWithCurl` uses `CommandRunner.run`** — resolution upgraded from the earlier "introduce `PACFetcher` protocol" plan. `PACResolver.init` already has an `insecureFetcher: (@Sendable (URL) async throws -> String)? = nil` parameter; this step changes the default from `Self.fetchWithCurl` to a URLSession-only fetcher, deletes `fetchWithCurl`, and lets `AppState` (which will link `PlatformMac`) inject a free-function `CurlPACFetcher` closure. `pm-proxy` keeps the default (no shell-out). See "Revisit notes" below for the reasoning: the init-closure seam already exists; adding a protocol for a one-caller capability would be overfitting.

#### pm-proxy + pm-tunnel consequences

Today's `pm-proxy/PMProxy.swift` constructs `CredentialManager()` and passes it to `credentialBasedAuthenticatorProvider(...)`. `pm-tunnel/PMTunnel.swift` does the same inline (without the factory helper). After this step the concrete `CredentialManager` is in `PlatformMac`, which neither executable is allowed to link.

**Decision: introduce `CredentialProvider` protocol in `ConduitCore` at this step with a narrow initial shape.** The name is terminal — a later step widens the protocol's surface (adds per-upstream keying, a setter) without renaming, so this step avoids the mechanical sed pass that an interim name would incur. Initial shape:

```swift
package protocol CredentialProvider: Sendable {
    func credentials(for config: ProxyConfig) throws -> ProxyCredentials
}
```

- `CredentialManager` conforms (trivially — already has `loadCredentials(for:)` with a compatible signature). Moves to `PlatformMac` at task 7 with the conformance intact.
- New `InMemoryCredentialProvider` in `Sources/ConduitCore/Security/InMemoryCredentialProvider.swift` — Foundation-only, kernel-side. Credential *storage* is a kernel-value-types concern (matches where `ProxyCredentials` and `CredentialManager` live today); auth *use* is `ProxyAuth`'s job (token generation).
- `credentialBasedAuthenticatorProvider` in `Sources/ProxyAuth/AuthenticatorFactory.swift` is rewritten to take `any CredentialProvider` instead of `CredentialManager`. No behaviour change; existing callers (`AppState`, `pm-proxy`) are upshifted via the conformance.
- `pm-proxy` stops constructing `CredentialManager()`; constructs `InMemoryCredentialProvider()` instead (empty credential store — auth calls raise the same `ProxyAuthenticatorNotConfiguredError` on 407 as today when no creds are saved). A future `--credentials-file` CLI flag can populate it; not this step's concern.
- `pm-tunnel` mirrors `pm-proxy`.

Result: this step's exit criterion ("`pm-proxy`'s `Package.swift` has no `PlatformMac`") holds the moment it lands.

#### Ordered task list

1. **Extract `CorporateDefaults` → new file `Sources/ConduitCore/Models/CorporateDefaults.swift*`* (still kernel-side at this step; keeps `ConfigDefaults.swift` as pure Kernel content). Then `git mv` it to `Sources/PlatformMac/CorporatePreset.swift` in task 7; the two-step makes the rename-vs-move diff readable.
2. **Introduce `Sources/ConduitCore/Models/TunnelResolverPort.swift`** — one `package enum TunnelResolverPort { static let port = 15053 }` declaration. `TunnelForwarder` reads from it; `TunnelResolverManager` (about to move to PlatformMac) reads from it too post-move. Replace the existing `TunnelResolverManager.resolverPort` reference in `TunnelForwarder.swift` with the new kernel constant.
3. **Introduce `CredentialProvider` protocol** in `Sources/ConduitCore/Security/CredentialProvider.swift` (next to `CredentialManager.swift`). Terminal name — a later step widens the shape without renaming. Make `CredentialManager` conform (one-line extension; existing `loadCredentials(for:)` already matches). Add new `Sources/ConduitCore/Security/InMemoryCredentialProvider.swift` — Foundation-only, empty-store default that throws `CredentialManagerError.missingCredentials` on every call (same error path as `CredentialManager` when the Keychain entry is missing, so the outer `credentialBasedAuthenticatorProvider` closure handles it identically). Refactor `credentialBasedAuthenticatorProvider` in `ProxyAuth/AuthenticatorFactory.swift` to take `any CredentialProvider`.
4. **Drop `credentialManager:` init parameter from `ProxyOrchestrator`.** It was a transitional carry from the ProxyAuth move. Today's pass-throughs (`AppState`, `pm-tunnel`) stop passing it; `pm-sim` + tests never passed it.
5. **Change `PACResolver`'s default `insecureFetcher`** from `Self.fetchWithCurl` to a URLSession-only fetcher that throws on `http://` URLs (message: "Configure `insecureFetcher:` to fetch plaintext PAC URLs"). Delete `fetchWithCurl` and `isATSError` static helpers from `PACResolver` — they were the only callers of `CommandRunner` in `ProxyPAC`. `AppState` gains a tiny free function `curlPACFetcher(url:)` in `Sources/Conduit/App/` (app target, links `PlatformMac`) that wraps `CommandRunner.run`, and passes it as `PACResolver(insecureFetcher: curlPACFetcher)`. `pm-proxy` keeps the URLSession-only default — it's headless, shouldn't shell out.
6. **Split `Sources/ConduitCore/System/PrivilegeClient.swift`.** Protocol stays where it is today (moves to `Sources/ProxyKernel/Abstractions/` only at the rename/reorganization step). Concrete class renamed + extracted to a new file `Sources/PlatformMac/HelperPrivilegeClient.swift`; `AppState` + test doubles update the concrete type name via mass-edit.
7. **Move files (mechanical per file):**
  - `Sources/ConduitCore/Security/*` (2 files: `KeychainStore.swift`, `CredentialManager.swift`) → `Sources/PlatformMac/`.
  - `Sources/ConduitCore/System/*` except `PrivilegeClient.swift` (7 files: `ActivationPreflight`, `DNSManager`, `EnvironmentManager`, `LoginItemManager`, `SystemDNSManager`, `SystemProxyManager`, `TunnelResolverManager`) → `Sources/PlatformMac/`.
  - `Sources/ConduitCore/Network/{NetworkMonitor,VPNStatusMonitor,VPNDNSDetector}.swift` (3 files) → `Sources/PlatformMac/`.
  - `Sources/ConduitCore/Support/{CommandRunner,NotificationManager}.swift` (2 files) → `Sources/PlatformMac/`.
  - `Sources/ConduitCore/Models/CorporateDefaults.swift` (task-1 extract) → `Sources/PlatformMac/CorporatePreset.swift`.
  - Each moved file gains `import ConduitCore` at the top. The target is already set up (the first step's stub exists).
  - Delete `Sources/PlatformMac/Stub.swift`.
8. `**Package.swift`:**
  - `PlatformMac.dependencies = ["ConduitCore", "ConduitShared"]` (Shared because `HelperPrivilegeClient` uses the `ConduitShared` wire contract).
  - `Conduit` (app) gains `PlatformMac`. Tests gain `PlatformMac`. `**pm-vpn-check` gains `PlatformMac`** — it constructs `VPNStatusMonitor(...)` directly as a diagnostic and should exercise the production path.
  - `pm-proxy`, `pm-sim`, `pm-tunnel`, `pm-dns`, `pm-auth-check`, `ConduitHelper` do **not**. Verify by inspection — the dep list is this step's exit criterion.
9. **Update callers:**
  - `AppState` gains `import PlatformMac`. Each concrete System* manager lookup compiles unchanged because AppState holds the concretes directly (no orchestrator pass-through for those today). Adds a tiny `curlPACFetcher` free function (wraps `CommandRunner.run`) and passes it as `PACResolver(insecureFetcher:)`.
  - `pm-proxy` stops constructing `CredentialManager()`; constructs `InMemoryCredentialProvider()` instead. Drops the `credentialManager:` argument to `ProxyOrchestrator.init` (parameter removed in task 4).
  - `pm-tunnel` same as `pm-proxy`.
  - `pm-vpn-check` gains `import PlatformMac` (after the file move `VPNStatusMonitor` is only visible through that target).
  - `pm-auth-check` imports `GSS` directly and doesn't touch any moved file; no change.
10. **Update tests:**
  - Every test file that references a moved type gains `@testable import PlatformMac`. Expected set (to be re-audited after this step's grep is complete): `ActivationPreflightTests`, `KeychainAccessTests`, `SystemDNSManagerTests`, `HelperContractTests`, and any test that constructs `CredentialManager` directly (`KeychainAccessTests` at minimum; `SleepRecoveryTests` constructs `NetworkMonitor()`).
    - The eight ProxyAuth-move-touched test files and the three ProxyPAC-move-touched test files keep their existing `@testable import` chain — they don't grow a `PlatformMac` import unless they also reference a moved System* type.

#### Exit criteria

- `swift build` green; `swift test` green (730 tests, same count as the ProxyAuth/ProxyPAC moves — this step is structural).
- `rg '^import Security|^import SMAppService|^import UserNotifications|^import SystemConfiguration|^import Network$' Sources/ConduitCore` → 0 matches.
- `rg 'Process\b' Sources/ConduitCore` → 0 matches (the `Process()` construction rule; `CommandRunner` moved out).
- `pm-proxy`'s `Package.swift` dep list is `["ConduitCore", "ProxyAuth", "ProxyPAC"]` — no `PlatformMac`. The same holds for `pm-sim`, `pm-dns`, `pm-tunnel`, `pm-vpn-check`, `pm-auth-check`, `ConduitHelper`.
- Running `otool -L .build/debug/pm-proxy` shows no linkage against `SystemConfiguration.framework`, `UserNotifications.framework`, `ServiceManagement.framework`, `Security.framework`, `Network.framework` — the dynamic-load profile is the enforcement.

#### Non-goals for this step

- **No `PlatformIntegration` composite yet.** AppState still calls the System* managers directly. (Originally planned for the rename step; deferred to the later control-plane work — see "New Abstractions § PlatformIntegration (deferred)".)
- **No `LogSink` protocol yet.** Lands in the final abstractions step.
- **No CFNetwork PAC swap.** Unchanged from the ProxyPAC move's non-goals.
- **No `Resources/Presets/example-corp.json` externalization.** This step moves the struct to `PlatformMac/CorporatePreset.swift`; the later OSS-prep work moves it to JSON.

#### Expected scope

Rough: 19 file moves (17 designated + 2 extractions for the splits) + ~6 kernel-side refactor sites + ~5 caller updates + ~6 test-file import updates. Significantly larger than the ProxyAuth or ProxyPAC moves; expect ~200–400 lines of diff across Package.swift + call sites plus the pure moves. The refactor-first discipline is load-bearing — applied as a straight file-move this step will hit the first cycle inside 10 minutes.

#### Deviations from the plan (shipped 2026-04-21)

1. `**CorporateDefaults` stayed kernel-side.** The plan called for moving `Sources/ConduitCore/Models/CorporateDefaults.swift` to `Sources/PlatformMac/CorporatePreset.swift`. In practice, `ProxyConfig.corporateDefault()` is called from ~100 test sites and from kernel-side `ProxyConfigPersistence` fallbacks; breaking that surface at this step would bloat it and obscure the main structural work. The later OSS-prep work externalizes the data to `Resources/Presets/example-corp.json`, eliminating the Swift struct entirely — that is the right time to absorb the ripple. Net: `CorporateDefaults.swift` was extracted to its own file (task 1 as planned) but stays in `Sources/ConduitCore/Models/`. The step's scope shrank from 17 file moves to 16.
2. `**VPNStateFuser` + `UtunRawObservation` extracted from `VPNStatusMonitor.swift`** into a new kernel file `Sources/ConduitCore/Network/VPNStateFuser.swift`. The original file mixed the SCDynamicStore-backed production monitor (PlatformMac-bound) with a pure-logic state machine (Foundation-only, tested directly by `VPNStateFuserTests`, consumed by `pm-sim` scenarios). The move surfaced the coupling; the extraction is a clean split with no behavioural change. Not anticipated in the pre-audit.
3. **New `TunnelResolverApplying` protocol in the kernel.** `TunnelForwarder` (kernel) stored `resolverManager: TunnelResolverManager?` directly — a kernel-to-concrete cross-target reference that the pre-audit missed. Introduced a three-method protocol (`cleanupStale`, `applyAll`, `removeAll`) mirroring the concrete's existing public surface; `TunnelResolverManager` conforms trivially; `TunnelForwarder` now stores `any TunnelResolverApplying`. Same seam-shape as the ProxyAuth move's `authenticatorProvider` and the ProxyPAC move's `PacEvaluator`.
4. `**ProxyOrchestrator.startTCPRelay / stopTCPRelay` refactored off the `HelperToolPrivilegeClient` downcast.** Kernel code was doing `privilegeClient as? HelperToolPrivilegeClient` to reach for the socket-backed helper; after this step the concrete class lives in `PlatformMac` and isn't nameable from the kernel. Rewrote both methods to call the `PrivilegeClient` protocol's `execute(_:values:)` only, with the `AppleScriptPrivilegeClient` fallback throwing `PrivilegeClientError.executionFailed("Relay commands require the privileged helper")` — which the kernel downgrades to an info log. User-visible behaviour unchanged. Also not anticipated in the pre-audit.
5. `**ProxyCredentials` + `CredentialManagerError` extracted** into a new kernel file `Sources/ConduitCore/Security/ProxyCredentials.swift`. These were nested inside `CredentialManager.swift`; with the concrete moving to `PlatformMac`, `ProxyAuth` and the kernel-side `CredentialProvider` / `InMemoryCredentialProvider` lost visibility. Extract-first-then-move is the clean fix, matching the ProxyPAC move's `PACTypes.swift` pattern.

Combined impact: three new kernel files not in the original plan (`VPNStateFuser.swift`, `TunnelResolverApplying.swift`, `ProxyCredentials.swift`), one new kernel file at the pre-audited spot (`InMemoryCredentialProvider.swift`), one new PlatformMac file at the pre-audited spot (`HelperPrivilegeClient.swift`), and one reverted move (`CorporateDefaults`). Every deviation traces to the same root cause: **the pre-audit enumerated kernel-side constructions of PlatformMac types, but missed kernel-side storage of them and kernel-side references to private types bundled in a moving file.** The next step's pre-audit should grep both (a) `someConcrete(` constructions and (b) `: SomeConcrete\b` stored-property / parameter types.

Exit criteria (as verified):

- `swift build` green; `swift test` runs 730 tests, 3 skipped, 0 failures (same count as the ProxyPAC move — this step changed no behaviour).
- `rg '^import Security$|^import SMAppService$|^import UserNotifications$|^import SystemConfiguration$|^import Network$|^import ServiceManagement$' Sources/ConduitCore` → 0 matches.
- `rg 'Process\(' Sources/ConduitCore` → 0 matches. (`CommandRunner.runPrivilegedShellScript` + `CommandRunner.run` both gone from the kernel.)
- `Package.swift`: `PlatformMac` appears only under the target declaration itself, `Conduit` (app), `pm-vpn-check`, and the test target. `pm-proxy`, `pm-sim`, `pm-tunnel`, `pm-dns`, `pm-auth-check`, and `ConduitHelper` do not list it.

#### Revisit notes (pre-move audit, 2026-04-21)

Four architectural questions were revisited before the PlatformMac move started. The answers changed the plan above; they are recorded here so a future reader can see the "what was considered and why this was picked" for each:

1. `**CredentialProvider` name is terminal.** An earlier draft named this step's protocol `ProxyAuthCredentialSource`, promising a later step would rename it to `CredentialProvider`. The rename would have been a mechanical sed pass across ~6 call sites and zero semantic work — discarded. Protocol lands as `CredentialProvider` here; a later step widens the surface (per-upstream keying, a setter) without touching the name.
2. `**InMemoryCredentialProvider` lives in `ConduitCore/Security/`, not `ProxyAuth`.** The earlier draft put the default impl in `ProxyAuth` alongside `AuthenticatorFactory`. Wrong fit: credential *storage* is a kernel-value-types concern (matches where `ProxyCredentials` and `CredentialManager` live today); auth *use* (turning a credential into an NTLM/Negotiate token) is `ProxyAuth`'s job. Placing the in-memory default next to the value type keeps the semantic boundary clean and lets `pm-proxy` / `pm-tunnel` (which already link `ConduitCore`) use it without adding a `ProxyAuth` dependency just for the fallback case.
3. **No `PACFetcher` protocol.** The earlier draft proposed a kernel protocol + two impls (`URLSessionPACFetcher` + `CurlPACFetcher`) to resolve the ProxyPAC-move `CommandRunner.run` carryover. Discarded: `PACResolver.init` already accepts an `insecureFetcher:` closure, so the extension point exists. This step changes the default to URLSession-only and lets `AppState` inject a curl-backed closure for the ATS-bypass case. One protocol fewer, one maintenance surface fewer.
4. `**pm-vpn-check` + `pm-auth-check` added to the target matrix.** They had been missing from the original matrix. `pm-vpn-check` constructs `VPNStatusMonitor` directly (by design — it's a diagnostic that exercises the SCDynamicStore production path) and gains `PlatformMac` at this step. `pm-auth-check` uses `import GSS` at the executable level without referencing `ProxyAuth`'s concrete types; stays `ConduitCore`-only.

#### Known redundancies (post-move cleanup, not blocking)

Both items below were revisited after the PlatformMac move shipped and slotted into the rename + abstractions shape — see those sections below for the resolution. Kept here for traceability of how the decisions were made.

- **Three `NIOLockedValueBox<ProxyConfig>` mirrors.** `ProxyOrchestrator` has an internal `ProxyConfigBox` (pre-existing); the ProxyAuth move added independent mirrors in `AppState` and `pm-proxy` for the authenticator factory to read from NIO event loops. Three boxes of the same state. **Resolved in the abstractions step** as a stored `package let configSnapshotProvider: @Sendable () -> ProxyConfig` on the orchestrator (one closure allocated at init, captured by callers; AppState + pm-proxy drop their boxes). Decision against the original "later cleanup" plan: the consolidation is small (~−35 LOC), self-contained, and touches the same call sites as the abstractions step's `CredentialProvider` widening — bundling them avoids two passes over `AuthenticatorFactory`'s caller surface. CI grep enforces the singleton invariant: `rg 'NIOLockedValueBox<ProxyConfig>' Sources/` must return exactly one match.
- **Rename/abstractions ordering revisit.** The original plan put the `ConduitCore → ProxyKernel` rename in the final step (after the LogSink / CredentialProvider work) with a "rename-or-reorganize" decision at the end of the preceding step. **Resolved by flipping the order**: the rename + `Abstractions/` reorganization (mechanical sed, ~67 import-line edits) goes first, the substantive abstractions go last. Rationale: the abstractions step introduces 2–4 new files (`LogSink.swift`, widened `CredentialProvider.swift` adjustments, possibly `StandardLogSinks.swift`) — landing them at their final post-rename paths avoids a second move. The 21-callsite `LogSink` refactor also reads more cleanly without `import ConduitCore → import ProxyKernel` noise mixed into the same diff. The "reorganize-without-rename" middle option (`Sources/ConduitCore/Abstractions/`) was discarded — pays the file-move cost without the clarity dividend.

### Step 5 — Rename `ConduitCore` → `ProxyKernel`; reorganize protocols into `Abstractions/` (shipped 2026-04-22)

Pure mechanical rename + directory reorganization. No behavior change. No new abstractions. No widening of existing protocols. The substantive abstraction work is the next step.

This is the inverse of the original plan (where the abstractions came first and the rename last). Flipped at the design review after the PlatformMac move — see "Known redundancies → Rename/abstractions ordering revisit" above for the rationale. Net of the flip: the abstractions step's new files land directly at their final paths, the 21-callsite `LogSink` refactor reads cleanly without rename noise interleaved.

#### Pre-audit

- `**import ConduitCore` count**: 41 in `Sources/`, 26 in `Tests/` — 67 mechanical replacements. Plus 4 prose references in `docs/` and `roadmap-v2.md` (preserved verbatim where they describe history; updated where they describe the post-split shape). Verified via `rg -l '^import ConduitCore' Sources Tests | wc -l`.
- **String-literal `ConduitCore` references**: only intentional ones survive — none in log category names (those are `LogCategory` enum cases), none in bundle IDs (those reference `io.github.srps.Conduit`, the app bundle), none in persisted file paths (those are under `~/Library/Application Support/Conduit`, also the app bundle). Verified via `rg 'ConduitCore' Sources Tests | rg -v '^import '`.
- **Existing protocol files to relocate into `Abstractions/`** (six files containing eight protocols):
  - `Sources/ConduitCore/Proxy/ProxyAuthenticator.swift` → `Sources/ProxyKernel/Abstractions/ProxyAuthenticator.swift`
  - `Sources/ConduitCore/Proxy/PacEvaluator.swift` (contains `PacEvaluator` + `PacScriptEvaluating`) → `Sources/ProxyKernel/Abstractions/PacEvaluator.swift`
  - `Sources/ConduitCore/Proxy/TunnelResolverApplying.swift` → `Sources/ProxyKernel/Abstractions/TunnelResolverApplying.swift`
  - `Sources/ConduitCore/Network/VPNStatusObserving.swift` → `Sources/ProxyKernel/Abstractions/VPNStatusObserving.swift`
  - `Sources/ConduitCore/Security/CredentialProvider.swift` → `Sources/ProxyKernel/Abstractions/CredentialProvider.swift`
  - `Sources/ConduitCore/System/PrivilegeClient.swift` → `Sources/ProxyKernel/Abstractions/PrivilegeClient.swift`
  After the move, `Sources/ProxyKernel/System/` contains zero files and gets deleted; the only occupant after the PlatformMac move was `PrivilegeClient.swift`. `Sources/ProxyKernel/Security/` keeps `ProxyCredentials.swift` + `InMemoryCredentialProvider.swift` (kernel value type + headless-daemon default). `Sources/ProxyKernel/Network/` keeps the kernel-clean network code (relays, monitors-as-protocols are now in `Abstractions/`).
- **Pre-existing import-fence violation** carried in by `Sources/ConduitCore/Support/Logging.swift`: `import Combine` for `AppLogStore`'s `ObservableObject`/`@Published`. The rename does **not** fix this — the file is renamed-in-place to `Sources/ProxyKernel/Support/Logging.swift` with the violation intact. The fix lands in the next step when `AppLogStore` moves to the app target. Documented here so this step's post-rename grep is honest about its one remaining miss.

#### Ordered task list

1. `**git mv Sources/ConduitCore Sources/ProxyKernel`.** Single-commit move; preserves git history per file.
2. **Mechanical import sed**: `rg -l '^import ConduitCore' Sources Tests | xargs sed -i '' 's/^import ConduitCore$/import ProxyKernel/g'`. Verified via grep that the rg output count matches the post-sed change count.
3. **Create `Sources/ProxyKernel/Abstractions/`** and `git mv` the six protocol files into it (per pre-audit list). Update no contents — package access stays `package`, no signature changes. Delete the now-empty `Sources/ProxyKernel/System/` directory.
4. `**Package.swift**`: rename the target (`name: "ProxyKernel"`, `path: "Sources/ProxyKernel"`); rename the product (`.library(name: "ProxyKernel", targets: ["ProxyKernel"])`); update every dependency reference in `ProxyAuth`, `ProxyPAC`, `PlatformMac`, `pm-proxy`, `pm-sim`, `pm-tunnel`, `pm-dns`, `pm-vpn-check`, `pm-auth-check`, `ConduitHelper`, `Conduit`, and `ConduitTests` from `"ConduitCore"` to `"ProxyKernel"`. Delete the step-by-step comment block (it no longer describes the current state). Delete the stub `ProxyKernel` target declaration from the first step (the renamed-from-Core target now occupies that name).
5. **Delete `Sources/ProxyKernel/Stub.swift`** if it survived from the first step. (The stub typealias was specifically for the empty-target placeholder; the renamed target inherits Core's actual contents.)
6. **Doc updates** (the bounded set, not a global find-replace):
  - `AGENTS.md` § Architecture: replace `Sources/ConduitCore/` with `Sources/ProxyKernel/`; the import-fence rule already names `ProxyKernel` correctly. Preserve the historical note about the split.
  - `README.md`: update target-name references in any architecture summary; preserve historical references.
  - `ROADMAP.md`: update the rename + abstractions entries (separately, see ROADMAP changes); preserve the chronological "Done" log verbatim.
  - `docs/design-module-split.md`: this file. Update the Target Module Graph section's prose where it describes `ConduitCore` as the current state; the matrix already reads `ProxyKernel`. Preserve every mention of `ConduitCore` inside the earlier-step sections (those describe what shipped under the old name).
  - `roadmap-v2.md`: do not edit — it's a historical plan document and should keep its original target names.
  - `docs/architecture.md`: not a stub — describes the pre-split single-`ConduitCore` shape and is no longer accurate after the rename. Add a status banner pointing readers at `README.md` § Architecture + `docs/design-module-split.md`; defer the substantive rewrite to after the abstractions step when the final shape (`LogSink`, widened `CredentialProvider`, `Sources/ProxyKernel/Abstractions/` directory) is locked in. Other in-`docs/` design docs that referenced `Sources/ConduitCore/...` paths (`design-tunnel-dns-override.md`, `design-dns-intercept-transparent-proxy.md`, `design-vpn-flap-resilience.md`) get either a path-translation banner or surgical sed depending on reference count.
7. **Tests** are unchanged in content; only their `import ConduitCore` lines flipped via sed in step 2. The `@testable import` chain (which lists `ConduitCore` in many files) is rewritten by the same sed.

#### Exit criteria

- `swift build` green; `swift test` runs 730 tests, 3 skipped, 0 failures (same count as the PlatformMac move — the rename changes no behavior).
- `rg '^import ConduitCore$' Sources Tests` → 0 matches.
- `rg -l '^import ProxyKernel$' Sources Tests | wc -l` → 67 (matches the pre-sed count).
- `Sources/ProxyKernel/Abstractions/` contains exactly seven files (six existing protocols + the directory's `README.md`-style header comment in one of them, optional). No protocol file lives outside `Abstractions/`. Verified by `find Sources/ProxyKernel -name '*.swift' | xargs rg -l '^package protocol' | rg -v Abstractions/` returning 0 matches.
- `Package.swift` declares one library product named `ProxyKernel`; the previous `ConduitCore` target name appears nowhere in `Package.swift`.
- `rg 'ConduitCore' Sources Tests` → 0 matches outside historical-context comments (which are explicitly preserved in this file under the per-step sections).

#### Non-goals for this step

- **No new protocols.** `LogSink` waits for the abstractions step. The "introduce abstractions" framing of the original plan for this step is entirely the next step's concern now.
- **No widening of `CredentialProvider`.** Today's narrow shape (one method, `ProxyConfig`-keyed) survives this step verbatim; the next step widens it.
- **No `Logging.swift` split.** The Combine import survives this step inside the renamed file; the next step fixes it by moving `AppLogStore` to the app target.
- **No `NIOLockedValueBox<ProxyConfig>` consolidation.** Three mirrors survive this step; the next step collapses them via `ProxyOrchestrator.configSnapshotProvider`.
- **No CI grep additions.** The fence-enforcing greps (e.g. `import Security` in `Sources/ProxyKernel`) become valuable after the abstractions step when `AppLogStore` is gone and the kernel is fully fence-clean. Adding them here would flag the known `Combine` violation as a build break.
- **No behavior change.** Period. If `swift test`'s test count differs from 730 / skip count differs from 3, this step changed something it shouldn't have.

#### Expected scope

~67 import-line edits + 6 file moves + 11 Package.swift dep references + 4 doc files updated. Single PR, ~150–250 lines of net diff (most concentrated in `Package.swift` + the doc updates; the source files are pure moves with zero content change).

#### Shipped (2026-04-22)

- **97 import-line edits** (not 67 — the pre-audit counted bare `import ConduitCore` only and missed `@testable import ConduitCore` in 55 test files; combined was 42 bare + 55 testable). One-shot sed via `rg -l '^(@testable )?import ConduitCore$' Sources Tests | while read f; do sed -i '' -E 's/^(@testable )?import ConduitCore$/\1import ProxyKernel/' "$f"; done`. Post-sed counts verified: 42 bare-Kernel + 55 testable-Kernel + 0 remaining-Core.
- **6 protocol files moved into `Sources/ProxyKernel/Abstractions/`** as planned — `ProxyAuthenticator`, `PacEvaluator`, `TunnelResolverApplying`, `VPNStatusObserving`, `CredentialProvider`, `PrivilegeClient`. The now-empty `Sources/ProxyKernel/System/` directory was removed.
- `**Sources/ConduitCore/` directory removed**; `Sources/ProxyKernel/` is now the canonical kernel directory, with the same six subdirectories (`Models`, `Network`, `Proxy`, `Security`, `Support`, plus the new `Abstractions`).
- `**Package.swift`**: `ProxyKernel` target now points at `Sources/ProxyKernel` and inherits the `ConduitShared` + NIO dependencies that the renamed-from-Core target had; the stub `ProxyKernel` target from the first step was deleted (the rename consumes that name); the library product flipped from `name: "ConduitCore"` to `name: "ProxyKernel"`; 11 dependency references across `ProxyAuth`, `ProxyPAC`, `PlatformMac`, `pm-proxy`, `pm-sim`, `pm-tunnel`, `pm-dns`, `pm-vpn-check`, `pm-auth-check`, `ConduitHelper`, `Conduit`, and the test target updated.
- **Doc updates**: `AGENTS.md` § Architecture lists the four targets explicitly with their dep relationships; `README.md` § Architecture replaces the old `ConduitCore` ASCII diagram with the post-split executable / consumer matrix; this design doc gets a status banner at the top + a "shipped" subsection for this step. `roadmap-v2.md` § 2.2 gets a forward-pointer to ROADMAP / this doc as the as-shipped source of truth (the historical plan body preserved verbatim). Three subsidiary design docs got file-path updates discovered during review: `docs/design-tunnel-dns-override.md` (3 surgical sed replacements; `TunnelResolverManager` updated to its PlatformMac home), `docs/design-dns-intercept-transparent-proxy.md` (1 surgical sed), `docs/design-vpn-flap-resilience.md` (~15 references — added a path-translation status banner because the doc is finished + the cost of mechanical sed exceeds the clarity gain). `docs/architecture.md` got a status banner explaining the doc predates the split; substantive rewrite deferred to after the abstractions step.
- **13 string-literal `ConduitCore` references survive in `Sources/`** (in comments describing where files used to live). These are the explicit "preserve historical-context comments" exit criterion. Verified via `rg 'ConduitCore' Sources Tests | rg -v '^[^:]+:[0-9]+:[ \t]*//' | wc -l` → 0 (every remaining mention is inside a line comment).
- **Build green; 730 tests, 3 skipped, 0 failures** — same count as the PlatformMac move. Rename verified non-behavior-changing.

#### Deviations from the plan (shipped 2026-04-22)

1. **97 import-line edits, not 67.** The pre-audit grep for `^import ConduitCore$` missed `@testable import` lines (55 of them in the test target). The sed pattern was widened to `^(@testable )?import ConduitCore$` for the actual run. No behavioral consequence; the count discrepancy is a pre-audit accuracy issue. Lesson for future renames: grep the union of `^(import|@testable import)`  patterns when counting an import sed footprint.

### Step 6 — `LogSink` + widened `CredentialProvider` + `configSnapshotProvider` consolidation + `ProxyConfig.testFixture()` (shipped 2026-04-22)

The substantive abstraction step — the protocol-introduction phase that the rename step originally claimed. Three independent refactors land in one PR because they share callers (the auth factory wiring touches the credential provider AND the config snapshot; the kernel files touched by `LogSink` overlap with those touched by the orchestrator's parameter-list churn). Each is small enough to land on its own; bundling avoids three passes over the same files.

`**PlatformIntegration` is intentionally deferred.** The evidence gathered after the PlatformMac move (`ProxyOrchestrator` references zero PlatformMac concretes; AppState owns every platform side-effect call site) showed the composite has no kernel caller today. It re-enters the plan when the later control-plane work lands and the orchestrator (or a `DaemonHost`) needs to drive platform side-effects on reload commands. Designing it now against speculative callers risks the god-protocol antipattern that the PlatformMac move's three-method protocols deliberately avoided.

#### Pre-audit (applying the earlier lesson: grep both constructions and storage)

The PlatformMac-move retrospective established the grep pattern: `someConcrete(` *constructions* AND `: SomeConcrete\b` *stored-property / parameter types*. Applied to this step's surface:

- `**AppLogStore` reaches 15 kernel files** (not the design doc's earlier "21 callsites" figure — that double-counts files with multiple init params; the file count is what matters for the refactor). Stored-property + init-parameter combined audit:
  - `Sources/ProxyKernel/Proxy/`: `HTTPProxyHandler`, `CONNECTHandler`, `ConnectionPool`, `LocalProxyServer`, `SOCKS5Server`, `ProxyOrchestrator`, `TunnelForwarder` (×3), `PACRoutingEngine`, `TransparentTCPProxy` (×2), `TunnelDNSResponder` (×2)
  - `Sources/ProxyKernel/Network/`: `UpstreamProber`, `DirectConnectDetector`, `AutoRecovery`, `LocalDNSForwarder` (×2)
  - `Sources/ProxyKernel/Support/Logging.swift`: the file itself (moves out)
  Verified via `rg -l '\bAppLogStore\b' Sources/ProxyKernel`. Each occurrence is either an init parameter, a stored `let logger: AppLogStore`, or a function-parameter usage in a `Recording`* test double.
- `**AppLogStore` reaches 1 PlatformMac file**: `EnvironmentManager.apply(...)` and `clear(...)` take `logger: AppLogStore?` as an optional method parameter. Doesn't move; gets retyped to `(any LogSink)?` along with the kernel sites.
- `**AppLogStore` reaches the app target** at the construction site (`AppState.swift:73`) and at the SettingsView "Diagnostic log" export. Construction stays in app target post-move; the export reads `entries` directly (which stays a `package private(set) var [LogEntry]` — protocol doesn't expose the buffer).
- `**AppLogStore` storage in PlatformMac concretes**: `SystemProxyManager`, `SystemDNSManager`, `EnvironmentManager`, `LoginItemManager`, `TunnelResolverManager` all take `AppLogStore?` parameters on their methods (per the design doc Pillar one). After this step these become `(any LogSink)?` — same shape, looser type. PlatformMac links ProxyKernel today, so the `LogSink` protocol is visible.
- `**CredentialManager` (concrete) reached from non-PlatformMac targets**: `AuthenticatorFactory.swift` (ProxyAuth) takes `any CredentialProvider` already (after the PlatformMac move); the widening changes the protocol, the factory closure picks up the new signature, no new cross-target reference. AppState references the concrete `CredentialManager` for `saveHash` / `clear` / `hasSavedCredentials` — those methods stay on the concrete (not on the widened protocol), so the AppState surface is unchanged.
- `**NIOLockedValueBox<ProxyConfig>` storage** (the consolidation target). Verified by `rg 'NIOLockedValueBox<ProxyConfig>' Sources/`:
  - `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift:108` — the orchestrator's internal `ProxyConfigBox` (canonical).
  - `Sources/Conduit/App/AppState.swift:101` — AppState's mirror, fed via `$config` Combine sink.
  - `Sources/pm-proxy/PMProxy.swift:71` — pm-proxy's mirror, fed via SIGHUP reload.
  All three exist for one reason: `credentialBasedAuthenticatorProvider` needs a `@Sendable () -> ProxyConfig` closure callable from NIO event loops (off MainActor). The orchestrator's `package var config: ProxyConfig` is `@MainActor`-isolated; can't be read from a NIO loop.
- `**ProxyConfig.corporateDefault()` test sites**: 110 across `Tests/ConduitTests/`. The vast majority don't depend on vendor-specific values — they just need a populated valid config. This step adds `ProxyConfig.testFixture()` (vendor-neutral) but does **not** migrate any existing call site; migration is opportunistic during unrelated test edits, completed by the later OSS-prep work when `corporateDefault()` becomes a JSON loader.

#### Carryovers from the rename step

- `**Sources/ProxyKernel/Support/Logging.swift` still imports `Combine`** because `AppLogStore` is still in it. This step's first task is the file split that resolves this.

#### Three independent refactors, one PR

Each block below is internally self-contained and could land alone; bundling avoids three passes over `AuthenticatorFactory`, `ProxyOrchestrator.init`, and the 15 NIO files.

##### Refactor A — `LogSink` introduction + `Logging.swift` split

The `LogSink` protocol shape locks in the perf characteristics discussed in the later design review:

```swift
// Sources/ProxyKernel/Abstractions/LogSink.swift

package protocol LogSink: Sendable {
    /// Lower bound for which levels are worth constructing a message for.
    /// Implementations gate this on their loudest enabled output (e.g.
    /// `AppLogStore` returns `min(minStderrLevel, minBufferedLevel)`).
    /// Read at most a handful of times per request — the existential cost is
    /// dwarfed by the saved string-interpolation work when filtered out.
    var minLevel: LogLevel { get }

    /// Called from any thread / any actor. Implementations decide their own
    /// threading: `ConsoleLogSink` writes inline; `AppLogStore` hops to
    /// MainActor for its ring buffer; daemons may pipe to a background queue.
    /// Implementations MUST NOT assume the calling thread.
    func log(_ level: LogLevel, _ message: String, category: LogCategory)
}

extension LogSink {
    /// Convenience for the frequent NIO call site pattern: skip the entire
    /// log call (including String interpolation) when filtered out at the sink.
    /// This is where most of the daemon-side allocation savings come from —
    /// `pm-proxy --status-interval 2` stops paying for `.debug` message
    /// interpolations that today are built then discarded inside AppLogStore.
    @inlinable
    package func log(
        _ level: LogLevel,
        category: LogCategory = .general,
        _ message: @autoclosure () -> String
    ) {
        guard level >= minLevel else { return }
        log(level, message(), category: category)
    }
}
```

Two stock implementations land alongside the protocol (`Sources/ProxyKernel/Support/StandardLogSinks.swift`):

```swift
package struct ConsoleLogSink: LogSink {
    package let minLevel: LogLevel
    package init(minLevel: LogLevel = .notice) { self.minLevel = minLevel }
    package func log(_ level: LogLevel, _ message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        FileHandle.standardError.write(Data((entry.formatted() + "\n").utf8))
    }
}

package struct DiscardingLogSink: LogSink {
    package init() {}
    package var minLevel: LogLevel { .error } // anything past .error is discarded too — never appends
    package func log(_: LogLevel, _: String, category _: LogCategory) {}
}
```

Note: `DiscardingLogSink.minLevel` returns `.error` (the highest case) so the `@autoclosure` extension always short-circuits; the explicit method is unreachable in practice. This matters because tests / pm-sim that wire `DiscardingLogSink` get zero per-call cost — not even the message interpolation runs.

**File-level reorganization** (drives the Combine fence-violation fix):

- `Sources/ProxyKernel/Support/Logging.swift` (the messy file, ~140 LOC, mixes value types + Combine + @MainActor + file I/O + protocol intent) splits into:
  - `Sources/ProxyKernel/Models/LogTypes.swift` — `LogEntry`, `LogLevel`, `LogCategory` value types (Foundation only). One reason to change: domain model.
  - `Sources/ProxyKernel/Abstractions/LogSink.swift` — protocol + `@autoclosure` extension. One reason to change: cross-target seam shape.
  - `Sources/ProxyKernel/Support/StandardLogSinks.swift` — `ConsoleLogSink` + `DiscardingLogSink`. One reason to change: stock implementation behavior.
  - `Sources/Conduit/App/AppLogStore.swift` — the `@MainActor` `ObservableObject` ring buffer + file logger + `LogSink` conformance via the existing nonisolated `bridge(_:_:category:)` method. One reason to change: app-side log presentation.
  This is the surgical split the rename step's "no behavior change" rule defers to this step. Post-split, `Sources/ProxyKernel/` does **not** import `Combine` anywhere — the fence-enforcing CI grep can finally light up.

**Call-site refactor** (the bulk of the diff):

- 15 kernel files retype `let logger: AppLogStore` → `let logger: any LogSink` (or the corresponding init parameter). Mechanical: the call surface used by every caller is `logger.log(.notice, ..., category: .x)` which is satisfied identically by both types.
- The optional-`AppLogStore?` parameter in PlatformMac's System* managers becomes `(any LogSink)?`. Same shape, looser type.
- `RecordingLogSink` test double is added in `Tests/ConduitTests/Helpers/`: a Sendable struct that captures into a `NIOLockedValueBox<[LogEntry]>` for assertion. Mirrors the existing `RecordingPrivilegeClient` pattern.
- Tests that construct `AppLogStore()` purely for log inspection switch to `RecordingLogSink`. Tests that exercise the @MainActor ring-buffer behavior (`AppLogStoreTests`, the SwiftUI log view tests) keep `AppLogStore`.

##### Refactor B — Widened `CredentialProvider`

Today's narrow shape:

```swift
package protocol CredentialProvider: Sendable {
    func credentials(for config: ProxyConfig) throws -> ProxyCredentials
}
```

Widened shape:

```swift
package protocol CredentialProvider: Sendable {
    /// Return saved credentials for `upstream`. Returns `nil` (not throws) when
    /// none exist — that's the common case during Kerberos-only handshakes
    /// where the caller falls back without ceremony. Throws only for actual
    /// storage failures (Keychain ACL denial, decode failure, etc.).
    func credentials(for upstream: UpstreamProxy) throws -> ProxyCredentials?

    /// Persist `credentials` for `upstream`. Idempotent overwrite.
    func setCredentials(_ credentials: ProxyCredentials, for upstream: UpstreamProxy) throws
}
```

Two semantic shifts to call out:

1. **Optional return for the "not found" case.** Today `CredentialManagerError.missingCredentials` is thrown; the auth factory catches that specific error to fall back to Kerberos. Optional + throws-only-for-real-failures matches the call-site semantics directly and saves a try/catch dance on the hot path.
2. `**UpstreamProxy` keying instead of `ProxyConfig` keying.** The protocol no longer presumes a storage shape; conformers derive their own key. Today's `CredentialManager` keys on `"\(config.domain)|\(config.username)|\(config.profileName)"` (two of three fields are identity, one is profile selector). After widening it derives `"\(upstream.host):\(upstream.port)|\(domain)|\(username)"` — per-upstream credentialing — using the active config's identity fields plus the upstream's address.

**Keychain migration** (one-time, lazy, on first access):

- `CredentialManager.credentials(for: upstream)` first probes the new key. If found, returns. If not, probes the old key shape (`"\(domain)|\(username)|\(profileName)"` derived from the active config). If found, re-stores under the new key, deletes the old, returns.
- Migration is per-credential, not per-launch — users who never use a given upstream never trigger that upstream's migration. Users who only use one upstream pay the cost on the first 407.
- A structured `auth.credential_migration` event fires per migration, masked, for telemetry. Verifies migration completed in pilot before the later stricter Keychain ACL changes assume the new key shape.
- `InMemoryCredentialProvider` (kernel-side default) gains a `private let store: NIOLockedValueBox<[UpstreamProxy: ProxyCredentials]>` — `setCredentials` writes, `credentials(for:)` reads. Today's "always throws missingCredentials" behavior is preserved as the default-constructed state (empty store → returns nil for everything).
- `AuthenticatorFactory.credentialBasedAuthenticatorProvider` updates: the closure receives `upstream: UpstreamProxy` (it already does today via its `(String) throws -> ProxyAuthenticator` shape — the `String` is the host; gets reconstructed into an `UpstreamProxy` lookup using the live config's matching upstream entry).

##### Refactor C — `configSnapshotProvider` consolidation + `ProxyConfig.testFixture()`

```swift
package final class ProxyOrchestrator {
    private let configBox: NIOLockedValueBox<ProxyConfig>

    /// Read-only snapshot of the live config, callable from any thread.
    /// Allocated once at init; callers (AppState, pm-proxy) capture the
    /// closure once at startup and pass it to `credentialBasedAuthenticator-
    /// Provider`. Zero allocations per request.
    ///
    /// Invariant: the orchestrator's `config` setter MUST update `configBox`
    /// before running side-effects so the closure never returns a snapshot
    /// older than the in-flight reload.
    package let configSnapshotProvider: @Sendable () -> ProxyConfig

    package init(config: ProxyConfig, ...) {
        let box = NIOLockedValueBox(config)
        self.configBox = box
        self.configSnapshotProvider = { box.current }
        ...
    }

    package var config: ProxyConfig {
        get { configBox.current }
        set {
            configBox.current = newValue   // writer-first; load-bearing
            // ...existing side-effects...
        }
    }
}
```

Caller updates:

- `AppState.init`: drops `private let configBox: NIOLockedValueBox<ProxyConfig>` and the corresponding `$config` Combine sink that fed it. Constructs the orchestrator first, then captures `orchestrator.configSnapshotProvider` to pass into `credentialBasedAuthenticatorProvider`. The init order needs a tiny shuffle (orchestrator constructed before the auth factory closure) — straightforward.
- `pm-proxy/PMProxy.swift`: drops the local `configBox`. The SIGHUP handler now calls `orchestrator.applyConfigChange(newConfig)` and the consolidated box updates as a side-effect of the orchestrator's setter — one source of truth.
- The earlier note about `vpnFlapWindowBox` is unchanged: that box mirrors *two TimeInterval fields*, not the whole config, and lives on for `VPNStatusMonitor`'s `monitorQueue` reads. Different use case, stays.

`ProxyConfig.testFixture()`:

```swift
extension ProxyConfig {
    /// Vendor-neutral populated config for tests that need a valid
    /// ProxyConfig but don't depend on vendor-specific values. Use this for
    /// new tests; existing tests keep `ProxyConfig.corporateDefault()` until
    /// touched. Later OSS-prep work externalizes `corporateDefault()` to JSON;
    /// tests that have migrated to `testFixture()` are unaffected by that change.
    package static func testFixture() -> ProxyConfig {
        ProxyConfig(
            profileName: "test-fixture",
            upstreams: [UpstreamProxy(host: "proxy.example.com", port: 8080)],
            // ...minimum populated valid config...
        )
    }
}
```

Lives in `Sources/ProxyKernel/Models/ProxyConfig.swift` next to the existing `corporateDefault()` factory. Zero test-site migrations land in this step — opportunistic during unrelated test edits.

#### Ordered task list

1. **Add `LogSink` protocol** at `Sources/ProxyKernel/Abstractions/LogSink.swift` (refactor A) and the two stock implementations at `Sources/ProxyKernel/Support/StandardLogSinks.swift`. Build green; `LogSink` is unreferenced.
2. **Add `RecordingLogSink`** at `Tests/ConduitTests/Helpers/RecordingLogSink.swift`. Build green; tests still use `AppLogStore`.
3. **Split `Logging.swift`**: extract `LogEntry`/`LogLevel`/`LogCategory` to `Sources/ProxyKernel/Models/LogTypes.swift`; extract `AppLogStore` to `Sources/Conduit/App/AppLogStore.swift` (with `LogSink` conformance via `bridge`); delete the now-empty `Sources/ProxyKernel/Support/Logging.swift`. Kernel build fails because the 15 callers reference `AppLogStore`.
4. **Retype the 15 kernel callers**: `let logger: AppLogStore` → `let logger: any LogSink`; init params + stored properties + (where present) `RecordingPrivilegeClient`-style test wiring. Build green; tests reference `AppLogStore`-the-construction in `AppState`/test setup unchanged.
5. **Retype PlatformMac call sites**: `EnvironmentManager` + System* managers' `logger: AppLogStore?` parameters → `logger: (any LogSink)?`. Build green.
6. **Migrate test sites that don't need ring-buffer** to `RecordingLogSink`. Single sweep, ~10–15 test files. Build + test green. (Tests that genuinely test `AppLogStore` ring-buffer behavior keep it.)
7. **Widen `CredentialProvider`** (refactor B): update protocol shape; rewrite `InMemoryCredentialProvider` with `NIOLockedValueBox`-backed store; rewrite `CredentialManager.credentials(for: upstream)` with lazy migration; update `AuthenticatorFactory.credentialBasedAuthenticatorProvider` for the new closure signature + Optional return. Build + test green; auth handshake tests cover the new shape.
8. **Add `auth.credential_migration` event kind** + emit from the lazy-migration path. Add a single integration test asserting the migration runs once and the old key is deleted.
9. **Consolidate `NIOLockedValueBox<ProxyConfig>` mirrors** (refactor C): add `configSnapshotProvider` to `ProxyOrchestrator`; drop `AppState.configBox` + `$config` mirror sink; drop `pm-proxy`'s local `configBox`. Init ordering shuffle in AppState. Build + test green.
10. **Add `ProxyConfig.testFixture()`** as a vendor-neutral factory in `Sources/ProxyKernel/Models/ProxyConfig.swift`. No test-site migrations.
11. **CI grep additions** (now that the kernel is fully fence-clean):
  - `rg '^import (Security|SMAppService|UserNotifications|SystemConfiguration|Network|ServiceManagement|JavaScriptCore|GSS|CommonCrypto|Combine|AppKit|SwiftUI)$' Sources/ProxyKernel` must return 0.
    - `rg 'Process\(' Sources/ProxyKernel` must return 0.
    - `[[ $(rg 'NIOLockedValueBox<ProxyConfig>' Sources/ -l | wc -l) -eq 1 ]]` (only the orchestrator's box).
    - `otool -L .build/debug/pm-proxy | rg '(Security|SystemConfiguration|UserNotifications|ServiceManagement)\.framework'` must return 0.
12. **Doc updates**: `docs/architecture.md` (post-split module diagram + protocol surface inventory); `AGENTS.md` § Architecture lists `Sources/ProxyKernel/Abstractions/` as the seam directory and references the CI greps.

#### Exit criteria

- `swift build` green; `swift test` green (730 tests + new credential-migration test = 731). `pm-proxy --port 0 --dns-port 0 --status-interval 2 --state-dir /tmp/x` runs and serves test traffic with a `ConsoleLogSink`.
- All four CI greps from task 11 return 0 / pass the count assertion.
- `Sources/ProxyKernel` does not contain `import Combine` anywhere (the file split removed the last instance).
- `Sources/ProxyKernel/Abstractions/` contains exactly eight files (the seven from the rename step + `LogSink.swift`); no protocol files live outside `Abstractions/`.
- `pm-sim multi-100` shows reduced MainActor task pressure compared to a pre-step baseline (the per-log Task allocations from `AppLogStore.bridge` no longer happen in headless contexts). Capture before/after as a one-time measurement; do not gate CI on the delta (the PR's value isn't perf, it's structural — the perf win is gravy).

#### Non-goals for this step

- **No `PlatformIntegration`.** Deferred to the later control-plane work when the reload path becomes its first real caller. See "New Abstractions § PlatformIntegration (deferred)" below.
- *No per-concern System protocols.** `SystemProxyApplying` / `SystemDNSApplying` / `EnvironmentApplying` / `LoginItemControlling` are tempting because they pattern-match `TunnelResolverApplying`, but they share the same "no kernel caller today" disqualification. Deferred indefinitely.
- **No `NotificationSink`.** Same rule: introduce when the kernel needs it. AppState's notification calls stay direct against `NotificationManager`.
- **No `SecretBytes`.** Later roadmap work; the credential boundaries become visible after this step, but the type itself stays out.
- **No CFNetwork PAC swap.** Later roadmap work; `PacEvaluator` is the seam it lands behind, no additional shaping needed here.
- **No `corporateDefault()` test-site migration.** `testFixture()` lands; migration is opportunistic. The later OSS-prep work finishes the job when externalizing to JSON.
- **No new orchestrator init parameters that take `PlatformMac` concretes.** When the later control-plane work introduces `PlatformIntegration`, the orchestrator gains exactly that one parameter; until then the orchestrator's init signature is closed for new platform-side dependencies.
- **No widening of `LogSink` past the 1-method-plus-`minLevel`-property shape.** A future structured-event sink (per STYLE rule 3's eventual convergence with logging) is a separate `EventSink` protocol, not a `LogSink` widening.

#### Expected scope

~~250–400 lines of net diff. Largest concentrations: the 15 kernel-file LogSink retypes (~~30 lines each = ~~450 lines, but most are 1–2 line changes), the `Logging.swift` 4-way split (~~140 lines moved + small reorg), the widened `CredentialProvider` + migration logic (~~80 lines new + 40 lines updated in `AuthenticatorFactory` + `CredentialManager`), the consolidation (~~−35 lines net negative), `testFixture()` (~~15 lines), CI script additions (~~10 lines).

#### Revisit notes (locked in before this step starts)

These are the design decisions made during the architecture review after the PlatformMac move. Each was a real fork; the rationale is preserved here so a future reader sees what was considered and why.

1. `**LogSink.minLevel` as a protocol-required property + `@autoclosure` extension method** — instead of just the simple `func log(_:_:category:)` from the original design doc draft. The autoclosure pattern is canonical (`os.Logger`, `swift-log`); the minLevel query lets the call site skip String interpolation when filtered out. For `pm-proxy --status-interval 2` and `pm-sim multi-100`, this eliminates the per-`.debug`-log message-interpolation cost that today's code pays-then-discards inside `AppLogStore`. The cost is one read-only property per conformer (5 lines of code).
2. **Stored `let configSnapshotProvider`, not a computed `var`.** A computed property would allocate a fresh closure per access — measurable overhead given the auth factory invokes it on every upstream 407. The stored let allocates one closure at init; AppState + pm-proxy capture it once at startup. Zero per-request cost.
3. `**CredentialProvider` returns `Optional`, not `throws .missingCredentials`.** Today's throws-on-missing pattern bleeds error-handling overhead into the `pacRoutingEngine`-style "no creds, fall back to Kerberos" hot path. Optional + throws-for-real-failures matches semantic intent and is faster.
4. `**UpstreamProxy` keying for `CredentialProvider`, not `ProxyConfig` keying.** Per-upstream credentialing is a real product feature (different upstreams may want different credentials in tunnel-style or gateway-style deployments). The protocol is storage-agnostic — conformers pick their key shape. Today's `CredentialManager` migrates lazily; pilot before the later stricter Keychain ACL work builds on the new key shape.
5. `**ProxyConfig.testFixture()` is vendor-neutral, not a `corporateDefault()` alias.** An alias would defer the "what's actually a vendor-specific test fixture vs a vendor-neutral one?" question that the later OSS-prep work must answer anyway. Vendor-neutral makes that job mechanical: `corporateDefault()` becomes a JSON loader; the few remaining call sites are all the genuine vendor-specific tests, which is correct. The cost here is one factory function — no migration required.
6. **All three refactors in one PR.** Separate PRs would each pass over `AuthenticatorFactory.swift` + `ProxyOrchestrator.init` + the kernel LogSink callers. Bundling shares the diff over those files exactly once. The PR is large but linear; the alternative (three serial PRs) would land slower and read worse — and would force three separate review cycles over the same caller surface.

#### Shipped (2026-04-22)

- **Refactor A landed as planned, with three implementation discoveries that shaped the final shape:**
  - `AppLogStore.log` (the new LogSink-conformance method) reads `Thread.isMainThread` and uses `MainActor.assumeIsolated` for the synchronous fast path when called from main, falling back to `Task { @MainActor in ... }` only when off-main. The earlier `@MainActor func log` had synchronous semantics that LoggingTests + the 14 AppState callers relied on; routing every call through a Task hop would have broken assertion-after-log patterns. The thread check is ~1 ns; uniform `Task` would have been simpler but observably wrong. (Caught by LoggingTests.testFileLoggingCreatesFile during this refactor's first test run.)
  - `AppLogStore.minStderrLevel` and `minBufferedLevel` moved behind `NIOLockedValueBox` so the LogSink-required `nonisolated var minLevel` can read them without crossing actor isolation. The earlier properties were `@MainActor`-isolated stored vars; making them nonisolated by adding the box is concurrency-safe (one lock acquire per filter check, dwarfed by the file-write or Task-hop the call usually triggers).
  - File-logging behavior changed: previously the file write was unconditional (ignored level filters); now it respects `min(stderrLevel, bufferedLevel)`. The earlier quirk wasn't documented anywhere and caused LoggingTests to need a `minBufferedLevel = .info` setter before the assertion. The new behavior is consistent (file is one of three outputs, all gated by the same filter).
- **Refactor B took a simpler shape than the original plan called for. Per the locked-in decision (UI stays profile-keyed for this step; per-upstream UX is future work), `CredentialManager` keeps the existing Keychain key shape `"\(domain)|\(username)|\(profileName)"` unchanged — no migration code. The widened protocol's `UpstreamProxy` parameter is ignored by the conformance methods; every upstream returns the same profile-level credential, preserving prior semantics. The `auth.credential_migration` event + integration test from the original plan are therefore N/A; if/when per-upstream UX lands, that's when the migration code + test get added.**
  - The one new wiring requirement: `CredentialManager.init(identityProvider:)` takes a `@Sendable () -> (domain, username, profileName)` closure to derive identity for the protocol-required methods (which take `UpstreamProxy`, not `ProxyConfig`). AppState wires this from the orchestrator's `configSnapshotProvider` (refactor C). Tests pass a fixed-identity closure.
- **Refactor C consolidation required a small additional change to `ProxyOrchestrator`:** the `authenticatorProvider` stored property changed from `let` to `var` with a `package func setAuthenticatorProvider(_:)` setter. This resolves the chicken-and-egg between "orchestrator init takes the auth factory" and "auth factory captures `orchestrator.configSnapshotProvider`" — AppState constructs the orchestrator with `authenticatorProvider: nil`, then sets it post-init. The orchestrator's lazy proxy/tunnel vars capture the closure at first access (which is `startProxy()` time, well after AppState's init completes the wiring), so the pre-init nil is never observed by the lazy-init path.
- **Test infrastructure landed three categories:**
  - `RecordingLogSink` lives kernel-side in `Sources/ProxyKernel/Support/StandardLogSinks.swift` (not in `Tests/Helpers/` as the plan called for). The reason: pm-sim's `directModeSilence` scenario was already constructing `AppLogStore` to read `entries` for severity assertions; pulling it into the kernel lets pm-sim use it without a Tests-target dependency.
  - 21 plumbing-only test files swapped `AppLogStore()` → `DiscardingLogSink()`. 3 content-asserting test files swapped to `RecordingLogSink(minLevel: .debug)` + `.entries` → `.entries()` (RecordingLogSink uses a method, not a property, for the snapshot). 1 test file (`LoggingTests`) that exercises `AppLogStore`-specific behaviour added `@testable import Conduit` and stays on the concrete class.
  - `KeychainAccessTests` updated for `CredentialManager.init(identityProvider:)`. No new test added.
- **6 daemon/sim files swapped `AppLogStore()` → `ConsoleLogSink(minLevel:)`** for synchronous stderr output without MainActor pressure: `pm-proxy`, `pm-dns`, `pm-tunnel`, `pm-sim/Harness.swift`, `pm-sim/OrchestratorScenarios.swift` (×2), `pm-sim/VPNFlapScenarios.swift` (×2). One pm-sim site (`directModeSilence`) used `RecordingLogSink` instead. The earlier `minBufferedLevel = .info` setters in pm-sim were dead code (scenarios assert on `orchestrator.eventLog`, not the logger's buffer); deleted.
- **All four CI greps pass:**
  - `rg '^import (Security|SMAppService|UserNotifications|SystemConfiguration|Network|ServiceManagement|JavaScriptCore|GSS|CommonCrypto|Combine|AppKit|SwiftUI)$' Sources/ProxyKernel` → 0 (the Combine carryover from the rename step is fixed)
  - `rg 'Process\(' Sources/ProxyKernel` → 0
  - `rg 'NIOLockedValueBox<ProxyConfig>' Sources/ -l | wc -l` → 1 (only the orchestrator's box; AppState + pm-proxy mirrors gone)
  - `otool -L .build/debug/pm-proxy | rg '(Security|SystemConfiguration|UserNotifications|ServiceManagement)\.framework'` → 0
- **730 tests, 3 skipped, 0 failures** — same count as the rename step. The credential-migration test was N/A and not added; total test count unchanged.

#### Deviations from the plan (shipped 2026-04-22)

1. **No Keychain key migration in CredentialManager** (per refactor B's locked-in decision). The earlier key shape `"\(domain)|\(username)|\(profileName)"` preserved; protocol's `UpstreamProxy` parameter is ignored by the conformance methods. Migration code + the planned `auth.credential_migration` event + the integration test are deferred until per-upstream credential UX lands.
2. `**MainActor.assumeIsolated` fast path on `AppLogStore.log`** — the original plan's "always Task hop" was simpler but broke synchronous-assertion test patterns. The thread-check + assumeIsolated branch preserves prior semantics for MainActor callers while keeping the protocol-required nonisolated entry point valid for kernel callers.
3. `**AppLogStore` filter levels behind `NIOLockedValueBox`** — the earlier `@MainActor`-isolated stored properties don't survive the new `nonisolated var minLevel` requirement. Box is the cleanest concurrency-safe replacement; the per-call lock acquire is below noise.
4. `**RecordingLogSink` lives kernel-side, not in `Tests/Helpers/**` — pm-sim's `directModeSilence` scenario needs it without a Tests dependency.
5. `**ProxyOrchestrator.authenticatorProvider` changed from `let` to `var` + setter method** — required to break the init chicken-and-egg with `configSnapshotProvider`. Lazy-init capture timing makes this safe (lazy vars evaluate at `startProxy()` time, after AppState wiring).
6. **File-logging now respects level filters** in `AppLogStore` — previously it was unconditional. The new behaviour is consistent with stderr/buffer outputs; LoggingTests.testFileLoggingCreatesFile updated to set `minBufferedLevel = .info` explicitly.
7. **Credential-migration integration test not added** — would have tested code that doesn't exist (per deviation #1). Skipped.

## Backward Compatibility

The split is structural; nothing about the runtime, the wire format, the config schema, or the persisted state changes. So "back-compat" here means:

- **Existing call sites in `Sources/Conduit/` (the SwiftUI app) compile.** The app does `let logger = AppLogStore(); orchestrator.init(logger: logger, ...)`. After the abstractions step the orchestrator's stored property type changes to `any LogSink`; `AppLogStore` conforms via its existing `bridge` method; the call site keeps its `logger:` parameter label for friction-zero migration.
- **Persisted files (`~/Library/Application Support/Conduit/config.json`, `saved-dns.json`, etc.) load without migration.** The on-disk schema is `Codable` value types in Kernel; their definition doesn't move.
- **NDJSON event consumers (us, `pm-sim`) see no change.** Event categories, event shapes, and snapshot fields are unchanged.
- **External callers — none exist.** The package has one consumer (this repo) and we control every callsite.

If a third party ever consumes `ProxyKernel` as a library in the future, the public API surface is whatever `package` types we promote to `public` at that point. Today that surface is empty.

## Architecture Notes

### Why this is *not* preparation for Plan B

The split is justified by macOS-only Plan A goals:

- The build-time fence makes "what is portable?" answerable at the file level.
- The dependency graph stops dragging every Apple framework into `pm-proxy`/`pm-sim`/`pm-dns`/`pm-tunnel`.
- Cross-target callsites become protocol-mediated, which is itself a security and testability win (a `RecordingLogSink` in tests is much sharper than `AppLogStore`-with-side-effects).
- The later CFNetwork PAC swap, the daemon promotion, and the `CorporateDefaults` externalization are all easier to land cleanly in an already-split codebase.

If Plan B ever activates, the split is also the precondition for "extract `ProxyKernel` as the protocol layer the Rust port re-implements" — but that's a future benefit, not a present-day justification. The split is justified because today's monolith is in the way of today's roadmap.

### Why "4 targets, not 7" stays the right choice

`[roadmap-v2.md](roadmap-v2.md)` (§2.2) argues for 4–5 targets, not the 7 the original plan listed. After this audit, 4 (or 5 if `ProxyKernel/Tunnels` ever earns its own target) is still right:

- `Models`, `DNS`, `Tunnels`, `Logging` would be additional targets on paper but they don't cross-import Apple frameworks. Splitting them now adds bureaucracy (more target boundaries to maintain, more `package` access widening) without enabling anything we want to do.
- The day one of those subdirectories earns its own target — say, `ProxyDNS` because we want a vendored `pm-dns` daemon that doesn't link the proxy at all — we split it then. The current 4 targets are the minimum that pays for itself in compile-time enforcement.

### Why the import fence belongs in `Package.swift`, not `AGENTS.md`

`AGENTS.md` already states the import fence in prose; the rule is essentially unenforceable while everything is one target. After the abstractions step, the fence is an SPM target boundary: the compiler refuses `import GSS` from a `ProxyKernel` file because `ProxyKernel`'s target doesn't link `GSS`. The `AGENTS.md` rule moves from a review-time check to a build-time invariant — exactly the intent of `[AGENTS.md`'s "if a rule can be enforced by a linter, a test, or a type, move it there and delete it from here"](../AGENTS.md) header.

The `AGENTS.md` rule stays as documentation of intent (so reviewers don't try to add a linker exception that would re-open the fence), but its enforcement is by the build.

### Side-effects-behind-protocols compliance

Every kernel-side cross-target call after the abstractions step goes through a protocol:

- `LogSink` for logging (abstractions step).
- `CredentialProvider` for credentials (introduced narrow at the PlatformMac move, later widened to per-upstream).
- `PacEvaluator` + `PacScriptEvaluating` for PAC (ProxyPAC move).
- `PrivilegeClient` for privileged ops via the helper (pre-split protocol; the PlatformMac move surfaced the kernel/PlatformMac split).
- `ProxyAuthenticator` for upstream auth (pre-split).
- `VPNStatusObserving` for VPN state (pre-split; `FakeVPNStatusObserver` is the test/sim injection).
- `TunnelResolverApplying` for `/etc/resolver/`* writes (PlatformMac move).

System proxy / DNS / env / login-item / notification / activation-preflight calls **stay direct** between `AppState` (which links `PlatformMac`) and the System* managers — those side effects don't cross a kernel boundary today. The composite `PlatformIntegration` protocol re-enters the plan with the later control-plane work when the orchestrator (or a `DaemonHost`) needs to drive them on `pmctl reload` commands; until then the protocol slot is reserved, the abstraction isn't introduced.

This satisfies the `[AGENTS.md` ALWAYS rule](../AGENTS.md): *"Always route side effects behind a protocol."* The rule applies to **cross-kernel-boundary** side effects; AppState's direct calls into PlatformMac concretes are not in violation because AppState is the wiring layer that legitimately owns those concretes. The split makes the rule physically true at the build level for the kernel — `import GSS` from a kernel file is a build error, not a review failure.

### The `LogEntry` / `RuntimeEvent` relationship

`[docs/STYLE.md](./STYLE.md)` rule 3: *"Every runtime behaviour emits a RuntimeEvent first. Log lines are derived from events, never the other way around."*

Today the codebase emits log lines and events in parallel — both `logStore.log(.notice, ...)` and `emitEvent(...)` are called for the same routing/auth/failover decision. The split is **not** the place to converge them; that's a separate refactor (and a follow-up to STYLE rule 3 enforcement).

But the split sets up the right shape: after the abstractions step, `LogSink` is the only logging seam in the kernel. A future change can route every `LogSink.log(...)` call through `RuntimeEventLog` first and let the sink derive the log line from the event — without changing any callsite.

### Ordering: why the rename comes before the abstractions

The original sequencing put the abstractions first and the rename last. After the PlatformMac move the order flipped to rename-first, abstractions-last. Two reasons:

1. **The abstractions step's new files land at their final paths.** That step introduces 2–4 new files (`Sources/ProxyKernel/Abstractions/LogSink.swift`, `Sources/ProxyKernel/Support/StandardLogSinks.swift`, plus the split-out `Sources/ProxyKernel/Models/LogTypes.swift` from `Logging.swift`, plus `Sources/Conduit/App/AppLogStore.swift`). With the rename done first, those files land directly at their final paths — no second move afterward. With the rename last, the abstractions diff would be created under `Sources/ConduitCore/...` then immediately re-pathed.
2. **The 21-callsite `LogSink` refactor reads cleanly without rename noise.** Mixing `import ConduitCore` → `import ProxyKernel` flips into the same diff as the `AppLogStore` → `any LogSink` retypes makes both harder to review. Separating concerns: the rename step is mechanical sed (one-line-per-file changes), the abstractions step is structural (parameter-list edits across 15 files).

This also matches the PlatformMac move's lesson that "pure file-move steps" (the rename, in the new ordering) and "structural-refactor steps" (the abstractions) shouldn't share a PR.

The earlier-doc rationale for the original ordering — "the rename can only be mechanical if the abstractions step already removed every concrete cross-target reference" — was wrong on the evidence. The kernel today (after the PlatformMac move) has no concrete `CredentialManager` / `SystemProxyManager` / `AppLogStore` *constructions* (those moved at the PlatformMac move); the kernel files only *take them as init params*. The rename-time `git mv` doesn't touch parameter types, so the rename is mechanical with or without the LogSink refactor done first.

## Open Items (Deferred)

Not required for the split to ship; revisit when the relevant phase comes around:

- `**PlatformIntegration` protocol** (and the `PlatformMacIntegration` composite). Originally planned for the rename step. Evidence after the PlatformMac move (orchestrator references zero PlatformMac concretes; AppState owns every platform side-effect call site) showed no kernel caller exists today. Re-enters the plan with the later control-plane work when the reload path becomes its first real consumer; the shape (composite vs per-concern) is a design choice driven by that work's actual call sites, not pre-emptive. See "New Abstractions § PlatformIntegration (deferred)" for the full rationale.
- `**SecretBytes` opaque credential type.** `[roadmap-v2.md](roadmap-v2.md)` (§2.5). Replaces `String` at credential boundaries; the boundaries are clearer after the abstractions step (every `CredentialProvider` callsite is one). Later roadmap work.
- **CFNetwork PAC evaluator.** `[roadmap-v2.md](roadmap-v2.md)` (§2.5). Second `PacEvaluator` impl swappable behind a feature flag. Later roadmap work.
- `**CorporateDefaults.swift` → `Resources/Presets/example-corp.json`.** `[roadmap-v2.md](roadmap-v2.md)` (§2.9). Vendor preset externalization for OSS distribution. The file stayed kernel-side at the PlatformMac move (originally planned to move to PlatformMac as `CorporatePreset.swift`); `ProxyConfig.testFixture()` introduced at the abstractions step reduces the test-site surface that the later OSS-prep work has to migrate.
- `**NotificationSink` protocol.** Introduce when kernel code needs to fire user-visible notifications. Not before.
- **Generic `LogSink` parameterization.** If profiling under `pm-sim multi-100` shows existential dispatch on `any LogSink` is hot (>2% in witness tables), switch the hottest 2–3 callsites to `<L: LogSink>` generic parameters. Measure before optimizing.
- `**PacEvaluator` → `PacFetcher` + `PacEvaluatorFactory` decomposition.** The existing 3-method `PacEvaluator` mixes fetch and evaluation — different lifetimes. Worth considering a future split when the later `CFPACEvaluator` lands and there are two impls to compare. Don't pre-emptively split.
- `**TransparentTCPProxy` ↔ helper TCP-relay wiring.** Listed as a roadmap carryover in `[ROADMAP.md](../ROADMAP.md)`. The split doesn't block it; doing it during the split would conflate diffs.
- `**ConfigDefaults.swift` → `ConfigDefaults/Generic.swift` + `ConfigDefaults/Provider.swift` + `ConfigDefaults/Migration.swift`.** Optional file-level decomposition for clarity. Not required by the split.
- `**EnvironmentManager` kernel/platform split.** The shell-export-line generation (`export HTTP_PROXY=...`) is pure string formatting; the filesystem write is platform. Pattern-matches `VPNStateFuser`'s extraction at the PlatformMac move. Defer until a kernel/test/sim consumer materially benefits — most likely the later "Log-sink sanitization" work (the formatter wants the same masking) or the vendor-neutral preset rendering.

## References

### Plan documents

- `[roadmap-v2.md](roadmap-v2.md)` (§2.2) — module split description (4–5 targets) and the import-fence rules this design implements.
- `[roadmap-v2.md](roadmap-v2.md)` (§2.4) — the module-split task list.
- `[ROADMAP.md](../ROADMAP.md)` — pillar-tagged checklist of the module-split work items.
- `[AGENTS.md](../AGENTS.md)` — NEVER section (import fence statement), ALWAYS section (side-effects-behind-protocols rule).
- `[docs/STYLE.md](./STYLE.md)` — engineering discipline. Specifically: rule 3 (structured events first), rule 8 (side-effects gated behind protocols).
- `[docs/design-vpn-flap-resilience.md](./design-vpn-flap-resilience.md)` — the precedent for how side-effecting behaviours (`VPNStatusMonitor`) are introduced behind a protocol (`VPNStatusObserving`) with an injectable fake (`FakeVPNStatusObserver`). Same pattern, applied to the existing PlatformMac surface.

### Codebase references

- `Sources/ConduitCore/Support/Logging.swift` — `AppLogStore` definition; the file that splits across the PlatformMac-move and rename steps.
- `Sources/ConduitCore/System/PrivilegeClient.swift` — protocol-and-concrete-in-one-file pattern that splits during the PlatformMac move.
- `Sources/ConduitCore/Models/ConfigDefaults.swift` — `GenericDefaults` (stays Kernel) + `CorporateDefaults` (moves PlatformMac) + `LegacyConfigMigration` (stays Kernel).
- `Sources/ConduitCore/Network/VPNStatusMonitor.swift` — the file that already carries the relocation header comment.
- `Sources/ConduitCore/Proxy/ProxyOrchestrator.swift` — the largest aggregator of cross-target dependencies; takes `AppLogStore`, `CredentialManager`, references `TunnelResolverManager.resolverPort`. The rename step's refactor target.
- `Sources/pm-proxy/PMProxy.swift` — the headless daemon that already lives at the fence; the binary whose `Package.swift` dependency drop is the test of the PlatformMac move's correctness.
- `Sources/pm-sim/Harness.swift` — the simulator harness; should depend on `ProxyKernel` + `ProxyAuth` only post-split.
- `Sources/Conduit/App/AppState.swift` — the SwiftUI app's wiring layer; owns every `PlatformMac` concrete and is the only post-split site that links them. (The originally-planned `PlatformMacIntegration` composite was deferred to the later control-plane work — see "New Abstractions § PlatformIntegration (deferred)".)

### External references

- [Swift Package Manager — Target dependencies](https://www.swift.org/documentation/package-manager/) — for the `Package.swift` shape changes.
- [Swift evolution SE-0386: `package` access modifier](https://github.com/apple/swift-evolution/blob/main/proposals/0386-package-access-modifier.md) — the access modifier the codebase already uses everywhere; required reading for understanding why "cross-target call must go through a protocol" is enforced (not advisory).

