# 0014: Async runtime client and bounded observation contract

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 implementation checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The existing synchronous DaemonClient and thin ControlDaemonStatus cannot supply
AppState's presentation inventory or subscriptions. A local shortcut would defer
semantic bugs until the daemon switch. The owner agreed with the recommendations
and authorized staged implementation in [#186](https://github.com/srps/Conduit/issues/186).

## Decision

Use one async typed RuntimeClient with Codable/Sendable control values and stable
errors. Commands express explicit intent and relevant generation preconditions;
no toggle derived from a stale UI snapshot. Separate admission/join/rejection
from operation settlement and bounded outcome lookup. After a possible send,
timeout/disconnect can mean unknown; do not blindly retry a mutation or promise
durable exactly-once execution. Stop sets its session fence before admission ACK,
without waiting for persistence or ordinary-command queue capacity.

Snapshots are authoritative presentation values. Atomically capture a baseline,
event high-water cursor and subscriber registration under the owner. Separate
snapshot revisions, event sequences and host incarnations. Send baseline first,
bounded ordered replay with catch-up, then live events; report missing ranges or
changed incarnation. Events explain decisions and never become UI mutation
commands or durable recovery authority. Disconnect/staleness is last-known or
unavailable state, not proof of a stopped runtime.

Coalesce unsent complete snapshots. Never silently drop decision events or
operation outcomes. Bound frames, strings, queues, subscribers, operations,
retained outcomes, replay and collection pages/cursors. Overflow terminates with
reserved terminal capacity, or disconnects within the write budget. Cancellation
releases resources without stopping the host. Page large collections at bounded
retained collection revisions; preserve totals and explicit continuation/staleness.

In-memory transport encodes/decodes the same framed v2 contract and bounds as the
later socket. Preserve v1 commands, replies and 16 KiB bound. Helper IPC is
separately versioned. No production v2 socket ships in this first contract slice.
Known malformed payloads fail validation; bounded unknown informational wire
events do not create an untyped domain producer escape hatch.

Observation I/O and diagnostic failures cannot gate control or physical outcomes.
Bound work per turn as well as queue capacity; verify fairness under replay,
counter and health load. Keep control responsiveness independent from observer
backlog; favor separate command and observation connections in the later adapter.
The [runtime design](../design-runtime-host-contract.md) specifies compatibility,
field-inventory and sizing obligations.

## Alternatives

Direct local calls hide framing/backpressure defects. Event-sourced UI rendering
confuses diagnostic history with authority. Unbounded replay buffers or a single
blocked observation/control path threaten daily-driver reliability. Automatic
mutation replay after timeout hides ambiguous outcomes.

## Consequences

The local boundary pays codec overhead in exchange for exercising the future
client contract now. Measure that overhead before considering a fast path. The
contract exposes unknown/gap states; callers must render them honestly.

## Invariants and verification

- Codec fixtures preserve v1 and reject unsupported/malformed v2 values.
- Inventory every presentation/preflight read; a largest valid baseline/page fits
  its frame bound, without silent truncation or credential disclosure.
- Independent bounded models drive the production subscription/admission adapter,
  covering baseline/replay/live ordering, overflow, cancellation and unknowns.
- Slow consumers and failed log sinks cannot block status/Stop or leak resources.
- Record exact source/build and command evidence; earlier passing trees do not
  validate later changes. Unit/model evidence does not replace machine checks.

## Implementation evidence

Partial: the stage-1 foundation is implemented on this branch.

- Protocol and values: [`RuntimeClient.swift`](../../Sources/ConduitShared/RuntimeClient.swift) (the async protocol, `RuntimeDeadline`, `RuntimeSubscription` and `RuntimeClientError`) and the `ControlRuntime*.swift` files beside it: commands with a request ID and expected incarnation, admission and lookup values, pages, snapshot stamps and the v2 envelope. The v2 envelope is version 2; v1 stays at 1.
- Codec and bounds: [`ControlRuntimeCodec.swift`](../../Sources/ConduitShared/ControlRuntimeCodec.swift) (one JSON value per line; checks run in order: size, version, kind, body type, then strict whole-payload syntax and the typed body) and [`ControlRuntimeSizing.swift`](../../Sources/ConduitShared/ControlRuntimeSizing.swift) (a summed byte budget refused before encoding).
- Observation values: [`ControlRuntimeEventRecord.swift`](../../Sources/ConduitShared/ControlRuntimeEventRecord.swift) (a known record, or a bounded unknown display record) and [`RuntimeSnapshotControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeSnapshotControlProjection.swift).
- Tests: `Tests/ConduitTests/RuntimeClientCodecTests.swift`, `RuntimeClientContractTests.swift`, `RuntimeConfigSizingTests.swift`, `RuntimeSnapshotProjectionTests.swift`, `ControlRuntimeEventProjectionTests.swift` and `RuntimeEventTypedTests.swift`. The focused counts are in the [stage-1 inventory](../runtime-client-stage1-inventory.md).
- Framed client (2026-10-24, slice 1): [`FramedRuntimeClient.swift`](../../Sources/ConduitShared/FramedRuntimeClient.swift) runs the v2 codec over the package byte transport in [`RuntimeTransport.swift`](../../Sources/ConduitShared/RuntimeTransport.swift). The package seam is `makeFramedRuntimeClient`, which returns `any RuntimeClient`. The concrete adapter stays file-private, so tests and `pm-sim` depend only on the protocol. It maps each outcome to the error vocabulary above: a local refusal before any send, not-sent, admission unknown after a possible send, read aborted, host wire answers, unexpected replies, and typed stream ends. The transport owns every wait and timer, and the client adds none. A stream handle is single-pull and releases its stream once. Tests: [`FramedRuntimeClientTests.swift`](../../Tests/ConduitTests/FramedRuntimeClientTests.swift), over a bounded scripted transport, and the headless `pm-sim framed-runtime-client` scenario, over a simulated host. Verification is in [the framed client note](../runtime-framed-client-2026-10-24.md).

- Service foundation (2026-10-25, unadopted): [`RuntimeServiceCore.swift`](../../Sources/ConduitRuntime/RuntimeServiceCore.swift) and [`ControlCommandOwner.swift`](../../Sources/ConduitRuntime/ControlCommandOwner.swift) separate request admission, owner fencing, logical settlement and physical quiescence. [`RuntimeAliasTable.swift`](../../Sources/ConduitRuntime/RuntimeAliasTable.swift) bounds best-effort request recovery without pinning aliases. [`RuntimeInMemoryTransport.swift`](../../Sources/ConduitRuntime/RuntimeInMemoryTransport.swift) and [`RuntimeTransportGate.swift`](../../Sources/ConduitRuntime/RuntimeTransportGate.swift) exercise the framed client with separate finite lanes, one caller timer and reservations retained through actual hop/timer/waiter cleanup. The ordinary request envelope carries its wire budget consistently. [`RuntimeServiceModelTests.swift`](../../Tests/ConduitTests/RuntimeServiceModelTests.swift) compares the production wait/work mechanisms with bounded reference models; [`RuntimeServiceLifetimeTests.swift`](../../Tests/ConduitTests/RuntimeServiceLifetimeTests.swift) covers release/cleanup races. The [checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md) records 216 focused tests, explored bounds and limitations. This is partial local evidence, before full workflow gates or a service PR.

Not implemented: complete observation/replay models, retained collection pages, snapshot coalescing, a production v2 socket transport, the configuration workflow and AppState adoption. The actual RuntimeHost has not adopted the command-owner protocol or its fault-to-event emitter; fake owners establish service behavior only. No shipping ordinary v2 frame/queue/deadline defaults are selected; v1 keeps its 16 KiB frame. Private configuration limits are recorded separately in 0021–0022.

Does not prove: a production control socket, cross-process authority, host fences, admission order, retention, validated shipping resource limits, or the full client-engine behavior.

## Open questions

Exact command/field inventory, measured frame/page/queue limits and deadline values
are stage-1 obligations. Config projection and component grouping follow 0015;
listener handoff policy remains a gate before changing that behavior.
