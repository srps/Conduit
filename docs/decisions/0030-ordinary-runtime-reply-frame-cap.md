# 0030: Ordinary v2 replies and stream frames capped at 64 KiB

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186: selected “64 KiB replies/stream frames (Recommended)”)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The owner selected bounded display text in [0029](0029-bound-runtime-display-text.md).
The actual codec now measures a populated escape-heavy baseline with widened metadata
at **49,376 bytes including its line feed**. This is a measured point, not a proof
of the longest encoding of every finite Double or every future schema branch.
The earlier 16 KiB suggestion in [0014](0014-runtime-client-stream.md) was a review
input, not a selected shipping default. The owner chose the reply/stream ceiling
in [#186](https://github.com/srps/Conduit/issues/186) after reviewing measured sizes,
allocation lifetimes and the alternatives with Claude and Codex.

## Decision

Cap ordinary v2 **replies and stream frames at 65,536 encoded bytes**, including
the envelope and trailing line feed. Keep a complete baseline in one frame;
collections remain separately paged against the exact frame bound. Preserve
explicit refusal when a caller selects a narrower bound; do not silently widen it.
The measured baseline leaves 16,160 bytes of margin. That margin is engineering
judgment, not permission to add unbounded fields.

Keep the private configuration channel's separately selected 8 MiB cap and the
legacy v1 contract unchanged. This decision does not select request capacity,
queue/operation/subscriber counts, retention, event budgets, per-turn work or
deadlines. Their coherent shipping profile and actual-host verification remain
gates. Configurable experimental/test limits are not production defaults.

Carry the selected ceiling through the existing client/service composition when
that shipping profile is implemented. Do not add a second codec, an unused
parallel limit interface or a split-baseline assembler. New snapshot and
AppliedState shapes must be closed and bounded, pass actual framing/sizing checks
and be reviewed before adoption; they cannot consume the margin implicitly.

## Alternatives

- **128 KiB replies:** no measured view needs the additional space. It increases
  the encoded-custody charge for each transport reservation and buffered first
  frame. Under the current two-reply charge, raising64 to128 KiB adds128 KiB
  per reservation, before multiplying by the selected lane counts.
- **16 KiB with split baselines:** lowers per-frame custody but requires partial
  baseline retention, revision/incarnation consistency, completion and resync
  rules. The maximum-text fixture cannot fit16 KiB. Normal small baselines can;
  splitting would be needed for larger accepted views, not every baseline.
- **Refuse all larger baselines:** exact refusal remains a safety behavior, but
  deliberately choosing a ceiling below the measured bounded view would make
  accepted status unavailable in that case.

## Consequences

One baseline remains a single consistent value. Collections already have their
own paging contract, so rows do not need to share the baseline's frame.
The ceiling is encoded bytes, **not RAM**. Decoded objects, encoder scratch,
Foundation temporaries and lane/subscriber counts require separate accounting.
The [allocation experiment](../experiments/runtime-display-codec/README.md) exposed
and verified a shared sanitizer lifetime correction; it does not establish a
universal memory or actual-host latency bound.

## Invariants and verification

Test the complete populated baseline and notices through the actual codec,
including worst text escaping, widened metadata, exact limit and one byte over.
Before production adoption, pin the selected ceiling in the coherent profile,
check producer/client agreement, narrower-caller refusal and separate private/v1
limits. Recompute the checked aggregate custody under the selected lane counts.
Measure actual-host Stop/status latency and bounded collection work independently.

## Implementation evidence

The choice is recorded; production profile/composition is not implemented.
The existing measurement is
[`RuntimeDisplayBoundsProjectionTests.swift`](../../Tests/ConduitTests/RuntimeDisplayBoundsProjectionTests.swift)
(`testAWidenedMetadataBaselineIsEncodedAtTheWidestScalarsTheRulesAllow`). Its
49,376-byte result and 303-byte envelope difference are recorded in
[the checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md).
This evidence supports the decision and does not claim enforcement of a shipping
profile or actual RuntimeHost/AppState adoption.

The local [actual-client checkpoint](../verification-runtime-client-owner-2026-10-27.md) exercises the actual host through [`RuntimeInMemoryTransport`](../../Sources/ConduitRuntime/RuntimeInMemoryTransport.swift) under the selected 64 KiB reply cap. [`RuntimeServiceLimits`](../../Sources/ConduitRuntime/RuntimeServiceLimits.swift) accounts for its structural Quit/Stop lanes and operation partitions. The module-stamp extension raises the measured populated baseline by 96 bytes to 49,472; production profile selection and AppState composition remain open.

Does not prove: selected production capacities/deadlines, AppState activation, RuntimeActor isolation, installed-app behavior or release readiness.

## Open questions

Select the remaining coherent shipping profile from measured custody/work and
pressure results. Revisit this ceiling for a new bounded snapshot/AppliedState
shape, changed redaction/encoding, a measured view exceeding the margin, or a
demonstrated workload that needs larger frames. Bring that change to owner review
before implementing the affected path; do not infer a larger default.
