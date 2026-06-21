# Conduit Roadmap

Forward-looking plan. For shipped history see [`CHANGELOG.md`](./CHANGELOG.md); for the
longer-form design philosophy behind these themes see [`docs/roadmap-v2.md`](./docs/roadmap-v2.md).

Every item is tagged with the product pillar(s) it serves: **[Rel]** Reliability,
**[Sec]** Security, **[Eff]** Efficiency, **[Obs]** Observability, **[UI]** Great UI,
**[Dmn]** Daemon-first, **[Sim]** Simulators & demos, **[OSS]** Open-source readiness.
An item without a pillar fit doesn't belong here. `[~]` marks work that is partially landed.

See also:

- [Product Pillars](./README.md#product-pillars) - the contributor contract.
- [`AGENTS.md`](./AGENTS.md) - review-time rules.
- [`docs/STYLE.md`](./docs/STYLE.md) - engineering discipline.

---

## Security hardening

- [ ] **Inbound gateway auth** - enforce `strictMode` by requiring `Proxy-Authorization` from gateway clients (`Negotiate` via `gss_accept_sec_context`, plus NTLM challenge-response). Closes the gap where `strictMode` declares intent without enforcement. [Sec]
- [ ] **Upstream-proxy certificate pinning** - per-upstream expected SPKI hash in config; a mismatch refuses the connection and emits an event. Defends against MITM between the app and the corporate proxy. [Sec]
- [ ] **Connection audit log** - rolling, size-capped NDJSON at `$state-dir/audit.ndjson` recording CONNECT target, PAC decision, routing choice, and auth method per connection, with credentials masked. Complementary to the event stream. [Sec, Obs]
- [ ] **SOCKS5 auth hardening** - username/password mode alongside no-auth; per-client-CIDR allow-list enforcement for gateway deployments. [Sec]
- [ ] **Control-socket capability handshake** - clients declare `observe` / `control` / `configure` scope at connect; the daemon enforces per command. Belt-and-suspenders on top of the owner-only socket for a multi-client future. [Sec, Dmn]
- [~] **Audit remaining credential-bearing strings** - in-memory credential boundaries and durable log/event surfaces are covered; one-shot HTTP header strings remain lifecycle-bound. [Sec]
- [~] **Keychain ACL tightening** - device-bound accessibility is applied; caller bundle-ID restriction is deferred to the signed-helper / Data Protection Keychain work. [Sec]

## Reliability

- [ ] **Kerberos credential expiry** - mid-session TGT expiry emits an event, attempts renewal, and falls back to NTLM cleanly. [Rel]
- [ ] **Upstream circuit-breaker formalization** - explicit open / half-open / closed state machine with an event per transition and an `upstream-flap` simulator scenario. [Rel, Obs]
- [ ] **Upstream selection strategies** - expose `priority` vs `automatic stable` selection. Priority mode preserves the draggable order; automatic mode prefers lower-latency upstreams using EWMA/hysteresis so a healthy upstream isn't dropped for one transient faster probe. [Rel, Obs, UI]
- [ ] **Crash cleanup** - `pm-proxy` recovers after `SIGKILL` without manual state-dir intervention. [Rel]
- [ ] **Tunnel health probes** - per-tunnel lightweight probe on a configurable interval; a failing probe moves the tunnel to `warning` without tearing down active sessions. Adds a `tunnel-flap` scenario. [Rel, Obs]
- [ ] **Graceful upgrade / zero-downtime restart** - a replacement daemon takes over the listening socket via Unix-domain-socket file-descriptor handoff; in-flight connections survive. Makes install and auto-update invisible to clients. [Rel, Dmn]
- [~] **HTTP standards hygiene** - the proxy answers `Expect: 100-continue` on its own behalf and forwards response trailers on the pooled path. Remaining: `421 Misdirected Request` handling on reused connections. [Rel]

## Daemon-first architecture & control plane

**Goal:** the runtime runs without the UI; menu bar, main app, and CLI are all clients of
the same control plane. Detailed plan: [`docs/design-daemon-first-control-plane.md`](./docs/design-daemon-first-control-plane.md).

- [ ] **Control protocol completion** - the shared control protocol, bridge, and `pmctl` exist; complete the contract (`start`, `set-profile`, daemon metadata, config generation, stable error codes) with bounded, versioned request frames. [Dmn, Obs]
- [ ] **Production user-session daemon** - a LaunchAgent executable that owns the runtime. `pm-proxy` stays side-effect-free for CI and isolated testing rather than becoming this daemon. [Dmn, Rel]
- [ ] **Runtime & platform ownership migration** - move ownership of the orchestrator, listeners, DNS forwarder, transparent proxy, tunnel forwarder, network/VPN monitors, and platform side effects (system proxy, PAC URL, environment, resolver files, helper relay) out of the app into the daemon. The app becomes a controller over the daemon. [Dmn, UI, Sec]
- [ ] **User-session credential contract** - the production daemon runs as the logged-in user so Keychain, Kerberos ticket cache, CFNetwork PAC evaluation, and user network state stay available; privileged work stays delegated to the helper. [Dmn, Sec]
- [ ] **Control socket server** at `$state-dir/control.sock` - typed request/response for `status`, `start`, `stop`, `reload`, `set-profile`, `test-upstream`, `events --follow`, `diag`, and a dev-only fault-injection command. One implementation serves both `pmctl` and the app. [Dmn, Obs]
- [ ] **Observable state files** - the daemon writes a capped `events.ndjson` and an atomic `snapshot.json`, readable by `pmctl diag` even when the control socket is down. [Obs, Dmn]
- [ ] **LaunchAgent lifecycle** - ship the agent plist, install/uninstall/upgrade commands, stale-socket cleanup, state-dir ownership checks, and keep-alive on unexpected exit. Prefer user-space bootstrap; escalate to the helper only where required. [Dmn, Rel]
- [ ] **Crash/restart contract** - after `SIGKILL` the daemon emits a crash-restart event with prior-exit evidence, reloads config, repairs stale socket/spool state, reapplies system side effects, and resumes without UI involvement. [Rel, Dmn]
- [ ] **App adopts the daemon client** - the app detects the daemon, bootstraps the LaunchAgent if missing, subscribes to snapshots/events, and stops owning listeners. The in-process fallback is dev-only and gated for removal before 1.0. [Dmn, UI]
- [ ] **Menu bar & settings over the control plane** - profile switcher, per-upstream traffic light, direct-mode indicator, connection count, test-upstream, diag bundle, events viewer, reload, and guarded quit all go through the daemon client. [UI, Dmn, Obs]
- [ ] **Config hot reload** - `reload` applies a config diff subsystem-by-subsystem; active HTTP, CONNECT, SOCKS5, DNS, and tunnel sessions survive unrelated changes. [Dmn, Rel]
- [ ] **Per-connection/tunnel metrics over the control socket** - bytes, uptime, detected protocol, last activity, active route, upstream, and auth mode, bounded and redacted. [Obs]
- [ ] **Daemon-first simulators** - force-quit the UI while traffic flows, `kill -9` the daemon and assert restart, reload DNS-only config without dropping sessions, verify `pmctl status/events/diag` against a live daemon. [Rel, Dmn, Sim]

> Demand-gated (post-1.0, design-doc first; see [`docs/design-extension-model-and-vision-grounding.md`](./docs/design-extension-model-and-vision-grounding.md)): out-of-process routing-decision hooks and out-of-process auth-provider extensions. In-process plugins are a non-goal.

## Efficiency

- [~] **Allocation capture & perf baselines** - repeatable cold-start and throughput gates run in CI; remaining: Instruments-backed allocation stacks, drift baselines once stable CI artifacts exist, and a raw-CONNECT header parser / header-interning pass. [Eff]

## UI excellence (Liquid Glass, HIG)

**Goal:** native to macOS 26 - Liquid Glass, proper materials, SF Symbols, correct spacing;
the menu bar covers 90% of daily tasks.

- [ ] HIG audit across every view; triage violations and fix bottom-up. [UI]
- [ ] Liquid Glass menu-bar popover: profile header, per-upstream mini-list with latency, recent events, quick toggles, diag/quit footer. [UI]
- [ ] Floating status window: minimal, always-on-top, opt-in for screen-sharing/demos. [UI]
- [ ] Settings redesign aligned to the config sections with inline validation feedback. [UI]
- [ ] Event inspector window - live, filterable, copyable, exportable (the UI equivalent of `pmctl events --follow`). [UI, Obs]
- [ ] Upstream detail sheet - latency sparkline, recent auth outcomes, test-now, temporary-disable. [UI, Obs]
- [ ] Accessibility pass - VoiceOver, Dynamic Type, high-contrast. [UI]
- [ ] Launch-at-login as a first-class Settings toggle with explanation. [UI]
- [ ] Multiple named profiles with quick switching. [UI]
- [ ] Docker / VM gateway-mode onboarding and dedicated settings. [UI]

## Simulators & demos

- [ ] Expand the `pm-sim` suite: `network-transition`, `auth-expiry`, `pac-fallback`, `dns-poison-attempt`, `tunnel-rotation`, `upstream-flap`, `socks5-mixed`, `gateway-mode`, `tunnel-flap`. [Rel, Sec, Sim]
- [ ] Chaos demo window (dev builds only): live state, color-coded event stream, and a fault injector (kill upstream, expire TGT, cut network, saturate, reset), excluded from release builds. [Sim, UI, Obs]
- [ ] 60-second demo recording - healthy → kill upstream → auto-failover → expire TGT → NTLM fallback → reset. Evidence, not marketing; linked from the README. [OSS]

## Open-source readiness

- [ ] `docs/architecture.md` expansion with the module and daemon/client diagrams. [OSS]
- [ ] `docs/configuration.md`: every config field documented with units, defaults, and validation rules. [OSS]
- [ ] Homebrew formula in a dedicated tap. [OSS]
- [ ] Developer ID signing + notarization for the app and helper; a `docs/releasing.md` documents the identity. [OSS, Sec]
- [ ] SemVer policy: 0.x allows breaking changes; 1.0 when the daily-driver reliability criteria are met. [OSS]
- [ ] **`SMAppService` signed privileged helper** - replaces the LaunchDaemon + install script; unlocks MDM distribution and userspace DNS interception. Depends on Developer ID signing. [OSS, Sec]
- [ ] **Credential isolation via Data Protection Keychain** - migrate off the login Keychain; eliminates ACL prompts. Requires signing. [Sec]
- [ ] **In-app updating** - Sparkle 2 with an EdDSA-signed appcast from GitHub Releases; opt-in automatic checks. Daemon-aware: hands the daemon over via the graceful-upgrade FD-handoff so in-flight connections survive, and fetches the appcast through the proxy/DIRECT per current routing. Depends on Developer ID signing + notarization. [OSS, Rel, UI]
- [~] **Config backup / restore** - runtime config now carries a schema version and auto-normalizes unversioned files; remaining: a user-facing backup/restore flow and explicit migration hooks. [UI, OSS]

## SASE coexistence

**Goal:** stay useful as corporate networks migrate from legacy explicit proxies to SASE
clients (Zscaler, Netskope, Cloudflare One). Design + rationale:
[`docs/design-extension-model-and-vision-grounding.md`](./docs/design-extension-model-and-vision-grounding.md).

- [~] **TLS-inspection diagnostics** - `pm-tls-check` captures the presented chain (direct or via CONNECT), classifies *publicly trusted* / *locally-trusted inspection* / *untrusted*, heuristically names the vendor, and exports the inspection CA as PEM. Remaining: live per-connection capture in `pmctl test-upstream` and the upstream detail UI, plus a structured event on inspection-CA change. [Sec, Obs, UI]
- [ ] **SASE-client coexistence detection** - model SASE agents like the VPN observer: detect the agent's localhost proxy listener behind an injectable protocol, treat it as an upstream that appears/disappears, and switch profiles automatically. [Rel, Obs]
- [ ] **SASE edge presets** - ship presets for documented explicit-proxy endpoints of major SASE vendors. Pure config + docs. [OSS]
- [ ] **Identity-aware auth (demand-gated)** - OIDC/device-cert auth legs as out-of-process extensions when a real deployment needs them; never speculatively in-core. [Sec]

---

## Non-goals

Declared so contributors don't drag the project here (rationale:
[`docs/design-extension-model-and-vision-grounding.md`](./docs/design-extension-model-and-vision-grounding.md)):

- **Packet-tunnel VPN.** Conduit coexists with corporate VPNs; it doesn't implement one. The adjacent step is a DNS-proxy provider post-signing.
- **In-process dylib/bundle plugins.** Extensions are separate processes over the versioned control plane + event stream. Third-party code never shares the daemon's address space (GSS contexts, secrets, Keychain).
- **HTTP/3 / QUIC / MASQUE (pre-2.0).** Proxied clients fall back to TCP; corporate MASQUE adoption is ~nil. Track, don't build.
- **Client-facing HTTP/2 listener (demand-gated).** HTTP/2 flows opaquely through CONNECT today; almost no client speaks HTTP/2 to an explicit proxy. Revisit on real demand.

## Enterprise addenda (post-1.0)

IT-integration work that complements but doesn't drive daily-driver quality. None of these
should delay the core roadmap.

- [ ] MDM / managed-preferences profile; the app reads the managed defaults domain on launch and locks managed fields in the UI. [Sec, OSS]
- [ ] `.pkg` installer with the helper bundled for silent deployment. [OSS]
- [ ] OpenTelemetry-compatible telemetry export (opt-in, complementary to the event stream). [Obs]
- [ ] Helper-binary tamper detection: verify the hash on startup and refuse to start on mismatch. [Sec]

## Optional cross-platform port (gated)

**Not active work.** Considered only if sustained non-macOS demand, macOS stability, and
ecosystem readiness all materialize; the architecture is preserved in
[`docs/roadmap-v2.md`](./docs/roadmap-v2.md).

- [ ] Linux headless support (`pm-proxy` + a systemd service file).
- [ ] Windows support.

## Out of scope

Explicitly not planned. Reversing any of these requires documenting a decision in
[`docs/roadmap-v2.md`](./docs/roadmap-v2.md).

- **iOS / iPadOS** - a Network-Extension architecture, fundamentally different from a user-space daemon.
- **Cross-platform Swift port** - SwiftNIO on Windows is pre-production and there's no maintained Swift Kerberos wrapper; a Rust port is the answer if cross-platform ever triggers.
- **Stabilized C ABI for external embedders** - if a port ever happens, the public API is the Unix-socket control protocol, not a C ABI.
- **A unified "verbose log everything" debug mode** - structured events first; log verbosity is a last-resort view.
