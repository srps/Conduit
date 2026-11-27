# 0052: No DoH route through the upstream; the tunnel's resolvers cover a full tunnel that drops direct DoH

- Date: 2026-11-27
- Decision: proposed
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

The owner chose this on 2026-11-27, after a review of the unmerged #306 branches. The record stays `proposed` until the pull request that carries it records the owner's acceptance. It then reads `accepted (owner, YYYY-MM-DD, #N)`.

## Context

Decision 0045 removed the DoH route that sent lookups straight to an upstream proxy. CFNetwork answered that proxy's 407 by itself, and on a first VPN connect macOS prompted the user for a proxy password. 0045 accepted a gap until "a DoH route through the upstream that authenticates with Conduit's own path" landed. Here is the gap. A full-tunnel VPN drops direct 443. The client rules send the DoH providers DIRECT, through a PAC DIRECT answer, a bypass entry or direct mode. The listener route then goes direct too, so both DoH routes fail.

Part C of #306 built that upstream route, but it never merged. It is about 3,000 lines:
- a loopback SOCKS route that only the DoH sessions may use, with an admission check on the provider hostname so that no other local client can reach the upstream through it;
- its own connection pool;
- a stop fence;
- rate-limited events.

The code is on the local branch `claude/doh-306-round7-wip` and the remote `claude/doh-no-proxy-auth-prompt`.

Decision 0049 changes what DNS depends on while a full tunnel is up. Conduit's helper publishes its own DNS key, so the Mac resolves through Conduit. The relay behind that key fails over to the servers the VPN pushed, inside the tunnel. On a full tunnel, DoH is no longer the path that decides whether names resolve.

## Decision

1. Conduit adds no DoH route through an upstream proxy. DoH keeps the two routes of 0045 and #339: direct, and Conduit's own listener. The listener route is skipped while client traffic routes directly.
2. On a full tunnel that drops direct DoH, public names resolve through the tunnel's own servers under 0049. That replaces the upstream route 0045 expected.
3. The #306 part C branch stays as reference and is not ported.

## Alternatives

- Port #306 part C. It closes the gap even without 0049, but it adds a second authenticated path to the upstream and a new local port that needs its own admission fence. That is about 3,000 lines to maintain for a case 0049 already covers.
- Let CFNetwork answer the upstream's 407 again. 0045 rejected this, because it brings back the macOS proxy-password prompt.

## Consequences

- One fewer authenticated route to the upstream, and no new local port.
- On a full tunnel, public names depend on the VPN's resolvers answering through 0049's relay, not on DoH reaching a provider. If the tunnel's servers fail, 0049 withdraws its key and the Mac falls back to the VPN client's own resolver configuration.
- Without 0049, a full tunnel that drops direct 443 while the providers route DIRECT still leaves DoH with no working route. That happens when the override is off or its helper is not installed. The tunnel's own resolver configuration, which macOS uses when Conduit's key is absent, still answers those names.

## Invariants and verification

- DoH never sends a lookup straight to an upstream proxy: `DoHSessionFactoryTests.testRoutesAreDirectAndTheListenerNeverTheUpstream`.
- The listener route is skipped while client traffic routes directly (`DoHRoute.directOnly`, off the VPN with direct mode for `vpnDisconnected` or `noUpstreamsConfigured`), for the forwarder and the transparent proxy's origin resolver alike: `ProxyChallengeRefusalTests.testADirectOnlyRouteNeverAsksTheLocalProxy` with its control `testAProxyAndDirectRouteAsksTheLocalProxy`, `testTheDoHRouteFollowsWhereClientTrafficGoes`, `OriginResolverTests.testADirectOnlyRouteNeverAsksTheLocalProxy`, `VPNReconnectRoutingTests.testTheDoHRouteFollowsTheVPN` and pm-sim `vpn-reconnect-reprobe`. A route change emits `dns.doh_route_changed`.
- While 0049's key is published, public names resolve through the relay's tunnel servers, not DoH. 0049 lists its relay and failover tests.
- Disproved by: on a full tunnel with 0049 active and the DoH providers routed DIRECT, a public name that fails while the tunnel's servers answer it.

## Implementation evidence

No upstream route is built. The two routes and `DoHRoute` are in [`DoHSessionFactory.swift`](../../Sources/ProxyKernel/Network/DoHSessionFactory.swift) (#339), the orchestrator recomputes the route on every VPN or direct-mode change, and the coverage on a full tunnel is 0049's relay.

Does not prove: that public names resolve on a real full-tunnel VPN whose PAC sends the DoH providers DIRECT. That check is the pending validation.

## Open questions

None.
