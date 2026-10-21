# 0011: Path-based socket sweeps for VPN transitions

- Date: 2026-10-15
- Decision: accepted (owner, 2026-10-15, #156, #162)
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

After a confirmed VPN disconnect or reconnect, sockets that could no longer carry traffic stalled for a minute or more before clients gave up (#148, #153). The owner's requirement is that such sockets close at once.

#156 proposed a runtime-wide transition authority with routing tokens and leases, and #158 shipped it as `RoutingStamp`. A stamp fences against the orchestrator's view of the VPN, which changes only after the network did, so it cannot say whether a socket works. Every review round found another interleaving (#159, #160, #161). Separately, a probe that straddled a newer transition could still change routing (#155).

## Decision

Recorded on #156 on 2026-10-15 and implemented in #162:

- Judge each socket by its path. It is stranded when its local address is gone, or when the kernel would now reach its peer through another interface. A failed lookup is unknown, and the socket is left alone.
- Check at registration, on every confirmed transition including the first `unknown → connected`, and again at +2 s and +10 s while routes settle. Sweeps run off the main actor and are held during a flap.
- Keep the disconnect routing phase: a disconnect whose probe routes DIRECT still closes every upstream socket.
- Keep the control-plane routing generation from #155, so stale probe results cannot change routing.
- Remove `RoutingStamp` and the stamp threading through every request path.

## Alternatives

The routing-token and lease authority from #156, shipped in #158 and replaced by #162 for the reason above.

## Consequences

- A split-tunnel reconnect no longer closes DIRECT sockets that still route via Wi-Fi, and an on-prem upstream tunnel survives a disconnect whose probe still finds the upstream.
- Accepted residual: a tunnel recreated with the same address, or a NAT change behind an unchanged interface, looks current. Those sockets fall back to TCP keepalive and response timeouts.

## Invariants and verification

- Every routed socket (pools, dedicated tunnels, DIRECT HTTP, SOCKS5 and transparent) registers with the bounded `OutboundSocketRegistry`.
- A socket that connected over a removed path is closed on arrival (`connection.late_dial_retired`).
- Sweeps emit `vpn.tunnels_migrated phase=paths pass=N`.

## Implementation evidence

- [`SocketPathChecking`](../../Sources/ProxyKernel/Abstractions/SocketPathChecking.swift), [`SystemSocketPaths`](../../Sources/ProxyKernel/Network/SystemSocketPaths.swift) and [`OutboundSocketRegistry`](../../Sources/ProxyKernel/Proxy/OutboundSocketRegistry.swift), with [`OutboundSocketRegistryTests`](../../Tests/ConduitTests/OutboundSocketRegistryTests.swift) and [`ConnectionPoolMigrationTests`](../../Tests/ConduitTests/ConnectionPoolMigrationTests.swift).
- The `vpn-transition-*` scenarios in [`VPNTransitionMigrationScenarios`](../../Sources/pm-sim/VPNTransitionMigrationScenarios.swift).
- Owner validation on a full-tunnel VPN with a pre-release build is recorded in `ROADMAP.md` (commit d6b58ce, 0.5.6).

Does not prove: split-tunnel behaviour, or the released 0.5.6 build, on a real VPN. `SystemSocketPaths` is unit-tested only against loopback sockets and an unassigned address.

## Open questions

None recorded.
