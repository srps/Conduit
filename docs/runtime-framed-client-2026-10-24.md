# Framed runtime client: architecture and verification (2026-10-24)

Scope: slice 1 of [decision 0014](decisions/0014-runtime-client-stream.md). It is one `RuntimeClient`
over a package byte transport, in `ConduitShared`. It has no host, engine, `RuntimeActor`, store,
private configuration, AppState adoption or production socket.

## Architecture

- `ControlRuntimeTransport` (`RuntimeTransport.swift`): `exchange` and `openStream` take one complete
  request frame, the explicit `ControlFrameLimits` for the reply, and the caller's `RuntimeDeadline`.
  `ControlRuntimeStream.next` returns one complete frame, with its line feed. `cancel` is idempotent
  and never stops the host. `ControlRuntimeTransportFailure` is `notSent` or `sent`.
- `FramedRuntimeClient` (`FramedRuntimeClient.swift`): the same v2 codec for every message.
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
| Typed `notSent` from the transport | `notSent(end)` |
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

Strict-JSON boundary witness, before the fix (same wrapper, same tests): `ControlRuntimeStrictJSONTests`
ran 6 tests with 14 failures. The current codec accepted 14 malformed values inside an unknown field of
an otherwise valid known v2 frame: a lone high surrogate, a lone low surrogate, a high surrogate before a
non-surrogate escape, a high surrogate before a literal character, an unknown escape letter, a raw
control character, invalid UTF-8, an overlong sequence, an encoded surrogate, a truncated sequence, a
leading-zero number, a number with no fraction digit, a misspelled literal, a trailing comma, and a
malformed string nested in an object. Only an unterminated string was refused, by Foundation. The valid
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
over synthetic transports only.
