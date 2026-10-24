# 0027: Refuse ordinary saves over changed configuration files

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 external-file edit checkpoint)
- Implementation: planned
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

None yet. The existing runtime replacement primitive classifies read-back but
deliberately has no expected-baseline policy. Store/client adoption remains planned.

## Open questions

None for this conflict policy. Concrete store APIs, measured engine capacities,
listener handoff and full writer/shutdown adoption remain separate implementation
or affected-slice gates.
