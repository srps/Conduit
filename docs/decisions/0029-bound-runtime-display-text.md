# 0029: Bound runtime display text with explicit notices

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186: selected “Bound display text with explicit notices (Recommended)”)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The v2 runtime snapshot, the collection rows and the upstream probe carried free
text with no bound. The configuration bounds ([0021](0021-bounded-configuration-at-all-boundaries.md))
cover names and URLs at input, but not kernel or OS diagnostics, and JSON escaping
expands raw text: a NUL costs six encoded bytes. One long diagnostic could therefore
make the current status frame too large. The alternatives and the measured worst cases
are in the [bounds review](../design-runtime-display-bounds-review.md), and the
2026-10-25 inventory is in [the checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md#text-inventory-historical-before-decision-0029).

The owner chose the bounded policy with explicit notices in #186. The quoted selection in
the header matches the top section of that issue, checked on 2026-10-25. This record is the
authorization for the caps below; it does not select any frame, retention, queue or
deadline value.

## Decision

- **Caps, after redaction, in UTF-8 bytes.** Config-derived names (profile name,
  upstream name, tunnel label, probe name) take `DomainResourceLimits.displayText`,
  which is 1,024. Diagnostic text and endpoints take 512.
- **Input limit.** A raw value over 16,384 bytes is replaced whole by the fixed
  marker `<omitted>` before any redaction or copy-heavy work. The gate reads at most
  16,385 bytes of a native string. A bridged NSString may materialize its UTF-8 on
  first access, which is outside that bound.
- **Order.** Redact, then cut at a character boundary. A cut never precedes redaction,
  so, for the credential forms the sanitizer's grammar recognizes (Bearer and Basic tokens,
  URL userinfo and query, and the listed sensitive header lines), no part survives as a prefix.
  A secret in a form that grammar does not recognize is not promised redacted; the policy bounds
  it and does not identify it. One path,
  `ControlDisplayText.bounded`, does this for the projection and the unknown-event display.
- **Notices.** A closed enum, `ControlDisplayField`, names every displayed field,
  with its owner and its cap. Each record carries `displayNotices`: one notice per
  shortened or omitted field, in canonical order, at most one per field. A notice needs its
  field's value to be present, and an `omitted` notice needs the fixed marker. Redaction
  alone is not a notice. A bare `<omitted>` value with no notice is accepted as genuine text,
  because a configured value may equal the marker.
- **Codec.** Every encode and decode of a record that carries display text runs one
  check. Only the projection cuts text. A raw value over its cap handed to the codec directly
  is refused, never truncated, and that refusal surfaces as an invalid value. When a value is
  both over its cap and too large for the frame, the frame budget measures first, so the
  refusal is `frameTooLarge`; a value within the frame but over its cap is `invalidValue`. The check also
  refuses a malformed notice array, a notice for another
  owner's field, and a notice for an absent value. It never rewrites a value. A kept
  value with no notice is accepted, because a notice cannot prove the history of text
  that arrived without one. Decode reads the notice array in one bounded pass and
  refuses before it keeps an element beyond the owner's count.
- **Unchanged.** Stored configuration, stable IDs, enum facts, exact counts and
  collection totals, command inputs, known events and the v1 wire. The unknown-event
  display keeps its 64, 128 and 512-byte limits. It gains only the input gate, and its
  `truncated` flag now means cut or omitted.
- **Not selected.** Any shipping ordinary-v2 frame cap, reply cap, retention, queue,
  deadline or collection capacity. The measured sizes are evidence for that later
  decision, not defaults. A `RuntimeServiceLimits` floor is not added.

## Alternatives

- **Refuse oversize snapshots or rows whole.** Rejected: one long diagnostic would
  blank the status.
- **Cut by encoded length.** Rejected: it needs a second cut algorithm, and the
  decision keeps one raw-byte path with an exact encoded check after encoding.
- **Producing omitted fields with no notice.** Rejected: a reader could not tell an omitted
  field from a real value. The codec still accepts a bare `<omitted>` value as genuine text,
  because an ordinary configured value can equal the marker. The notice, not the marker, is
  what says a value was omitted.
- **A single truncated flag on the snapshot.** Rejected for the snapshot and rows, because
  it cannot name the field. The unknown-event record keeps its boolean for compatibility.
- **Raise the frame cap instead.** Rejected: the source text stays unbounded, so the failure only moves.

## Consequences

- Text over a cap now arrives shortened or omitted with a notice, where it previously
  arrived whole or made the frame fail. Clients must read the notices.
- The v2 wire gains one required key, `displayNotices`, on the snapshot, the four
  row types and the upstream probe. No shipping v2 socket exists, so no compatibility
  shim is needed. The v1 wire is unchanged.
- Sizes, for one measured maximum-text sample and its computed text lower bound (the
  checkpoint has the exact figures): the snapshot's text is about 46 KB by computation, and
  the measured maximum-text snapshot frame is 48,735 bytes. The widened-metadata baseline is
  49,376 bytes including its line feed. These are not universal maxima. An owner reply cap and
  collection capacity must hold the widened figure. That is a later decision, not made here.
- Work is bounded by counts, not timed. Each field is read at most through the 16 KiB input
  gate. An owner turn projects at most the caller's row budget (`ControlRowBudget.maxRows`)
  of rows, each with its fields. No separate CPU deadline exists in this slice, and no time
  bound is claimed. Two URL-dense probes in the experiments directory observed about 39 to 42 ms
  for a cold update of fourteen 16 KiB fields, and 45 to 78 ms for two more. These are single
  local observations, not percentiles or a deadline.

## Invariants and verification

- Every projected display string is at most its cap in UTF-8 after redaction.
- Redaction precedes every cut, and no input over 16,384 bytes is cut. For the credential
  forms the sanitizer's grammar recognizes, no part of the secret survives the cut. Other
  secret forms are not promised redacted.
- Each notice names one owner's field, appears once and in canonical order, and
  names a value that is present. An `omitted` notice names the marker.
- The encoder never publishes, and the decoder never accepts, a value over its cap or a malformed notice array.
- Stable IDs, enum facts, counts, totals and command inputs are unchanged by the projection.

Tests: `ControlDisplayTextTests` (a seeded Character-prefix model that shares no loop with
the production path, named Unicode edges, the input gate, and credential witnesses at the
512, 1,024 and 16 KiB cut points, limited to the grammar-recognized forms),
`RuntimeDisplayBoundsProjectionTests` (caps, input gate, rows, the published DNS-host branch,
probe, stable facts, secret cut points, the maximum-text records measured through the Bridge
and the codec, and a widened-metadata baseline checked against the measured reference
overhead), and `ControlDisplayNoticeCodecTests` (exact frame limit, decode
refusals including an over-count array refused before its extra element, encode refusals,
and the other displayed records). Updated tests: `RuntimeSnapshotProjectionTests` and
`RuntimeServiceTransportTests` now test a real frame limit rather than a value the policy
shortens, and `RuntimeServiceReplayTests` uses the largest probe the policy admits (name and
endpoint at their caps, NUL) so the oversize outcome keeps its mechanism. The headless
scenario is `pm-sim runtime-display-bounds`. A failure of any invariant above disproves the record.

## Implementation evidence

Partial. The shared policy and the codec are in
[`ControlRuntimeDisplay.swift`](../../Sources/ConduitShared/ControlRuntimeDisplay.swift),
[`ControlDisplayPolicy.swift`](../../Sources/ConduitShared/ControlDisplayPolicy.swift) and
[`ControlDisplayRecordCodec.swift`](../../Sources/ConduitShared/ControlDisplayRecordCodec.swift).
The records and the sizing are in
[`ControlRuntimeSnapshot.swift`](../../Sources/ConduitShared/ControlRuntimeSnapshot.swift),
[`ControlRuntimeCollections.swift`](../../Sources/ConduitShared/ControlRuntimeCollections.swift),
[`ControlRuntimeCommands.swift`](../../Sources/ConduitShared/ControlRuntimeCommands.swift) and
[`ControlRuntimeSizing.swift`](../../Sources/ConduitShared/ControlRuntimeSizing.swift). The
projection is in
[`RuntimeSnapshotControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeSnapshotControlProjection.swift).
The v2 probe mapping, [`RuntimeProbeControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeProbeControlProjection.swift),
is unadopted: no owner adapter calls it. The verification record and measured sizes are in
[the checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md#display-text-bounds-decision-0029-local-2026-10-25).

Verification status: the focused wrapper passed on its second run, 357 tests with 0 failures,
before the final allocation fix. After the final source fix, 28 targeted tests pass, and the
release probes in [the experiments directory](../experiments/runtime-display-codec/README.md)
show the scalar snapshot path flat across 101 unpooled updates (+16 B). The full 40-check
workflow is running and is not complete, and independent review is pending.

Does not prove: the owner's shipping profile; any frame, retention or deadline value;
host or store adoption; known-event detail bounds or redaction; the v1 probe text;
RSS behaviour; the row path's allocation; any time bound for URL-dense fields; a universal
memory bound; a real VPN or installed build. Numeric widths are covered only by the one
widened-metadata baseline shape.

## Open questions

- The reply/stream ceiling is now selected in [0030](0030-ordinary-runtime-reply-frame-cap.md). Remaining shipping profile: collection capacity, retention and
  deadlines, sized against the measured widened baseline (49,376 bytes including its line feed)
  and the measured maximum-text rows. This is an owner gate.
- Known-event `kind`, `event` and `detail` have no display bound or redaction in the
  Bridge. They belong to the event-adoption slice.
- The v1 `ControlUpstreamTestResult` keeps raw probe text, by design of the legacy wire.
