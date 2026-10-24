# 0024: Strict syntax and Unicode throughout configuration files

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 strict file-preflight checkpoint)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Decisions [0021](0021-bounded-configuration-at-all-boundaries.md) and
[0022](0022-configuration-identity-path-and-host-bounds.md) require bounded reads
and preflight before typed expansion, preserving valid unknown fields and the
first occurrence of a known key. The current Foundation decoder defers validation
of ignored string contents. An actual `ProxyConfigPersistence.decode` witness
accepted malformed escapes, invalid UTF-8, raw controls and a lone surrogate in
an ignored value. The [synthetic sources and results](../experiments/config-file-preflight/README.md)
record what was executed and its limits.

The owner selected **"Strict syntax and Unicode throughout (Recommended)"** in
#186's file-preflight checkpoint. This clarifies grammar acceptance alongside
0022's retained unknown-field and first-key behavior; it does not replace those
choices.

## Decision

Require valid JSON syntax, valid UTF-8 and valid Unicode scalar escapes throughout
the runtime configuration input, including ignored unknown values and later
duplicate values. Reject raw string controls, invalid escapes, unpaired surrogates
and invalid UTF-8 before typed decode. Preserve the original rejected file; do not
repair, truncate or silently rewrite it.

Valid unknown fields remain ignored. The first known key still wins, including
escaped spellings of that same key. Later values must have valid grammar but do
not consume domain-field resource budgets because they are discarded before
object expansion. The physical input cap still includes all bytes.

Share strict lexical primitives with the private request scanner. Format-specific
schemas, unknown-key handling and duplicate policy remain separate: private wire
keys are strict, required and duplicate-free. Avoid a second permissive lexical
mode maintained only to emulate Foundation's ignored-value quirks.

An ignored `1e400` is syntactically valid JSON and remains accepted without
conversion to a Double. Known typed numeric fields keep their finite/range checks.
This choice introduces no new file schema, duration precision, sidecar/journal
byte cap or domain resource ceiling.

## Alternatives

- **Preserve deferred validation for ignored contents:** retains every witnessed
  acceptance quirk, but requires a separate parsing contract and differential
  maintenance against Foundation implementation behavior. Not selected.
- **Feed ignored subtrees into Foundation:** retains decoder behavior while
  permitting dense unknown objects to expand before they are discarded; fails
  the selected early-allocation requirement.
- **Reject unknown or duplicate keys outright:** simplifies the file schema but
  abandons the compatibility selected in0022. Not selected.
- **Silently sanitize malformed ignored content:** changes the file without
  explaining the repair and makes acceptance depend on whether a field is known
  in a particular release. Not selected.

## Consequences

Files that loaded only because malformed ignored contents were never inspected
will now fail explicitly at startup, reload and import. Their bytes remain intact
for repair. Valid legacy files keep their unknown-key and duplicate behavior.
The file and private boundaries share one lexical contract, with their respective
schemas responsible for representation differences.

Revisit an explicit repair/import mode only for a demonstrated recovery need.
It would require a separate owner choice and tests for what is changed; it must
not become an automatic fallback or a second ordinary runtime path.

## Invariants and verification

Drive actual startup, reload, import and argv-input adapters. Cover malformed
unknown values and later duplicates, invalid UTF-8, controls, escape pairs, valid
unknown huge exponents, first-key behavior and escaped duplicate keys. Verify
refusal before typed expansion or migration writes, preservation of original
bytes, and one authoritative resource policy. Pin legacy depth behavior against
the actual decoder; the private schema's depth-eight bound is not a file limit.

## Implementation evidence

[JSONByteCursor.swift](../../Sources/ConduitShared/Grammar/JSONByteCursor.swift)
provides one strict lexical contract, shared by the private scanner and the
[RuntimeFileFilter.swift](../../Sources/ProxyKernel/Support/RuntimeFileFilter.swift)
file adapter. The filter discards unknown and later duplicate values before typed
expansion, validates their complete grammar, and maps known fields through
[RuntimeFileSchema.swift](../../Sources/ProxyKernel/Support/RuntimeFileSchema.swift)
to the shared resource policy. Its retained bytes enter one typed document decode.

[RuntimeConfigurationFileReader.swift](../../Sources/ProxyKernel/Support/RuntimeConfigurationFileReader.swift)
bounds actual reads at 8 MiB. [ProxyConfigPersistence.swift](../../Sources/ProxyKernel/Support/ProxyConfigPersistence.swift)
adopts the gate for load, migration and import; legacy components use the same
frozen document. AppState import checks the schema before editor assignment, and
pm-proxy argv input uses the same format gate. Candidates are staged before
migration writes. Rejected source bytes are preserved.

[ConfigurationFileBoundaryTests.swift](../../Tests/ConduitTests/ConfigurationFileBoundaryTests.swift),
[ConfigurationFileGateTests.swift](../../Tests/ConduitTests/ConfigurationFileGateTests.swift),
[ConfigurationFileReaderTests.swift](../../Tests/ConduitTests/ConfigurationFileReaderTests.swift),
[BoundedJSONByteCursorTests.swift](../../Tests/ConduitTests/BoundedJSONByteCursorTests.swift),
the AppState harness and `pm-sim config-file-boundary` exercise these adapters.
They pin escaped duplicate keys, malformed ignored values, valid ignored huge
exponents, resource parity, the actual decoder's depth boundary and unchanged
rejected originals. See the [combined verification record](../verification-configuration-boundary-2026-10-24.md).

This implements runtime-file grammar, not a new sidecar/journal grammar or cap.
Does not prove: owner/real-machine startup validation, global working-memory bounds,
writer admission or release readiness.

## Open questions

None for this grammar choice. Reader and parser APIs remain implementation review
items under the selected module ownership.
