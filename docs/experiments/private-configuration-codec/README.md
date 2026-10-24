# Actual private codec resource probe, 2026-10-24

This is a scratch-process experiment against the production private codec and bridge, not the earlier generic JSON sizing mirror. No user configuration or machine settings are read. Each case runs in a fresh process with synthetic values, validates through `ProxyConfig.validate()`, freezes, encodes, frames in bounded consume calls, decodes, thaws and checks exact config equality. The live app is untouched.

Observed on local arm64 macOS, debug library objects, Xcode toolchain. `getrusage(RUSAGE_SELF).ru_maxrss` is bytes on this platform. The process deliberately retains the original config, frozen request, encoded frame, frame body, decoded request and thawed result together through the last measurement. These are whole-process high-water marks, not attributable allocator totals, steady state, release-build performance or a universal worst case. Timing is cumulative from process start. There is one active synthetic request and no traffic or concurrent Stop probe.

| Fixture | Complete frame | Peak RSS | End-to-end wall time |
| --- | ---: | ---: | ---: |
| 100,000 empty DoH provider strings | 302,177 B | 34,455,552 B | 0.213 s |
| 1,000,000 empty DoH provider strings | 3,002,178 B | 239,173,632 B | 1.979 s |
| 2,700,000 empty DoH provider strings | 8,102,178 B | 574,554,112 B | 5.269 s |
| 8,000,000-byte profile string | 8,002,255 B | 55,164,928 B | 2.540 s |

All four inputs pass the current domain validator and round-trip equal. Empty provider strings are allowed by that validator; the experiment does not propose adding a per-field or item-count restriction. Dense small values can cost much more memory than one large string with a similar encoded size. The 8 MiB frame cap therefore does not imply an 8 MiB memory budget or a short codec call.

## Adoption gate and possible follow-up

The codec remains unconnected to any runtime client, store, or transport. Before adoption, measure release builds and receiver-only lifetime separately, define active/pending request capacity and working-memory/lifetime limits, and verify Stop/status latency independently of configuration work. Avoid retaining all pipeline forms at once. If dense valid frames still exceed the selected operational budget, compare an incremental typed decoder/less allocation-heavy private value storage with revisiting transfer limits. A lower frame cap or new item-count restrictions change owner-selected compatibility and need an explicit decision; they are not silently introduced here. Chunking alone would not reduce decoded object amplification.

`ResourceProbe.swift` is the exact executed probe. `resource-probe-results.json` contains the numeric stage output and process exit statuses. It was linked with `-package-name conduit` against the worktree's existing debug `ProxyKernel`, `ProxyControlBridge`, `ConduitShared`, `RuntimeEvents`, and transitive SwiftNIO dependency objects, using their existing generated/header module maps. Its source is experiment-only and is not a product target or a CI memory assertion. Reproduction requires a normal Xcode-prefixed debug build first, then linking those existing objects with the probe; the test-only compilation does not widen product access.

## Proposed domain bounds probe

After the owner rejected supporting millions of DoH providers, Codex ran two additional fresh-process fixtures using the same codec. `ProposedBoundsProbe.swift` and `proposed-bounds-results.json` preserve the executed source/output. No product limits were changed by this experiment.

Both fixtures use the proposed count ceilings: 8 DoH providers, 8 DNS servers per domain across 256 entries, 32 upstreams, 64 tunnels, 256 intercept rules, 256 allowed clients, 256 bypass entries and 256 forced-proxy patterns. Hosts/patterns are 253-byte valid names where used; private URLs are 16,384 bytes; profile/upstream/tunnel labels are 1,024 bytes. Allowed clients are valid loopback literals; bypass entries fit their existing encoded-byte cap. The second fixture uses escaped control bytes in display labels. Both pass today's domain validator and reconstruct equal configs. These are upper-count fixtures, not an exhaustive byte-maximum search or a claim that every future semantic rule has been selected.

| Proposed-profile fixture | Complete frame | Whole-process peak RSS | Cumulative end-to-end time |
| --- | ---: | ---: | ---: |
| Long ordinary strings | 639,291 B | 17,399,808 B | 0.250 s |
| Escaped display labels | 1,135,932 B | 19,349,504 B | 0.445 s |

As in the earlier probe, every pipeline form is deliberately retained until the end. The debug-process baseline is about 7 MB. These observations support early domain bounds and do not prove a universal memory bound, release performance, receiver-only cost, busy-peer capacity or Stop/status latency. The earlier 575 MB result remains evidence of the uncapped input shape; no allocator optimization is claimed.

The same two fixtures were also compiled with `-O` and linked against an Xcode-prefixed `swift build -c release --target ProxyControlBridge` (completed in53.87s). Fresh-process release measurements, still retaining all forms, were:

| Fixture | Whole-process peak RSS | End-to-end time |
| --- | ---: | ---: |
| Long ordinary strings |15,581,184B |0.125s |
| Escaped display labels |17,776,640B |0.222s |

Baseline was6,864,896B. These are single runs, not medians, limits or latency guarantees. The fixtures reach proposed collection-count ceilings but do not exhaust every byte/uniqueness combination; they include repeated host/label strings and remain a sizing experiment. They do not exercise concurrent busy peers, runtime DoH fan-out, or Stop/status. The owner subsequently selected domain caps and startup enforcement in [decision0021](../../decisions/0021-bounded-configuration-at-all-boundaries.md), with128 tunnels as the hard ceiling. These fixtures have64; the subsequent128-case measurements are below. The original results remain unchanged.


## Approved 128-tunnel headroom probe

After the owner selected128 configured forwards as the hard ceiling, Codex reran
the same synthetic release cases with128 instead of64 tunnel definitions.
`ApprovedBounds128Probe.swift` and `approved128-release-results.json` preserve the
executed source and numeric output. Both validated and reconstructed equal.

| Fixture | Complete frame | Whole-process peak RSS | End-to-end time |
| --- | ---: | ---: | ---: |
| Long ordinary strings |730,811B |17,334,272B |0.163s |
| Escaped display labels |1,555,132B |21,004,288B |0.299s |

Baseline was6,946,816B. All pipeline forms were retained again. These single-run
high-water marks do not measure steady configuration storage, runtime listeners,
traffic, receiver-only lifetime, uniqueness/byte maxima, or Stop/status. They use
the unadopted pre-domain-limit codec: product enforcement remains separate work.
The source differs from the earlier64-case probe only in tunnel count. Two
initial compilation attempts lacked dependency header module maps and did not
run; adding the existing _AtomicsShims/CNIOWindows maps allowed compilation.
No product source or dependency was changed for this experiment.


## Staged representation lifetimes (128 tunnels)

`ConfigurationLifetimeProbe.swift` uses the same synthetic128-definition fixtures
and the same existing release library objects, before domain-limit implementation.
It returns only the frame from the sender, releases that after framing, releases
the body after decoding, and releases the decoded request after reconstruction.
The final configuration survives until a separate function returns. Function
boundaries and `withExtendedLifetime` make the intended retention stages explicit.
The probe verifies shape; exact equality was already checked by the all-forms
headroom probe. No product source was optimized for this experiment.

It samples three distinct measures: `getrusage` peak RSS, `task_info(TASK_VM_INFO)`
current resident bytes/physical footprint, and `malloc_zone_statistics(nil, ...)`
bytes currently in use across malloc zones. SDK header declarations were checked
before use. Allocator bytes exclude memory outside those allocations; they are
not the configuration's entire physical footprint. Raw output is preserved in
`lifetime-release-results.json`.

| Stage/metric | Ordinary labels | Escaped labels |
| --- | ---: | ---: |
| Baseline allocator bytes in use |89,248B |89,312B |
| Final runtime values only: allocator bytes in use |1,165,568B |1,220,736B |
| After releasing final values: allocator bytes in use |188,000B |201,952B |
| Final values only: current resident bytes |15,646,720B |20,430,848B |
| Final values only: physical footprint |8,307,192B |13,091,320B |
| Baseline resident bytes |6,176,768B |6,144,000B |
| Baseline physical footprint |1,622,376B |1,589,608B |

The live-allocation increase with only final values is roughly1.1MB, and most of
that disappears from malloc in-use after releasing the values. Resident bytes
and physical footprint did **not** immediately fall after release. Freed
allocation pages can remain reserved for reuse, and library mappings/caches also
contribute; these counters do not attribute all retained pages. Thus live heap,
RSS, physical footprint and high-water marks must not be substituted for each
other, and releasing a representation does not promise an immediate RSS drop.

This single-update scratch process has no old active configuration, listeners,
traffic, UI, concurrency or repeated-update growth test. It is neither an idle
running-Conduit measurement nor an exhaustive byte/uniqueness maximum. A real
update can retain the previous live configuration until replacement. Measure that
lifetime and repeated updates during adoption; do not derive an app footprint
by adding these numbers to a one-off app RSS sample. Fixed resource caps and
shorter lifetimes are the current recommendation; no claimed allocation/storage
optimization or new RSS acceptance threshold is introduced.
