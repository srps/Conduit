# Framed runtime client: architecture and verification (2026-10-24)

Scope: slice 1 of [decision 0014](decisions/0014-runtime-client-stream.md). It is one `RuntimeClient`
over a package byte transport, in `ConduitShared`. It has no host, engine, `RuntimeActor`, store,
private configuration, AppState adoption or production socket.

## Architecture

- `ControlRuntimeTransport` (`RuntimeTransport.swift`): `exchange` and `openStream` take one complete
  request frame, the explicit `ControlFrameLimits` for the reply, and the caller's `RuntimeDeadline`.
  `ControlRuntimeStream.next` returns one complete frame, with its line feed. `cancel` is idempotent
  and never stops the host. `ControlRuntimeTransportFailure` is `notSent` or `sent`.
- `makeFramedRuntimeClient` (`FramedRuntimeClient.swift`): the one package seam. It returns `any RuntimeClient`
  and constructs the file-private `FramedRuntimeClient` adapter, which runs the same v2 codec for every message.
  `ControlRuntimeCodec.decodeFullFrame` is the one full-frame check. It enforces size before parsing,
  one trailing line feed, and no second frame.
- Timers: the transport owns every wait and timer. The client checks the deadline once before a send,
  refuses a cancelled task before a send, and passes the same absolute deadline down. It claims no
  socket deadline enforcement.

## Error provenance

| Situation | Result |
| --- | --- |
| Encoding or size refusal, before any send | `localRefusal(code)`, transport not called |
| Deadline passed or task cancelled, before a send | `notSent(end)`, transport not called |
| Budgeted call (`submit`, `lookupAdmission`, `outcome`) whose budget rounds to zero, before a send | `notSent(deadlineExpired)`, transport not called; a cancelled task is `notSent(cancelled)` first |
| Typed `notSent` from the transport | `notSent(end)` |
| Raw `RuntimeWaitEnd` from the transport (possible send) | keeps its reason: `admissionUnknown(requestID, end)` for a mutation, `readAborted(end)` for a read or a stream open |
| Submit: sent failure, or untyped error | `admissionUnknown(requestID, end)`, one call, never resent |
| Submit: malformed, incomplete, overlimit, multi-frame, wrong correlation, wrong kind | `admissionUnknown(requestID, invalidReply)` |
| Submit: host failure with the request's correlation | `wire(code)` |
| Read: sent failure, or untyped error | `readAborted(end)` |
| Read: malformed or wrong reply | `unexpectedReply` |
| Read: host failure with correlation | `wire(code)` |
| `next` on a deadline or a cancel | `readAborted(end)`, no frame consumed, stream still valid |
| `next` while another is in flight | `readInProgress`, transport not touched |

## Stream handle

- The first frame must be the baseline. A typed end or a host failure may come first instead.
- The baseline's incarnation is retained. A later snapshot from another incarnation ends the stream
  with `unexpectedReply`, even when its correlation matches.
- Allowed wait failures are `deadlineExpired`, `cancelled` and a Swift `CancellationError`. Each
  ends the wait with `readAborted(...)`, and the stream stays valid with no frame consumed.
  `disconnected`, `invalidReply` and any untyped error are terminal. They release the stream.
- The first terminal state wins, including for a wait in flight. An explicit cancel recorded
  during a wait is reported in place of a timeout or disconnect that ends that wait afterwards.
- A frame that breaks the protocol (wrong correlation, a second baseline, an oversize or concatenated
  frame, a response) ends the stream with `unexpectedReply`.
- Scope: event cursor order, replay continuity and gap handling are not validated here. They belong
  to the engine and its model, which remain separate work.
- A typed `end` ends it with `streamClosed(reason)`.
- Terminal state is entered once. The transport's `cancel` runs once, outside any lock, on an
  explicit cancel, on a terminal end, on a broken stream, or when the last handle is dropped.
- A frame that lands after a cancel is dropped and never delivered.
- Locks are `NSLock` leaf locks. Nothing is held across an await, and no external callback runs under a lock.
- No task is created per frame. No queue or collection grows.

## Independent-review corrections

Three narrow corrections. They touch only `FramedRuntimeClient`, the `wireBudget` doc in `RuntimeClient.swift`,
`ControlRuntimeCodec.decodeFullFrame`, and the framed-client tests.

- Raw wait ends keep their reason. A `RuntimeWaitEnd` thrown by the transport from `exchange` or `openStream` is a
  possible send, so it maps to `.sent(end)`. A mutation gives `admissionUnknown(requestID, end)`. A read or a stream
  open gives `readAborted(end)`. Only a typed `ControlRuntimeTransportFailure.notSent` asserts that nothing was sent.
  An untyped error stays `disconnected`. Host failures, local refusals and typed `notSent` keep their meanings.
- A zero wire budget is never sent. The budget is still the existing `RuntimeDeadline.wireBudget` arithmetic, read
  through `ControlWireBudget.rawValue`. Zero also comes from under a millisecond left, or a cap under one millisecond,
  because the rounding is down. `submit`, `lookupAdmission` and `outcome` refuse zero as `notSent(.deadlineExpired)`
  before the transport is called. A cancelled task is `notSent(.cancelled)`, checked first. The budget reads the clock
  once per call, and the live check after encoding reads it again, so an expiry in between sends nothing.
  `readPage`, `readSnapshot` and `subscribe` carry no budget and keep the absolute-deadline check.
- `decodeFullFrame` keeps the size check and the required single trailing line feed. Then `decodeFrame` makes one
  interior line-feed scan of the payload and refuses any line feed it finds, as it did before. Priority is unchanged:
  size, trailing feed, payload line feed, then version, kind and body. The strict JSON walk and Foundation's
  `JSONDecoder` still traverse the JSON bytes after that scan, so this is one scan for line feeds, not a single pass
  over the whole decode.

Limits of these claims:

- The wire budget is the time left when the request was encoded. It is an upper bound on the receiver's wait, not an
  exact figure at the moment of send.
- The client passes the same absolute deadline to the transport and starts no timer. No production transport exists in
  this slice, so no deadline enforcement is measured here. The contract is only that the transport receives the
  deadline and owns the wait.
- No host zero-budget policy is defined, and the wire schema is unchanged. Zero is still a valid wire value. This
  client just never sends it.

## Package seam (module-boundary correction)

The concrete adapter is no longer a `package` type. `FramedRuntimeClient` is file-private, and its initializer and
protocol methods are internal to that file, not `package`. The only package declaration in the file is
`makeFramedRuntimeClient(transport:limits:wireBudgetCap:now:makeCorrelation:) throws -> any RuntimeClient`. It owns the
defaults for `now` and `makeCorrelation`, and it refuses a non-positive `wireBudgetCap`. The adapter's initializer has no
defaults. The framed-client tests and `pm-sim
framed-runtime-client` construct through it, and their helper returns `any RuntimeClient`. No other target names
the adapter. No behavior, wire, host, store or policy changed, and no test was added to mirror the implementation.

## Verification

Authorized command: `bash /private/tmp/conduit-runtime-stage1-20261024/verify-framed-client.sh`
(`swift build`, focused `swift test`, `check-kernel-imports.py`, `check-event-catalogue.py`,
`check-decisions.py --require-history`, `pm-sim framed-runtime-client`).

Result, final freeze run, 2026-10-24, on this checkout's working tree after the strict-JSON boundary fix, logs under
`/private/tmp/conduit-runtime-stage1-20261024/framed-client-checks`. The script printed PASS.

- `swift build`: complete. The warnings are in `ProxyConfigPersistence.swift` and
  `pm-sim/DNSResolverScenarios.swift`, neither of which this slice touched. None is in the new files.
- Focused `swift test --filter 'FramedRuntimeClient|RuntimeClient|ControlRuntime|RuntimeConfigSizing|RuntimeSnapshotProjection'`:
  156 tests, 0 failures. `FramedRuntimeClientTests` ran 26 of 26. `ControlRuntimeStrictJSONTests` ran 6 of 6.
- `check-kernel-imports.py`: passed (103 Swift files).
- `check-event-catalogue.py`: passed (207 event names). The slice emits no events.
- `check-decisions.py --require-history`: passed.
- `pm-sim framed-runtime-client`: PASS, 10 of 10 assertions.

Correction run, 2026-10-24, after the three corrections above, the header and note edits, and the fixed-shape
clock fixture. It used the same wrapper and overwrote the logs in `framed-client-checks`. The script printed PASS.

- `swift build`: complete, with no compiler warnings in the changed files.
- Focused `swift test`: 163 tests, 0 failures (0 unexpected). `FramedRuntimeClientTests` ran 33 of 33, which is the
  26 from the freeze run plus 7 new methods. `ControlRuntimeStrictJSONTests` ran 6 of 6.
- `check-kernel-imports.py`: passed (103 Swift files).
- `check-event-catalogue.py`: passed (207 event names).
- `check-decisions.py --require-history`: passed.
- `pm-sim framed-runtime-client`: PASS, 10 of 10 assertions.

Module-boundary correction run, 2026-10-24, on the final source after the package seam, with defaults only on
`makeFramedRuntimeClient`. It used the same wrapper and overwrote the logs. The script printed PASS.

- `swift build`: complete, with no warnings in `build.log`.
- Focused `swift test`: 163 tests, 0 failures (0 unexpected). `FramedRuntimeClientTests` ran 33 of 33 and
  `ControlRuntimeStrictJSONTests` ran 6 of 6.
- `check-kernel-imports.py`: passed (103 Swift files).
- `check-event-catalogue.py`: passed (207 event names).
- `check-decisions.py --require-history`: passed.
- `pm-sim framed-runtime-client`: PASS, 10 of 10 assertions.

Strict-JSON boundary witness, before the fix (same wrapper, same tests): `ControlRuntimeStrictJSONTests`
ran 6 tests with 14 failures. The pre-fix codec accepted 14 malformed values inside an unknown field of
an otherwise valid known v2 frame: a lone high surrogate, a lone low surrogate, a high surrogate before a
non-surrogate escape, a high surrogate before a literal character, an unknown escape letter, a raw
control character, invalid UTF-8, an overlong sequence, an encoded surrogate, a truncated sequence, a
leading-zero number, a number with no fraction digit, a trailing comma, and a malformed string nested in
an object. Of the 17 malformed cases in that corpus, three were already refused by Foundation: a short
unicode escape, an unterminated string, and a misspelled literal. The valid
extensions, the byte fixtures and the priority tests passed before the fix, as they do after it.

The fix is in the same decode path, `ControlRuntimeCodec.decodeFrame`. After classification and before the
typed decode, a strict walk with the shared `JSONByteCursor` checks the whole payload and requires its end.
The walk is `skipValue` with the payload size as its depth bound, so no valid payload is refused. It
materializes no value, and a valid `1e400` is skipped without a Double conversion. The order stays size,
version, kind and body type, then classification, then the strict walk, then the typed decode. The
unsupported-version, unknown-kind and oversize priority tests are unchanged and still pass.

Not run here: the full `swift test`, `pm-sim all`, `scripts/perf-gate.sh`, and the other
workflow-equivalent gates. Those belong to the broader gate, and they are not claimed for this slice.

## Does not prove

Production host fences, admission order, retention, global body admission, working-memory bounds,
the engine, the full client-engine behavior, or any machine effect. The tests and the simulator run
over synthetic transports only. It also does not prove the host or store, a production socket transport,
any model, or that a real transport enforces a deadline or the exact remaining time at send.
