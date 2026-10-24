# 0025: Hold a mixed configuration apply until required inputs verify

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 mixed-apply granularity checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0015](0015-save-before-apply.md) separates durable intent from runtime outcome.
[0018](0018-private-configuration-request.md) requires authoritative receipts for
an effect's runtime/platform inputs and keeps UI preferences independent. It does
not define whether one mixed update is split into several apply groups.

The current RuntimeReconciler advances runtime and platform baselines in one
pass. Today's app can reconcile after the runtime save succeeds even when the
platform save fails. The reviewed [store workflow](../design-runtime-store-workflow.md)
compared holding that combined apply with introducing independent effect groups,
per-group baselines and partial-repair logic now. After reviewing the effort
comparison, the owner selected the recommendation to hold the mixed apply in
[#186](https://github.com/srps/Conduit/issues/186). Claude reviewed the architecture
through the owner's claude.ai Max subscription; no API authentication was used.

## Decision

Treat one ordinary update that changes both runtime and platform-management
settings as one apply unit for this release. Do not apply its new runtime or
platform values until every required component has verified persistence and the
combined input passes its runtime eligibility gates. Keep the prior applied
configuration while an input is failed or unknown. Recheck current intent,
incarnation and Stop/shutdown fences after suspension before admission/apply.

Report each component's actual persistence result separately. A runtime file that
verified remains saved even when the platform write fails; do not call it rolled
back, fully committed or applied. Retain the saved intent, expose the partial
state and allow bounded repair through the sole writer. Crash recovery revalidates
the actual durable set; this choice adds no multi-file transaction.

A runtime-only change uses the receipts its effects require, including matching
previously verified unchanged platform input where needed. It does not require
rewriting an unchanged file. A failed UI preference write still cannot veto an
independently verified runtime update. Preserve saved repair drafts and existing
non-blocking validation classifications; this decision selects apply granularity,
not a stricter persistence or proxy-start policy.

Explicit Stop and Quit retain their selected exceptions: fence/cleanup admission
never waits for saving, a late save cannot clear the fence, and Quit does not
persist a disable. This decision selects no new listener-handoff behavior.

Keep typed component/phase outcomes and the store/client boundary usable by later
effect-group planning. Do not introduce a second writer, AppState coordinator or
snapshot registry to implement this choice.

## Alternatives

- **Independent effect groups now:** apply effects whose complete input set
  verifies. Offers more partial progress, but needs an explicit dependency plan,
  separate applied baselines, partial settlement/repair and expanded models and
  harness integration. Much of that is useful future #194 work; it is not the
  smaller first store/client slice. Not selected for this release.
- **Apply runtime whenever its file saves:** retains today's failure behavior but
  can apply part of a mixed requested destination without verified matching
  platform intent. Does not satisfy the selected combined-unit policy.
- **Roll back the runtime file on platform failure:** adds another fallible write
  and cannot make several file replacements atomic. Not selected.

## Consequences

The mixed-update failure path can make less immediate progress than independent
apply groups, but has one coherent input and baseline over today's reconciler.
Persistence remains honestly partial. The store, receipts and transport are
reusable when apply planning is refined later; replacing the combined gate and
adding per-group baselines still needs deliberate implementation and verification.

## Invariants and verification

Drive the production store/workflow with runtime success plus platform failure
and unknown outcomes. Assert unchanged applied baselines, exact component results,
no false rollback and no platform side effect using an unverified value. Cover
later repair, newer intent supersession, invalid-but-saveable drafts, unchanged
verified components, independent preference failure, Stop during save and Quit.

Use an independent bounded model and injected adapter faults for applying before
all required receipts, accepting stale completion and clearing Stop. Retain
fake-machine and headless scenario evidence. Unit/model checks do not establish
real-machine cleanup or power-loss durability.

## Implementation evidence

None yet. The current app still has the earlier mixed-save behavior. The shared
store/client workflow and its apply gate remain planned.

## Open questions

Revisit effect groups for demonstrated user benefit from independent progress or
when #194's per-surface applied-state ownership is ready. Specify the dependency
map, baseline migration, partial outcomes and recovery before changing this rule.
Listener handoff, full #194 scope and measured total shutdown remain separate gates.
