# 0038: Bound complete runtime collection captures independently of live connections

- Date: 2026-10-27
- Decision: accepted (owner, 2026-10-27, #186: selected “4 MiB capture / 8 MiB retained (Recommended)”)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The paged client needs finite collection custody before AppState adoption. Live
connection capacity and projected display-row bytes measure different things.
Multiplying the connection limit by the widest constructed row would make
retention disproportionately large. A small fixed row count would refuse useful
ordinary activity lists prematurely.

The owner selected the independent count/byte profile in
[#186](https://github.com/srps/Conduit/issues/186), after reviewing the measured
4 MiB/8 MiB and 8 MiB/16 MiB alternatives.

## Decision

A complete collection capture admits at most 10,000 rows and at most 4 MiB
(4,194,304 bytes) of encoded rows. Retained row sets across all collection kinds
share an 8 MiB (8,388,608-byte) ceiling. Count and byte bounds apply independently.
A capture exceeding either is unavailable as a whole, with its exact known total.
It is never a truncated list presented as complete. Page frames retain their
separate selected 64 KiB cap.

These observation bounds do not limit live proxy connections or change stored
configuration acceptance. The UI must identify an unavailable list and preserve
the exact total. It must not imply that the host stopped serving those connections.

Use one composition profile; add no configuration-store mode or registry. This
choice selects neither revision/proof counts, retention ages, event/queue limits
nor deadline values. Verify those coherently before activation.

## Alternatives

- **8 MiB capture / 16 MiB retained:** fits all 10,000 of the probe's wider
  connection rows, at 12 MiB more accounted encoded custody than the selected
  pair. It still cannot fit 10,000 maximum-length rows. Rejected for now because
  no measured usage requires the larger observation budget.
- **Count multiplied by the widest row:** preserves every constructed row at
  the count ceiling but increases custody markedly. The selected independent
  byte ceiling provides a clear bounded refusal instead.
- **Lower count alone:** cheaper but prevents large ordinary lists even when
  their encoded rows fit the byte budget.
- **Sampling or partial capture:** could offer some activity at lower cost but
  needs explicit selection/completeness semantics. Not selected; do not silently
  turn the complete revision-qualified collection into a sample.

## Consequences

The pre-event-integration probe at `3ed13fa` fit 10,000 typical connection rows
(about 2.9 MB), 5,309 wider rows, 688 mixed-escape rows or 327 widest constructed
rows under 4 MiB. These are synthetic shapes, not a measured distribution of the
owner's traffic. Retained inbound-connection logs are not active-request row data.

Review the budget if actual usage regularly refuses useful lists, if display rows
change materially, or if new collection kinds need simultaneous retention. Prefer
measured changes to the same profile. Introduce sampling only with an explicit
product contract. These byte accounts are not preallocated RAM or a process-memory
bound; private custody and object overhead remain separate.

## Invariants and verification

Exercise the count and byte boundary through bounded projection and the service's
whole-capture refusal, preserving exact totals and revision qualification. Measure
normal, wide and escaped shapes. Keep Stop/status independent under pressure and
confirm cleanup and host release. New fields must pass the existing frame/custody
checks before adoption.

## Implementation evidence

[`RuntimeCollectionLedger`](../../Sources/ConduitRuntime/RuntimeCollectionLedger.swift)
and [`RuntimeServiceLimits`](../../Sources/ConduitRuntime/RuntimeServiceLimits.swift)
already enforce independent supplied bounds. The
[pre-integration measurement](../experiments/actual-runtime-client-profile/runs/3ed13fa-8p7pkC/metadata.json)
records the candidate; its
[projection measurements](../experiments/actual-runtime-client-profile/runs/3ed13fa-8p7pkC/profile-sizing.ndjson)
record the rows that fit. The actual event feed and shutdown were missing at that
checkpoint, so it is not final production-profile acceptance. The fresh [corrected-source run](../experiments/actual-runtime-client-profile/runs/ef3e4df-OdAmdZ/README.md)
passes all 31 mode/trials, including actual event delivery and host shutdown, at
clean/stable source `ef3e4df`. Its row-shape measurements remain synthetic;
that run preceded production composition and AppState adoption.

[`RuntimeServiceProfile.inProcessApp`](../../Sources/ConduitRuntime/RuntimeServiceProfile.swift)
now supplies the selected bounds to the app's actual framed clients and shared
host. [`RuntimeServiceShippingProfileTests`](../../Tests/ConduitTests/RuntimeServiceShippingProfileTests.swift)
pin the caps and codec-derived custody terms.
[`RuntimePresentationAdapterTests`](../../Tests/ConduitTests/RuntimePresentationAdapterTests.swift)
exercise a complete 10,000-row capture across four revisions through the actual
observer/client/service and preserve unavailable totals. The collector enforces
4 MiB and 10,000 rows; the host ledger owns the 8 MiB retained encoded-row budget.
The display adapter's object/string memory is not included in that host accounting.
The [fresh activation measurements](../verification-appstate-activation-2026-10-28.md)
pass all 31 Release profile trials and three Debug consumer trials on stable
source. Native acceptance remains pending; no app RAM bound follows.

Does not prove: production app memory, normal usage row sizes, installed-machine
behavior or release readiness.

## Open questions

Other composition capacities and deadlines remain separate from this selected pair.

### Control-fairness correction — 2026-10-28

The [activation checkpoint](../verification-runtime-actor-activation-2026-10-28.md) measures a long synchronous projection and records the reviewed off-owner correction. [One shared capture flight](../../Sources/ConduitRuntime/RuntimeCaptureFlight.swift) across kinds reuses the existing one-capture staging term in [RuntimeServiceLimits](../../Sources/ConduitRuntime/RuntimeServiceLimits.swift), without reserving budget early or changing eviction. Eight MiB remains retained encoded rows, with up to one four-MiB capture in progress; these accounts exclude object memory. Source, causal checks and final-source resource acceptance pass in the linked checkpoint. A small-kind capture can keep an unselected larger collection alive, so neither the row cap nor these encoded accounts bound the whole frozen value or app RAM.
