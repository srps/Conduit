# Conduit planning detail

Conduit is a macOS-native Swift menu-bar corporate proxy manager. The product work
strengthens the existing runtime, its recovery, and its user interface. No rewrite
or cross-platform port is planned.

This document explains implementation boundaries, dependencies, and acceptance
criteria. [`ROADMAP.md`](../ROADMAP.md) is the sole execution queue and status
tracker; [`CHANGELOG.md`](../CHANGELOG.md) records delivery. Subsystem design
documents carry detailed contracts. This document replaces the former V2 plan.

## Product and engineering direction

The daily-driver goal is reliable corporate-authenticated proxying across network
transitions, with bounded resource use and an explanation for every consequential
decision. The menu bar should cover routine tasks; the main window should make
configuration and diagnosis clear. The user-session daemon should keep traffic
flowing when the UI exits.

The [product pillars](../README.md#product-pillars) remain the contributor contract.
[`STYLE.md`](./STYLE.md) and [`AGENTS.md`](../AGENTS.md) define the engineering rules:
bounded state, validation at boundaries, explicit lifetimes, structured events,
and machine side effects behind injectable protocols and fakes. The architectural
inspiration is discipline and observability; native toolkit lifetimes and concrete
product needs determine the implementation.

The foundation is already in place: separate kernel/auth/PAC/platform targets,
shared helper/control contracts and a control bridge, CFNetwork PAC evaluation,
secret redaction, configuration validation/diffing, JSON presets, explicit circuit
states, and headless simulators. Use [`Package.swift`](../Package.swift) for the
actual target graph. The historical module split is documented in
[`design-module-split.md`](./design-module-split.md); do not replay it as future work.

The April ecosystem and competitive research is retained in an
[archive](./archive/planning-research-2026-04.md). It supplies historical context,
not current dependency versions, market claims, or a second implementation plan.

## Network locations and recovery

The location-recovery work is tracked in [#110](https://github.com/srps/Conduit/issues/110).

Network-path and VPN signals do not identify the macOS network location whose
settings Conduit captured. Restoring prior settings by service name alone can
apply the wrong location's configuration. Location awareness therefore starts as
a restoration-correctness change, before profiles or switching automation.

Observe the active location explicitly. Key prior state by stable location and
service identifiers, distinguish active from inactive locations, and account for
retained loopback endpoints. Design migration of existing journal entries without
guessing their location. Define behavior when locations/services are renamed or
deleted, an external switch occurs during an apply/restore, and recovery is partial.

Keep the VPN state machine, direct routing, split-DNS gates, and flap handling.
Implement shared platform policy in `PlatformMac` behind protocols and fakes; both
hosts must agree. `pm-proxy` remains isolated and performs no machine mutations.

Acceptance evidence:

- Location switches never restore another location's captured values.
- Inactive-location recovery does not leave settings pointing to dead listeners.
- External changes during apply/restore are handled without stale-generation writes.
- Journal migration, rename/deletion, interrupted restoration, and repeated recovery
  are covered by unit tests and fault-injection scenarios.
- Every observe/reconcile/recovery decision has a structured event.
- Controlled macOS 26/27 checks with the corporate VPN client precede deployment;
  automated tests use fakes and never replace the serving app/helper.

Named profiles can later associate a location with a profile. Automatic location
switching requires a separate opt-in contract for manual overrides, brief VPN
flaps, and broader DNS/IP/service-order changes. Observation and safe recovery do
not require that automation.

## Ownership and recovery after owner death

Launch recovery repairs outstanding settings when a host starts. It cannot repair
an outage if no replacement host starts. Production ownership must cover both
availability restoration and the authority to mutate or restore a surface.

Choose one client-side mutation authority. The app must not remain an independent
journal writer after the daemon migration. If privileged recovery uses helper-owned
leases, define one coherent authority model rather than two authoritative journals
for the same setting. Bind operations to authenticated owners, sessions, and
generations; do not rely on PID liveness alone.

For leases, persist previous/applied values before mutation. Schedule expiry
independently of potentially blocked client requests. Bound renewal, restoration,
and shutdown work. Compare current state with the applied generation before
restoring so an administrator's or user's later change is preserved. Define how
this interacts with location-scoped records and existing recovery of legacy residue.

Acceptance evidence:

- No two production hosts can simultaneously own listeners/platform mutations.
- Owner death without replacement triggers the documented recovery behavior.
- Crash before/after persistence or mutation, helper restart, stale renewal, PID
  reuse, external edits, sleep/wake, logout, and partial restore are tested.
- Repeated recovery is idempotent and failures remain observable.
- Restoring connectivity is documented separately from any mandatory-proxy policy;
  cleanup is not a security kill switch.

The existing restoration design is in
[`design-helper-proxy-restore.md`](./design-helper-proxy-restore.md). Finalize the
ownership/wire-compatibility contract before production lease wiring and before
moving the installed app to the daemon client.

## Request replay and resource budgets

Per-body spooling bounds one request's memory use. It does not bound total disk
consumption or downstream queued writes across concurrent requests. Replay must
follow downstream progress rather than read a whole file into an output queue.

Introduce a runtime-owned spool service with private session storage and explicit
lifetime through request draining. Bound aggregate spool bytes, queued writes, and
outstanding replay work in configuration. Keep creation, writes, and cleanup off
NIO event loops. Propagate setup/write failures and report cleanup failures without
turning an already completed response into a new request failure.

Acceptance evidence:

- Slow/stalled origins, many clients, pipelining, and cancellation stay within the
  declared memory, disk, file-descriptor, and work-queue budgets.
- Disk-full and create/write/cleanup failures produce structured outcomes.
- One runtime's shutdown or stale-file cleanup cannot remove another's active bodies.
- Auth replay and fallback preserve request bytes and retry semantics.
- Tests measure aggregate bounds and teardown, not only individual body sizes.

## Production daemon and app client

The runtime host is `ConduitDaemon`, running as the logged-in user. It owns proxy,
SOCKS5, PAC, DNS, transparent proxy, tunnels, health/recovery, network/VPN monitors,
and user-session platform managers. The privileged helper remains narrow.
`pm-proxy` remains a side-effect-free executable for CI and isolated reproductions.

The app and menu bar use the same versioned control contract as `pmctl`. Keep
credentials out of snapshots, events, diagnostics, and command payloads. Verify
Keychain, the user's Kerberos cache, and CFNetwork behavior in the LaunchAgent
session; a user-space process is not sufficient evidence of every session behavior.

Follow [`design-daemon-first-control-plane.md`](./design-daemon-first-control-plane.md)
with these delivery boundaries:

1. Wire a bounded production server to the existing protocol/client/bridge. Implement
   status/start/stop/reload and event access, then upstream tests. Validate versions
   and frames; bound subscriptions, queues, transactions, and cancellation.
2. Add exclusive-owner LaunchAgent install/uninstall/upgrade and readiness behavior.
   Repair stale state, validate directory/socket ownership, and define restart policy
   and prior-exit evidence. Do not invent an exit code that was not observed.
3. Move app/menu-bar commands and state subscriptions to `DaemonClient`. Reconnect
   after UI exit/crash/restart. Keep development composition over `FakeMachine`.
4. Verify reload and observable-file parity, including the daemon's connection audit
   sink and offline diagnostics. Distinguish a command's declaration from its
   implementation; named-profile switching waits for profile storage semantics.

Acceptance evidence:

- UI force-quit leaves HTTP/CONNECT/SOCKS5/DNS/tunnel traffic flowing.
- UI restart reconnects and displays the daemon's current state.
- Crash/restart restores service within the declared restart window and reports why.
- `pmctl` commands and file-based diagnostics work with and without a connected UI.
- Supported unrelated config changes preserve active sessions; rejected config leaves
  the prior generation intact. Settings/control paths agree on the committed policy.
- Platform ownership and recovery remain correct during start/stop/reload races.

## Secure GitHub Releases updating

The near-term update feature ([#111](https://github.com/srps/Conduit/issues/111))
provides manual checks, opt-in automatic checks, release notes, deferral, and an
explicit Install Update and Restart action. Prefer Sparkle 2 with an HTTPS appcast,
architecture-specific release ZIPs, Ed25519 archive signatures, and a public
verification key embedded in the app. Adding the updater dependency requires the
normal dependency review.

Keep ad-hoc signing available for shared builds. Developer ID/notarization improves
public distribution later but does not gate authenticated archive updates. A brief
proxy interruption is acceptable initially; zero-downtime daemon handoff is a
separate feature.

The flow is check → offer → bounded staging/download → verify → preflight/safe
shutdown → replace via a separate updater → relaunch → confirm readiness → reapply
managed settings. Preserve config/state and a recoverable previous app; document
rollback limits across migrations. Respect corporate proxy/DIRECT routing and
trusted CAs with TLS verification enabled.

Acceptance evidence:

- Preflight installation permissions and helper identity compatibility before
  shutdown. An ad-hoc build cannot satisfy a helper pinned to a local certificate;
  updates must preserve helper admission checks.
- Restore proxy/DNS safely before shutdown and reapply only after the new runtime
  is ready; failed startup must not strand dead loopback settings.
- Downloads, retries, staging, and cleanup are bounded. Download/authenticity,
  compatibility, replacement, launch, and startup failures have structured events
  and clear recovery paths.
- Release CI signs archives and publishes the feed; the update key is protected
  and backed up. Test actual old-to-new updates on macOS 26/27 and both architectures.
- Document first-install/post-update Gatekeeper approval and managed-Mac limits;
  do not promise prompt-free launch.
- Platform work stays behind protocols/fakes, with unit tests and restart/recovery
  simulators; `pm-proxy` remains side-effect-free.

## Release evidence and the 1.0 gate

Performance and simulator CI already exist on main. The separate release-work
branch adds ARM/Intel packaging and optimized PAC checks; land those before treating
them as the main-branch baseline. Add release documentation covering installation,
signing, helper-pin, migration, and rollback requirements.

Measure optimized builds under idle, representative concurrent load, and an
hours-long soak: request latency percentiles, steady-state/peak RSS, CPU/wakeups,
file descriptors, and growth over time. Record hardware, configuration, workload,
and measurement method. The existing debug cold-start/RSS/wall-time gates do not
establish release p99 latency or long-run stability. Start with reproducible
baselines and tolerances; tune allocations/parsers only against measured costs.

Before 1.0:

- Record at least 90 days of daily use without a required manual restart; regressions
  restart the evidence window after their fix. Record config/build and incident data.
- Pass full CI checks, relevant optimized behavior checks, and daemon/location/crash
  scenarios, with controlled upgrade/rollback evidence.
- Complete human VoiceOver, keyboard, text-scaling, and high-contrast checks on the
  menu bar, main window, settings, and validation feedback.
- Verify Developer ID signing/notarization and installation on a clean machine.
  Ad-hoc package verification and local helper-caller signing serve different purposes.
- Provide current configuration, architecture, setup, and migration documentation
  that a colleague unfamiliar with the code can follow.

## Later feature contracts

These boundaries guide future design; priority and checkbox status remain in the
roadmap.

**Gateway security:** `strictMode` governs routing/direct fallback. Introduce explicit
client admission/auth settings instead of changing its meaning. Define HTTP and
SOCKS admission, trusted clients, credential mechanisms, denial behavior, and
onboarding together. Do not treat an upstream authenticator as a ready-made
server-side authenticator.

**Secure upstreams:** preserve transport kind through config/PAC/routing, then define
TLS hostname/trust validation, handshake deadlines, auth binding, and downgrade
refusal. Optional SPKI pinning follows, with rotation windows and mismatch events.
Destination TLS through CONNECT does not provide TLS to the upstream proxy.

**Graceful upgrades:** listener transfer covers new accepts. Existing HTTP requests,
CONNECT/SOCKS tunnels, DNS work, and tunnel sessions need a defined outgoing-runtime
drain policy, ownership transfer, deadline, rollback, and protocol-specific tests.
Update UX must disclose any interruption until zero-downtime behavior is verified.

**Profiles and configuration:** named profiles need durable storage, credential
identity, schema/migration semantics, and transactional validation/application.
Profile switches must not expose a partly applied policy. Add menu-bar and location
associations after this contract; preserve manual overrides for automation.

**Health and observability:** tunnel probes must not tear down active sessions when
they mark warning. Event inspectors, upstream history, and connection metrics need
bounded retention and redaction. Audit existing unit/scenario coverage before adding
scenario names; each new runtime behavior still needs tests and a simulator.

**Distribution:** secure archive updating is near-term and independent of
Developer ID/notarization or zero-downtime handoff. Signed helper lifecycle,
Data Protection Keychain, and any DNS Network Extension need their own signing,
access-group, entitlement/distribution, upgrade, and rollback validation. Signing
alone does not establish those capabilities or eliminate all credential prompts.

**Extensions and enterprise integrations:** real deployment demand precedes SASE
automation, identity-aware extensions, managed settings, or telemetry export.
Extensions run out of process over the versioned control plane/events; third-party
code never shares the credential-bearing runtime. See
[`design-extension-model-and-vision-grounding.md`](./design-extension-model-and-vision-grounding.md)
for the historical rationale, subject to the current scope below.

## Scope decisions

The product stays on Swift and macOS. Rewrites, cross-platform ports, iOS/iPadOS,
packet-tunnel VPNs, in-process plugins, and a stabilized external C ABI are outside
the plan. HTTP/3/QUIC/MASQUE and a client-facing HTTP/2 listener require a concrete
deployment need before design work. Structured events remain the diagnostic
contract; verbose logs are a secondary view.

Changing this scope requires recording the product need, alternatives, maintenance
cost, validation plan, and effect on the daily-driver queue here. Historical
research or a language-learning preference does not create an implementation track.
