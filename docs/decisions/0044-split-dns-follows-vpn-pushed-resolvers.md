# 0044: Split DNS follows the resolvers a connected VPN pushes

- Date: 2026-11-10
- Decision: accepted (owner, 2026-11-10, [#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774052129): 1 to 7 and 9 as recommended, 8 with full-tunnel `DomainName` and `SearchDomains` counted as pushed domains, and a duplicate-entry hint added to 4)
- Implementation: planned
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

Split-DNS entries are a snapshot that the setup wizard and the Settings "Auto-detect from VPN" button copy from `scutil --dns` into `config.dnsEntries`. They then apply on every network. On a phone hotspot the VPN gateway's own name sat under such an entry, and the VPN could not come up until the 0043 silence fallback answered it publicly. The owner's goal is that split-DNS resolution stops breaking when the network changes. While a tunnel is connected, Conduit follows the resolvers it pushes. While it is down, they go unused. Manual entries stay for networks that push nothing.

[`design-live-vpn-split-dns.md`](../design-live-vpn-split-dns.md) holds the design: a `PushedResolverMonitor` on `SCDynamicStore` in PlatformMac, a pure `LiveSplitDNSPolicy` beside `SplitDNSVPNGate`, and the host pushing the kernel's `SplitDNSTable` into the forwarder without a restart. PR #298 shipped the kernel table this builds on. Observed on the owner's machine with a full-tunnel VPN, the tunnel's DNS key has `DomainName` and `SearchDomains` but no `SupplementalMatchDomains`, and its IPv4 key has `OverridePrimary` 1.

## Decision

1. The detected set writes no `/etc/resolver` files. Manual entries keep the files, the VPN gate and the repair unchanged.
2. On a domain that both name, the detected servers come first, then manual servers not already listed. Longest suffix decides between domains.
3. A per-entry "never resolve publicly" switch is deferred. When it comes, it applies to manual entries only.
4. The wizard shows the detected set and pins it as manual entries only when asked. Settings → DNS shows a hint on a manual entry whose domain the in-use detected set provides, with a one-click "Remove manual copy". The removal edits the configuration draft and goes through the normal save. The runtime never writes configuration.
5. The monitor reads the public `SCDynamicStore` DNS keys. It does not use the private `dnsinfo.h` API or poll `scutil`.
6. The table takes at most 16 detected domains and `DomainResourceLimits.dnsServers` servers per domain. `dns.split_resolver_ignored reason=over_limit` reports the excess.
7. `dns.followVPNResolvers` in the DNS section turns the feature on and off, and decodes as on when absent. Off, the monitor does not start and the table holds manual entries only.
8. The live set infers no parent domains. A DNS key with `SupplementalMatchDomains` contributes only those domains. A key without them whose IPv4 `OverridePrimary` is 1, a full tunnel, contributes its `DomainName` followed by its `SearchDomains`, each once, checked with `DomainNameSyntax`. A key with neither contributes no domains and is rejected with reason `no_match_domains`.
9. Public names stay on DoH while a full tunnel is up, as today. The reading records `OverridePrimary` as `PushedResolver.overridesPrimary` and nothing acts on it yet.

## Alternatives

- Merge detected entries into `ProxyConfig`. Rejected in the design: every VPN transition would restart the forwarder, and network state would sit in the owner's saved intent.
- Write `/etc/resolver` files for detected domains (decision 1). `configd` already installs the tunnel's resolver for them, and a stranded file is the deadlock the gate prevents.
- Manual servers first on a shared domain (decision 2). That keeps the stale snapshot ahead of what the current network pushes.
- Infer `corp.example` from a pushed `eu.corp.example` (decision 8). That sends names the tunnel never claimed to its servers.
- Ignore a full tunnel's `DomainName` and `SearchDomains` (decision 8). A full-tunnel profile then detects nothing, and the user keeps the manual entry this work exists to retire.
- Send public names to a full tunnel's servers (decision 9). That follows the VPN's intent but makes public resolution depend on the internal servers staying healthy.
- Read the private `dnsinfo.h` API (decision 5). It returns the parsed list directly, but it would be the first private symbol in the app.

## Consequences

- On a full-tunnel VPN that pushes `corp.example` as its search domain, the detected set equals the manual entry users imported, so the hint offers to remove it.
- Off the VPN, names under detected-only domains are public names: no internal wait, cached, and visible to the DoH providers, as 0043 already allows for manual entries.
- A manual entry removed through the hint no longer applies on networks that push nothing, such as an office LAN. The hint only offers the removal, and nothing removes configuration without the user's click.
- Two new ceilings (16 detected domains, servers per domain) join the bounded collections, approved here.
- `overridesPrimary` is recorded but unused, so a later change on full-tunnel public names needs no new reading.

## Invariants and verification

- Each decision has the tests and pm-sim scenarios the design lists under "Tests and pm-sim scenarios": `LiveSplitDNSPolicyTests`, `PushedResolverMonitorTests` with the full-tunnel, full-tunnel-with-extra-search-domain and split-tunnel fixtures, `SplitDNSTableTests`, `DNSForwarderTests`, `RuntimeHostSplitDNSTests`, `AppStateSplitDNSHintTests`, and pm-sim `dns-split-follows-vpn` and `dns-split-flap-holds`.
- Disproved by: a detected domain that writes an `/etc/resolver` file, a VPN transition that restarts the forwarder or writes `config.json`, a full-tunnel reading whose `SupplementalMatchDomains` are absent and that yields no domains, a split-tunnel reading that yields its `DomainName`, or a public name sent to a full tunnel's servers instead of DoH.
- Owner validation: hotspot with the VPN off, VPN on with the hint shown on an imported entry, VPN off again within the grace window, and the office LAN, as the design lists.

## Implementation evidence

None yet. PR #298 delivered the kernel `SplitDNSTable` this builds on, and the design's sequencing names what units 2 to 4 add.

## Open questions

None. Decision 3's switch needs its own issue when it is taken up.
