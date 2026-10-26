# Interactive editor admission: owner review

Status: decision 1 selected by the owner on 2026-10-26 ([0035](decisions/0035-whole-request-lifecycle-validation.md));
implementation is planned. Decision 2 remains proposed. This supplements the
[editor contract](design-runtime-editor-contract-review.md).
Official subscription-backed Claude Code reviewed the alternatives. The existing app has one local
client; its behavior alone does not decide races between future app/CLI clients.

## Decision 1: one stale lifecycle slot in a combined update

A frozen private request carries one runtime/platform input and three explicit module intents.
For example, it asks to start the proxy and apply DNS settings at observed DNS revision 7. Before
admission, another client stops DNS, advancing its revision to 8. The file baselines are still current.

**A — validate the request as one unit (selected).** Reserve
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
DNS slot. The daemon whole-host CLI facade remains separate.

**Proposed recommendation — explicit conditional activation owned by the host (Claude reviewed).**
Preserve the convenience through a separately named, bounded action: bring DNS up only if its current
host-held intent is already enabled and unfenced. The client explicitly includes this action with proxy
Start or Restart; it never changes the DNS enable bit or clears a DNS Stop fence. The companion is
valid only with proxy Start/Restart, not as a general new lifecycle verb. It has its own exact
DNS lifecycle revision and outcome. This is a contract extension, not a new meaning of save-only.

For private Start, the fixed module plan can express proxy Start plus DNS conditional activation. For
ordinary menu Restart, add a narrowly typed companion action to the proxy restart command. It
submits no editor values. Its Start phase still verifies required inputs through the sole store/workflow;
unresolved or mixed inputs hold, with no fallback to last-applied values. Proxy and DNS use the same
verified pair. Settings Save-and-Restart can explicitly submit the draft through the private path. Exact API names remain
reviewable implementation details. Both operations use the same workflow authorization and fixed
module ownership; introduce no generic dependency graph, second writer or UI-side lifecycle authority.

A stale participating revision rejects the whole request under 0035. A later Stop invalidates any
remaining shared write/apply as selected there. When Restart only acts on unchanged verified inputs,
a DNS Stop cancels the companion; completed physical effects stay reported facts. Disabled/fenced
DNS is a typed no-op. Running/starting DNS needs no activation. A failed bind leaves its enabled intent
and fence unchanged and restores its machine DNS surfaces as the app does today. A DNS startup failure reports its own result
and does not pretend that an already-started proxy was rolled back. Ordinary restart must not silently
apply unsaved editor values. New fields require frame sizing before adoption.

The behavioral boundary is explicit: activation reads authoritative host intent rather than the editor
draft bit; ordinary menu Restart sends no unsaved values. Every interactive Start already uses the
private current-frozen-draft request. This adds no ordinary Start or new launch auto-start behavior.

Example: DNS was enabled on disk but failed to bind. Restart Proxy explicitly requests a conditional
DNS retry. With unchanged DNS revision and no fence, the host retries it. If the user explicitly stopped
DNS, the action leaves it stopped. If that Stop changed the revision after the client observation, the
whole request is stale; the client preserves the draft and does not replay Start automatically.

**Alternative — explicit client-composed DNS Start.** The client adds a normal DNS Start when its
observation says enabled, unfenced and stopped. The host still validates revisions. This reuses the
private Start case, but Restart needs either a separate private operation, with a separate outcome and
possible intervening controls, or a new companion command anyway. Keep the live host authoritative;
never infer permission from a stale UI mirror.

**Alternative — independent module controls.** Proxy Start/Restart never starts DNS. This is the
smallest contract but changes today's cold-start and failed-DNS retry behavior; users must start DNS
separately despite its saved enabled intent. Revisit coupling if an actual product need changes; do not
add general workflow/dependency machinery for this single existing convenience.

## Work that does not depend on these selections

Finish the byte-exact runtime correction and verification. The shared host's per-module Stop ownership,
ordinary status and private read can be developed for actual-adapter measurements without choosing
private-update admission. Production custody/deadline limits and total Quit budget still require the
measured profile decision. No AppState switch or private update implementation is authorized by this draft.
