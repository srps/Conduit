# Design: split DNS follows the resolvers the VPN pushes

Proposal for [#290](https://github.com/srps/Conduit/issues/290) part 2. Date 2026-11-09. Status: proposal, no code. Part 1 of the issue (per-server health circuit) is separate work; this design leaves it a seam and names where the two meet.

## Problem

Split-DNS entries (`ProxyConfig.dnsEntries`, `[DomainDNSEntry]`) are a one-time snapshot. `VPNDNSDetector.detect()` ([`Sources/PlatformMac/VPNDNSDetector.swift`](../Sources/PlatformMac/VPNDNSDetector.swift)) runs `scutil --dns`, parses the scoped resolvers on `utun*` interfaces, and the setup wizard and the Settings "Auto-detect from VPN" button append the result to `dnsEntries`. From then on the entries are ordinary manual configuration and apply on every network. On a phone hotspot the VPN gateway's own name sat under such an entry, the forwarder asked a server only the tunnel can reach, and the VPN could not come up. 0.6.2 added the silence fallback ([decision 0043](decisions/0043-split-dns-names-fall-back-to-doh-on-silence.md), PR #291) so the name resolves publicly after the 2 s internal wait. The snapshot itself is still wrong whenever the network differs from the one it was taken on.

The owner's goal is that split-DNS resolution stops breaking when the network changes. While a tunnel is connected, Conduit follows the resolvers that tunnel pushes. While it is down, those resolvers are unused. Manual entries stay for networks that push nothing.

## What exists today

Read before designing. Each item is the thing the design has to fit.

- **Entries.** `DomainDNSEntry { id, domain, servers, enabled }` in [`UpstreamProxy.swift`](../Sources/ProxyKernel/Models/UpstreamProxy.swift), stored in the DNS section of `ProxyConfig`, bounded by `DomainResourceLimits.dnsEntries` (256) and `.dnsServers`.
- **The forwarder.** `DNSResolutionCore.resolve(query:)` in [`LocalDNSForwarder.swift`](../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) reads `configProvider()` per query. It flattens every enabled entry's servers and asks only `internalServers.first` for every internal name, whichever entry matched (#290 part 1 tracks this). With no enabled entries it asks `192.0.2.53`, a TEST-NET address, so every uncached public name waits `internalAttemptTimeout` (1.5 s) on a blackhole before DoH. `forwardUDP` has no fast failure for it. The table in this design removes that wait by construction; it should also be filed as its own bug, since it affects users with no split-DNS entries at all.
- **The `/etc/resolver` gate.** `SplitDNSVPNGate` ([`SplitDNSVPNGate.swift`](../Sources/PlatformMac/SplitDNSVPNGate.swift)) is a pure value fed `VPNObservedState`. `entriesWanted` is false only for `.disconnected`; `.unknown` and `.reasserting` keep the files. `DNSManager.getEntries(from:vpnConnected:)` returns `[]` when the VPN is down, so the entry files exist only while the tunnel is up. `clearEntryFiles` removes the files for `config.dnsEntries`, and `clearUnconfiguredRecordedFiles` removes journal-recorded files the config no longer names. `SplitDNSEntryFileRepair` retries a failed write or removal when the helper comes back.
- **The host.** `RuntimeHost` ([`RuntimeHost.swift`](../Sources/ConduitRuntime/RuntimeHost.swift), decision 0031) owns the gate, the `DNSManager`, the VPN observer and the network-path observer. `handleVPNStateChange` updates the gate, queues the entry-file operation on `platformWork` in the same turn, then tells the orchestrator, then reconciles system DNS. Network-path updates go through `NetworkPathReports.receive`, which runs the orchestrator's leading-edge invalidation and the settled refresh.
- **The orchestrator's VPN mirror.** `ProxyOrchestrator.vpnConnectedForDNSBox` (a `NIOLockedValueBox<Bool>`, [`ProxyOrchestrator.swift`](../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift) around lines 1084 and 2282) mirrors `snapshot.vpnState == .connected` for the forwarder's `preferProxyPathForDoH` closure, because NIO handlers cannot read the owner's snapshot. The forwarder is built once with `configProvider` and `preferProxyPathForDoH` closures.
- **Config reload.** `applyConfigChange` restarts the forwarder on any `ConfigDiff.dnsChanged` while it runs (`config.dns_restart reason=dns_section`).
- **Observers.** `VPNStatusObserving` ([`VPNStatusObserving.swift`](../Sources/ProxyKernel/Abstractions/VPNStatusObserving.swift)) with `VPNStatusMonitor` on `SCDynamicStore` (`State:/Network/Interface/utun[0-9]+/IPv4|IPv6`, `Setup:/Network/Service/*`) and `FakeVPNStatusObserver`. `NetworkPathObserving` ([`NetworkPathObserving.swift`](../Sources/PlatformMac/NetworkPathObserving.swift)) with `NetworkMonitor` and `FakeNetworkPathObserver`. Both are `setOnChange` / `start` / `stop`, callback on any queue, consumer hops to `@RuntimeActor`.
- **The UI.** `DNSSettingsView` edits `appState.config.dnsEntries` as a draft. The runtime reaches the app only through the control protocol; display text is bounded (decisions 0029, 0038), so anything new the UI shows from the runtime needs a sized field in `ControlDisplayRecordCodec` and `ControlRuntimeSizing`.
- **The import fence.** `ProxyKernel` imports no `SystemConfiguration` ([`scripts/check-kernel-imports.py`](../scripts/check-kernel-imports.py)). Values the kernel consumes are defined in the kernel, Foundation-only; PlatformMac produces them. `VPNObservedState` is the precedent.
- **Designs this builds on.** [`design-vpn-flap-resilience.md`](design-vpn-flap-resilience.md) for the fuser, grace window and what a flap may and may not do. [`design-network-location-recovery.md`](design-network-location-recovery.md) for the rule that VPN and path reports drive reconciliation and that split-DNS policy is not modified by location work.

## Goals

- The forwarder asks the servers the connected tunnel pushes for the domains it pushes them for, within seconds of the tunnel coming up, and stops within seconds of it going down.
- Manual entries keep working exactly as today, gated files included.
- No forwarder restart on a VPN transition. No write to `config.json` for anything the network said.
- Every input is a protocol with a fake, every decision a pure value with tests, every change an event.
- A flap (`.reasserting`) changes nothing a client can see, as the flap design requires.

## Non-goals

- The per-server health circuit and the off-VPN 2 s wait for manual entries (#290 part 1). This design gives it the per-rule server list to work on.
- A per-entry "never resolve publicly" switch (issue open question). Listed under owner decisions, recommended as later work.
- Replacing the forwarder's public-name path, DoH providers or the intercept rules.

## Data shape

Caller's usage first. The forwarder, per query:

```swift
let table = splitDNSProvider()                 // replaces config.dnsEntries reads
guard let rule = table.rule(matching: name) else { /* public path: DoH, cache */ }
for server in rule.servers { /* ask in order, next on silence; part 1 skips open circuits */ }
```

The host, per input:

```swift
if liveSplitDNS.update(gate: splitDNSGate, pushed: pushedResolvers) {   // pure
    let table = liveSplitDNS.table(manual: config.dnsEntries, limits: .standard)
    orchestrator.applySplitDNSTable(table)       // kernel: swap the box, drop affected cache, event
    mutateSnapshot { $0.detectedSplitDNS = liveSplitDNS.detectedInUse.display }   // bounded, for Settings
}
```

### Kernel values (`ProxyKernel/Network/SplitDNSTable.swift`, Foundation only)

```swift
/// Where a rule came from. The forwarder does not branch on it; events and the UI do.
package enum SplitDNSOrigin: Hashable, Sendable {
    case manual                          // an enabled `DomainDNSEntry` with servers
    case detected(interface: String)     // pushed by the tunnel on this utun
}

/// One domain and the servers asked for names at or under it, in the order they are tried.
package struct SplitDNSRule: Hashable, Sendable {
    package let domain: String           // lowercased, no trailing dot; validated where it entered
    package let servers: [String]        // 1...limit IP literals; first is asked first
    package let origins: [SplitDNSOrigin]  // one per server, parallel to `servers`
}

/// What the forwarder consults. Built by the host, swapped whole, never mutated in place.
package struct SplitDNSTable: Hashable, Sendable {
    package static let empty = SplitDNSTable(rules: [])
    package let rules: [SplitDNSRule]    // one rule per domain

    /// Longest-suffix match on the labels of `name`; nil means a public name.
    package func rule(matching name: String) -> SplitDNSRule? { notImplemented() }

    /// Domains in `self` and not in `other`, or the reverse: what a swap has to drop from the response cache.
    package func domainsDiffering(from other: SplitDNSTable) -> Set<String> { notImplemented() }
}
```

One rule per domain. When a detected resolver and a manual entry name the same domain, the rule's servers are the detected servers first, then manual servers not already listed, and `origins` records which is which. Longest suffix wins between rules, so a detected `eu.corp.example` beats a manual `corp.example` for names under it. These are the two precedence rules; there are no others.

### Platform values (`PlatformMac`)

```swift
/// A resolver a tunnel pushed, as the dynamic store holds it. One per (interface, domain set).
package struct PushedResolver: Hashable, Sendable {
    package let interface: String        // "utun4"
    package let domains: [String]        // the domains the store scopes it to; see "What is read"
    package let servers: [String]
}

/// Producer of the current pushed-resolver set. Mirrors `VPNStatusObserving` and `NetworkPathObserving`.
package protocol PushedResolverObserving: AnyObject, Sendable {
    /// Called with the whole current set on every change, on any queue. An empty array is a valid reading.
    func setOnChange(_ onChange: @Sendable @escaping ([PushedResolver]) -> Void)
    func start()                         // reads the store once and reports it, then observes
    func stop()
}
```

The callback carries the whole set, never a delta. The consumer converges to the same state however many readings it missed or received twice (idempotent by construction).

### The policy value (`PlatformMac/LiveSplitDNSPolicy.swift`, sibling of `SplitDNSVPNGate`)

```swift
/// Which pushed resolvers are in use right now, as a pure function of the gate's verdict and the last store
/// reading. The one place that decides it, for the forwarder's table, the events and the Settings display.
package struct LiveSplitDNSPolicy: Sendable {
    package private(set) var lastReading: [PushedResolver] = []
    private var heldThroughFlap: [PushedResolver] = []

    /// Records inputs. Returns true when `detectedInUse` changed.
    package mutating func update(gate: SplitDNSVPNGate, pushed: [PushedResolver]) -> Bool { notImplemented() }

    /// `[]` when the gate withholds (`.disconnected`). The last reading otherwise, except during `.reasserting`,
    /// when an empty reading keeps the set that was in use when the flap began.
    package private(set) var detectedInUse: [PushedResolver] = []

    /// Manual entries plus `detectedInUse`, validated, bounded, merged per domain.
    package func table(manual: [DomainDNSEntry], limits: SplitDNSLimits) -> SplitDNSTable { notImplemented() }
}

package struct SplitDNSLimits: Sendable {
    package var maxDetectedDomains: Int      // owner decision; proposed 16
    package var maxServersPerDomain: Int     // `DomainResourceLimits.dnsServers`, the manual ceiling, reused
}
```

## Shapes considered

Three whole-shape candidates. Each was screened against the architect red flags: a contributor who opens one file and copies the nearest example should end up right for the whole repo.

### A. Merge detected entries into `ProxyConfig` and apply through `applyConfigChange`

The host appends detected `DomainDNSEntry` values to a derived config and calls `orchestrator.applyConfigChange`. Nothing in the kernel changes.

Rejected. `ConfigDiff.dnsChanged` restarts the forwarder, so every VPN transition would recycle the DNS listener (`config.dns_restart`) and the helper relay points at it. The configuration workflow (decisions 0035, 0036) treats `ProxyConfig` as the owner's saved intent with revisions, baselines and whole-request validation; a network observation inside it is a second writer with no revision, and the next save or reload would either persist it or fight it. The next contributor would read `config.dnsEntries` in the UI and see network state, which is the confusion this design exists to remove.

### B. A live table the host builds and pushes into the kernel (chosen)

The kernel defines `SplitDNSTable`. The orchestrator keeps one in a locked box beside `vpnConnectedForDNSBox` and hands the forwarder a `splitDNSProvider` closure, the way it hands `configProvider` and `preferProxyPathForDoH` today. The host owns the two inputs (the gate and the pushed-resolver observer), decides with `LiveSplitDNSPolicy`, and pushes the result with `applySplitDNSTable`. Manual entries enter the same table from the applied config, so the forwarder has one read path for split DNS instead of two.

Chosen. It is the existing shape (observer in PlatformMac, pure decision value, host owns the turn, kernel mirror box, forwarder closure) applied to one more input. No restart. The kernel import fence holds because the kernel only defines values and the box. Events, the entry-file decision and the Settings display all read `LiveSplitDNSPolicy` in the same host turn, so they cannot disagree. Interface depth: the forwarder's public surface shrinks (one `rule(matching:)` instead of three config reads), and the complexity of merging, bounding and flap-holding sits behind one pure value with one test file.

### C. A pull provider the forwarder calls per query

A kernel protocol `SplitDNSSource { func current() -> SplitDNSTable }` implemented in PlatformMac over the store, injected into the forwarder at construction. No host turn, no orchestrator API.

Rejected. The forwarder would ask platform code per query, with the store read or cached inside a NIO-adjacent path. No one turn knows the set changed, so the events, the response-cache drop on a domain entering or leaving the table, the entry-file policy and the Settings display each need their own observation of the same store, or a second notification channel back to the host. B gives all of them one owner for free.

## Where detection runs

### Production observer: `PushedResolverMonitor` (PlatformMac, `SCDynamicStore`)

The same mechanism `VPNStatusMonitor` uses, not `scutil`. `scutil --dns` prints the configuration `configd` builds from the dynamic store's DNS dictionaries, so reading those dictionaries is reading the source `scutil` prints.

Notification patterns:

- `State:/Network/Service/[^/]+/DNS`. A tunnel's service publishes its pushed resolvers here when it connects and removes the key when it disconnects or the client rewrites them.
- `State:/Network/Global/DNS`. The merged primary; a change here is the cheapest signal that `configd` rebuilt the DNS configuration.

On each notification the monitor lists `State:/Network/Service/*/DNS`, and for each key reads the DNS dictionary and the sibling `State:/Network/Service/<id>/IPv4` dictionary for `InterfaceName`. A service whose interface is not `utun*` is skipped. Admission mirrors `VPNStatusMonitor.handleStoreChanges`: a utun that never had IPv4 is an Apple service tunnel and does not count.

What is read from the DNS dictionary, in this order of preference, the first non-empty list winning: `SupplementalMatchDomains`, `SearchDomains`, `DomainName`. `ServerAddresses` gives the servers. Domains that fail `DNSManager.validateDomain`, servers that fail `DNSManager.validateServer`, `local` and the `arpa` reverse zones are dropped with one `dns.split_resolver_ignored` event each, never silently. The reading is reported whole through `onChange`, on the monitor's queue; the host hops.

The parent-domain inference `DetectedDNSConfig.toDNSEntries()` performs today (an entry for `corp.example` when the tunnel pushed `eu.corp.example`) is not carried into the live set. The tunnel's own scoping is what macOS itself uses for those names.

**Observed on the owner's machine (2026-11-09, Cisco Secure Client connected, full tunnel).** The values below are masked: `corp.example` for the pushed domain and RFC 5737 addresses for the servers. The parser fixture uses this shape.

- The service ID is not a UUID. Cisco publishes `State:/Network/Service/com.cisco.anyconnect/DNS` and `State:/Network/Service/com.cisco.anyconnect/IPv4`. The physical service (`State:/Network/Service/<UUID>/DNS`, the hotspot resolver) is listed alongside them, and the `InterfaceName` filter skips it. So the monitor must not assume UUID-shaped service IDs.
- The DNS dictionary has `DomainName` (`corp.example`), `SearchDomains` (`[corp.example]`), `SearchOrder` (`1`) and `ServerAddresses` (two servers, for example `[192.0.2.53, 198.51.100.53]`). There is **no `SupplementalMatchDomains`**, so the preference order above falls through to `SearchDomains`.
- The IPv4 dictionary carries `InterfaceName` (`utun6`), `Addresses`, `Router` and **`OverridePrimary : 1`**. As the monitor expects, `InterfaceName` sits in the IPv4 dictionary, not in the DNS dictionary.
- `State:/Network/Global/DNS` mirrors the tunnel's servers and search domain, with `__CONFIGURATION_ID__ : Default: com.cisco.anyconnect 0`. The VPN is the machine's **primary** resolver, not a supplemental one. `scutil --dns` shows the tunnel resolver scoped to `utun6`, while Conduit's relay (`127.0.0.1`) stays resolver #1 on the physical interface.

What this changes:

- **A full-tunnel VPN pushes a default resolver plus a search domain, not a list of split domains.** For this VPN, the detected set is the one search domain and its servers, which equals today's manual entry.
- **The pushed servers are the VPN's default resolver.** In a full-tunnel profile they are meant to answer every name. Today Conduit sends public names to DoH even while the VPN is up. Whether a full tunnel with `OverridePrimary` should instead route public names to the pushed servers is owner decision 9 below. The recommendation is to keep DoH for public names, which is the current behaviour, and record `OverridePrimary` on the reading so that a later change can act on it.
- **The fixture needs a split-tunnel case too.** It should cover `SupplementalMatchDomains` present and no `OverridePrimary`. That reading comes from the configd sources, not from an observation.

Owner decision 5 covers the alternative, the private `dnsinfo.h` API (`dns_configuration_copy`), which returns exactly the parsed list `scutil --dns` prints but is not in the public SDK.

### Triggers

The three triggers the issue names collapse into one subscription. A VPN connect publishes the DNS key, a disconnect removes it, and a path change that makes the client rewrite its resolvers changes it. There is no `scutil` process, no poll and no re-detection call from the VPN or path handlers. The VPN observer's verdict and the pushed set are two inputs to one policy value, and the host does not need them in any order.

`start()` reads the store once and reports it, so a host launched with the tunnel already up has the set before the first notification, the way `VPNStatusMonitor.primeInitialState` reports the initial utun sweep.

### Fake: `FakePushedResolverObserver` (`PlatformFakes.swift`)

`emit(_ resolvers: [PushedResolver])`, delivered only between `start()` and `stop()`, plus `primedReading` delivered on start, mirroring `FakeVPNStatusObserver`. `RuntimeHostEffects` gains `pushedResolvers: any PushedResolverObserving`; `AppComposition`, `DevLaunch.makeAppState`, `AppStateHarness.launch()`, `ConduitDaemon` and the pm-sim host harness supply it.

### Lifecycle

The monitor runs while the forwarder is enabled (`dns.forwarderEnabled`) and the new `dns.followVPNResolvers` switch is on (owner decision 7), independent of `manageDNSResolvers`, because its consumer is the forwarder, not the entry files. It starts and stops with the VPN observer. A monitor that cannot create its store emits `dns.split_detection_failed` once and the host runs on manual entries alone.

## Flap handling

The fuser already decides what a flap is. The policy follows it and adds one rule.

- `.connected`: `detectedInUse` is the last reading. A reading that arrives before the verdict is kept and takes effect on the verdict.
- `.reasserting`: an empty reading does not clear `detectedInUse`. Tunnel clients often remove and republish the DNS key during a reassert, and the flap design forbids a client-visible change inside the grace window. A non-empty reading during `.reasserting` replaces the held set; the client has republished.
- `.disconnected`: `detectedInUse` is `[]` whatever the reading says. The held set is dropped.
- `.unknown`: like `.connected`, for the same reason `SplitDNSVPNGate` keeps files on `.unknown`: wrongly keeping is self-correcting once the monitor primes, wrongly clearing churns.

The orchestrator's `applySplitDNSTable` drops cached answers for `table.domainsDiffering(from: previous)` and nothing else. A VPN connect already resets the DoH transports and the settled path report already clears the cache (`dns.transports_reset`, `dns.response_cache_cleared`); the targeted drop covers the case neither does, a name resolved and cached publicly off-VPN that is internal once the table gains its domain.

The sequence stamp the host takes for VPN reports (`VPNObservationSequencer`, `vpn.observation_stale`) covers the gate input. The pushed-resolver observer delivers whole readings, so an older reading landing after a newer one is the one hazard; the host delivers them through `deliveries` in arrival order on the owner, as it does network-path batches, and the last one delivered is the current one.

## Flow into the kernel

```swift
extension ProxyOrchestrator {
    /// The forwarder's split-DNS table from now on. Swaps the box, drops cached answers under the domains that entered or
    /// left, emits `dns.split_table_changed`. Never restarts the forwarder. Safe before the forwarder has started.
    package func applySplitDNSTable(_ table: SplitDNSTable) { notImplemented() }
}
```

Inside: `splitDNSBox: NIOLockedValueBox<SplitDNSTable>` beside `vpnConnectedForDNSBox`; the forwarder is constructed with `splitDNSProvider: { [splitDNSBox] in splitDNSBox.withLockedValue { $0 } }`.

Forwarder changes in `DNSResolutionCore.resolve(query:)`:

- `let rule = table.rule(matching: domain)` replaces `isInternalDomain(domain, config:)` and the flattened `internalServers`. `DNSWireFormat.isUnderEnabledDNSEntry` (PR #291) takes the table. `.local` keeps its own predicate.
- An internal name asks `rule.servers` in order with `internalDomainTimeout` split evenly across them, so the total wait stays what it is today. A server that stays silent passes to the next; any reply, NXDOMAIN included, is the answer (0043). All silent falls back to DoH (0043). This is the seam for part 1: the circuit skips a server here.
- A public name with an empty table goes straight to DoH. Today it waits 1.5 s on `192.0.2.53`. With a non-empty table the internal attempt asks the first server of the first rule, which keeps today's behaviour for corporate resolvers that answer public names on the VPN; part 1 decides whether that attempt survives at all.
- Answers under a rule are not cached, as today.

Manual entries reach the table from the host, not from `configProvider()`. `applyConfigChange` already restarts the forwarder on `dnsChanged`; the host also rebuilds the table from the new config in the same turn. A later subtraction can narrow `dnsChanged` so that an entries-only edit no longer restarts the listener, since the forwarder no longer reads entries from config. That is out of scope here and noted so nobody re-adds the read.

The fence: `SplitDNSTable`, `SplitDNSRule` and `SplitDNSOrigin` are Foundation-only kernel values. `PushedResolver`, the observer protocol, the monitor, the fake and the policy are PlatformMac. The host imports both. Nothing new crosses toward the kernel but values.

## Interaction with the `/etc/resolver` gate and the 0043 fallback

**Entry files.** Recommended (owner decision 1): the detected set writes no `/etc/resolver` files. The files exist to send a domain's lookups to tunnel servers when the system resolver is Conduit's forwarder or the Wi-Fi resolver; for a tunnel that pushes its own resolvers, `configd` has already installed a scoped or supplemental resolver for exactly those domains, which is what the monitor is reading. A file would duplicate it, and a stranded duplicate is the deadlock the gate exists to prevent. Manual entries keep the gate, the repair and `DNSManager` untouched: `getEntries(from:vpnConnected:)` still reads `config.dnsEntries`, and the only new `DNSManager` call is `validateDomain` / `validateServer` reused by the monitor.

If the owner chooses files for detected domains instead, `DNSManager`'s entry-file paths take a `[SplitDNSRule]` parameter in place of `config`, `clearEntryFiles` removes the journal-recorded set rather than the config's, and the host runs `reconcileEntryFiles` on a table change as it does on a gate flip. The repair's `Observation.after(config:)` reads would follow. This is the larger change and the reason for the recommendation.

**Shared domains.** With files written for the manual `corp.example` entry (VPN up) and the forwarder preferring the detected servers for `corp.example`, mDNSResponder sends the domain to the manual servers and the forwarder's own clients get detected first. Both point at servers the tunnel reaches, so the two surfaces agree on reachability and differ only in order. The Settings display shows both so a user can delete the manual copy.

**0043 silence fallback.** Unchanged in rule and narrowed in effect. On the VPN, detected rules answer, so the fallback rarely runs. Off the VPN, detected rules are absent, so names under those domains are public names and take the public path with no 2 s wait and with caching; the next table change drops those cached answers. Manual entries off the VPN keep the 0043 behaviour until part 1 lands. The privacy consequence recorded in 0043 (corporate names reaching DoH providers off-VPN) is unchanged for manual entries and applies off-VPN to detected domains as well; the owner decision on a never-public switch (decision 3) is the place to narrow it.

**Office LAN.** No tunnel, nothing pushed, `detectedInUse` is `[]`. Manual entries apply, files withheld (VPN down), and the forwarder asks the manual servers, which answer on the LAN. The same as today; this design does not touch it, which is what the location-recovery design asks.

## Settings UI

Settings → DNS, Split DNS section, becomes two groups.

- **Manual entries.** The list as today, editing `appState.config.dnsEntries`. Rows whose domain is also in the detected set carry a secondary caption "also pushed by the VPN" and a "Remove manual copy" action, so a user who imported their entries can retire them when they see the live set working.
- **Detected from VPN.** Read-only rows from the runtime snapshot: domain, servers, interface, and a state of "in use" (connected), "held" (reasserting) or "idle, VPN down" (disconnected). An empty state reads "Nothing pushed on this network." A toggle "Follow VPN-pushed resolvers" (`dns.followVPNResolvers`) sits above it.
- **Buttons.** "Add DNS Entry" stays. "Auto-detect from VPN" becomes "Copy detected to manual", enabled only when the detected set is non-empty, and appends the detected rules as `DomainDNSEntry` values. That is the one remaining way to pin a set for a network that pushes nothing, and it reads from the monitor's current set, not from `scutil`.
- **Wizard.** The DNS step shows the detected set with "Conduit follows these while the VPN is connected" and an unchecked "Also keep them as manual entries". Recommended default is not to pin (owner decision 4). `VPNDNSDetector` and its `scutil` parser go when the wizard and the button read the monitor; its tests go with it.

The detected set reaches the app as a bounded field on the runtime snapshot, projected by `ProxyControlBridge` with a fixed cap on domains and servers and the usual text budgets (decisions 0029, 0038, sized before codec adoption per 0036). `VPNStatusFormatter` already renders the VPN state the rows' captions derive from.

## Events

Kind `health`, listed beside `dns.transports_reset` in [`events.md`](events.md). Closed detail codes; server addresses are not secrets and may appear, bounded by the table cap.

| Event | When |
| --- | --- |
| `dns.split_table_changed` | The forwarder's table was swapped: `detected_domains=N manual_domains=N rules=N cache_dropped=N reason=pushed\|vpn_connected\|vpn_disconnected\|flap_held\|config\|detection_off`. Emitted by the orchestrator before the log line, once per swap, including the swap to empty. |
| `dns.split_detected` | The in-use detected set changed: `interface=utunN domains=<comma list> servers=N outcome=applied\|held\|cleared`. Emitted by the host from `LiveSplitDNSPolicy` in the turn that decided it. `held` is the flap case. |
| `dns.split_resolver_ignored` | A pushed resolver was dropped before it reached the table: `interface= reason=invalid_domain\|invalid_server\|system_domain\|over_limit\|not_tunnel`. One per dropped resolver per reading, so a persistently odd push is visible but bounded by the cap. |
| `dns.split_detection_failed` | The monitor could not create or read its store: `reason=store_create\|store_read`. Once per start; the host runs on manual entries alone. Warning log line. |

`scripts/check-event-catalogue.py` fails the build until all four are catalogued.

## Tests and pm-sim scenarios

Unit, against values and fakes only:

- `LiveSplitDNSPolicyTests`. The gate state and reading matrix: connected × non-empty applies, connected × empty clears, reasserting × empty holds, reasserting × non-empty replaces, disconnected × anything clears, unknown keeps. `table(manual:limits:)`: shared domain merges detected first, longest suffix order, caps enforced with ignored resolvers reported.
- `PushedResolverMonitorTests`. The parser over fixture dictionaries recorded from the owner's VPN: three domain keys, `InterfaceName` filter, system domains dropped, invalid server dropped.
- `DNSForwarderTests` (extends `DNSForwarderIntegrationTests` from #291). Longest-suffix rule wins; the second server answers when the first is silent; a name under a rule is not cached; an empty table sends a public name straight to DoH with no internal attempt; a table swap drops exactly the differing domains from the cache.
- `RuntimeHostSplitDNSTests` (actual host over `FakeMachine`, `FakeVPNStatusObserver`, `FakePushedResolverObserver`). A primed reading plus `.connected` produces one `applySplitDNSTable` and one `dns.split_detected outcome=applied`; `.disconnected` produces the empty table; the snapshot field follows; `manageDNSResolvers` on writes files for manual entries only.
- `SplitDNSVPNGateTests` and `DNSManagerVPNGatingTests` unchanged, which is the point.

pm-sim, registered in `pm-sim all`:

- `dns-split-follows-vpn`. Fake corp server on loopback answers `host.corp.example`. Off-VPN the forwarder answers from the fake DoH provider and caches. The fake pushed-resolver observer emits `corp.example → loopback server`, the fake VPN observer emits `.connected`: the next answer comes from the corp server and the public answer is gone from the cache. `.disconnected`: the corp server is never asked again, and no internal answer was cached across either transition.
- `dns-split-flap-holds`. `.reasserting` with an empty reading keeps answering from the corp server; the grace window expiring to `.disconnected` stops it; `.connected` with the reading back resumes it.
- `dns-split-second-server`. A rule with two servers, the first silent: the answer comes from the second inside the rule's budget, and DoH is not asked.

Owner validation, recorded in the decision record: hotspot with the VPN off (gateway name resolves publicly, no 2 s wait for names under a detected-only domain), VPN on (corporate names from the pushed servers, Settings shows them in use), VPN off again (set idle within the grace window), office LAN (manual entries, files withheld).

## Migration

No file migration. `DomainDNSEntry` is unchanged, the detected set is never persisted, and `dns.followVPNResolvers` decodes as `true` when absent (owner decision 7). Users who imported their entries keep them as manual entries with today's behaviour. The Settings caption "also pushed by the VPN" and the "Remove manual copy" action are the migration path; nothing deletes configuration on the user's behalf.

The CHANGELOG entry says that imported entries are now redundant on networks that push the same resolvers and names the Settings action to remove them.

## Owner decisions

1. **Files for detected domains.** Recommend none. The tunnel's own scoped resolver covers them, and the entry-file surface is the deadlock-prone one. The alternative is described above and costs a `DNSManager` signature change.
2. **Precedence on a shared domain.** Recommend detected servers first, then manual servers not already listed, with longest suffix deciding between domains. The alternative, manual first, defeats the purpose on the network the user is actually on.
3. **A per-entry "never resolve publicly" switch.** Recommend deferring to part 1, where the circuit decides when a name goes public at all, and scoping it to manual entries when it comes. It does not change the shape here.
4. **Wizard default.** Recommend that the wizard shows the detected set and does not pin it as manual entries unless asked. Pinning is what produced the hotspot failure.
5. **Detection source.** Recommend `SCDynamicStore` DNS keys, public API already used by `VPNStatusMonitor`. The private `dnsinfo.h` API returns the parsed resolver list directly but is not in the SDK and would be the first private symbol in the app. `scutil` polling is rejected either way.
6. **Bounds.** Recommend at most 16 detected domains and the existing `DomainResourceLimits.dnsServers` per domain, with excess reported by `dns.split_resolver_ignored reason=over_limit`. Two new ceilings require the owner's approval per the AGENTS.md rule on bounded collections.
7. **The switch and its default.** Recommend `dns.followVPNResolvers`, default on, in the DNS section. Off means the monitor does not start and the table holds manual entries only.
8. **Parent-domain inference.** Recommend dropping it for the live set and keeping whatever parent entries users already have as manual entries. Inferring `corp.example` from a pushed `eu.corp.example` sends names the tunnel never claimed to its servers.
9. **Full-tunnel default resolver.** In a full-tunnel profile (`OverridePrimary : 1`) the pushed servers are the VPN's default resolver. Recommend keeping DoH for public names, as today, and recording `OverridePrimary` on the reading so that a later change can act on it. Sending every public name to the pushed servers would follow the VPN's intent, but it would make public resolution depend on the internal servers staying healthy.

## Sequencing

Five verifiable units, each green on its own, in this order.

1. **Kernel table.** `SplitDNSTable`, the forwarder consults it, the orchestrator builds it from `config.dnsEntries` for now. Per-rule servers, longest suffix, empty table skips the internal attempt. Forwarder tests. On its own this unit removes the `192.0.2.53` wait and the first-server-only bug that #290 part 1 lists as related.
2. **Platform inputs.** `PushedResolver`, `PushedResolverObserving`, `PushedResolverMonitor`, the fake, `LiveSplitDNSPolicy`. Pure tests and the parser fixture from the owner's VPN.
3. **Host wiring.** `RuntimeHostEffects.pushedResolvers`, the policy in `RuntimeHost`, `applySplitDNSTable`, the four events, the snapshot field and its sizing, the three pm-sim scenarios, `events.md`.
4. **App.** Settings groups, wizard, `VPNDNSDetector` deleted, compositions supply the observer.
5. **Record.** A decision record for owner decisions 1, 2, 4, 5, 6, 7, 8 and 9 with the owner's validation evidence, and 0043's open question on the first server closed by reference.
