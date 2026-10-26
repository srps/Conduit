# Private editor reply sizing: request-codec evidence and a mirror estimate, 2026-10-26

This experiment informed the eight-MiB private reply ceiling selected in
[decision 0034](../../decisions/0034-private-editor-reply-frame-cap.md) and the
[editor contract review](../../design-runtime-editor-contract-review.md). It is a synthetic, single-process probe
that links the actual release objects of product commit `7e7dccc` (Swift 6.4, arm64 macOS, `-O` probe). No app, helper,
store, socket, user configuration or machine setting is involved, and the serving Conduit was unchanged. It is not product
code, not itself a limit implementation, and **not the future reply codec**. At this measurement checkpoint no production reply writer or decoder existed, so nothing
here measures reply encoding, reply decoding or their lifetimes.

Two kinds of number appear below, and they must not be mixed:

- **Measured (actual codec):** the production private request path. `PrivateConfigurationBridge.makeRequest`,
  `PrivateConfigurationEncoder.measureBody`/`encode`, `PrivateConfigurationFrameReader`, `PrivateConfigurationDecoder`,
  `makeValues`, the shared resource check, `validate()` counts, `ProxyConfigPersistence.stagedFile` and startup `decode`, and
  the sidecar staging/decode functions.
- **Estimated (mirror):** the reply members beyond the request body. A probe-local `Encodable` mirror stands in for them, and
  a conservative allowance is charged over its lexemes. It is a sizing argument, not a type proposal or a codec.

`Probe.swift` is the exact executed source (sha256 `ac930e8e761e74d5be65689b0cb0c791d947439deb9469b63fa6cc9b7203e19a`).
`results/` holds its numeric NDJSON output and `metadata.json`. Every record is a label, count or metric; no fixture string
is printed. All four modes exit 0 with zero failed checks and nothing inconclusive.

## Fixtures

Every collection is at its approved ceiling (decisions 0021/0022): 32 upstreams, 128 tunnels, 256 DNS entries × 8 servers,
256 intercept rules, 256 allowed clients, 256 forced-proxy patterns, 256 bypass patterns landing exactly on the 8,192-byte
canonical aggregate, and 8 DoH providers. Every Bool is `false` (the wider literal), every optional is present, enums take
their longest raw value, and numbers are the accepted schema-two defaults.

- `small`: short valid strings. It calibrates the lexer against an explicit field inventory and is `eligible`.
- `string-maximum`: every resource-bounded text at its decoded UTF-8 ceiling, every byte U+0001 (a six-byte `\u0001`
  escape, the widest), except the required `*.` prefix and the one ASCII byte that lands the bypass aggregate. Equal
  strings share storage.
- `unique-maximum`: the same widths, every text distinct. Its distinct tags use only six-byte escapes, so its frame has
  the same byte count as `string-maximum`. The contents differ.
- `repeat`: 20 sequential `unique-maximum` pipelines in one process, sampled after each release.

Both maximum fixtures are storable repair drafts that block start (1,026 validation problems, 514 start-blocking). They pass
the shared resource check, the schema-two representability predicates and `stagedFile`. The staged pretty file is 7,443,050 B,
under the 8,388,608 B runtime file limit, and startup decode of the staged and compact bytes reproduces the input exactly.
A loaded file can therefore hold this shape, and an observation must be able to return it.

## Request frame: measured, plus a conservative bound

| Fixture | Body, B | Frame, B |
| --- | ---: | ---: |
| small | 119,654 | 119,669 |
| string-maximum / unique-maximum | 7,382,940 | 7,382,956 |

Calibration on the maximum body: 3,921 bounded texts hold 1,217,519 decoded bytes, of which 1,217,006 are six-byte
escapes. The lexer accounts for every body byte and agrees with the field inventory by count and by bytes:
341 integers (1,287 B), 11 doubles (42 B), 813 `false`, 0 `true`, 0 `null`, 3,339 keys and 4,725 value strings.

The bound covers any request the shared resource check accepts. Each text is at its ceiling and every byte takes the widest
escape. Each numeric lexeme is charged at its widest spelling: 20 B for any `Int` or `UInt64`, and 1,100 B for any finite
binary64 (exact positional expansion ≤ 1,092 B; the proof is in the source; the widest Swift spelling observed is 24 B).
Numeric allowance 17,591 B gives a body bound of 7,400,531 B and a **frame bound of 7,400,547 B** against the 8,388,608 B cap.

## Reply frame: estimate, not measurement

The worst candidate reply carries one runtime, one platform and one preferences value (no second full configuration), plus
every metadata member at once with every optional present:

- three component states, each with an exact baseline (namespace UUID, component, `UInt64.max` version), a migration flag, a
  fallback token and a retained-reason token;
- three module intents (module, `Int.max` lifecycle revision, intent token, fence);
- host incarnation, owner generation, terminal flag and launch-at-login;
- one causal receipt with request, draft and operation identities, a generation, three component outcomes (outcome, cause,
  hold, reported-error flag, receipt baseline), and an apply outcome and reason.

| Term | Bytes |
| --- | ---: |
| Request body bound (request-only members not subtracted) | 7,400,531 |
| Widest preferences object (16 KiB browser URL, all escapes; canonical width ≥ private width) | 98,475 |
| Metadata allowance: 80 keys at 66 B, 48 value strings at 386 B (64-byte token guard, all escapes), 11 integers at 20 B, 11 Bools at 5 B, 189 structural B | 24,272 |
| Envelope allowance (three members) | 249 |
| **Reply frame bound** | **7,523,543** |
| Headroom under 8,388,608 | 865,065 (10.3%) |

The mirror's own metadata encodes to 4,237 B, and its full frame would be 7,503,310 B. The headroom would hold 1,909 more
members of the widest class (453 B each: key, escaped token value and comma). An earlier run with a one-module mirror (bound 7,499,869 B) is superseded and not cited.

**Mirror versus candidate inventory.** 7,523,543 B is the bound for the executed mirror, not for the finished API. The
mirror's receipt has one aggregate apply outcome and reason, plus a draft identity. The candidate receipt in the
[design review](../../design-runtime-editor-contract-review.md) has an apply or start outcome per module, and no draft
identity on the wire. Those per-module result members, and any other bounded member the final shape adds, consume the
865,065 B headroom. The actual reply codec must measure them. The counts above are the executed evidence and stay as
recorded.

## Request-codec memory and work

These numbers are whole-process samples for the request pipeline only. They are not a whole-host peak, not running-app
RAM, not a reply measurement and not evidence of Stop/status latency or fairness. Live values (`mallocInUseBytes`,
footprint, resident) are sampled between stages. A copy that lives and dies inside one stage appears only in the monotonic
high-water fields: `ru_maxrss` and `ledger_phys_footprint_peak`. Examples are the reader's buffer growth and completion
copy, the decoder's `Data` copy, and the encoder's `SecretBytes` copy. `mallocMaxInUseBytes` reads 0 because the default
allocator does not maintain it, so it is not used. The "previous" value is rebuilt after decode, so an owner value retained
through encode, read and decode is **not** modelled. An in-process host plus client would add at least that value
(about 1.7 MB live malloc for `unique-maximum` domain input) and the client's draft.

`unique-maximum`, one fresh process:

| Stage | Live malloc, B | Footprint peak, B | Peak RSS, B | Elapsed in stage, s |
| --- | ---: | ---: | ---: | ---: |
| baseline | 89,232 | 1,556,816 | 6,307,840 | |
| domain input built | 1,817,984 | 4,145,560 | 10,960,896 | 0.015 |
| frozen request (+ count pass) | 2,028,896 | 4,440,496 | 12,009,472 | 0.098 |
| sender overlap (measure + encode) | 9,418,208 | 19,251,632 | 26,820,608 | 0.221 |
| wire frame only | 7,573,376 | 19,268,016 | 26,853,376 | |
| receiver body only (reader) | 7,573,856 | 30,523,848 | 38,076,416 | 0.936 |
| decoded request only | 2,055,632 | 33,030,600 | 40,796,160 | 0.055 |
| domain values only (+ count pass) | 2,096,176 | 33,030,600 | 40,796,160 | 0.096 |
| previous + domain values | 3,731,024 | 33,407,432 | 41,189,376 | |
| final released | 195,728 | 33,440,200 | 41,222,144 | |

`string-maximum` ends at 40,042,496 B peak RSS and `small` at 12,271,616 B. In `repeat`, live malloc after each release
went from 195,456 B to 195,984 B over 20 iterations (+528 B, unchanged from iteration 10). Peak RSS was 45,400,064 B and
footprint peak 38,093,256 B, at about 1.45 s per pipeline. Resident and footprint values stay high after release while
live malloc returns to its baseline. That pattern is consistent with allocator reservations and mappings. It is not a
general proof that the codec has no leaks: the probe samples one allocator statistic at stage boundaries, in one
process, for this fixture.

The reader stage took 0.94–0.98 s for one 7.38 MB frame (about 7.7 MB/s), roughly four times the two encode passes. The
probe feeds `consume` from another module, so the cost is per-byte work. The cause is not isolated: unspecialized generic
iteration and per-byte append are both likely. All timings are single local observations, not percentiles.

### Probe artifact found and removed

An earlier `repeat` showed +85,712 B over 20 iterations, about 4.5 KB each, with logging outside any autorelease pool.
The probe's `JSONSerialization` records are bridged Foundation objects, and a command-line main thread does not drain
autoreleased objects. Scoping `emit` in `autoreleasepool` was the only change on the `repeat` path besides two added
sample fields, and the growth fell to +528 B. The earlier figure is therefore treated as a probe-logging artifact. That attribution rests on this one
before-and-after comparison; no allocation trace isolated it.

## Reproduction

This is a historical probe against `7e7dccca3d32f28a0d593d5b2ccd4b4d0161d967`, whose private request API predates the
exact-baseline editor contract. Use a checkout with that product source and build its Release products. The runner's
`--repo` selects that checkout; it refuses changed product sources before compiling rather than retaining obsolete
production API just for the experiment. Run the script from the checkout containing this experiment:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release --package-path /path/to/baseline-checkout
python3 docs/experiments/private-editor-reply/run.py "$(mktemp -d /tmp/private-editor-reply-XXXX)" --repo /path/to/baseline-checkout
```

`run.py` expects the SwiftPM release layout (`.build/release`) and the generated NIO module maps, as the display codec
runner does. The recorded results came from an equivalent scratch runner over the same 26 release objects and the same
source.

This portable runner was then executed independently, on the same product commit and probe sha256 (`ac930e8e…`). All four
modes exited 0, and the reply frame bound was again exactly 7,523,543 B, with 865,065 B of headroom. That run's `repeat`
showed the same +528 B released-malloc growth, with a peak RSS of 45,268,992 B, against 45,400,064 B in the recorded run.
Byte counts reproduced exactly; they are deterministic for this source and product commit. Memory and timing columns vary
with allocator, OS and toolchain.

## Does not prove

Reply codec size, cost or lifetime; host and client coexistence in one process; owner-retained values during transfer;
store staging and verification memory; private-lane custody; Stop/status latency during a transfer; real-machine behavior.
These remain adoption gates for the actual reply codec and the actual host adapter.
