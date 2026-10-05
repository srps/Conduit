# Conduit Roadmap

The execution queue and sole tracker of product-work status. Reviewed against the
checkout on 2026-10-02. Conduit remains a macOS-native Swift corporate proxy manager;
no rewrite or cross-platform port is planned.

Implementation rationale, dependencies, and acceptance criteria live in
[`docs/planning.md`](./docs/planning.md). Shipped history lives in
[`CHANGELOG.md`](./CHANGELOG.md). Later features do not block the current work.

Pillars: **[Rel]** Reliability, **[Sec]** Security, **[Eff]** Efficiency,
**[Obs]** Observability, **[UI]** Great UI, **[Dmn]** Daemon-first,
**[Sim]** Simulators & demos, **[OSS]** Open-source readiness.
`[ ]` means planned; `[~]` means partially implemented; `[x]` means implemented,
with remaining validation called out separately. An item needs a pillar fit.

See also [Product Pillars](./README.md#product-pillars), [`AGENTS.md`](./AGENTS.md),
and [`docs/STYLE.md`](./docs/STYLE.md).

## Now

1. [x] **Network-location-safe recovery ([#110](https://github.com/srps/Conduit/issues/110))** — active-location observation independent of path/VPN signals, stable location/service journal identity, compare-and-write helper v5, inactive-location cleanup, conservative legacy migration, and shared app/daemon reconciliation are implemented with unit and simulator coverage. External edits, renames/deletion, failed reapply, loginwindow cleanup, and stale active-location writes are covered. Shipped in 0.4.0 and validated with helper v5 and the corporate VPN client on macOS 26; macOS 27 was waived for that release and remains untested. Same-location drift repair is bounded against programs that keep rewriting proxy settings ([#116](https://github.com/srps/Conduit/issues/116)). Profile associations ([#114](https://github.com/srps/Conduit/issues/114)) and opt-in switching ([#115](https://github.com/srps/Conduit/issues/115)) follow later. See [`docs/design-network-location-recovery.md`](./docs/design-network-location-recovery.md). [Rel, Obs, UI, Sim]
2. [ ] **Secure GitHub Releases updating ([#111](https://github.com/srps/Conduit/issues/111))** — manual and opt-in automatic checks, release notes, and explicit Install Update and Restart. Prefer Sparkle 2 with Ed25519-authenticated archives and an embedded verification key. Preserve config/state, preflight helper identity compatibility, restore proxy/DNS before shutdown, and reapply only after readiness. Keep downloads/staging/retries bounded and recover from verification/replacement/launch failures. A brief interruption is acceptable; Developer ID/notarization and zero-downtime handoff do not gate this feature. [OSS, Rel, Sec, UI, Obs, Sim]
3. [~] **Owner-death recovery and one mutation authority** — app and daemon launch recovery exist. Remaining: exclusive ownership of platform mutations and durable recovery when no replacement runtime starts. Coordinate journal authority, authenticated helper sessions, and any helper-owned leases; preserve later external changes. This is a production daemon-migration gate. [Rel, Sec, Dmn, Sim]
4. [~] **Request-body replay bounds and isolation** — per-body bounded spooling exists. Remaining: runtime-owned private spool storage, aggregate disk/queued-write budgets, replay backpressure tied to downstream completion/writability, off-event-loop cleanup, and structured failure reporting. Cover slow origins, disk failures, cancellation, and concurrent runtimes. [Rel, Sec, Eff, Sim]

## Next

Implement the daemon work in the order below. Named profiles, demo UI, and advanced
metrics do not block the first usable daemon/client slice.

1. [~] **Production control socket** — protocol, bridge, `DaemonClient`, `pmctl`, versioning, metadata, config generation, and stable error codes exist; `pm-proxy` has an isolated server. Wire a bounded server into `ConduitDaemon` for status/start/stop/reload and event access, then upstream tests. Define subscription limits, cancellation, disconnects, and version mismatch behavior. [Dmn, Obs, Rel]
2. [~] **User-session daemon and LaunchAgent lifecycle** — `ConduitDaemon` owns an explicit runtime host, platform managers, credential-store seam, launch recovery, and observable files. Remaining: production install/uninstall/upgrade lifecycle, exclusive-owner startup/readiness, state-dir checks, stale-state repair, restart policy, and crash-restart evidence. Confirm logged-in-user Keychain, Kerberos, and CFNetwork behavior. `pm-proxy` stays side-effect-free. [Dmn, Rel, Sec, Sim]
3. [ ] **App and menu bar adopt the daemon client** — replace app ownership of listeners, monitors, and platform mutations with commands and snapshot/event subscriptions. Bootstrap the LaunchAgent when needed; reconnect after UI restart. Keep any in-process fallback dev-only and remove it from production before 1.0. [Dmn, UI, Rel, Sim]
4. [~] **Reload and observability parity** — section diffing, reload paths, capped `events.ndjson`, atomic `snapshot.json`, and offline diagnostics exist. Verify supported unrelated changes preserve active HTTP/CONNECT/SOCKS5/DNS/tunnel sessions. Wire the connection audit sink into `DaemonRuntimeHost`; bounded, redacted audit files already work in the app and `pm-proxy`. [Dmn, Rel, Sec, Obs, Sim]
5. [~] **Release and daily-driver evidence** — Full debug tests, simulator CI, and cold-start/throughput gates exist. ARM/Intel ZIP/DMG packaging, optimized PAC checks, and helper upgrade/rollback guidance ship with 0.4.0. Remaining: representative release-build latency, idle CPU/RSS and sustained-growth baselines, crash/restart/upgrade evidence, human accessibility validation, and a recorded 90-day reliability window for 1.0. [Rel, Eff, UI, OSS]
6. [ ] **Release trust and installation** — Developer ID signing/notarization for app and helper, documented identities/upgrade/rollback behavior, and clean-machine installation validation. Local caller-identity signing and ad-hoc CI packaging are foundations, not completion of public release trust. [OSS, Sec]
7. [ ] **Configuration and architecture documentation** — document every config field's units/defaults/validation in `docs/configuration.md`; refresh `docs/architecture.md` for the actual target graph, both hosts, and daemon/client migration. Add release guidance covering installation, signing, updates, and rollback. [OSS, Obs]

## Later

### Reliability and security

- [ ] **Kerberos credential expiry** — explicit mid-session expiry/renewal/fallback contract and scenario coverage, including unavailable renewal and absent NTLM credentials. [Rel, Sec, Sim]
- [ ] **Tunnel health probes** — bounded per-tunnel probes; failures mark warning without tearing down active sessions; add `tunnel-flap`. [Rel, Obs, Sim]
- [ ] **Upstream selection strategies** — retain draggable priority order; optionally add automatic stable selection with measured EWMA/hysteresis behavior. [Rel, Obs, UI]
- [ ] **Isolated crash cleanup** — verify `pm-proxy` restart after `SIGKILL` repairs its own socket/spool state without manual intervention or host side effects. [Rel, Sim]
- [~] **HTTP standards hygiene** — `Expect: 100-continue` and pooled response trailers exist; remaining: `421 Misdirected Request` handling on reused connections. [Rel]
- [ ] **Graceful upgrade and connection draining** — design listener handoff plus outgoing-runtime session draining, deadlines, rollback, and platform-ownership transfer. Listener FD handoff alone does not preserve active sessions; validate each supported protocol before claiming zero downtime. [Rel, Dmn, Sim]
- [ ] **Inbound gateway admission/authentication** — define explicit client admission and auth policy, then supported Negotiate/NTLM server-side mechanisms. Keep `strictMode` as routing policy; it is not client authentication. [Sec, Sim]
- [ ] **SOCKS5 auth hardening** — username/password mode alongside no-auth, with explicit per-client-CIDR admission for gateway deployments. [Sec, Sim]
- [ ] **Secure upstream transport, then optional pinning** — model transport kind, hostname/trust validation, handshake deadlines, auth binding, and downgrade refusal before adding per-upstream SPKI pins and rotation windows. [Sec, Rel, Sim]
- [ ] **Control-socket capability scopes** — demand-gated observe/control/configure authorization for a multi-client model, after the production owner-only socket contract. [Sec, Dmn]
- [~] **Credential-bearing string audit** — in-memory boundaries and durable sinks are covered; document lifecycle-bound one-shot HTTP header strings and verify cleanup/redaction. [Sec]
- [~] **Keychain isolation** — device-bound accessibility exists; design caller restrictions and Data Protection Keychain migration with signing/access-group and upgrade compatibility tests. [Sec, UI]

### Daily UI and profiles

- [ ] **Named profiles and quick switching** — storage, validation, credential identity, and transactional switch behavior; then `set-profile`, menu-bar profile header, and optional location-to-profile associations ([#114](https://github.com/srps/Conduit/issues/114)). [UI, Dmn, Rel]
- [ ] **Opt-in location switching ([#115](https://github.com/srps/Conduit/issues/115))** — only after location-safe recovery and profiles; respect manual overrides and brief VPN flaps, with macOS/VPN compatibility and recovery validation. [Rel, UI, Sim]
- [ ] **Event inspector** — live, bounded, filterable, copyable/exportable events, plus an upstream detail sheet with latency history, recent auth outcomes, test-now, and temporary disable. [UI, Obs]
- [~] **Accessibility and HIG validation** — existing VoiceOver labels/grouping need listening tests; audit text scaling, high contrast, keyboard access, and remaining views. [UI]
- [~] **Floating status surface** — keep-on-top exists; a minimal status-only window remains optional. [UI]
- [ ] **Gateway onboarding** — Docker/VM settings that explain binding, admission/auth policy, and recovery. [UI, Sec]
- [~] **Config backup/restore** — schema versioning and normalization exist; remaining: user-facing export/import and explicit migration hooks. [UI, OSS]
- [ ] **Connection/tunnel metrics** — bounded, redacted bytes, uptime, protocol, activity, route/upstream/auth data over the control plane and in the UI. [Obs, Dmn]

### Measurement and demonstrations

- [~] **Allocation and performance analysis** — add Instruments allocation stacks and drift baselines to existing gates. Parser/header-interning changes follow measured bottlenecks. [Eff]
- [~] **Scenario coverage completion** — audit behavioral coverage before adding named scenarios: auth expiry, PAC fallback, DNS poison rejection, tunnel rotation, mixed HTTP/SOCKS, gateway admission, and tunnel health. Network transitions, connection flood, auth storm, and upstream flap already have scenarios. [Rel, Sec, Sim]
- [ ] **Chaos demo and recording** — dev-only SwiftUI state/events/fault UI over fake credentials and isolated resources; a short recovery demonstration after the daemon/client path works. [Sim, UI, Obs, OSS]

### Distribution and demand-gated integrations

- [ ] **Homebrew tap** and documented SemVer/migration policy. [OSS]
- [ ] **Signed helper lifecycle** — evaluate `SMAppService` installation/removal after public signing is established; treat any DNS Network Extension as a separate entitlement/distribution design. [OSS, Sec]
- [~] **TLS-inspection diagnostics** — `pm-tls-check` exists; remaining: control/UI integration and an event on inspection-CA change. [Sec, Obs, UI]
- [ ] **SASE coexistence** — demand-gated injectable agent/listener detection and documented endpoint presets; automatic profile changes depend on profiles and verified routing behavior. [Rel, Obs, OSS]
- [ ] **Identity-aware auth extensions** — real-deployment demand required; separate processes over the control plane. [Sec, Dmn]
- [ ] **Enterprise integrations (post-1.0)** — managed preferences, managed update policy, silent `.pkg` deployment, opt-in telemetry export, and helper-binary integrity checks. None delay the daily-driver queue. [Sec, OSS, Obs]

## Implemented foundations

This is a baseline for planning, not a replacement for the changelog.

- [x] Module split, protocol seams, STYLE, threat model, `SecretBytes`, credential/log redaction, and bundled JSON presets. [Sec, OSS]
- [x] Native CFNetwork PAC evaluation; JavaScriptCore migration is complete. [Rel, Sec]
- [x] Explicit upstream circuit-breaker states, transition events, tests, and `upstream-flap`. [Rel, Obs, Sim]
- [x] Network-transition, connection-flood, and auth-storm scenarios; scenario outcomes and full-suite CI gates. [Rel, Sim]
- [x] Settings redesign with inline validation, Liquid Glass menu chrome, VPN interface display, keep-on-top, and the General launch-at-login toggle. [UI, Obs]
- [x] App/daemon launch recovery and serialized platform work; helper caller-identity support with local signing. Production installation/soak evidence remains tracked above. [Rel, Sec]
- [x] Full debug tests, simulator CI, and cold-start/throughput performance gates. ARM/Intel release packaging and optimized PAC checks ship with 0.4.0. [OSS, Eff]

## Out of scope

- Rewrites, cross-platform ports, and iOS/iPadOS support.
- Packet-tunnel VPNs and in-process third-party plugins.
- A stabilized C ABI for external embedders; clients use the versioned control protocol.
- HTTP/3/QUIC/MASQUE and a client-facing HTTP/2 listener without a demonstrated deployment need.
- A unified verbose-log mode as the primary diagnostic surface; structured events remain the contract.

Scope changes require a documented decision in [`docs/planning.md`](./docs/planning.md).
The dated ecosystem research is [archived](./docs/archive/planning-research-2026-04.md).
