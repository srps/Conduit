# 0043: Split-DNS names fall back to public DoH when the internal server is silent

- Date: 2026-11-09
- Decision: accepted (owner, 2026-11-09, [#291 comment](https://github.com/srps/Conduit/pull/291#issuecomment-6744513427): approved the silence fallback for 0.6.2)
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

The forwarder asks the first server of the enabled split-DNS entries about every name under one of their domains, waits up to 2 s, and before this change answered SERVFAIL when nothing came back. The internal servers are often reachable only through the VPN, and a VPN client's gateway hostname is often under the same corporate domain. Off the VPN, the gateway's name was then unresolvable, so the VPN could never come up to make the internal server reachable. Observed on a phone hotspot: the forwarder answered SERVFAIL after about 2 s for the gateway's name, while the hotspot's resolver and a public resolver both answered it.

The [2026-09-09 review](../review-2026-09-09.md) noted that recognized internal names stayed on the internal-server path, and asked whether the public DoH fallback that other names take after an internal failure or NXDOMAIN is permitted, since an incomplete internal-domain list exposes names to the DoH provider. This record does not answer that question, which stays open. It widens what reaches the DoH providers: names under a configured split-DNS domain now reach them too, but only while the internal server gives no reply at all.

## Decision

- For a name at or under an enabled split-DNS entry's domain, when the internal server gives no reply (it timed out, or the send failed), the forwarder asks the configured DoH providers and returns their answer.
- Only A and AAAA queries have a DoH lookup. Any other type (SRV, PTR, MX, TXT and the like) under a split-DNS domain gets REFUSED off the network without any provider being asked. That reply is not counted as a DoH fallback (`dohFallbacks`), and its event says `outcome=refused_qtype`.
- Any reply from the internal server, NXDOMAIN, SERVFAIL and REFUSED included, stays the answer. On the VPN, with the internal server answering, nothing changes.
- `.local` names (multicast DNS) never fall back, including names under a split-DNS entry that is itself under `.local`, such as an Active Directory domain `corp.local`.
- Conduit does not cache the DoH answer for an internal name, as it does not cache internal answers. Once the internal server is reachable, its answer wins on Conduit's next lookup. The operating system and browsers keep their own caches, and they can hold the public answer for its TTL after the VPN comes up.
- Each fallback is a routing decision, so it emits `dns.split_dns_doh_fallback` (`domain=` the matched entry, `name=`, `server=`, `outcome=answered|unanswered|refused_qtype`, `suppressed=`) and the log line is derived from it. Off the VPN every lookup under the domain falls back and none is cached, so a `RuntimeEventRepeatGate` holds the event to one per entry domain and outcome per 60 s, the same gate the Kerberos fallback events use. A held-back fallback logs at debug only and is counted in the next event's `suppressed=`.

## Alternatives

- Keep internal names internal-only: the off-VPN deadlock stays.
- Fall back on any failure, NXDOMAIN included: on the VPN it would send names the corporate server denies to public resolvers and could return a public address for an internal host.
- Gate the fallback on VPN state. [`SplitDNSVPNGate`](../../Sources/PlatformMac/SplitDNSVPNGate.swift) already withholds the `/etc/resolver` entry files while the VPN is definitively down, for the same bootstrap deadlock, and the forwarder already receives VPN state through `vpnConnectedForDNSBox` in [`ProxyOrchestrator.swift`](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift), which today only picks the DoH transport. Gating on it would skip the 2 s internal wait off the VPN, and on the VPN it would keep internal names off public DoH even when the internal server has gone silent. Silence was chosen anyway because it does not depend on the VPN verdict being right. A VPN the monitor does not recognize, a monitor that has not primed, or a flap held as connected would gate wrongly and bring the deadlock back, while silence is observed on the query itself. The 2 s wait is tracked in #290.
- Track internal-server health and use the resolvers the VPN pushes live: the better long-term shape, too large for a release fix. Tracked as #290.

## Consequences

- Off the VPN, A and AAAA lookups for names under split-DNS domains go to the configured DoH providers. They are corporate names, so this reveals them to those providers while the internal server is out of reach.
- Off the VPN, other query types under split-DNS domains (SRV, PTR and similar) get REFUSED, as public names of those types already do.
- A lookup for such a name off the VPN costs the 2 s internal wait plus the DoH round trip, on every lookup, because Conduit caches nothing for it. Since #290 part 1 the wait is paid per server until three lookups in a row got no reply from it, the one internal attempt a public name makes included: its circuit then opens and later lookups go to DoH at once while a probe asks the server. Every transports reset closes the circuit, so the wait is paid again after each network change. One lookup's internal attempts share a budget of half the helper relay's 10 s pending window (`UDPRelay.staleTimeoutSeconds`), 5 s (`DNSForwarderTuning.internalStageBudget`): a server is asked only while a whole 2 s attempt fits what is left, so however many servers an entry names, at most two silent ones are waited on before DoH, and the DoH race keeps the window's other half, more than its 4 s request timeout. A server the budget left unasked recorded no silence, so an entry's later servers are reached once the earlier ones have opened their circuits. The worst case, 4 s of attempts plus a DoH race that ends only at its 8 s resource timeout, exceeds the window; a race that ends at its request timeout fits it. A provider answering after about 6 s has its reply dropped by the relay and the client retries.
- After the VPN comes up, clients can keep using a public answer they cached for up to its TTL. Since #290 part 1 the fallback answer's TTLs are cut to 5 s (`DNSResolutionCore.splitDNSFallbackTTL`), what the intercept path uses, so those caches drop it within seconds.
- On the VPN with an internal server that has stopped answering, an internal name may get a public address where one exists. A reply of any kind from the internal server prevents this.

## Invariants and verification

- Silence falls back, a reply does not, `.local` never does (under a `.local` entry or not), only a provider's answer counts as a DoH fallback, the event is emitted once per domain and outcome per window and not when the internal server replies, and the fallback answer is not cached: `DNSForwarderIntegrationTests.testConfiguredInternalNameFallsBackToDoHWhenInternalServerIsSilent`, `testSplitDNSFallbackEventIsThrottledPerDomainAndOutcome`, `testSplitDNSNameOfAnotherTypeIsRefusedWithoutAskingDoH`, `testConfiguredInternalNameKeepsTheInternalServersNXDOMAIN`, `testLocalNameDoesNotFallBackToDoH`, `testNameUnderLocalSplitDNSEntryDoesNotFallBackToDoH`, and pm-sim `dns-internal-unreachable-falls-back` (UDP and TCP, a `corp.local` entry, the event, and the relay window).
- The internal attempts fit the relay window whatever the entry names, a server the budget left unasked records no silence, and the budget leaves the DoH race more than its request timeout: `DNSForwarderHealthTests.testSixSilentServersStillAnswerInsideTheRelayWindow`, `testServersTheBudgetLeftUnaskedRecordNoSilence`, `testInternalStageBudgetLeavesTheDoHRaceRoomInTheRelayWindow`, and pm-sim `dns-internal-stage-budget`.
- Disproved by: an internal name that the internal server answered (with any rcode) reaching a DoH provider, a `.local` name reaching one, a fallback answer served from Conduit's cache, or a fallback that emits no event.

## Implementation evidence

Implemented in [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) (`DNSResolutionCore.resolve(query:)`, `askInternalServers` and `reportSplitDNSFallback`) with the domain predicates in [`DNSWireFormat.swift`](../../Sources/ProxyKernel/Network/DNSWireFormat.swift). Tests in [`DNSForwarderTests.swift`](../../Tests/ConduitTests/DNSForwarderTests.swift) and [`DNSForwarderHealthTests.swift`](../../Tests/ConduitTests/DNSForwarderHealthTests.swift); scenarios in [`DNSResolverScenarios.swift`](../../Sources/pm-sim/DNSResolverScenarios.swift) and [`DNSHealthScenarios.swift`](../../Sources/pm-sim/DNSHealthScenarios.swift).

Does not prove: that the VPN client connects from an off-VPN network with an installed build, or that the internal answer takes over once the VPN is up.

## Open questions

- Resolved by #290 part 1: the servers of the entry the name matched (longest suffix) are asked in order, a server whose circuit is open is skipped, and the event's `server=` lists the servers asked or `none`. The VPN's own resolvers are #290 part 2.
- Whether public DoH fallback for names outside the internal-domain list is permitted, the [2026-09-09 review](../review-2026-09-09.md)'s question, is not decided here.
