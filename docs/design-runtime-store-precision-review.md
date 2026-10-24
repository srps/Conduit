# Verified store precision checkpoint

Date: 2026-10-24. **Owner selected schema2 with explicit refusal of inexact saves; implementation is partial on branch `codex/bounded-configuration-files` and not merged.** See [decision0023](decisions/0023-exact-schema-two-persistence.md). Prepared by Codex with an independent read-only Claude Code review using the owner's claude.ai Max subscription. Tracks [#224](https://github.com/srps/Conduit/issues/224) and the store phase of [#186](https://github.com/srps/Conduit/issues/186).

Current implementation checkpoint: exact file staging, whole-millisecond correction,
finite/range checks and the thin app save gate initially passed 440 focused tests.
The integrated boundary suite passed 697 focused tests and 2846 full-suite tests
(two skips); see the [verification record](verification-configuration-boundary-2026-10-24.md). This
is not the asynchronous verified store: physical read-back, component revisions,
lease adoption and complete Stop/Quit fencing remain pending.

## Why this choice is needed

The selected save-before-apply policy requires runtime input equal to verified persisted intent. The existing schema 2 stores two health durations in integer units, although the in-memory model and selected private request use Double seconds:

| Input accepted by today's domain validator | Actual scratch save/load | Implication |
| --- | --- | --- |
| Probe timeout 1.001 seconds, from 1001 ms | 1.0 seconds | Reachable UI rounding bug; fix routine integer-unit conversion. |
| Direct-cache TTL 90.5 seconds | 60 seconds | Legacy integer-minute format cannot represent this exact intent. |

Codex executed both cases through the actual `ProxyConfigPersistence` in an owned scratch process. No installed config was inspected or changed. The runtime's legacy getters use the same integer units, so fixing file output alone is insufficient. The 1001 ms case does not imply every subsequent save loses another millisecond:1000ms is representable exactly in this example.

Separate source review found nonfinite/huge-duration validation gaps and unsafe integer conversions, plus missing upstream-port checks. These need ordinary boundary safety fixes before adoption, regardless of the precision decision. No arbitrary product-duration ceiling is selected by this draft. Wire requests keep canonical seconds and no generic Codable conformance.

## Selected policy: preserve schema 2 and refuse inexact ordinary saves

Fix representable integer-millisecond round trips and conversion safety. Before writing, stage the exact file encoding and decode it through the same format, then require equality with the frozen input for the required runtime fields. If the format cannot reproduce the value, refuse explicitly with a field code before any write or runtime admission. A 90.5-second TTL would receive that error. Stop/Quit still proceed independently of save failure.

This chooses compatibility with current file readers and UI units while keeping the future daemon store's contract exact. The store owns representability; the private codec and RuntimeHost do not round or silently normalize. Later schema evolution remains behind this boundary, so clients, receipts and host APIs need not change.

Cost: some values accepted by today's broad in-memory validator would be refused for an ordinary committed update, although today's file format already changes those values silently. This is an explicit compatibility/behavior decision, not merely a codec implementation detail.

## Alternatives considered

| Option | Benefit | Cost and compatibility |
| --- | --- | --- |
| **A: schema 2 with exact representability check (recommended now)** | No format migration; current settings units remain meaningful; verified intent is honest. | Sub-millisecond probe timeouts and fractional-minute TTL cannot be committed. Other seconds-based fields retain their existing precision. |
| **B: schema 3 with canonical seconds for both fields** | Aligns disk, domain and future daemon request;90.5 seconds can persist exactly. | Requires a migration and explicit rollback story: schema 2 releases refuse schema 3 at their checked load boundary. All import/load paths must enforce that gate; plain JSON decode currently has a bypass in app import. |
| **C: explicit caller-visible normalization before commit** | Can keep schema 2 while allowing users to enter arbitrary precision. | Adds editor/client confirmation state and changes the requested intent. Silent normalization would violate the selected exact-input contract. No such confirmation flow exists today. |
| **Dual keys under schema 2** | Appears compatible. | Old named-key decoders silently consume lossy legacy values, or use defaults if those keys are absent. It cannot preserve exact semantics for old readers and is not recommended. |

Schema3 need not change UI labels/units: exact whole milliseconds and minutes can remain the editor defaults while the file stores seconds. A seconds UI is a separate product decision, not an automatic consequence of B. Likewise, adding the writer lease does not itself require a schema migration; combining upgrade barriers is optional planning, not a prerequisite.

## Revisit and future work

If A is selected, revisit for a demonstrated requirement for sub-millisecond probes, fractional-minute cache TTL, or a broader deliberate schema upgrade. Evaluate B then, with migration/rollback fixtures and every reader/import path inventoried. No global registry or snapshot history is involved. Keep exact-input receipts and independent persistence/admission outcomes in either shape.

Before affected store adoption: fix duration/port boundary safety, reproduce stable whole-unit round trips, implement the selected representability policy, exercise read-back ambiguity/partial components/late completions against an independent model, and prove Stop/Quit fences and writer quiescence. Codec memory/capacity/latency verification is a separate adoption gate; this precision choice does not change the 8 MiB frame cap.

## Review provenance and limits

Claude's review was read-only and did not execute the probes. Codex verified the actual conversion, persistence and schema-gate source. The owner subsequently selected optionA. No schema3 migration, normalization UI, async store or new receipt authority is claimed.
