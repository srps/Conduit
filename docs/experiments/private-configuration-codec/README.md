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

Baseline was6,864,896B. These are single runs, not medians, limits or latency guarantees. The fixtures reach proposed collection-count ceilings but do not exhaust every byte/uniqueness combination; they include repeated host/label strings and remain a sizing experiment. They do not exercise concurrent busy peers, runtime DoH fan-out, or Stop/status. Product caps and startup compatibility remain pending owner selection.
