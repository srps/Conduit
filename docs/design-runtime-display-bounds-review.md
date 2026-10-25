# Runtime display text: owner review

Status: selected by the owner on 2026-10-25 (#186: "Bound display text with explicit notices (Recommended)") and recorded as [decision 0029](decisions/0029-bound-runtime-display-text.md). Implemented locally on the v2 wire (partial): caps, input gate, notices and codec checks. Not implemented: store, client and host adoption, and the v2 probe owner. No shipping frame, retention, queue or deadline profile is selected. The proposal text below is the record of the options; where it says "proposed", the selection above governs.

The ordinary v2 snapshot/row/probe bridge sanitizes display strings but does not cap them.
A finite frame therefore cannot promise to deliver every otherwise valid view.
Configuration bounds do not solve all of this: kernel/OS diagnostic strings have no selected text ceiling,
and JSON escaping expands raw UTF-8. Existing `ControlDisplayText.bounded` already supplies redaction then a character-boundary cut.

## Proposed policy

| Item | Proposal |
| --- | --- |
| Configuration-derived display names | At most 1,024 UTF-8 bytes after redaction |
| Diagnostic display text and endpoint labels | At most 512 UTF-8 bytes after redaction; existing stricter host grammars remain |
| Sanitizer input work | Refuse inputs over 16 KiB to a fixed redacted omission marker before regex/copy-heavy sanitization |
| Disclosure | A bounded, typed list names each shortened or omitted display field and its treatment |
| Semantic values | Preserve stored configuration, command inputs, stable IDs, enum facts, counts and collection totals exactly |
| Encoded size | Continue enforcing actual codec/frame and retained-payload bounds; measure the completed worst-case view before selecting shipping limits |

Use one shared display policy at the projection boundary. Keep persistence and the private configuration request unchanged.
Do not cut raw input before secret redaction. An input above the sanitizer work cap is replaced wholly,
so an incomplete credential or URL query cannot survive as a prefix.
The metadata has a finite closed field set and no arbitrary keys; per-row notices stay with that row.
Known event names and typed semantic payloads are not shortened into different facts.
Existing bounded ingress/loss rules still govern events; this proposal concerns display fields.

## Alternative

Keep full display strings and explicitly refuse snapshots or rows that exceed their byte budget.
This avoids shortening and new notice metadata, but one long diagnostic can make the current status unavailable.
Increasing the frame alone postpones the failure because the source text remains unbounded.

Claude and Codex recommend the bounded display policy for the future daemon/client boundary.
It keeps control facts usable and tells clients exactly which display text is incomplete.
It does not create another configuration acceptance limit or change saved intent.

## Evidence and next gate

The actual bridge/codec samples include eight 513-byte scalar fields: the escaped snapshot payload is
8,890 bytes and its worst-metadata baseline frame is 9,193 bytes; the plain twin is 5,698/6,001 bytes.
These are measured points, not a maximum. An all-NUL profile demonstrates six encoded bytes per raw byte:
1,024 raw bytes need 6,144 encoded string-content bytes, excluding the JSON quotes.
The exact measurements, source trace, fixture and exploration limits are in
[the service checkpoint](runtime-service-engine-checkpoint-2026-10-25.md#text-inventory-no-implementation-owner-decision-needed).

The owner has selected the policy, and it is recorded as [decision 0029](decisions/0029-bound-runtime-display-text.md). It is implemented through the shared helper, and the populated scalar fields and notices are measured with actual codec framing in the checkpoint. The frame and retention profile is still reviewed separately, and no shipping value is selected by this draft.
Revisit on new display fields, altered redaction/encoding, or measured views beyond the selected envelope.

The completed widened baseline measures 49,376 bytes including its line feed. The owner subsequently selected 64 KiB replies/stream frames in [0030](decisions/0030-ordinary-runtime-reply-frame-cap.md). The remaining shipping profile and actual-host scheduling/latency are still separate gates. [Final verification](verification-runtime-display-2026-10-25.md).
