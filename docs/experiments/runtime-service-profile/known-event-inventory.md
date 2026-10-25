# Known-event inventory for the candidate profile (read-only, 2026-10-25)

Read-only evidence for the `maxEventBytes` decision. It adds no runtime event name, no producer, no legacy truncation and no catalogue
decision. Names are governed by `docs/events.md` and `scripts/check-event-catalogue.py`. That check passed in the current run and reported
"catalogues all 218 event names in product sources, and nothing more".

Sources read: `Sources/ConduitShared/ControlRuntimeEventTyped.swift`, `ControlProtocol.swift` (`ControlRuntimeEvent`),
`ControlRuntimeDisplay.swift` (`ControlUnknownEventDisplay`), `ControlRuntimeEventRecord.swift`.

## Two different kinds of size guarantee

- **Finite cap with explicit loss.** An event larger than `maxEventBytes` is not sent. The existing oversize path records it as an observation
  loss, and the stream reports the loss. Nothing is silently truncated. This bounds memory and frame size, but it does not stop events from
  being lost. The candidate's loss-on-oversize behaviour is already selected, and this inventory does not change it.
- **Loss-free producer bound.** Every producer is shown to emit events no larger than the bound, so the bound never causes loss. This
  inventory does **not** establish that for legacy events, and it does not claim it for any family.

## Families

| Family | Shape | Size guarantee at the type | Status for `maxEventBytes = 8,192` |
| --- | --- | --- | --- |
| Typed lifecycle (`ControlTypedRuntimeEvent.lifecycle`, four names: `lifecycle.superseded`, `lifecycle.coalesced`, `lifecycle.termination_drain_expired`, `lifecycle.version_changed`) | Closed enum payload. The human detail is derived from the typed values. Operation and reason are closed enums. The version text is bounded by `maximumVersionBytes = 59`. | Finite by construction. Its largest encoded size has not been measured through the Bridge and ingress. | Finite cap. Not measured here, so no loss-free claim. |
| Legacy known (`ControlRuntimeEvent`, a public struct: `kind`, `event`, `detail: String?`, optional `typed`) | Free text. | **None at the type.** `detail` is a plain stored `String?`, and nothing bounds or redacts it there. | Not finitely bounded. A `maxEventBytes` of 8,192 is a candidate choice, not a proven maximum, and it cannot be a loss-free bound until producers are audited. Oversize events would be lost, and the loss is explicit. |
| Unknown name (`ControlUnknownEventDisplay`) | Free text for a name this build does not define. | `kind` 64 bytes, `event` 128 bytes, `detail` 512 bytes, through `ControlDisplayText.bounded`, with a `truncated` flag. | Finite by construction. This is the display path for unknown names, not the known-event path. |

## What this supports

- The 8,192-byte `maxEventBytes` is **provisional**. Its finite cap and its explicit loss path are the selected behaviour. It is not a
  loss-free bound for legacy events, because the legacy `detail` has no finite bound at its type.
- No claim is made about event-loss storms or the rate of oversize events. Producer redaction of legacy `detail` is not audited here.
- Bounding legacy `detail`, or moving it to typed values, is a product decision and is outside this stage.

## Gaps

- No largest bounded typed-lifecycle fixture has been run through the actual Bridge and ingress. That is the next small witness, and it
  needs a separate authorization before it runs.
- No legacy known-event fixture was run at any size. The legacy path has no finite bound to choose one.
- Smallest boundary witnesses would reuse existing names and grammar. None were added here.
