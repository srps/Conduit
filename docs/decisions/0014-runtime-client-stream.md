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

- Service foundation (2026-10-25, unadopted): [`RuntimeServiceCore.swift`](../../Sources/ConduitRuntime/RuntimeServiceCore.swift) and [`ControlCommandOwner.swift`](../../Sources/ConduitRuntime/ControlCommandOwner.swift) separate request admission, owner fencing, logical settlement and physical quiescence. [`RuntimeAliasTable.swift`](../../Sources/ConduitRuntime/RuntimeAliasTable.swift) bounds best-effort request recovery without pinning aliases. [`RuntimeInMemoryTransport.swift`](../../Sources/ConduitRuntime/RuntimeInMemoryTransport.swift) and [`RuntimeTransportGate.swift`](../../Sources/ConduitRuntime/RuntimeTransportGate.swift) exercise the framed client with separate finite lanes, one caller timer and reservations retained through actual hop/timer/waiter cleanup. The ordinary request envelope carries its wire budget consistently. [`RuntimeServiceModelTests.swift`](../../Tests/ConduitTests/RuntimeServiceModelTests.swift) compares the production wait/work mechanisms with bounded reference models; [`RuntimeServiceLifetimeTests.swift`](../../Tests/ConduitTests/RuntimeServiceLifetimeTests.swift) covers release/cleanup races. The [checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md) records 267 focused tests, explored bounds and limitations. This is partial local evidence, before full workflow gates or a service PR.

- Retained collection pages (2026-10-25, unadopted, partial): [`RuntimeCollectionLedger.swift`](../../Sources/ConduitRuntime/RuntimeCollectionLedger.swift) keeps bounded proofs and row sets per revision, with logical expiry at each read and a bounded janitor. The one bounded projection is [`ControlRowProjection.swift`](../../Sources/ConduitShared/ControlRowProjection.swift) (`ControlRowBudget`) with `RuntimeSnapshotControlProjection.projectRows` in [`RuntimeSnapshotControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeSnapshotControlProjection.swift). The top-level unavailable reply carries an optional exact `knownTotal`. Reads answer closed codes (`changed_incarnation`, `internal_failure`, `frame_too_large`, `invalid_value`) through the framed client as stable wire errors. The snapshot stream frame already exists as `ControlRuntimeFrame.snapshot`, so no new frame is needed for the later subscription work. Tests: `RuntimeCollectionLedgerTests`, `RuntimeServiceTransportTests`, `RuntimeClientCodecTests` and `RuntimeSnapshotProjectionTests`. Models: one kind, 22,620 exhaustive sequences plus 100 walks, and two kinds, 69,904 plus 100. These are written from the same design, not as an independent specification. No source mutant of the cross-kind eviction has been executed on the current source. The review fixes of 2026-10-25 add three things: a held current proof, live, aged or released, is compared with the owner's total before any decision, and a mismatch is `revisionTotalChanged`; a ledger accounting mismatch is the closed `collectionAccountingMismatch` fault; and an answer the caller's frame cannot hold is replaced once by `frame_too_large`, while a failure that cannot fit ends as a disconnect. Their witnesses ran in the 267-test wrapper log, and no mutant has been run against them.

- Observation slice M2B (2026-10-25, unadopted, partial): [`RuntimeSubscriptionTable.swift`](../../Sources/ConduitRuntime/RuntimeSubscriptionTable.swift) owns the subscriber cursors, the one parked wait per subscriber and exactly-once removal. [`RuntimeSnapshotSlot.swift`](../../Sources/ConduitRuntime/RuntimeSnapshotSlot.swift) holds one measured latest snapshot under a private delivery generation, and it refuses broken owner state with closed faults. The core captures the owner once per turn for `ownerDidChange`, subscribe and read, and live snapshots alternate with ordered frames. Tests: `RuntimeServiceObservationTests`, `RuntimeServiceSubscriptionTableTests`, and the bounded live model `RuntimeServiceObservationModelTests` (7,380 exhaustive sequences and 100 seeded walks, both passing). Limits and sizing are in the [checkpoint](../runtime-service-engine-checkpoint-2026-10-25.md). The live model is not an independent specification of replay, and no source mutant of these rules has been run. The replay rules (outcome interleave, eviction during catch-up, explicit refusal of replays that may miss history) are modelled over the observation log in `RuntimeServiceReplayModelTests` and tested through the core in `RuntimeServiceReplayTests`. The checkpoint's M2C section records a replay defect that was fixed and populated sizing through the Bridge. M2D gives stream pulls their own explicit lane, so parked pulls no longer refuse status reads. Its section also records a real upstream-probe outcome witness through the framed client, and a text-length inventory whose owner decision is still open.

- Replay correction M2E (2026-10-25, unadopted): the log retains one last-lost control boundary across ordinary eviction and oversize skips. Replays crossing it explicitly report expired history; later replays remain available. The independent outcome-fate model now explores 37,448 depth-1–5 sequences over eight actions and 200 walks of 40. Log/core/framed witnesses failed on the earlier source and passed after correction. The combined focused wrapper passes 323 tests; the first combined full workflow found an existing PAC test callback race, corrected separately. Final all-workflow/PR evidence is recorded in [the verification note](../verification-runtime-service-pages-2026-10-25.md). No shipping text/frame policy is selected.

Parent verification now includes executed source variants for gate release and cross-kind eviction, with exact detection mechanisms and limits in [the retained-page verification note](../verification-runtime-service-pages-2026-10-25.md). These are limited sensitivity checks, not a complete model proof.

The service-only checkpoints above preceded actual-host adoption. The merged
[actual-client checkpoint](../verification-runtime-client-owner-2026-10-27.md)
connects [`RuntimeHostControlOwner`](../../Sources/ConduitRuntime/RuntimeHostControlOwner.swift)
and [`RuntimePrivateEditor`](../../Sources/ConduitRuntime/RuntimePrivateEditor.swift)
to that same framed service, with the sole configuration workflow, causal
receipts and shared physical custody. A snapshot read returns the current stamped
view; its request has no expected-incarnation input. Production v2 socket transport
and AppState adoption remain open. Ordinary v2 replies/streams use the selected
64 KiB ceiling (0030); remaining queue, retention and deadline values await the
measured composition profile. V1 retains its 16 KiB frame.

Does not prove: cross-process authority, release readiness or real-machine
validation. See the linked verification notes for each model's scope.

The native-client follow-up adds the Foundation-only
[`ProxyRecoveryEvent`](../../Sources/RuntimeEvents/ProxyRecoveryEvents.swift)
family, its separate wire mirror and exhaustive bridge. The kernel emits at its
existing recovery decision sites; RuntimeHost's extra recovery callback is
removed. AppState retains its legacy notification callback until activation.
No summary or endpoint enters the new typed payload. The same
[native-client checkpoint](../verification-runtime-native-client-2026-10-27.md)
adds saved Start receipts, admitted helper observations, credential cache
invalidation and injected, coalesced wake observation. It records the focused,
workflow and actual-adapter evidence separately from AppState activation.

## Open questions

Exact command/field inventory, measured frame/page/queue limits and deadline values
are stage-1 obligations. Config projection and component grouping follow 0015;
listener handoff policy remains a gate before changing that behavior.

### Collection capture implementation clarification — 2026-10-28

The [shared-host contract](../design-runtime-host-contract.md) and [activation checkpoint](../verification-runtime-actor-activation-2026-10-28.md) record one off-owner capture flight. A first page waiting for its own capture resumes through the existing cursor path for that revision, preserving explicit current/stale/expired status. [The service](../../Sources/ConduitRuntime/RuntimeServiceCore.swift) wakes page waits immediately on shutdown, starts no new captures then, and can still serve retained rows. This clarifies implementation of the existing continuation/staleness contract; it introduces no new wire response, bound or deadline.
