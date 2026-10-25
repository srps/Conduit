# 0032: Explicit configuration reload adopts and reconciles eligible changes

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186: selected “Reload and reconcile eligible changes (Recommended)”)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0027](0027-refuse-external-configuration-edits.md) refuses ordinary saves over
changed files until explicit reload/review. The shared-host workflow now needs
the meaning of that explicit action. The existing tested host reload reads via
a migration-capable loader and reconciles; it has no production caller. The daemon
has no reload endpoint or SIGHUP handler. The app has startup/import paths but no
explicit disk-reload action. The diagnostic pm-proxy has its own reload behavior.
The owner reviewed the alternatives in [#186](https://github.com/srps/Conduit/issues/186)
and selected reload-and-reconcile.

## Decision

An explicit shared-host reload observes and verifies bounded disk inputs through
the sole configuration store, adopts that observation with matching baselines,
and reconciles eligible effects in the same deliberate action. Reload itself
writes no migration output or missing defaults. Startup migration finishes before
store baselines are adopted. Preserve the existing loader's accepted and refused
missing-file combinations. This replaces the old test-only host reload's blanket
missing-runtime refusal; explicit --config startup keeps its existing refusal.

Adopt supported repair drafts for editing while holding ineligible apply. Permitted
absence remains uncommitted; required inputs must verify through the normal commit
workflow before apply. A later explicit Start commits required defaults first.
Malformed or unreadable inputs refuse the whole observation: keep the last known
values without new baseline authority. Validation-only repair problems are adopted.
Neither refusal nor a repair draft can authorize ineligible apply or overwrite originals.
Eligible runtime apply requires verified required inputs, no start-blocking problem,
current intent and an open lifecycle fence.
Runtime/platform changes keep the whole mixed-input gate under 0025; preferences
retain their selected independence.

Reload never clears an accepted Stop fence or restores a stale enabled flag.
Only newer explicit Start/Enable can re-enable that lifecycle. Check current intent,
incarnation and shutdown fences around suspension; late reload completion cannot
overtake newer intent. Another client's reload cannot discard a client's dirty
draft or refresh its originally observed save tokens. A changed observation can
make those original tokens stale, so the subsequent save refuses rather than
retokenizing the draft.

A normal private editor read captures current in-memory values and their matching
baselines in one owner turn, with no disk read and no apply. Disk reload and local
draft replacement remain explicit actions. Preserve selected lifecycle-intent merge
under 0015 and relevant-component durable preconditions under 0018/0027. No implicit
editor/disk merge, file watcher, snapshot registry or parallel writer follows.

The app's separate import action and pm-proxy's v1 reload, read-only input and CLI
override behavior are unchanged. This decision does not add a daemon endpoint or
select a private editor reply ceiling or remaining service-profile defaults.

## Alternatives

- **Reload for review, then separate Apply:** adds an inspection step before
  runtime effects, but requires another action and durable-versus-running UI state.
  Not selected; the explicit reload action already expresses the owner's intent
  to adopt disk changes and apply those eligible under the existing fences.
- **Implicit reload on editor read or conflict:** would silently change runtime
  behavior or refresh stale draft tokens. Incompatible with explicit conflict
  recovery and preservation of client-owned drafts.
- **Reload through migration/save:** risks hidden writes during an observation
  operation and bypassing the sole store's baselines. Keep startup migration
  separate and use the existing normal commit path for defaults or repairs.

## Consequences

Label the action to make its runtime effects clear. Verification and runtime
eligibility remain separate, so disk and applied state may differ after a repair
or partial observation. Explicit results must explain held/refused changes.
This is not multi-file atomicity or exclusion of a non-cooperating editor racing
after verification. The one shared workflow must retain corrective work when
newer intent supersedes a started physical operation.

## Invariants and verification

Before adoption, add typed outcomes/events, focused tests, an independent bounded
production-workflow model and pm-sim coverage for valid/invalid/missing inputs,
external-edit conflicts, Stop during a read, newer edits/reloads, partial component
observations and retained dirty drafts. Prove no reload/default/migration write
occurs merely due to reload, and no stale completion authorizes apply. Preserve
required-default commits, mixed-input holds and the same writer authority path.

## Implementation evidence

None yet. The reviewed proposal is [design-runtime-reload-review.md](../design-runtime-reload-review.md).
Session/store authority preparation is merged in [PR #242](https://github.com/srps/Conduit/pull/242);
it does not implement the adopted reload workflow.

Does not prove: installed-app behavior, real VPN/auth/PAC operation or daemon handoff.

## Open questions

Private editor reply sizing and remaining service-profile defaults remain separate
owner choices. This record selects no values for them.
