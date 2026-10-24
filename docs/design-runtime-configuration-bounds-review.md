# Configuration resource bounds: owner review

Date: 2026-10-24. **Owner selected this profile and startup enforcement; implementation remains planned.** See [decision 0021](decisions/0021-bounded-configuration-at-all-boundaries.md) and #186. This refines the earlier no-count-limit assumption after the owner explicitly rejected supporting millions of DoH providers. Codex and Claude reviewed the actual code using Claude Code on the owner's claude.ai Max subscription. The packed-array optimization was stopped before it edited source.

## Selected profile

| Resource | Hard ceiling | Basis |
| --- | ---: | --- |
| DoH providers | 8 | Default3; these are parallel resolution endpoints, not a large rule database. |
| DNS servers per configured domain | 8 | Small resolver set; count every entry, including disabled definitions. |
| Upstream proxies | 32 | The owner's current config has11; allow headroom without a large collection. |
| Tunnel definitions | 128 | Native-protocol local forwards; primary performance case64, double headroom128. Each enabled definition can own a listener. |
| DNS domain entries | 256 | Bound managed configuration and resolver work. |
| DNS intercept rules | 256 | Same principle; existing helper list budgets are also256, though calls/resources are separate. |
| Allowed proxy clients | 256 | Small explicit allowlist; byte limits also apply. |
| Forced-proxy patterns | 256 | Align with bypass list; current matching cost is unmeasured, so4096 is not justified yet. |
| Bypass patterns | Existing limits |256 entries,253 UTF-8 bytes/entry and8192 encoded bytes are already enforced. |
| Host/domain/pattern/address strings |253 UTF-8 bytes where existing grammar permits | Retain stricter existing semantic limits. |
| Display text/profile labels |1024 UTF-8 bytes | Bound non-routing free text; not a million-byte profile name. |
| Private URL fields |16384 UTF-8 bytes | Generous bounded allowance for token-bearing queries; not an assertion that current URLs need it. |
| Complete private frame |8388608 bytes | Retain the selected8MiB ceiling, including framing. |
| Runtime config file read |8388608 bytes | Bounded read before JSON expansion; preserve and reject an oversized file. Verify legal-maximum pretty encoding before adoption. |
| Private config bodies/decode |One active globally | Refuse busy before allocating another complete body; Stop/status retain independent capacity. |

Codex inspected only configuration shape/counts and URL lengths, without printing values:3 DoH providers,11 upstreams,2 tunnels,2 DNS entries,6 intercept rules,2 allowed clients,23 bypass patterns,1 forced-proxy pattern; maximum2 servers/entry and43 URL UTF-8 bytes. These are the current file's shape, not a product-wide usage study. The proposed ceilings accommodate it.

Every remaining string/array must be inventoried and covered; this table is not permission for unlisted fields to remain unbounded. Authentication identities and paths need appropriate semantic byte bounds, not accidental classification as display labels. Disabled definitions still consume configuration memory and count against resource ceilings.

## Enforcement shape

One domain-resource policy is shared across startup/file import, in-memory updates and later daemon requests. The client cannot raise host limits. Keep neutral domain limits separate from ordinary control execution policy and preserve the selected module boundaries.

For private JSON, make the existing scanner schema-aware: recognize allowed object keys without allocating arbitrary key sets; count array entries and decoded UTF-8 bytes; reject unknown/over-limit input before Foundation's typed decode. Escaped bytes count by their decoded UTF-8 representation, while the frame cap independently counts physical wire bytes. Validate domain semantics afterward. A post-decode check alone does not prevent the575MB stress allocation.

For disk input, bound the actual read, not only stat metadata; then apply the same schema/count/byte preflight before generic JSON decode. File grammar differs from the private request, so reuse policy and scanner primitives without pretending their schemas match. Refuse over-limit ordinary updates before saving/admission. Existing oversized files are preserved and produce an explicit field/limit error; do not truncate, auto-rewrite or silently remove disabled definitions. The owner selected startup enforcement, replacing0019's old startup-validator choice.

Use one private work slot, release intermediate forms as soon as their stage is done, and measure peak memory on legal-maximum fixtures. No disk spool, snapshot registry, pooled collection or permanent secret intern cache is introduced. The8MiB cap is not an RSS guarantee. Stop/status latency and write quiescence remain separate verification obligations.

## Runtime work is a separate bound

Current DoH code starts2 formats across up to3 routes per provider. Eight providers can mean48 fetch tasks per lookup. The relay already caps64 admitted queries, but OriginResolver's256-entry cache is not an in-flight limit; it creates separate sessions for its fetches. Thus provider limits remove nonsensical growth but do not prove a suitable global HTTP-attempt budget. A bounded fair scheduler/admission policy needs its own latency/model evidence; selecting config ceilings does not silently choose scheduling semantics or force sequential fallback.

## Alternatives and review differences

- **Only a frame cap, validate after decode:** rejected as sufficient; dense values and unknown objects expand first.
- **Optimize storage for millions of endpoints:** not justified after the owner's direction. Revisit packed storage only if supported configurations still exceed the chosen measured budget.
- **4096 forced-proxy patterns:** initially proposed by Codex, challenged by Claude for lack of workload/matcher evidence. Recommend256 now; revisit for real imported lists with benchmarks/indexed matching.
- **16 upstreams:** initial proposal; the current11-entry config warrants32 for reasonable headroom at negligible storage cost.
- **2048-byte private URLs:** Claude suggested borrowing the helper's autoproxy limit. Codex checked that code: it limits machine-facing autoproxy URLs to2048 Swift characters, not2048 UTF-8 bytes, and is not a general limit on private upstream PAC/health/DoH URLs. Do not conflate the contracts. Recommend16KiB here; keep helper validation unchanged.
- **Grandfather oversized startup files:** preserves old acceptance but leaves allocation/runtime cost unbounded. Recommend clear refusal with the file untouched.
- **Ignore oversized disabled features:** still requires reading/materializing unsupported input and complicates round-trip preservation. A bounded diagnostic/editor workflow can be considered separately; do not silently strip it in the host.

## Verification and revisit

Before adoption: exact-limit and one-over fixtures for every field, escaped-byte cases, unknown large keys/arrays rejected before DTO construction, actual bounded file reads under growth, client/host parity, and legal-maximum release-build sender/receiver memory measurements. Test busy peers without allocating N bodies and independently verify Stop/status responsiveness. Preserve the earlier575MB probe as evidence of the old unsupported shape, not a supported workload or acceptable budget.

Revisit only for a demonstrated configuration needing more entries/bytes, a measured supported-case budget failure, or a new runtime matching/listener execution model. Record changed compatibility and capacity as a new decision. This review does not choose the separate store precision policy in#224.

## Executed candidate-profile sizing

Using the same unmodified codec, Codex executed two synthetic proposed-count-ceiling fixtures with long valid hostnames,16KiB URLs and1KiB display labels. Both validated and round-tripped equal while retaining all pipeline forms. Debug peaks were17,399,808B and19,349,504B; release peaks were15,581,184B and17,776,640B. Frames were639,291B and1,135,932B. These are single-process observations, not exhaustive maximum-memory proofs, an accepted threshold or an allocation-strategy improvement. Full sources, raw stage output and limits are in the [experiment note](experiments/private-configuration-codec/README.md#proposed-domain-bounds-probe).


The approved128-tunnel headroom was subsequently measured with otherwise identical
fixtures: release whole-process peaks17,334,272B /21,004,288B over6,946,816B baseline;
frames730,811B /1,555,132B; cumulative times0.163s /0.299s. All forms were deliberately
retained and both round-tripped equal. This does not measure128 active listeners
or steady app memory. Exact sources/output are in the experiment note above.
