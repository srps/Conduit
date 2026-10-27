# AppState adoption: integration-cut review

Status: **activation sequence selected by the owner**, 2026-10-25, recorded in
[0031](decisions/0031-incremental-runtime-development-single-activation.md).
Implementation is partial: the consumed session/store capability is merged;
the headless host/workflow now consumes the store and selected reload policy,
with its [verification checkpoint](verification-runtime-workflow-2026-10-26.md).
Actual host/client integration is merged in PR254; the
[native-client completion](verification-runtime-native-client-2026-10-27.md)
records saved commands, helper/credential/wake integration, actual event delivery
and shutdown, plus explicit reload and DNS health. AppState activation remains open. Reply/stream frames are selected
at 64 KiB in 0030. The measured candidate profile remains experimental; select its
remaining values after complete actual-host integration checks. Claude Code
and Codex source-review findings are recorded below; Claude used the owner's
claude.ai subscription.

## Selected activation sequence

The owner selected implementing and verifying DNS, tunnels and proxy incrementally
in the shared host, then **activating the AppState-to-RuntimeClient switch once**.
Delete the replaced AppState runtime/writer paths in that integration change.
Decision 0031 replaces 0001/0013's separate lifecycle activation steps while
carrying forward their shared-runtime, module and isolation direction.

The unselected alternative keeps separate active DNS, tunnel and proxy switches. It remains
feasible in principle, but needs temporary private capability/execution bridges
and coordination until each remaining lifecycle moves. It is not categorically
forbidden by the client boundary: an internal executor behind that boundary is
different from exposing a live manager or policy-less wire command to clients.
This is our interpretation of 0001's no-shortcut invariant, not an already
approved temporary API: a separate-switch design must demonstrate that all
commands still traverse the client and one authority, or return any named
exception to the owner before implementation.

| Choice | Benefit | Cost and risk |
| --- | --- | --- |
| **One final AppState activation (selected)** | One orchestrator, intent/store owner and reconciler baseline at activation; no transitional runtime escape route to maintain. Aligns with the later daemon transport swap. | Larger final integration review and broader acceptance. All lifecycles and UI flows must pass before activation. |
| **Separate lifecycle activations** | Smaller user-visible integration increments, retaining the original sequence. | Temporary narrow drivers/capabilities and extra deletion/parity checks; shared DNS/config/reconciler paths still need coordination at the first switch. |

This is a choice about the **activation boundary**, not permission to develop an
unverified wholesale rewrite. Under the recommendation, reviewable implementation
commits and fake-machine parity checks still progress DNS→tunnels→proxy. Keep the
current isolation during convergence; moving the whole control cluster to
RuntimeActor remains its own selected later step. Do not install an interim build
or replace the serving app to test either option.

## Why the current boundaries matter

- AppState and RuntimeHost each construct an orchestrator today, in their separate
  app/daemon compositions. Adopting the host must result in **one instance in the
  app**, rather than instantiating both existing compositions together.
- AppState proxy startup calls its DNS lifecycle and split-DNS repair. Kernel
  proxy startup itself does not start DNS. Kernel DNS startup/stop also owns the
  intercept listener, which must move with DNS.
- DNS managers participate in recovery, retries/reapply and Quit cleanup. Their
  serialization is per instance; two manager objects are not one authority.
- RuntimeReconciler serializes passes and maintains one applied baseline. The
  selected whole mixed-input verification gate must remain one gate, even while
  physical effects are developed or migrated in smaller pieces.
- The first actual adoption also replaces all three direct configuration writers
  with the sibling ConduitRuntime store/workflow. A writer-only AppState
  coordinator, a second save route or a path re-read after verification would
  defer the ownership work we selected.

Source inventory: `AppState.startProxy` and DNS lifecycle/reapply/recovery/
termination paths; `ProxyOrchestrator.startDNS/stopDNS/startProxy`;
`RuntimeReconciler.reconcile`; `SystemDNSManager.serialized`; the existing
`ConfigurationStore` and `StateRootSession`. The staged design details still need
to name each moved/remaining responsibility if the owner later revisits the activation sequence.

## Invariants under either choice

One semantic store/workflow remains in ConduitRuntime, sibling to RuntimeHost.
StateRootSession already retains its private lease. Adoption uses a narrow
component-scoped replacement seam delegating to the existing verified physical
primitive. That seam is now consumed by the store; its raw-plan/raw-lease
constructor is removed. The shared host now consumes that store/workflow; AppState adoption remains open.
The lease stays private and no registry is added.
The host consumes the exact verified immutable input. AppState keeps editor drafts,
presentation, notifications and app administration.

UI commands for migrated responsibilities use the actual framed RuntimeClient.
No live manager crosses that client, no direct in-process command shortcut is
added, and no production composition is added without a real caller. A temporary
internal driver, if selected, owns only its named remaining effects and has
explicit deletion gates; it cannot become another intent or persistence owner.

The selected save-before-apply, mixed-apply hold and Stop/Quit policies remain
unchanged. Implementing them changes current AppState behavior: DNS enable today
applies before its save. That ordering must change with explicit parity/policy
tests; this is not a wholly behavior-preserving activation.
Stop fences before saving; Quit drains under one total budget without persisting
a disable merely to exit. Started physical writes retain authority until they
quiesce; a newer intent can supersede unstarted work but cannot undo a started
write. Unresolved saves never authorize a new Start from last-applied values.

## Client/workflow shape to carry forward

These are refinements of selected semantics, not a new registry or independently
approved final spelling:

- One private frozen configuration request and one workflow request ID span
  persistence, runtime admission and settlement. Internal phase IDs stay distinct.
  Private values stay out of ordinary status/events/outcome lookup.
- Use a closed explicit intent: ordinary reconcile versus enable of one module
  with the observed lifecycle revision. Ordinary edits may reconcile eligible
  changes but cannot clear a session Stop. Avoid optional fields that permit an
  enable with no lifecycle precondition.
- Start without new values names the host's current verified required input,
  with relevant config/platform, intent and lifecycle freshness checks. Required
  absent/default inputs must be committed through the same workflow first.
- Expected incarnation/revisions/owner generation remain workflow preconditions;
  the store echoing a context does not make the fields optional correlation.
  Store-internal file baseline versions are not machine-effect revisions or
  caller-minted receipts. Capture the authoritative generation before suspension
  and recheck it and Stop/shutdown fences before apply. The implemented stamp
  carries the workflow lifecycle revision and each module's revision; the private
  observation carries exact component baselines. Reload reconciliation also
  checks the host's accepted-view generation, using the same predicate for its
  remaining effects and typed result. The native-client checkpoint verifies
  these paths. Future observation fields still need bounded framing checks
  under 0030; presentation revisions never grant mutation authority.
- Ordinary saves merge current explicit lifecycle intent before staging. Keep
  save, admission, apply and physical quiescence facts separate, with closed safe
  result types and no configuration plaintext in outcomes.

The implementation/API review must verify startup migration completes before
store baselines are adopted, initial editor/host values come from the same
observation, private read/edit observation supplies the preconditions, and all
new snapshot/AppliedState metadata stays bounded within 0030. Explicit disk reload now selects reload-and-reconcile in
[0032](decisions/0032-explicit-reload-and-reconcile.md); normal private editor reads
remain in-memory observations without apply.

## Required verification before activation

Run shared-host/fake-machine parity and model witnesses for every migrated
lifecycle, save/Stop races, partial/unknown writes, stale generations, external
edits, callback ordering, cleanup and total shutdown. Inventory and delete every
replaced writer/reconciler/lifecycle path; prove no overlapping effects. Check
actual framed client/subscription behavior and bounded page work under pressure.
Run the complete repository workflow, then isolated native app validation.
Real VPN/Kerberos or installed-app acceptance remains separate where needed.

Decision 0031 records the selected replacement sequence. No production profile
or activation code is implemented by this checkpoint. Workflow/API and profile
review still precede their affected implementation; the selected sequence itself
is no longer an owner gate.

## Source-review findings (2026-10-25)

Codex and subscription-backed Claude Code reviewed the inventory and alternatives.
Claude confirmed the shared DNS/intercept/repair coupling, per-instance
serialization, reconciler baseline and three writer paths. Review corrections
incorporated here distinguish the proposed session seam from existing code and
the selected persistence policy from current DNS behavior. The temporary-driver
interpretation of 0001 and the still-incomplete intent-generation observation API
are explicitly qualified. Both reviewers recommend incremental verification with
one final activation, subsequently selected by the owner in #186. No claim of
implemented migration or complete API specification follows from this review.


## App activation boundary reviewed on 2026-10-27

Subscription-backed Claude source review found the current command and private
editor APIs cover the actions used by the app. Keep one composition and one
opening phase: migrate under the held session, open RuntimeHost, create its
clients, obtain the editor baselines, commit explicit launch overrides through the
existing save-only request, then enable editing and lifecycle controls. A refused
open follows the existing journal recovery path and configuration banner. Never
construct a second orchestrator or let a default draft overwrite unread files.

| Responsibility | After the one switch |
| --- | --- |
| Runtime, lifecycle, reconciliation, recovery and persistence | RuntimeHost and its sole workflow/store; delete the corresponding AppState managers, lanes, timers, observers, callbacks and direct saves. |
| Drafts and editing | App-owned debounce/commit hold; private requests carry frozen values and exact baselines. Only the matching own receipt rebases an unchanged draft. |
| Runtime presentation | Consume wire snapshots and revision-qualified collection pages. Clear current claims when observation is lost; never derive persistence authority from status. |
| Helper installation and credential enrollment | App-owned adapters, followed by admitted refresh/invalidation commands. Retry only a known-unadmitted notice; recover ambiguous admission by lookup. |
| PAC preview, updates, windows and notifications | App-owned. Preview uses the draft and its own evaluator. Typed recovery events classify generic notifications; a snapshot is not causally paired with an event. |
| Quit | AppKit terminate-later, the existing client Quit routine and its final frozen saves; no synchronous owner wait or second teardown. |

Production effects preserve the app's PAC-fetch compatibility and workspace wake
adapter. The daemon remains inert for workspace wake. Do not call the daemon's
ready-file entry point from the app. Host diagnostics own events.ndjson and
snapshot.json; app-only events stay in the bounded app log.

DNS health presentation must survive observation gaps without app-side runtime
logic: retain one host-owned liveness observation, clear it on recovery/lifecycle
changes and project it through the existing bounded dnsError while DNS runs and
has no kernel error. Notifications remain best effort. Do not reproduce the
legacy presentation override that could mark a failed kernel module running.
This host-owned observation and its stale-run guards are implemented in the
native-client checkpoint; AppState presentation adoption remains open.

Before deleting an AppState test, identify its existing host witness, retain it as
a thin client-flow test, add missing host coverage first, or explain why it is
obsolete. Similar test names alone do not establish duplicate coverage. Update
harness/dev compositions and their instructions in the same switch.

Compatibility differences are explicit: asynchronous Quit; host diagnostic files
in the app state root; and launch overrides persisted before use rather than on a
later unrelated save. No new schema or helper/v1 protocol break is required.
