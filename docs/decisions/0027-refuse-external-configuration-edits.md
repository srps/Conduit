# 0027: Refuse ordinary saves over changed configuration files

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 external-file edit checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The sole writer and expected component revisions in [0015](0015-save-before-apply.md)
order participating operations. The root lease in [0017](0017-exclusive-state-directory-writer.md)
excludes cooperating hosts, not an editor changing a file directly. Neither decision
selected what to do when an ordinary save observes external changes.

Example: Conduit verified A, an editor wrote B, and Settings submits a draft based
on A. Overwriting B preserves legacy behavior but knowingly loses external work.
Claude identified the unresolved choice during subscription-backed store review.
The owner selected **"Refuse changed files; reload explicitly (Recommended)"** in
[#186](https://github.com/srps/Conduit/issues/186), including formatting-only conflicts
and the limitation on editors racing after the check.

## Decision

Before an ordinary configuration replacement, compare the actual bounded file
content with the store's verified baseline. If the bytes changed, refuse that
replacement, preserve the observed file and the user's draft, and hold the new
runtime apply pending explicit reload/review. A formatting-only edit conflicts.
Creation or deletion relative to a verified absent/present baseline also changes
that baseline. Do not silently adopt new external content as a successful save.

Apply this to the runtime, platform and preferences configuration documents through
one store path and their existing physical/resource bounds. A failed pre-read does
not establish an unchanged baseline and cannot authorize the replacement. Keep
content identity private; ordinary results/events name the component and safe
reason, never file contents, private URLs or content fingerprints.

Explicit reload/review establishes a new verified input through the same owner.
It does not bypass runtime eligibility, current intent/incarnation checks or the
Stop/shutdown fences selected in 0015. Do not add automatic merge, implicit reload,
force-overwrite retry or a second AppState writer.

A multi-file operation remains honestly partial under [0025](0025-hold-mixed-configuration-apply.md).
A conflict does not roll back a component already verified saved, and the mixed
apply remains held until all required inputs verify. UI preferences retain their
selected independence from unrelated runtime work.

Stop and Quit proceed despite a persistence conflict. A failed attempt to persist
a disable cannot refuse the session stop; report that later startup may still
follow saved enabled intent. Quit does not persist a disable merely to exit.

This is detection before replacement, not filesystem compare-and-swap. A
nonparticipating editor can still race after the check. The advisory root lease
remains the authority mechanism for cooperating writers; no global registry,
watcher or durable snapshot history is introduced.

## Alternatives

- **Retain overwrite authority:** simpler and compatible with today's writes,
  but can knowingly replace external edits based on an obsolete draft. Not selected.
- **Compare only decoded values:** avoids formatting-only conflicts, but ignores
  unknown fields and representation changes. It cannot promise to preserve the
  observed external bytes. Not selected for this baseline rule.
- **Watch files and auto-reload/merge:** notifications are not atomic writer
  exclusion and merging introduces new conflict semantics. Optional observation
  can be considered later; it is not save authority.
- **Treat the root lease as sufficient:** nonparticipating editors do not acquire
  it. Per-file leases or a registry likewise cannot exclude such editors without
  their cooperation. Not a substitute for the selected content check.

## Consequences

Users must explicitly reload/review even a formatting-only external edit before
saving an older draft. The daemon can enforce the same rule behind the existing
client boundary, with private content identity and public revision tokens. There
is still no transaction across files or power-loss durability claim.

Revisit for demonstrated editing workflows needing semantic comparison, explicit
merge/override or cooperative editor integration. Specify preservation, stale-intent
handling and failure tests before introducing such behavior. Keep the check behind
the store so the client, modules and sole-writer architecture remain reusable.

## Invariants and verification

Drive the production store against an independent bounded model: unchanged bytes,
formatting-only edits, changed known/unknown fields, creation/deletion, read failure,
external content already equal to the proposed save, explicit reload, mixed partial
persistence and edits racing after the check. The latter must not be presented as
excluded. Cover superseded operations and Stop/Quit during conflict/reload.

Inject adapter defects that skip the baseline check, silently adopt external
content, mint a receipt on conflict or clear a Stop fence during reload. Preserve
scratch-file and headless witnesses alongside the model. No unit/model result
alone establishes real-machine behavior or physical compare-and-swap.

## Implementation evidence

Partial: the store core implements the check before a replacement, for all three
configuration files, in [`ConfigurationStore.swift`](../../Sources/ConduitRuntime/ConfigurationStore.swift)
and its `ConfigurationStore*.swift` siblings. A baseline is the verified bytes the
store observed or wrote. Each conditional replacement, and each verification, compares
the observed bytes with that baseline first. A change refuses the replacement, reports
`conflict`, and keeps the observed file and latches the component until an explicit
reload. A formatting-only edit conflicts, because the check compares bytes. Creation
and deletion relative to a verified absent or present baseline also conflict. A failed
pre-read authorizes no write (`preReadFailed`). The replacement itself is
[`VerifiedConfigurationFileReplacement.swift`](../../Sources/PlatformMac/VerifiedConfigurationFileReplacement.swift),
which runs the pre-read against an opaque baseline and then the existing write and read-back
classifier. The store correction replaces synthesized value equality with canonical persisted-value comparison
on the store worker: Unicode-equivalent strings can otherwise hide different URL/configuration bytes. The canonical
comparison controls verify-without-rewrite; raw observed bytes still decide whether a file changed. Source-dependent
missing-sidecar tokens and first-creation checks accompany that correction. The
[verification checkpoint](../verification-configuration-source-2026-10-26.md) records 169 focused tests, five executed source mutations, independent READY review and all
41 passing local workflow checks (3,432 Swift tests, four skips, zero failures; 103 simulator records).
Client/AppState adoption and owner validation remain open.

Evidence is separate by kind, and each kind covers only what it names:

- Gated and focused tests in [`ConfigurationStoreTests.swift`](../../Tests/ConduitTests/ConfigurationStoreTests.swift):
  an external change latches until a reload even when the old bytes return; an unchanged
  formatted file is verified and not rewritten; a valid unknown-field edit conflicts; an
  external platform change holds the runtime write; each component's authority reason is
  decided on its own. The busy slot is proven by the gated read, which holds the worker while
  other operations are refused without queued I/O. The 7-row coupled fault matrix asserts
  bytes, baselines and write counts per row.
- The preservation guard in [`ConfigurationStorePreservationTests.swift`](../../Tests/ConduitTests/ConfigurationStorePreservationTests.swift)
  (decision 0026): a runtime rewrite that would drop decoded legacy preference values is
  held until the preferences sidecar verifies in the same physical step, and every held
  outcome is typed. Its one known gap is pinned, not claimed closed: a sidecar changed after
  the check and before the runtime replacement is not excluded. Shadowed legacy values (observe-only, a sidecar present) are witnessed for wrong-kind,
  null, duplicate and explicit-default forms, and filter parity. The status stays partial, and validation stays none.
- Sequential bounded models in the same store test file: a runtime/platform model and a
  preferences model, each run over fixed seeds. They reach the outcome classes listed in
  the verification note, and they assert that reach. They are not exhaustive, they do not
  explore interleavings, and their fault injection is the fake's, not the store's.
- The classifier matrix (432 cases, with 288 reaching the write) and the scratch witnesses
  remain in [`VerifiedRuntimeFileReplacementModelTests.swift`](../../Tests/ConduitTests/VerifiedRuntimeFileReplacementModelTests.swift)
  and [`ScenarioConfigFileConditionalReplacement.swift`](../../Sources/pm-sim/ScenarioConfigFileConditionalReplacement.swift).

Counts, seeds and limits are in [the verification note](../verification-configuration-store-2026-10-25.md).

Does not prove: a nonparticipating editor racing after the check (the check is not
compare-and-swap), including a sidecar changed between the preservation check and the
runtime replacement, power-loss durability, cross-process exclusion, the Stop, Quit or
incarnation fences, or the mixed-apply hold of 0025. The daemon now consumes this store through the shared workflow (PR244); AppState and `pm-proxy` do not.
The private client and app writer convergence remain open. Owner validation is none.

## Open questions

None for this conflict policy. Concrete store APIs, measured engine capacities,
listener handoff and full writer/shutdown adoption remain separate implementation
or affected-slice gates.
