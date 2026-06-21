# Extension Model, Web-Standards Coverage, and Vision Grounding

**Date:** 2026-06-10
**Status:** Proposal — grounds the "lightweight core + plugins" vision and the
"modern web standards" goal against the existing Plan A architecture, and
defines the implementation plan for both. Companion critique of
`roadmap-v2.md` / `ROADMAP.md` is in §1.

---

## 1. Vision grounding — what stands, what should change

The written plan (roadmap-v2 + ROADMAP) is unusually honest and mostly
correct: the niche analysis is real, the Plan B gating is wise, and the
module-split → hardening → daemonize sequencing was the right order. The
points below are where the vision as *spoken* ("full featured corporate
proxy/VPN, plugin-extensible, lightweight core") diverges from what the
evidence supports.

### 1.1 The plugin vision conflicts with the security pillar — resolve it out-of-process

"Users install plugins, or develop their own" implies in-process loading of
third-party code (dylib/bundle). For *this* product that is the wrong
mechanism:

- The daemon holds live GSS contexts, NTLM hashes (`SecretBytes`), Keychain
  access, and a privileged-helper channel. Third-party code in that address
  space can read all of it. The threat model (`docs/threat-model.md`) cannot
  survive "arbitrary signed-by-nobody dylibs in the credential process."
- Library validation must be disabled to load non-team-ID dylibs — exactly
  the hardened-runtime flag a security-sensitive tool should never give up,
  and a notarization smell.
- Swift has no practical plugin ABI story for third parties (library
  evolution mode, version lockstep). Every plugin would pin to a compiler
  version; the maintenance cost lands on a solo maintainer.

**The grounded form of the same vision: the control plane *is* the plugin
API.** The daemon-first control plane already builds a versioned typed
protocol over a Unix socket plus an NDJSON event stream. Extensions are
separate processes — any language,
any signing identity, zero access to daemon memory, crash-isolated. This is
the Ghostty lesson the plan already cites (§5.7: no C-ABI embedding) applied
to plugins.

### 1.2 "Lightweight core, NTLM as a plugin" optimizes the wrong axis

NTLM is ~300 LOC over CommonCrypto with no UI, no background cost, and no
attack surface when unconfigured (the Negotiate fallback is already lazy by
invariant). Extracting it saves nothing measurable; the build flavors that
*do* matter already exist or are planned:

- `pm-proxy` — side-effect-free headless core (exists).
- `ConduitDaemon` — daemon without UI (the daemon-first control plane).
- `Conduit.app` — full UI client.

"Lightweight" should mean *daemon without app*, which the daemon-first
control plane delivers. Where modularity genuinely pays is **optional
subsystems with real weight or risk**: the transparent proxy + privileged
helper, tunnel forwarding, and future protocol work. Those stay compile-time
SPM targets (the module-split import-fence pattern),
selected by configuration — not runtime-loaded code. Keep the existing
invariant: a feature that is off costs nothing and listens on nothing.

### 1.3 VPN means *coexistence*, and that's already a strength

(2026-06-10 clarification: the vision is "works flawlessly over the corporate
VPN that's already running," not "implements a VPN.") That reading is already
one of the project's strongest shipped capabilities — the VPN flap-resilience
work, `VPNStateFuser`, split-DNS safety in routing, and the half-open
dual-stack fallback all serve it. Keep investing on that axis (the
`network-transition` scenario is the open item), and state implementing a
packet-tunnel VPN as an explicit non-goal in README/ROADMAP so contributors
don't drag the project there. See §1.6 for where VPN-coexistence thinking
extends naturally into the SASE world.

### 1.4 Sequencing: OSS feedback is the gate for everything else — pull it forward

UI-excellence work (6–10 sessions) and the chaos demos currently sit between
today and open-source prep (signing, brew, getting-started). But every
strategic gate in the
plan — Plan B triggers, enterprise addenda, even 1.0 — keys off *external
demand signals* that cannot arrive until people can install the thing. The
SASE anti-trigger cuts both ways: the legacy-explicit-proxy niche is
shrinking, so time-to-public matters more than polish. Make it explicit:
**open-source-prep core (signing + notarization
+ brew + getting-started + CI) lands before the UI-excellence and demo
work**, with the UI pass trimmed to a fast menu-bar pass for launch. The
TestFlight/3-testers exit criterion converts to
"first 10 external GitHub issues triaged."

### 1.5 The 1.0 reliability criterion is unmeasurable without a crash loop

"Zero 'I had to restart it' moments in a rolling quarter" is the right bar,
but today's evidence channel is the user noticing an `.ips` file days later.
The daemon-first watchdog +
`lifecycle.crash_restart` event closes half the loop; close the rest:
`pmctl diag` collects recent sanitized crash reports, and the README invites
them in bug reports. A reliability bar you can't measure is a vibe, not a
criterion.

### 1.6 SASE is not (only) a threat — it's the next coexistence target

The SASE trend (Zscaler Client Connector, Netskope, Cloudflare One, Entra
Private Access) shrinks the *legacy explicit proxy* niche, but it does not
shrink the *developer pain* Conduit actually solves — it mutates it.
What survives, and what Conduit is uniquely positioned to own:

**TLS-inspection diagnostics + trust distribution (high value, squarely
in-pillar).** Every SASE deployment MITMs TLS, and the dominant developer
pain becomes certificate trust: `node`/`python`/`java`/`curl` each need the
inspection root CA wired up differently (`NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, keystores…). Conduit already sits on the wire and
already manages the shell environment file. Build: per-connection upstream
cert-chain capture surfaced in `pmctl test-upstream` / the upstream detail UI
("inspected by Zscaler Root CA"), detection of inspection-CA changes
(structured event), and opt-in export of the inspection root into the
env-file mechanism for the common toolchains. Nobody ships this; every
developer in a SASE org needs it weekly.

**SASE-client coexistence detection (extends the VPN-flap pattern).**
ZCC/Netskope clients commonly expose a localhost proxy or PAC in
tunnel-with-local-proxy modes, and they come and go like VPN sessions.
Model them exactly like the VPN observer: detect the agent's local listener
(process/port probe behind a protocol, like `VPNStatusObserving`), treat it
as an upstream that appears/disappears, and switch profiles automatically.
Conduit's failover ladder, health probes, and observability apply
unchanged — the upstream is just `localhost:9000` instead of
`proxy.corp:3128`.

**SASE edge presets + health.** Ship presets for the documented
explicit-proxy endpoints of the major SASE vendors (Zscaler
`gateway.<cloud>.net`, Netskope explicit-proxy) the same way the example-corp
preset ships. Zero new machinery; pure config + docs.

**Identity-aware auth (demand-gated; lands with the out-of-process
auth-provider extensions).** SASE replaces Kerberos/NTLM with device certs
and OIDC tokens. When a real deployment needs it, the out-of-process
auth-provider extension point is the hook — do not build OIDC into the core
speculatively.

The strategic reframing: today's tagline is "corporate proxy manager with
real failover"; the durable version is **"the developer's egress control
plane on macOS — stable local endpoint, observability, and trust management
over whatever the company runs this year"**. Legacy proxies, SASE clients,
and hybrid messes are all just upstreams with different health behaviors.

### 1.7 What the docs get right — keep

- Import fence enforced by the build, not review. Best idea in the repo;
  extend it to every new target (§2).
- Bounded-everything + structured-events-first. These two invariants are
  what will make the OSS project reviewable by strangers.
- Plan B preservation with explicit triggers/anti-triggers. Don't touch it.
- pm-sim-before-ship. The GSS crash is the counterexample that proves the
  rule: the one subsystem a simulator can't fake (real Heimdal) is where the
  field crash lived. Hence the sanitizer-soak recommendation (§4).

---

## 2. Extension model (the grounded plugin architecture)

### Goals

- Third parties extend Conduit without touching daemon memory or
  requiring a Swift toolchain.
- The core stays auditable: extension surface = control protocol + event
  stream, both already versioned contracts.
- A removed/crashed extension degrades its feature only; the daemon never
  blocks on an extension.

### Non-goals

- In-process dylib/bundle loading (see §1.1). Revisit only if Apple ships a
  sandboxed ExtensionKit story for daemons.
- A plugin marketplace/registry pre-1.0.
- Stable *Swift* API for embedding; the stable surface is the wire protocol.

### Extension points (in dependency order)

**Observer extensions (ship with the daemon-first control plane, nearly
free).**
Read-only consumers of `events.ndjson` / `snapshot.json` / `events --follow`.
Covers: exporters (OTel, Splunk), notifiers, dashboards, statistics. Work:
document the event schema as a public contract (`docs/events.md`), add
`schemaVersion` to the NDJSON header line, and promise additive-only changes
within a major version. This makes the enterprise-addenda OTel exporter a
*third-party-buildable* tool instead of core work.

**Command extensions (just after the daemon-first control plane).**
`pmctl`-equivalent control-socket clients with scoped permissions. Work: the
control protocol gains a capability handshake (`observe`, `control`,
`configure`) so a dashboard extension can't call `stop`. Owner-only socket
already enforced; capabilities are belt-and-suspenders for the
multi-extension future.

**Routing/decision hooks (post-1.0, pull-based).**
The genuinely novel extension point: "let me veto/redirect a connection."
Implement as a *synchronous-with-deadline* request over a dedicated extension
socket: daemon → extension `route-query {host, port, pac_decision}` with a
hard 5 ms budget and a fail-open/fail-closed per-extension config. Bound the
queue (STYLE rule 1), emit `extension.timeout` events, and circuit-break
a slow extension exactly like a flapping upstream — the pattern already
exists. If no third party ever asks for this hook, never build it.

**Auth-provider extensions (only on demonstrated demand).**
A SASE/OIDC/custom-SSO auth handshake as an external helper process speaking
a challenge/response protocol (effectively out-of-process
`ProxyAuthenticator`). Latency is fine (auth legs are rare), but the
credential-isolation analysis is subtle — design doc required before any
code. Kerberos/NTLM stay in-core forever; they are the product, not plugins.

### Packaging

Extensions are plain executables + a manifest
(`~/Library/Application Support/Conduit/Extensions/<name>/manifest.json`
with name, version, capabilities, socket scope). The daemon launches nothing;
extensions are user-launched (launchd agents, brew services). The daemon's
only knowledge of extensions is capability enforcement + per-connection
attribution in events. This keeps the daemon's threat model unchanged.

---

## 3. Web-standards coverage

Assessment of "doesn't support modern web standards" against the actual
proxy role — an explicit forward proxy is mostly a *tunnel*; standards
matter at the edges:

**WebSocket upgrade through the plain-HTTP path (gap, fix in
hardening-class work).** `wss://` already works (opaque CONNECT). Plain
`ws://` via an explicit proxy arrives as `GET` + `Upgrade: websocket` at
`HTTPProxyHandler`, which has no upgrade handling — and the hop-by-hop
sanitizer strips `Upgrade`/`Connection: upgrade`, so the handshake dies.
Fix: detect the upgrade request, switch the
client↔upstream exchange to raw relay on `101` (the relay machinery exists
in the CONNECT path), preserve `Upgrade`/`Connection` for that exchange
only. Add `pm-sim websocket-upgrade` (fake origin answering 101 + echo
frames) before shipping, per invariant. Same mechanism covers any future
`Upgrade:` protocol.

**HTTP/2 (mostly a non-problem; document it).** Browsers speak
HTTP/1.1 CONNECT to explicit proxies and run h2 *inside* the tunnel — that
works today, and `ProtocolDetector` already recognizes the h2 preface on the
transparent path. Client-side h2-to-proxy (RFC 8441 extended CONNECT) is
spoken by almost no client against explicit proxies; a real-world HTTP/2
client failure we investigated was the client bypassing the proxy, not a
Conduit gap. Plan: a `docs/` compatibility note + a
`pm-sim h2-through-connect` scenario asserting the tunnel is truly opaque
(no buffering/latency cliffs for long-lived h2 streams). Implementing an h2
listener is post-1.0 at earliest, demand-gated like Plan B.

**HTTP/3 / QUIC / MASQUE (explicit non-goal pre-2.0).** Clients with a
configured proxy fall back from QUIC to TCP; MASQUE (`CONNECT-UDP`) adoption
in corporate proxies is ~nil. Track, don't build. The SOCKS5 UDP relay
already covers the rare UDP-tunnel need.

**Standards hygiene quick wins (fold into the hardening backlog).**
`Expect: 100-continue` forwarding behavior (verify against the body-spooling
path), trailer pass-through on chunked responses, and `421 Misdirected
Request` handling on reused tunnels. Each is a small test-first check against
the existing handlers; file as individual roadmap checkboxes.

---

## 4. Reliability & memory hardening program

The "crashes / leaks / unknown classes" worry, made systematic:

**Crash-loop closure (with the daemon-first control plane).** Watchdog
restart + `crash_restart` event (planned) + `pmctl diag` collecting sanitized
recent `.ips` reports +
a `docs/` triage runbook ([`docs/crash-triage.md`](crash-triage.md), whose
template is: instruction-stream → branch identification → fault-address →
field-offset).

**Sanitizer soaks (scheduled CI, not per-merge).** Weekly job: full
`pm-sim` suite under ASan and TSan (`-sanitize=address` / `thread`), plus a
30-minute `multi-100` soak with `MallocStackLogging` asserting RSS plateau
(the perf gate already measures max RSS; add a slope check). C-boundary
code (GSS, CommonCrypto, CFNetwork) is where the type system can't help —
this is the net for the next field crash.

**Confinement assertions.** Debug-only `eventLoop.assertInEventLoop()`
in state-mutating methods of the big `@unchecked Sendable` handlers
(`HTTPProxyHandler`, `CONNECTHandler`, `SOCKS5Handler`). Cheap, catches the
race class that TSan only finds when a schedule happens to interleave.

---

## 5. Roadmap deltas (applied to ROADMAP.md 2026-06-10)

1. Daemon-first control plane: add the observer extensions (event-schema
   contract + `docs/events.md`) and command extensions (capability handshake)
   items; mark the routing-decision hooks and out-of-process auth-provider
   extensions as demand-gated post-1.0 with a pointer here.
2. Hardening: WebSocket upgrade + `pm-sim websocket-upgrade`
   (**shipped 2026-06-10**), the HTTP standards-hygiene checkboxes; the
   sanitizer-soak CI job; confinement assertions.
3. Open-source prep: pull signing/brew/getting-started/CI ahead of the
   UI-excellence and demo work; replace the TestFlight exit criterion with an
   external-issue-triage criterion.
4. README/ROADMAP: state non-goals explicitly — packet-tunnel VPN, in-process
   plugins, HTTP/3/MASQUE (pre-2.0), h2 listener (demand-gated).
5. Daemon diag: `pmctl diag` includes sanitized crash reports (crash-loop
   closure).
6. New "SASE coexistence" section (after the daemon-first control plane,
   before enterprise addenda): TLS-inspection diagnostics + trust
   distribution, SASE-client coexistence detection, SASE edge presets, and
   identity-aware auth via the out-of-process auth-provider extensions
   (demand-gated). See §1.6.
