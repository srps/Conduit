# 0045: DoH reaches the upstream only through Conduit, and DoH and PAC sessions never hand a proxy challenge to macOS

- Date: 2026-11-11
- Decision: proposed
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

The owner approved this decision on 2026-11-11, before the pull request existed, and approved the upstream route and the narrowed scope in review of that pull request the same day. It stays proposed until the owner confirms it on the pull request.

## Context

On the first full-tunnel VPN connect, Conduit 0.6.2 made macOS show an "authenticate to the proxy server" dialog for the Conduit process. The macOS log showed the cause. CFNetwork tasks with the DoH timeouts (4 s request, 8 s resource, `DoHSessionFactory.requestTimeout`) logged "Fetching proxy credential". Then `AuthBrokerAgent` logged "Prompting user" for Conduit's process ID.

The DNS forwarder and the transparent proxy's origin resolver race each DoH lookup over several routes. One of these routes sent the lookup straight to the first enabled upstream proxy, through a `URLSession` with no delegate. When the upstream answers 407, a session with no delegate lets CFNetwork authenticate by itself. CFNetwork asks `AuthBrokerAgent` for a saved proxy credential. On the first connect there is no Kerberos service ticket yet, so the saved credential fails, and macOS prompts the user.

Removing that route left two: direct, and Conduit's client listener. The client listener applies the client routing rules. When PAC answers DIRECT for a DoH provider, a bypass entry matches it, or Conduit is in direct mode, the listener's tunnel goes direct too. Under a full-tunnel VPN that drops direct 443 to a public resolver, every DoH route is then a black hole for as long as the rule holds. `pm-dns` runs no client listener, so it had the direct route only.

## Decision

- DoH lookups have three routes, raced together: direct, Conduit's client listener, and the upstream route. No route names an upstream proxy to `URLSession`.
- The upstream route is a loopback SOCKS listener on an ephemeral port (`DoHUpstreamRoute`). The DNS forwarder binds it when it starts and closes it when it stops. It applies no PAC, bypass or direct-mode rule: it tunnels through an upstream proxy or fails. It dials through `CONNECTCoordinator` and the tunnel pool, so the upstream's 407 is answered by Conduit's own Kerberos/NTLM authenticator and a failing upstream fails over, as for every other tunnel.
- The route admits a connection only to a configured DoH provider's own host and port. Anything else is refused with `dns.doh_upstream_route_refused` and nothing is dialled.
- The route is absent when no upstream is enabled. The app also withholds it while client traffic is routed direct because the VPN is off (`DirectModeCause.vpnDisconnected`) or no upstream is configured: Conduit dials no upstream in those states, and direct DoH works there. It stays offered in every other state, including the transient direct mode after a VPN connect.
- `pm-dns` builds a pool and coordinator of its own, as `pm-tunnel` does, and offers the route whenever its config enables an upstream.
- A DoH session, an origin-resolver session and the PAC download session cancel a proxy-authentication challenge with `.cancelAuthenticationChallenge`, whatever its scheme. Every other challenge, such as server trust or a server's own 401, keeps CFNetwork's default handling.
- Each refusal is reported. A DoH or origin-resolver session emits `auth.proxy_challenge_refused` (`client=`, `proxy=`, `method=`, `suppressed=`), at most once a minute per client, proxy and scheme, with a warning log line derived from it, and the forwarder's "all DoH providers failed" warning names the refusal. A PAC fetch fails with an error that names the refusal, and that error reaches `pac.refresh_failed` or `pac.preview_failed`.
- The update download is outside this decision and keeps CFNetwork's default challenge handling. See Alternatives.

## Alternatives

- Keep the direct-to-upstream route and add only the challenge guard. The guard stops the prompt, but every DoH lookup on that route would still meet a 407 and fail.
- Two routes only, direct and the client listener. This was the first form of this decision. It leaves DoH dependent on client routing rules, as Context describes.
- Make the client listener force DoH providers through the upstream. That changes routing for every client that talks to those hosts, a browser's own DoH included, against the rules the user configured.
- An HTTP CONNECT listener for the upstream route. It needs a new listener and handler, where SOCKS reuses the existing `SOCKS5Server` with one routing mode added. An HTTP proxy hop also has a response in which a 407 could one day reach CFNetwork; a SOCKS hop with no authentication has none. And CONNECT carries only `https` providers, so no test without a TLS server could show an answered lookup through it. Measured on macOS 26: `URLSession` greets a SOCKS proxy offering only "no authentication", sends a provider's hostname unresolved, and sends nothing before the SOCKS reply.
- A fixed local port relayed to one provider, as `TunnelForwarder` does. `URLSession` would connect to a loopback address, so the provider's TLS name would not match.
- `.rejectProtectionSpace`. CFNetwork then offers the proxy's next scheme, and after the last one CFNetwork decides what happens. Cancelling ends the task at once.
- Answer the challenge with Conduit's own credentials. That would be a second authentication path beside the pool's, with its own Kerberos and NTLM state.
- Guard the update download as well. An earlier form of this decision did. It refused an update behind an authenticating system proxy that is not Conduit's listener, where macOS's saved credential would have worked. Sparkle's own sessions run in the same updater process and are Sparkle's code, so the guard did not stop a prompt there. And an update is something the user asked for, so a credential prompt during one is expected, where a prompt from a background DNS lookup is not.

## Consequences

- No macOS proxy-credential prompt comes from a DoH lookup or a PAC download.
- A routing rule that sends a DoH provider DIRECT no longer makes public names unresolvable under a VPN that drops direct 443. This also covers the transient direct mode after a VPN connect, which the first form of this decision accepted as a few seconds of failed lookups.
- The DoH race starts three routes per provider and encoding while an upstream is in play. Each lookup can open tunnels in the tunnel pool, within that pool's connection limit.
- New caps: the route's listener holds at most 64 connections (`DoHUpstreamRoute.maximumConnections`), and its three per-target events are limited to one a minute by a 64-entry `RuntimeEventRepeatGate`. It reuses the SOCKS listener's 10 s handshake deadline.
- A local process can open a tunnel to a configured DoH provider through the upstream without the client routing rules being consulted. It cannot reach anything else through this listener.
- A plain `http://` provider is carried too, as a tunnel to its port 80. Most upstreams refuse that, and the route then reports `dns.doh_upstream_route_failed`.
- The guard does not see every proxy challenge. For a proxy that offers only Negotiate, CFNetwork raises no challenge: it tries the user's Kerberos ticket by itself and fails the request, with no prompt (measured on macOS 26). Offered Negotiate, NTLM and Basic together, it hands the delegate NTLM. No DoH route names a proxy that asks, so this limits only the backstop.
- An update download through an authenticating system proxy behaves as it did before this decision.

## Invariants and verification

- No DoH route names an upstream proxy to `URLSession`, and the upstream route exists only with an enabled upstream: `DoHSessionFactoryTests`.
- With the client rules sending the provider DIRECT and direct a black hole, a lookup is answered through an upstream that demands authentication, after Conduit answers its 407; without the route the same lookup fails: `DoHUpstreamRouteTests` and pm-sim `dns-doh-upstream-407`. Both run the real listener, `CONNECTCoordinator`, `ConnectionPool` and authenticator seam against a fake upstream. The provider is plain HTTP, because no TLS server is available to the tests.
- An `https` provider reaches the upstream as an authenticated `CONNECT` to its port 443, and the session's TLS handshake arrives through the tunnel: `DoHUpstreamRouteTests.testAnHTTPSProviderReachesTheUpstreamAsAnAuthenticatedTunnelCarryingTLS`.
- The route refuses a target that is not a provider endpoint, reports a failing upstream, is withheld while the host says so, and closes with the forwarder: `DoHUpstreamRouteTests`.
- Every session `DoHSessionFactory` builds, every session a running forwarder holds, and the PAC download delegate cancel a proxy challenge of each scheme. These tests send no request. Each test that lets a loopback proxy answer 407 first checks the session it is about to use the same way, and sends nothing if the guard is missing, so a regressed guard cannot open the dialog on the machine running the tests: `ProxyChallengeRefusalTests` and `ProxyChallengeCanary`. pm-sim puts no 407 in front of a `URLSession`.
- NTLM, Basic and Digest, each offered alone, are cancelled and reported under their own `method=`. A server challenge keeps default handling. A PAC refresh through a challenging proxy reports the refusal in `pac.refresh_failed`: `ProxyChallengeRefusalTests`.
- Disproved by: a DoH request that reaches an upstream proxy without passing through one of Conduit's listeners, a macOS proxy-credential prompt for Conduit caused by a DoH lookup or PAC download, or a lookup that fails under a full-tunnel VPN with a healthy upstream because a client rule said DIRECT.

## Implementation evidence

The routes are in [`DoHSessionFactory.swift`](../../Sources/ProxyKernel/Network/DoHSessionFactory.swift) and `DoHTransports` in [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift). The upstream route is [`DoHUpstreamRoute.swift`](../../Sources/ProxyKernel/Network/DoHUpstreamRoute.swift), on the upstream-only mode of [`SOCKS5Server.swift`](../../Sources/ProxyKernel/Proxy/SOCKS5Server.swift). The app wires it to the tunnel pool in [`ProxyOrchestrator.swift`](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift), and `pm-dns` in [`PMDns.swift`](../../Sources/pm-dns/PMDns.swift). The DoH and origin-resolver sessions use `ProxyChallengeRefusingDelegate` in [`ProxyChallengeRefusal.swift`](../../Sources/ProxyKernel/Network/ProxyChallengeRefusal.swift). The PAC download has its own delegate, `PACBoundedDownload` in [`CFPACEvaluator.swift`](../../Sources/ProxyPAC/CFPACEvaluator.swift), which makes the same refusal and fails the fetch. Tests are in [`DoHSessionFactoryTests.swift`](../../Tests/ConduitTests/DoHSessionFactoryTests.swift), [`DoHUpstreamRouteTests.swift`](../../Tests/ConduitTests/DoHUpstreamRouteTests.swift) and [`ProxyChallengeRefusalTests.swift`](../../Tests/ConduitTests/ProxyChallengeRefusalTests.swift). The scenario is in [`DoHProxyAuthScenarios.swift`](../../Sources/pm-sim/DoHProxyAuthScenarios.swift).

Does not prove: that the first full-tunnel VPN connect on a real corporate network shows no prompt with an installed build, and that public names resolve there while a rule sends the providers DIRECT. That check is the pending validation. The tests also do not show an answered lookup over TLS through the route: they show the TLS handshake entering an authenticated tunnel, and an answered lookup over plain HTTP. And they say nothing about CFNetwork's SOCKS behaviour on a macOS version other than 26. If a version resolved a provider's hostname locally before dialling the SOCKS proxy, a hostname provider would depend on the system resolver there, as it already does on the direct route. The shipped providers are IP literals.

## Open questions

None.
