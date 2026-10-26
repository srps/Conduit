# Explicit configuration reload: owner policy review

Status: selected by the owner, 2026-10-25: **reload and reconcile eligible changes**.
Decision [0032](decisions/0032-explicit-reload-and-reconcile.md) records the choice;
headless host/workflow implementation is partial. Private editor/client integration
and AppState activation remain open. This review preserves the alternatives and
paths observed at selection. The session/store capability slice merged independently in PR #242.

## Selected policy

Recommend **explicit reload and reconcile**: observe and verify disk inputs
through the sole store, adopt that observation and its matching baselines, then
reconcile only eligible runtime changes through the same workflow. The alternative
adopts the disk view for review while leaving runtime apply to a separate command.
Both retain save-before-apply, mixed-input hold and Stop/Quit policies.

| Choice | Benefit | Cost and implication |
| --- | --- | --- |
| **Reload and reconcile (recommended)** | One deliberate action adopts disk changes and applies eligible effects. Matches the existing host method's intent and pm-proxy's familiar reload behavior. | The action may change listeners/routing/platform effects; label it explicitly. Supported repair drafts remain editable; permitted absent inputs stay uncommitted and held from apply. |
| **Reload for review only** | Provides an inspection step before runtime effects. | Requires a separate apply action and clear durable-versus-running presentation. The future shared-host reload command would have different behavior from its existing tested method. |

## Paths observed at selection

`RuntimeHost.reloadConfiguration` reads through `loadAllMigrating`, rejects
start-blocking values and reconciles/drains effects. `loadAllMigrating` can write
migration output today; the proposed read-only reload deliberately removes those
writes while keeping startup migration. The current method also refuses a missing
runtime file (`allowMissing: false`). It currently has no production
caller; the daemon entry point handles termination signals and serves no control
socket. Do not describe ConduitDaemon as having a current SIGHUP reload API.
The app has startup and import paths, but no explicit disk-reload action. Import
currently replaces the draft, saves and reconciles; this proposal does not change
that separate file-import action or silently add a new draft-discard flow.
`pm-proxy` has its own v1 control/SIGHUP reload and CLI-override handling. Its
read-only input and existing compatibility remain unchanged by this proposal.

## Examples under the recommendation

| Situation | Result |
| --- | --- |
| Running A; valid external file B | Verify and adopt B with its baselines, then reconcile eligible effects. |
| B is a representable repair draft with a start-blocking port | Adopt B for repair, report held apply and keep the prior applied baseline. Do not silently run B. |
| A required file is malformed or unreadable | Report the closed refusal; do not authorize a new apply or overwrite the original. |
| The loader permits a required file to be absent | Report absent/uncommitted defaults or fallback; hold apply until the normal commit workflow verifies required inputs. A later Start commits required defaults first. Missing-file combinations the loader already refuses stay refused. |
| This session already accepted Stop | Reload cannot clear that fence or restore a stale enabled flag. Only a newer explicit Start/Enable may do so. |
| Another client reloads while an editor has a dirty draft | Keep that draft and its originally observed tokens. A stale save refuses; replacing a local draft remains explicit reload/review UI policy. |

A normal **private editor read** is different: it captures current in-memory
values and matching baselines in one owner turn, with no disk read and no apply.
It is not an implicit reload, nor a way to refresh stale tokens before overwriting.
Adopting permitted absence and holding apply follows the store contract and differs
from the current tested host method; pm-proxy retains its existing missing-file
refusal. No loader/startup acceptance rule changes through this policy.

## Constraints under either choice

Use the existing bounded reader/parser/store and exact verified values. Reload is
observation, not a hidden persistence operation: no new migration/default write
merely because reload ran. Startup migration completes before store baselines
are adopted. Preserve the original files on refusal. Keep storage acceptance
separate from runtime eligibility; supported repair drafts remain editable.

One whole mixed runtime/platform gate remains. Preferences retain their selected
independence. Check incarnation, current intent and Stop/shutdown fences around
suspension. A late reload completion cannot supersede newer explicit intent.
No snapshot registry, parallel writer, second parser, file watcher or implicit
merge of editor and disk values is selected. Lifecycle-intent merge remains
selected under 0015. Relevant component preconditions stay distinct from unrelated
preferences and runtime-view revisions.

The owner's choice is recorded in 0032. Before adoption, cover valid/invalid/missing
inputs, external-edit conflicts, Stop during read, newer edits/reloads, partial
component observations and retained dirty drafts with typed events, focused tests,
an independent bounded model and pm-sim. This policy does not select private
editor-reply budgets or any remaining service-profile default.
