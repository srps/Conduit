# 0045: DoH skips the upstream, and Conduit's DoH and PAC sessions never hand a proxy challenge to macOS

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

The other proxied route goes through Conduit's own listener. The listener applies the client routing rules. When they send a provider to an upstream, the listener authenticates with Conduit's Kerberos/NTLM path, and a failure there is a 502 to the session, never a prompt.

## Decision

- DoH lookups have two routes: direct, and Conduit's own listener. Neither the forwarder (`DoHTransports`) nor the origin resolver (`DoHSessionFactory.routes`) sends a lookup straight to an upstream proxy.
- The DoH sessions, the origin resolver's sessions and the PAC download never let CFNetwork answer a proxy-authentication challenge that CFNetwork hands to their delegate. A challenge whose protection space is a proxy is cancelled with `.cancelAuthenticationChallenge`, whatever its scheme. Every other challenge, such as server trust or a server's own 401, keeps CFNetwork's default handling.
- The guard covers only the challenges CFNetwork hands to the delegate. A proxy that offers only Negotiate raises no challenge on macOS 26: CFNetwork tries the user's Kerberos ticket by itself, with no password to ask for and no dialog, and fails the task when it has no ticket for the proxy. The delegate never sees that exchange, so the guard cannot refuse it. No production route meets an authenticating proxy now. DoH goes direct or to Conduit's own listener, which never answers 407, and the PAC download goes direct.
- Each refusal is reported. A DoH session or an origin-resolver session emits `auth.proxy_challenge_refused` (`client=`, `proxy=`, `method=`, `suppressed=`), at most once a minute per client, proxy and scheme, and a warning log line derived from it. When every DoH provider fails and a refusal is part of why, the all-providers-failed warning says so. A PAC fetch fails with an error that names the refusal, and that error reaches `pac.refresh_failed` or `pac.preview_failed`.
- The update download keeps CFNetwork's default handling. The user asked for the update, and Sparkle's own sessions in the same updater process are not Conduit's code, so a guard on the download alone would not stop a prompt from that process.

## Alternatives

- Keep the upstream route and add only the challenge guard. The guard stops the prompt, but every lookup on that route then meets a 407 and is refused, so the route can no longer succeed.
- `.rejectProtectionSpace`. CFNetwork then offers the proxy's next scheme, and after the last one CFNetwork decides what happens. Cancelling ends the task at once, so CFNetwork never gets to its default handling.
- Answer the challenge with Conduit's own credentials inside the session. That would be a second authentication path beside the listener's, with its own Kerberos and NTLM state.
- Remove the route and add no guard. A later route or session that meets a proxy would bring the prompt back with nothing to report it.

## Consequences

- No macOS proxy-credential prompt comes from a Conduit DoH, origin-resolver or PAC session.
- DoH can fail where it worked before. When the client listener's rules send the DoH providers DIRECT (a PAC DIRECT answer, a bypass entry, or direct mode, including the transient direct mode after a VPN connect), the listener route goes direct too. Under a full-tunnel VPN that drops direct 443, both routes then fail, and public names do not resolve over DoH until the rules send the providers to an upstream again. Before this change, the deleted upstream route usually covered that case without a sound, because CFNetwork answered the 407 with a saved credential or a Kerberos ticket, and prompted only when those failed. A later change adds a DoH route through the upstream that authenticates with Conduit's own path.
- DNS has its own lifecycle, apart from the proxy listener's. When the forwarder runs while the proxy is stopped, failed to bind, or is restarting, the listener route fails too, so under a full-tunnel VPN that drops direct 443 both DoH routes fail. In dev with ephemeral ports, a forwarder started before the listener binds has no listener route until its transports are next reset.
- The DoH race starts one route fewer per provider and encoding.

## Invariants and verification

- The DoH routes are direct and the listener, never an upstream: `DoHSessionFactoryTests.testRoutesAreDirectAndTheListenerNeverTheUpstream`.
- A proxy challenge on a Conduit DoH session is cancelled, reported once with its scheme, and never answered with a credential. A fake proxy that answers every request with 407 sees one CONNECT per fetch and no `Proxy-Authorization`. A PAC fetch or refresh through that proxy fails with the refusal, and the all-providers-failed warning names it: `ProxyChallengeRefusalTests`. The DoH providers are HTTPS, and CFNetwork turns the 407 to their CONNECT into a challenge. A plain-HTTP request's 407 comes back as a response with no challenge, so the tests use HTTPS.
- Before any test or the pm-sim scenario lets a loopback proxy answer 407 to a real request, `ProxyChallengeCanary` (in ProxyKernel, so both can use it) hands a made-up proxy challenge of each scheme to the delegate of each session that request will use, and requires a cancel. It calls the handler URLSession would call: the session-level handler for NTLM, Negotiate, client-certificate and server-trust challenges when the delegate has one, and the task-level handler otherwise. A DoH test or the scenario checks the sessions the forwarder or `DoHSessionFactory` actually holds. A PAC test checks the session the download builds for itself, through `CFPACEvaluator`'s `downloadWillResume`, before that session's request is sent. When the answer is not a cancel, the check throws and no request is sent, so a guard broken in a way the canary can see fails the check instead of raising the macOS dialog. The canary cannot see a challenge CFNetwork answers without asking the delegate, such as the Negotiate-only case above, nor a session a test does not hand it.
- pm-sim `dns-doh-upstream-407`. First the canary checks every DoH session the forwarder holds. Until that passes, the upstream fake closes each connection without an answer and the listener fake answers 200, and a failure stops the scenario with no request sent. Then the only enabled upstream answers 407 to everything. A DoH lookup is answered through the listener path, the upstream sees no request, and no request carries `Proxy-Authorization`. The canary checks the sessions again before the listener starts answering 407, and that 407 is refused with `auth.proxy_challenge_refused`.
- Disproved by: a DoH request that reaches an upstream proxy directly, or a Conduit DoH, origin-resolver or PAC session whose delegate is handed a proxy challenge and does not cancel it. A Negotiate-only proxy answered with the user's Kerberos ticket does not disprove it, because CFNetwork never hands that challenge to the delegate.

## Implementation evidence

The route removal is in [`DoHSessionFactory.swift`](../../Sources/ProxyKernel/Network/DoHSessionFactory.swift) and in `DoHTransports` in [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift). The guard is [`ProxyChallengeRefusal.swift`](../../Sources/ProxyKernel/Network/ProxyChallengeRefusal.swift). The DoH sessions and the origin resolver's sessions use it, and the PAC download delegate in [`CFPACEvaluator.swift`](../../Sources/ProxyPAC/CFPACEvaluator.swift) applies the same rule. Tests are in [`DoHSessionFactoryTests.swift`](../../Tests/ConduitTests/DoHSessionFactoryTests.swift) and [`ProxyChallengeRefusalTests.swift`](../../Tests/ConduitTests/ProxyChallengeRefusalTests.swift). The canary they and pm-sim share is [`ProxyChallengeCanary.swift`](../../Sources/ProxyKernel/Network/ProxyChallengeCanary.swift). The scenario is in [`DoHProxyAuthScenarios.swift`](../../Sources/pm-sim/DoHProxyAuthScenarios.swift).

Does not prove: that the first full-tunnel VPN connect on a real corporate network shows no prompt with an installed build. That check is the pending validation.

## Open questions

None.
