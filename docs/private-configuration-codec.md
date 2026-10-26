# Private configuration codec: implementation notes

Date: 2026-10-24. Scope: the explicit private codec of decisions 0018 and 0019, and
its bridge to `ProxyConfig`. It is headless. It has no transfer engine, store, writer
lease, socket or AppState adoption. Decisions 0018 and 0019 link here for their partial
implementation evidence. The foundation checkpoint is not edited here.

## API

Shared target `ConduitShared`, all `package` access. Nothing is `public`.

- `PrivateURLValue`, `PrivateRuntimeConfiguration`, `PrivatePlatformConfiguration`,
  `PrivateConfigurationRequest`: the values. None is `Codable`. Reflection is redacted.
- `PrivateBaseline`, `PrivateModuleSlots`, `PrivateModuleIntent`: the update's
  preconditions (see "Editor preconditions"). Not `Codable`; they hold no value.
- `PrivateConfigurationFrame.Kind` (`update`, `editorReply`) with its separately named
  caps `maxRequestFrameBytes` and `maxEditorReplyFrameBytes`.
- `PrivateConfigurationEncoder.measureBody(_:) throws -> Int`: the body length, from a
  counting pass that writes nothing. It refuses an unrepresentable value and a body past
  the loose bound described under "Frame and limits".
- `PrivateConfigurationEncoder.encode(_:) throws -> SecretBytes`: one complete frame.
- `PrivateConfigurationFrameReader(expecting:)` (`final class`, one owner, not `Sendable`):
  `consume(_:)`, `finish()`, `reset()`, `retainedByteCount`. It reads one frame of the kind
  it expects, and its body carries that kind.
- `PrivateConfigurationDecoder.decode(_:) throws -> PrivateConfigurationRequest`. It
  refuses a body of another kind before reading its bytes.
- `PrivateConfigurationWireError`: fixed text, no input echoed.

Target `ProxyControlBridge`, `package` access:

- `PrivateConfigurationBridge.makeRequest(...) throws`: kernel config and platform, plus
  the caller's baselines and module intents, to the request. It checks shared resources
  before mapping, then exact frame size.
- `PrivateConfigurationBridge.makeValues(from:localLaunchAtLogin:) throws`: request to
  kernel values. It takes the exact count first, so a request built in memory is
  bounded too. Mapping does not authorize runtime apply.
- `PrivateConfigurationBridgeError`: `tooLarge` or `resourceLimit`. Errors carry
  fixed field/limit metadata, no collection and no configuration value.

The local store-preparation correction removes the unadopted bridge's full semantic
validation gate: exact schema-two staging owns storage representability, and the
runtime owns start/subsystem eligibility. Representable invalid repair drafts stay
saveable and held as today; non-blocking feature errors do not become proxy-start
refusals. This correction is not an adopted store or apply engine.

## Frame and limits

The frame is `PCV1 <kind> <decimal length>\n<JSON body>\n`, where the kind is `Q` for an
update and `R` for an editor reply. The whole frame, header and terminator included, is at
most its kind's cap: 8,388,608 bytes for a request (`maxRequestFrameBytes`, decision 0019)
and 8,388,608 bytes for an editor reply (`maxEditorReplyFrameBytes`, decision 0034). The
two are separate constants. Every kind's prefix is seven bytes, so the arithmetic below
holds for both.

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

The header is read one byte at a time. Each byte of the expected kind's fixed prefix,
`PCV1 Q ` or `PCV1 R `, must match. The first byte that differs decides the refusal:

- position 3, the version digit: `unsupportedVersion`;
- position 5, the kind: `unexpectedFrameKind`, whether the letter names another known kind
  or none;
- any other prefix position: `malformedHeader`.

A line feed inside the prefix is one of those bytes. So `PCV\n` is `unsupportedVersion`
and `PCV1 \n` is `unexpectedFrameKind`. A line feed ends the header only after the prefix
and at least one digit. `ReferenceFrameParser` follows the same rule for either letter, and
the fixed differential cases include both counterexamples, the other prefix positions and
request frames offered to a reply reader.

## Editor preconditions (2026-10-26)

The update request no longer carries Int revisions. It names, as preconditions the caller
observed:

- `runtimeBaseline` and `platformBaseline`: each a `PrivateBaseline`, the store namespace
  (a UUID family separate from the host incarnation), the file as a
  `ControlConfigWorkflowFile`, and the store's exact `UInt64` version. The initializer
  refuses a baseline in the other file's slot. A decoded baseline is not authority: only
  the store mints tokens and decides.
- `modules`: one `PrivateModuleIntent` per module in fixed `PrivateModuleSlots` (no
  array): `saveOnly`, `applyWhileRunning(ifLifecycleRevision:)` or
  `start(ifLifecycleRevision:)`. Stop is not here; it stays ordinary.

On the wire a version is a JSON number spelled as plain decimal digits, at most 20, no
greater than `UInt64.max` (`.unsignedDecimal`). The scanner refuses a sign, fraction,
exponent, leading zero or overflow before Foundation reads it, so nothing is rounded or
narrowed. `lifecycleRevision` is a required nullable member: null for save-only, a
revision for apply and start; any other pairing is refused. The retired members
(`expectedConfigRevision`, `expectedPlatformRevision`, `expectedOwnerGeneration`) are
unknown keys. `PrivateConfigExpectedGeneration` remains only in the store's operation
context. No production caller built the old request, so nothing deployed reads it.

`PrivateEditorCodecTests` pins the `UInt64` range and refusals, the slot and component
checks, every intent in every slot, the strict pairings and the retired keys.
`pm-sim private-config-boundary` round-trips a `UInt64.max` baseline and all three
intents through every read schedule, and refuses one past the maximum, a swapped slot and
a save-only revision.

## Editor read and replies (2026-10-26)

Decision 0034 caps one editor reply at 8,388,608 bytes. This slice adds a read (`G`) and a
correlated reply (`R`) to the same frame grammar, writer, scanner and decoder:

- `PrivateEditorReadRequest`: `requestID`, `incarnation`, `budgetMilliseconds`.
- `PrivateEditorReply`: `requestID` (the request it answers), `hostIncarnation` (the
  incarnation that answered) and exactly one answer. On the wire, `admission`,
  `observation` and `refusal` are all required and nullable, and exactly one is not null.
  - `admission(ControlAdmission)` answers an update: accepted, joined or rejected. It is
    never settlement, so a lost admission is recovered through the ordinary request and
    operation lookups, by request ID.
  - `observation(PrivateEditorObservation)` answers a read.
  - `refused(ControlRejectionCode)` answers a read that was not served.
- `admission(answering:)` and `answer(answering:)` match a reply to the request a client
  sent: same request ID; an answer of the right kind; and the same incarnation, except a
  `changedIncarnation` rejection or refusal. A client drops any other reply.
- The observation holds the terminal flag, one full set of runtime, platform and
  preference values, the stored `launchAtLogin`, one `PrivateComponentState` per file
  (`verified(baseline)`, `absent(baseline)`, `retained(reason)`, with the baseline's
  component checked against its slot), and one `PrivateModuleState` per module
  (lifecycle revision, enabled, fenced). There is no whole-host generation. A client
  never retokenizes a dirty draft from an observation.
- `ControlAdmission` keeps its own `Codable` encoding: the writer embeds the bytes its
  `JSONEncoder` writes with sorted keys, and the decoder reads it through its own
  `Decodable`, then requires the member set its own encoding writes for that variant.
  No other type takes this path; private values have no `Encodable` conformance.
- The bridge has one field mapping in each direction. `makeObservation` runs the approved
  ceilings, maps with the same runtime and platform walks as the request plus one
  preferences mapping, then runs the format preflight. `makeValues(from:)` for an
  observation runs the same preflight, then maps back with the stored `launchAtLogin`.
  The preflight is `PrivateConfigurationEncoder.measureObservation`: the ceilings, then
  the reply's own observation writer through a counting sink, so a non-finite number is
  `invalidValue` exactly as in the reply and the request bridge, with no second field
  walk. It counts the observation alone and invents no request ID or incarnation: the
  host puts the observation in a reply with the real envelope, and only the reply encoder
  counts the complete frame against the reply cap. Format, not eligibility: a
  start-blocking repair draft maps both ways and keeps its classification.

**Maximum observation.** `Tests/ConduitTests/Fixtures/PrivateEditorMaximumFixture.swift`
imports only `ConduitShared` (no XCTest, no `@testable`), so a Release probe can compile it
with `-package-name conduit`. Every approved count and UTF-8 ceiling comes from
`DomainResourceField`; every text byte is a six-byte escape; the bypass list sits exactly on
its canonical aggregate; numbers take their widest spelling and baselines are `UInt64.max`.
It is a wire-width maximum, not a storability claim. Its reply body counts **7,487,859
bytes** (frame 7,487,875), under the 8,388,608-byte cap by 900,733 bytes, in the
debug counting pass, which is deterministic. `PrivateEditorReplyCodecTests` pins it, and
round-trips the full reply through the reader and decoder. Release lifetimes, host and
client coexistence and Stop/status latency are not measured here.

**Receipt deferred.** No causal receipt type exists yet. The merge of current explicit
lifecycle intent into whole-configuration saves (decision 0015) is not implemented, and
today only `dns.forwarderEnabled` is lifecycle-owned in the stored values, so the committed
intent a client must rebase from is not defined. Before live adoption, the workflow cut
must define a bounded receipt that:

- names the original update's request ID, separate from the correlation of the reply or
  lookup that carries it, and is kept only when it matches the expected incarnation and
  request;
- carries one outcome per written file through `ControlConfigWorkflowWrite` and its
  existing serialization, with the new baseline only for persisted or unchanged;
- carries the actually committed lifecycle intent, or an equivalent, so a client rebases
  its canonical enable values causally and never marks an older draft clean blindly;
- carries one result per module, where a failure names a `ControlFailureCode`;
- keeps a busy store distinct from a persistence failure, beside the operation's own
  admission.

Its transport (ordinary operation lookup or a private answer) and how a baseline is coded
there are chosen with that cut. Until then a client has no way to advance a draft's
baselines after an update, so this codec is not adoptable alone.

Evidence: `PrivateEditorReplyCodecTests` (reads, every admission and refusal, admission
bytes against its own encoding, strict answer presence and variant members, every
component and module state, slot checks, a start-blocking draft returned unchanged, both
matchers, reply exact cap and one over, the maximum fixture's bounds and size, redaction),
`PrivateConfigBridgeTests` (observation both ways with the stored `launchAtLogin`, refusals),
`PrivateConfigResourceReviewTests` (read and reply tables against encoder output) and
`pm-sim private-editor-codec`. Headless codec evidence does not prove an owner turn,
fences, store admission, the private lane or client draft behavior.

## Shared resource preflight

`DomainResourceCheck.configuration` is the one typed traversal through
representation-only kernel/private-request views. Adapters expose existing stored
values; they keep no second limit/order policy or mapped arrays merely for sizing.
The streaming scanner follows byte order and reuses neutral limits and scalar/list
counters. The earlier lower-bound walk was removed rather than retained beside
this check. Exact private encoding size still accounts for escaping and framing.

## Canonical bypass width and token guard

The bypass list (`noProxyHosts`) has a canonical JSON width of at most 8,192 bytes (decision 0021). The width is what `JSONEncoder` writes by default, counted instead of written. The scanner charges each item as it closes, so an over-limit list is refused before any later byte is read. The typed checks, in `ConduitShared` and in `ProxyKernel`, charge the same way, in wire order: the count, then each item's own ceiling, then the aggregate.

- **Counted per scalar** (`CanonicalJSONWidth`): `"`, `\`, `/` and the short escapes take 2 bytes; other controls take 6 (`\u00XX`); other ASCII takes 1; everything else takes its UTF-8 length. The solidus is escaped by default. On the toolchain that ran the differential test, U+2028 and U+2029 are written raw, at 3 bytes.
- **Decoded value, not wire spelling.** `a` and `a` both take 1 byte. The physical body is still bounded by the 8 MiB frame cap, so an escape-heavy list can exceed 8,192 wire bytes and still be accepted when its canonical width fits.
- **No buffer.** The scanner keeps a running sum, and the typed checks use the same counter. The earlier typed check encoded the list with `JSONEncoder`. `ProxyBypassSyntax` now uses the same canonical counter, and tests pin it to the boundary.
- **Known difference.** For a list past its count, the scanner refuses the first bad item it reads, and the typed check refuses the count first. Both are resource refusals, but they can name different fields. The scanner reads at most 256 items before the count refusal, so the cost stays bounded.

**Token guard (64 bytes).** This is a lexical guard of the token grammar, not a product ceiling. A valid identifier is a canonical UUID of 36 bytes (`UUID(uuidString:)`), and every enumeration raw value the private decoders accept in a token place is 20 bytes or less: the widest is the retained reason `changedSinceBaseline`. Baseline namespaces and admission operations are UUIDs; baseline components, intent actions, component states, retained reasons, rejection codes and admission types are closed raw values. So no valid token is refused. A longer token is malformed and the scanner refuses it as `malformedBody`, not as `resourceLimitExceeded`. `ConfigurationResourceCanonicalWidthTests` derives those lengths from the decoder's own types, including every enumeration the read, update and reply decoders accept, and pins the widest.

Evidence in the repository, all headless:

- `ConfigurationResourceCanonicalWidthTests` ([file](../Tests/ConduitTests/ConfigurationResourceCanonicalWidthTests.swift)): a differential against `JSONEncoder` for every Unicode scalar value, plus the named classes; the wire boundary at exactly 8,192 bytes and one byte over; escaped spellings; raw and escaped solidi; agreement with `ProxyBypassSyntax` at the same boundary; the item-before-aggregate order; and the token derivation.
- `PrivateConfigResourceReviewTests` ([file](../Tests/ConduitTests/PrivateConfigResourceReviewTests.swift)): the aggregate is refused before a later malformed suffix, and it is counted canonically, not physically.
- `ConfigurationResourceLimitsTests` ([file](../Tests/ConduitTests/ConfigurationResourceLimitsTests.swift)): every string place and count at exactly its ceiling and one over, in the kernel and in the scanner.
- The scanner and its shared counter: [`PrivateConfigurationDecoder.swift`](../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationDecoder.swift), [`DomainResourceLimits.swift`](../Sources/ConduitShared/DomainResourceLimits.swift).

Does not prove: the startup, file, or import boundary; runtime admission; the app's own bypass validation moving onto the shared counter; real-machine behavior; or release-build memory.

## Resource traversal ownership

- **Authoritative typed traversal.** `DomainResourceCheck.configuration(_:)` in `ConduitShared` is the only place that assigns a field to a resource place, sets the wire order, and applies counts, element ceilings and the bypass aggregate. It reads a `ConfigurationResourceSource`.
- **Representation-only adapters.** The kernel check (`ProxyConfig.resourceViolation()`) and the private check (`PrivateRuntimeConfiguration.resourceViolation()`) only map their stored values and URL byte counts to that protocol. They hold no limit, order or refusal.
- **Streaming grammar.** The decoder's scanner is a separate traversal in byte order. It refuses before Foundation decodes, accepts members in any order, and never builds a typed projection. It shares `DomainResourceField`, `DomainResourceCheck.entries`, `utf8` and `encodedBytes` with the typed walk, but not the walk itself.
- **Bypass size.** The size of a bypass list is measured by `CanonicalJSONStringList`, not by encoding it. The entry bound is `DomainNameSyntax.maxLength`, so each number has one source.

## Grammar agreement and intentional refusals

`PrivateConfigGrammarDifferentialTests` runs full schema-shaped bodies through the real decoder and through `JSONSerialization`. The bodies are the encoder's output for the sample, changed by byte-level edits. Each body is decoded, and for agreement the decoded request must re-encode to the canonical body.

Agreement (both parsers accept, and the values match):

- Finite Double lexemes in a Double field: `0`, `-0`, `2.50`, `2E+1`, `1.5e3`, `-1.25E-2`, `1e300`, `4.9e-324`, and others. The expected values come from Swift's `Double(String)`.
- Malformed JSON numbers, such as `01`, `1.`, `.5`, `+1`, `1e`, `NaN`, `Infinity`, `0x1F`, and `1 2`: both refuse.
- Raw and escaped valid strings, surrogate pairs, the short escapes, escaped controls, DEL, and U+2028/U+2029, raw and escaped.
- JSON whitespace (space, tab, LF, CRLF) between tokens and around the body. Member order is changed at every depth by 24 fixed seeds, with alternating whitespace.
- An integral-valued fraction in an Int field, `5000.0`, decodes to 5000. This keeps existing behavior: Foundation preserves the value, so no contract is changed. A non-integral one, `5000.5`, is refused.

Intentional stricter refusals. The scanner refuses these, and Foundation's verdict is asserted only where stated:

- Duplicate keys, including one spelled with `\u` escapes. Foundation accepts, which the test asserts. The scanner refuses.
- Unknown keys. Foundation accepts, which the test asserts. The scanner refuses by name, before the value is read.
- Raw bytes below 0x20 in a string, lone or mismatched surrogate escapes, and invalid, overlong, surrogate-encoded or truncated UTF-8. Foundation's verdict is not asserted.
- Vertical tab and form feed between tokens. They are not JSON whitespace.
- Lexemes that overflow Double, such as `1e400`, are refused by the decoder's finite check.
- A 1,025-byte profile name is refused as its 1,024 ceiling. Foundation accepts, which the test asserts. A 1,024-byte value agrees.
- Depth. The bound of eight is structural. The schema reaches depth five through known keys, and an unknown key is refused by name first, so no body in the test reaches the bound. It is not tested separately.

Does not prove: an exhaustive grammar; behavior of Foundation versions other than the one that ran the test; or nested-value fuzzing.

## Error mapping

- The decoder reports every decode failure as `malformedBody`. That includes a value the
  typed domain refuses, such as port `70000` (`WireValue` raises `invalidValue`, and the
  decoder's catch turns it into `malformedBody`). This is deliberate. The error names no
  field, and the tests pin it. No finer taxonomy is claimed. A token past its guard is
  `malformedBody` too (see "Canonical bypass width and token guard").
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
2. **Duration NaN and out-of-range upstream ports (D2, separate field types).** `validate()` has no check for
   `upstreams[].port` (an Int), while duration `NaN` passes the non-negative and positive checks. So
   `makeRequest` can succeed, and the later `encode` throws `invalidValue` with no field
   name. No data is written wrongly, because the writer refuses. Tracked in #224.
3. **Receiver memory before validation.** `makeValues` takes the exact count, but not the
   preflight, so dense decoded arrays exist before `validate()` rejects them. The cost is
   measured above for valid frames only.
4. **Error taxonomy at call sites.** See "Error mapping".
5. **Stop latency.** Not measured. The 16 KiB `consume` and the completion copy are
   bounded by the cap, not by time.
6. **Scanner differential test.** Partly closed. The canonical-width counter is differential-
   tested against `JSONEncoder` for every scalar value, and the scanner's key tables are
   compared with `JSONSerialization` output. The scanner's grammar decisions (escapes,
   numbers, nesting, and the ordering of refusals) have only the bounded differential in
   "Grammar agreement and intentional refusals". That is not an exhaustive grammar proof, and
   nesting depth is not exercised. Only the frame grammar has `ReferenceFrameParser`.
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

The owner then explicitly rejected supporting millions of providers and requested sane limits. The [resource-bounds review](design-runtime-configuration-bounds-review.md) proposes early schema-aware rejection and shared domain limits before further adoption. The speculative packed-array optimization was stopped before it edited source. Two proposed-profile fixtures measured17.4/19.3MB peak RSS with the same codec, as recorded in the [probe note](experiments/private-configuration-codec/README.md). The owner subsequently selected the domain/startup policy in0021 and remaining string categories/legacy compatibility in0022. Enforcement remains under implementation, not adopted.

## Canonical width and token guard pass (2026-10-24)

The focused verification script of this pass built the package and ran 115 focused tests with zero failures. That includes the six `PrivateConfigResourceReviewTests` witnesses, the nine `ConfigurationResourceCanonicalWidthTests` and the nine `PrivateConfigGrammarDifferentialTests`. The kernel import fence, the event catalogue, the decision records and both pm-sim scenarios (`private-config-boundary`, `config-resource-bounds`) also passed. This is headless fixture evidence. It is not owner validation, real-machine evidence or an adoption claim. The file, startup and import boundaries are unchanged, and their enforcement is still open.
