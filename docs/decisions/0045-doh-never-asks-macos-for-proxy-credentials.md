# 0045: DoH skips the upstream, and Conduit sessions never hand a proxy challenge to macOS

- Date: 2026-11-11
- Decision: proposed
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

The owner approved this decision on 2026-11-11, before the pull request existed. It stays proposed until the owner confirms it on the pull request.

## Context

On the first full-tunnel VPN connect, Conduit 0.6.2 made macOS show an "authenticate to the proxy server" dialog for the Conduit process. The macOS log showed the cause. CFNetwork tasks with the DoH timeouts (4 s request, 8 s resource, `DoHSessionFactory.requestTimeout`) logged "Fetching proxy credential". Then `AuthBrokerAgent` logged "Prompting user" for Conduit's process ID.

The DNS forwarder and the transparent proxy's origin resolver race each DoH lookup over several routes. One of these routes sent the lookup straight to the first enabled upstream proxy, through a `URLSession` with no delegate. When the upstream answers 407, a session with no delegate lets CFNetwork authenticate by itself. CFNetwork asks `AuthBrokerAgent` for a saved proxy credential. On the first connect there is no Kerberos service ticket yet, so the saved credential fails, and macOS prompts the user.

The other proxied route goes through Conduit's own listener. That route authenticates with Conduit's Kerberos/NTLM path, and a failure there is a 502 to the session, never a prompt.

## Decision

- DoH lookups have two routes: direct, and Conduit's own listener. Neither the forwarder (`DoHTransports`) nor the origin resolver (`DoHSessionFactory.routes`) sends a lookup straight to an upstream proxy.
- No Conduit-owned `URLSession` lets CFNetwork answer a proxy-authentication challenge. A challenge whose protection space is a proxy is cancelled with `.cancelAuthenticationChallenge`, whatever its scheme. Every other challenge, such as server trust, keeps CFNetwork's default handling.
- Each refusal is reported. A DoH session or an origin-resolver session emits `auth.proxy_challenge_refused` (`client=`, `proxy=`, `method=`, `suppressed=`), at most once a minute per client, proxy and scheme, and a warning log line derived from it. A PAC fetch fails with an error that names the refusal, and that error reaches `pac.refresh_failed` or `pac.preview_failed`. An update download fails the preflight as `update.preflight_failed reason=update_proxy_auth_refused`, because the preflight worker has no event stream.
- Conduit authenticates to an upstream only through its own Kerberos/NTLM path.

## Alternatives

- Keep the upstream route and add only the challenge guard. The guard stops the prompt, but every DoH lookup on that route would still meet a 407 and fail. The listener route already reaches the same upstream with authentication, so the upstream route adds a failure and no reach.
- `.rejectProtectionSpace`. CFNetwork then offers the proxy's next scheme, and after the last one CFNetwork decides what happens. Cancelling ends the task at once, so CFNetwork never gets to its default handling.
- Answer the challenge with Conduit's own credentials. That would be a second authentication path beside the listener's, with its own Kerberos and NTLM state. The listener already does this.
- Remove the route and add no guard. A later route or session that meets a proxy would bring the prompt back with nothing to report it.

## Consequences

- No macOS proxy-credential prompt comes from a Conduit `URLSession`.
- While Conduit is in its transient direct mode after a VPN connect, the listener goes direct too. Under a full-tunnel VPN that blocks direct 443, public-name DoH can fail for a few seconds, until direct mode ends. The owner accepted this trade-off.
- The DoH race starts one route fewer per provider and encoding.
- An update download through a system proxy that asks for authentication, which is not Conduit's listener, now fails the preflight with `update_proxy_auth_refused`. Before this change, macOS answered the challenge with a saved credential or a prompt. Sparkle's own sessions in the nested updater are Sparkle's code, and this decision does not change them.

## Invariants and verification

- The DoH routes are direct and the listener, never an upstream: `DoHSessionFactoryTests.testRoutesAreDirectAndTheListenerNeverTheUpstream`.
- A proxy challenge on a Conduit DoH session is cancelled, reported once with its scheme, and never answered with a credential. A fake proxy that answers every request with 407 sees one CONNECT per fetch and no `Proxy-Authorization`. A PAC fetch through that proxy fails with the refusal: `ProxyChallengeRefusalTests`. The DoH providers are HTTPS, and CFNetwork turns the 407 to their CONNECT into a challenge. A plain-HTTP request's 407 comes back as a response with no challenge, so the tests use HTTPS.
- pm-sim `dns-doh-upstream-407`. The only enabled upstream answers 407 to everything. A DoH lookup is answered through the listener path, the upstream sees no request, no request carries `Proxy-Authorization`, and a listener that answers 407 is refused with `auth.proxy_challenge_refused`.
- Disproved by: a DoH request that reaches an upstream proxy directly, or a Conduit session that sends a `Proxy-Authorization` header it did not build itself.

## Implementation evidence

The route removal is in [`DoHSessionFactory.swift`](../../Sources/ProxyKernel/Network/DoHSessionFactory.swift) and in `DoHTransports` in [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift). The guard is [`ProxyChallengeRefusal.swift`](../../Sources/ProxyKernel/Network/ProxyChallengeRefusal.swift). The DoH sessions and the origin resolver's sessions use it, and so do the PAC download delegate in [`CFPACEvaluator.swift`](../../Sources/ProxyPAC/CFPACEvaluator.swift) and the update download delegate in [`UpdateArchiveDownload.swift`](../../Sources/PlatformMac/UpdateArchiveDownload.swift). Tests are in [`DoHSessionFactoryTests.swift`](../../Tests/ConduitTests/DoHSessionFactoryTests.swift) and [`ProxyChallengeRefusalTests.swift`](../../Tests/ConduitTests/ProxyChallengeRefusalTests.swift). The scenario is in [`DoHProxyAuthScenarios.swift`](../../Sources/pm-sim/DoHProxyAuthScenarios.swift).

Does not prove: that the first full-tunnel VPN connect on a real corporate network shows no prompt with an installed build. That check is the pending validation.

## Open questions

None.
