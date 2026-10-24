# 0013: Shared runtime modules and control isolation

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 implementation checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

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

None yet. The target/control-owner migration has not started.

Does not prove: production daemon ownership, real-session auth/PAC behavior or
machine-side concurrency safety.

## Open questions

Concrete resource bounds need sizing. Later subsystem actors and broader kernel
splits require measured contention or dependency evidence, not this decision.
