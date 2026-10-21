# 0007: Split large kernel files before any target split

- Date: 2026-09-23
- Decision: accepted (owner, 2026-09-23, #85)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

A few kernel files hold most of the logic: on 2026-10-09 `ProxyOrchestrator.swift` was 2,738 lines, `ConnectionPool.swift` 1,805, `HTTPProxyHandler.swift` 1,663 and `LocalDNSForwarder.swift` 1,340 (#85). Their state and invariants are hard to find.

## Decision

Decompose the large kernel files around state-owning seams first, starting with the orchestrator's snapshot, lifecycle, VPN, PAC, health, DNS and transparent-proxy concerns. Land small, behaviour-preserving changes after the overlapping correctness work settles (#31, #47, #79, #81). Afterwards, record a dependency map and a reasoned decision on whether to split the kernel into Core, HTTP, DNS and Tunnel targets. A target split is optional and follows demonstrated clean boundaries or another consumer.

## Alternatives

- Split targets now: the boundaries are not yet clean, and it would widen access across targets.
- Split files mechanically into extensions: that widens dozens of private members without putting state and invariants together.

## Consequences

- No compile-time claim is made; smaller files have to be measured before anyone says they build faster.
- [0001](0001-one-runtime-host.md) waits on the dependency map to choose where `RuntimeHost` lives.

## Invariants and verification

- Behaviour, event ordering, resource bounds and connection lifetimes stay unchanged; each change passes the full `swift.yml` checks, including `pm-sim all`.
- Any access widening is justified and minimal, with no unreviewed public API.

## Implementation evidence

None yet.

## Open questions

The target-split decision itself, after the dependency map.
