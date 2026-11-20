# 0050: Ask the network's own DNS server once when DoH is silent and no internal server can be asked

- Date: 2026-11-19
- Decision: proposed
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

The owner chose option B on 2026-11-19, in a chat session. A chat is never a source for this index, so the record stays `proposed` until the pull request that carries it records the owner's acceptance; it then reads `accepted (owner, 2026-11-19, #N)`.

## Context

With "Manage system DNS" on, every lookup on the Mac goes to Conduit's forwarder on `127.0.0.1`: the PAC host and the upstream proxies' hostnames included. For a name the split-DNS table has no server for, the forwarder asks the public DoH providers and nothing else. Off the VPN, when no split-DNS entry has servers, `SplitDNSTable.firstServers` is empty, so a public name gets no internal attempt at all (#296), and the network's own DNS server, the one DHCP gives the physical service, is never asked: `PushedResolverReading.parse` skips every service that is not a `utun` (decision 0044).

Observed on the owner's machine on 2026-11-19, 14:09 to 14:17, on the office LAN of `<corp>` without the VPN. The LAN blocks direct egress, so every DoH request hung until its timeout. In turn:

1. The PAC fetch failed, because curl resolves the PAC host through the forwarder.
2. The upstream probe failed for the same reason.
3. Routing went direct (`vpnDisconnected`), and direct egress is blocked.
4. Nothing worked. The PAC refresh then backed off (`pac.refresh_backoff failures=4 remainingSeconds=227` at 14:09:52), so even a recovered resolver would not have been used for minutes.

On the same network, 0.6.1 worked only because a manual split-DNS entry, since disabled, asked the company server for every name. A second effect: the DNS health tick's 2 s liveness probe asked a public name, which waited on the hanging DoH requests, so the tick took a slow upstream for a dead relay and restarted it (`dns.pipeline_unresponsive`).

## Decision

**Option B.** When every DoH route went unanswered for a name and the split-DNS table had no server to ask for it, the forwarder asks the network's own DNS server once. Its reply, NXDOMAIN included, is the answer.

1. **The source.** The network's server is the `ServerAddresses` of the primary service's `State:/Network/Service/<id>/DNS`, where the primary service is `State:/Network/Global/IPv4`'s `PrimaryService`. Never `Setup:`, which holds Conduit's own `127.0.0.1`. A primary service on a tunnel interface gives none: a full tunnel's servers are pushed ones. The pushed-resolver observer reads it beside the pushed resolvers, from the keys it already watches plus `State:/Network/Global/IPv4`, so there is no second watcher.
2. **Validated at the boundary** (decision 0046, a trusted local source replaced whole): only IP literals, never loopback (`127/8`, `::1`, `::ffff:127.x`), each once, at most 4 (`PushedResolverReading.networkServerLimit`). Loopback is what Conduit itself writes, as the relay address in `Setup:` and as the 0049 override in a full tunnel's key, so the network server is never one Conduit wrote, on or off the VPN.
3. **When.** Only for a name the table has no server for: a public name with no entry that names servers, or a name under an entry that names none. Only after every DoH route went unanswered: a provider's answer is never second-guessed. Never while any rule in the table asks a server a tunnel pushed, in the table the lookup began with or the one in use when DoH gave up: the fallback is for a network with no internal server. The VPN verdict itself does not gate it.
4. **Bounds.** One attempt, on the first network server whose circuit is closed, with its own timeout (1.5 s, `DNSForwarderTuning.networkResolverTimeout`), made only while a whole attempt fits what is left of the helper relay's 10 s pending window (`UDPRelay.staleTimeoutSeconds`) since the lookup began. It shares the internal servers' circuit breaker (#290), so a silent network server stops costing lookups after three silences.
5. **Reporting.** `dns.network_resolver_fallback` with `outcome=answered|silent|not_asked` and the number of network servers, never an address, rate-limited to one per outcome per minute. `dns.network_resolver_changed` when the set changes, with counts. The circuit events name the server `network-resolver`. The forwarder's counters gain `networkResolverFallbacks`.
6. **Recovery.** When DNS answers on a path after lookups on it went unanswered, or when only the network server answered, the orchestrator retries at once what failed meanwhile: a PAC fetch past the failure backoff and, in direct mode, the upstream probe (`dns.resolution_recovered`). Once per path: the forwarder's start, or a transports reset.
7. **The health probe.** The DNS liveness probe asks `conduit-probe.invalid`, which the forwarder answers itself, so a slow or failing upstream no longer reads as a dead relay.

## Alternatives

- **A. Re-enable the manual entry** that asks the company server for every name. The owner's own interim configuration step, not code. It sends every name to the company server, on and off the company network, and fails wherever that server cannot be reached.
- **B′. Sticky ordering.** As B, but once the network server answers while DoH is silent, ask it first for later names on the same path until DoH answers again. It removes the DoH timeout from every new name's latency. Not chosen now: it changes who sees a name for every lookup on such a path, which is a privacy question of its own; B leaves room for it later.
- **C. The network's server first whenever off the VPN.** Simplest and fastest on a corporate LAN. **Rejected on privacy grounds** by the owner: on a café or hotel network it would hand every name to that network's resolver in plaintext, which DoH exists to avoid.

## Consequences

- On a corporate LAN that blocks direct egress, public names, the PAC host and the upstream hostnames resolve again, and routing and the PAC recover on their own.
- **Plaintext DNS to the local network when DoH is down.** A name whose DoH lookup went unanswered is sent to the network's server unencrypted, as any DHCP-configured Mac sends it. Only then: while DoH answers, the network's server sees nothing. On a hostile network that blocks DoH, the names Conduit would otherwise fail to resolve become visible to it.
- **Latency.** Each new name off the cache waits out the DoH timeout (4 s per request) before the network's server is asked. The answer is cached like any public answer, and the recovery retry makes the PAC and the probe hit the cache. B′ is the remedy if this hurts.
- The fallback needs the pushed-resolver observer, which runs only while `dns.followVPNResolvers` is on (the default) and the forwarder runs. With it off, there is no network server and lookups behave as before.
- The Test DNS button and the health tick share the liveness probe, so Test DNS now proves that the relay and the forwarder answer, not that an upstream does. A SERVFAIL counted as an answer before, so it never proved that either.

## Invariants and verification

- The network server is never loopback and never comes from a tunnel's service or from `Setup:`. `Tests/ConduitTests/NetworkResolverParseTests.swift`: primary only, tunnel excluded, loopback and non-literals skipped, capped, nothing after a failed reading.
- DoH answering means the network server is never asked; a table server or pushed servers in use mean it is never asked, including pushed servers that come into use while DoH is held; with DoH silent and no table server it is asked once and answers; both silent answer SERVFAIL inside the relay window; no attempt is made that cannot fit the window; its circuit opens under its label. `Tests/ConduitTests/DNSForwarderNetworkResolverTests.swift`, counting queries, not timing them, except for the window itself.
- The host gives the forwarder the servers whatever the VPN verdict, reports counts only, and clears them on a failed reading or a stop. `Tests/ConduitTests/RuntimeHostSplitDNSTests.swift`.
- The liveness probe is answered at once while every upstream is silent. `Tests/ConduitTests/DNSLivenessProbeTests.swift`.
- End to end through the actual host: `pm-sim dns-offvpn-network-resolver`, with the VPN disconnected, the manual entry disabled, DoH accepting and never answering, and the network's server a loopback stub. A public name and an upstream hostname resolve, the fallback event fires, routing returns to the upstream after the probe, and a PAC whose host only the stub knows loads. With the fallback disabled, six of its eleven checks fail; with the recovery retry disabled, three fail.
- What would disprove the design: a lookup that reaches the network server while DoH answers or while a tunnel's servers are in the table, or a `dns.network_resolver_*` event that carries an address.

## Implementation evidence

Implemented in #330:

- The source: [`PushedResolver.swift`](../../Sources/PlatformMac/PushedResolver.swift) (`NetworkResolver`, `parseNetworkResolver`) and [`PushedResolverMonitor.swift`](../../Sources/PlatformMac/PushedResolverMonitor.swift) (the global IPv4 key). The host hands it over in [`RuntimeHostSplitDNSDetection.swift`](../../Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift).
- The fallback, its bounds, event and counter, and the recovery report: [`LocalDNSForwarder.swift`](../../Sources/ProxyKernel/Network/LocalDNSForwarder.swift); the recovery retry: [`ProxyOrchestrator.swift`](../../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift) (`handleDNSResolutionRecovered`).
- The probe: [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift) (`dnsLiveness`), tested in [`DNSLivenessProbeTests.swift`](../../Tests/ConduitTests/DNSLivenessProbeTests.swift).
- The tests and scenario listed above: [`NetworkResolverParseTests.swift`](../../Tests/ConduitTests/NetworkResolverParseTests.swift), [`DNSForwarderNetworkResolverTests.swift`](../../Tests/ConduitTests/DNSForwarderNetworkResolverTests.swift), [`NetworkResolverScenarios.swift`](../../Sources/pm-sim/NetworkResolverScenarios.swift).

Does not prove: behaviour on the owner's office LAN with a real DHCP server and a real egress block, that the store's primary service is the physical one there, or how the DoH timeout's latency feels in daily use.

## Open questions

- Whether the latency of waiting out DoH for each new name on such a network calls for B′.
