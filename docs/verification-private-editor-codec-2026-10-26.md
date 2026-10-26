# Private editor codec: verification checkpoint

This unreleased headless slice implements the selected eight-MiB private reply ceiling in
[0034](decisions/0034-private-editor-reply-frame-cap.md). It adds correlated private editor reads and
admission/observation/refusal replies, exact component baselines and explicit per-module update intent.
It does not expose a live host writer, activate AppState or make Conduit release-ready. The serving
0.5.8 app was not stopped or replaced. Claude Code implemented and reviewed through the owner's
verified claude.ai Max subscription; no API authentication was used.

## Boundary and reuse

One private header grammar, counting/emitting writer and schema-directed scanner serve Q updates,
G reads and R replies. The reader requires the expected kind and rejects its mismatch before the body.
Baseline versions retain the full UInt64 range; store authority is not minted by the codec. Private
values remain non-Codable and redacted in reflection. Ordinary values retain their existing wire types.
Update admission is separate from settlement: no codec round trip proves a save or apply.

Bridge observation preflight uses the same production field writer with a counting sink, rejecting
non-finite values without a dummy request. There is one field mapping in each direction. The reader
copies contiguous body runs in batches, retaining the same 16 KiB input budget, doubling growth,
scrubbing, fallback path and completion copy. The budget limits bytes examined, not total copy work.

## Review and regression witnesses

Independent subscription-backed Opus reviews of immutable snapshots `68c556f`, `521bf66` and
`51c07e9` returned READY. These were static reviews; execution evidence is recorded separately.
The reviews led to direct scanner-overflow coverage, required-null coverage, exhaustive G reference
parsing and a growth-capacity witness. The final test follow-up `641353f` also covers nonzero Data slices.
Focused verification passed 167 tests, event/decision checks and both private codec scenarios.

Codex executed four deliberate production-source mutations, each rejected by the intended XCTest
assertion rather than a compiler failure:

| Mutation | Witness |
| --- | --- |
| Treat a required nullable revision as an optional member | Module-intent strict shape |
| Remove the scanner's UInt64 upper bound | Direct scanner overflow refusal |
| Skip expected-kind checking | Wrong-kind refusal before body inspection |
| Grow bulk storage to exactly the requested bytes | Twin bytewise buffer capacity equality |

After every mutation the original bytes were restored. Restored targeted tests passed and the source
matched committed bytes. Restored SHA-256 values:

```text
PrivateConfigurationDecoder.swift 39774f9db0a4d618b6fb2082eaa55c689607390c3c350c8fc6ba38543d2f86fb
PrivateJSONScanner.swift 0cb9c73b90be9dad79659d5f5b309eaf4ee5f2b655a08a06fbe8fafc58c11f8f
PrivateConfigurationFrame.swift 0225e36b22b2efff8ee9482f6491b0155e48b008b37f00c417e4c1a26559f64c
```

The first fixture calibration intentionally still asserted size zero and failed on the measured size;
it was replaced by that value. An initial experiment did not compile, and an intermediate probe
retained the owner past its purported release. Those runs are excluded from memory evidence.

## Actual Release codec evidence

The [experiment and raw numeric results](experiments/private-editor-codec/README.md) compare
`521bf66` with `51c07e9`, using identical probe, runner and maximum fixture bytes. All three modes
passed with an equal decoded observation, a 7,487,875-byte frame and 458 reader calls. The fixture's
conservative numeric allowance gives 7,499,714 bytes, leaving 888,894 under the eight-MiB ceiling.
It is not a universal bound on future fields or all schema branches.

With the owner and a separate client draft held throughout, the widest sampled live-malloc stage
was about 18.84 MB; observed codec-process RSS peaks were about 41–46 MB. A stage sample misses
allocations created and freed within that stage. Twenty repeated transfers retained flat live malloc
at their release points. This is neither installed-app RAM nor a general leak proof.

The batched reader's repeat median was 0.86 ms versus 925.7 ms before. Encode/decode timings
and sampled live allocations were broadly unchanged; no memory improvement is claimed. One run
per phase cannot establish run-to-run variance. These timings do not measure host response latency.

## Full workflow

Verification is running on frozen source after `641353f`; final counts and fingerprint will be added
before push. No passing full-workflow or hosted-CI result is claimed yet.

## Remaining adoption gates

Connect the real host and framed client, complete ordered interactive admission and per-module
fences, implement causal settlement receipts from actual canonical writes, and keep preference and
administrative persistence in the sole store. Before exposing those sidecar writers, prove baseline
freshness and preservation when missing sidecars inherit legacy runtime values. The
[editor integration review](design-runtime-editor-contract-review.md) tracks these obligations.

Measure actual-host Stop/status responsiveness and all custody terms before selecting the production
service profile, deadlines and total Quit budget with the owner. No shipping profile, live private
adapter, AppState convergence, RuntimeActor move, production socket or installed-app acceptance
is proved by this codec slice.
