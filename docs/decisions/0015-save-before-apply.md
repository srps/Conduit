# 0015: Save durable intent before apply, with Stop and Quit exceptions

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 implementation checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Saving only after runtime success can lose the requested setting when apply
fails or the process exits. Waiting for saving before Stop/Quit can refuse an
urgent control action. The owner selected save-before-apply with explicit
exceptions and authorized staged implementation after Claude's policy review
in [#186](https://github.com/srps/Conduit/issues/186).

## Decision

Keep editor draft, durable intent, effective session intent and actual per-surface
applied state distinct. AppState remains the interim writer. Ordinary durable
edits/enables require verified persistence of validated coupled runtime components
before admission. Retain saved intent and bounded correction on apply failure.
Independent UI preference failure need not refuse unrelated runtime work.

Saving returns verified persisted, verified not persisted or unknown. A write
error alone cannot prove absence. Use bounded authoritative read-back; unresolved
saving admits no ordinary apply and warns that the value may take effect on a
later launch. Component receipts identify revisions; a hash alone proves neither
durability nor authority. Separate config/platform/prefs writes are not atomic;
#182 remains platform-journal versioning only.

Use one generation-ordered writer with expected prior component revisions. Capture
generation before awaits; reject stale queued writes. A late save success must
still check current intent and stop/shutdown fences before apply. Whole-config
saves merge current explicit lifecycle intent instead of restoring an older enable.

Stop is session control: submit it first and establish the host's fence at
admission, then queue any applicable disabled-intent save. Saving failure cannot
refuse Stop. Report listener outcome, cleanup outcome and saving outcome
separately. Unknown admission cannot be called an established stop/fence, even if
disabled intent can still be saved. Autosave, repair, VPN and retries cannot clear
the fence; only a newer explicit start/enable may. Warn that another host may use
older saved enabled intent after an unsaved Stop. No persistent warning marker is
introduced by this decision.

Quit fences the in-process runtime immediately, without a durable disable merely
because the app exits. Drain the latest valid pending edit save without applying
it, within one total monotonic deadline covering read-back, writes, helper and
manager waits. Invalid edits do not block Quit. Started writes may complete;
cancellation is not a physical rollback. Preserve recovery records for incomplete
cleanup. Later daemon-mode UI Quit disconnects only.

An exited process cannot run a late completion; an overlapping live writer needs
proven exit/quiescence or exclusive state-directory write ownership. A local queue
or receipt does not establish that property. See the
[runtime design](../design-runtime-host-contract.md) for failure histories and
model obligations. Behavior-preserving host extraction does not implement this
new policy implicitly; each affected lifecycle migration makes the tested change.

## Alternatives

Apply-before-save can run an intent that will disappear on restart. Save-after-
success makes desired state depend on transient runtime availability. Requiring
save success for Stop/Quit couples control to disk availability. Treating all
files as a transaction or all write failures as no-write gives false guarantees.

## Consequences

Saved intent can precede successful application and requires honest pending/failed
presentation. Unsaved Stop is a session guarantee, not a new-launch guarantee.
Partial commits, unknown writes and overlapping processes remain explicit states.

## Invariants and verification

Drive production adapters and independent models through save success/failure/
unknown, partial writes, inverse edits, Stop during enable write, superseded
whole-config saves, out-of-order completions, shutdown deadline and fresh launch.
Show injected-bug sensitivity for generation, stop and ambiguous-write checks.
Retain fake-machine harness and pm-sim evidence of actual effects. Never infer
applied state solely from a saved flag or label a pending stop as stopped.

## Implementation evidence

None yet. Existing persistence paths are not claimed to enforce this policy.

Does not prove: atomic multi-file commits, cancellation of started writes,
exclusive ownership across processes or machine cleanup after a deadline.

## Open questions

Classify secret-free committed fields and coupled components before their client
commands. Decision [0017](0017-exclusive-state-directory-writer.md) settles writer lifetime
with an exclusive lease; its adapter, writer coverage and upgrade evidence remain
due. Settle listener handoff failure/retirement policy before changing those paths. Size total shutdown and
helper/lock budgets with evidence.
