# 0013: Shared runtime modules and control isolation

- Date: 2026-10-24
- Decision: superseded (owner, 2026-10-24, #186 implementation checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: 0031

## Context

[0031](0031-incremental-runtime-development-single-activation.md) replaces this
record, preserving its shared-runtime/module/isolation direction while selecting
incremental host development followed by one final AppState activation. The
historical decision and evidence below are retained.

[0001](0001-one-runtime-host.md) selected one host in stages, leaving target
placement open. AppState and the daemon still own duplicated lifecycle policy.
PlatformMac already serves the updater; adding host/auth/PAC/control composition
there would broaden that dependency path. Moving only the host off MainActor
would leave its orchestrator, lifecycle, reconciler and retry owners behind.
The owner selected the target/isolation shape, then authorized staged
implementation in [#186](https://github.com/srps/Conduit/issues/186).

## Decision

Add ConduitRuntime for RuntimeHost, composition, dispatch and in-memory transport.
Keep PlatformMac's machine protocols/managers/fakes and PlatformWork. Add a small
Foundation-only RuntimeEvents for typed domain producers and safe diagnostic
values. ConduitShared owns control values/client/codec, independent of the kernel
and RuntimeEvents. ProxyControlBridge maps domain values to separate wire values
exhaustively. New first-party declarations use package access.

Extract with current isolation, adopt AppState DNS, tunnels and proxy in stages,
then move the whole runtime control-owner cluster onto a shared RuntimeActor
declared in a low-level ProxyKernel abstraction. UI/AppKit/presentation remain
MainActor; NIO channel state remains on event loops; blocking effects remain on
PlatformWork. Per-host resources, tokens and lifetimes stay explicit. The global
actor is an isolation domain, not a singleton runtime or dedicated thread.

Use short owner turns, typed effect inputs/completions and authority checks at
dispatch/completion. Status/Stop must stay responsive during slow effects and
observer load. Actor isolation does not make awaits atomic or establish
cross-process ownership. Preserve GSS serialization and decision 0011's path-based
socket policy. The detailed shape is in the [runtime design](../design-runtime-host-contract.md).

## Alternatives

PlatformMac composition would broaden updater dependencies. A kernel/control
combined contract would invert producer dependencies. Moving the host alone
leaves main-actor policy behind. Broad kernel splitting or subsystem actors
before extraction adds migration cost without demonstrated ownership seams.

## Consequences

One runtime implementation prepares the later daemon transport without switching
production ownership now. The staged actor migration still requires serialization,
fencing and bounded termination evidence. Resource-global cleanup (#31/#81) and
production ownership/recovery (#48) remain independent obligations.

## Invariants and verification

- No updater dependency on ConduitRuntime, ProxyAuth or ProxyPAC is introduced.
- No live manager escapes through the runtime client; app/daemon parity stays
  tested until duplicate lifecycle ownership is actually deleted.
- Runtime isolation includes the lane/reconciler/retry/observer cluster; moving
  only RuntimeHost cannot close #47/#79.
- Slow effects and full observation queues do not block status/Stop admission;
  late completions cannot supersede a newer lifecycle token.
- Each slice runs required repository checks, pm-sim and performance gates.

## Implementation evidence

Partial: the stage-1 foundation is implemented on this branch.

- Targets in [`Package.swift`](../../Package.swift): `RuntimeEvents` and `ConduitShared` have no dependencies. `ProxyControlBridge` depends on `ProxyKernel`, `ConduitShared` and `RuntimeEvents`. `ProxyKernel`, `PlatformMac`, the app and `ConduitDaemon` depend on `RuntimeEvents`.
- Typed values: [`LifecycleEvents.swift`](../../Sources/RuntimeEvents/LifecycleEvents.swift) and [`RuntimeEventPayload.swift`](../../Sources/RuntimeEvents/RuntimeEventPayload.swift); the kernel carries them on `RuntimeEvent` ([`RuntimeEvent.swift`](../../Sources/ProxyKernel/Models/RuntimeEvent.swift)).
- Exhaustive projection: [`RuntimeEventControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeEventControlProjection.swift) and [`RuntimeSnapshotControlProjection.swift`](../../Sources/ProxyControlBridge/RuntimeSnapshotControlProjection.swift), mapping onto the wire types in [`ControlRuntimeEventTyped.swift`](../../Sources/ConduitShared/ControlRuntimeEventTyped.swift).
- Producers: [`LifecycleLane.swift`](../../Sources/PlatformMac/LifecycleLane.swift), the termination drain in [`AppState.swift`](../../Sources/Conduit/App/AppState.swift), and [`AppUpdates.swift`](../../Sources/PlatformMac/AppUpdates.swift) (`lifecycle.version_changed`).
- Fences: [`check-kernel-imports.py`](../../scripts/check-kernel-imports.py) (ProxyKernel and RuntimeEvents) and [`check-event-catalogue.py`](../../scripts/check-event-catalogue.py) (closed `lifecycle.` namespace).

The behavior-preserving extraction adds [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift) in `ConduitRuntime`, composed by [`ConduitDaemon.swift`](../../Sources/ConduitDaemon/ConduitDaemon.swift). The entry point injects process start time and terminal exit, preserving exit placement before lifecycle defer. [`NetworkPathObserving.swift`](../../Sources/PlatformMac/NetworkPathObserving.swift) keeps observer setup/lifecycle owner-confined, with callback values crossing via the delivery adapter and a fake in [`PlatformFakes.swift`](../../Sources/PlatformMac/PlatformFakes.swift). The migrated [`DaemonRuntimeHostTests.swift`](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift) retains the FakeMachine suite and tests the new seams.

The [host verification checkpoint](../verification-runtime-host-extraction-2026-10-24.md) records all 39 passing workflow-equivalent gates on an unchanged relevant-source fingerprint (2,509 tests, two skips; 85 simulator results and perf).

Not implemented: AppState adoption, the in-memory client/stream engine and RuntimeActor isolation (stage 4). The updater does not depend on ConduitRuntime; no running host serves v2 yet.

Does not prove: production daemon ownership, real-session auth/PAC behavior or
machine-side concurrency safety.

## Open questions

Concrete resource bounds need sizing. Later subsystem actors and broader kernel
splits require measured contention or dependency evidence, not this decision.
