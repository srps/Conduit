# 0021: Bound configuration resources at update and startup boundaries

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 configuration resource profile checkpoint)
- Implementation: planned
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

None yet for this refined policy. The existing local codec/probes motivated the
choice but do not enforce these domain/startup limits or global admission.

Does not prove: exhaustive working-memory maxima, real-machine behavior, writer
coverage, control responsiveness or complete startup/import boundary enforcement.

## Open questions

The field inventory is completed by accepted [0022](0022-configuration-identity-path-and-host-bounds.md); its implementation remains planned. Persistence precision/schema policy in #224 is
separate and unselected. Revisit resource ceilings for a demonstrated supported
workflow, measured supported-case memory failure, or a changed matching/listener
model. A changed compatibility/capacity policy needs a new record. Later daemon
peer admission and total shutdown validation remain adoption gates.
