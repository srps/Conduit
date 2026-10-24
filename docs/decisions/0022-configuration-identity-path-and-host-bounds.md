# 0022: Complete identity, path and host configuration bounds

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 resource-profile completion checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0021](0021-bounded-configuration-at-all-boundaries.md) selects collection/display/
URL/file bounds and startup enforcement, leaving other field categories for an
inventory. Claude's source review found authentication identity strings and an
audit path without bounds, plus host/address fields whose validation did not
bound raw stored UTF-8. Codex verified synthetic Foundation behavior: duplicate
known keys decode the first value, unknown fields are ignored, a Double1e400 is
refused, and finite1e300 is accepted. Darwin's PATH_MAX is1024. The owner selected
the completion profile in [#186](https://github.com/srps/Conduit/issues/186).

## Decision

Complete the neutral configuration resource policy with these raw UTF-8 ceilings:

| Field category | Hard ceiling |
| --- | ---: |
| Authentication username/domain/workstation, each |1024 bytes |
| Audit path |1023 bytes |
| Host/domain/address values, each |253 bytes |
| DNS intercept pattern with leading `*.` |255 bytes |

Existing stricter domain/IP/bypass grammars remain in force. Resource bounds
apply even when disabled or when whitespace would later be trimmed. The
intercept allowance includes the two-byte prefix and preserves a253-byte domain.
Allowed-client items get a byte bound without adding an IP-only semantic
restriction. Keep the selected URL ceiling for URL-valued preferences too.
The path ceiling is a resource policy based on PATH_MAX including its terminating
NUL, not a guarantee that every relative/expanded path below it is usable.

Preserve ignored unknown legacy file fields and the existing first-duplicate-wins
behavior for known keys by bounded grammar scanning/filtering before generic
typed decoding. Keep private wire keys strict, required and duplicate-free.
Skip unknown file values iteratively within the physical input budget; do not
impose the private schema's depth-eight bound on arbitrary ignored legacy values.
Any scratch stack itself has a fixed ceiling derived from the8MiB input bound.
Do not materialize unknown objects/arrays in Foundation before discarding them.

This adds no scalar execution-capacity maxima, general duration product ceilings,
new forced-proxy aggregate byte cap, new file schema or precision policy.
Required finite/checked conversions and NTLM wire-length guards are boundary
safety obligations, separate from #224's unselected persistence-precision choice.

## Alternatives

- **Treat identities as display labels implicitly:** hides the contract. Name the
  category explicitly and still guard the actual encoded NTLM wire lengths.
- **Use only the NTLM UInt16 field ceiling:** technically bounds one protocol's
  representation but leaves unnecessary large identity strings in configuration.
- **Apply IP-only client allowlists:** changes existing semantics beyond resource
  bounds; not selected.
- **Use253 bytes for the entire wildcard intercept pattern:** unnecessarily cuts
  the available domain length by the prefix size.
- **Strict unknown/duplicate refusal for legacy files:** makes scanning simpler
  but changes acceptance; the owner selected compatibility-preserving filtering.
- **Pass unknown subtrees through to JSONDecoder:** preserves value behavior but
  still permits dense unknown objects to expand before being ignored.
- **Use the private depth bound on unknown legacy values:** changes acceptance;
  iterative bounded skip avoids that requirement.

## Consequences

The resource profile now names all string categories identified by the inventory.
Previously accepted oversized values are refused with original files preserved,
as0021 selects. The bounds do not establish valid credentials, endpoints or file
paths, and do not replace domain validation. Filtering creates a temporary known-
field byte representation; document its lifetime and private-copy limitations.
No new helper IPC or control DTO dependency in ProxyKernel is introduced.

## Invariants and verification

Test exact-limit and one-over values for every category, raw whitespace,
multibyte/escaped lengths, disabled entries, and wildcard prefix accounting.
Exercise first-key behavior with invalid/oversized later duplicate values,
unknown large arrays/deep structures, malformed skipped JSON and legacy platform/
preference extraction. Refusal and filtering precede Foundation typed allocation.
Bound actual reads and scratch buffers, preserve rejected files, and test parity
across startup/import/in-memory/private boundaries. Fixed errors do not echo values.

## Implementation evidence

Partial: the private request boundary and the kernel's typed check enforce the identity, host, path, and allowed-client ceilings on their own values, under the same ceilings as [0021](0021-bounded-configuration-at-all-boundaries.md).

- Ceilings and width counter: [DomainResourceLimits.swift](../../Sources/ConduitShared/DomainResourceLimits.swift). Scanner: [PrivateConfigurationDecoder.swift](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationDecoder.swift).
- Typed checks: [PrivateConfigurationResourceCheck.swift](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationResourceCheck.swift) and [ConfigResourceLimits.swift](../../Sources/ProxyKernel/Models/ConfigResourceLimits.swift).
- Tests: [ConfigurationResourceLimitsTests.swift](../../Tests/ConduitTests/ConfigurationResourceLimitsTests.swift), [ConfigurationResourceCanonicalWidthTests.swift](../../Tests/ConduitTests/ConfigurationResourceCanonicalWidthTests.swift), [PrivateConfigResourceReviewTests.swift](../../Tests/ConduitTests/PrivateConfigResourceReviewTests.swift), and [PrivateConfigGrammarDifferentialTests.swift](../../Tests/ConduitTests/PrivateConfigGrammarDifferentialTests.swift).
- Codec notes: [private-configuration-codec.md](../private-configuration-codec.md), "Canonical bypass width and token guard".

Does not prove: legacy file filtering, load, or import; startup refusal with preserved bytes; runtime admission; steady or runtime memory; Stop/status fairness; actual write quiescence; or real-machine behavior. No owner or real-machine validation is claimed.

Partial protocol-boundary safety: [NTLMAuth.swift](../../Sources/ProxyAuth/NTLMAuth.swift)
checks transformed Type1 and Type3 field lengths before narrowing to UInt16 and
before crypto or offset construction. The fixed error does not echo identities.
[NTLMIdentityLengthTests.swift](../../Tests/ConduitTests/NTLMIdentityLengthTests.swift),
[NTLMProtocolLengthReviewTests.swift](../../Tests/ConduitTests/NTLMProtocolLengthReviewTests.swift)
and [ScenarioAuthIdentityLength.swift](../../Sources/pm-sim/ScenarioAuthIdentityLength.swift)
exercise exact boundaries, uppercase/UTF16 expansion and refusal classification
against the real authenticator with synthetic credentials. The scenario passed8
assertions. These protocol guards complement the configured resource profile;
legacy file/startup/import enforcement remains a separate planned slice.

Does not prove: complete boundary coverage, steady/runtime memory, Stop/status
fairness, actual write quiescence or real-machine behavior.

## Open questions

Persistence precision/schema is selected in [0023](0023-exact-schema-two-persistence.md); the asynchronous store remains planned.
Revisit these ceilings for a demonstrated legitimate value or a changed underlying
protocol/platform limit, with compatibility and measured cost recorded separately.
