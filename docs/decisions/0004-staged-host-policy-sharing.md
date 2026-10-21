# 0004: Share app and daemon platform policy piece by piece

- Date: 2026-09-23
- Decision: superseded (owner, 2026-09-23, #79; superseded 2026-10-21, #186)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: 0001

## Context

`AppState` and `DaemonRuntimeHost` duplicate platform operations: reconciler manager calls, DNS health and relay work, host event wiring, and direct `NetworkMonitor()` construction (#79). It was one of the module-boundary issues filed on 2026-09-23.

## Decision

Extract the duplicated serialized platform operations in small stages, coordinated with #47. Reuse the existing managers, locks, lifecycle lanes and operation queues, and do not add a second competing coordinator. Keep AppKit termination and daemon orchestration at their host boundaries. Add an injectable network-path monitor with a fake.

Superseded on 2026-10-21 by [0001](0001-one-runtime-host.md): the sharing now happens by converging both hosts on one `RuntimeHost`. #79's acceptance list stays as the checklist for #186 stages 2 and 3.

## Alternatives

The ones #186 later weighed: one host now (chosen there), or finishing daemon-first first.

## Consequences

The shared pieces below stay. New sharing work follows [0001](0001-one-runtime-host.md).

## Invariants and verification

Each extracted policy has one implementation that both hosts consume, and both fake-machine host suites cover the same outcomes (#79).

## Implementation evidence

- Both hosts use [`RuntimeReconciler`](../../Sources/PlatformMac/RuntimeReconciler.swift), [`PlatformWork`](../../Sources/PlatformMac/PlatformWork.swift) and [`LifecycleLane`](../../Sources/PlatformMac/LifecycleLane.swift).
- #90 centralized intercept-file refresh in [`DNSManager`](../../Sources/PlatformMac/DNSManager.swift); #83 added the daemon credential-store seam.

Does not prove: that the hosts behave the same. Both still construct their own managers and observers, and the remaining duplication is listed in #79.

## Open questions

None; see [0001](0001-one-runtime-host.md).
