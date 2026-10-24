# 0023: Keep schema two and refuse inexact committed durations

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #224 precision policy checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Save-before-apply in [0015](0015-save-before-apply.md) requires applied runtime
input to equal verified persisted intent. Schema2 stores connection-check timeout
in integer milliseconds and direct-connect cache TTL in integer minutes, while
the domain/private request use Double seconds. The actual scratch persistence
probe changed a1001ms timeout to1000ms through floating-point truncation and a
90.5-second TTL to60 seconds through integer-minute storage. These are separate
problems. The [precision review](../design-runtime-store-precision-review.md)
records the executed witnesses and Claude's subscription-backed source review.
The owner selected compatibility-preserving exact saves in
[#224](https://github.com/srps/Conduit/issues/224).

## Decision

Keep the existing schema2 file format and editor units. Fix representable whole-
millisecond round trips without truncating a floating-point approximation of
an integer. Reject nonfinite/out-of-range conversions before saving or admitting
untrusted runtime input. Do not introduce arbitrary general duration ceilings
under this representability policy; respect existing product bounds.

For an ordinary durable update, stage the bounded file encoding, decode it through
the same format, and require equality with the frozen required runtime values
before any physical write or runtime admission. If those values cannot round-trip
exactly, return a fixed field-coded representability error. A90.5-second TTL or a
sub-millisecond timeout cannot be silently committed. No automatic rounding or
normalization dialog is introduced. Preserve the rejected original file.

Representability belongs to the store boundary; private requests and RuntimeHost
keep canonical seconds and never silently quantize. Treat an integer-unit value
as representable only when conversion to the integer unit and decoding back yield
the original domain value. Apply safe conversion checks before narrowing; do not
first call a trapping integer initializer. Correct runtime consumers/getters as
well as file encoding so the accepted whole-unit intent is actually applied.

Read-back verification, expected revisions, partial component results and unknown
outcomes remain separate from pre-write representability. Keep Stop/Quit behavior
from0015: a persistence refusal cannot refuse the session stop/shutdown or permit
a stale completion to re-enable. Physical writer authority lasts until writes
are quiescent, independent of caller deadlines. No new schema/registry is needed.

## Alternatives

- **Schema3 with canonical seconds:** represents fractional-minute TTLs and aligns
  domain/file units, but introduces a migration and rollback barrier: checked
  schema2 readers refuse the newer file. Revisit for a demonstrated precision
  requirement or a deliberate broader schema upgrade, with every import/load
  gate and mixed-version behavior verified.
- **Explicit caller-visible normalization:** could retain schema2 and accept more
  editor inputs, but adds confirmation/draft state and changes requested intent.
  No such flow is selected. Silent normalization violates exact committed intent.
- **Dual old/new keys under schema2:** old named-key readers consume lossy values
  or defaults and cannot preserve new semantics; not selected.
- **Blind truncation or clamping:** hides changed intent and may still trap on
  nonfinite/out-of-range inputs; not selected.
- **Require a new schema for writer leases:** ownership coordination is separate
  from file units. Combining version barriers is not required by the architecture.

## Consequences

Some in-memory values previously accepted by broad validation are refused for an
ordinary committed update. Today's schema already changes those values silently;
the new behavior makes the limitation explicit and preserves old-reader/rollback
compatibility. Future daemon/client interfaces and receipts remain independent of
file encoding, so later schema evolution need not change their contract.

## Invariants and verification

Exercise1001ms and other whole-millisecond values across editor/domain/file/runtime
consumers, exact-minute TTLs, sub-unit neighbors, zero, range boundaries, NaN and
infinity. Test refusal before any write/admission and unchanged original bytes.
Use property/seeded cases around integer-unit boundaries with decode-equality
checks independent of the conversion implementation. No cumulative precision
loss is inferred from the original single-round-trip witness.

Verify required-field equality rather than only successful JSON decoding. Test
partial component writes, read-back ambiguity, late completions, Stop/Quit fences
and writer quiescence against an independent model as the store is introduced.
Use scratch files/fakes; no installed app/helper or user configuration changes.

## Implementation evidence

None yet for the selected behavior. The old scratch witness establishes the
problem; it is not evidence that exact saves or safe runtime consumption exist.

Does not prove: complete boundary coverage, asynchronous store ordering, physical
write quiescence, actual shutdown latency or real-machine behavior.

## Open questions

Revisit schema3 for a demonstrated need for sub-millisecond probes, fractional-
minute cache TTLs, or a broader deliberate format migration. Keep rollback and
all-reader/import evidence explicit. Listener handoff and later daemon deployment
remain separate affected-slice gates; this choice changes no resource/frame cap.
