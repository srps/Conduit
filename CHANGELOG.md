# Changelog

All notable changes to Conduit. This is the pre-release development history that
precedes the first public `0.1`; entries are grouped by theme, newest first. Forward-looking
plans live in [`ROADMAP.md`](./ROADMAP.md).

## Unreleased (pre-0.1)

### Architecture & modularization
- Split the monolithic core into focused SwiftPM targets: a portable, Apple-framework-free
  kernel (`ProxyKernel`) plus `ProxyAuth`, `ProxyPAC`, and a macOS-only `PlatformMac` glue
  layer. Cross-target calls go through protocols (`LogSink`, `CredentialProvider`,
  `PacEvaluator`, `PrivilegeClient`, `ProxyAuthenticator`, `VPNStatusObserving`,
  `TunnelResolverApplying`), and the build itself enforces the import fence - the headless
  `pm-proxy` links no macOS frameworks.
- Introduced a `LogSink` protocol with stock console/discarding/recording conformers, and a
  single config-snapshot provider on the orchestrator that removed duplicated config mirrors.
- Externalized vendor presets to bundled JSON under `Resources/Presets/` loaded by a single
  `PresetLoader`; persistence falls back to generic defaults, and tests use a vendor-neutral
  `ProxyConfig.testFixture()`. Runtime config now carries a schema version and auto-normalizes
  unversioned files on load.

### Security
- Added a documented threat model covering malicious PAC, upstream MITM, Keychain credential
  theft, in-memory token snooping, local port hijack, helper privilege escalation, IPv6 family
  confusion, and SNI/CONNECT host mismatch.
- Replaced the JavaScriptCore PAC engine with the OS-patched CFNetwork evaluator (Safari
  parity), and removed the JavaScriptCore dependency from the sources entirely.
- Added `SecretBytes`, an opaque credential container that redacts in `print`/`dump`/lldb,
  refuses JSON serialization, and zeroes on deinit; routed in-memory credential boundaries
  through it.
- Centralized log/event sanitization so `Authorization` / `Proxy-Authorization` / `Cookie` /
  `Set-Cookie` and bearer tokens are masked across every sink, with an assertion that no log
  line carries an unmasked long token.
- Hardened the privileged-helper trust boundary: versioned and validated IPC, rejection of
  legacy unversioned frames, console-user-restricted socket, and pre-IPC command validation.
- Closed a confirmed gateway-mode SSRF bypass by applying the metadata blocklist to all
  outbound paths and canonicalizing IPv6 metadata-address forms.
- Added a privileged-action audit trail (request/outcome events with no raw helper values),
  tunnel credential rotation on config reload, and device-bound Keychain accessibility.

### Reliability & networking
- Automatic upstream failover with health-probed reachability, an upstream circuit breaker
  (failure threshold, exponential backoff, half-open probing, EWMA latency), idempotent retry
  on connection reset, and connection prewarming.
- Replay-aware request-body handling for non-CONNECT HTTP: bodies stay in memory up to a cap
  and spill to bounded `0600` temp files, preserving direct/PAC/fallback routing and multi-leg
  upstream 407 auth replay without unbounded RAM or event-loop file I/O.
- WebSocket / HTTP-Upgrade relay over a dedicated direct origin connection, with
  upgrade-preserving header sanitization and raw splice on `101`.
- `Expect: 100-continue` answered by the proxy, response trailers forwarded on the pooled path,
  and debug-only event-loop confinement assertions at callback-driven mutation sites.
- DNS-cache-poisoning resistance: responses whose question doesn't match are neither forwarded
  nor cached.
- Sleep/wake recovery so the proxy no longer sticks in DIRECT mode after macOS sleep, plus
  VPN/network-change reconciliation and port-retry on restart.

### PAC-aware routing & DNS
- PAC routing engine that fetches/caches corporate PAC files, evaluates `FindProxyForURL()`
  per request via CFNetwork, and respects full fallback chains (`PROXY → PROXY → DIRECT`).
- Native PAC DNS resolution (`dnsResolve`, `myIpAddress`, `isResolvable`, `isInNet`) with a
  per-evaluation cache.
- Local PAC serving: hosts the active routing chain at `http://127.0.0.1:<port>/proxy.pac` and
  points macOS auto-proxy at it, so browsers keep a stable local PAC URL that survives
  corporate PAC outages.
- DoH forwarder with a smart connection cascade (direct → upstream proxy → local proxy),
  LRU+TTL response cache with NXDOMAIN negative caching, DNS intercept rules, and optional
  system-DNS management via a native UDP relay in the privileged helper with crash recovery.

### Authentication
- Kerberos/SPNEGO via the system GSS framework as the default mode, with a protocol-based
  authenticator strategy: NTLMv2, Kerberos, and Negotiate (Kerberos-first with NTLM fallback).
  Default mode requires no first-run password prompt.
- GSS contract hardening (correct empty-token / mutual-auth-final-leg handling, replay/sequence
  flags) and a fix to store the authenticator per-handshake so multi-leg SPNEGO works.

### Protocol tunnels
- A tunnels module with service presets and proxied-tunnel support over HTTP CONNECT through a
  corporate proxy (TLS-inside-CONNECT with Kerberos auth), validated end-to-end against a
  cloud database through a corporate proxy.
- Self-contained per-tunnel DNS override via a mini UDP DNS responder and `/etc/resolver/`
  files, with progressive capability tiers (helper installed → fully transparent; AppleScript
  fallback → one admin prompt; no privilege → guided SOCKS5/hosts setup).
- DNS-intercept + transparent TCP proxy for clients that bypass `HTTP_PROXY`, with TLS
  ClientHello SNI extraction and privileged port-443 binding in the helper.

### Efficiency
- Connection-pool hot-path hardening: dedicated CONNECT tunnels reserve capacity through the
  same active/idle/pending cap as pooled exchanges, with O(1) channel→connection cleanup.
- Snapshot fan-out coalescing, an O(1) active-connection store, and amortized log ring-buffer
  trimming cut menu-bar CPU spikes substantially.
- Repeatable perf gates in CI (cold-start budget, `multi-100` completion, wall time, max RSS)
  and a scheduled sanitizer (ASan/TSan) soak job for the C-boundary code.

### Observability
- A fully `Codable` orchestrator snapshot, NDJSON `ready`/`status` streaming from `pm-proxy`,
  and a documented, versioned (v1), additive-only event-stream contract so observer extensions
  are third-party-buildable.
- `pmctl diag` collects recent, sanitized crash reports (home-path/login-name/device-id
  redaction, symbols preserved) with a crash-triage runbook.

### Diagnostics & tooling
- `pm-tls-check` captures and classifies the presented TLS chain (publicly trusted vs
  locally-trusted inspection vs untrusted), names common inspection vendors, and exports the
  inspection CA as PEM.
- Headless `pm-proxy` and `pm-dns` CLIs, plus the `pm-sim` fault-injection harness used as the
  reliability test bed.

### UI
- Module-cards dashboard with independent start/stop and live metrics for the proxy and DNS
  forwarder, per-module inline errors, a setup wizard, and a filterable log view.
- Draggable upstream ordering persisted as failover priority, reachability probes that don't
  rewrite priority, auth-mode badges, and a settings layout aligned to the config sections.

### Documentation & project
- Engineering-discipline style guide (`docs/STYLE.md`), contributor/AI guardrails
  (`AGENTS.md`), and a vendor-neutral README with the product-pillars contract.
