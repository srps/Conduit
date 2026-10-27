# Private editor and client integration

Status: the actual shared-host/client integration is implemented locally and under
review, 2026-10-27. AppState still owns its old runtime and writers until the one
activation selected in [0031](decisions/0031-incremental-runtime-development-single-activation.md).
The [current checkpoint](verification-runtime-client-owner-2026-10-27.md) owns
verification status. This document describes the selected boundaries; it is not
a second execution queue or a release-readiness claim.

## One owner and one persistence path

`RuntimeHost` owns intent, lifecycle, reconciliation and its private workflow/store.
The service owns admission/lookup/observation mechanics and delegates intent to
that host. AppState becomes the draft, presentation and administration client.
Use the actual framed async boundary in memory now and over a later daemon
transport. No live managers, direct in-process mutation shortcut, second writer,
configuration registry or AppState save coordinator crosses that boundary.

The host, service and workflow use one host incarnation. The store independently
mints component baselines: exact namespace UUID, runtime/platform/preferences
component and UInt64 version. A baseline is persistence authority only; it is
not a config-view, presentation or lifecycle revision. Keep the existing v1
generation's accepted-view meaning.

Normal editor reads capture values, component authority and module intents in one
owner turn, without disk I/O. Each component is verified, absent with a baseline,
or retained for display with a closed reason and no authority. The store records
those reasons at its existing latch sites. Explicit Reload configuration reads
and verifies disk, then reconciles eligible changes (0032). An observation or
another client's reload cannot retokenize or replace a dirty draft.

## Private operations and safe receipts

Configuration values remain non-Codable, explicitly encoded and redacted in
reflection. Neutral handles and safe write facts may be Codable. Private URLs
and frozen bodies never enter ordinary status, logs, aliases or outcome lookup.
Kernel mapping belongs in ProxyControlBridge; the scanner and typed boundary
reuse the selected resource limits.

| Operation | Preconditions and effect |
| --- | --- |
| Private read | Correlated host incarnation; coherent memory observation only. |
| Runtime/platform update | Full frozen values, exact component baselines and one explicit intent per module; the sole store saves before eligible apply. |
| Preferences update | Its own baseline and private values; no lifecycle admission or runtime apply. |
| Launch-at-login administration | Safe Boolean command and exact platform baseline; writes only that stored flag through the same store. App-side login-item administration remains app-side. |
| Reload | Deliberate disk observation and eligible reconciliation; retains Stop fences and client-owned drafts. |
| Stop | Fences immediately, independently of private capacity or save failure; owed DNS-disable persistence uses the same store. |
| Quit | Fences immediately, then permits only its declared final save request IDs under one total deadline; no apply or exit-disable. |

Runtime/platform updates preserve the current stored launch-at-login flag inside
the write claim. Ordinary saves merge current lifecycle intent rather than letting
a stale draft re-enable a stopped module. Preferences failures do not veto
independently verified runtime work. A mixed runtime/platform apply waits until
all its required inputs verify (0025); this release does not introduce separate
effect groups or applied baselines.

A causal receipt names the submitted request, host, per-component write facts and
exact new baselines, plus actual member/conditional outcomes when requested. It
never reports listener success merely because the runtime took an input. DNS
Stop's disable write also names the prior baseline: its own client may advance
only a draft still holding that baseline and preserve the false DNS intent. An
intervening client's write still conflicts. Later local edits survive any receipt;
no receipt may mark a newer draft clean.

## Lifecycle intent

Each private module slot expresses save-only, apply-while-running at the observed
revision, or explicit Start at that revision. Only a current explicit Start can
clear its module's Stop fence. DNS may instead carry a conditional Start beside
proxy Start (0036): check the client-observed DNS revision, use the same verified
pair, and start only already-enabled, unfenced DNS that is down. It writes no
enable and clears no fence. Report the companion separately; DNS failure leaves
an already-started proxy running. Menu Restart carries no unsaved Settings values.

Check all actionable revisions as one request before intent or persistence changes
(0035). A stale request is refused whole, preserving its draft. After admission,
Stop remains immediate; it invalidates unstarted writes and remaining apply while
already-saved facts remain honest. A held Start is never automatically retried.
Saved commands capture their input once at preparation capacity (0037); private
Starts keep their submitted frozen values. Neither follows a newer replacement
through a rebind loop.

Call-site review found that native Starts are saved-value menu, Overview and
shortcut actions; Settings never combines Start with apply. Mixed private
Start-plus-apply remains explicitly refused for this release. Ordinary saved
Start and the remaining helper/credential/wake integration still precede
activation; none may introduce a direct-host UI fallback.

Legacy app launch flags `--port`, `--no-system-proxy` and `--no-env` change the
session's in-memory draft; they reach disk with a later save, including some
lifecycle saves. Launch alone does not persist them. At activation, preserve their
effect through one existing private save-only update after host open/read, before
exposing runtime controls; failed persistence holds that startup intent. This
intentionally persists explicit launch overrides up front, including a session
with no later edit or Start. This needs no override layer or second loader. App-only events
remain in their bounded app-local log and `proxy.log`, as today; the host owns
`events.ndjson`. These retain existing behavior without a new event-ingress API.

## Capacity and termination

The composition reserves one private transfer before mapping or encoding. An
update also reserves one frozen input through physical operation cleanup. Both
private update kinds share those bounds. Ordinary Stop/status have separate
capacity. Request/reply encoding and mapping run off the owner and PlatformWork;
an owner turn captures COW values or admits intent.

Logical deadlines and cancellation do not free physically held work. Private
exchanges use the same wait gate and ticket parts as ordinary transport. The
Quit client's final saves wait for physical private capacity, within the same
total deadline, without polling or resending updates. The capacity wait itself
is bounded through timer cleanup.

Quit reserves pre-minted configuration and preference request IDs; unrelated
autosaves cannot spend those parts or evict its admission alias. The client
flushes the latest valid local values, or its clean runtime value beside valid
sidecar edits, under the exact baselines it held. Invalid runtime drafts cannot
veto valid preferences or Quit. Already-started writes may finish, and the host
retains root authority through actual cleanup. Preserve an owed pre-Quit Stop
save; quitting itself writes no disable.

## Limits, compatibility and verification

Ordinary v2 replies/stream frames are capped at 64 KiB (0030). Complete private
requests and editor replies are separately capped at 8 MiB (0021/0034). Apply
bounded reads, strict syntax/Unicode, selected domain ceilings and schema-two
exact persistence at their existing boundaries. New snapshot fields require
renewed complete-frame sizing. Keep v1 and installed helper IPC compatible;
additive unshipped v2 cases do not require a legacy compatibility-mode matrix.

The remaining production profile comes from actual client custody/work/latency
measurements, including final Quit and helper holds. Experimental values are not
shipping defaults. Encoded reservations and whole-probe RSS are different kinds
of evidence. The [checkpoint](verification-runtime-client-owner-2026-10-27.md)
records review corrections, focused tests/models, executed guard checks and their
limits. Earlier [reply mirror](experiments/private-editor-reply/README.md) and
[headless codec](experiments/private-editor-codec/README.md) experiments retain
their narrower historical scope.

Complete coherent-source review and all workflow/hosted checks before merging.
After client/profile readiness, activate AppState once and delete its replaced
runtime/reconciler/observer/save paths together; then move the entire control
cluster to RuntimeActor. Production daemon sockets, listener handoff and broader
applied-state expansion remain separately scoped.
