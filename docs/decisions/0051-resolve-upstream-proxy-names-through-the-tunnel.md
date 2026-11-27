# 0051: Resolve upstream proxy hostnames through the tunnel's servers, never through DoH

- Date: 2026-11-19
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

The owner approved the approach in [#331](https://github.com/srps/Conduit/issues/331). The record stays `proposed` until the pull request that carries it records the owner's acceptance; it then reads `accepted (owner, YYYY-MM-DD, #N)`.

## Context

Decision 0044 gives a public name, one under no split-DNS rule, one attempt on the table's `firstServers` (`internalAttemptTimeout`, 1.5 s, `askingAtMost: 1`) and then DoH. Decision 0049 points a full tunnel's default resolver at Conduit's relay, so every lookup on the Mac reaches the forwarder, including the ones Conduit makes itself.

Conduit resolves its own upstream proxy hostnames with `getaddrinfo`: mDNSResponder, then the relay, then `LocalDNSForwarder`. Those hostnames often sit outside the tunnel's match and search domains. For example, the proxies are under `corp.example` and the VPN publishes only `de.corp.example`. They then take the public-name path.

That path has a circular dependency. While the VPN is connected, DoH prefers the local proxy session, so it reaches the providers through the same upstream proxies whose names it is resolving. When the single internal attempt fails, for example because the first pushed server is silent during a flap, the proxies' names can only resolve through the proxies. Every public name then fails until the cached answers expire. Observed while investigating a flap outage on PR #330; source [#331](https://github.com/srps/Conduit/issues/331).

**Owner question:** while a tunnel's pushed servers are in use, should Conduit's own upstream proxy hostnames be asked of the tunnel's servers as an internal name is, with no DoH after them?

## Decision

**Recommended: option A.**

1. **Which names.** The hosts of the enabled upstreams in `ProxyConfig`, and the hosts of the `PROXY` entries a PAC answer named. The configuration bounds the first set. The second is the last `PACProxyHosts.limit` (32) hosts used: the engine records the first 32 distinct `PROXY` hostnames of every answer it gives, cached or evaluated, last to first, so an answer's first choice is the newest. Recording a new host past the limit evicts the host used longest ago, which then resolves as a public name until an answer names it again, and emits `pac.proxy_hosts_evicted` (once a minute, counts only). `HTTPS` entries are rejected by `PACChain.classify` and never dialled, so they are not recorded. The record belongs to one PAC URL: it is emptied when PAC routing is off or its URL differs from the one the hosts were learned from, when the engine retires its evaluator or drops its script, and when a refresh installs a different script, in the same step that retires or replaces the script. An answer is stamped together with the script or cached route it comes from, and recorded only if nothing emptied the record since and the configuration still routes by the stamped PAC, so an evaluation that finishes after PAC was turned off never makes its proxy a tunnel name. The configured upstreams are never in the record and stay in the set.
2. **Matching.** Exact, ignoring case and a trailing dot. No suffix matching: a name under a proxy host is a public name.
3. **When.** Only while `SplitDNSTable.usesPushedServers`, and only for a name under no split-DNS rule. A name under a rule keeps the rule's path. A `.local` proxy host under no rule is a proxy host first: it asks the pushed servers, not the table's first servers.
4. **How.** Ask every pushed server, in rule order and each once (`SplitDNSTable.pushedServers`), with `internalDomainTimeout`, the internal stage budget and the internal servers' circuit breaker, as an internal name is asked. The first reply, NXDOMAIN included, is the answer. Silence answers SERVFAIL. It never falls through to DoH or to the 0050 network resolver. Like an internal answer, it is not cached.
5. **Off the VPN.** No pushed servers are in use, so the names take the public-name path unchanged.
6. **Reporting.** `dns.proxy_host_via_tunnel` with `name=`, `servers=` (a count, never an address), `outcome=answered|silent|not_asked` and `suppressed=`, at most one per outcome per 60 s, as `dns.network_resolver_fallback` is.
7. **Wiring.** The orchestrator hands the forwarder a `proxyHostsProvider`, in the same shape as `splitDNSProvider` and `networkResolverProvider`. It reads the current configuration and the `PACProxyHosts` record that `PACRoutingEngine` writes for each answer it gives. Off the VPN the same set is kept out of the 0050 network fallback, as its item 8 keeps the configured hosts, and a network-server answer cached before a name joined the set is not reused for it.

## Alternatives

- **A. Ask every pushed server and never DoH** (recommended). It removes the circular dependency. It costs nothing off the VPN, and it adds nothing for a name the tunnel's servers cannot answer: DoH could not have answered it either, because it travels through those proxies.
- **B. Every pushed server, then DoH on silence**, as decision 0043 does for split-DNS names. The DoH attempt goes through the proxies being resolved, so it adds the DoH timeout to each failed lookup and never answers.
- **C. Make DoH skip the local proxy for these lookups.** On a full tunnel that blocks direct egress, the direct route to the providers is exactly what does not work.
- **D. Pin proxy addresses** from the last good answer, or from the configuration as IP literals. Stale addresses outlive a proxy move. IP literals are already possible today and need no decision; this one serves the many configurations that name the proxies by hostname.
- **E. Raise `askingAtMost` for every public name on a tunnel.** It fixes the proxies' names but sends every public name to each pushed server in turn, which reverses decision 0044's single attempt for all of them.

## Consequences

- On a full tunnel, the proxies' names resolve as long as any pushed server answers, so a flap that silences the first server no longer takes public DNS down through DoH.
- The proxies' names are visible to the tunnel's servers. They already are: the single attempt asks the first of them.
- A proxy name that only public DNS knows, while a tunnel is in use, gets the tunnel servers' NXDOMAIN instead of a DoH answer. DoH over those same proxies could not reliably answer it either. A configuration in this state should name the proxy by IP literal.
- A PAC answer that names many proxies is held to 32 hosts. Past that, the names used longest ago lose the tunnel path until an answer names them again; a proxy still being dialled is always among the most recent.
- The name set is rebuilt from the configuration and the PAC record on each public lookup while pushed servers are in use: one lock, an array copy and a set of at most the upstream count plus 32 names.

## Invariants and verification

- While pushed servers are in use, a configured or PAC-learned proxy host asks every pushed server and never DoH; NXDOMAIN is the answer; silence is SERVFAIL; the event carries a count, never an address, once per outcome per window. Off the VPN the same name takes the public path. A name that only has a proxy host as a suffix is a public name. `Tests/ConduitTests/DNSForwarderProxyHostTests.swift`.
- Off the VPN, with DoH silent, a PAC-learned proxy host is never asked of the network's server: SERVFAIL and `outcome=proxy_host`; a network answer cached before the host was learned is not reused. `DNSForwarderNetworkResolverTests.testAPACLearnedProxyHostIsNeverAskedOfTheNetworkServer` and `testACachedNetworkAnswerIsNotReusedOnceItsNameIsAPACProxy`. A `.local` proxy host asks the pushed servers, not a manual entry: `DNSForwarderProxyHostTests.testALocalProxyHostOnATunnelAsksThePushedServersNotAManualEntry`.
- The PAC record holds its cap and evicts the host used longest ago and reports it; the engine records each answer's `PROXY` hosts, cached or evaluated, first choice newest. `DNSForwarderProxyHostTests`, `PACRoutingEngineTests.testEvaluatedProxyHostsAreRecordedForTheForwarder`, `testACachedAnswerRecordsItsProxyHostAgainAfterEviction` and `testAChainLongerThanTheHostSetKeepsItsFirstChoices`.
- A PAC that no longer routes takes its names with it: an evaluation held across PAC being turned off records nothing and its proxy resolves as a public name while a configured upstream stays a tunnel name; an answer started before the record was emptied is not recorded; a replaced script empties the record and a changed URL hides it before the engine notices. `PACRoutingEngineTests.testAnEvaluationHeldAcrossDisableNeverMakesItsProxyATunnelName`, `testAnAnswerStartedBeforeTheSetWasEmptiedIsNotRecorded` and `testRecordedHostsBelongToThePACTheyCameFrom`, each shown to fail with the record's stamp and configuration checks removed. A dropped script takes its names with it even when the refetch fails, and an answer from a script installed while the lookup ran is recorded: `testADroppedScriptTakesItsProxyHostsWithItWhenTheRefetchFails` and `testAnAnswerFromTheScriptInstalledDuringTheLookupIsRecorded`, each shown to fail with the record emptied after the engine's lock and the stamp taken before the script is read (the #330 review follow-up).
- End to end through the actual host: `pm-sim dns-proxy-names-via-tunnel`. On a full tunnel that pushes `de.corp.example`, with the first pushed server silent and DoH never answering, the upstream's hostname resolves through the second pushed server, DoH is not asked for it, and a public name keeps its single attempt and DoH. With the proxy-host path disabled, four of its twelve checks fail.
- What would disprove the design: a proxy host that reaches DoH or the network resolver while pushed servers are in use, a proxy host that reaches a pushed server off the VPN, a suffix match, or a `dns.proxy_host_via_tunnel` event that carries an address.

## Implementation evidence

- The path, its event and the pushed-server list: [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) (`resolve`, `reportProxyHostViaTunnel`) and [`SplitDNSTable.swift`](../../Sources/ProxyKernel/Network/SplitDNSTable.swift) (`pushedServers`).
- The name set and its cap: [`PACProxyHosts.swift`](../../Sources/ProxyKernel/Proxy/PACProxyHosts.swift), recorded by [`PACRoutingEngine.swift`](../../Sources/ProxyKernel/Proxy/PACRoutingEngine.swift) (`answer`) and handed to the forwarder by [`ProxyOrchestrator.swift`](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift).
- The tests and scenario listed above: [`DNSForwarderProxyHostTests.swift`](../../Tests/ConduitTests/DNSForwarderProxyHostTests.swift), [`PACRoutingEngineTests.swift`](../../Tests/ConduitTests/PACRoutingEngineTests.swift), [`ProxyNamesViaTunnelScenarios.swift`](../../Sources/pm-sim/ProxyNamesViaTunnelScenarios.swift).

Does not prove: behaviour on a real full-tunnel VPN through a real flap, that `getaddrinfo` reaches the forwarder for the proxies' names there, or that the tunnel's servers know the proxies' names.

## Open questions

- Whether a proxy host under a split-DNS rule should also skip the 0043 DoH fallback while pushed servers are in use. Its rule already asks every server, so only the DoH timeout after total silence is at stake.
- Whether the PAC host, which Conduit also resolves itself, belongs in the set.
