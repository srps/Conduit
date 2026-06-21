# Conduit

A **macOS-native corporate proxy manager** built with SwiftUI and SwiftNIO. If you run macOS inside an AD-Kerberos/NTLM enterprise with legacy explicit proxies, Conduit is built for you. If you run a generic HTTP/SOCKS5 upstream, it works there too.

**Kerberos + NTLMv2 + PAC + SOCKS5 + DoH forwarding + tunnels + health-probed failover**, all in one native menu-bar app.

> I built Conduit out of my own necessity. Daily-driving macOS behind a corporate proxy, the constant proxy/VPN connection flakiness was a real drag, and I wanted a single reliable tool that just worked whether I was on VPN or off it. PAC support and automatic proxy re-routing were my biggest pain point, so that's the core the rest is built around. Everything else (SOCKS5, DoH forwarding, tunnels, the menu-bar UI) started as nice-to-haves layered on top. It's open-sourced in case it saves someone else the same trouble.

## Why Conduit?

| Tool | macOS-native UI | NTLM | Kerberos | PAC | SOCKS5 | Tunnels | Real failover |
|------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **px** (Python) | - | ✓ | ✓ | ✓ | - | - | comma-list, no health |
| **alpaca** (Go) | - | ✓ | - | ✓ | - | - | PAC-list only |
| **proxydetox** (Rust) | - | - | ✓ | ✓ | - | - | PAC-list only |
| **cntlm** (C) | - | ✓ | ✓ | ✓ | - | - | round-robin |
| **Conduit** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **health-probed, circuit-breaker, auto-recovery** |

## Quick Start

```bash
# Build
swift build

# Run headless proxy on port 3128
swift run pm-proxy --port 3128 --state-dir /tmp/pm-test

# Test it works
curl -x http://localhost:3128 https://httpbin.org/ip

# Or install the GUI app
./bundle-app.sh --install
```

See [`docs/getting-started.md`](docs/getting-started.md) for full setup instructions.

## Product Pillars

Every change is measured against these axes. A proposed feature either lands under one of these pillars or it doesn't ship.

| Pillar | What it means | How it's measured |
|---|---|---|
| **Reliability** | No daily-driver regressions; survives Wi-Fi ↔ VPN ↔ captive portal transitions | Daily use; `pm-sim` chaos suite green; zero "I had to restart it" moments per quarter |
| **Security** | No secret leaks; PAC evaluation sandboxed; tunnel credentials rotatable | Reviewed threat model; Keychain audit; `Proxy-Authorization` never logged |
| **Efficiency** | < 40 MB RSS idle, < 3% CPU idle, < 50 ms added latency at p99 | Instruments profile under `pm-sim multi-100`; long-run baseline |
| **Observability** | Every routing/auth/failover/health decision is a typed `RuntimeEvent` | `ProxyOrchestratorSnapshot` is machine-consumable; NDJSON status stream; agent harness asserts behaviour from events alone |
| **Great UI** | Menu bar handles 90% of daily tasks; main window is HIG-correct | Toggle proxy / switch profile / test upstream / view health without opening the app |
| **Daemon-first** | The runtime runs with no UI attached; UI is a client | `pm-proxy` serves traffic even with the GUI force-quit |
| **Simulators & demos** | Every runtime behaviour is testable and demonstrable | Every new behaviour ships with a `pm-sim` scenario; demo mode visualizes the event stream live |

## Features

### Core Proxy

- Local HTTP proxy listener with configurable bind host and port
- NTLMv2 upstream authentication (compatible with corporate proxy infrastructure)
- HTTPS tunneling via `CONNECT`
- Plain HTTP forwarding
- Bundled presets for generic setups, corporate proxy fleets, and self-hosted Squid
- Draggable upstream proxy ordering: top-to-bottom order is persisted as failover priority
- Upstream reachability probing without rewriting configured priority order
- Automatic upstream failover: when a CONNECT tunnel fails, the coordinator retries through remaining upstreams before returning an error
- Automatic direct-connect detection with configurable TTL cache and progressive timeout backoff
- Off-VPN `directMode` that bypasses corporate upstreams when they are unreachable
- `NO_PROXY`-style matching for direct connections
- `forceProxyHosts` overrides for domains that must always use the upstream proxy
- Configurable connection timeout, direct-connect TTL, strict mode, and verbose logging

### PAC-Aware Routing

- Fetches and caches corporate PAC files (supports `http://` PAC URLs via ATS-safe curl fallback)
- Evaluates `FindProxyForURL()` through macOS CFNetwork (Safari-parity, OS-patched PAC engine)
- Respects full PAC fallback chains (`PROXY -> PROXY -> DIRECT`): if the upstream proxy fails, automatically falls back to DIRECT when the PAC chain allows it
- Native PAC DNS resolution: `dnsResolve()`, `myIpAddress()`, and `isResolvable()` implemented via Swift callbacks with per-evaluation DNS cache. `isInNet()` subnet checks work correctly for hostnames
- PAC helper functions: `isPlainHostName`, `localHostOrDomainIs`, `dnsDomainLevels`, `shExpMatch`, `dnsDomainIs` with proper semantics
- Upstream PAC routing toggle: enable/disable PAC-based internal routing without clearing the PAC URL
- Adaptive local PAC serving: macOS can point at `127.0.0.1:<localPACPort>/proxy.pac` while Conduit keeps the upstream PAC URL as its internal routing source
- Works in manual proxy mode: system proxy stays on localhost (so CLI tools work), but routing decisions use PAC internally

### DNS over HTTPS (DoH) Forwarder

- Local UDP DNS forwarder that intercepts and resolves queries
- Response cache: LRU with TTL from minimum RR TTL, NXDOMAIN negative caching, 2048 entry limit
- Internal domains (configurable) go through corporate DNS servers first
- External domains fall back to configurable DoH providers (default: Cloudflare, Quad9, Google)
- Smart connection cascade for DoH: tries direct, then upstream corporate proxy, then local proxy -- for each provider in order
- DNS intercept rules: wildcard pattern matching (e.g., `*.cursor.sh`) returns a synthetic loopback IP for transparent proxying
- Optional system DNS management: sets macOS DNS to 127.0.0.1 on all connected interfaces so all apps (including Cursor/Electron `getaddrinfo`) use the forwarder. Uses a native Swift UDP relay on port 53 running inside the privileged helper daemon. DNS pipeline liveness probe runs every 30 seconds with auto-recovery.
- VPN-aware DNS reconciliation: when interfaces appear or disappear (VPN connect/disconnect), new interfaces are automatically redirected to the forwarder and stale entries pruned from saved state
- Crash recovery: original DNS servers are saved to disk and restored on stop or automatically on next app launch if the app was force-quit. Tolerates vanished interfaces, detects stale state (>7 days), and handles port-53 conflicts intelligently
- Runs independently as `pm-dns` CLI or integrated in the GUI app
- Fixes DNS resolution on VPN where corporate DNS returns NXDOMAIN for public domains

### System Integration

- macOS system proxy configuration via `networksetup`
- PAC toggle: enable/disable automatic proxy configuration without losing the PAC URL
- Shell environment variable management for `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`
- Split DNS support via `/etc/resolver`
- PAC file fetching and evaluation preview
- Login-item support
- Bundled `.app` wrapper script for local development builds
- Activation preflight that detects whether admin will be needed before enabling/disabling
- No-op detection: skips privileged operations when current state already matches
- Privileged helper daemon for one-time authorized system proxy, DNS management, and DNS relay

### Reliability

- Connection pooling and keep-alive reuse
- Configurable connection timeout (reads from `connectionCheckTimeoutMS` in config, default 500ms)
- Health checking and auto-recovery when upstream mode is active
- Stalled connection cleanup
- VPN/network change detection
- Port-retry logic on restart so the proxy recovers cleanly after quick restarts
- NIO event loop safety: all cross-channel operations use `.hop(to:)` or Channel-level thread-safe APIs

### UI

- Module cards dashboard: independent start/stop for HTTP Proxy and DNS Forwarder with live metrics and inline error display when a module fails (multi-line, copyable)
- Per-module error tracking: proxy and DNS errors appear on their respective cards; non-module errors show in a dismissible global banner
- SwiftUI desktop app with settings, logs, and setup wizard
- Translucent material window backgrounds
- Compact active connections summary (count + top 3 destinations) on the dashboard; full scrollable list available separately
- Settings with tabbed navigation (Proxy, Auth, Network, DNS, Env, Advanced)
- Filterable log view with category chips (PAC, Proxy, Auth, Network, System), level picker, text search, and copy buttons for LLM analysis
- Menu bar extra
- Floating window support
- Global keyboard shortcut support
- Notifications when run as an app bundle
- Config import/export
- Config files carry a `schemaVersion`; older unversioned configs are normalized and rewritten automatically on load

### Advanced Features

- SOCKS5 proxy server with IPv6 support (ATYP 4)
- Gateway mode (`0.0.0.0`) for Docker / VM / LAN usage
- Allowed-client list for gateway deployments
- Cloud metadata endpoint blocking in gateway mode (prevents SSRF to `169.254.169.254`, link-local, loopback)
- TCP tunnel / port-forward definitions
- Transparent TCP proxy for apps that bypass `HTTP_PROXY` (e.g., Cursor `http2.connect()`): DNS intercept + TLS SNI extraction + authenticated CONNECT tunnel, with Cursor preset rules in Settings
- Configurable max upstream connections and inbound connection limits (warn + reject thresholds)
- Configurable request body buffer limit (default 16 MB; oversized bodies are rejected before forwarding)
- Verbose logging toggle (gates stderr output; in-app ring buffer always captures all levels)
- Optional file logging to `~/Library/Logs/Conduit/proxy.log`

### Security

- Credentials stored in macOS login keychain (traditional keychain; no entitlements required)
- NT hash derived once and stored securely
- No plaintext password persistence
- Helper daemon socket restricted to `root:staff` group with `getpeereid` peer validation
- `setAutoproxyURL` URL scheme validation (http/https only) to prevent PAC URL injection
- CONNECT tunnel dedicated connections exempt from stalled connection reaper (prevents false kill of active tunnels)

### Tests

- 1,100+ automated tests across 83 test files
- Coverage includes NTLM, PAC routing and CFNetwork PAC evaluation, DoH DNS forwarder, DNS wire format and poisoning resistance, UDP/TCP relay forwarding, system DNS management, config migration, upstream failover, circuit breaker/EWMA, direct-connect detection, event loop safety, helper contract, keychain credential management, metadata blocklist, tunnel exemption, IPv6 parsing, body buffering, SNI parser (ClientHello parsing, hostname validation, random-garbage false-positive coverage), DNS intercept rules, transparent proxy config, logging sanitization, local PAC serving, and autoproxy URL validation

## Architecture

The module split separated the monolithic library into four targets along the import-fence: portable kernel, auth crypto, PAC evaluation, macOS-specific glue. See `[docs/design-module-split.md](./docs/design-module-split.md)` for the file-by-file destination map and the protocol surfaces that cross target boundaries.

```
ProxyKernel  (Foundation + Dispatch + NIO* only - no Apple frameworks)
ProxyAuth    (+ GSS, CommonCrypto)              depends on ProxyKernel
ProxyPAC     (+ CFNetwork PAC evaluator)             depends on ProxyKernel
PlatformMac  (+ Security, SMAppService, etc.)   depends on ProxyKernel + ConduitShared
ConduitShared                              <- helper IPC wire contract

Executables / consumers:
  Conduit           (GUI app)         <- ProxyKernel + ProxyAuth + ProxyPAC + PlatformMac + Shared
  pm-proxy               (headless daemon) <- ProxyKernel + ProxyAuth + ProxyPAC  (no PlatformMac - fence test)
  pm-sim                 (fault injection) <- ProxyKernel + ProxyAuth + NIO
  pm-tunnel              (TCP forwarder)   <- ProxyKernel + ProxyAuth
  pm-dns                 (DoH forwarder)   <- ProxyKernel
  pm-vpn-check           (diagnostic)      <- ProxyKernel + PlatformMac
  pm-auth-check          (diagnostic)      <- ProxyKernel
  pm-tls-check           (diagnostic)      <- PlatformMac   (TLS inspection / CA export)
  ConduitHelper     (LaunchDaemon)    <- ProxyKernel + Shared
  ConduitTests      (1,100+ tests)       <- everything
```

- **ProxyKernel**: portable library with all non-UI, non-platform-specific code. Pure Swift + SwiftNIO. The headless daemon `pm-proxy` runs entirely off this target - its `Package.swift` deliberately does not list `PlatformMac`, and the build is the test.
- **ProxyAuth / ProxyPAC**: opt-in capability layers. NTLM/Kerberos and PAC evaluation respectively. ProxyPAC uses macOS CFNetwork for Safari-parity PAC execution.
- **PlatformMac**: macOS-specific glue (Keychain, networksetup, SMAppService, SCDynamicStore, NWPathMonitor, helper XPC, `/etc/resolver` writer, TLS-inspection diagnostics). Linked by the GUI app and the `pm-vpn-check` / `pm-tls-check` diagnostics.
- **Conduit**: GUI app. Thin orchestration shell importing the kernel + capability layers + platform glue.
- **ConduitHelper**: privileged helper for system proxy, DNS changes, and UDP relay on port 53.

Cross-target calls go through protocols in `Sources/ProxyKernel/Abstractions/`: `LogSink`, `CredentialProvider`, `PacEvaluator`, `PrivilegeClient`, `ProxyAuthenticator`, `VPNStatusObserving`, `TunnelResolverApplying`. Kernel types use Swift's `package` access level (visible within the SwiftPM package but not outside).

## Current Limitations

- Hot reload is not implemented yet; restart is still required after config changes outside the app
- The standalone user-session daemon (`ConduitDaemon`) is still a runtime-host skeleton without its own control socket; `pm-proxy` is the primary headless runtime surface, and `pmctl` drives its control socket
- The privileged helper uses a LaunchDaemon with Unix socket communication; this works for all developers building from source but does not use Apple's `SMAppService` signed-helper flow needed for Jamf/MDM distribution

## Open In Xcode

Open the cloned `Conduit` package directory directly in Xcode. Xcode can
open Swift packages natively, resolve the `swift-nio` dependency graph, and run
the macOS app target.

## Build And Run

Building needs only the Command Line Tools (Swift 6.2+); Xcode is not required to
build. Build from Terminal:

```bash
cd Conduit
swift build
```

> Running the test suite *does* need Xcode, because XCTest ships with Xcode
> rather than the Command Line Tools - see [Run Tests](#run-tests).

Create a local app bundle (stays in the project directory):

```bash
./bundle-app.sh
open Conduit.app
```

Run a second instance on another port for safe testing:

```bash
Conduit.app/Contents/MacOS/Conduit --port 3129 --no-system-proxy --no-env
```

## Run pm-dns Standalone

```bash
swift run pm-dns --port 5353 --verbose
```

Then point your system DNS at `127.0.0.1` and queries for internal domains go through corporate DNS, external domains resolve via DoH. Or enable "Manage system DNS" in the GUI to have it done automatically.

## Install As A Normal App

Build, bundle, and install to `/Applications` in one step:

```bash
./bundle-app.sh --install
```

For an optimized release build:

```bash
./bundle-app.sh --release --install
```

Once installed the app can be found in Spotlight, Launchpad, and Finder > Applications. Pin it to the Dock by right-clicking its Dock icon > Options > Keep in Dock. The "Launch at Login" setting also requires the app to be in `/Applications`.

On first launch macOS may show a Gatekeeper warning ("cannot verify the developer") because the app is ad-hoc signed. Right-click the app > **Open** > click **Open** in the dialog. This is only needed once.

## Run Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Privileged Helper (One-Time Setup)

System proxy changes, `/etc/resolver` writes, and the DNS port 53 relay require admin. By default the app prompts each time. To eliminate repeated prompts, install the privileged helper once:

```bash
./bundle-app.sh --install
sudo ./install-helper.sh
```

The install script finds the helper binary from the installed app bundle in `/Applications`, the local bundle, or the build directory (in that order). It installs a LaunchDaemon that runs as root. The app communicates with it over a Unix domain socket at `/var/run/io.github.srps.Conduit.Helper.sock`. After installation, proxy enable/disable, DNS changes, and the port 53 relay happen without any further admin prompts.

You can also install/uninstall the helper from within the app: **Settings > Advanced > Privileged Helper**.

**Important**: after updating the app, reinstall the helper to pick up new helper commands:

```bash
sudo ./install-helper.sh
```

To remove the helper:

```bash
sudo ./uninstall-helper.sh
```

The app automatically falls back to standard macOS admin prompts when the helper is not installed.

## Targets

- `ProxyKernel`: portable library with all non-UI, non-platform logic (proxy, PAC routing, DoH, UDP relay, models, kernel-side abstractions). Foundation + Dispatch + NIO* only.
- `ProxyAuth` / `ProxyPAC` / `PlatformMac`: capability layers split out of the original monolith - see Architecture above.
- `Conduit`: the macOS GUI app
- `pm-dns`: standalone DoH DNS forwarder CLI
- `ConduitHelper`: helper executable for privileged operations and DNS relay
- `ConduitShared`: shared types between the app and helper (helper command contract)
- `ConduitTests`: automated regression tests

## Contributing

Contributions are welcome. Before you open a PR, a few things worth knowing:

- **Product direction** lives in [`docs/roadmap-v2.md`](./docs/roadmap-v2.md). The [Product Pillars](#product-pillars) at the top of this README are the contributor contract - any proposed change that doesn't fit Reliability, Security, Efficiency, Observability, Great UI, Daemon-first, or Simulators & demos should include a short rationale for why it still belongs here.
- **Engineering discipline** lives in [`docs/STYLE.md`](./docs/STYLE.md): bounded everything, assert invariants, structured events first, validate at the boundary, no silent failures, explicit resource lifetime, side-effects behind protocols, security-first, deterministic where possible.
- **Agent and contributor guardrails** (toolchain commands, import fences, judgment boundaries) live in [`AGENTS.md`](./AGENTS.md). Both humans and AI assistants read that file first; it supersedes informal conventions.
- **Tests are not optional.** New runtime behaviour adds a `pm-sim` scenario and unit tests before it ships. The full suite must stay green on Xcode's toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`).
- **Never commit secrets.** Credentials, tokens, and `.env` files don't belong in the repo or in log output.

If you're unsure whether a change fits the pillars, open a draft PR or an issue first - "should we do this?" is a better conversation to have before the code than after.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for current, next, and later milestones.
