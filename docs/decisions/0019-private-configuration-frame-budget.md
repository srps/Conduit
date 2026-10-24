# 0019: One private configuration frame capped at eight MiB

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 private transfer budget checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0018](0018-private-configuration-request.md) selects one private request with full
frozen configuration values. Current validation accepts strings and collection
counts that can exceed any finite transport limit. The executed synthetic
[single-request probe](../experiments/runtime-config-transfer/README.md) includes
a valid 40,000-entry input at 5,584,533 encoded bytes (about 5.33 MiB).
The installed file was 6,443 bytes; only its metadata was inspected.

Claude reviewed the alternatives using the owner's claude.ai Max subscription;
Codex reviewed the source and executed the probe. The owner selected one private
frame with an eight-MiB cap in [#186](https://github.com/srps/Conduit/issues/186).
The [budget review](../design-runtime-private-budget-review.md) records the costs
and verification gates. The measurements are not production-codec benchmarks.

## Decision

Cap a complete encoded private configuration request, including its envelope and
framing, at **8 MiB (8,388,608 bytes)**. Use batched I/O and work/capacity independent
of Stop/status; a configuration transfer cannot reserve their admission capacity
or block the runtime owner while encoding, decoding or saving. Exercise the same
private framing in memory before the later socket adapter. In that adapter, keep
private transfer on a connection separate from Stop/status. Preserve v1's 16 KiB
limit; this selects no ordinary v2 observation/page limit.

Refuse oversize updates explicitly **before saving** and before runtime admission.
Never truncate configuration or persist a partial transfer. Preserve loading
existing files under today's validator: an existing file can be valid at startup
yet too large to submit as a new private update. Explain that refusal honestly;
the update must be reduced or the budget deliberately changed. Raw file size and
encoded request size are different measures.

This selects no per-field/count or query-string restriction. It also does not
make eight MiB an RSS cap. Bound owned pending/decoding/saving inputs, temporary
allocations and work per turn separately. A caller timeout does not release a
physical write or bypass [0017](0017-exclusive-state-directory-writer.md).

## Alternatives

Sixteen-KiB chunks with the same total cap allow frame-level multiplexing, but
add transfer identity/order, reassembly and incomplete-transfer cleanup. They
still require a total input and decode-memory cap. Independent private/control
work avoids that need here. An unlimited frame fails the bounded-resource rule;
keeping the v1 limit would refuse modest currently valid configurations.

## Consequences

The codec has a concrete input bound without a chunk-transfer state machine.
Some previously accepted configurations may exceed the new update limit;
startup compatibility is preserved. Independent connections alone do not prove
CPU fairness or bounded memory. Serialization can create plaintext copies, as
0018 already records. No production socket, lease/store or installed-app change
is implemented by this record.

## Invariants and verification

Test exact boundary/overflow, multibyte/escaped strings, malformed or partial
frames, slow input, busy capacity, disconnect and timeout. Where framing declares a length, refuse an oversize
declaration before body allocation; incremental framing must stop at the cap
without copying the overflow. Encode preflight must not first allocate
an unbounded result. Measure actual decoder memory and status/Stop latency during
all transfer/save phases; verify late completion cannot defeat the stop fence.
The synthetic generic mirror does not establish these production properties.

## Implementation evidence

None yet. The candidate under `docs/experiments/` is test-only sizing evidence,
outside Package.swift. No production private codec or transfer engine exists.

Does not prove: codec allocation bounds, control responsiveness, writer coverage
or real-machine behavior.

## Open questions

Measured working-memory, lifetime, capacity and total shutdown budgets remain
adoption gates. Canonical writer coverage for external paths and listener handoff
remain separate affected-slice decisions. No owner/machine validation is recorded.
