# 0015: Save durable intent before apply, with Stop and Quit exceptions

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 implementation checkpoint)
- Implementation: partial
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

Partial: the exact-schema-two app gate is merged (PRs227/228). The app's
commit path in [AppState.swift](../../Sources/Conduit/App/AppState.swift)
(`saveConfig`) reconciles the runtime only after the save is written and the
config blocks no proxy start. A refused save, or a commit that blocks a start,
keeps the runtime on the config it last applied, and the reconcile still runs for
platform changes at that config. The refusal and the held commit emit
`config.save_rejected` and `config.apply_held`. Quit writes the platform file even
when the runtime save is refused. The explicit health check and the tunnel start
refuse a duration the runtime cannot hold, and name its field, before any connect. The
direct-connect detector, built on system wake too, starts no probe without a usable budget.
`AppState` keeps a temporary editor baseline (`editorBaseline`) to tell whether an unsaved
edit is pending. It is not a receipt or a check of disk state; the store that replaces it
owns that.
Tests: [ConfigSaveGateTests.swift](../../Tests/ConduitTests/ConfigSaveGateTests.swift)
on a real `AppState` over the harness, and
[ConfigExactPersistenceTests.swift](../../Tests/ConduitTests/ConfigExactPersistenceTests.swift).

Still open: the save is not a store transaction, so ordering through an actor, read-back
of physical writes, expected revisions, and Stop/Quit fences beyond the quit path are
unproven. The app's runtime host is still a twin of `RuntimeHost`, not one isolated
host. The Settings UI is not exercised by the gate tests.

Does not prove: atomic multi-file commits, cancellation of started writes,
exclusive ownership across processes or machine cleanup after a deadline.

Store core, not adopted (2026-10-25): [`ConfigurationStore.swift`](../../Sources/ConduitRuntime/ConfigurationStore.swift) makes one serialized writer for the runtime, platform and preferences files. It stages the runtime and platform candidates before the first write, writes the platform file first, and reports typed persistence facts with the caller's context. Each operation holds one busy slot and refuses an overlapping call as busy without queuing it. It has no Start, Stop, apply, intent counter or request ledger, and no app path constructs it yet. Evidence and limits are in [the verification note](../verification-configuration-store-2026-10-25.md).

Physical verification primitive, consumed by the store core (2026-10-25): [`VerifiedConfigurationFileReplacement.swift`](../../Sources/PlatformMac/VerifiedConfigurationFileReplacement.swift)
classifies a component replacement as verified persisted, verified not persisted, unknown or not started, from an expected-baseline pre-read, the write's own result and bounded read-back. The outcome carries no bytes. It takes no intent generation and mints no receipt; the store owns component baselines/receipts, while the actual workflow owns intent and apply. Evidence and limits are in [the verification note](../verification-runtime-file-replacement-2026-10-24.md).

The store now compares canonical staged values rather than synthesized String equality before issuing
an unchanged receipt. This prevents handing the host candidate URL/text bytes that differ from the
verified file. The [source-authority checkpoint](../verification-configuration-source-2026-10-26.md)
records the exact evidence and limits. The separate apply/reconciler correction (#246) uses one
byte-aware adoption predicate across the host, reconciler and orchestrator, with byte-aware PAC
and credential caches. Its [verification checkpoint](../verification-byte-exact-runtime-intent-2026-10-26.md)
records failing witnesses, executed mutations and remaining checks. Neither establishes AppState convergence.

## Open questions

Classify secret-free committed fields and coupled components before their client
commands. Decision [0017](0017-exclusive-state-directory-writer.md) settles writer lifetime
with an exclusive lease. Its OS adapter and startup acquisition are implemented;
complete writer coverage, shutdown accounting and upgrade evidence remain due. Settle listener handoff failure/retirement policy before changing those paths. Size total shutdown and
helper/lock budgets with evidence.
