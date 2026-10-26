# 0035: Validate combined editor lifecycle intent as one request

- Date: 2026-10-26
- Decision: accepted (owner, 2026-10-26, #186)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The private editor request carries one frozen runtime/platform input and per-module lifecycle slots.
Exact revisions and independent Stop fences were selected, but the records did not say whether one
stale slot rejects the combined request. A second client, or the same client toggling DNS during a save,
can create that race. One shared applied baseline and the mixed-input hold remain selected (0025).

After official subscription-backed Claude review, the owner selected “Whole-request validation
(Recommended)” on 2026-10-26, recorded in [#186](https://github.com/srps/Conduit/issues/186).
The [reviewed alternatives](../design-runtime-editor-admission-options.md) contain the concrete scenario.

## Decision

Reserve bounded operation capacity, then check every actionable Start/apply-while-running lifecycle
revision in the owner admission turn, before any persistence or intent change. If any is stale, reject
the entire request with the stale-revision result and preserve the client draft. Save-only slots have no
lifecycle revision. File-baseline conflict policy remains 0027; observation does not authorize overwriting.

After admission, Stop retains independent capacity and immediately fences its module. Relevant intent
includes actionable revisions and merged persisted lifecycle values, today DNS forwarderEnabled.
If changed intent invalidates an unstarted write or remaining shared apply, hold or supersede the
remaining combined operation. Keep any verified saves and report per-component persistence and
per-module outcomes honestly. Do not introduce a re-staging/retry loop for this release.

A held or failed Start leaves no pending enable authorization that reload, autosave, VPN handling or
repair can activate later. Preserve the previous Stop fence and newer controls. Only a new explicit
Start can authorize activation; rejected/held Starts are never replayed automatically. Representing a
pending Start need not clear its fence before verified persistence.

Already-started physical writes can complete; a fence is not rollback. Ordered Stop saving and any
unsaved-Stop warning remain as in 0015. A held combined operation does not stop other modules that
were already running. Ordinary snapshots must expose bounded per-module lifecycle revisions; renew
frame sizing before adopting those fields.

## Alternatives

Save values with current lifecycle intent and allow unaffected module actions to progress, reporting
stale slots separately. This improves progress under concurrent clients, but requires subtler partial
outcomes and potentially bounded re-staging while retaining one applied input. It was not selected for
this release. Silently weakening exact revisions, making save-only enable a module, or automatically
replaying Start would change approved control authority and were rejected.

## Consequences

One request has a clear causality gate and bounded work. An unrelated lifecycle action can make a
combined edit require another explicit submission, even from the same client. Saved-but-unapplied
intent requires clear presentation. The sole writer and future daemon remain reusable; a demonstrated
need for partial progress can revisit the policy without adding another writer or client-specific rules.

## Invariants and verification

Drive real workflow/client adapters and an independent bounded model through stale slots before
admission, capacity refusal, Stop during staging, partial platform persistence, and Stop after a started
write. Assert no write or intent change on pre-admission refusal; no stale unstarted write; honest saved
facts; no apply from an invalidated pair; no automatic Start after a hold. Exercise same-client toggle/
autosave races and fresh observations that cannot silently retry Start. Add actual-host pm-sim evidence.

## Implementation evidence

None yet. The existing process facade and headless private codec do not implement this interactive rule.
No AppState activation or production service-profile selection follows from this record.

## Open questions

Dependent proxy-to-DNS startup and Restart remain a separate owner choice. Production capacity,
custody/deadline and total Quit values still require actual-adapter measurement. Revisit partial progress
for demonstrated multi-client need, with explicit dependencies, bounded work and one coherent apply model.
