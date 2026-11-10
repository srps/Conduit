# 0044: Split DNS follows the resolvers a connected VPN pushes

- Date: 2026-11-10
- Decision: accepted (owner, 2026-11-10, [#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774052129): 1 to 7 as recommended, 8 with full-tunnel `DomainName` and `SearchDomains` counted as pushed domains, and a duplicate-entry hint added to 4; 9 revised the same day, [#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774517730), because its first premise was wrong)
- Implementation: partial
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

History: the owner first answered decision 9 as "public names stay on DoH, as today". That premise was wrong, because today a public name first gets one 1.5 s attempt on the first split-DNS server and reaches DoH only when that server does not answer with records. The owner revised decision 9 on 2026-11-10, before this record merged, to keep that path for manual and detected servers alike.

Split-DNS entries are a snapshot that the setup wizard and the Settings "Auto-detect from VPN" button copy from `scutil --dns` into `config.dnsEntries`. They then apply on every network. On a phone hotspot the VPN gateway's own name sat under such an entry, and the VPN could not come up until the 0043 silence fallback answered it publicly. The owner's goal is that split-DNS resolution stops breaking when the network changes. While a tunnel is connected, Conduit follows the resolvers it pushes. While it is down, they go unused. Manual entries stay for networks that push nothing.

[`design-live-vpn-split-dns.md`](../design-live-vpn-split-dns.md) holds the design: a `PushedResolverMonitor` on `SCDynamicStore` in PlatformMac, a pure `LiveSplitDNSPolicy` beside `SplitDNSVPNGate`, and the host pushing the detected rules into the kernel without a forwarder restart. The orchestrator merges them with the manual entries of its own config in `SplitDNSTable(manual:detected:)`. PR #298 shipped the kernel table this builds on. Observed on the owner's machine with a full-tunnel VPN, the tunnel's DNS key has `DomainName` and `SearchDomains` but no `SupplementalMatchDomains`, and its IPv4 key has `OverridePrimary` 1.

## Decision

1. The detected set writes no `/etc/resolver` files. Manual entries keep the files, the VPN gate and the repair unchanged.
2. On a domain that both name, the detected servers come first, then manual servers not already listed. Longest suffix decides between domains.
3. A per-entry "never resolve publicly" switch is deferred. When it comes, it applies to manual entries only.
4. The wizard shows the detected set and pins it as manual entries only when asked. Settings → DNS shows a hint on a manual entry whose domain the in-use detected set provides, with a one-click "Remove manual copy". The removal edits the configuration draft and goes through the normal save. The runtime never writes configuration.
5. The monitor reads the public `SCDynamicStore` DNS keys. It does not use the private `dnsinfo.h` API or poll `scutil`.
6. The table takes at most 16 detected domains and `DomainResourceLimits.dnsServers` servers per domain. `dns.split_resolver_ignored reason=over_limit` reports the excess.
7. `dns.followVPNResolvers` in the DNS section turns the feature on and off, and decodes as on when absent. Off, the monitor does not start and the table holds manual entries only.
8. The live set infers no parent domains. A DNS key with `SupplementalMatchDomains` contributes only those domains. A key without them whose IPv4 `OverridePrimary` is 1, a full tunnel, contributes its `DomainName` followed by its `SearchDomains`, each once, checked with `DomainNameSyntax`. A key with neither contributes no domains and is rejected with reason `no_match_domains`.
9. Public names keep today's single path. An intercept rule and a cached answer come first. Then one attempt (`internalAttemptTimeout`, 1.5 s) on the table's `firstServers`, whether that server is manual or detected, and DoH unless the server answers with records (`DNSWireFormat.shouldFallbackToPublicDoH`). There is no DoH-only switch for now. The reading records `OverridePrimary` as `PushedResolver.overridesPrimary` because decision 8's full-tunnel domain rule needs it; only that rule branches on it.

## Alternatives

- Merge detected entries into `ProxyConfig`. Rejected in the design: every VPN transition would restart the forwarder, and network state would sit in the owner's saved intent.
- Write `/etc/resolver` files for detected domains (decision 1). `configd` already installs the tunnel's resolver for them, and a stranded file is the deadlock the gate prevents.
- Manual servers first on a shared domain (decision 2). That keeps the stale snapshot ahead of what the current network pushes.
- Infer `corp.example` from a pushed `eu.corp.example` (decision 8). That sends names the tunnel never claimed to its servers.
- Ignore a full tunnel's `DomainName` and `SearchDomains` (decision 8). A full-tunnel profile then detects nothing, and the user keeps the manual entry this work exists to retire.
- Public names on DoH only (decision 9, first answer). It rested on the wrong premise that public names reach DoH only today, and it would remove the one attempt that lets a split-DNS server answer a public name. No DoH-only switch for now.
- Send every public name to a full tunnel's servers with no DoH after them (decision 9). That follows the VPN's intent but makes public resolution depend on the internal servers staying healthy.
- Read the private `dnsinfo.h` API (decision 5). It returns the parsed list directly, but it would be the first private symbol in the app.

## Consequences

- Manual entries never depend on the host pushing. With nothing detected, the table equals today's `SplitDNSTable(entries:)`, so an office LAN, detection switched off and pm-proxy resolve through the manual servers as today. `RuntimeHostSplitDNSTests` and `ProxyOrchestratorSplitDNSTests` cover the three cases.
- On a full-tunnel VPN that pushes `corp.example` as its search domain, the detected set equals the manual entry users imported, so the hint offers to remove it.
- Off the VPN, names under detected-only domains are public names: no wait on a detected server, cached, and visible to the DoH providers, as 0043 already allows for manual entries.
- A `.local` name under no rule goes to `firstServers` with no DoH fallback. With only detected rules in use it now reaches the tunnel's server, where today, with no manual entries, it gets an immediate SERVFAIL.
- A user with no manual entries gains one attempt on the tunnel's first server for public names, only while the detected set is in use. Off the VPN the set is withheld, so no attempt is made, as today (#296).
- A manual entry removed through the hint no longer applies on networks that push nothing, such as an office LAN. The hint only offers the removal, and nothing removes configuration without the user's click.
- Two new ceilings (16 detected domains, servers per domain) join the bounded collections, approved here. The design also adds a 16-resolver cap. It decides which resolvers reach the table, the first 16 in resolver order, and it bounds the Settings display's row count so the codec can never refuse it. That cap is a design addition, pending owner approval, and so is the 64-rejection cap on the set the policy reports as ignored.
- `overridesPrimary` is recorded, and only decision 8's full-tunnel domain rule reads it, so a later change on full-tunnel public names needs no new reading.

## Invariants and verification

- Each decision has the tests and pm-sim scenarios the design lists under "Tests and pm-sim scenarios": `LiveSplitDNSPolicyTests`, `PushedResolverMonitorTests` with the full-tunnel, full-tunnel-with-extra-search-domain and split-tunnel fixtures, `SplitDNSTableTests`, `DNSForwarderTests`, `RuntimeHostSplitDNSTests`, `ProxyOrchestratorSplitDNSTests`, `AppStateSplitDNSHintTests`, and pm-sim `dns-split-follows-vpn` and `dns-split-flap-holds`.
- Disproved by: a name under a manual entry that does not reach its manual servers while nothing is detected, a detected domain that writes an `/etc/resolver` file, a VPN transition that restarts the forwarder or writes `config.json`, a full-tunnel reading whose `SupplementalMatchDomains` are absent and that yields no domains, a split-tunnel reading that yields its `DomainName`, a public name with no intercept rule or cached answer that skips an in-use first server whose circuit is closed, or a public name that waits on a detected server while the set is withheld.
- Owner validation: hotspot with the VPN off; VPN on with the hint shown on an imported entry; Wi-Fi turned off and on again within the grace window, with no `vpn.disconnected.*` event and the set in use or held throughout; Wi-Fi left off past the grace window, with `vpn.disconnected.lost` and the set idle after it; a disconnect from the VPN client, with `vpn.disconnected.user` and the set idle at once, because only a lost network passes through `.reasserting` and the grace window; and the office LAN, as the design lists.

## Implementation evidence

PR #298 delivered the kernel `SplitDNSTable` this builds on, and the design's sequencing names what units 2 to 4 add.

Unit 2, the platform inputs, is [PR #299](https://github.com/srps/Conduit/pull/299). It changes no running-product behaviour: neither the app nor the daemon composes the monitor or the policy yet, and only the `pm-vpn-check` diagnostic prints a reading. [`PushedResolver.swift`](../../Sources/PlatformMac/PushedResolver.swift) parses the store's DNS keys under decisions 5 and 8, and [`PushedResolverMonitor.swift`](../../Sources/PlatformMac/PushedResolverMonitor.swift) observes them, with its fake in [`PlatformFakes.swift`](../../Sources/PlatformMac/PlatformFakes.swift). [`LiveSplitDNSPolicy.swift`](../../Sources/PlatformMac/LiveSplitDNSPolicy.swift) decides which pushed resolvers are in use from the gate, the live tunnels and the reading, holds them through a flap and applies decision 6's caps. [`VPNStateFuser.swift`](../../Sources/ProxyKernel/Network/VPNStateFuser.swift) reports the live tunnel set, and [`SplitDNSTable.swift`](../../Sources/ProxyKernel/Network/SplitDNSTable.swift) merges manual and detected rules under decision 2. [`LiveSplitDNSPolicyTests`](../../Tests/ConduitTests/LiveSplitDNSPolicyTests.swift), [`PushedResolverMonitorTests`](../../Tests/ConduitTests/PushedResolverMonitorTests.swift), [`SplitDNSTableTests`](../../Tests/ConduitTests/SplitDNSTableTests.swift) and [`VPNStateFuserTests`](../../Tests/ConduitTests/VPNStateFuserTests.swift) cover them.

Does not prove: host wiring (unit 3: `RuntimeHost`, the forwarder's provider, the four events, the snapshot field and the pm-sim scenarios), the app (unit 4: Settings, the duplicate-entry hint and the wizard), or the owner validation, which stays pending.

## Open questions

None. Decision 3's switch needs its own issue when it is taken up.
