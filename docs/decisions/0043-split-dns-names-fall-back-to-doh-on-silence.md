# 0043: Split-DNS names fall back to public DoH when the internal server is silent

- Date: 2026-11-09
- Decision: proposed
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

The forwarder asks the first server of the enabled split-DNS entries about every name under one of their domains, waits up to 2 s, and before this change answered SERVFAIL when nothing came back. The internal servers are often reachable only through the VPN, and a VPN client's gateway hostname is often under the same corporate domain. Off the VPN, the gateway's name was then unresolvable, so the VPN could never come up to make the internal server reachable. Observed on a phone hotspot: the forwarder answered SERVFAIL after about 2 s for the gateway's name, while the hotspot's resolver and a public resolver both answered it.

The [2026-09-09 review](../review-2026-09-09.md) noted that internal names never took the public DoH fallback and asked whether that fallback is permitted. This record answers that question for one case: an internal server that does not answer at all.

## Decision

- For a name at or under an enabled split-DNS entry's domain, when the internal server gives no reply (it timed out, or the send failed), the forwarder asks the configured DoH providers and returns their answer.
- Any reply from the internal server, NXDOMAIN, SERVFAIL and REFUSED included, stays the answer. On the VPN, with the internal server answering, nothing changes.
- `.local` names (multicast DNS) never fall back.
- The DoH answer for an internal name is not cached, as internal answers are not, so the internal server's answer wins on the next lookup once it is reachable.
- The decision is a debug log line, like the public-name DoH fallback it mirrors. The resolution core reports per-query outcomes through the log and its metrics counters (`dohFallbacks` counts this fallback too), and has no event sink; listener lifecycle is what the forwarder reports as events.

## Alternatives

- Keep internal names internal-only: the off-VPN deadlock stays.
- Fall back on any failure, NXDOMAIN included: on the VPN it would send names the corporate server denies to public resolvers and could return a public address for an internal host.
- Track internal-server health and use the resolvers the VPN pushes live: the better long-term shape, too large for a release fix. Tracked as #290.

## Consequences

- Off the VPN, names under split-DNS domains go to the configured DoH providers. They are corporate names, so this reveals them to those providers while the internal server is out of reach.
- A lookup for such a name off the VPN costs the 2 s internal wait plus the DoH round trip, on every lookup, because nothing is cached.
- On the VPN with an internal server that has stopped answering, an internal name may get a public address where one exists. A reply of any kind from the internal server prevents this.

## Invariants and verification

- Silence falls back, a reply does not, `.local` never does, and the fallback answer is not cached: `DNSForwarderIntegrationTests.testConfiguredInternalNameFallsBackToDoHWhenInternalServerIsSilent`, `testConfiguredInternalNameKeepsTheInternalServersNXDOMAIN`, `testLocalNameDoesNotFallBackToDoH`, and pm-sim `dns-internal-unreachable-falls-back` (UDP and TCP).
- Disproved by: an internal name that the internal server answered (with any rcode) reaching a DoH provider, a `.local` name reaching one, or a fallback answer served from the cache.

## Implementation evidence

Implemented in [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) (`DNSResolutionCore.resolve(query:)`) with the domain predicates in [`DNSWireFormat.swift`](../../Sources/ProxyKernel/Network/DNSWireFormat.swift). Tests in [`DNSForwarderTests.swift`](../../Tests/ConduitTests/DNSForwarderTests.swift); scenario in [`DNSResolverScenarios.swift`](../../Sources/pm-sim/DNSResolverScenarios.swift).

Does not prove: that the VPN client connects from an off-VPN network with an installed build, or that the internal answer takes over once the VPN is up.

## Open questions

- The owner's authorization has to be recorded on the PR before this record is accepted.
- Only the first configured internal server is asked; #290 covers asking the others and the VPN's own resolvers.
