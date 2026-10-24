# Private configuration codec: implementation notes

Date: 2026-10-24. Scope: the explicit private codec of decisions 0018 and 0019, and
its bridge to `ProxyConfig`. It is headless. It has no transfer engine, store, writer
lease, socket or AppState adoption. Decisions 0018 and 0019 link here for their partial
implementation evidence. The foundation checkpoint is not edited here.

## API

Shared target `ConduitShared`, all `package` access. Nothing is `public`.

- `PrivateURLValue`, `PrivateRuntimeConfiguration`, `PrivatePlatformConfiguration`,
  `PrivateConfigurationRequest`: the values. None is `Codable`. Reflection is redacted.
- `PrivateConfigurationEncoder.measureBody(_:) throws -> Int`: the body length, from a
  counting pass that writes nothing. It refuses an unrepresentable value and a body past
  the loose bound described under "Frame and limits".
- `PrivateConfigurationEncoder.encode(_:) throws -> SecretBytes`: one complete frame.
- `PrivateConfigurationFrameReader` (`final class`, one owner, not `Sendable`):
  `consume(_:)`, `finish()`, `reset()`, `retainedByteCount`.
- `PrivateConfigurationDecoder.decode(_:) throws -> PrivateConfigurationRequest`.
- `PrivateConfigurationWireError`: fixed text, no input echoed.

Target `ProxyControlBridge`, `package` access:

- `PrivateConfigurationBridge.boundedLowerBound(_:) -> Int?`: a refusal test before
  mapping. It returns nil once the bound passes the frame cap.
- `PrivateConfigurationBridge.makeRequest(...) throws`: kernel config and platform to
  the request. It refuses by bound first, then runs `ProxyConfig.validate()`.
- `PrivateConfigurationBridge.makeValues(from:localLaunchAtLogin:) throws`: request to
  kernel values. It takes the exact count first, so a request built in memory is
  bounded too, then validates.
- `PrivateConfigurationBridgeError`: `tooLarge`, or `invalidConfiguration(firstCheck:
  failureCount:)`. `firstCheck` is one `ConfigValidationError.check` field code. The
  error carries no collection and no value.

## Frame and limits

The frame is `PCV1 Q <decimal length>\n<JSON body>\n`. The whole frame, header and
terminator included, is at most 8,388,608 bytes (`PrivateConfigurationFrame.maxFrameBytes`).

- The exact frame size of a body of `N` bytes whose length has `D` decimal digits is
  `N + D + 9`. `PrivateConfigurationFrame.frameByteCount(bodyCount:)` computes it, and the
  reader and the decoder both use it. So a body with a seven-digit length is at most
  8,388,592 bytes, and a body of 8,388,593 bytes is refused whatever it holds.
- Oversize lengths are refused in the header, before any body byte is stored.
- The decoder checks the same exact size before it scans, copies or allocates. A body
  held in memory never passed the reader's header check, so the decoder does not rely on
  it. `PrivateConfigReviewRegressionTests` pins this, including an oversize body of
  invalid JSON, which must be refused as too large and not as malformed.
- Zero length: the reader refuses `PCV1 Q 0`. The decoder refuses an empty or
  whitespace-only body as `malformedBody`, because its frame is far under the cap.
- The encoder's counting pass refuses a body past `cap - 10`, the smallest frame
  overhead. For a body between 8,388,593 and 8,388,598 bytes, `measureBody` returns the
  count, and `encode` then applies the exact size and throws `frameTooLarge`. `encode`
  never truncates.
- Each `consume` examines at most 16,384 input bytes. That bounds input examined. It
  does not bound all work in the call:
  - growing the body buffer copies the bytes it already holds, at most the cap;
  - the call that completes a frame copies the body into `SecretBytes` and scrubs the
    buffer, at most the cap.
- Peak memory while a body is held is about two body lengths during completion. The
  decoder's `Data` copy adds one more, and none of the copies made outside the buffer
  is scrubbed (see "Copies and scrubbing").
- A body held by the reader has one owner. Do not share a reader between tasks. Run it
  off the main actor when a stop must stay short. Stop latency is not proven.

## Header grammar

The header is read one byte at a time. Each byte of the fixed prefix `PCV1 Q ` must
match. The first byte that differs decides the refusal:

- position 3, the version digit: `unsupportedVersion`;
- position 5, the kind: `unknownFrameKind`;
- any other prefix position: `malformedHeader`.

A line feed inside the prefix is one of those bytes. So `PCV\n` is `unsupportedVersion`
and `PCV1 \n` is `unknownFrameKind`. A line feed ends the header only after the prefix
and at least one digit. `ReferenceFrameParser` follows the same rule, and the fixed
differential cases include both counterexamples and the other prefix positions.

## Preflight bound (bridge)

`boundedLowerBound` charges a budget that starts at the frame cap:

- each string: its raw UTF-8 bytes plus two quotes;
- each object in an array: 2 braces plus a floor of 4 bytes per member (6, 4, 4 or 8
  members, by type);
- each array item, including each string in an array.

It stops at the first charge past the cap, so an oversize input costs no more than the
cap. Escapes and separators only add to the real size, so the bound never exceeds the
encoded body. The bound covers stored values only. Top-level fixed structure is not
charged, which keeps it a lower bound.

Cost of the walk: `String.utf8.count` is constant time for native strings. A bridged
NSString may be copied to count its bytes. The existing editor object's memory is not
covered by this bound.

## Error mapping

- The decoder reports every decode failure as `malformedBody`. That includes a value the
  typed domain refuses, such as port `70000` (`WireValue` raises `invalidValue`, and the
  decoder's catch turns it into `malformedBody`). This is deliberate. The error names no
  field, and the tests pin it. No finer taxonomy is claimed.
- The writer raises `invalidValue` for a non-finite number and for a port outside
  0...65535. It never truncates.
- `encode` can throw `frameTooLarge` after `measureBody` has passed. Escape expansion
  (for example `"` or `\u0001`) adds bytes after the count. A caller must handle this
  wire error as well as the bridge's `tooLarge`.

## Copies and scrubbing

The codec scrubs only the buffers it allocates itself (`PrivateFrameBuffer`): frame
bytes and body bytes. It zeroes them on growth, on `reset`, on failure and on release.
`SecretBytes` zeroes its storage on release.

These copies are not scrubbed. They are temporary Swift values, and the codec does not
promise that their plaintext is zeroed (0018 §2–3):

1. Decoder key copies. The scanner captures the unescaped bytes of every object key into
   an ordinary `[UInt8]`, and keeps them in a `Set` for the duplicate check. A malformed
   key can hold token-like text. These arrays are released without zeroing.
2. Scanner escape strings. A key that contains an escape is rebuilt through a temporary
   `String` for each escape.
3. The decoder's `Data(bytes)` copy of the whole checked body.
4. `JSONDecoder`'s own `String` and value copies, one per decoded string. This includes
   every URL before it becomes a `PrivateURLValue`, which then holds its bytes in
   `SecretBytes`.
5. Encoder string copies. `writeString` takes a mutable copy of its `String` to read its
   UTF-8, which may allocate.
6. The decoded `String`s and `PrivateURLValue`s that the caller keeps. They are the
   caller's values, not the codec's.

Redaction is hygiene for logs and reflection. It is not a claim that all plaintext is
erased from memory.

## Resource probe (evidence, not an adoption claim)

[`docs/experiments/private-configuration-codec`](experiments/private-configuration-codec/README.md)
measured the production codec and bridge in fresh scratch processes, with synthetic
values only. Each case is one process, a debug build on arm64, and the peak is
`getrusage` `ru_maxrss` in bytes:

| Fixture | Complete frame | Peak RSS | End-to-end wall time |
| --- | ---: | ---: | ---: |
| 100,000 empty DoH provider strings | 302,177 B | 34,455,552 B | 0.213 s |
| 1,000,000 empty DoH provider strings | 3,002,178 B | 239,173,632 B | 1.979 s |
| 2,700,000 empty DoH provider strings | 8,102,178 B | 574,554,112 B | 5.269 s |
| 8,000,000-byte profile string | 8,002,255 B | 55,164,928 B | 2.540 s |

The densest of the four fixtures, 2,700,000 empty DoH strings at 8,102,178 bytes, reached
574,554,112 bytes. The probe kept every pipeline form alive through the last measurement,
so this is a measured retained-pipeline peak for that fixture, not a steady state or a proven upper bound. The 8 MiB cap is not a
memory budget, and the probe does not measure release builds, receiver-only lifetime or
Stop latency. The probe's numbers are not a pass threshold.

## Adoption gates (open, not claimed)

These are open. None is closed by this pass.

1. **Finite durations trap in the kernel (D1).** `ConfigValidation` checks only `>= 0`
   for several timeouts and TTLs. A finite value such as `1e300` passes `validate()`, and
   the kernel then converts it with `Int(Double)` or `Int64(Double)`. That traps on save
   (`ProxyConfig.swift`), on the probe path (`ConnectionPool.swift`), and on the request
   path. Tracked in #224. The kernel is unchanged in this slice, and the codec does not
   quantize or clamp the seconds.
2. **NaN and out-of-range upstream ports (D2).** `validate()` has no check for
   `upstreams[].port`, and `NaN` passes the non-negative and positive checks. So
   `makeRequest` can succeed, and the later `encode` throws `invalidValue` with no field
   name. No data is written wrongly, because the writer refuses. Tracked in #224.
3. **Receiver memory before validation.** `makeValues` takes the exact count, but not the
   preflight, so dense decoded arrays exist before `validate()` rejects them. The cost is
   measured above for valid frames only.
4. **Error taxonomy at call sites.** See "Error mapping".
5. **Stop latency.** Not measured. The 16 KiB `consume` and the completion copy are
   bounded by the cap, not by time.
6. **Scanner differential test.** The JSON scanner has no differential or fuzz test
   against `JSONSerialization`. Only the frame grammar has `ReferenceFrameParser`.
7. **Release-build memory and steady state.** Not measured.
8. **Count limits, schema evolution and new cap values.** Not introduced here. The
   owner's choices in 0018 and 0019 are unchanged.

## Review corrections (2026-10-24, second pass)

- The decoder now checks the exact frame size before it scans or copies. Before this,
  a valid body padded to `cap - 15` bytes was accepted directly.
- A line feed inside the fixed prefix is classified by position, as in the reference.
  Before this, `PCV\n` and `PCV1 \n` were reported as `malformedHeader`.
- The arithmetic in "Frame and limits" was wrong in the earlier notes. A body with a
  seven-digit length is at most 8,388,592 bytes, not 8,388,598.
- The error flattening and the key copies are now documented where they happen, and
  in this note.
- D1 and D2 are documented as open adoption gates. The kernel is not changed.

## Results

Claude implemented and corrected the codec through the owner's claude.ai Max subscription; a separate Claude pass reviewed the actual code read-only. Codex reviewed the patch, added and executed the direct-decoder cap witness, measured the resource probes, and ran the final focused wrapper after Claude could not invoke Bash in its correction session.

On corrected source: Xcode-prefixed debug build, **174 selected tests with zero failures**, kernel import fence, event catalogue, decision checks with history, and `pm-sim private-config-boundary` (**11 assertions**) passed. The earlier 170-test result predates the final decoder/header regressions. Full workflow-equivalent gates will be recorded separately after integrating the preceding lease foundation; the first 39-command run was superseded by source corrections and is not final evidence.

## Limits and what is not claimed

- These are headless fixture results. They are not a benchmark, a latency measurement,
  or real corporate-VPN evidence.
- No adoption readiness is claimed. The adoption gates above are open.
- Full workflow-equivalent and hosted checks remain separately tracked until complete. The independent review was read-only, not a second execution of the suite.
- The SecretBytes scrub covers only the buffers the codec allocates. It does not cover
  the `Data`, `String` or `JSONDecoder` copies made later.

## Stable full checkpoint and owner limits review

The corrected codec stacked over the lease foundation passed all 39 local workflow-equivalent gates on unchanged source at206e478: 2,631 tests, two skips, zero failures;87 simulator results; perf10.14s /34,078,720B RSS. Relevant-source SHA256 before/after: `8827441b6fe8ed002c95a0ca4566579e693e797278f5b7b819450a3650ebfe89`. This is correctness evidence for an unadopted foundation, not memory-budget acceptance.

The owner then explicitly rejected supporting millions of providers and requested sane limits. The [resource-bounds review](design-runtime-configuration-bounds-review.md) proposes early schema-aware rejection and shared domain limits before further adoption. The speculative packed-array optimization was stopped before it edited source. Two proposed-profile fixtures measured17.4/19.3MB peak RSS with the same codec, as recorded in the [probe note](experiments/private-configuration-codec/README.md). No new limits, startup compatibility policy or ADR are selected yet.
