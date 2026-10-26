# Interactive editor admission: owner review

Status: proposed, not selected or implemented. This supplements the
[editor contract](design-runtime-editor-contract-review.md); it changes no accepted record.
Official subscription-backed Claude Code reviewed the alternatives. The existing app has one local
client; its behavior alone does not decide races between future app/CLI clients.

## Decision 1: one stale lifecycle slot in a combined update

A frozen private request carries one runtime/platform input and three explicit module intents.
For example, it asks to start the proxy and apply DNS settings at observed DNS revision 7. Before
admission, another client stops DNS, advancing its revision to 8. The file baselines are still current.

**A — validate the request as one unit (Codex and Claude recommendation).** Reserve
capacity and check every actionable Start/apply-while-running revision in the owner admission turn.
If any is stale, reject the request before persistence or intent changes. Keep the client's draft and
show the stale lifecycle result. A new observation does not authorize silently replaying a Start;
the user explicitly submits again after reviewing the current state. Save-only slots have no lifecycle
revision to check.

After admission, Stop always takes its independent path and fences its own module immediately.
Relevant intent includes both actionable module revisions and merged persisted lifecycle values
(today DNS `forwarderEnabled`), even for a save-only DNS slot. If it invalidates an unstarted write
or the remaining shared apply, hold or
supersede the remaining combined operation. Preserve any verified saves and report exactly which
components persisted and which actions did not occur. Do not re-stage in a retry loop in this release.
This may prevent a pending proxy Start from completing when DNS changes during its shared update;
it does not stop an already-running proxy. A platform file already saved before a now-stale runtime
write remains a reported partial save; the remaining runtime write must not begin from stale intent.
Started physical writes can finish and require honest
read-back/Stop-save results; neither cancellation nor a fence is physical rollback.

Benefits: one clear causality rule, one applied input, exact revision semantics, and bounded work.
Cost: an unrelated module action, including the same client toggling DNS during its save, can make a
combined edit require review/resubmission. Ordinary snapshots must expose the bounded per-module
revisions so this does not require reading a full private configuration just to learn lifecycle changes.
Rejected/held Starts are never automatically retried. This proposal selects no automatic retry loop for
other holds; ordinary new autosaves still follow the selected baseline-conflict rules. Values already
saved before a later fence remain durable pending intent, as selected in save-before-apply.

**B — save and make partial lifecycle progress (alternative).** Accept the
request, save values with current lifecycle intent merged, and report stale slots separately. Current
module actions can progress. Keep one shared configuration input; define when the whole input must
hold if a running module has a stale slot. DNS intent changes during staging may require bounded
re-staging to preserve an unaffected proxy Start.

Benefit: fewer rejected edits and more progress under concurrent clients. Cost: more lifecycle/persistence
combinations, additional bounded work/capacity policy, and subtler receipts. This must not quietly weaken
exact lifecycle revisions or introduce separate per-module applied configuration baselines.

A held or failed Start must leave no enabled authorization that reload, autosave, VPN or repair can
activate later. Retire its pending authorization while preserving the prior Stop fence and any newer
Start/Stop; only a new explicit Start may authorize activation. A pending Start need not clear its fence
before verified persistence. This applies under either choice.

Both choices retain the sole writer, private value boundary, independent Stop capacity, mixed runtime/
platform verification gate and current frozen valid draft. Neither changes save-only into Start.
Revisit partial progress when actual multi-client use demonstrates enough benefit to justify it.

## Decision 2: preserve proxy-to-DNS dependent startup

Unselected and separate from decision 1. Today proxy Start/Restart may start enabled DNS. Under the
approved private API, a DNS save-only slot cannot enable stopped DNS; ordinary proxy Restart has no
DNS slot. Options are explicit companion DNS Start, a separately named host dependent-activation
operation, or removing that coupling. Preserve the approved meanings while comparing compatibility,
Stop races and failure reporting. The daemon whole-host CLI facade remains separate.

## Work that does not depend on these selections

Finish the byte-exact runtime correction and verification. The shared host's per-module Stop ownership,
ordinary status and private read can be developed for actual-adapter measurements without choosing
private-update admission. Production custody/deadline limits and total Quit budget still require the
measured profile decision. No AppState switch or private update implementation is authorized by this draft.
