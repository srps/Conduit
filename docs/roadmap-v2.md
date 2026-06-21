# Conduit V2 — Plan (Revised)

**Status**: Plan A is mandatory. Plan B is optional and gated on a later decision.
**Date of revision**: 2026-04-17. Inputs: full re-read of every source file in the kernel module (then named `ConduitCore`), `Sources/pm-sim/`, `Sources/pm-proxy/`, and seven deep research passes on the 2026 state of the Rust auth/proxy/JS/DNS ecosystems, Swift cross-platform viability, the competitive corporate-proxy landscape, and the Ghostty/TigerBeetle architectural templates. All research is archived in Part 5 documenting why each call was made.

---

## TL;DR

1. Conduit is a **macOS-native Swift menu-bar proxy with real upstream failover and full corporate-auth support**. That is the product. Its niche — *developers on macOS inside AD-Kerberos/NTLM enterprises that still run legacy explicit proxies* — is real, underserved (Preproxy dead since 2022, alpaca is NTLM-only, proxydetox is Kerberos-only, px/cntlm are CLI/Python), and **nobody else has real failover**.
2. **Plan A (mandatory)** is to double down on macOS: finish the module split, tighten security and reliability, make the UI excellent, make the daemon and menu bar fully separable, and build chaos simulators that double as demos. Swift stays. JavaScriptCore is replaced with CFNetwork on macOS for PAC (free Safari-parity). No Rust work is done as part of Plan A.
3. **Plan B (optional)** is a Rust port for cross-platform reach. It is preserved in detail in Part 3 with its research but **no work is started until Plan A ships and daily-driver-survival criteria are met**. Ingredients: `hyper 1.x` + `tokio 1.52` + `rustls 0.23` + `hickory-dns` + `fast-socks5` + hand-rolled NTLM + `libgssapi`/`cross-krb5` + `rquickjs`. *Not* `sspi-rs`, *not* `pingora`, *not* Zig/Odin side-quests.
4. The Ghostty/TigerBeetle inspiration is kept as *philosophy* (discipline, observability, module separation) but not as *template* (no Zig core, no deterministic simulation database, no C ABI for external embedders). The updated research in Part 5 includes Hashimoto's own 2025 walk-back of the thin-shell pattern.
5. `STYLE` — the sensible subset of TIGER_STYLE — gets baked into `AGENTS.md` and `README.md` during the foundation phase so every future change (agent or human) is measured against the same discipline.

---

## Table of Contents

- [Part 1 — Premise & Principles](#part-1--premise--principles)
  - [1.1 The premise (updated)](#11-the-premise-updated)
  - [1.2 Inspiration, honestly read](#12-inspiration-honestly-read)
  - [1.3 Where we are today](#13-where-we-are-today)
  - [1.4 The niche](#14-the-niche)
- [Part 2 — Plan A (MANDATORY): macOS-first, Swift](#part-2--plan-a-mandatory-macos-first-swift)
  - [2.1 Product pillars](#21-product-pillars)
  - [2.2 Module split (4-5 targets)](#22-module-split-45-targets)
  - [2.3 STYLE](#23-style)
  - [2.4 Foundation & module split](#24-foundation--module-split)
  - [2.5 Security, reliability, efficiency](#25-security-reliability-efficiency)
  - [2.6 Daemon-first architecture & control plane](#26-daemon-first-architecture--control-plane)
  - [2.7 UI excellence (Liquid Glass, HIG)](#27-ui-excellence-liquid-glass-hig)
  - [2.8 Simulators & chaos demos](#28-simulators--chaos-demos)
  - [2.9 Open-source preparation](#29-open-source-preparation)
  - [2.10 Enterprise addenda (post-1.0)](#210-enterprise-addenda-post-10-not-part-of-the-core-critical-path)
- [Part 3 — Plan B (OPTIONAL): Rust port](#part-3--plan-b-optional-rust-port)
  - [3.1 When (not) to trigger Plan B](#31-when-not-to-trigger-plan-b)
  - [3.2 Preserved Rust architecture](#32-preserved-rust-architecture)
  - [3.3 The Rust stack, justified](#33-the-rust-stack-justified)
- [Part 4 — What NOT to do](#part-4--what-not-to-do)
- [Part 5 — Research archive](#part-5--research-archive)
  - [5.1 Swift cross-platform viability (April 2026)](#51-swift-cross-platform-viability-april-2026)
  - [5.2 Rust forward-proxy stack](#52-rust-forward-proxy-stack)
  - [5.3 NTLM / Kerberos / SPNEGO libraries](#53-ntlm--kerberos--spnego-libraries)
  - [5.4 PAC evaluation](#54-pac-evaluation)
  - [5.5 DNS, TUI, Zig, Odin, tokio, JS engines](#55-dns-tui-zig-odin-tokio-js-engines)
  - [5.6 Competitive landscape](#56-competitive-landscape)
  - [5.7 Ghostty / TigerBeetle architectural fact-check](#57-ghostty--tigerbeetle-architectural-fact-check)

---

# PART 1 — Premise & Principles

## 1.1 The premise (updated)

Conduit started as a working corporate proxy manager built in a week that saved its author two hours every day. It works for one developer, which means it could work for every other macOS developer at a large-enterprise-shaped organization. The product question is not "how do we go multi-platform?" — it is *"how do we make this the tool nobody on macOS can live without?"*

The answer is not more features. It's:

- **Bulletproof failover** under the real-world chaos of Wi-Fi → VPN → captive portal → coffee-shop tunneling.
- **Security that withstands scrutiny** — corporate auth, tunnel credentials, and PAC evaluation all touch sensitive surfaces.
- **Efficiency** — a menu-bar tool has a budget measured in dozens of megabytes and single-digit percent CPU, always.
- **Observability by default** — every routing, auth, and failover decision is a structured event, not a log line.
- **A UI people love using** — native, HIG-correct, Liquid Glass, fast; the menu bar does the job most users need without ever opening the main window.
- **A headless daemon mode** that runs fine without the UI at all — for CI, for developers on SSH, for the day someone wants a systemd-style setup.
- **Simulators and chaos demos** that prove the product works and double as testing infrastructure.

Everything in Plan A is in service of those seven qualities. Everything in Plan B is preserved but off the critical path.

## 1.2 Inspiration, honestly read

Ghostty and TigerBeetle are lodestars for *philosophy*, not *architecture*. The research in §5.7 documents:

- Ghostty 1.2 shipped Sep 15, 2025. Its C API is **explicitly not stabilized** — "may change significantly between releases." So "any language can embed libghostty" is aspirational, not production-true.
- Ghostty's GTK application was **rewritten in Aug 2025** to embrace GObject. Mitchell Hashimoto's own [post-mortem](https://mitchellh.com/writing/ghostty-gtk-rewrite) explicitly rejects the "thin native shell over a core" template: *"an entire class of bugs where the Zig memory or the GTK memory has been freed, but not both."* The lesson is **embrace the platform toolkit's lifetime model, don't treat the native shell as a view**. For us: the SwiftUI layer is a first-class Swift module, not a thin wrapper over an abstract runtime.
- TigerBeetle has **not shipped 1.0**. Still on 0.17.0 (Apr 3, 2026) after 6+ years. "Zero dependencies" works because they own every line and are building a *financial database* where a mis-accounting is a lawsuit. We are not that. We ship on top of SwiftNIO + GSS.framework + Foundation + AppKit, and that is fine.
- TIGER_STYLE's *principles* are correct: bounded everything, assert invariants, structured events, no silent failures, explicit resource lifetime. Its *extremes* (70-line function limit, zero dynamic allocation post-init) are not our tax to pay.

**Takeaway for Plan A**: keep the discipline (STYLE, §2.3), keep the observability story, keep module separation, keep the "library at the core, app at the edge" idea. Don't keep the Zig, the C ABI, the determinism-at-all-costs, or the thin-shell pattern.

## 1.3 Where we are today

Based on a line-by-line re-read of everything in `Sources/`:

### Already-done work the previous plan underestimated

- **Section-based config** (`Models/ConfigSections.swift` in the kernel module): `ProxySection`, `AuthSection`, `RoutingSection`, `DNSSection`, `TunnelSection`, `HealthSection`, `LoggingSection`, `PlatformIntegrationConfig`, `AppPreferences`. UI prefs already separated from daemon config.
- **Config validation** scaffolding (`ConfigValidation.swift`) and per-section diffing (`ConfigDiff.swift`) already exist.
- **Vendor-vs-generic defaults** already split: `GenericDefaults` and a corporate-preset defaults type both implement `ConfigDefaultsProvider` (`ConfigDefaults.swift`). The corporate preset is no longer hardcoded in the main type.
- **Bounded ring-buffered event log**: `RuntimeEventLog` (`RuntimeEvent.swift`) with fixed capacity and oldest-evicted-on-overflow semantics. TIGER_STYLE "put a limit on everything" already applied.
- **Fault-injection harness**: `Sources/pm-sim/` — `FakeClient`, `FakeOrigin`, `FakeUpstreamProxy`, `MockAuthenticator`, `Harness`, scenario suite (baseline / silent-then-burst / multi-concurrent / high-throughput / long-silent / keepalive / health-check / failover / flood-slow-drain). This is the foundation for chaos demos.
- **Headless isolated runtime**: `pm-proxy --state-dir /tmp/x --port 0 --dns-port 0 --status-interval 2` already runs with zero system-side-effects and streams NDJSON status. This *is* the UI-less daemon mode — it just isn't called that yet.
- **Clean DI boundary**: `RuntimeEnvironment` + `ProxyOrchestratorSnapshot` + `ProxyAuthenticator` protocol + `PrivilegeClient` protocol all already abstract the right seams.
- **537 tests across 46 files**. Real coverage.

### Entanglement that still needs work

- All 46 source files live in one SPM target (at the time of writing, `ConduitCore`). Apple-framework imports (`GSS`, `Security`, `JavaScriptCore`, `CommonCrypto`, `SMAppService`, `UserNotifications`, `CFNetwork` helpers) sit next to pure-NIO logic (`ConnectionPool`, `DNSWireFormat`, `NoProxyMatcher`). Any consumer of the library drags in every Apple framework.
- `PACResolver.swift` uses `JavaScriptCore` — a whole JS engine embedded for a tiny surface (see §5.4 for the CFNetwork-native replacement).
- `PacEvaluator`, `CredentialProvider`, `PlatformIntegration` abstractions described in the previous plan are **not yet introduced**. The `ProxyAuthenticator` protocol exists; the rest don't.
- The corporate defaults type still hardcodes 10 regional endpoints in source; they should move to a preset file for open-source release.
- No STYLE document. No centralized invariant assertions. No top-level security review.

### What is *not* a problem

SwiftNIO on macOS is fine. Swift 6.3 on macOS 26.x is fine. GSS.framework is correct for Kerberos on macOS (SSO from the user's kinit ticket; see §5.3 for why `sspi-rs` on macOS would be a downgrade). The codebase is already deep into Swift 6 concurrency (`@MainActor`-isolated `ProxyOrchestrator`, `package` access everywhere, `Sendable` types). None of this needs to change.

## 1.4 The niche

The competitive research (§5.6) is unambiguous:

| Tool | macOS-native UI | NTLM | Kerberos | PAC | SOCKS5 | Tunnels | Real failover |
|------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **px** (Python) | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ | comma-list, no health |
| **alpaca** (Go) | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | PAC-list only |
| **proxydetox** (Rust) | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | PAC-list only |
| **cntlm** (C) | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ | round-robin |
| **gontlm-proxy** (Go) | ✗ | Win-only | Win-only | ✗ | ✗ | ✗ | single upstream |
| **Preproxy** (macOS) | ✓ (2022, dead) | ✓ | ✓ | ✓ | ✗ | ✗ | basic |
| **Conduit** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **full recovery ladder, health probes, circuit breaker** |

**Nobody else has the combination.** The moat is:

1. **macOS-native UI** in an app people actually want to open.
2. **Real failover** — health-probed, auto-recovering, circuit-breaker-gated, not "try the next host and give up."
3. **Everything in one tool** — NTLM *and* Kerberos *and* PAC *and* SOCKS5 *and* tunnel forwarding.
4. **Observable** — structured events and snapshots, not log-grepping.

Plan A extends all four.

---

# PART 2 — Plan A (MANDATORY): macOS-first, Swift

## 2.1 Product pillars

Every piece of work lands under one of these seven pillars. If a proposed task doesn't fit, it's out of scope.

| Pillar | Definition | How it's measured |
|---|---|---|
| **Reliability** | No daily-driver regressions. Survives network transitions flawlessly for 90+ days. | Daily use; `pm-sim` chaos suite green; zero "I had to restart it" moments in a rolling quarter. |
| **Security** | No secret leaks. Zero `unsafe` holes. PAC eval sandboxed. Tunnel credentials rotatable. | Threat-model doc reviewed; `KeychainStore` audit; `PACResolver` sandbox asserted; every public `Sendable` reviewed for secret leakage. |
| **Efficiency** | < 40 MB RSS idle, < 3% CPU idle, < 50 ms added latency to proxied requests at p99. | Instruments profile under `pm-sim multi-100`; `top`/`Activity Monitor` long-run baseline; `ProxyOrchestratorSnapshot.timing` per-request samples. |
| **Observability** | Every routing / auth / failover / health decision emits a typed event. Snapshots are machine-consumable. | `RuntimeEventLog.totalCount` under load; NDJSON stream; agent harness can assert behaviour from events alone. |
| **Great UI** | Menu bar does 90% of daily tasks; main window is beautiful and HIG-correct; Liquid Glass throughout. | One-shot tasks from menu bar (toggle proxy, switch profile, test upstream, view health, last N events); zero HIG violations; TestFlight beta feedback. |
| **Daemon-first** | The runtime runs with no UI attached. Menu bar and app connect as clients. | `pm-proxy` survives and serves traffic with the GUI force-quit. `pmctl` CLI can talk to a running daemon. |
| **Simulators & demos** | `pm-sim` keeps pace with every new behaviour; a demo mode visualizes the event stream live. | Every new runtime behaviour adds a scenario before it ships. Demo TUI / SwiftUI view subscribes to the event stream and renders faults in real time. |

## 2.2 Module split (4-5 targets)

The original single kernel target (then named `ConduitCore`) mixed pure-Swift logic with every Apple framework. The goal of the split is **not** preparation for Rust, and **not** maximal modularity — it is *visibility*. After the split, the dependency graph answers "what is portable?" and "what is Apple-specific?" at a glance.

> **Status (2026-04-22): the early migration steps shipped. The shape below reflects the original plan; the as-shipped shape diverged in three places** — the corporate-defaults source file stayed kernel-side (deferred to the open-source-prep phase's JSON externalization), `PlatformIntegration` was deferred to the daemon-first phase (no kernel caller existed at the time; AppState owns every platform side-effect call site), and the last two migration steps were reordered (one became a mechanical rename, the other introduced LogSink + widened CredentialProvider + the three-mirror consolidation). The `LogSink` protocol shape also gained a `minLevel` property + `@autoclosure` extension for daemon-side allocation savings. **`ROADMAP.md`'s foundation phase plus `docs/design-module-split.md` are the authoritative source for the as-shipped state**; the rest of this section is preserved as the original design intent for historical reading.

```
Package.swift
├── ProxyKernel           (pure Swift + SwiftNIO + NIOConcurrencyHelpers — zero Apple frameworks)
│   ├── Models/           ProxyConfig, ConfigSections, ConfigValidation, ConfigDiff,
│   │                     ConfigDefaults (only GenericDefaults), ProxyStatus,
│   │                     UpstreamProxy, RuntimeEvent, RuntimeEventLog
│   ├── Proxy/            LocalProxyServer, HTTPProxyHandler, CONNECTHandler,
│   │                     ConnectionPool, ProxyOrchestrator, SOCKS5Server,
│   │                     NoProxyMatcher, ProtocolDetector, ProxyAuthenticator (protocol),
│   │                     MetadataBlocklist
│   ├── Network/          AutoRecovery, DirectConnectDetector, HealthChecker,
│   │                     UpstreamProber, DNSWireFormat, LocalDNSForwarder,
│   │                     TCPRelay, UDPRelay
│   ├── Tunnels/          TunnelForwarder, TunnelDNSResponder, TransparentTCPProxy
│   ├── Support/          RuntimeEnvironment, ErrorFormatting, TCPKeepalive,
│   │                     ProxyConfigPersistence (file-only, no Keychain).
│   │                     Logging value types (LogEntry / LogLevel / LogCategory) move to
│   │                     Models/Logging.swift; AppLogStore (the @MainActor / Combine
│   │                     ObservableObject) moves to Sources/Conduit/App/, conforming
│   │                     to the LogSink protocol below.
│   └── Abstractions/     CredentialProvider (new protocol), PacEvaluator (new protocol),
│                         PlatformIntegration (new protocol), LogSink (new protocol;
│                         see §2.4 — surfaced by the audit, replaces concrete AppLogStore
│                         at 21 cross-target callsites). NotificationSink deferred until
│                         a kernel caller exists for it.
│
├── ProxyAuth             (imports GSS, CommonCrypto — isolates Kerberos + NTLM crypto)
│   ├── NTLMAuth.swift               (pure; MD4/HMAC-MD5 via CommonCrypto)
│   ├── KerberosAuth.swift           (GSS.framework bridge)
│   ├── NegotiateAuthenticator.swift (Kerberos-first, lazy NTLM fallback)
│   └── AuthTokenFormats.swift       (SPNEGO / NTLMSSP binary framing)
│
├── ProxyPAC              (imports JavaScriptCore for now; swaps to CFNetwork in the security/reliability phase)
│   ├── PACResolver.swift            (→ CFNetworkExecuteProxyAutoConfigurationURL in the security/reliability phase)
│   ├── PACRoutingEngine.swift       (route-chain evaluator; pure Swift)
│   └── PACFallback.swift            (native helper impl for off-by-default cases)
│
├── PlatformMac           (imports Security, SMAppService, UserNotifications, CFNetwork,
│   │                      Foundation process-launching; calls helper via PrivilegeClient)
│   ├── KeychainStore.swift                  (CredentialProvider impl)
│   ├── NotificationManager.swift            (UserNotifications; called only from AppState
│   │                                         today, no NotificationSink protocol yet — see §2.4)
│   ├── SystemProxyManager.swift             (networksetup wrapper)
│   ├── SystemDNSManager.swift               (networksetup wrapper)
│   ├── EnvironmentManager.swift             (shell env file)
│   ├── LoginItemManager.swift               (SMAppService)
│   ├── HelperPrivilegeClient.swift          (helper XPC; concrete impl of the
│   │                                         PrivilegeClient protocol, which moves to
│   │                                         ProxyKernel/Abstractions/)
│   ├── ActivationPreflight.swift            (permissions probe)
│   ├── TunnelResolverManager.swift          (/etc/resolver)
│   ├── VPNDNSDetector.swift                 (scutil / SCDynamicStore)
│   ├── NetworkMonitor.swift                 (NWPathMonitor)
│   ├── CommandRunner.swift                  (Process wrapper)
│   ├── CorporatePreset.swift                (was the corporate-defaults type — migrates to a bundled TOML/JSON in the open-source-prep phase)
│   └── PlatformMacIntegration.swift         (PlatformIntegration impl composing the above)
│
└── ProxyApp (executable)  (imports SwiftUI, AppKit, Combine, Observation)
    ├── App/                                 AppState, WindowManagement, Commands
    ├── Views/                               SwiftUI views (main window, status pane, settings)
    ├── MenuBar/                             MenuBarService (Liquid Glass menu extras)
    ├── DaemonClient/                        ControlSocketClient (talks to pm-proxy when detached)
    ├── Floating/                            FloatingStatusWindow (optional)
    └── Assets/                              icons, Liquid Glass materials
```

Executables that keep existing:

- `pm-proxy` — links `ProxyKernel` + `ProxyAuth` + `ProxyPAC`, *not* `PlatformMac`. Proves the daemon runs without Apple-framework imports beyond what `ProxyAuth` needs (GSS is effectively required for Kerberos; see §5.3).
- `pm-sim` — links only `ProxyKernel` + `ProxyAuth`. Scenarios don't touch the platform.
- `pm-dns` — links `ProxyKernel`. Demonstrates the DNS module is self-contained.
- `pm-tunnel` — links `ProxyKernel`. Same.
- `ConduitHelper` — LaunchDaemon helper; links `ConduitShared` + whatever it needs from `ProxyKernel`. Stays minimal.
- `Conduit` (app) — the SwiftUI app. Links everything.

**Why 4-5 not 7:** Separating `Models`, `DNS`, `Tunnels`, `Logging` as additional targets buys nothing at 10K LOC — they already don't cross-import Apple frameworks. Separating them *later*, when one earns it, is cheap. Separating them *now* is bureaucracy.

**Explicit interface rules for the split:**

1. `ProxyKernel` imports *only* `Foundation`, `Dispatch`, `NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOConcurrencyHelpers`. Any change that adds `import GSS`, `import Security`, `import JavaScriptCore`, `import CoreFoundation`-for-CFNetwork, `import SMAppService`, `import UserNotifications`, `import Combine`, `import SystemConfiguration`, or `import Network` to a `ProxyKernel` file fails review. Once the kernel rename lands, the build itself enforces this — `ProxyKernel`'s SPM target doesn't link those frameworks, so the `import` statement is a compiler error rather than a review-time miss.
2. `ProxyAuth` is allowed `import GSS` and `import CommonCrypto` only. No `Security` (Keychain belongs in `PlatformMac`).
3. `ProxyPAC` is allowed `import JavaScriptCore` *until* the CFNetwork swap lands; after that it's allowed `import CoreFoundation` and `import CFNetwork` only.
4. `PlatformMac` is the only target allowed to shell out via `Process` or talk to the helper.
5. Every cross-target call goes through a protocol in `ProxyKernel/Abstractions/`. No concrete cross-target types. If a concrete type leaks, it's a design signal to refactor.

## 2.3 STYLE

The discipline we actually adopt — TIGER_STYLE minus the parts that are over-engineering for a desktop proxy. This gets baked into `AGENTS.md` (review-time reference) and `README.md` (contributor-facing) during the foundation phase.

```
STYLE

1. Bound everything.
   Every pool, queue, cache, and buffer has a fixed capacity defined in config.
   The runtime runs for weeks without memory growth. Unbounded growth is a bug.
   Already applied: RuntimeEventLog, maxConnections, maxTunnelSessions, inboundConnectionMaxLimit.
   Still needed: DNS cache bound, PAC eval queue bound, pending-auth-handshake bound.

2. Assert invariants, not just happy paths.
   After every mutation (config reload, connection open/close, auth handshake, failover),
   assert internal state is consistent. precondition() for bugs, throws for user errors.
   Assertion failures are structured events with correlation IDs, not silent crashes.

3. Structured events before log lines.
   Every runtime behaviour emits a RuntimeEvent first. Log lines are derived from events,
   never the other way around. Events are the contract with the UI, the CLI, the demos,
   and the agent harness.

4. Validate at the boundary, trust inside.
   ProxyConfig is validated at parse time (ConfigValidation.swift). Network input is
   validated in NIO handlers. Inside ProxyKernel, data is already valid; assertions
   catch bugs, not user errors.

5. Functions fit on a screen.
   100 lines max (not TigerBeetle's 70; we're not a state machine at that granularity).
   Long functions are a signal to name the sub-steps and extract. ProxyOrchestrator.startProxy
   is the worst offender today; split during the foundation phase.

6. No silent failures.
   Every error is either recovered (with a structured event explaining how) or surfaced
   (with a structured event explaining why). "Catch and continue" without an event is banned.

7. Explicit resource lifetime.
   Every connection, auth context, DNS session, tunnel session has a defined start,
   lifecycle, and cleanup. Cleanup is idempotent. Leaks are assertion failures.

8. Side-effects gated behind protocols.
   System proxy, env variables, /etc/resolver, login items, helper daemons — none
   of these are called directly from ProxyKernel. All go through PlatformIntegration,
   which is mocked in tests and in pm-proxy's headless mode.

9. Security is a first-class review axis.
   Credentials never cross ProxyKernel boundaries as String; use opaque SecretBytes.
   PAC evaluation is CPU- and memory-bounded. Tunnel configs never embed plaintext passwords.
   The threat model doc (docs/threat-model.md) is updated when any auth, credential,
   or privilege-escalation change lands.

10. Deterministic where possible.
    pm-sim scenarios must be reproducible for a given seed. ProxyOrchestrator decisions
    should be pure functions of (config, snapshot, wall-clock). Hidden non-determinism
    (ambient env vars, global state) is a bug.
```

## 2.4 Foundation & module split

**Goal:** the codebase visibly matches its intent. New contributors see "what's portable" on page one.

The split itself has its own design document: [`docs/design-module-split.md`](./docs/design-module-split.md). It carries the file-by-file destination map (56 files, audited), the four new protocols this section names, the target dependency matrix, and six independently-shippable migration steps: add target directories → move `ProxyAuth` → move `ProxyPAC` → move `PlatformMac` files → wire abstractions → rename the kernel module to `ProxyKernel`. The tasks below are the surrounding foundation work; the split's mechanics live in the design doc.

### Tasks

1. **Write `docs/STYLE.md`** from §2.3. Link from the root `README.md` and referenced from `AGENTS.md`. ✅ shipped.
2. **Update `AGENTS.md`** to:
   - Point to `STYLE.md`.
   - Add the import-fence rules from §2.2 as review criteria.
   - Add the "structured event first" rule to the Design Invariants section.
   - Keep every existing invariant — they're good.
   - ✅ shipped.
3. **Update `README.md`** to:
   - State the product pillars (§2.1) as the contributor contract.
   - Rename any employer-specific framing → "macOS-native corporate proxy manager (vendor-neutral, validated against a real corporate proxy)".
   - Add a "Contributing" section linking to `STYLE.md` and `AGENTS.md`.
   - ✅ shipped.
4. **Write `docs/design-module-split.md`** — file-by-file audit, target dependency matrix, six-phase plan with exit criteria per phase. ✅ shipped.
5. **Execute the split per `docs/design-module-split.md`**, as a sequence of independently-shippable steps:
   - Create target directories + stub files; `Package.swift` declares four new targets; build green.
   - Move `NTLMAuth.swift` + `KerberosAuth.swift` → `ProxyAuth`; build green.
   - Move `PACResolver.swift` → `ProxyPAC`; introduce `PacEvaluator` protocol; `PACRoutingEngine` takes the protocol; build green.
   - Move 17 macOS-bound files → `PlatformMac` (with two file splits: `PrivilegeClient.swift` and `ConfigDefaults.swift`); resolve the `TunnelForwarder.resolverPort` cross-target reference; build green.
   - Introduce `LogSink`, `CredentialProvider`, `PlatformIntegration` protocols in `ProxyKernel/Abstractions/`; refactor 21 `AppLogStore` parameters to take `any LogSink`; `AppLogStore` moves to `Sources/Conduit/App/AppLogStore.swift` and conforms to `LogSink` via its existing nonisolated bridge; `ProxyOrchestrator` takes protocols, not concrete types; `pm-proxy` constructs `NoOpPlatformIntegration` + `ConsoleLogSink`; `pm-proxy`'s `Package.swift` drops `PlatformMac` from `dependencies`. The build is now the test that the fence is correct.
   - Rename the kernel module to `ProxyKernel`; mass-edit imports; update docs.
6. **Decompose `ProxyOrchestrator.startProxy()` and any other >100-line function** per STYLE rule 5. Name the sub-steps after the lifecycle states they implement. (Independent of the split; can land before or after.)
7. **Move the corporate-defaults type out of `ProxyKernel`.** Lands as part of the `PlatformMac` migration (`PlatformMac/CorporatePreset.swift`); the open-source-prep phase moves it further to a bundled resource file.
8. **Audit for `TODO`, `FIXME`, `XXX`, `// hack`.** Triage each; fix or document why not. STYLE rule 0 (implicit): zero tech debt tolerated after this phase's cutoff.
9. **Introduce a `DNS.cache` capacity bound** if missing. Tunnel pending-auth bound. PAC eval queue bound. Any other unbounded-collection case found during audit.

### Abstractions clarified

The original plan listed four protocols (`CredentialProvider`, `PacEvaluator`, `PlatformIntegration`, `NotificationSink`) as foundation work. The audit in `docs/design-module-split.md` revised this to **four protocols, but not the four originally named**:

- `CredentialProvider` — stays. `CredentialManager` (in `PlatformMac` post-split) conforms; `pm-proxy` uses an in-memory impl.
- `PacEvaluator` — stays. `PACResolver` (in `ProxyPAC` post-split) conforms; the CFNetwork swap in the security-hardening work introduces a second impl behind the same protocol.
- `PlatformIntegration` — stays. `PlatformMacIntegration` composes the four System* managers + `LoginItemManager` + `ActivationPreflight` and conforms; `pm-proxy` uses `NoOpPlatformIntegration`.
- **`LogSink` — added.** The audit revealed `AppLogStore` (a `Combine` `ObservableObject` with `@MainActor` isolation) is the most-pervasive cross-target dependency: 21 kernel-bound types take it as an init parameter. The kernel cannot import `Combine`. `LogSink` is the protocol; `AppLogStore` (moves to the SwiftUI app) conforms; `ConsoleLogSink` / `DiscardingLogSink` / `RecordingLogSink` are the test/headless impls. Without `LogSink`, the kernel cannot be built without `Combine` and the import fence is unenforceable.
- **`NotificationSink` — deferred.** `NotificationManager` is invoked only from `AppState`; no kernel-module file references it. Introducing a protocol now would be a placeholder with one no-op call site. We move `NotificationManager` directly to `PlatformMac` (or leave it in the app target — both are fine) and introduce the protocol the day kernel code wants to fire a user-visible notification. YAGNI.

### Exit criteria

- `swift build` green, `swift test` green at every migration-step boundary; all 721+ tests pass at the end.
- After the kernel rename: `grep -rn "import GSS\|import Security\|import JavaScriptCore\|import CommonCrypto\|import SMAppService\|import UserNotifications\|import Combine\|import SystemConfiguration\|import Network$" Sources/ProxyKernel` returns zero matches.
- After the abstractions are wired: `pm-proxy`'s `Package.swift` does not list `PlatformMac`; `pm-sim` likewise. The Swift compiler enforces the fence; the absence of the dependency is the test.
- `docs/STYLE.md`, updated `AGENTS.md`, updated `README.md`, `docs/design-module-split.md` all committed. ✅ shipped.
- `pm-proxy --state-dir /tmp/x --port 0 --dns-port 0 --status-interval 2` runs on a CI box with no Apple-framework side effects (verified via `vmmap` / `otool -L`).

### Duration estimate

2-4 focused sessions. It's refactoring, not rewriting. Each migration step is one self-contained change; the six-step sequence makes review and bisect easy.

## 2.5 Security, reliability, efficiency

**Goal:** the product is *measurably* more secure, reliable, and efficient than it is today.

### Security hardening

> **Status (as of 2026-04-27):** items 1, 2, 3, 5, and 6 below have shipped; item 4 is partially shipped (in-memory credential boundaries plus durable log/event sanitisation done, one-shot HTTP header strings remain lifecycle-bound). The late-April security hardening wave on `main` (proxy/helper trust boundaries, IPv6 metadata canonicalisation, helper IPC versioning + validation) advanced items 7, 9, and 10 incrementally without finishing them. See [`ROADMAP.md`](./ROADMAP.md)'s security-hardening section for per-item status and the Done log for ship dates. Items 7 (Keychain ACL), 8 (tunnel rotation), 9 (privileged-action audit trail), 10 (inbound gateway auth), 11 (cert pinning), 12 (audit log), and 13 (SOCKS5 auth hardening) remain.

1. **Threat model document** (`docs/threat-model.md`). Covers: (a) malicious PAC, (b) MITM on upstream proxy, (c) credential theft from Keychain, (d) local-process snooping of in-memory auth tokens, (e) TCP hijacking of the local proxy port, (f) privilege escalation via helper, (g) IPv6 address-family confusion, (h) SNI/CONNECT host mismatch.
2. **Replace `PACResolver`'s JavaScriptCore with `CFNetworkExecuteProxyAutoConfigurationURL`** (see §5.4). Rationale: Safari-parity behaviour, OS-level security patching, no in-process JS engine, negligible code size. Caveats: 5-second internal timeout (wrap calls with our own), known silent drop of `HTTPS` return keyword (we already normalize routes; verify our normalizer handles this), known `PACClient` retain cycle (wrap in `autoreleasepool`). **Shipped behind a feature flag** (2026-04-23): `Sources/ProxyPAC/CFPACEvaluator.swift` coexists with `PACResolver` behind `experimentalCFPacEvaluator` (default off). Settings UI toggle + restart-required banner shipped 2026-04-26. Remaining: graduate the flag default after pilot soak, then remove `PACResolver` and drop the `JavaScriptCore` link.
3. **Introduce `SecretBytes`** — an opaque Swift type that:
   - wraps `Data`
   - forbids `description` / `debugDescription` from surfacing bytes
   - zeroes memory on `deinit` (via `memset_s` or `CryptoKit.SymmetricKey`)
   - conforms to `Sendable` but *not* `Codable`/`LosslessStringConvertible`
   - is the only type the Keychain and credential-provider APIs accept/return

   **Shipped** (initial implementation refined shortly after, 2026-04-23). New file `Sources/ProxyKernel/Security/SecretBytes.swift`; class-backed `Sendable` struct with `CustomStringConvertible` + `CustomDebugStringConvertible` + `CustomReflectable` all returning the redacted form, no `Codable` conformance, zero-on-`deinit` via `explicit_bzero`. `ProxyCredentials.ntHash` retyped from `Data` to `SecretBytes`; the `KeychainPayload` keeps `Data` for the bespoke wire format with explicit conversion at the boundary.
4. **Audit every `String` carrying a password, token, or cookie.** Replace with `SecretBytes` where a lifecycle bound is possible. Where not (e.g., one-shot `Authorization: Negotiate …` header), document why. **Partially shipped** (in-memory credential boundaries via item 3; durable log/event sanitisation via item 5).
5. **Explicit `Proxy-Authorization` header sanitization** in all log sinks. `AppLogStore`, `Logging.swift`, NDJSON event emitter. Assertion: no log line may contain a `base64`-encoded token longer than 64 chars without a mask. **Shipped 2026-04-26** via central `LogSink` message and `RuntimeEvent.detail` sanitization for `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, bearer tokens, and long base64-like tokens.
6. **Strict SNI hostname validation** (RFC 952 per-label) is already in `SNIParser` per AGENTS.md; add a property-based test that random garbage never produces a false positive. **Shipped 2026-04-26** with deterministic seeded random-garbage coverage.
7. **Keychain access-control list**: set the ACL on credential entries to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (we may already; verify), and limit allowed callers to Conduit bundle ID + helper daemon team ID.
8. **Tunnel credential rotation path**: every tunnel that has credentials should support invalidation + reload without the daemon restarting. Structured event on rotation.
9. **Privileged-action audit trail**: every call to the helper daemon via `PrivilegeClient` emits a structured `auth.privilege_request` event with the action and outcome. Makes "who changed my DNS?" answerable from events.
10. **Inbound gateway auth (`InboundAuthHandler`).** Enforce `strictMode` by requiring `Proxy-Authorization` from gateway clients. Server-side: `gss_accept_sec_context` for Negotiate, NTLM challenge-response. The `ProxyAuthenticator` protocol is already shaped for this; the implementation is new. Closes a long-standing gap where `strictMode` declared intent without enforcement. When we open the bind to `0.0.0.0` for Docker/VM/LAN we must be able to say "only authenticated clients get through."
11. **Upstream-proxy certificate pinning.** Per-upstream expected SPKI hash (or short fingerprint list for rotation windows) in config. Mismatch refuses the connection and emits a structured event. Defends against MITM between the app and the corporate proxy — a realistic threat on compromised-LAN networks and in tiered-corporate deployments where the proxy sits behind another inspection layer.
12. **Connection audit log.** Rolling, size-capped NDJSON at `$state-dir/audit.ndjson` recording CONNECT target, PAC decision, routing choice, and auth method per connection, with credentials masked. Complementary to `events.ndjson` (which carries runtime events). Purpose: compliance surface for enterprise users who need "what sites went through which upstream with which auth, when?" — answerable from the file alone.
13. **SOCKS5 auth hardening.** User/pass authentication alongside the current NO_AUTH mode. Per-client-CIDR allow-list enforcement for gateway deployments, evaluated in the SOCKS5 handler before routing. Builds on the existing gateway-mode allow-list pattern.

### Reliability work

1. **Network-transition hardening.** The hardest real-world failure mode is Wi-Fi → VPN → captive-portal → resume. Add a dedicated `pm-sim` scenario that cycles reachability and asserts `ProxyOrchestrator` recovers in < 5 s without leaking connections.
2. **Connection-pool back-pressure.** When `inboundConnectionMaxLimit` is hit, we currently reject. Verify the rejection path is fast (< 1 ms) and doesn't hold locks. Add scenario `connection-flood` to `pm-sim`.
3. **Auth-storm protection.** A misconfigured client can cause hundreds of 407 handshakes per second. Bound pending handshakes per-source-IP (already partly there via `inboundConnectionWarnThreshold`; formalize).
4. **DNS cache poisoning resistance.** The local DNS forwarder should refuse to cache responses that don't match the question it asked. Property test with random mutation.
5. **Kerberos credential expiry handling.** When the TGT expires mid-session, `NegotiateAuthenticator` should emit a structured event, attempt renewal, fall back to NTLM cleanly (this already works; add an explicit test).
6. **Upstream prober circuit breaker**: once an upstream fails N consecutive probes, enter open state; emit event; half-open after backoff; emit event; recover. Already largely present in `AutoRecovery`/`UpstreamProber`; formalize the state machine and add scenarios.
7. **Cleanup on crash.** If `pm-proxy` crashes, the state-dir socket and PID file should be recoverable on the next start without manual intervention. Test with SIGKILL during `pm-sim failover`.
8. **Tunnel health probes.** Per-tunnel lightweight connection probe on a configurable interval, mirroring the upstream health-probe pattern. A failing probe moves the tunnel into `warning` state without tearing down active sessions. Surfaces on the tunnels module card and via the control socket. Today's tunnels module reports session count but has no notion of reachability — add `pm-sim tunnel-flap` alongside.
9. **Graceful upgrade / zero-downtime restart.** The replacement daemon takes over the listening socket from the outgoing daemon without dropping in-flight connections. Unix-domain-socket file-descriptor handoff is the primary path (macOS-first, well-supported); `SO_REUSEPORT`-style coordination is a fallback. Makes `./bundle-app.sh --install` and auto-update invisible to clients mid-flight — a correctness-class improvement for daily-driver trust.

### Efficiency pass

1. **Profile under Instruments** with `pm-sim multi-100` (100 concurrent streams, 10 s). Record a baseline: RSS, CPU %, allocation count, p99 request latency.
2. **Target**: idle < 40 MB RSS, < 3% CPU; under `multi-100` load, < 200 MB RSS, < 40% CPU on an M-series Mac. Lock these in CI as perf tests using `XCTClockMetric`/`XCTMemoryMetric`.
3. **Allocation audit.** Use `malloc_stack_logging` to identify per-request allocations in `HTTPProxyHandler` and `CONNECTHandler`. Kill obvious wins (e.g., `ByteBuffer` reuse, header-value string interning for common values).
4. **NIO pipeline review.** Confirm no handler does synchronous work > 1 ms on the event loop (AGENTS.md already forbids it; we verify).
5. **Connection-pool hot path.** `ConnectionPool.swift` is 962 LOC — the biggest file. Read it with fresh eyes. Kill redundant locking. Document the invariant (active + idle ≤ capacity) as a `precondition` on every mutation.
6. **Startup latency.** Cold-boot `pm-proxy` should be < 200 ms to "ready" event on M1. Today it's probably < 300 ms already; measure and lock in.

### Exit criteria

- `docs/threat-model.md` written and reviewed.
- `SecretBytes` in use at every credential boundary.
- PAC resolver uses CFNetwork, not JavaScriptCore (JavaScriptCore dependency removed from `ProxyPAC`).
- Perf baseline recorded; CI regresses on >10% drift.
- Network-transition, connection-flood, auth-storm, tunnel-flap scenarios added to `pm-sim`, all green.
- No `import JavaScriptCore` anywhere in `Sources/`.
- Inbound `InboundAuthHandler` enforces `strictMode` end-to-end; covered by scenario tests.
- Upstream certificate pinning operational; mismatch event emitted and verified in scenario tests.
- `$state-dir/audit.ndjson` present, rotating, credential-masked.
- Tunnel health probe emits `warning` state without tearing down active sessions.
- Graceful-upgrade handoff path verified: a rolling `./bundle-app.sh --install` drops zero in-flight connections.

### Duration estimate

4-8 focused sessions. The threat model, CFNetwork swap, inbound-auth handler, and graceful-upgrade handoff are the biggest chunks.

## 2.6 Daemon-first architecture & control plane

**Goal:** The daemon runs without the UI. The menu bar, main app, and CLI are all clients of the same control plane. Closing the app must not kill the proxy.

### The shape

```
┌────────────────────┐
│  ConduitHelper│ (LaunchDaemon, privileged ops)
└─────────▲──────────┘
          │ XPC
┌─────────┴──────────┐
│   pm-proxy daemon  │ (LaunchAgent, user-level; runs ProxyOrchestrator)
│  — ControlSocket   │ — Unix domain socket at $state-dir/control.sock
│  — NDJSON events   │ — $state-dir/events.ndjson (rolling)
│  — Snapshot file   │ — $state-dir/snapshot.json (atomic)
└────▲────────▲──────┘
     │        │
     │        └──────────────┐
     │ Unix socket           │ NDJSON tail
 ┌───┴──────┐           ┌────┴────────┐
 │  pmctl   │           │  ProxyApp   │ (SwiftUI + MenuBar, optional)
 │  CLI     │           │  — DaemonClient
 └──────────┘           │  — MenuBarService
                        │  — FloatingStatus
                        └─────────────┘
```

### Tasks

1. **Promote `pm-proxy` to the daemon.** Today `pm-proxy` is a test harness that happens to serve real traffic; it becomes the first-class daemon binary. Renamed nothing; just reframed.
2. **Ship a LaunchAgent plist** for `pm-proxy`. Same model as `mac-proxy2`'s LaunchAgent, but user-level and point to our binary. `./install-launchagent.sh` script.
3. **Control socket** (`ConduitShared/ControlProtocol.swift`): a typed request/response JSON protocol over a Unix domain socket at `$state-dir/control.sock`. Commands:
   - `status` → `ProxyOrchestratorSnapshot`
   - `reload` → apply new config from disk, return `ConfigDiff`
   - `set-profile <name>` → switch preset
   - `test-upstream <name>` → probe one upstream, return latency + auth outcome
   - `kill-upstream <name> <ms>` (only if `--allow-fault-injection` flag) → for demos
   - `events --follow` → NDJSON stream
   - `stop` → graceful shutdown
   Server-side is tokio-free, just NIO on a `ServerSocket`.
4. **NDJSON event file** (`$state-dir/events.ndjson`) — rolling, capped at N events (STYLE rule 1). Any client can tail it; the menu bar does.
5. **Snapshot file** (`$state-dir/snapshot.json`) — atomic (write-temp-then-rename), updated every `--status-interval` seconds.
6. **`pmctl` CLI** — new target, thin, links `ConduitShared` only (not Core). Commands: `status`, `reload`, `profile ls`, `profile use <name>`, `events --follow`, `test <upstream>`, `diag` (dumps state for bug reports). `pmctl` is the UI-less user interface.
7. **`ProxyApp` adopts `DaemonClient`.** Today the app launches an in-process orchestrator. After this phase, the app:
   - detects whether the daemon is running via the control socket
   - if running, connects as a client; all "state" is derived from snapshots + event subscription
   - if not running, either launches the LaunchAgent or runs in-process (fallback mode, same binary)
   This is the single biggest architectural win of Plan A. The app becomes a *view of* the daemon, not the *owner of* it.
8. **Menu bar upgrade**. Today the menu bar reads from `AppState`. After this phase, the menu bar reads from `DaemonClient`. New menu bar items:
   - Current profile (with switcher)
   - Per-upstream traffic light (green/yellow/red from health events)
   - Direct-mode indicator
   - Active connection count
   - "Test upstream" sub-menu (triggers `pmctl test`)
   - "Copy diag bundle" (writes a sanitized diag archive to Desktop; for bug reports)
   - "Events…" (opens a rolling event viewer window)
   - "Reload config" / "Quit daemon" (guarded)
9. **LaunchAgent lifecycle.** Install / uninstall / upgrade via the existing `ConduitHelper` when escalation is needed; otherwise `launchctl bootout/bootstrap` from user space.
10. **Config hot reload with targeted subsystem reconfiguration.** The `reload` control-socket command applies the `ConfigDiff` subsystem-by-subsystem (auth, routing, DNS, tunnels, health, logging) without full runtime teardown. Active connections survive unrelated changes. Today's reload is process-level; this refinement is the difference between "restart" and "reload" in the systemd sense and makes config edits non-disruptive for daily-driver users.
11. **LaunchAgent watchdog.** `KeepAlive { SuccessfulExit = false }` restarts the daemon on unexpected crash; launchd handles exponential-backoff semantics; on the next startup the daemon emits a `lifecycle.crash_restart` event with the previous exit code so the reason is observable and not hidden in Console.app. Important for daily-driver trust: if the daemon crashes at 02:00, the user's morning coffee still goes through — and the event log shows what happened.
12. **Per-tunnel connection metrics via the control socket.** Bytes sent / received, uptime, detected protocol, last-activity timestamp, per-connection. The menu bar connections inspector and `pmctl status --verbose` consume this. Observability gap-filler for the tunnels module, which today reports session count but not per-session telemetry.

### Exit criteria

- `pm-proxy` runs as a LaunchAgent without the main app ever launching.
- `pmctl status` returns the running daemon's snapshot.
- Closing the main app leaves proxy traffic flowing.
- Menu bar traffic lights reflect upstream health within 5 s of a state change.
- The main app, force-quit-restarted, reconnects to the running daemon and shows the correct state.
- `pmctl reload` applies a DNS-only `ConfigDiff` without affecting in-flight HTTP or tunnel sessions.
- Killing the daemon process with `kill -9` causes an automatic restart within the LaunchAgent throttle window; next-start emits `lifecycle.crash_restart` with the prior exit code.
- Per-tunnel bytes / uptime / protocol / last-activity are visible in `pmctl status --verbose` and the menu bar connections inspector.

### Duration estimate

5-10 focused sessions. The control socket, `DaemonClient` rewiring of `AppState`, and targeted hot-reload path are the bulk.

## 2.7 UI excellence (Liquid Glass, HIG)

**Goal:** the UI feels *native to macOS 26*. Liquid Glass, proper materials, SF Symbols, correct spacing. The menu bar is enough for 90% of daily tasks.

This phase leans on the `liquid-glass` skill (read at task-start time). The points below are the product decisions; the skill carries the implementation discipline.

### Principles

1. **The menu bar is the product** for most users. The main window is the settings/observability/troubleshooting surface. Design for "never needs to open the app" as a feature.
2. **One navigation model** throughout the app. Sidebar + detail pane, not tabs + sheets + popovers mixed.
3. **Liquid Glass materials** where they belong (menu bar popovers, floating window, sheets) — not everywhere. Per HIG: glass is for chrome that sits over content, not content itself.
4. **SF Symbols only** for icons. No custom icons except the app bundle icon.
5. **HIG-correct spacing and typography.** `.callout` for secondary text, `.headline` for section titles, 16/12/8 pt rhythm.
6. **Dark-mode first**; light mode second. Our target user is a developer on a dark theme.

### Tasks

1. **Audit every view** against HIG. Catalogue violations (spacing, typography, missing affordances, non-dynamic-type-safe layouts). Triage to a spreadsheet; fix bottom-up.
2. **Menu bar rework** (coordinates with the daemon-first phase):
   - Liquid-Glass popover with:
     - Header: current profile, bindings (proxy / SOCKS / DNS)
     - Body: per-upstream mini-list with latency and traffic light
     - Body: last N events as a compact feed
     - Body: quick-toggle for gateway mode, direct mode, PAC
     - Footer: "Open Conduit", "Copy diag bundle", "Quit daemon"
3. **Floating status window** (opt-in): minimal, always-on-top, shows proxy state and the last 5 events. For screen-sharing or demo use.
4. **Settings redesign**. Current settings are functional; after this phase they're *pleasant*. Sections match `ProxyConfig` sections (proxy, auth, routing, DNS, tunnels, health, logging, appearance, advanced). Each section has inline validation feedback from `ConfigValidation`.
5. **Event inspector window** — a live view into `RuntimeEventLog`, filterable by kind, copyable, exportable. The UI equivalent of `pmctl events --follow` with filters.
6. **Upstream detail sheet** — per-upstream latency chart (sparkline), last N auth outcomes, "test now" button, "disable temporarily" toggle.
7. **Accessibility pass.** Full VoiceOver support; Dynamic Type on every label; high-contrast validation.
8. **Launch-at-login UX.** Today `SMAppService` integration exists; surface it as a first-class toggle in Settings → Appearance with a clear explanation.

### Exit criteria

- Every daily task (toggle proxy, switch profile, see health, inspect last failure) is doable from the menu bar without opening the main window.
- No HIG violations on a random-sample audit of 20 views.
- TestFlight beta with ≥3 testers for ≥2 weeks before GA-equivalent release.

### Duration estimate

6-10 focused sessions. UI work is where hours disappear quickly.

## 2.8 Simulators & chaos demos

**Goal:** every runtime behaviour is testable and demonstrable. `pm-sim` is the testing workhorse; a demo mode visualizes the event stream live.

### Expand `pm-sim`

`pm-sim` already has: `baseline`, `silent-then-burst`, `multi`, `multi-small`, `high-throughput`, `multi-100`, `long-silent`, `keepalive`, `health-check`, `failover`, `flood-slow-drain`. Add:

- `network-transition` — simulate Wi-Fi → VPN → captive portal → resume. Assert recovery < 5 s, zero connection leaks.
- `auth-expiry` — mid-session TGT expiry, assert NTLM fallback without client-visible failure.
- `connection-flood` — saturate `inboundConnectionMaxLimit`, assert back-pressure is fast and doesn't starve other requests.
- `auth-storm` — 500 rps of forced 407s from a client, assert bounded pending-auth queue holds.
- `pac-fallback` — PAC returns `PROXY a; PROXY b; DIRECT`, a and b unreachable, assert DIRECT is taken and an event is emitted.
- `dns-poison-attempt` — forwarder receives a response whose question doesn't match; assert it's discarded.
- `tunnel-rotation` — tunnel config reloads; assert in-flight sessions continue, new sessions use new config.
- `upstream-flap` — upstream goes up/down repeatedly; assert circuit breaker opens and eventually half-opens.
- `socks5-mixed` — SOCKS5 client alongside HTTP client on the same daemon, both through same upstream chain.
- `gateway-mode` — bind to 0.0.0.0, non-local client allowed, non-whitelisted client rejected.

Each scenario emits NDJSON results (already established pattern) and exits non-zero on assertion failure. CI runs the full suite per PR.

### Chaos demo mode

Build a native **SwiftUI "Chaos Demo" window** in `ProxyApp` (not a separate TUI). It is **off by default** and enabled by a debug flag or a hidden menu item. Rationale:

- We're a native macOS app; users have a screen. A SwiftUI dashboard is higher-fidelity than a TUI and requires no extra dep.
- It reuses the same `DaemonClient` event subscription as the menu bar.
- It lives in the main app, not shipped to users by default (guarded behind `ProxyApp.isDevelopmentBuild`).

The demo window has three panes:

1. **State** — live view of `ProxyOrchestratorSnapshot`: upstreams with traffic lights and latencies, proxy/SOCKS/DNS bindings, active connection count, auth state, current profile.
2. **Event stream** — the last N events, color-coded by kind (lifecycle / routing / auth / connection / health / config), filterable.
3. **Fault injector** — buttons:
   - "Kill upstream A/B/C" (sends `pmctl kill-upstream <name> 15000`)
   - "Expire TGT" (client-side: `kdestroy`; server watches the auth event)
   - "Cut network" (simulates via `NetworkMonitor` test hook — tolerated in dev builds only)
   - "Saturate" (triggers `pm-sim multi-100` in-proc against the running daemon)
   - "Reset all" (clears all injected faults)

The fault-injection surface lives in a separate `DevTools` module, compiled only in non-App-Store builds (`#if DEBUG || SELF_SIGNED`), so shipped App Store builds (if we ever ship there) don't contain fault-injection paths.

### Demo video

Once the chaos demo mode is done, record a 60-second screen capture of:

1. Daemon started, healthy.
2. Kill upstream → menu-bar traffic light goes red for 2 s → auto-failover → green on a different upstream → one browser request that *never saw the failure*.
3. Expire TGT → Kerberos fails → NTLM fallback event → request succeeds.
4. Reset → menu bar fully green.

This is the "demo video" equivalent of TigerBeetle's chaos talk. It's evidence, not marketing.

### Exit criteria

- `pm-sim` suite runs in CI and gates PRs.
- Chaos demo window subscribes to the real running daemon via control socket.
- At least one public-facing recording exists for the README.

### Duration estimate

3-6 focused sessions. `pm-sim` scenarios are mostly copy-paste of existing patterns.

## 2.9 Open-source preparation

**Goal:** the project is usable by people who aren't the original author and aren't at the organization it was first built for.

### Tasks

1. **Vendor-specific preset externalization.** `CorporatePreset.swift` → `Resources/Presets/example-corp.json` (or `.toml` if we migrate config format first). Loaded on `pmctl apply-preset example-corp`. Ship 2–3 example presets (empty/generic, an example corporate preset, a "self-hosted Squid" preset).
2. **Repository rename / brand.** Current name is fine (`Conduit`). Tagline: *"A macOS-native corporate proxy manager with real failover."*
3. **License**. MIT or Apache-2.0. Apache-2.0 has an explicit patent grant which is better for corporate users. Default: Apache-2.0.
4. **Architecture doc** (`docs/architecture.md` — already referenced in AGENTS.md). Fill out with the module diagram from §2.2 and the daemon/client diagram from §2.6.
5. **Getting-started guide** (`docs/getting-started.md`): install, run headless with `pm-proxy`, configure an upstream, enable PAC, verify with `curl -x localhost:3128`.
6. **Configuration reference** (`docs/configuration.md`): every field in `ProxyConfig` documented with units, defaults, validation rules.
7. **Threat-model doc** (produced during security hardening — link from README).
8. **CI for macOS**. GitHub Actions running `swift build` + `swift test` + `pm-sim` matrix on macOS 26.x runners. No Linux/Windows until Plan B.
9. **Homebrew formula** — `brew install proxymanager`. Formula lives in a `homebrew-proxymanager` tap or eventually homebrew-core.
10. **Notarization & Developer ID signing** for the `.app` and the helper. Document the signing identity in a `docs/releasing.md`.
11. **Semantic versioning policy.** 0.x = breaking changes allowed. 1.0 = when the macOS daily-driver-survival criteria (§2.1 Reliability) are met.
12. **`SMAppService` signed privileged helper.** Replaces the current LaunchDaemon + manual `sudo ./install-helper.sh` flow with Apple's signed-helper model. Unlocks two things: (a) Jamf / MDM enterprise distribution — the current hand-rolled flow is developer-friendly but blocks IT rollouts — and (b) `NEDNSProxyProvider` for userspace DNS interception, which lets tunnel DNS override drop its `/etc/resolver/` fallback path entirely. Depends on item 10 (Developer ID signing). This is the single biggest "unlock" for enterprise adoption and for simplifying the DNS override architecture.
13. **Credential isolation via Data Protection Keychain.** Migrate from the login Keychain to the Data Protection Keychain, which requires a signed app. Eliminates the ACL-prompt UX friction users hit on first auth and aligns with Apple's current best practice for credential storage. Paired with `SecretBytes` (§2.5, security hardening) it closes the Keychain-to-process credential path end-to-end.
14. **Config backup / restore with versioned schema migration.** Export and import `ProxyConfig` as JSON with an explicit schema version in the file; automatic upgrade path for older configs loaded after a breaking change. Enables team sharing ("send me your config"), cross-machine setup, and safe config-format evolution across versions. The schema-migration piece is what makes the SemVer 1.0 promise honorable — we can change the schema in 2.0 without stranding 1.0 users.

### Exit criteria

- A colleague unfamiliar with the project can clone, build, install, configure, and run the thing from `docs/getting-started.md` alone.
- `brew install` works.
- The repository contains zero employer-specific strings outside `Resources/Presets/example-corp.json` and `docs/`.
- `.app` and helper are Developer-ID signed and notarized; Gatekeeper is silent on first launch.
- `SMAppService` installs the helper without `sudo`; uninstall removes it cleanly.
- Credentials live in the Data Protection Keychain; no ACL prompts during auth flows.
- Config export-then-import across a schema-breaking change succeeds via the migration path.

### Duration estimate

3–5 focused sessions + release-engineering bureaucracy.

## 2.10 Enterprise addenda (post-1.0, not part of the core critical path)

Enterprise IT adoption compounds on Plan A's core product but introduces integration work that doesn't drive daily-driver quality. These items are acknowledged, tracked in `ROADMAP.md` under "Enterprise addenda," and intentionally deferred. None of them should delay the core phases; they land post-1.0 at earliest.

- **MDM / managed-preferences profile** for `io.github.srps.Conduit`. IT can push upstream proxies, PAC URLs, auth mode, tunnel definitions, DNS settings; the app reads the managed `UserDefaults` domain on launch and locks managed fields in the UI.
- **`.pkg` installer** with helper bundled for Jamf / Munki / Intune silent deployment. Replaces the manual `./install-helper.sh` step in the enterprise path.
- **Automatic updates** (Sparkle or equivalent) for self-update without IT involvement. Gated on Developer ID signing + notarization (§2.9 item 10).
- **OpenTelemetry-compatible telemetry export** — opt-in, complementary to the NDJSON event stream (§2.6), not a replacement. Enables Splunk / Datadog / Grafana integration for enterprises that run centralized observability.
- **Helper-binary tamper detection** — verify the helper binary hash on startup; refuse to start and emit a `security.helper_tamper` event on mismatch. Defends against post-install binary replacement.

These items share a common gate: they only make sense *after* the core Plan A product is itself solid. Shipping a telemetry pipeline for a tool that still has daily-driver regressions is backwards.

---

# PART 3 — Plan B (OPTIONAL): Rust port

Plan B is **not active work**. It is preserved here in full so that if and when we decide to trigger it, the research and design decisions from April 2026 are not lost. The trigger conditions are explicit so "should we start Rust now?" always has a clear answer.

## 3.1 When (not) to trigger Plan B

### Triggers

Plan B is activated when **at least two** of the following hold true:

1. **Demand signal**: ≥ 10 Windows or Linux users have filed issues or emailed asking for a port *after* Plan A has shipped (not before — we don't want theoretical users driving work).
2. **Stability signal**: Plan A's macOS release has survived ≥ 90 days of daily driving with zero "I had to restart it" moments (§2.1 Reliability exit).
3. **Personal signal**: you are bored with Swift maintenance and want to learn Rust *as a project*, not as a side-quest. This is a valid reason — label it honestly.
4. **Ecosystem signal**: `sspi-rs` 0.19.2+ has stabilized (no new NTLM/Kerberos regressions for 6+ months) **or** you've committed to the `libgssapi` + hand-rolled-NTLM path (which doesn't depend on `sspi-rs` stabilizing).

### Non-triggers (do not trigger Plan B on these alone)

- "I want to learn Rust." → Do a bounded exercise, not a rewrite.
- "Conduit should be cross-platform." → That's aspiration, not demand.
- "px has bugs and I could do better." → px works. Users who want px's niche already use px.
- "Ghostty's architecture is beautiful." → See §5.7; Ghostty's architecture also had to be rewritten.

### Anti-triggers (reasons to specifically not do Plan B)

- **SASE adoption** at the corporate users we care about. Zscaler Client Connector, Netskope, Microsoft Entra Private Access, Cloudflare One — if these land at the typical target customer (large-enterprise-shaped orgs), the legacy explicit-proxy niche collapses and Plan B serves an evaporating market.
- **Solo-maintainer reality.** Maintaining two production runtimes in parallel is infeasible. Plan B starts only if you're willing to freeze Swift runtime features at feature parity and accept that the Swift codebase becomes a client of the Rust runtime eventually (as the original plan described).

## 3.2 Preserved Rust architecture

If Plan B activates, the shape is:

```
libproxymanager (Rust, ~4 crates — not 7)

├── pm-core           config (serde), models, events, traits, errors
├── pm-runtime        orchestrator, HTTP proxy (hyper 1.x), SOCKS5 (fast-socks5),
│                     DNS forwarder (hickory-dns), tunnels, connection pool,
│                     CONNECT coordinator, health/recovery/circuit breaker,
│                     direct-connect detection
├── pm-auth           ProxyAuthenticator trait, hand-rolled NTLMv2 (port of Swift 279 LOC),
│                     Kerberos/SPNEGO via libgssapi (Linux/macOS) + native SSPI (Windows
│                     via cross-krb5 or windows-rs), CredentialProvider trait
├── pm-platform       macOS: GSS.framework FFI (if we use native TGT ccache) + Keychain +
│                          networksetup (platform-integration phase only)
│                     Windows: windows-rs + windows-service + WinHTTP
│                     Linux: libsecret + systemd-resolved + nftables
└── (PAC evaluator lives in pm-runtime, not a separate crate, using rquickjs)

Clients (separate crates):
├── pmctl             CLI
├── pmd               daemon binary (== pm-proxy in today's Swift world)
└── ui-macos          Swift/SwiftUI, calls libproxymanager via Unix-socket control plane
                      (not C FFI — see §3.3 for why)
```

**Why 4 crates not 7**: same reason as §2.2. Modularity earns its keep when a module is imported independently; until then, files in different folders of one crate are sufficient.

**Why Unix-socket IPC instead of C FFI to Swift**: Ghostty's own 1.2 C API remains unstabilized (§5.7). Coupling Swift's lifetime management to a Rust library through a C ABI is exactly the class of bugs Hashimoto called out in the GTK rewrite post-mortem. A control socket + NDJSON events is the less-clever, more-robust choice and matches the Plan A daemon architecture (§2.6).

### Phased Rust plan (if triggered)

1. **Skeleton**: workspace, `pm-core`, `pm-runtime` stub that can proxy HTTP with hand-rolled NTLM to a corporate upstream.
2. **Parity**: SOCKS5, DNS+DoH, PAC (rquickjs), tunnels, direct-connect, auto-recovery, Kerberos (`libgssapi`), transparent TCP proxy. Each is validated in daily use. No feature moves forward until the previous is production-quality.
3. **Platform integration**: Windows (sspi via `cross-krb5`, Credential Manager, WinHTTP, Windows Service), Linux (libsecret, systemd, polkit), macOS (the existing Swift shell becomes a client of `pmd` via the same control protocol from §2.6).
4. **Open source (Windows/Linux)**: CI matrix, `.msi` / `.deb` / `.rpm` packaging.

## 3.3 The Rust stack, justified

Every dependency decision below is traced to research in Part 5. If reality changes, the table changes.

| Layer | Choice | Why (short) | Why not alternatives |
|---|---|---|---|
| Async runtime | **tokio 1.52** | LIFO steal + sharded `spawn_blocking`, production default | §5.5: no real alternative for this workload |
| HTTP server | **hyper 1.x + hyper-util (feature-gated)** | First-class `CONNECT` upgrade; used by every Rust forward proxy that ships | §5.2: pingora explicitly disables CONNECT; rama is pre-1.0 and churning |
| HTTP parser fallback | **httparse** | Zero-alloc, used by linkerd2-proxy, shadowsocks | §5.2 |
| SOCKS5 | **fast-socks5 1.0** | MIT, tokio-native, production-used | §5.5: socks5-proto is GPL-3.0 and stale |
| TLS | **rustls 0.23** | aws-lc-rs backend, FIPS optional, production-used | §5.5: rustls-mitm pattern is well-known |
| DNS | **hickory-dns 0.25 / 0.26-beta** | Actively maintained rename of trust-dns; DoH built-in | §5.5: domain/simple-dns are sub-scope |
| JS engine (PAC) | **rquickjs (QuickJS-NG) 0.11** | What pacparser migrated to in Feb 2026; 500 KB – 1 MB; better real-PAC compat than boa | §5.4: boa at 94.12% Test262 fails real Zscaler PACs; V8 too heavy |
| Kerberos | **libgssapi (macOS/Linux) + cross-krb5 (cross-platform wrapper)** | Native TGT access on macOS via GSS.framework; uses system SSPI on Windows | §5.3: sspi-rs on macOS is pure-Rust reimpl, no ccache access; has regressed in 0.18.x–0.19.1 |
| NTLM | **hand-rolled port of `NTLMAuth.swift`** (279 LOC Swift → ~500 LOC Rust) | Protocol frozen since early 2000s (MS-NLMP); already battle-tested against a corporate proxy | §5.3: sspi-rs doesn't handle `Proxy-Authorization` plumbing; `winauth 0.0.5` is a fine reference if we want |
| Credential storage | **keyring-rs 4.0** | Unified API: Keychain / Windows Credential Manager / libsecret | §5.1: no Swift equivalent exists for Windows/Linux |
| TUI (if we want a Rust chaos demo) | **ratatui 0.30** | Healthy, modular, production-used | §5.5: cursive is smaller community; tui-rs is dead |
| Config | **serde + toml crate** | Standard in the ecosystem | N/A |
| HTTP client for upstream probes | **reqwest or raw hyper Client** | Depends on how much control we want over 407 retry state | §5.2: hyper-util `Tunnel` or hand-rolled CONNECT are both fine |

**Explicitly excluded:**

- **`sspi-rs`**: no HTTP proxy plumbing, no native macOS TGT, known 2026 regressions, 73 stars, effectively zero HTTP-proxy production users. §5.3.
- **`pingora`**: maintainers explicitly do not support forward-proxy CONNECT ("Pingora doesn't implement typical protocols such as HTTP CONNECT"). §5.2.
- **`rama`**: pre-1.0, breaking changes landing quarterly, large abstraction surface we don't need. §5.2.
- **`boa_engine` as default PAC**: 94.12% Test262 means real-world PACs (Zscaler-generated) will silently fail on regex/closure edge cases. §5.4.
- **Zig DNS / Odin NTLM side-quests**: see Part 4.

---

# PART 4 — What NOT to do

These are specific anti-commitments. Violating one should require an explicit decision documented in this file.

1. **Don't build a chaos TUI in Rust for this macOS product.** The chaos demo is SwiftUI in the main app. A Rust `ratatui` chaos dashboard is Plan-B-only, and even then it's optional.
2. **Don't write a DNS parser in Zig** and link it into Swift or Rust. `DNSWireFormat.swift` works. `hickory-proto` works. Zig's stdlib (§5.5) just shipped a breaking `std.io`→`std.Io` rewrite on Apr 14, 2026; expect annual Writergates.
3. **Don't write NTLM in Odin** (or Zig) and link it into production. Odin has bus factor 1, no production users of Rust-consumed C ABI exports, and no `cbindgen` equivalent. If you want to *learn* Odin, port `NoProxyMatcher` (75 LOC, pure) over a weekend as a throw-away.
4. **Don't adopt `sspi-rs`** for NTLM/Kerberos without a cost-benefit writeup. See §5.3.
5. **Don't adopt `pingora`** for forward-proxy work. See §5.2.
6. **Don't promise a stabilized C ABI** for external embedders. Ghostty hasn't after 4 years (§5.7). We won't either. If Plan B activates, the public API is a Unix-socket control protocol, not a C ABI.
7. **Don't split `ProxyKernel` into more than 5 targets.** Over-decomposition is latency for no readability gain.
8. **Don't add features to the Swift codebase that don't fit a product pillar (§2.1).** New capabilities pay for themselves in Reliability / Security / Efficiency / Observability / UX / Daemon / Simulators, or they don't ship.
9. **Don't design the control-plane IPC protocol for extensibility before v1.** Start with the 8 commands in §2.6; add more when a client needs them.
10. **Don't maintain two runtimes in parallel.** If Plan B triggers, Swift runtime work freezes at the time of trigger. The SwiftUI app survives; `ProxyKernel` goes into maintenance mode.
11. **Don't add a global "verbose log everything" mode as the primary debugging path.** Structured events first (STYLE rule 3). Log verbosity is a last-resort view, not the default.
12. **Don't assume JavaScriptCore is acceptable for PAC long-term.** CFNetwork is the macOS answer (§2.5, §5.4); rquickjs is the cross-platform answer.

---

# PART 5 — Research archive

This section is the *reason* for every decision above. Every claim is dated April 2026 based on the research pass performed for this plan revision. When reality changes, revisit.

## 5.1 Swift cross-platform viability (April 2026)

**Verdict**: Swift is fine for macOS. It is **not viable for a proxy daemon on Windows** today. Linux is possible but offers no ergonomic win over Rust for our stack.

### Windows blockers

| Blocker | Evidence |
|---|---|
| **SwiftNIO on Windows is pre-production** with known-broken TCP semantics for proxy workloads | [Mid-2025 status thread](https://forums.swift.org/t/mid-year-2025-swiftnio-for-windows-status/81143); PR [#3433](https://github.com/apple/swift-nio/pull/3433) "Winsock Fixes" open since Nov 2025 and still under review; known bug: *"TCP client connections to Windows servers don't read/write until a second connection arrives"*. No `NIOWindows` target shipping as of April 2026. |
| **No maintained Swift Kerberos/GSSAPI wrapper** | `PerfectlySoft/Perfect-SPNEGO` — last commit 2018. Nothing else. |
| **No Swift SSPI binding** | Would require hand-authoring `module.modulemap` over `sspi.h` and manually marshalling `SecBufferDesc` / `CtxtHandle`. |
| **No Windows Service support** in `swift-service-lifecycle` | [Issue #196](https://github.com/swift-server/swift-service-lifecycle/issues/196): explicitly POSIX-only. |
| **ABI not stable on Windows/Linux** | Apple's own [ABI Stability Manifesto](https://www.swift.org/blog/abi-stability-and-more/): *"Windows is maturing, but there is still a long path to get to the point where we should start thinking about ABI stability."* Swift runtime DLLs must ship with every release. |
| **`swift-system` Windows surface is officially "Unstable"** | Minor releases can be source-breaking. |
| **Toolchain instability in Q1 2026** | Nightly installers shipping without required DLLs (`_CompilerSwiftScan.dll`, `mimalloc-redirect.dll`) — swift#86191, swift#88376. ARM64 release/6.3 branch has 274 test failures (swift#86529). |

### Positives (2026)

- **Swift 6.3 shipped March 24, 2026** with cross-platform build improvements.
- **Official Windows Workgroup** formed Jan 2026 — first formal corporate commitment.
- **Static Linux SDK** is real (Tuist uses it) but there's no Windows equivalent.
- The Browser Company ships Arc on Windows in Swift — proof it *can* ship, though Arc is a GUI app, not a long-running networked service.

### Linux positives

- `swift build` + `swift test` generally work.
- Foundation-on-Linux has improved substantially.
- Static musl target exists.

### Linux negatives

- Still must hand-roll `libkrb5`/`libgssapi` FFI (no maintained Swift wrapper).
- Still must hand-roll `libsecret` FFI (no `keyring-rs` equivalent).
- Still on unstable ABI — runtime ships with releases.

### Interpretation

For Plan A (macOS-only), Swift is the right tool — it's our comfort zone, the codebase already exists, and macOS is the primary target. For Plan B (cross-platform, if triggered), Swift-on-Windows is a non-starter; Rust is the answer. There is no path where Swift-everywhere makes sense in 2026.

## 5.2 Rust forward-proxy stack

**Verdict**: hyper 1.x + tokio + httparse + fast-socks5 is the 2026 correct answer. Pingora and rama are out. (Relevant only if Plan B activates.)

### hyper 1.x — **recommended**

- **Latest stable**: 1.8.1 (2025-11-13); 1.9.0 scheduled 2026-03-31.
- **CONNECT support**: first-class via `hyper::upgrade::on(req).await`. The `examples/http_proxy.rs` in-repo demonstrates exactly the forward-proxy CONNECT pattern.
- **hyper-util 0.1.20** (2026-02-02) provides connection pool, CONNECT tunnel client (`Tunnel` with custom `Proxy-Authorization`), and h1/h2 auto-negotiation. Cherry-pick features; avoid default-features bloat.
- **500M+ downloads; 1.9k+ direct deps.** Every production Rust forward proxy uses it.

### pingora — **rejected**

- **0.8.0 (Mar 2026)** actively regressed CONNECT: returns 405 by default unless `allow_connect_method_proxying` is set.
- [Maintainer](https://github.com/cloudflare/pingora/issues/224): *"Pingora doesn't implement typical protocols such as HTTP CONNECT, PROXY protocol or SOCKS. So it does not work out of box with clients that expect one of these protocols."*
- Phase graph (`ProxyHttp` trait with `upstream_peer` / request filter / response filter / logging) is reverse-proxy-shaped and fights forward-proxy semantics (per-connection 407 state, connection pinning across Type 1/2/3).
- Idle footprint dominated by `Server` + `Service` + background-service runtime, designed for fleet services, excessive for a desktop daemon.
- **No production Rust forward proxy uses pingora.**

### rama — **rejected (for now)**

- **0.3.0-alpha.4 (2025-12-27)**, stable 0.3 planned for late Jan 2026.
- Service-graph framework with fingerprinting, TLS, HTTP/SOCKS5, telemetry. Used in production by commercial partners.
- Pre-1.0 with major architectural churn (they forked parts of `http`; the `Context` type was removed wholesale in 0.3).
- Fine for a multi-protocol gateway product; overkill and unstable for a single-binary forward proxy.

### Raw tokio + httparse — **use selectively**

- **httparse 1.10.1** (2025-03-03) — zero-alloc, zero-copy, used by hyper internally, shadowsocks, linkerd2-proxy, reqwest.
- Appropriate for tight control over a specific hot path (custom pre-parse for transparent-mode sniffing, etc.). Not appropriate as the whole HTTP/1.1 framer — hyper is 500–800 LOC you don't write.

### SOCKS5

- **fast-socks5 1.0.0** (2026-01-20) — MIT, tokio-native, SOCKS5+4+4a, UDP+TCP, user/pass + custom auth, 1.5M+ downloads. **Use this.**
- `socks5-proto 0.4.1` / `socks5-server 0.10.1` (EAimTY) — lower-level, **GPL-3.0** (kill-switch for shipping), stale since Apr 2024. **Skip.**

### Reference implementations (for learning)

- **Tinyproxy** (C, ~2 MB RSS): closest philosophical match to "single-binary desktop daemon." Reads well.
- **https_proxy** (Rust, hyper+tokio, ~7 MB binary with LTO): existing proof that hyper is the right layer for this use case. 407 auth, CONNECT tunneling, HTTP/2 extended CONNECT (RFC 8441).
- **linkerd2-proxy** (Rust, hyper+tower+rustls+tokio): service-mesh proxy; good reference for production-scale event loop.
- **mitmproxy** (Python+asyncio): study its `ConnectionHandler` layered-protocol design.
- **Squid** (C++ AsyncJob): 20+ years of corner cases; consult when hit by a weird interaction.

## 5.3 NTLM / Kerberos / SPNEGO libraries

**Verdict**: For macOS today (Plan A), keep the Swift implementations. For Plan B if triggered: port the Swift NTLMv2 to Rust by hand (~500 LOC) and use `libgssapi` / `cross-krb5` for Kerberos/SPNEGO. **Do not adopt `sspi-rs`.**

### sspi-rs (Devolutions) — detailed

- **Latest crate**: `sspi 0.19.2` (Mar 2026). GitHub tag `v2026.03.27.0`. Last push Mar 30, 2026. 73 stars, 33 forks, 40 contributors.
- **Reverse deps**: 8 on crates.io, almost all Devolutions' own tools (`ironrdp`, `jetsocat`, `picky-ldap`).
- **Activity**: multiple 2026 releases; dependabot weekly; Kerberos-first-with-NTLM fallback actually works as of v0.19.1 (Mar 13, 2026).
- **Regressions of concern**: Issue [#640](https://github.com/Devolutions/sspi-rs/issues/640) — NTLM broken in 0.18.8–0.19.1 when `USE_SESSION_KEY` is requested without Kerberos. Tested matrix on Dell PowerScale: v0.18.7 = 53/53 pass, v0.18.8 = 0/53. Only fully fixed in 0.19.2. Direct relevance: corporate proxies are often IP-addressed and non-domain-joined, which is exactly what broke.
- **Does NOT handle `Proxy-Authorization`.** You parse 407s, you pin the TCP connection across Type 1→407→Type 3, you base64-wrap tokens. The HTTP-proxy-specific plumbing is on you regardless.
- **On macOS**: pure-Rust reimplementation via `picky-krb` / `picky-asn1-*`. Does **not** call GSS.framework or read the user's `kinit` ccache without explicit work. Loss of SSO.
- **Dependency tax**: `picky-*` chain adds ~15 transitive crates (ASN.1, X.509, Kerberos, RC4/DES/AES/HMAC). Several MB of `.text`.
- **Production users for HTTP proxies**: effectively zero. Users are FreeRDP, RDP gateway, LDAP clients, SQL Server (via `tiberius`).

### Alternatives that *are* appropriate

| Crate | Latest | NTLM | Kerberos | macOS | Notes |
|---|---|:--:|:--:|---|---|
| **libgssapi 0.9.1** (estokes, Jul 2025) | — | ✗ | ✓ | via Heimdal/GSS.framework | Best when you want native ccache/TGT on macOS |
| **cross-krb5 0.4.2** (estokes, Jun 2025) | — | ✗ | ✓ | ✓ | Single API across libgssapi (*nix) + system sspi (Windows). Use this for Plan B cross-platform Kerberos. |
| **winauth 0.0.5** (steffengy, Mar 2024) | — | ✓ NTLMv2 only | ✗ | pure Rust | 600 LOC, MS-NLMP-faithful, supports channel bindings. Good reference or drop-in. |
| **ntlmclient 0.2.0** (Nov 2024) | — | ✓ | ✗ | pure Rust | Alternative to winauth |
| **reqwest-negotiate 0.1.0** (Jan 2026) | — | ✗ | ✓ | via Heimdal | Uses `libgssapi`. Client-side only (not proxy auth), but proves the integration pattern. |
| **krb5proxy 0.1.8** (veldrane, Oct 2025) | — | ✗ | ✓ | Linux only | Rust forward proxy that injects `Proxy-Authorization: Negotiate`. cntlm-for-Kerberos. |

### What cntlm, px, gontlm-proxy actually use

- **cntlm** (C, `versat` fork): fully in-tree NTLMv2 in `ntlm.c`. Zero external crypto. This is the blueprint for our hand-rolled port.
- **px** (Python): Windows via SSPI (`pywin32`); Linux/macOS via libcurl built with GSSAPI/krb5. Doesn't implement NTLM itself — delegates to libcurl.
- **gontlm-proxy** (Go): Windows SSPI via `go-ntlmssp`, no pure-Go NTLMv2 path, Windows-only really.

### HTTP-proxy auth gotchas (universal, not library-specific)

1. **TCP connection affinity.** NTLM authenticates the *connection*, not the request. The pool must pin the socket across Type 1 → 407+Type 2 → Type 3. `Connection: close` on any leg restarts from scratch. Already handled by our `CONNECTHandler` + `ConnectionPool`; verify when porting.
2. **CONNECT vs. non-CONNECT.** Authenticate the tunnel hop first (three-leg handshake on the proxy), then open the tunnel, then do TLS. Some proxies send periodic mid-tunnel 407s (Zscaler, Bluecoat).
3. **Channel bindings (EPA / CBT).** NTLMv2 with Extended Protection for Authentication hashes the TLS server-cert. Our NTLM doesn't support this today; relevant when proxy enforces EPA.
4. **SPN for the proxy.** Kerberos to the proxy is `HTTP/proxy.corp.example.com` — *not* the origin host. Lots of implementations get this wrong.
5. **IP-addressed proxies** trigger sspi-rs's (broken until 0.19.2) IP-SPN path. If ever adopting, pin ≥ 0.19.2.
6. **Target name for NTLM.** Echo Type 2's `TargetName` AV-pair in Type 3. cntlm does this; verify our Swift NTLM does.
7. **macOS TGT.** `sspi-rs` will not read the macOS ccache. `libgssapi` or direct GSS.framework FFI is needed for SSO.
8. **Unicode in passwords.** NTLMv2 requires UTF-16LE. Easy to get wrong.

## 5.4 PAC evaluation

**Verdict (Plan A, macOS)**: replace JavaScriptCore with `CFNetworkExecuteProxyAutoConfigurationURL`. Zero binary overhead, Safari-parity behavior, Apple-maintained security surface. **Verdict (Plan B, cross-platform)**: `rquickjs` (QuickJS-NG). Do *not* use `boa_engine`. Do *not* write a PAC-subset interpreter.

### CFNetworkExecuteProxyAutoConfigurationURL (macOS) — **recommended**

- Zero binary cost; system-maintained; what Safari uses.
- Known quirks: 5-second internal timeout (we wrap with our own); silent drop of `HTTPS` return keyword (our route normalizer should tolerate this); `PACClient` retain cycle (wrap in `autoreleasepool`).
- Our current `PACResolver.swift` uses `JavaScriptCore`. Migration is a module-scoped swap; the `PacEvaluator` protocol lands in `ProxyKernel` (abstractions), `PACResolver` moves to `ProxyPAC` as the CFNetwork-backed impl.

### rquickjs (QuickJS-NG) — cross-platform recommendation

- **Latest**: 0.11.0 (Dec 24, 2025). Repo pushed Mar 31, 2026. MSRV 1.85.
- Wraps **QuickJS-NG**, the actively-maintained fork of Bellard's QuickJS (upstream is dormant).
- Binary cost: 500 KB – 1 MB stripped. Runtime create/teardown < 300 μs.
- Near-complete ES2020; higher real-world PAC compatibility than boa today.
- **pacparser 1.5.0 (Feb 8, 2026) just migrated from SpiderMonkey to QuickJS.** The most experienced PAC implementer alive picked QuickJS in 2026. That's the strongest possible signal.
- Requires a C compiler in CI.

### boa_engine — **not for production PAC**

- **Latest**: 0.21.1 (Mar 29, 2026). Register-based VM, NaN-boxed `JsValue` since 0.21 (Oct 2025).
- **Test262**: 94.12% — ~6% of real-world ECMAScript behavior fails. Includes regex Annex-B semantics, `String.replace` with function callbacks, closure corner cases — exactly what Zscaler-generated corporate PACs use.
- Self-describes as "experimental" in README.
- **If used**, users will hit silent PAC returns-DIRECT bugs that are near-impossible to diagnose.
- Acceptable for a *learning* PAC evaluator. Not for a product.

### rusty_v8 — **too heavy**

- V8 is 600k+ LOC C++. Binary cost tens of MB; cold start orders of magnitude worse than QuickJS.
- Chromium uses V8 for PAC only because V8 is already in-process. We are not in-process.

### Is "PAC-subset interpreter" viable?

**No.** Research is unambiguous:

1. Real PAC files are not a clean subset. Closures, regex with Annex-B, `String.prototype.replace` with function callbacks, sometimes ES6 chunks. Zscaler-generated PACs rotate.
2. The only project that tried (Java `hudeany/ProxyAutoConfig`) self-documents as *"far from being a perfect JavaScript interpreter."*
3. Savings (~500 KB vs rquickjs) are negative against the maintenance and security burden of owning a JS parser.

### What browsers and tools use

| Stack | PAC engine |
|---|---|
| Chromium / Chrome / Edge | V8 in-process (memory-tuned flags; isolated `proxy_resolver` in some builds) |
| Firefox | SpiderMonkey (`netwerk/base/ProxyAutoConfig.cpp`) |
| WebKit / Safari / macOS apps | `CFNetworkExecuteProxyAutoConfigurationURL` (system service) |
| curl | **None.** Official guidance: pre-resolve manually or run a PAC-aware local proxy |
| libproxy 0.5.x | Duktape via `pacrunner-duktape` plugin |
| pacparser 1.5.0 (Feb 2026) | **QuickJS** (migrated from SpiderMonkey) |

### PAC landscape in 2026

PAC is not dying. Zscaler Client Connector still generates it; Netskope / Cloudflare Gateway / Palo Alto Prisma all emit PAC as an output format. The trend is wrapping PAC in a SASE tunnel (Client Connector / WARP / Entra PNC), not replacing it.

### Security

- PAC over WPAD is attacker-controllable on hostile networks (Pacdoor, BlackHat 2016).
- CVE-2021-23406 in npm `pac-resolver` bypassed Node `vm` sandbox via `this.constructor.constructor`. Any PAC evaluator needs a real sandbox + CPU/memory limits.
- pacparser's 2026 migration was driven by SpiderMonkey's 17-year-old "Ancient Monkey" JS escape. Frozen engines eventually become vulnerabilities.

## 5.5 DNS, TUI, Zig, Odin, tokio, JS engines

### hickory-dns (ex trust-dns) — **recommended** (Plan B only)

- **Latest stable**: `0.25.2` (May 2025). Pre-release `0.26.0-beta.3` (Apr 2, 2026). Last repo activity Apr 3, 2026.
- 40M+ downloads, 267 reverse deps on `hickory-resolver`. Maintainer `bluejekyll` + 240 contributors.
- Native DoH/DoT/DoQ/DoH3 via `https-rustls` feature. Crate split (`hickory-proto`/`-client`/`-server`/`-resolver`/`-recursor`) means we pull only what we need.
- Alternatives (`domain`, `simple-dns`) are sub-scope for a local forwarder.

### rustls — **recommended** (Plan B only)

- **Latest**: `0.23.37` (Feb 24, 2026).
- aws-lc-rs is default backend since Feb 2024; FIPS available; post-quantum ML-KEM shipping (~2% of Cloudflare TLS 1.3 traffic).
- Does NOT handle CONNECT (correct layering — CONNECT is HTTP). Pair with `hyper` + per-SNI `ResolvesServerCert` for MITM patterns (2026 crates `slinger-mitm`, `rustls-mitm`, `rust-forward-proxy` all demonstrate this).

### ratatui — **recommended if we ever want a Rust TUI**

- **Latest**: `0.30.0` (Dec 26, 2025). MSRV 1.86.0. Stars 19,481; downloads 23.6M; reverse deps 3,436.
- Monolithic crate → modular workspace in 0.30: `ratatui-core`, `ratatui-widgets`, `ratatui-crossterm`, `ratatui-termion`, `ratatui-termwiz`, `ratatui-macros`.
- Alternatives: `tui-rs` is **dead** (ratatui is its fork); `cursive` is active but much smaller and ncurses-flavored. **ratatui is the pick if Rust TUI is wanted.**

### Zig — **usable, expect churn**

- **Latest stable**: `0.16.0` (Apr 14, 2026). 1.0 is multi-year out; no 2026 timeline.
- 0.15→0.16 was **Writergate**: `std.io`→`std.Io`; `GenericReader`/`AnyReader`/`FixedBufferStream` deleted; `readToEndAlloc` signature changed; `usingnamespace` removed. Every tutorial older than ~Dec 2025 is broken.
- Cross-compilation via `cargo-zigbuild 0.22.1` is production-grade for linking Rust binaries. That's the real Zig-in-Rust-ecosystem use.
- **Not appropriate** as the source language for a DNS parser linked into Swift or Rust — hickory-proto / DNSWireFormat.swift already solve it better.

### Odin — **not appropriate for a Rust-consumed library**

- Rolling `dev-YYYY-MM` tags; latest `dev-2026-04`. LLVM 22.
- Solo BDFL (Ginger Bill); 10K+ stars but bus factor 1.
- No public production users exporting C ABI consumed by Rust. No `cbindgen` equivalent.
- Fine as a standalone tool/game language. Risky as a Rust dependency.

### tokio — **recommended** (Plan B only)

- **Latest**: `1.52.0` (Apr 14, 2026).
- 1.50–1.52 highlights for a proxy: sharded `spawn_blocking`, LIFO steal, vectored writes, `io_uring` SQPOLL support in-flight (Linux-only, unstable feature flag).
- No breaking changes in 1.x line.

### boa_engine vs rquickjs (Rust JS engines)

- **boa_engine 0.21.1** (Mar 29, 2026): pure Rust, no-unsafe, debuggable, async-Rust-friendly; 94.12% Test262; register-based VM + NaN-boxing since 0.21.
- **rquickjs 0.11.0** (Dec 24, 2025): C dependency; near-complete ES2020; higher real-world PAC compatibility; smaller binary.
- See §5.4 for the PAC-specific verdict.

### Zig ↔ Rust interop

- **Linker use** (`cargo-zigbuild`): ✅ production-grade.
- **Library source interop** (`autozig` + manual `build.rs` + hand-authored `extern "C"`): 🟡 works, niche. No `cxx` equivalent for Zig. No `cbindgen` for Zig.
- **Async boundary**: 🔴 do not cross tokio/Zig-async. Keep Zig sync; call from `spawn_blocking`.

### Rust ↔ Swift interop (on macOS, for Plan B's macOS shell)

- **Unix-socket control protocol is the right answer.** C FFI between Swift and Rust works mechanically but recreates the exact class of bugs Hashimoto called out in the Ghostty GTK rewrite (§5.7). Cost-benefit favors IPC.

## 5.6 Competitive landscape

**Verdict**: the niche for Conduit is **macOS developers at AD-Kerberos/NTLM enterprises running legacy explicit proxies**. This niche has no live competitor that offers our combination of features. Plan A extends the moat. Plan B competes on Windows/Linux where multiple tools already exist.

### Direct competitors

| Tool | Lang | Stars | Latest release | Maint. | macOS | Linux | Win | NTLM | Kerb | PAC | SOCKS5 | DNS fwd | Failover |
|---|---|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| **px** (genotrance) | Python | 1,082 | v0.10.3 (Mar 11, 2026) | Active | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | comma-list, no health |
| **cntlm** (versat fork) | C | 165 | v0.94.0 (Aug 19, 2025; pushed Apr 7, 2026) | Active | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | round-robin |
| **alpaca** (samuong) | Go | 244 | v2.0.11 (Aug 11, 2025) | Active | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ | PAC-list only |
| **gontlm-proxy** (bdwyertech) | Go | 75 | v0.5.35 (Nov 14, 2025) | Active | — | — | ✓ | ✓ | ✓ | reg/env | ✗ | ✗ | single upstream |
| **proxydetox** (kiron1) | Rust | 46 | v0.13.0 (Dec 12, 2025) | Active | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ | dnsdetox module | PAC-list only |
| **krb5proxy** (veldrane) | Rust | tiny | v0.1.8 (Oct 2025) | Early active | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | — |
| **Preproxy** (Eugene Hom) | ObjC/Swift | App Store | 1.5.5 (May 2022) | **Dead** | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ | basic |
| **Conduit** (us) | Swift | (us) | — | **Active** | ✓ | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | **health + circuit breaker + ladder** |

### Adjacent categories

- **mitmproxy**: upstream-auth support is Basic only; NTLM requires custom Python addon hacks. Not a corporate-auth tool.
- **proxychains-ng**: `LD_PRELOAD` sockifier. Different category.
- **ngrok Desktop / Cloudflare Tunnel / WARP**: inbound-tunnel / SASE client. Needs to cross a corporate proxy, doesn't authenticate to one. Orthogonal.
- **Zscaler Client Connector / Netskope / Cisco Umbrella / Entra Private Access + PNC**: SASE/ZTNA *replacements* for explicit proxies. On managed endpoints, intercept at kernel/NetworkExtension layer and push through the cloud — no NTLM handshake. The strategic risk to Plan B, not to Plan A.
- **Windows native (WinHTTP + SSPI + WPAD)**: seamless for Edge/Chrome/.NET. Does *not* help WSL (no NTLM/Kerberos per [WSL #10804](https://github.com/microsoft/WSL/issues/10804)), Python, Node, Go, curl, JetBrains, etc. Partial solution at best.
- **Docker Desktop 4.30+**: native NTLM/Kerberos/SOCKS5 — Docker traffic only.

### macOS-specific pain points (relevant to Plan A's differentiation)

- `curl --proxy-negotiate / --proxy-ntlm` fails on macOS while succeeding on Windows in the same AD domain ([curl #14757](https://github.com/curl/curl/issues/14757)).
- `URLSession` breaks when proxy advertises `Negotiate` before `NTLM` — Apple's stack picks Negotiate and can't fall back ([Apple Dev Forums 100523](https://developer.apple.com/forums/thread/100523)).
- `px` on macOS has a history of PAC-parsing regressions (v0.8.4, v0.10.0) and a "URL malformed" bug under Python 3.11/3.12.
- Preproxy dead since May 2022.

### Interpretation

Plan A's niche (macOS-native, real failover, all protocols in one tool, Kerberos + NTLM, active maintenance) is genuinely unfilled in April 2026. A Swift-native macOS app with our feature set hits a gap that has been open for 4+ years. We should not try to be a better px; we should be the thing that finally makes Preproxy's successor, with failover no competitor has.

## 5.7 Ghostty / TigerBeetle architectural fact-check

**Verdict**: philosophy ✓, template ⚠️. Keep the discipline; don't copy the architecture uncritically.

### Ghostty claims

| Claim | Status | Note |
|---|:-:|---|
| libghostty is a platform-independent core in Zig | ✓ | [ghostty.org/docs/about](https://ghostty.org/docs/about). Also `libghostty-vt` for narrower VT-only use, targets macOS/Linux/Windows/WASM. |
| Swift/AppKit on macOS, Zig/GTK4 on Linux | ✓ with update | **GTK application rewritten Aug 2025** (PR [#8235](https://github.com/ghostty-org/ghostty/pull/8235), "gtk-ng") to embrace GObject. Hashimoto's post-mortem explicitly rejects the thin-shell pattern: *"an entire class of bugs where the Zig memory or the GTK memory has been freed, but not both."* Shipped in 1.2 (Sep 15, 2025). **This changes how we should think about the Swift layer.** |
| Core exposes a C API any language can embed | ⚠️ overstated | API exists, PR [#11506](https://github.com/ghostty-org/ghostty/pull/11506) added `ghostty_terminal_*` / `ghostty_formatter_*` surface in Mar 2026, **but docs state**: *"API is currently used primarily by the macOS app and is not yet stabilized for general-purpose embedding. The API may change significantly between releases."* Four years in, still not stable. |
| Core owns all terminal logic; shells only handle platform/UI | ✓ | Reinforced, not contradicted, by GTK rewrite — core stayed in Zig; platform integration got deeper. |
| ~2 years of private beta before 1.0 | ✓ | [1.0-reflection post](https://mitchellh.com/writing/ghostty-1-0-reflection): private beta reached ~600 → ~5,000 users before public 1.0 Dec 2024. |

### TigerBeetle claims

| Claim | Status | Note |
|---|:-:|---|
| Zero external dependencies | ✓ | Enforces Zig 0.14.1 exactly. Vendors tools (`llvm-objcopy`) as released binaries. No `build.zig.zon` third-party deps as of Apr 2026. |
| Deterministic simulation testing — replay any failure | ✓ | VOPR simulator, seeded. `./zig/zig build vopr`. |
| Static allocation, no GC, no dynamic allocation in hot paths | ✓ (extended) | Canonical [article](https://tigerbeetle.com/blog/2022-10-12-a-database-without-dynamic-memory). Extended to the REPL via `StaticAllocator` in 2025. |
| Chose Zig over Rust for "favorable ratio of expressivity to complexity" | ✓ exact phrasing | In the Oct 25, 2025 [ZSF pledge post](https://tigerbeetle.com/blog/2025-10-25-synadia-and-tigerbeetle-pledge-512k-to-the-zig-software-foundation). Stated reasons: Rust's crash-on-OOM default, single-threaded TigerBeetle doesn't benefit from borrow-check, never-frees-memory model. |
| TIGER_STYLE.md is authoritative | ✓ | [docs/TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md). Order: safety, performance, developer experience. |
| **TigerBeetle has shipped 1.0** | ✗ | **No.** Latest `0.17.0` (Apr 3, 2026), weekly releases. Roadmap issue #259 closed Jan 2025 but no 1.0 tag. Production-ready in practice, 1.0-labelled never. The "TigerBeetle 1.0" benchmark claim in casual reading is wrong. |
| Ghostty 1.x shipped? | ✓ | 1.0 Dec 2024, 1.1 Feb 2025, 1.2 Sep 15 2025. ~50K stars by Mar 2026. |

### "Ghostty model" as architectural template (April 2026)

Still a reasonable template, with three refinements from the 2025–2026 experience:

1. **Embrace the platform toolkit.** Don't make the native shell thin. Wrap core structs in the toolkit's reference-counted / memory-managed types (GObject on GTK, NSObject-bridgeable Swift types on macOS). This is the explicit lesson of the Ghostty GTK rewrite.
2. **C ABI stability is harder than advertised.** Ghostty hasn't stabilized theirs in 4 years. If Plan B ever activates, we don't expose a C ABI; we expose a Unix-socket control protocol (which is what Plan A's daemon-first phase already establishes).
3. **Narrow, focused sub-libraries are what people actually embed.** `libghostty-vt` (VT parsing only) is more embeddable than `libghostty` (terminal). If we ever go cross-platform, a narrow `pm-core` with just the config + event types might be the stable public interface, not the whole runtime.

### In-production projects following the ghostty model

- `Xuanwo/gpui-ghostty` — Rust/GPUI embeds Ghostty VT.
- `semos-labs/attyx` — Zig GPU terminal.
- `duanebester/gooey` — Zig UI framework, Metal/Vulkan/WebGPU.
- `evmts/agent` (Smithers v2) — native macOS IDE on Swift + Zig using Ghostty.
- `ghostty_vte` (Dart package) on pub.dev — uses `libghostty-vt` via FFI incl. Windows.

Pattern: the narrower sub-libraries get embedded. The full runtime gets shipped as an app.

---

## Summary of current resolution

| Question | Answer |
|---|---|
| What is Plan A? | Finish Conduit as a **macOS-native menu-bar proxy with real failover**. Module split (4–5 targets), STYLE baked in, security/reliability/efficiency pass, daemon-first control plane, great UI (Liquid Glass), simulators & chaos demos, open-source prep. |
| What is Plan B? | **Optional** Rust port for Windows/Linux. Gated on demand signal + macOS stability + personal signal + ecosystem stability. Preserved here so the research isn't lost. |
| Language for Plan A | Swift 6.3 on macOS 26.x. Keep SwiftNIO; keep GSS.framework; swap JavaScriptCore for CFNetwork. |
| Language for Plan B (if triggered) | Rust. Stack: hyper 1.x + tokio 1.52 + rustls 0.23 + hickory-dns + fast-socks5 + hand-rolled NTLM + libgssapi/cross-krb5 + rquickjs. Not sspi-rs, not pingora, not rama, not boa, not Zig, not Odin. |
| Config format | Stay on JSON with sectioned schema (already done). TOML migration is Plan-B-only. |
| Corporate defaults | Already split out of main type. Move to `Resources/Presets/example-corp.json` during open-source prep. |
| TIGER_STYLE | Adopt the sensible subset as STYLE; bake into AGENTS.md + README.md during the foundation phase. |
| Chaos demo | SwiftUI dashboard in `ProxyApp`, dev-builds only (simulators & demos phase). |
| C ABI for external embedders | No. Use a Unix-socket control protocol (daemon-first phase). |
| Zig/Odin side-quests | Cut from the plan. Do them as throw-away weekend exercises on small pure files if you want to learn them. |
| Cross-platform abstractions | Built into the `ProxyKernel`/`PlatformMac` protocol split during the foundation phase. Not executed until Plan B triggers. |
| Enterprise readiness | §2.10 lists MDM profile, `.pkg` installer, Sparkle updates, OpenTelemetry export, tamper detection. All post-1.0; none delay the core phases. |
| High-value features absorbed from prior ROADMAP | Security hardening: inbound gateway auth, upstream cert pinning, connection audit log, SOCKS5 auth hardening. Reliability: tunnel health probes, graceful upgrade. Daemon-first: targeted hot-reload, LaunchAgent watchdog, per-tunnel metrics. Open-source prep: `SMAppService`, Data Protection Keychain, config backup/restore with schema migration. |

The most important thing: **the quality of the core Swift runtime determines everything else.** Get `ProxyKernel` right — correct, observable, testable, composable, efficient, secure — and the macOS product becomes something you're proud of for years. Cross-platform reach, if it ever happens, compounds on that foundation.
