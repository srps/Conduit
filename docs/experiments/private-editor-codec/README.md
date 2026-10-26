# Private editor reply codec: Release sizing and lifetime, before and after the batched reader copy (2026-10-26)

This experiment measures the actual private editor reply codec of [decision 0034](../../decisions/0034-private-editor-reply-frame-cap.md)
in Release builds. It ran once before and once after the frame reader started copying body bytes in batches.
`Probe.swift` and the pure maximum fixture (`Tests/ConduitTests/Fixtures/PrivateEditorMaximumFixture.swift`, unmodified) are
compiled together against the Release `ConduitShared` object alone, with `-package-name conduit`. No NIO object, no new test
hook and no widened access are involved. The probe reads no app, helper, network, store or configuration state. It prints labels,
counts and metrics only, never fixture text.

These are measurements of one synthetic process on one machine. They are **not** installed-app RAM, a whole-host peak,
private-lane fairness or Stop/status latency, and nothing here claims any of those.

## Method

A transfer is what an in-process host and client do with one observation reply. The host's owner value and a separately
built client draft stay alive (`withExtendedLifetime`) through measure, encode, read (the production
`PrivateConfigurationFrameReader`, fed the whole remaining frame each call) and decode. The wire frame is dropped once read,
the body once decoded, and the decoded reply once compared with the original. Each mode runs in a fresh process:

- `wide-shared`: fixture `distinct: false`. One transfer, sampled at every stage, then the sizing analysis.
- `wide-distinct`: fixture `distinct: true`: every text unique, same widths. Otherwise as above.
- `repeat-distinct`: `distinct: true`. One owner and one draft are held across 20 transfers. Only the stage after each
  transfer's release is sampled, and both values are still alive then.

Samples are `getrusage` peak RSS, live malloc (`size_in_use` summed over zones), physical footprint and its ledger peak. They are
written into storage reserved before the baseline, with static labels. Nothing is printed until the lifetime phase ends, each
printed record is built in its own autorelease pool, and each transfer runs in its own pool. The sizing analysis runs last, so
it cannot raise a quoted peak.

**Live malloc is sampled between stages.** The widest sampled stage is not the true transient maximum. A buffer that lives
and dies inside one stage appears only in the monotonic RSS and footprint peaks. Examples are the encoder's buffer and its
`SecretBytes` copy, the reader's buffer growth and completion copy, and the decoder's `Data` and Foundation values.

## Runs cited

| Run | Product commit | `ConduitShared.o` sha256 | Reader |
| --- | --- | --- | --- |
| `editor-reply-beforeBatch-ghl6a5qi` | `521bf66` | `5a208746…c391` | byte at a time |
| `editor-reply-afterBatch-mem1jzf9` | `51c07e9` | `aeed0206…55e7` | batched body copy |

The complete numeric logs and metadata are retained in [`results/before`](results/before/metadata.json) and
[`results/after`](results/after/metadata.json). Both runs used the same probe, runner and fixture (sha256 `68996832…e328`, `3d28b37d…8745` and `e90e48bf…485b`), Apple
Swift 6.4, macOS 26.7.1 on arm64. The product sources matched HEAD in both. Every mode exited 0 with zero failed checks. In
`ghl6a5qi`, two decoder files had newer mtimes than the object after a byte-exact restoration; the runner confirmed both still
matched HEAD.

Not evidence: `editor-reply-beforeBatch-z2g_a2gr`, where the probe failed to compile. Also not evidence:
`editor-reply-beforeBatch-w9kh2zq9`. Its last stage was labelled as releasing the owner, but a `guard case let` binding still
held the owner's observation (live malloc 1,982,336 B against a 96,832 B baseline). The fix scoped that binding and added
checks that each release returns its bytes.

## Sizes (identical before and after)

| | Bytes |
| --- | ---: |
| Reply body | 7,487,859 |
| Reply frame (15-byte header) | 7,487,875 |
| Under the 8,388,608 B reply cap | 900,733 |
| Reader calls per frame, every mode | 458 (the minimum the 16 KiB per-call budget allows) |

The decoded reply equaled the original in every transfer, in both runs.

**Conservative numeric bound.** A flat walk with the production `JSONByteCursor` primitives finds 343 integer lexemes
(6,857 B, widest 20) and 11 Double lexemes (264 B, widest 24, the fixture's spelling). Each integer is charged 20 B
(`Int.min`, `UInt64.max`). Each finite Double is charged 1,100 B, because its exact positional expansion is at most 1,092 B;
the proof is in `Probe.swift`. That gives an 11,839 B allowance, a frame bound of 7,499,714 B and 888,894 B of headroom.
The bound is a useful allowance for this fixture: its widest texts and counts plus its observed scalar spellings. It is not a
proved universal maximum, and it says nothing about future schema branches.

## Time (single local observations; no assertions depend on them)

| Step | Before | After |
| --- | ---: | ---: |
| read, `wide-shared` | 913.0 ms | 1.5 ms |
| read, `wide-distinct` | 999.6 ms | 9.5 ms |
| read, `repeat-distinct` median (min–max) | 925.7 ms (900.9–948.0) | 0.86 ms (0.74–1.92) |
| encode, repeat median | 221.7 ms | 223.0 ms |
| decode, repeat median | 54.0 ms | 54.0 ms |
| measure, repeat median | 95.0 ms | 94.7 ms |
| whole transfer, repeat median | 1,299.8 ms | 371.2 ms |

Only the read step changed. Encode is now the largest step. These are process timings of the codec alone. They do not show
how long a host takes to answer Stop or status while a transfer is in flight.

## Memory

Sampled live malloc and process peaks, `wide-distinct`:

| Stage (alive) | Live malloc before | Live malloc after | Peak RSS before | Peak RSS after |
| --- | ---: | ---: | ---: | ---: |
| baseline (nothing) | 96,832 | 96,832 | 5,963,776 | 5,963,776 |
| encoded (owner, draft, wire) | 11,331,344 | 11,331,216 | 26,755,072 | 26,738,688 |
| read (owner, draft, wire, body) | 18,835,568 | 18,835,344 | 38,174,720 | 38,518,784 |
| decoded (owner, draft, body, decoded) | 13,226,128 | 13,225,872 | 40,992,768 | 41,402,368 |
| owner released (nothing) | 120,848 | 120,592 | 40,992,768 | 41,402,368 |

The owner holds about 1,868,600 B of live malloc and the draft 1,861,552 B. After both are released, about 24 KB remains
above the baseline.

End of the lifetime phase (monotonic peaks):

| Mode | Peak RSS before | Peak RSS after | Footprint peak before | Footprint peak after |
| --- | ---: | ---: | ---: | ---: |
| `wide-shared` | 41,205,760 | 41,287,680 | 35,225,984 | 35,307,904 |
| `wide-distinct` | 40,992,768 | 41,402,368 | 35,307,928 | 35,422,592 |
| `repeat-distinct` | 45,252,608 | 46,022,656 | 39,993,728 | 40,075,648 |

The batched copy keeps the same buffers as before: the body buffer grows by doubling, then one completion copy. Sampled live
malloc is equal within 256 B. The peaks after are higher by at most 770,048 B of RSS and 114,664 B of footprint. With one run
per phase, run-to-run variation is not measured, so no memory change is claimed in either direction. In `repeat-distinct`, live malloc after
each release stayed at 3,843,824 B before and 3,843,888 B after, at every one of the 20 iterations: zero growth, with the owner
and the draft held throughout. That covers one allocator statistic at release points in one process. It is not a general
no-leak proof.

## Does not prove

- Installed-app or whole-host memory.
- Host and client in separate processes, a socket transport, or private-lane custody and fairness.
- Stop/status latency during a transfer; the actual host adapter must measure that.
- Store staging or verification memory.
- Any reply shape other than the maximum observation. The reader's per-call budget bounds the input it examines, not all its
  work: buffer growth and the completion copy are still bounded only by the cap.

## Reproduction

Build the Release products, then give the runner a new output directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release
python3 docs/experiments/private-editor-codec/run.py "$(mktemp -d /tmp/private-editor-codec-XXXX)"
```

The runner finds the repository from its own path and uses `.build/release` (or `.build/out/Products/Release`). It writes
`compile.log`, one NDJSON file per mode and `metadata.json`. The metadata holds the head, product status, toolchain, source,
object, module, probe and runner hashes, and any source newer than the object. Paths in the logs are replaced with placeholders.
Byte counts are deterministic for a given source. Memory and timing vary with the allocator, OS, toolchain and machine load.
