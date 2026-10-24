# 0021: Bound configuration resources at update and startup boundaries

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 configuration resource profile checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: 0019
- Superseded by: none

## Context

Decision [0019](0019-private-configuration-frame-budget.md) bounded the complete
private frame at eight MiB but retained the prior startup validator and selected
no collection limits. A synthetic valid 8,102,178-byte request with 2.7 million
empty DoH entries reached 574,554,112 bytes whole-process peak RSS while the probe
retained all pipeline forms. The owner explicitly rejected such a supported
shape and selected domain limits and startup enforcement in
[#186](https://github.com/srps/Conduit/issues/186). Claude reviewed the policy on
the owner's verified claude.ai Max subscription; Codex reviewed source and probes.
The [bounds review](../design-runtime-configuration-bounds-review.md) records
alternatives and measurement limits. The peak is neither disk usage nor a
prediction of the running app's footprint.

## Decision

Retain one private frozen configuration request and the complete **8,388,608-byte
frame cap**, including framing/envelope, from 0019. No chunks or snapshot registry.
Keep v1's 16KiB cap and leave ordinary v2 observation/page limits separate.
Use one global active private body/decode, with independent work and capacity for
Stop/status. Refuse busy input before reserving another complete body. Batched
transport and off-owner parsing must also bound work, not just collection size.

Apply this fixed domain-resource profile to ordinary updates, import and startup:

| Resource | Hard ceiling |
| --- | ---: |
| DoH providers | 8 |
| DNS servers per domain entry | 8 |
| Upstream proxies | 32 |
| Configured tunnel definitions | 128 |
| DNS domain entries | 256 |
| DNS intercept rules | 256 |
| Allowed proxy clients | 256 |
| Forced-proxy patterns | 256 |
| Bypass patterns | Existing 256-entry, 253 UTF-8 byte/entry, 8192 encoded-byte bounds |
| Display text/profile labels | 1024 UTF-8 bytes |
| Private URL values | 16384 UTF-8 bytes |
| Runtime configuration file read | 8,388,608 bytes |

Tunnels are local native-protocol forwards, such as MongoDB/Postgres, not active
connections. Use 64 definitions as the primary performance case and verify up
to double that: 128 is the hard ceiling. Disabled definitions count too.
Retain stricter existing domain/address grammars. Inventory all remaining
identity/path/string/array fields before claiming complete coverage; this record
does not silently select arbitrary new semantic caps for uncovered fields.

Share neutral resource policy across boundaries without importing control DTOs
into ProxyKernel. Count decoded UTF-8 bytes for escaped JSON strings and physical
bytes independently for frame/file budgets. Reject over-limit array/string input
before generic JSON materialization or typed DTO construction. Bound actual file
reads, including growth during a read, rather than relying on stat metadata.
Preserve legacy file migration and unknown-field compatibility where possible
with bounded scanning; bring a required compatibility change back for a decision.

Ordinary over-limit updates fail explicitly before saving/admission. Startup
refuses an over-limit file with a bounded field/limit diagnostic and preserves
the original bytes: no truncation, auto-rewrite or silent removal of definitions.
Stage validation before migration writes. Keep save-before-apply, exact component
receipts, and Stop/Quit exceptions from 0015; a deadline cannot release a physical
write or its writer authority. Keep private values out of ordinary events/status.

## Alternatives

- **Frame-only cap and post-decode validation:** dense small values expand into
  many objects before refusal, as the unsupported stress probe demonstrated.
- **Optimize packed storage for millions of endpoints:** unsupported product
  shape; first measure the selected useful configurations and release temporary
  representations promptly.
- **Grandfather oversized startup files:** preserves prior acceptance but bypasses
  the resource policy and retains the allocation/runtime risk. Owner chose
  startup enforcement with preservation and an explicit error.
- **Ignore oversized disabled features:** still reads/materializes unsupported
  input and creates lossy round trips. A bounded editor/recovery workflow can be
  considered separately.
- **Chunking:** bounds individual transport buffers but adds reassembly state and
  does not remove decoded configuration memory. Separate control capacity and a
  bounded complete request remain selected.
- **4096 forced-proxy patterns / 16 upstreams:** lack of matcher evidence favors
  256 patterns; the owner's current 11 upstreams supports 32 for useful headroom.
- **2048-byte private URLs:** the helper's machine autoproxy limit uses Swift
  characters and a different contract; it is not a general private URL budget.

## Consequences

Some files previously accepted at startup will now be refused, but preserved for
recovery. Entry/byte limits constrain accepted shape; eight MiB is not an RSS cap.
During a transfer the original, wire and decoded forms can overlap. Release them
as each stage finishes and measure supported worst cases before adoption. A
provider count limit does not establish a global DNS HTTP-attempt budget or pick
scheduler semantics. Listener/connection/runtime memory remains separately bound.

## Invariants and verification

Test exact-limit and one-over cases for every field, escaped/multibyte strings,
malformed/unknown large values, and stage witnesses proving refusal precedes
Foundation typed decode. Verify actual bounded reads under growth, import/load
parity, legacy migration, and unchanged rejected files. Measure release sender
and receiver lifetimes with 64 and 128 tunnel definitions; distinguish idle
configuration storage from temporary update cost and active runtime resources.
Test busy peers without allocating N bodies and independently exercise Stop/status
responsiveness during transfer/decode/save. Model capacity/supersession against
production code as the engine is introduced. Do not call a codec-only test proof
of global admission, physical write quiescence or running-app memory.

## Implementation evidence

Runtime file adoption is implemented in
[ProxyConfigPersistence.swift](../../Sources/ProxyKernel/Support/ProxyConfigPersistence.swift):
load/reload, migration, import and pm-proxy argv input share a bounded regular-file
reader and schema-aware filter. Known field checks precede typed expansion; unknown
and later duplicate values retain strict grammar through the shared lexical cursor.
Legacy extraction reuses one frozen document and stages candidates before writes.
[ConfigurationFileBoundaryTests.swift](../../Tests/ConduitTests/ConfigurationFileBoundaryTests.swift),
[ConfigurationFileGateTests.swift](../../Tests/ConduitTests/ConfigurationFileGateTests.swift)
and [ScenarioConfigFileBoundary.swift](../../Sources/pm-sim/ScenarioConfigFileBoundary.swift)
cover refusal and original-byte preservation. See the
[combined verification record](../verification-configuration-boundary-2026-10-24.md).

Partial, for the private request boundary and the kernel's typed check only:

- Scanner count, item, and aggregate bypass-width checks, and the token guard: [PrivateJSONScanner.swift](../../Sources/ConduitShared/PrivateConfiguration/PrivateJSONScanner.swift). The shared ceilings and the canonical width counter are in [DomainResourceLimits.swift](../../Sources/ConduitShared/DomainResourceLimits.swift).
- Typed checks over the private request and over `ProxyConfig`: [PrivateConfigurationResourceCheck.swift](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationResourceCheck.swift) and [ConfigResourceLimits.swift](../../Sources/ProxyKernel/Models/ConfigResourceLimits.swift).
- Tests: [ConfigurationResourceCanonicalWidthTests.swift](../../Tests/ConduitTests/ConfigurationResourceCanonicalWidthTests.swift), [ConfigurationResourceLimitsTests.swift](../../Tests/ConduitTests/ConfigurationResourceLimitsTests.swift), [PrivateConfigResourceReviewTests.swift](../../Tests/ConduitTests/PrivateConfigResourceReviewTests.swift), and [PrivateConfigGrammarDifferentialTests.swift](../../Tests/ConduitTests/PrivateConfigGrammarDifferentialTests.swift).
- Headless scenario: [ScenarioConfigResourceBounds.swift](../../Sources/pm-sim/ScenarioConfigResourceBounds.swift).
- Codec notes: [private-configuration-codec.md](../private-configuration-codec.md), "Canonical bypass width and token guard".

"Encoded bytes" means the default output of `JSONEncoder`, counted without a buffer. The app's `ProxyBypassSyntax` uses the shared canonical byte counter, and tests pin it to the same boundary.

Sidecar adoption is implemented under [0026](0026-bounded-platform-and-preferences-files.md):
platform/preferences inputs share the file gate and their 128 KiB cap; raw browser-URL
checks precede fallback and typed decoding. See
[ConfigSidecarBoundaryTests.swift](../../Tests/ConduitTests/ConfigSidecarBoundaryTests.swift)
and the [sidecar verification record](../verification-config-sidecar-boundary-2026-10-24.md).

Remaining: global private-body admission;
supported-case memory/latency; writer coverage and Stop/status responsiveness.
Does not prove: complete all-boundary enforcement,
working-memory maxima, actual write quiescence or real-machine behavior.

Runtime-file replacement read-back (2026-10-24): the package `ConfigurationFileReader.read(at:limit:)` lets the verified replacement's pre-read and read-back use the same reader, with the approved 8 MiB ceiling as the pre-read limit. The read-back limit is `max(staged length, observed prior length)`, and the reader adds its single probe byte. A larger unchanged prior therefore reads back in full after a failed write. The replacement primitive is unwired: no startup, host, AppState or store path calls it. Sidecar physical budgets and writer-lease adoption at startup and in the journal remain separate, and the replacement adds no sidecar cap. See [the verification note](../verification-runtime-file-replacement-2026-10-24.md).

## Open questions

The field inventory is completed by accepted [0022](0022-configuration-identity-path-and-host-bounds.md); its implementation is partial. Persistence precision/schema policy in #224 is
selected in [0023](0023-exact-schema-two-persistence.md) and implemented locally; store adoption remains separate. Revisit resource ceilings for a demonstrated supported
workflow, measured supported-case memory failure, or a changed matching/listener
model. A changed compatibility/capacity policy needs a new record. Later daemon
peer admission and total shutdown validation remain adoption gates.
