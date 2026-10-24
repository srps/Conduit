# Private configuration transfer: budget checkpoint

Status: owner selected the single private frame and eight-MiB encoded-request cap
on 2026-10-24; [0019](decisions/0019-private-configuration-frame-budget.md) records
that choice, refining 0018. Detailed working-memory/lifetime capacities and the
physical transport adapter remain implementation/adoption work.
No production configuration codec, transfer engine or new config ceiling is
implemented by this document.

## Selected shape

Use one private frame, with an **8 MiB maximum for the complete encoded request**,
including its envelope. This limit is separate from v1's unchanged 16 KiB limit
and from the still-provisional ordinary v2 control/observation limits. In the
later socket adapter, private configuration transfer uses a connection independent
of Stop/status. In memory, it likewise has separate bounded work and capacity.
Read/write in batches no larger than 16 KiB; encode/decode and persistence do not
run on the UI or runtime control owner. A large frame is not one large owner turn.

The initial capacity proposal is one assembling private request per host, with
explicit busy refusal. Count owned queued/decoding/saving inputs too: limiting
socket assembly alone does not bound operation memory. Transfer deadlines,
retained outcomes and total working-memory budgets remain implementation gates;
an encoded-byte cap is not an RSS cap. Stop must establish its session fence and
make progress despite stalled transfer, decode, save or diagnostic consumers.

An oversize **update** is refused explicitly before persistence and runtime
admission; no truncation, partial save or blind retry. This proposal preserves
loading an existing configuration under the current validator. An existing file
that produces an oversize request can still be loaded at startup, but cannot be
submitted as a new private update until reduced or the budget is deliberately
changed. Raw file bytes and encoded request bytes are different measures.

The owner approved this compatibility cost in the private transfer budget checkpoint. No new
per-field/count restriction or restriction on query-bearing URLs is selected.

## Alternative: small frames with chunking

Keep each private chunk within 16 KiB, with the **same 8 MiB total encoded input
cap** and the same independent work/capacity. Add transfer identity, length/order
validation, incomplete-transfer cleanup and bounded reassembly. Disk staging is
possible but needs its own capacity and cleanup. Final JSON decoding still needs
a separate memory/work budget. Chunking alone does not make an arbitrary-size
configuration safe or solve ownership of a timed-out physical write.

Chunking is useful if private data must share a multiplexed connection with
control, or measured transfer behavior requires smaller application frames.
Independent connections avoid that requirement here. Both designs still need
fair scheduling, bounded concurrency and deadlines; those limits are not unique
costs of chunking. Incremental I/O alone cannot interleave Stop inside a large
frame on the same byte stream.

## Evidence and limits

The installed `config.json` was 6,443 bytes at this checkpoint; only filesystem
metadata was inspected. That is a usage point, not a maximum or a transfer size.
The [executed synthetic probe](experiments/runtime-config-transfer/README.md)
includes a valid 40,000-entry configuration whose provisional single-request
encoding is 5,584,533 bytes (about 5.33 MiB), and valid single strings/URLs around
1 MiB. The executed single-request probe reconstructs equal runtime and platform
values for all eleven fixtures; it is a generic mirror, not a production codec.
The eight-MiB proposal
leaves headroom above those fixtures; it is not a demonstrated universal maximum.

Claude reviewed this choice using the owner's claude.ai Max subscription and
recommended the larger private frame with independent control capacity. Codex
agrees with that basis, with these corrections to the review: the recommendation preceded the owner selection; chunking also needs a total cap; both options need concurrency
and lifetime limits; and a separate connection does not itself prove CPU or
memory isolation. The old chunk counts include base64 expansion and envelope
overhead, so dividing raw bytes by the frame limit does not reproduce them.

Before adoption, verify the actual encoder/decoder at the boundary and just over
it, multibyte and escaped strings, invalid lengths, partial input, slow transfer,
disconnect, busy capacity, timeout and Stop during every phase. Measure peak
memory and control latency on the actual implementation; a generic test-only
JSON mirror cannot establish them. An oversized declared length must be refused
before body allocation; encode preflight must avoid allocating an unbounded JSON
result merely to discover it is too large. Keep canonical external-path writer
coverage, listener handoff and total shutdown budgets as separate decisions.
