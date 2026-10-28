# Conduit Roadmap

The execution queue and sole tracker of product-work status. Reviewed against the
checkout and open issues on 2026-10-26. Conduit remains a macOS-native Swift corporate proxy manager;
no rewrite or cross-platform port is planned.

Implementation rationale, dependencies, and acceptance criteria live in
[`docs/planning.md`](./docs/planning.md). Shipped history lives in
[`CHANGELOG.md`](./CHANGELOG.md). Owner decisions, with their decision,
implementation and validation status, are recorded in
[`docs/decisions/`](./docs/decisions/README.md); items link to them instead of
repeating their rationale. Later features do not block the current work.

Pillars: **[Rel]** Reliability, **[Sec]** Security, **[Eff]** Efficiency,
**[Obs]** Observability, **[UI]** Great UI, **[Dmn]** Daemon-first,
**[Sim]** Simulators & demos, **[OSS]** Open-source readiness.
`[ ]` means planned; `[~]` means partially implemented; `[x]` means implemented,
with remaining validation called out separately. An item needs a pillar fit.

See also [Product Pillars](./README.md#product-pillars), [`AGENTS.md`](./AGENTS.md),
and [`docs/STYLE.md`](./docs/STYLE.md).

## Immediate priorities (2026-10-28)

The runtime architecture program ([#186](https://github.com/srps/Conduit/issues/186),
[#180](https://github.com/srps/Conduit/issues/180),
[#183](https://github.com/srps/Conduit/issues/183)) is **unreleased**. Conduit 0.5.8
remains the serving version. [CHANGELOG](./CHANGELOG.md) records shipped history.

| Stage | Current state | Remaining work |
| --- | --- | --- |
| Contracts and mechanisms | Typed lifecycle/configuration values, framed client/service, bounded observation/replay, verified store and file readers are merged. | Broader event families migrate with their owners. |
| Shared owner | PR253 converges DNS, tunnels and proxy on one lifecycle/store path, with preparation-time capture, exact freshness and Stop/Quit policy. PR257 adds guarded host-owned audit parity. | Verify AppState consumes that owner without a parallel path. |
| Actual client integration | PR254 connects host admission/observation, private frozen updates, receipts, preferences/admin persistence and final Quit saves through the actual framed clients. | Local and exact-head hosted gates pass; consume it through the native-client completion below. |
| Native client completion | PR256 merged saved Start receipts, explicit reload, bounded preflight/credential/wake operations, typed recovery and DNS health after local and hosted checks. | Ten seconds total is selected in 0039; consume it with the production composition. |
| AppState, isolation and release | One final activation and deletion is selected (0031); 64 KiB ordinary frames and 8 MiB private frames are selected. | Use the selected 10,000-row / 4 MiB capture / 8 MiB retained collection profile (0038), consume the measured production profile, verify the in-progress single AppState switch and deletion, move the control cluster to RuntimeActor, then complete release acceptance. |

The [client-owner checkpoint](./docs/verification-runtime-client-owner-2026-10-27.md)
records the scoped independent review and all 41 passing local gates: 3,619 tests
(four skips), 103 simulator records and perf. PR254 merged after exact-head hosted Swift/CodeQL passed. Do not copy test profiles into production.
The resolved-source actual-client probe passed 29 mode/trials and independent
review, including the production Quit routine. Whole-probe numbers are not
installed-app RAM or shipping responsiveness claims.

The merged [module-owner verification](./docs/verification-runtime-module-owner-2026-10-27.md)
records all 41 local workflow checks, 3,551 tests (four skips), 103 simulator
records, 26 clean guard mutations and exact-head hosted evidence for PR253.
The [physical-ordering verification](./docs/verification-runtime-physical-ordering-2026-10-27.md)
records its narrower scope. Separate existing limitations remain #250 (shared
pool Stop isolation), #251 (applied ephemeral endpoints), and #252 (wall-clock
flap metrics), plus [#255](https://github.com/srps/Conduit/issues/255)
(the apparently unreachable legacy recovery-failure notification). Keep these
investigations separate from the behavior-preserving activation.

Earlier evidence remains with its owning slice:
[client/service](./docs/runtime-client-stage1-inventory.md),
[store](./docs/verification-configuration-store-2026-10-25.md),
[session authority](./docs/verification-session-store-authority-2026-10-25.md),
[display/profile measurements](./docs/verification-runtime-display-2026-10-25.md),
[diagnostic drain](./docs/verification-diagnostic-marker-drain-2026-10-26.md), and
[activation decision](./docs/design-runtime-adoption-cut-review.md).
These checks establish neither RuntimeActor isolation nor installed-app acceptance.

The owner's #205 Settings-path check passed in a dev build before 0.5.8 shipped;
installed-build validation remains separate.

1. **Safe dev bundle ([#23](https://github.com/srps/Conduit/issues/23)) [Rel, Sim]**
   — separate identity/name, automatic fake-machine mode, scratch state and
   ad-hoc signing. Reject installation and never share the production path.
   This now has a practical trigger: tandem testing selected a personal signing
   identity and generated repeated prompts, and duplicate bundle IDs made status
   inspection ambiguous. No private-key ACL change is needed.
   Implemented locally with Claude and reviewed by Codex; actual ad-hoc bundle
   launch selected FakeMachine without `--dev`, and the serving process remained
   unchanged ([decision 0016](./docs/decisions/0016-isolated-development-bundle.md)).
   Final gates are recorded in the [checkpoint evidence](./docs/verification-runtime-first-slice-2026-10-24.md).
2. **Sanitizer continuation race ([#118](https://github.com/srps/Conduit/issues/118))
   [Rel, Sim]** — track A remains open; track B shipped in 0.5.5. No
   continuation race fix or new suppression is claimed. Investigate structured
   teardown and the reduced reproducer before substantial actor-isolation work;
   this is a test-confidence workstream, not proof of a production race.

The owner reports stable daily use. The next development effort reduces bugs
found while changing the runtime: typed contracts and model-based verification
accompany host convergence instead of becoming separate projects to finish first.
The owner authorized staged implementation on 2026-10-24 after the final overalls
cross-check. Selected shapes and remaining slice-specific gates are in the
[runtime design](./docs/design-runtime-host-contract.md), with accepted refinements
in decisions [0013](./docs/decisions/0013-runtime-module-isolation.md),
[0014](./docs/decisions/0014-runtime-client-stream.md) and
[0015](./docs/decisions/0015-save-before-apply.md). Claude implements and verifies
each slice on the owner's subscription; Codex reviews the checkpoint. Existing
accepted decisions retain their status.

The path-based VPN migration shipped in 0.5.6 was validated on the owner's
full-tunnel VPN with a pre-release build; split-tunnel and the released build
are still pending
([decision 0011](./docs/decisions/0011-vpn-path-based-socket-sweeps.md)).

Owner acceptance is a separate lane: #99 needs a real KDC-failure recurrence;
#111's normal 0.5.3→0.5.4 preflight/install passed, but negative paths, platform
coverage and key-backup evidence remain. Do not add more happy-path tests merely
to declare these acceptance items closed. See `docs/validation-0.5.3.md`.

## Proposed release scope

**0.6 core — typed runtime contracts and one runtime host.** Stages 1–4 below
are the core scope. Each stage has its own behavioral and compatibility checks;
new runtime behavior adds unit tests and a pm-sim scenario. This is one program,
not a requirement to finish every event or property test before extraction:

1. **One runtime host ([#186](https://github.com/srps/Conduit/issues/186)),
   accepted** ([decision 0031](./docs/decisions/0031-incremental-runtime-development-single-activation.md)).
   **Stage 1 — contracts and persistence, implemented for the shared host.**
   The actual framed `RuntimeClient` now reaches the sole host/workflow/store,
   with typed commands, causal receipts, bounded observation/replay/pages and
   private frozen editor values. [PR254](https://github.com/srps/Conduit/pull/254)
   records integration; the [native-client checkpoint](./docs/verification-runtime-native-client-2026-10-27.md)
   adds saved Start, explicit reload, typed recovery, helper/credential/wake
   integration and host-owned DNS health. AppState adoption and the measured
   production composition remain open. Production v2 socket transport is a later
   milestone; shipped v1 and helper IPC remain compatible.

   Durable edits save before ordinary apply, while Stop/Quit proceed independently
   of failed saves ([0015](./docs/decisions/0015-save-before-apply.md)). One store
   holds a mixed runtime/platform apply until its required inputs verify
   ([0025](./docs/decisions/0025-hold-mixed-configuration-apply.md)). External edits
   refuse saves until explicit reload; reload verifies and reconciles eligible
   changes without discarding another client's draft
   ([0027](./docs/decisions/0027-refuse-external-configuration-edits.md),
   [0032](./docs/decisions/0032-explicit-reload-and-reconcile.md)). No second
   loader, writer, compatibility parser or snapshot registry is selected.

   One canonical state root, OS-backed exclusive lease and fixed writable names
   protect runtime/platform/preferences/journal ownership
   ([0017](./docs/decisions/0017-exclusive-state-directory-writer.md),
   [0020](./docs/decisions/0020-canonical-runtime-writer-root.md),
   [0028](./docs/decisions/0028-fixed-writable-state-filenames.md)). The verified
   store consumes that session and reports persistence, eligibility and physical
   settlement separately. Its shared bounded readers preserve rejected files,
   validate strict syntax/Unicode throughout and retain valid unknown fields and
   first-key-wins behavior. Schema two refuses inexact saves; no schema upgrade
   is needed ([0023](./docs/decisions/0023-exact-schema-two-persistence.md),
   [0024](./docs/decisions/0024-strict-configuration-file-grammar.md)).
   Platform/preferences files use 128 KiB each; the journal is separate
   ([0026](./docs/decisions/0026-bounded-platform-and-preferences-files.md)).

   Private requests and replies use separate 8 MiB caps; ordinary reply/stream
   frames use 64 KiB. Configuration counts/string bounds apply at load/import
   and wire boundaries through one typed resource traversal. Tunnels are native
   local forwards: 64 is the primary performance case, 128 the hard ceiling.
   See [0018](./docs/decisions/0018-private-configuration-request.md),
   [0019](./docs/decisions/0019-private-configuration-frame-budget.md),
   [0021](./docs/decisions/0021-bounded-configuration-at-all-boundaries.md),
   [0022](./docs/decisions/0022-configuration-identity-path-and-host-bounds.md),
   [0030](./docs/decisions/0030-ordinary-runtime-reply-frame-cap.md) and
   [0034](./docs/decisions/0034-private-editor-reply-frame-cap.md).
   Collection observation caps are selected in
   [0038](./docs/decisions/0038-bounded-runtime-collection-capture.md);
   the remaining engineering terms have a coherent measured candidate. Consume the selected ten-second total Quit wait (0039) and one production
   profile in the app switch.

   Earlier source/test counts are historical checkpoints, kept in the linked
   [client inventory](./docs/runtime-client-stage1-inventory.md),
   [store verification](./docs/verification-configuration-store-2026-10-25.md) and
   [session authority verification](./docs/verification-session-store-authority-2026-10-25.md).
   Current acceptance still requires the single AppState switch, RuntimeActor,
   native app checks and applicable installed-machine validation.
2. **Stage 2 — extract the shared host.** Merged in PR #221 (`3d566d8`): `RuntimeHost` now lives
   in ConduitRuntime, first with the daemon as its entry point. The stage-3 activation removes AppState's twin.
   The move preserves MainActor and existing policy, with the daemon fake-machine
   suite and explicit composition dependencies. The owner selected ConduitRuntime
   for the host and an event-only RuntimeEvents target; control values/client/
   codec stay in ConduitShared with ProxyControlBridge mapping. Broad kernel/file
   splitting is not a prerequisite. Client/stream semantics are selected in decision 0014.
3. **Stage 3 — incremental host development, one AppState activation.** Develop
   and verify DNS, tunnels and proxy in reviewable host increments, then switch
   AppState once and delete its replaced runtime/save paths together (0031).
   The activation is implemented on the current branch and under verification; it is not released. AppState retains editor drafts and UI responsibilities. Migrate the event
   families touched by each slice. Bring
   [#183](https://github.com/srps/Conduit/issues/183)'s independent models,
   bounded exhaustive exploration and seeded tests alongside lifecycle,
   subscription and supersession work. Merge twin tests only after parity is
   demonstrated, retaining thin composition/client suites.
4. **Stage 4 — runtime isolation.** Move runtime-owned control work off the main
   actor, meeting [#47](https://github.com/srps/Conduit/issues/47) and
   [#79](https://github.com/srps/Conduit/issues/79)'s remaining acceptance lists.
   `ProxyOrchestrator`, `LifecycleLane` and `RuntimeReconciler` are currently
   main-actor isolated too: moving the host alone does not complete this stage.
   The owner selected one shared RuntimeActor declared in ProxyKernel for the
   full runtime control-owner cluster. UI remains MainActor, NIO stays on its
   loops, and blocking effects stay on PlatformWork. Preserve serialized platform
   operations and bounded total termination. Bound work per turn and prove status/Stop
   responsiveness under observer load; diagnostics cannot gate control progress.

**Stage 5 — strengthen the shared implementation (separately scoped follow-ups).**
A bounded applied-state slice may join 0.6 once defined and validated; the full
list below does not gate the core release:

1. **Applied state per surface ([#194](https://github.com/srps/Conduit/issues/194)
   remainder).** Track desired, durable and actually applied state separately;
   retain pending/failed/superseded work and reconcile the login item at launch.
   Use typed surface outcomes and model-based ordering tests. 0.5.7's retries
   are mitigation, not completion. Full process ownership and durable helper
   leases remain the later production-daemon gate (#48).
   Include save-before-apply, partial durable writes and Stop/Quit exceptions
   from the review draft as explicit behavior changes, not extraction claims.
2. **Scheduling primitive ([#181](https://github.com/srps/Conduit/issues/181)).**
   `HealthChecker` is the first consumer. #207 fences stale completions but does
   not finish non-overlap or fence every pool side effect. Define the primitive
   and its bounded model together; migrate other timers only when touched.
3. **Journal envelope ([#182](https://github.com/srps/Conduit/issues/182)).**
   0.5.7 reads it; 0.6 writes it. The ISO-8601 reader and the 0.1.x DNS
   importer go one release later.
4. **Remaining timeout semantics ([#197](https://github.com/srps/Conduit/issues/197)):** response timeouts and
   the breaker (with the [#184](https://github.com/srps/Conduit/issues/184)
   spike), a health check's first timeout, the prober's slow `CONNECT`, the DNS
   health tick and the launchd residue read.
5. **Liveness-audit follow-ups:** the direct-connect cache
   ([#196](https://github.com/srps/Conduit/issues/196)), PAC invalidation on
   the first path change ([#198](https://github.com/srps/Conduit/issues/198)),
   DNS cache stores across a transport reset
   ([#200](https://github.com/srps/Conduit/issues/200)), launch recovery on a
   timed-out probe ([#201](https://github.com/srps/Conduit/issues/201)) and the
   `VPNStateFuser` latch ([#202](https://github.com/srps/Conduit/issues/202)).
6. **Configuration:** bypass-list validation and CIDR entries
   ([#172](https://github.com/srps/Conduit/issues/172)), and changed defaults
   reaching existing configs ([#173](https://github.com/srps/Conduit/issues/173)).
7. **DNS forwarding in gateway mode
   ([#206](https://github.com/srps/Conduit/issues/206)), deferred by the
   owner.** Since #205 the forwarder binds 127.0.0.1 whatever the listen host,
   so the rule that blocks DNS in gateway mode no longer protects anything.

**Following 0.5.x patches — runtime isolation.** #31 and #81 are patch candidates
when delivered as focused ownership/correctness changes. For #31, pin restart and
draining-connection lifetimes, isolate failure memories and retain process-wide
GSS serialization. Stage #81's private spool ownership/off-loop cleanup separately
from aggregate budgets and replay backpressure, coordinating paths with #82
([decision 0006](./docs/decisions/0006-module-boundaries.md)). Validate
cancellation, failures, concurrent runtimes and slow-origin replay. #163 (the
registration path check off the event loop) fits here too. Any new user-facing
limit or incompatible rejection policy needs an explicit compatibility decision
rather than being hidden in an internal refactor.

**Developer tooling — #23.** Land the separate dev bundle independently; it needs
no production version bump. Ad-hoc signing, a distinct identity, automatic fake
mode and rejection of installation are its acceptance gates.

**Stage 6 — production daemon/client transition (after the shared host).** Next
1–3 remain a separate milestone: exclusive process ownership/readiness, durable
owner-death recovery (#48, with #32/#76), production socket and LaunchAgent
lifecycle, and real user-session Keychain/Kerberos/CFNetwork validation. Sharing
one implementation does not establish one production owner. Preserve later
external settings; retire the AppleScript second-writer path as part of that
authority contract. API approval and the necessary ADRs precede implementation.

**Later product work.** Named
profiles and location switching (#114/#115) and broad kernel splitting (#85,
[decision 0007](./docs/decisions/0007-kernel-file-split-first.md)) follow the
ownership work. Refactor size alone does not require a minor version.

## Now

1. [x] **Network-location-safe recovery ([#110](https://github.com/srps/Conduit/issues/110))** — active-location observation independent of path/VPN signals, stable location/service journal identity, compare-and-write helper v5, inactive-location cleanup, conservative legacy migration, and shared app/daemon reconciliation are implemented with unit and simulator coverage. External edits, renames/deletion, failed reapply, loginwindow cleanup, and stale active-location writes are covered. Shipped in 0.4.0 and validated with helper v5 and the corporate VPN client on macOS 26; macOS 27 was waived for that release and remains untested. Same-location drift repair is bounded against programs that keep rewriting proxy settings ([#116](https://github.com/srps/Conduit/issues/116)). Profile associations ([#114](https://github.com/srps/Conduit/issues/114)) and opt-in switching ([#115](https://github.com/srps/Conduit/issues/115)) follow later. See [`docs/design-network-location-recovery.md`](./docs/design-network-location-recovery.md). [Rel, Obs, UI, Sim]
2. [~] **Secure GitHub Releases updating ([#111](https://github.com/srps/Conduit/issues/111))** — implemented for 0.5: Sparkle 2 in a nested updater process, an EdDSA-signed appcast per release, a project-held release certificate the helper pin admits ([`docs/release-signing.md`](./docs/release-signing.md)), events and simulator coverage. Candidate helper/installation preflight and fixed staging bounds shipped in 0.5.3; owner-installed 0.5.3→0.5.4 logged a successful authenticated preflight and replacement. Owner-installed 0.5.0→0.5.1→0.5.2 updates have logged proxy restoration, relaunch, readiness-before-reapply and resumed authentication on the current macOS 26 Apple Silicon machine (`docs/validation-0.5.3.md`). Remaining: new-preflight/negative-path/platform validation and key-backup evidence. Original scope: manual and opt-in automatic checks, release notes, and explicit Install Update and Restart. Prefer Sparkle 2 with Ed25519-authenticated archives and an embedded verification key. Preserve config/state, preflight helper identity compatibility, restore proxy/DNS before shutdown, and reapply only after readiness. Keep downloads/staging/retries bounded and recover from verification/replacement/launch failures. A brief interruption is acceptable; Developer ID/notarization and zero-downtime handoff do not gate this feature. See [decision 0010](./docs/decisions/0010-self-update.md). [OSS, Rel, Sec, UI, Obs, Sim]
3. [~] **Owner-death recovery and one mutation authority ([#48](https://github.com/srps/Conduit/issues/48))** — app and daemon launch recovery exist. A separate production-daemon milestone after shared-host convergence, not a gate for the 0.6 core extraction. Remaining: exclusive ownership of platform mutations and durable recovery when no replacement runtime starts. Coordinate journal authority, authenticated helper sessions, and any helper-owned leases; preserve later external changes. This is a production daemon-migration gate. [Rel, Sec, Dmn, Sim]
4. [~] **Request-body replay bounds and isolation ([#81](https://github.com/srps/Conduit/issues/81))** — per-body bounded spooling exists. Remaining: runtime-owned private spool storage, aggregate disk/queued-write budgets, replay backpressure tied to downstream completion/writability, off-event-loop cleanup, and structured failure reporting. Cover slow origins, disk failures, cancellation, and concurrent runtimes. [Rel, Sec, Eff, Sim]
5. [~] **Typed event contracts ([#180](https://github.com/srps/Conduit/issues/180))** — begin with #186's client boundary and migrate complete families alongside each host slice. Closed typed payloads derive stable names, categories, fields and human detail; compatibility and redaction cross the same codec/control bridge. Completion of every family is not a prerequisite for host extraction. Status (branch checkpoint): the `lifecycle.*` family is typed through its producers, the file and wire codecs, the bridge and tests; every other family is still legacy, and the catalogue is still hand-maintained. [Obs, Rel, Sim]
6. [~] **Model-based verification ([#183](https://github.com/srps/Conduit/issues/183))** — independent reference models, bounded exhaustive exploration for small finite state spaces, and seeded/shrunk sequences for larger inputs. Begin with lifecycle/subscription ordering; add applied-state and scheduler models when those owners change. Fail on exhausted exploration budgets and show sensitivity to injected bugs. Status: production lifecycle, admission/replay and verified-store models are implemented. The actual adopted-workflow model and host integration remain in progress; broader scheduler/applied-state coverage follows its owning changes. [Rel, Sim]

## Next

Implement the daemon work in the order below
([decision 0002](./docs/decisions/0002-daemon-first-ownership.md)). Named profiles,
demo UI, and advanced metrics do not block the first usable daemon/client slice.

1. [~] **Production control socket** — protocol, bridge, `DaemonClient`, `pmctl`, versioning, metadata, config generation, and stable error codes exist; `pm-proxy` has an isolated server. Wire a bounded server into `ConduitDaemon` for status/start/stop/reload and event access, then upstream tests. Define subscription limits, cancellation, disconnects, and version mismatch behavior. [Dmn, Obs, Rel]
2. [~] **User-session daemon and LaunchAgent lifecycle** — `ConduitDaemon` owns an explicit runtime host, platform managers, credential-store seam, launch recovery, and observable files. Remaining: production install/uninstall/upgrade lifecycle, exclusive-owner startup/readiness, state-dir checks, stale-state repair, restart policy, and crash-restart evidence. Confirm logged-in-user Keychain, Kerberos, and CFNetwork behavior. `pm-proxy` stays side-effect-free. [Dmn, Rel, Sec, Sim]
3. [ ] **App and menu bar adopt the daemon client** — replace app ownership of listeners, monitors, and platform mutations with commands and snapshot/event subscriptions. Bootstrap the LaunchAgent when needed; reconnect after UI restart. Keep any in-process fallback dev-only and remove it from production before 1.0. After the one-runtime-host stages ([decision 0001](./docs/decisions/0001-one-runtime-host.md)), this swaps the in-process host for `DaemonClient`. [Dmn, UI, Rel, Sim]
4. [~] **Reload and observability parity** — section diffing, reload paths, capped `events.ndjson`, atomic `snapshot.json`, and offline diagnostics exist. Verify supported unrelated changes preserve active HTTP/CONNECT/SOCKS5/DNS/tunnel sessions. The shared host now uses the guarded, bounded connection-audit sink with actual-host tests and simulator coverage; its local workflow passes, with local and exact-head hosted checks passed in PR257. [Dmn, Rel, Sec, Obs, Sim]
5. [~] **Release and daily-driver evidence** — Full debug tests, simulator CI, and cold-start/throughput gates exist. ZIP/DMG packaging, optimized PAC checks, and helper upgrade/rollback guidance ship with 0.4.0; packages are Apple Silicon only after 0.4.1. Remaining: representative release-build latency, idle CPU/RSS and sustained-growth baselines, crash/restart/upgrade evidence, human accessibility validation, and a recorded 90-day reliability window for 1.0. [Rel, Eff, UI, OSS]
6. [ ] **Release trust and installation** — Developer ID signing/notarization for app and helper, documented identities/upgrade/rollback behavior, and clean-machine installation validation. Local caller-identity signing and the self-signed release certificate CI signs releases with ([`docs/release-signing.md`](./docs/release-signing.md)) are foundations, not completion of public release trust. [OSS, Sec]
7. [ ] **Configuration and architecture documentation** — document every config field's units/defaults/validation in `docs/configuration.md`; refresh `docs/architecture.md` for the actual target graph, both hosts, and daemon/client migration. Add release guidance covering installation, signing, updates, and rollback. [OSS, Obs]

## Later

### Reliability and security

- [~] **Kerberos KDC recovery ([#99](https://github.com/srps/Conduit/issues/99))** — bounded independent service-ticket acquisition and one parent retry on a freshly confirmed KDC-unreachable initial leg, structured outcomes, retained probe diagnostics, unit tests and `kerberos-kdc-recovery` simulator are implemented. Installed corporate-SSO recurrence and cache-notification validation remain outstanding; see `docs/threat-model.md`. [Rel, Obs, Sim]
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
- [ ] **Enterprise integrations (post-1.0)** — managed preferences ([#174](https://github.com/srps/Conduit/issues/174)), managed update policy, silent `.pkg` deployment, opt-in telemetry export, and helper-binary integrity checks. None delay the daily-driver queue. [Sec, OSS, Obs]

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
