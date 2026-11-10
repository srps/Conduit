# Design: split DNS follows the resolvers the VPN pushes

Proposal for [#290](https://github.com/srps/Conduit/issues/290) part 2. Date 2026-11-09. Status: accepted. The owner decided its nine questions on 2026-11-10 ([#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774052129)) and revised decision 9 the same day ([#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774517730)), recorded in [decision 0044](decisions/0044-split-dns-follows-vpn-pushed-resolvers.md). Part 1 of the issue shipped in PR #298 (ab2ffe32): the kernel's `SplitDNSTable`, per-entry servers and per-server circuits. This design builds on that table.

## Problem

Split-DNS entries (`ProxyConfig.dnsEntries`, `[DomainDNSEntry]`) are a one-time snapshot. `VPNDNSDetector.detect()` ([`Sources/PlatformMac/VPNDNSDetector.swift`](../Sources/PlatformMac/VPNDNSDetector.swift)) runs `scutil --dns`, parses the scoped resolvers on `utun*` interfaces, and the setup wizard and the Settings "Auto-detect from VPN" button append the result to `dnsEntries`. From then on the entries are ordinary manual configuration and apply on every network. On a phone hotspot the VPN gateway's own name sat under such an entry, the forwarder asked a server only the tunnel can reach, and the VPN could not come up. 0.6.2 added the silence fallback ([decision 0043](decisions/0043-split-dns-names-fall-back-to-doh-on-silence.md), PR #291) so the name resolves publicly after the 2 s internal wait. The snapshot itself is still wrong whenever the network differs from the one it was taken on.

The owner's goal is that split-DNS resolution stops breaking when the network changes. While a tunnel is connected, Conduit follows the resolvers that tunnel pushes. While it is down, those resolvers are unused. Manual entries stay for networks that push nothing.

## What exists today

Read before designing. Each item is the thing the design has to fit.

- **Entries.** `DomainDNSEntry { id, domain, servers, enabled }` in [`UpstreamProxy.swift`](../Sources/ProxyKernel/Models/UpstreamProxy.swift), stored in the DNS section of `ProxyConfig`, bounded by `DomainResourceLimits.dnsEntries` (256) and `.dnsServers`.
- **The split-DNS table.** `SplitDNSTable` and `SplitDNSRule` in [`SplitDNSTable.swift`](../Sources/ProxyKernel/Network/SplitDNSTable.swift) (PR #298). `SplitDNSTable(entries:)` merges the enabled `dnsEntries` into one rule per lowercased domain, in configuration order, each server once. A rule's `servers` may be empty: an entry that names no server still claims its names. `rule(matching:)` returns the longest suffix match on a label boundary. `firstServers` is the servers of the first rule that has any. A rule has no record of where it came from.
- **The forwarder.** `DNSResolutionCore.resolve(query:)` in [`LocalDNSForwarder.swift`](../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) reads `configProvider()` and builds `SplitDNSTable(entries: config.dnsEntries)` on every query. An internal name asks the matched rule's servers in order. A server whose circuit is open is skipped, after three silences in a row, until a probe hears it or a transports reset closes the circuit. One lookup's internal attempts share `DNSForwarderTuning.internalStageBudget` (5 s). Silence falls back to DoH (0043). A public name that no intercept rule and no cached answer serves makes one attempt (`internalAttemptTimeout`, 1.5 s) on `firstServers`, the first one with a closed circuit, and makes none when no rule has a server (#296). DoH follows unless that server answers with records (`DNSWireFormat.shouldFallbackToPublicDoH`). While the network path is unsatisfied the forwarder answers SERVFAIL at once. `DNSWireFormat.enabledDNSEntryDomain(containing:config:)` and `isInternalDomain(_:config:)` build the same table from config, and only tests call them.
- **The `/etc/resolver` gate.** `SplitDNSVPNGate` ([`SplitDNSVPNGate.swift`](../Sources/PlatformMac/SplitDNSVPNGate.swift)) is a pure value fed `VPNObservedState`. `entriesWanted` is false only for `.disconnected`; `.unknown` and `.reasserting` keep the files. `DNSManager.getEntries(from:vpnConnected:)` returns `[]` when the VPN is down, so the entry files exist only while the tunnel is up. `clearEntryFiles` removes the files for `config.dnsEntries`, and `clearUnconfiguredRecordedFiles` removes journal-recorded files the config no longer names. `SplitDNSEntryFileRepair` retries a failed write or removal when the helper comes back.
- **The host.** `RuntimeHost` ([`RuntimeHost.swift`](../Sources/ConduitRuntime/RuntimeHost.swift), decision 0031) owns the gate, the `DNSManager`, the VPN observer and the network-path observer. `handleVPNStateChange` updates the gate, queues the entry-file operation on `platformWork` in the same turn, then tells the orchestrator, then reconciles system DNS. Network-path updates go through `NetworkPathReports.receive`, which runs the orchestrator's leading-edge invalidation and the settled refresh.
- **The orchestrator's VPN mirror.** `ProxyOrchestrator.vpnConnectedForDNSBox` (a `NIOLockedValueBox<Bool>`, [`ProxyOrchestrator.swift`](../Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift)) mirrors `snapshot.vpnState == .connected` for the forwarder's `preferProxyPathForDoH` closure, because NIO handlers cannot read the owner's snapshot. The forwarder is built once with `configProvider` and `preferProxyPathForDoH` closures.
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

- The per-server health circuit and the internal stage budget. Part 1 shipped them (PR #298) and this design does not change them.
- A per-entry "never resolve publicly" switch (issue open question). Deferred by owner decision 3.
- Replacing the forwarder's public-name path, DoH providers or the intercept rules.

## Data shape

Caller's usage first. The forwarder, per query:

```swift
let table = splitDNSProvider()                 // replaces SplitDNSTable(entries: config.dnsEntries)
guard let rule = table.rule(matching: name) else { /* public path: one attempt on firstServers, DoH, cache */ }
for server in rule.servers { /* as today: in order, open circuits skipped, inside the stage budget */ }
```

The orchestrator owns the table. It merges the manual entries from its own config with the detected rules the host last pushed, and caches the result:

```swift
// at init, in the `config` setter (every config write), and in applyDetectedSplitDNSRules
splitDNSBox.withLockedValue { $0.table = SplitDNSTable(manual: config.dnsEntries, detected: $0.detected) }
```

The host, per input, pushes only the detected rules:

```swift
let ignoredBefore = liveSplitDNS.ignored
let changed = liveSplitDNS.update(gate: splitDNSGate, liveInterfaces: vpnLiveInterfaces, reading: pushedReading)    // pure
for rejection in liveSplitDNS.ignored.subtracting(ignoredBefore) { emit(.splitResolverIgnored(rejection)) }
if changed {
    orchestrator.applyDetectedSplitDNSRules(liveSplitDNS.detectedRules, display: liveSplitDNS.display, reason: reason)   // merge, swap, event, snapshot
}
```

A runtime that never pushes, such as pm-proxy, keeps manual split DNS: with no detected rules the orchestrator's table is `SplitDNSTable(manual: config.dnsEntries, detected: [])`, which equals today's `SplitDNSTable(entries:)`.

### Kernel values (`ProxyKernel/Network/SplitDNSTable.swift`, Foundation only)

`SplitDNSTable` and `SplitDNSRule` exist on main (PR #298). This design adds `SplitDNSOrigin`, `SplitDNSRule.origins`, `SplitDNSTable.init(manual:detected:)` and `DetectedSplitDNSDisplay`. The comments mark which unit adds what.

```swift
/// Where a rule's server came from. The forwarder does not branch on it; events and the UI do.  [unit 2]
package enum SplitDNSOrigin: Hashable, Sendable {
    case manual                          // an enabled `DomainDNSEntry`
    case detected(interface: String)     // pushed by the tunnel on this utun
}

/// One domain and the servers asked for names at or under it, in the order they are tried.
package struct SplitDNSRule: Hashable, Sendable {
    package let domain: String           // lowercased, no trailing dot
    package let servers: [String]        // IP literals in the order asked; empty only for a manual entry that names none
    package let origins: [SplitDNSOrigin]  // [unit 2] one per server, parallel to `servers`; `[.manual]` for a serverless manual rule,
                                           // the one intended exception, so every rule records where it came from
}

/// What the forwarder consults. Built whole, never mutated in place.
package struct SplitDNSTable: Hashable, Sendable {
    package static let empty = SplitDNSTable(rules: [])
    package let rules: [SplitDNSRule]    // one rule per domain

    package init(rules: [SplitDNSRule])

    /// The one merge of manual and detected split DNS.  [unit 2]
    /// - Order: the enabled `manual` entries merged per domain in configuration order, as `init(entries:)` does today,
    ///   then the domains only `detected` names, in `detected` order.
    /// - Precedence on a shared domain: the detected servers first, then manual servers not already listed.
    /// - The per-domain server cap applies to `detected` before the merge: `LiveSplitDNSPolicy` caps each rule at
    ///   `DomainResourceLimits.dnsServers` and the initializer asserts it. Manual servers are appended uncapped.
    /// With `detected` empty, the result equals today's `init(entries: manual)` with every origin `.manual`.
    package init(manual: [DomainDNSEntry], detected: [SplitDNSRule])
    package init(entries: [DomainDNSEntry])            // exists; unit 2 migrates its callers to `init(manual:detected: [])` and deletes it

    package func rule(matching name: String) -> SplitDNSRule?    // exists: longest suffix on a label boundary
    package var firstServers: [String] { get }                    // exists: servers of the first rule that has any
}

/// What Settings shows of the detected set. The host builds it from `LiveSplitDNSPolicy`; the orchestrator stores it on
/// `ProxyOrchestratorSnapshot.detectedSplitDNS` and `ProxyControlBridge` projects it. The value is unit 2, because
/// `LiveSplitDNSPolicy.display` returns it; the snapshot field and the projection are unit 3.  [unit 2]
package struct DetectedSplitDNSDisplay: Hashable, Sendable, Codable {
    package enum State: String, Hashable, Sendable, Codable {
        case inUse                       // the gate allows and the reading is non-empty: its resolvers plus any held ones it does not name, `.reasserting` included
        case held                        // the gate allows and an empty reading kept the previous set in use
        case idle                        // `.disconnected`: rows are the last reading, capped the same way, unused
    }
    package struct Row: Hashable, Sendable, Codable {
        package let interface: String    // "utun6"
        package let domains: [String]
        package let servers: [String]
    }
    package static let none = DetectedSplitDNSDisplay(state: .idle, rows: [])
    package let state: State
    /// One per resolver of the displayed set, in resolver order: `detectedInUse` under `.inUse` and `.held`, the last
    /// reading under `.idle`. Both go through the same resolver order and caps, so each kept domain appears once,
    /// under the first resolver that kept it, a row left with no domain is omitted, and a row's servers are the
    /// resolver's kept servers. So at most `maxDetectedResolvers` rows, `maxDetectedDomains` domains in all and
    /// `maxServersPerDomain` servers a row, in every state.
    package let rows: [Row]
}
```

One rule per domain. `SplitDNSTable(manual:detected:)` owns the merge, and `LiveSplitDNSPolicy` produces only the detected rules it takes. When a detected rule and a manual entry name the same domain, the rule's servers are the detected servers first, then manual servers not already listed, and `origins` records which is which. A server both name counts as detected. Longest suffix wins between rules, so a detected `eu.corp.example` beats a manual `corp.example` for names under it. These are the two precedence rules; there are no others.

Detected resolvers have one order, the resolver order, so the same store contents always build the same table. `LiveSplitDNSPolicy` sorts `detectedInUse` by `searchOrder` ascending, with a missing `searchOrder` last, then by `serviceID`. The order in which the store lists its keys never matters. The resolver order decides four things:

- The order of `detectedRules`, and so the order of the detected-only rules in the table.
- Which resolvers the 16-resolver cap keeps: the first 16 in resolver order. Each one past them is reported as `over_limit` with `value` nil. The cap decides which resolvers reach the table, not only how many rows Settings shows. It is a design addition, pending owner approval; owner decision 6 approved only the domain and server caps.
- Which domains the 16-domain cap keeps: the first 16 distinct domains in resolver order. The rest are reported as `over_limit`.
- The servers of a domain that two detected resolvers both name: the first resolver's servers, then the second's not already listed.

The per-domain server cap applies to the detected servers, before the merge. `LiveSplitDNSPolicy` caps each resolver's servers, and then the detected list of each domain, at `DomainResourceLimits.dnsServers` (8), and reports a detected server past either cap as `over_limit`. `SplitDNSTable(manual:detected:)` then appends the manual servers for the same domain after the detected ones, never displaced and never counted against that cap. Manual entries are already bounded by the same limit at the configuration boundary.

Rule order decides `firstServers`, the one internal attempt a public name makes. `SplitDNSTable(manual:detected:)` lists the manual rules in configuration order, as `init(entries:)` does today, then the detected-only domains in resolver order. A user with manual entries keeps today's first server, or the detected server ahead of it when the first manual domain is also pushed. A user with no manual entries gains this one attempt on the tunnel's first server only while the detected set is in use. Off the VPN the gate withholds the set, so no attempt is made, as today (#296).

### Platform values (`PlatformMac`)

```swift
/// A resolver a tunnel pushed, as the dynamic store holds it. One per service DNS key.
package struct PushedResolver: Hashable, Sendable {
    package let serviceID: String        // "com.cisco.anyconnect", the `<id>` in `State:/Network/Service/<id>/DNS`
    package let searchOrder: Int?        // the DNS dictionary's `SearchOrder`; nil when absent
    package let interface: String        // "utun4"
    /// `SupplementalMatchDomains` when the DNS key has any. Otherwise, only when `overridesPrimary` (a full tunnel),
    /// `DomainName` then `SearchDomains`. Never empty: a key with neither is rejected as `no_match_domains`.
    /// Lowercased, no trailing dot, each once, valid under `DNSManager.validateDomain` (`DomainNameSyntax`).
    package let domains: [String]
    package let servers: [String]
    /// The sibling IPv4 key's `OverridePrimary` is 1: the tunnel is the machine's default resolver, a full tunnel.
    /// Recorded because the parser's full-tunnel domain rule (owner decision 8) needs it, and nothing else branches on it.
    package let overridesPrimary: Bool
}

/// Why the parser left a value out of a reading. The monitor has no event sink; the host reports these.
package struct PushedResolverRejection: Hashable, Sendable {
    package enum Reason: String, Hashable, Sendable {
        case invalidDomain = "invalid_domain", invalidServer = "invalid_server", systemDomain = "system_domain"
        case notTunnel = "not_tunnel", noMatchDomains = "no_match_domains"
        case overLimit = "over_limit"    // comes from the policy's caps, not the parser
    }
    package let serviceID: String
    package let interface: String?       // nil when the key named none
    package let value: String?           // the dropped domain or server; nil when the whole key was rejected
    package let reason: Reason
}

/// One whole reading of the store: the resolvers it admitted and what it rejected.
package struct PushedResolverReading: Hashable, Sendable {
    package enum Failure: String, Hashable, Sendable { case storeCreate = "store_create", storeSubscribe = "store_subscribe", storeRead = "store_read" }
    package var resolvers: [PushedResolver] = []
    package var rejections: [PushedResolverRejection] = []
    package var failure: Failure? = nil  // set when the store could not be created, subscribed to or read; resolvers are then empty
}

/// Producer of the current pushed-resolver set. Mirrors `VPNStatusObserving` and `NetworkPathObserving`.
package protocol PushedResolverObserving: AnyObject, Sendable {
    /// Called with the whole current reading on every change, on any queue. A reading with no resolvers is valid.
    func setOnChange(_ onChange: @Sendable @escaping (PushedResolverReading) -> Void)
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
    package init(limits: SplitDNSLimits)
    package private(set) var lastReading: [PushedResolver] = []
    /// Each service's last resolvers the policy put in use since the last `.disconnected`. A reading replaces the
    /// held resolvers of every service it names and keeps the rest. Only `.disconnected` clears it whole. Under
    /// `.connected`, a resolver whose `interface` is not in `liveInterfaces` is not in it, fresh or kept.
    private var heldThroughFlap: [PushedResolver] = []

    /// Records inputs. `liveInterfaces` is the VPN observer's `liveInterfaceNames`, read with the verdict the gate
    /// last recorded. Returns true when `detectedRules` or `display` changed.
    package mutating func update(
        gate: SplitDNSVPNGate, liveInterfaces: Set<String>, reading: PushedResolverReading
    ) -> Bool { notImplemented() }

    /// The last reading's rejections plus what the caps dropped from `detectedInUse` (`.overLimit`). The host emits
    /// `dns.split_resolver_ignored` for each member that was not in the set before the update, and nothing otherwise.
    package private(set) var ignored: Set<PushedResolverRejection> = []

    /// `[]` when the gate withholds (`.disconnected`). `heldThroughFlap` otherwise, so a service the reading omits
    /// keeps its resolvers in use under `.connected`, `.reasserting` or `.unknown`, less, under `.connected`, any
    /// resolver whose interface is no longer in `liveInterfaces`.
    package private(set) var detectedInUse: [PushedResolver] = []

    /// `detectedInUse` as rules: one per domain in resolver order, capped, every origin `.detected(interface:)`.
    /// `[]` while the gate withholds. What the host passes to `applyDetectedSplitDNSRules`; the kernel merges the
    /// manual entries in.
    package var detectedRules: [SplitDNSRule] { get }

    /// `detectedInUse` with its state, or the last reading as `.idle` when the gate withholds. The idle rows go
    /// through the same resolver order and the same caps (resolvers, domains, servers per domain, each domain once)
    /// as `detectedRules`. Capping idle rows adds nothing to `ignored`, because the set is unused.
    package var display: DetectedSplitDNSDisplay { get }
}

package struct SplitDNSLimits: Sendable {
    package var maxDetectedResolvers: Int    // 16; which resolvers reach the table, and the display's row cap. Pending owner approval
    package var maxDetectedDomains: Int      // 16, owner decision 6
    package var maxServersPerDomain: Int     // `DomainResourceLimits.dnsServers`, owner decision 6; caps each resolver's servers and each detected domain's list
}
```

## Shapes considered

Three whole-shape candidates. Each was screened against the architect red flags: a contributor who opens one file and copies the nearest example should end up right for the whole repo.

### A. Merge detected entries into `ProxyConfig` and apply through `applyConfigChange`

The host appends detected `DomainDNSEntry` values to a derived config and calls `orchestrator.applyConfigChange`. Nothing in the kernel changes.

Rejected. `ConfigDiff.dnsChanged` restarts the forwarder, so every VPN transition would recycle the DNS listener (`config.dns_restart`) and the helper relay points at it. The configuration workflow (decisions 0035, 0036) treats `ProxyConfig` as the owner's saved intent with revisions, baselines and whole-request validation; a network observation inside it is a second writer with no revision, and the next save or reload would either persist it or fight it. The next contributor would read `config.dnsEntries` in the UI and see network state, which is the confusion this design exists to remove.

### B. A live table the host builds and pushes into the kernel (chosen)

The kernel defines `SplitDNSTable`. The orchestrator keeps the detected rules and the merged table in a locked box beside `vpnConnectedForDNSBox` and hands the forwarder a `splitDNSProvider` closure, the way it hands `configProvider` and `preferProxyPathForDoH` today. The host owns the two inputs (the gate and the pushed-resolver observer), decides with `LiveSplitDNSPolicy`, and pushes the detected rules with `applyDetectedSplitDNSRules`. The orchestrator merges them with the manual entries of its own config, so manual split DNS never depends on the host pushing, and the forwarder has one read path for split DNS instead of two.

Chosen. It is the existing shape (observer in PlatformMac, pure decision value, host owns the turn, kernel mirror box, forwarder closure) applied to one more input. No restart. The kernel import fence holds because the kernel only defines values and the box. Events, the entry-file decision and the Settings display all read `LiveSplitDNSPolicy` in the same host turn, so they cannot disagree. Interface depth: the forwarder already consults one `rule(matching:)` (PR #298), and B changes only where its table comes from. The complexity of merging, bounding and flap-holding sits behind one pure value with one test file.

### C. A pull provider the forwarder calls per query

A kernel protocol `SplitDNSSource { func current() -> SplitDNSTable }` implemented in PlatformMac over the store, injected into the forwarder at construction. No host turn, no orchestrator API.

Rejected. The forwarder would ask platform code per query, with the store read or cached inside a NIO-adjacent path. No one turn knows the set changed, so the events, the entry-file policy and the Settings display each need their own observation of the same store, or a second notification channel back to the host. B gives all of them one owner for free.

## Where detection runs

### Production observer: `PushedResolverMonitor` (PlatformMac, `SCDynamicStore`)

The same mechanism `VPNStatusMonitor` uses, not `scutil`. `scutil --dns` prints the configuration `configd` builds from the dynamic store's DNS dictionaries, so reading those dictionaries is reading the source `scutil` prints.

Notification patterns:

- `State:/Network/Service/[^/]+/DNS`. A tunnel's service publishes its pushed resolvers here when it connects and removes the key when it disconnects or the client rewrites them.
- `State:/Network/Global/DNS`. The merged primary; a change here is the cheapest signal that `configd` rebuilt the DNS configuration.

On each notification the monitor lists `State:/Network/Service/*/DNS`, and for each key reads the DNS dictionary and the sibling `State:/Network/Service/<id>/IPv4` dictionary. The interface is the IPv4 dictionary's `InterfaceName`, or the sibling IPv6 dictionary's when IPv4 has none, so an IPv6-only tunnel counts. While the VPN gate depends on `VPNStatusMonitor`'s IPv4 admission, an IPv6-only tunnel never yields `.connected` and this fallback changes nothing; it stays so the reading is right if that admission widens. A key whose IPv4 and IPv6 dictionaries both lack `InterfaceName` is rejected as `not_tunnel`. A service whose interface is not `utun*`, such as the Wi-Fi or hotspot service, is not a pushed resolver and is skipped without a rejection. Whether the tunnel is up is the VPN observer's verdict, which the gate carries; the monitor does not repeat `VPNStatusMonitor`'s IPv4 admission.

What is read from the DNS dictionary (owner decision 8). The domains come from the first of these rules that applies:

1. `SupplementalMatchDomains` is present and non-empty. Those are the domains, and `DomainName` and `SearchDomains` are ignored, because a split tunnel names exactly what it claims.
2. `OverridePrimary` is 1 in the IPv4 dictionary. The profile is a full tunnel, and the domains are `DomainName` followed by `SearchDomains`.
3. Neither. The key names no domains it claims, and the whole key is rejected with reason `no_match_domains`. A service that sets a search domain without claiming the default route is not a full tunnel, and its `DomainName` is not a pushed split domain.

Domains are lowercased, trailing dots stripped, each domain once. `ServerAddresses` gives the servers, and `SearchOrder` gives `searchOrder`. `OverridePrimary` is recorded on the reading as `overridesPrimary`. Domains that fail `DNSManager.validateDomain`, servers that fail `DNSManager.validateServer`, `local` and the `arpa` reverse zones are left out of the resolver and returned in the reading as typed `PushedResolverRejection` values, never dropped silently. The monitor has no event sink. It reports the reading whole, resolvers and rejections, through `onChange` on its queue. The host hops to the owner, hands it to `LiveSplitDNSPolicy`, and emits `dns.split_resolver_ignored` only for rejections that entered the policy's `ignored` set, so a push that stays odd is reported once, not on every notification.

The parent-domain inference `DetectedDNSConfig.toDNSEntries()` performs today (an entry for `corp.example` when the tunnel pushed `eu.corp.example`) is not carried into the live set (owner decision 8). The tunnel's own scoping, or its own search domains on a full tunnel, is what macOS itself uses for those names.

**Observed on the owner's machine (2026-11-09, Cisco Secure Client connected, full tunnel).** The values below are masked: `corp.example` for the pushed domain and RFC 5737 addresses for the servers. The parser fixture uses this shape.

- The service ID is not a UUID. Cisco publishes `State:/Network/Service/com.cisco.anyconnect/DNS` and `State:/Network/Service/com.cisco.anyconnect/IPv4`. The physical service (`State:/Network/Service/<UUID>/DNS`, the hotspot resolver) is listed alongside them, and the `InterfaceName` filter skips it. So the monitor must not assume UUID-shaped service IDs. `VPNStatusMonitor` subscribes to `Setup:/Network/Service/[A-F0-9-]+`, which matches only UUIDs. The new monitor must not copy that pattern; its patterns use `[^/]+` for the service ID.
- The DNS dictionary has `DomainName` (`corp.example`), `SearchDomains` (`[corp.example]`), `SearchOrder` (`1`) and `ServerAddresses` (two servers, for example `[192.0.2.53, 198.51.100.53]`). There is **no `SupplementalMatchDomains`**, so the domains are `DomainName` plus `SearchDomains`, which is `[corp.example]` once the duplicate is dropped.
- The IPv4 dictionary carries `InterfaceName` (`utun6`), `Addresses`, `Router` and **`OverridePrimary : 1`**. As the monitor expects, `InterfaceName` sits in the IPv4 dictionary, not in the DNS dictionary.
- `State:/Network/Global/DNS` mirrors the tunnel's servers and search domain, with `__CONFIGURATION_ID__ : Default: com.cisco.anyconnect 0`. The VPN is the machine's **primary** resolver, not a supplemental one. `scutil --dns` shows the tunnel resolver scoped to `utun6`, while Conduit's relay (`127.0.0.1`) stays resolver #1 on the physical interface.

What this changes:

- **A full-tunnel VPN pushes a default resolver plus a search domain, not a list of split domains.** Owner decision 8 counts its `DomainName` and `SearchDomains` as pushed domains when `OverridePrimary` is 1 and the key has no `SupplementalMatchDomains`. For this VPN, the detected set is `corp.example` and its servers, which equals today's manual entry.
- **The pushed servers are the VPN's default resolver.** In a full-tunnel profile they are meant to answer every name. Owner decision 9 keeps today's public-name path unchanged: an intercept rule and a cached answer come first, then one 1.5 s attempt on the table's `firstServers`, then DoH unless that server answers with records. When the first rule with servers is a detected one, that attempt goes to the tunnel's server, so a full tunnel's resolver answers public names it resolves and DoH answers the rest. The reading records `OverridePrimary` as `overridesPrimary` because decision 8's full-tunnel domain rule needs it.
- **The fixture covers both profiles.** The full tunnel above reads as `domains: [corp.example]`, `overridesPrimary: true`. A full tunnel whose `SearchDomains` add to `DomainName` (`DomainName` `corp.example`, `SearchDomains` `[eu.corp.example, corp.example]`) reads as `[corp.example, eu.corp.example]`. A split tunnel with `SupplementalMatchDomains` `[corp.example, lab.corp.example]`, a `DomainName` of `other.example` and no `OverridePrimary` reads as `[corp.example, lab.corp.example]`, `overridesPrimary: false`. A key with `DomainName` `corp.example`, no `SupplementalMatchDomains` and no `OverridePrimary` is rejected as `no_match_domains`. The split-tunnel shape comes from the configd sources, not from an observation.

Owner decision 5 rejected the alternative, the private `dnsinfo.h` API (`dns_configuration_copy`), which returns exactly the parsed list `scutil --dns` prints but is not in the public SDK.

### Triggers

The three triggers the issue names collapse into one subscription. A VPN connect publishes the DNS key, a disconnect removes it, and a path change that makes the client rewrite its resolvers changes it. There is no `scutil` process, no poll and no re-detection call from the VPN or path handlers. The VPN observer's verdict and the pushed set are two inputs to one policy value. A non-empty reading and the `.connected` verdict that follows it end in the same `detectedInUse` in either order: a reading that arrives first is recorded and takes effect on the verdict, and one that arrives second takes effect at once.

`start()` reads the store once and reports it, so a host launched with the tunnel already up has the set before the first notification, the way `VPNStatusMonitor.primeInitialState` reports the initial utun sweep.

### Fake: `FakePushedResolverObserver` (`PlatformFakes.swift`)

`emit(_ reading: PushedResolverReading)`, delivered only between `start()` and `stop()`, plus `primedReading` delivered on start, mirroring `FakeVPNStatusObserver`.

The policy also needs the set of tunnels the fuser has not declared gone. Main exposes only `VPNStatusObserving.connectedInterfaceName`, the first of `VPNStateFuser.connectedInterfaceNames`, which lists the interfaces in `.connected` or `.linkDownDebouncing`. `VPNStateFuser` gains `liveInterfaceNames: [String]`, in name order: every interface in `.connected`, `.linkDownDebouncing` or `.linkDownAwaitingRecovery`. Only `.removed` and `.neverSeen` interfaces are left out. `VPNStatusObserving` gains `liveInterfaceNames: [String]`, defaulting to `[]`, and `FakeVPNStatusObserver` makes it settable. The host reads it in the monitor's `onChange`, where it reads `connectedInterfaceName` today, so the set belongs to the verdict it arrives with.

The set only helps if the monitor delivers when it changes. On main, `VPNStatusMonitor` re-delivers an unchanged `.connected` only when the first name moves. `refreshConnectedInterface()` compares `fuser.connectedInterfaceNames.first` with the name it stored last, and the `.noChange` branch of `applyFuserDecision(_:)` re-delivers `fuser.lastEmittedState` only when that comparison moved and the verdict is `.connected`. A tunnel that is removed while one that sorts before it stays up, such as `utun7` going while `utun3` stays, moves no first name, so the host never hears of it. Unit 2 changes `refreshConnectedInterface()` to store both `connectedInterfaceNames.first` and `liveInterfaceNames`, read from the fuser in the same call, and to return true when either moved. The `.noChange` branch keeps its condition. So the monitor re-delivers `.connected` whenever the live set changes, as well as when the first name moves. The orchestrator already treats a repeated state as a name update and emits no `vpn.*` event for it. The comparison runs against `SCDynamicStore` and has no unit test, as the first-name comparison has none today. `VPNStateFuserTests` pins the fuser side of the case it has to catch.

`RuntimeHostEffects` gains `pushedResolvers: any PushedResolverObserving`; `AppComposition`, `DevLaunch.makeAppState`, `AppStateHarness.launch()`, `ConduitDaemon` and the pm-sim host harness supply it.

### Lifecycle

The monitor runs while the forwarder is enabled (`dns.forwarderEnabled`) and the new `dns.followVPNResolvers` switch is on (owner decision 7), independent of `manageDNSResolvers`, because its consumer is the forwarder, not the entry files. The host starts it when both settings are on and stops it when either is off, at module start, at module stop, and on a config apply that flips either setting. A flip to off pushes an empty detected set with `reason=detection_off`. A monitor that cannot create, subscribe to or read its store reports a reading with `failure` set. A failed subscription (`SCDynamicStoreSetNotificationKeys` or `SCDynamicStoreSetDispatchQueue` returning false) detaches the store and records nothing, so the next stop and start retries. The host emits `dns.split_detection_failed` when `failure` changes to a value, once per start, and runs on manual entries alone.

## Flap handling

The fuser already decides what a flap is. The policy follows it and adds one rule, applied per service. `heldThroughFlap` holds each service's last resolvers in use since the last `.disconnected`, and `detectedInUse` is that held set whenever the gate does not withhold. On each update the new held set is the reading's resolvers whose `interface` is live plus every held resolver whose `serviceID` the reading does not name and whose `interface` is still live, sorted by `searchOrder`, then `serviceID`. A resolver whose interface is not live is not in use, whether it is fresh or kept. The caps apply after the union. A resolver the reading republishes replaces its held version. An empty reading is the case where the reading names no service, so it keeps every live held resolver; it is not a separate rule. With two tunnels, a reading in which one tunnel has withdrawn its DNS key during a flap and the other still publishes keeps the flapping tunnel's resolvers, as an empty reading would for that tunnel alone.

- `.connected`: live means in the observer's `liveInterfaceNames`. The reading's resolvers on a live interface are in use, and every held resolver of a service the reading omits stays while its `interface` is live. The filter applies to the reading too, because the host passes `lastReading` back on a VPN-only update: a reading that still names `utun7` after `utun7` left the live set must not put it back. A reading that arrives while the gate says `.disconnected` is recorded and takes effect on the `.connected` that follows. Before the first verdict the gate reads `.unknown`, so a reading is already in use then. A DNS key that arrives before the fuser admits its interface is recorded and not yet in use. It converges: the live set changing when the fuser admits the interface makes the monitor deliver again, and the host passes `lastReading` back with the new set.
- `.reasserting`: the same rule, without the interface filter. The grace window already bounds the hold: it ends in `.disconnected`, which clears the set, or in `.connected`, which applies the filter. Tunnel clients often remove and republish the DNS key during a reassert, and the flap design forbids a client-visible change inside the grace window, so a service missing from the reading keeps its held resolvers. A service the reading names replaces its held resolvers, because its client has republished.
- `.disconnected`: `detectedInUse` is `[]` whatever the reading says, and the held set is cleared. This is the only verdict that clears it.
- `.unknown`: applies the reading like `.connected`, but without the interface filter, the same as under `.reasserting`. Under `.unknown` the fuser has admitted no tunnel, so `liveInterfaceNames` is empty and filtering by it would drop every held resolver. The policy applies the reading for the same reason `SplitDNSVPNGate` keeps files on `.unknown`. Wrongly keeping corrects itself once the VPN observer primes, and wrongly clearing churns.

The rule does not depend on the order in which observers report. An empty reading that lands just before `.disconnected` and one that lands just after it end in the same empty set. The cost is that a tunnel which withdraws its DNS key and stays connected keeps its last set until it disconnects, whether or not another tunnel still publishes. A service that withdraws its key for good while its tunnel stays up keeps its last resolvers until that tunnel leaves the live set or the VPN disconnects. That tunnel pushed those servers and is still up, so they are the servers it last asked for.

The interface filter covers a second tunnel. The fuser reports `.connected` while any utun is connected, so when the corporate tunnel `utun7` is removed and another tunnel `utun3` stays up, the verdict never reaches `.disconnected`. Without the filter, `utun7`'s held resolvers would stay in use for as long as `utun3` is up, pointing at servers only `utun7` reached. With it, the `.connected` the monitor re-delivers when `utun7` leaves `liveInterfaceNames` drops them. A tunnel that is debouncing or awaiting recovery stays in the live set, so a flap of `utun7` while `utun3` stays up keeps `utun7`'s held set, as a flap of `utun7` alone would. One difference from a flap alone: the fuser starts a grace window only when the fused verdict turns `.reasserting`, and with `utun3` connected it stays `.connected`. So `utun7`'s held set lasts until `utun7` recovers or the tunnel client removes its interface, not until `graceSeconds` runs out.

A table swap drops nothing from the response cache, because no cached answer can be served across it. `DNSResolutionCore.resolve(query:)` decides whether a name is internal from the table it reads at the start of the query ([`LocalDNSForwarder.swift`](../Sources/ProxyKernel/Network/LocalDNSForwarder.swift) lines 816-818 on main at ab2ffe32). It reads the cache only for a name that is not internal (line 840) and stores an answer only for a name that is not internal (lines 940-942). So a name cached publicly off the VPN is never read from the cache once the table gains its domain, and a name that leaves the table has no cached answer, because internal answers are never stored. A query that started before a swap can still store a public answer after it, and the same check keeps that answer unread while the name is internal. Unit 3 keeps both checks against the one table the query read. A VPN connect already resets the DoH transports and the settled path report already clears the cache (`dns.transports_reset`, `dns.response_cache_cleared`), and nothing here adds to them.

The sequence stamp the host takes for VPN reports (`VPNObservationSequencer`, `vpn.observation_stale`) covers the gate input. The pushed-resolver observer delivers whole readings, so an older reading landing after a newer one is the one hazard; the host delivers them through `deliveries` in arrival order on the owner, as it does network-path batches, and the last one delivered is the current one.

## Flow into the kernel

```swift
extension ProxyOrchestrator {
    /// The detected half of the forwarder's split-DNS table from now on. Stores `rules`, rebuilds the merged table as
    /// `SplitDNSTable(manual: config.dnsEntries, detected: rules)`, and, when the merged table changed, swaps it and
    /// emits `dns.split_table_changed` with `reason`. Sets
    /// `snapshot.detectedSplitDNS` to `display`. Never restarts the forwarder. Safe before the forwarder has started.
    package func applyDetectedSplitDNSRules(
        _ rules: [SplitDNSRule], display: DetectedSplitDNSDisplay, reason: DetectedSplitDNSChangeReason
    ) { notImplemented() }
}

/// The host input that changed the detected rules, the `reason` of `dns.split_table_changed`. A config change is not
/// a case: the orchestrator's `config` setter detects it and emits `reason=config` itself.  [unit 3]
package enum DetectedSplitDNSChangeReason: String, Hashable, Sendable {
    case pushed                                  // a pushed-resolver reading
    case vpnConnected = "vpn_connected"          // a VPN report of `.connected` or `.unknown`
    case vpnDisconnected = "vpn_disconnected"    // a VPN report of `.disconnected`
    case flapHeld = "flap_held"                  // a VPN report of `.reasserting`
    case detectionOff = "detection_off"          // `dns.followVPNResolvers` turned off; the host pushes `[]`
}
```

Inside: `splitDNSBox`, a `NIOLockedValueBox` beside `vpnConnectedForDNSBox`, holds the detected rules and the merged table built from them. The orchestrator builds the merged table at init from the initial config, in the setter of `ProxyOrchestrator.config`, and in `applyDetectedSplitDNSRules`. The setter is the one choke point for config writes. `config` is a computed `package var` whose setter writes `configBox.current`, and besides `applyConfigChange` (`config = newConfig`), eight sites on main write it directly, in `NetworkTransitionScenarios.swift` (pm-sim), `TunnelReconcileTests`, `RuntimePhysicalOrderingTests` and `ProxyOrchestratorLocalPACTests`. One of them writes a nested property, `orchestrator.config.tunnels.definitions`, which also runs the setter. Rebuilding only in `applyConfigChange` would leave the forwarder on the old manual entries after such a write. So the setter writes `configBox.current` first, as its invariant requires, then rebuilds the merged table from the new `dnsEntries` and the stored detected rules. When the table changed, the setter swaps it and emits `dns.split_table_changed reason=config`, so the host never pushes for a config change. A query reads the cached table and never merges. The forwarder is constructed with `splitDNSProvider: { [splitDNSBox] in splitDNSBox.withLockedValue { $0.table } }`. The snapshot write goes through `mutateSnapshot`, which is `private` to `ProxyOrchestrator.swift`, so `applyDetectedSplitDNSRules` must live in that file, not in an extension elsewhere. The host has no other way to set the field. Not every snapshot write takes that path: the forwarder's `onMetrics` hop writes its counters to `snapshot` directly. `ProxyOrchestratorSnapshot` gains `detectedSplitDNS: DetectedSplitDNSDisplay`, decoding as `.none` when absent.

Forwarder changes, unit 3:

- `LocalDNSForwarder.init` gains `splitDNSProvider: (@Sendable () -> SplitDNSTable)? = nil`. The orchestrator passes its box. When it is nil, `DNSResolutionCore` builds `SplitDNSTable(manual: configProvider().dnsEntries, detected: [])` per query, which is today's table. pm-dns, the pm-sim scenarios and the forwarder tests construct the forwarder with `configProvider` only, so they keep manual split DNS with no change.
- In `DNSResolutionCore.resolve(query:)`, `let table = splitDNSProvider()` replaces `SplitDNSTable(entries: config.dnsEntries)`. Everything after that line is PR #298's and stays: the matched rule's servers in order, open circuits skipped, the stage budget, the 0043 fallback on silence, the one attempt on `firstServers` for a public name, and no internal answer cached.
- `DNSWireFormat.enabledDNSEntryDomain(containing:config:)` and `isInternalDomain(_:config:)` already have no production caller on main: `isInternalDomain` calls `enabledDNSEntryDomain`, and only `DNSForwarderTests` calls `isInternalDomain`. Their tests in `DNSForwarderTests` move to `table.rule(matching:)` and both functions are deleted in the same unit, so nothing outside `SplitDNSTable(manual:detected:)` reads split DNS from config again. `.local` keeps `isMulticastDNSName`.

Manual entries reach the table from the orchestrator's own config, never from the host. The table therefore holds the manual entries whenever the host has pushed nothing: at launch before the first VPN report, with the VPN `.disconnected`, with `dns.followVPNResolvers` off, and in pm-proxy, which runs an orchestrator with no host. `applyConfigChange` still restarts the forwarder on `dnsChanged`. A later subtraction can narrow `dnsChanged` so that an entries-only edit no longer restarts the listener, since the forwarder reads entries through the table. That is out of scope here.

The fence: `SplitDNSTable`, `SplitDNSRule` and `SplitDNSOrigin` are Foundation-only kernel values. `PushedResolver`, the observer protocol, the monitor, the fake and the policy are PlatformMac. The host imports both. Nothing new crosses toward the kernel but values.

## Interaction with the `/etc/resolver` gate and the 0043 fallback

**Entry files.** Owner decision 1: the detected set writes no `/etc/resolver` files. The files exist to send a domain's lookups to tunnel servers when the system resolver is Conduit's forwarder or the Wi-Fi resolver; for a tunnel that pushes its own resolvers, `configd` has already installed a scoped or supplemental resolver for exactly those domains, which is what the monitor is reading. A file would duplicate it, and a stranded duplicate is the deadlock the gate exists to prevent. Manual entries keep the gate, the repair and `DNSManager` untouched: `getEntries(from:vpnConnected:)` still reads `config.dnsEntries`, and the only new `DNSManager` call is `validateDomain` / `validateServer` reused by the monitor.

If the owner chooses files for detected domains instead, `DNSManager`'s entry-file paths take a `[SplitDNSRule]` parameter in place of `config`, `clearEntryFiles` removes the journal-recorded set rather than the config's, and the host runs `reconcileEntryFiles` on a table change as it does on a gate flip. The repair's `Observation.after(config:)` reads would follow. This is the larger change and the reason for the recommendation.

**Shared domains.** With files written for the manual `corp.example` entry (VPN up) and the forwarder preferring the detected servers for `corp.example`, mDNSResponder sends the domain to the manual servers and the forwarder's own clients get detected first. Both point at servers the tunnel reaches, so the two surfaces agree on reachability and differ only in order. The Settings display shows both so a user can delete the manual copy.

**0043 silence fallback.** Unchanged in rule and narrowed in effect. On the VPN, detected rules answer, so the fallback rarely runs. Off the VPN, detected rules are absent, so names under those domains are public names. They take the public path, with no wait on a detected server and with caching, and with the one attempt on a manual first server only when a manual entry names one. Once the VPN is back, the table makes those names internal again and the forwarder no longer reads their cached public answers. Manual entries off the VPN keep the 0043 behaviour, with the wait paid per server until its circuit opens (PR #298). The privacy consequence recorded in 0043 (corporate names reaching DoH providers off-VPN) is unchanged for manual entries and applies off-VPN to detected domains as well; a never-public switch, deferred by owner decision 3, is where to narrow it later.

**Office LAN.** No tunnel, nothing pushed, `detectedInUse` is `[]`. The orchestrator's table is `SplitDNSTable(manual: config.dnsEntries, detected: [])`, which equals today's table, so manual entries apply from launch whether or not the host has pushed anything. Files are withheld (VPN down), and the forwarder asks the manual servers, which answer on the LAN. That is the same as today, and this design does not touch it, which is what the location-recovery design asks. `RuntimeHostSplitDNSTests` proves it for a LAN launch with the VPN `.disconnected` and for detection off, and `ProxyOrchestratorSplitDNSTests` proves it for pm-proxy's headless path.

## Settings UI

Settings → DNS, Split DNS section, becomes two groups.

- **Manual entries.** The list as today, editing `appState.config.dnsEntries`.
- **Duplicate-entry hint (owner decision 4).** A manual entry whose domain, lowercased and without a trailing dot, is a domain in the in-use detected set (connected or held, not idle) shows the hint "Also pushed by the VPN on utunN" with the detected servers beside its own, and a "Remove manual copy" button. One click removes the entry from the draft, as the row's delete button does, and the settings save path persists it: the debounced save, or `commitPendingEdit`, with its validation and revision checks. The runtime never writes configuration; the hint is computed in the app from the draft and the snapshot's detected rows. The hint does not say the entry is useless: a manual entry still applies on networks that push nothing, such as the office LAN, and a user who needs it there keeps it.
- **Detected from VPN.** Read-only rows from the runtime snapshot's `detectedSplitDNS`: domains, servers, interface, and its state as "in use" (`.inUse`), "held" (`.held`) or "idle, VPN down" (`.idle`). An empty state reads "Nothing pushed on this network." A toggle "Follow VPN-pushed resolvers" (`dns.followVPNResolvers`) sits above it.
- **Buttons.** "Add DNS Entry" stays. "Auto-detect from VPN" becomes "Copy detected to manual", enabled only when the detected set is non-empty, and appends the detected rules as `DomainDNSEntry` values. That is the one remaining way to pin a set for a network that pushes nothing, and it reads from the monitor's current set, not from `scutil`.
- **Wizard.** The DNS step shows the detected set with "Conduit follows these while the VPN is connected" and an unchecked "Also keep them as manual entries". By owner decision 4 it does not pin unless asked. `VPNDNSDetector` and its `scutil` parser go when the wizard and the button read the monitor; its tests go with it.

The detected set reaches the app as a bounded field on the control snapshot. `RuntimeSnapshotControlProjection` maps `DetectedSplitDNSDisplay` to a `ControlDetectedSplitDNS` value with `ControlDetectedSplitDNSRow` rows. Its caps are at most 16 rows (`SplitDNSLimits.maxDetectedResolvers`), at most 16 domains across all rows (`SplitDNSLimits.maxDetectedDomains`), and at most `DomainResourceLimits.dnsServers` servers per row (`maxServersPerDomain`). These are true bounds of every valid policy output, idle included: rows are kept resolvers, each kept domain is listed once, and each resolver's servers are capped, whether the rows come from `detectedInUse` or from the last reading. Every domain passed `DomainNameSyntax`, every server is an IP literal, and every interface is a utun name, which macOS bounds at `IFNAMSIZ` (16 bytes, the terminating NUL included, so at most 15 characters). So each text value is bounded too. The codec therefore cannot refuse a valid policy output; a refusal means a bug. `ControlRuntimeSizing.swift` gains `measure(into:)` for the value and its rows, counting each interface, domain and server as text and each list as elements, and `ControlRuntimeSnapshot.measure(into:)` calls it. `ControlDisplayRecordCodec.swift` gains their encode and decode, refusing a list over its cap. A codec test builds the maximal policy output, 16 resolvers on 16 interfaces with one longest valid domain each and 8 IPv6 servers each, once as `.inUse` and once as `.idle` after `.disconnected`, and asserts that each round-trips and fits the snapshot frame. These follow decisions 0029 and 0038, sized before codec adoption per 0036. `VPNStatusFormatter` already renders the VPN state the rows' captions derive from.

## Events

Kind `health`, listed beside `dns.transports_reset` in [`events.md`](events.md). Closed detail codes; server addresses are not secrets and may appear, bounded by the table cap.

| Event | When |
| --- | --- |
| `dns.split_table_changed` | The forwarder's table was swapped: `detected_domains=N manual_domains=N rules=N reason=pushed\|vpn_connected\|vpn_disconnected\|flap_held\|config\|detection_off`. Emitted by the orchestrator before the log line, once per swap, including the swap to empty. `reason=config` comes from the setter of `ProxyOrchestrator.config`, which every config write passes through; the other reasons are the `DetectedSplitDNSChangeReason` the host passed to `applyDetectedSplitDNSRules`. |
| `dns.split_detected` | The in-use detected set changed: `interface=utunN domains=<comma list> servers=N outcome=applied\|held\|cleared`. Emitted by the host from `LiveSplitDNSPolicy` in the turn that decided it. `held` means an empty reading left the held set in use. |
| `dns.split_resolver_ignored` | A rejection entered `LiveSplitDNSPolicy.ignored`: `service= interface= reason=invalid_domain\|invalid_server\|system_domain\|over_limit\|not_tunnel\|no_match_domains`. Emitted by the host, once per rejection when it enters the set. A reading that repeats the same rejections emits nothing, so a persistently odd push is reported once. |
| `dns.split_detection_failed` | A reading arrived with `failure` set: `reason=store_create\|store_subscribe\|store_read`. Emitted by the host, once per start; the host runs on manual entries alone. Warning log line. |

`scripts/check-event-catalogue.py` fails the build until all four are catalogued.

## Tests and pm-sim scenarios

Unit, against values and fakes only:

- `LiveSplitDNSPolicyTests`. The gate state and reading matrix: connected × non-empty applies, connected × empty keeps the held set, reasserting × empty keeps the held set, reasserting × non-empty replaces the services it names, disconnected × anything clears the held set, unknown applies the reading like connected. A non-empty reading that arrives before `.connected` and one that arrives after it end in the same `detectedInUse`. Two tunnels, with the dropped one sorting after the one that stays so that the first name never moves: the corporate tunnel `utun7` is removed while `utun3` stays up with no DNS key, so the verdict stays `.connected`, the reading turns empty and `liveInterfaces` goes from `[utun3, utun7]` to `[utun3]`; `utun7`'s held resolvers are dropped and `detectedRules` is `[]`. `utun7` awaiting recovery while `utun3` stays connected (`.connected`, empty reading, `liveInterfaces` still `[utun3, utun7]`) keeps them. A pure flap of `utun7` (`.reasserting`, empty reading) keeps them. Per service: with `utun7` (`corp`) and `utun3` (`branch`) both publishing, a reading with only `branch` while both interfaces stay live keeps `corp`'s held resolvers, under `.connected` and `.reasserting`; the same reading with `utun7` gone from `liveInterfaces` drops them; and a reading that republishes `corp` with new servers replaces its held version and keeps `branch`. Replaying the two-tunnel `lastReading` after `utun7` leaves `liveInterfaces` drops `corp`. A reading that names `utun9` before `utun9` is live puts nothing in use, and the same reading replayed once `liveInterfaces` includes `utun9` puts it in use. An empty reading on either side of `.disconnected` ends in `[]`. `detectedRules`: the same resolvers delivered in shuffled order build the same rules, sorted by `searchOrder`, a missing `searchOrder` last, ties by `serviceID`. Two detected resolvers naming one domain give one rule with the first resolver's servers, then the second's, each once. The 17th resolver in resolver order is dropped as `over_limit`. The 17th distinct domain in resolver order is dropped as `over_limit`. A resolver with nine servers keeps eight and reports the ninth as `over_limit`, and so does a domain whose two resolvers name nine distinct servers between them. `display`: a domain two resolvers name appears once, under the first; a resolver whose every domain an earlier resolver kept has no row; the state is `.inUse` for a non-empty reading under `.reasserting` and `.held` only when an empty reading kept the previous set. Under `.disconnected`, a last reading of 17 resolvers naming 17 distinct domains, one with nine servers, gives an `.idle` display of 16 rows, 16 domains and at most eight servers a row, and adds nothing to `ignored`. A full-tunnel reading (`domains: [corp.example, eu.corp.example]`, `overridesPrimary: true`) yields a rule for each domain and none for public names. With no manual entries, `SplitDNSTable(manual: [], detected: detectedRules).firstServers` are the tunnel's servers while the set is in use and empty while the gate withholds it. A split-tunnel reading yields rules for its supplemental domains only.
- `VPNStateFuserTests` gains `liveInterfaceNames`. It lists the interfaces in `.connected`, `.linkDownDebouncing` and `.linkDownAwaitingRecovery` in name order. With `utun3` and `utun7` connected, removing `utun7` returns `.noChange`, leaves `connectedInterfaceNames.first` at `utun3` and changes `liveInterfaceNames` from `[utun3, utun7]` to `[utun3]`, which is the case the monitor's set comparison exists to catch. With `utun3` connected and `utun7` past its min-visible window, the verdict stays `.connected` and `liveInterfaceNames` keeps `utun7`.
- `PushedResolverMonitorTests`. The parser over the three fixture readings above, with their expected `domains` and `overridesPrimary`. `SupplementalMatchDomains` present wins over `DomainName` and `SearchDomains`; absent with `OverridePrimary` 1, the two are joined in that order and de-duplicated case-insensitively; absent without `OverridePrimary`, the key is rejected as `no_match_domains` and contributes no resolver; an invalid domain among them is returned as a rejection with reason `.invalidDomain` and the rest kept. Also the `InterfaceName` filter, `InterfaceName` read from IPv6 when IPv4 has none, a key with neither rejected as `not_tunnel`, a non-UUID service ID, system domains dropped and an invalid server dropped.
- `AppStateSplitDNSHintTests` (AppState harness). A manual entry duplicating an in-use detected domain shows the hint; an idle detected set shows none; "Remove manual copy" removes the entry from the draft and the editor's normal save persists it; no configuration write comes from the runtime.
- `SplitDNSTableTests` (from PR #298) gains the merge in `init(manual:detected:)`. With `detected` empty, the table equals `init(entries:)` for the same entries, rule for rule, with every origin `.manual`. A shared domain lists the detected servers first with their origins, then the manual servers not already listed, and a server both name counts as detected. Manual rules come before detected-only ones, in configuration order, then in `detected` order. A domain with eight detected servers and two manual ones keeps all ten, the manual ones last. PR #298 already covers longest suffix, per-rule servers, open circuits and the empty table in `SplitDNSTableTests` and `DNSForwarderHealthTests`.
- `DNSForwarderTests`. The forwarder reads the provider, not config: a table pushed with no change to `dnsEntries` routes the next query. A forwarder built without `splitDNSProvider` routes a name under a manual entry to its servers, as today. A public answer cached for `host.corp.example` before a table swap that adds `corp.example` is not served after it: the next query goes to the rule's server. Decision 9's public-name path on a provider table: with only a detected rule in use, a public name gets one attempt on its first server and DoH answers when that server returns NXDOMAIN or no records; the server's answer with records is used and DoH is not asked; with the table empty, the server is never asked and DoH answers at once; an intercept rule and a cached answer still win before the attempt.
- `RuntimeHostSplitDNSTests` (actual host over `FakeMachine`, `FakeVPNStatusObserver`, `FakePushedResolverObserver`). A primed reading plus `.connected` produces one `applyDetectedSplitDNSRules` and one `dns.split_detected outcome=applied`; `.disconnected` pushes no detected rules and leaves the manual ones; the snapshot field follows; a launch on a LAN with manual entries only, the VPN `.disconnected` and nothing pushed resolves a name under a manual entry through its manual servers; with `dns.followVPNResolvers` off the monitor never starts and the same name resolves through the manual servers; `manageDNSResolvers` on writes files for manual entries only. With `utun7`'s resolver held after an empty reading and `utun3` up with no DNS key, `FakeVPNStatusObserver` re-delivers `.connected` with `liveInterfaceNames` going from `[utun3, utun7]` to `[utun3]`; the host pushes `[]` with `applyDetectedSplitDNSRules` and the next name under `utun7`'s domain takes the public path. Two readings with the same rejection emit one `dns.split_resolver_ignored`, and a third reading with a new rejection emits one more.
- `ProxyOrchestratorSplitDNSTests`. pm-proxy's headless path: an orchestrator built from a config with manual entries, started with its forwarder and never sent `applyDetectedSplitDNSRules`, as `PMProxy.swift` runs it, resolves a name under a manual entry through its manual servers. A config change that edits `dnsEntries` rebuilds the merged table and emits `dns.split_table_changed reason=config`, and the detected rules last pushed stay in it. A direct write, `orchestrator.config.dnsEntries = [corp.example → 192.0.2.53]` with no `applyConfigChange`, reaches the running forwarder: the next query for `host.corp.example` goes to `192.0.2.53`.
- `SplitDNSVPNGateTests` and `DNSManagerVPNGatingTests` unchanged, which is the point.

pm-sim, registered in `pm-sim all`:

- `dns-split-follows-vpn`. Fake corp server on loopback answers `host.corp.example`. Off-VPN the forwarder answers from the fake DoH provider and caches. The fake pushed-resolver observer emits `corp.example → loopback server`, the fake VPN observer emits `.connected`: the next answer comes from the corp server, not from the cached public answer. On the VPN a public name, `www.example.com`, is asked of the corp server once, and the fake DoH provider answers it after the corp server returns NXDOMAIN. `.disconnected`: the corp server is never asked again, for either name, and no internal answer was cached across either transition.
- `dns-split-flap-holds`. `.reasserting` with an empty reading keeps answering from the corp server; the grace window expiring to `.disconnected` stops it; `.connected` with the reading back resumes it.

Owner validation, recorded in decision 0044: hotspot with the VPN off (gateway name resolves publicly, with no wait on a detected server), VPN on (corporate names from the pushed servers, Settings shows them in use and shows the duplicate-entry hint on an imported entry), a lost network with the VPN connected (turn Wi-Fi off and on again within the grace window: no `vpn.disconnected.*` event, and Settings shows the set in use or held throughout), a longer loss (leave Wi-Fi off past the grace window: `vpn.disconnected.lost`, and the set turns idle), a user disconnect from the VPN client (`vpn.disconnected.user`, and the set turns idle at once, with no held state, because a user disconnect goes straight to `.disconnected(.userInitiated)` and only a lost network passes through `.reasserting` and the grace window), office LAN (manual entries, files withheld).

## Migration

No file migration. `DomainDNSEntry` is unchanged, the detected set is never persisted, and `dns.followVPNResolvers` decodes as `true` when absent (owner decision 7). Users who imported their entries keep them as manual entries with today's behaviour. The duplicate-entry hint and its "Remove manual copy" button are the migration path; nothing deletes configuration on the user's behalf.

The CHANGELOG entry says that imported entries are now redundant on networks that push the same resolvers and names the Settings hint and its "Remove manual copy" button.

## Owner decisions

All nine are decided (owner, 2026-11-10, [#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774052129)) and recorded in [decision 0044](decisions/0044-split-dns-follows-vpn-pushed-resolvers.md).

1. **Files for detected domains.** The detected set writes no `/etc/resolver` files. The tunnel's own scoped resolver covers them, and the entry-file path is the one prone to the deadlock.
2. **Precedence on a shared domain.** Detected servers come first, then manual servers not already listed, with longest suffix deciding between domains. Manual first would defeat the purpose on the network the user is on.
3. **A per-entry "never resolve publicly" switch.** Deferred, and scoped to manual entries when it comes. Part 1 (PR #298) shipped without it. It does not change the shape here.
4. **Wizard default and duplicate entries.** The wizard shows the detected set and pins it as manual entries only when asked, since pinning produced the hotspot failure. Settings → DNS shows the duplicate-entry hint on a manual entry whose domain the in-use detected set provides, with a one-click "Remove manual copy" that goes through the draft and the normal save. The runtime never writes configuration.
5. **Detection source.** The monitor reads `SCDynamicStore` DNS keys, the public API `VPNStatusMonitor` already uses. It does not use the private `dnsinfo.h` API or poll `scutil`.
6. **Bounds.** The table takes at most 16 detected domains and `DomainResourceLimits.dnsServers` servers per domain, and `dns.split_resolver_ignored reason=over_limit` reports the excess.
7. **The switch and its default.** `dns.followVPNResolvers` turns the feature on and off. It defaults to on and lives in the DNS section. Off means the monitor does not start and the table holds manual entries only.
8. **Parent-domain inference and full-tunnel domains.** The live set infers no parent domains, and existing parent entries stay as manual entries. A DNS key with `SupplementalMatchDomains` contributes only those domains. A key without them whose IPv4 `OverridePrimary` is 1, a full tunnel, contributes its `DomainName` followed by its `SearchDomains`, de-duplicated and checked with `DomainNameSyntax`. A key with neither contributes nothing and is rejected as `no_match_domains`.
9. **Public names.** Revised by the owner on 2026-11-10 ([#295 comment](https://github.com/srps/Conduit/pull/295#issuecomment-6774517730)). The first answer kept public names on DoH "as today", but today a public name already makes one attempt on the first split-DNS server before DoH, so that premise was wrong. Public names keep today's single path: an intercept rule and a cached answer first, then one 1.5 s attempt on `firstServers`, whether manual or detected, then DoH unless that server answers with records. There is no DoH-only switch for now. The reading records `OverridePrimary` as `overridesPrimary` because decision 8's full-tunnel domain rule needs it, and only that rule branches on it.

## Sequencing

Five verifiable units, each green on its own, in this order. Unit 1 is delivered.

1. **Kernel table. Delivered by PR #298 (ab2ffe32).** `SplitDNSTable` built from `config.dnsEntries` per query, per-rule servers in order, longest suffix, per-server circuits, the internal stage budget, and no internal attempt when no rule has a server, which removed the `192.0.2.53` wait (#296). The design's shape differs from what shipped in two ways that the later units close: rules carry no `origins`, and the forwarder builds the table from config instead of reading a box.
2. **Platform inputs.** `PushedResolver`, `PushedResolverObserving`, `PushedResolverMonitor`, the fake, `LiveSplitDNSPolicy`, the monitor's re-delivery on a live-set change. In the kernel, `VPNStatusObserving.liveInterfaceNames`, `VPNStateFuser.liveInterfaceNames`, `DetectedSplitDNSDisplay`, `SplitDNSOrigin`, `SplitDNSRule.origins` and `SplitDNSTable.init(manual:detected:)`, which owns the merge; `init(entries:)` callers move to it and `init(entries:)` is deleted. Pure tests and the parser fixture from the owner's VPN.
3. **Host wiring.** `RuntimeHostEffects.pushedResolvers`, the policy in `RuntimeHost`, `applyDetectedSplitDNSRules(_:display:reason:)` and `DetectedSplitDNSChangeReason`, the four events, the two pm-sim scenarios, `events.md`. The snapshot field: `ProxyOrchestratorSnapshot.detectedSplitDNS` in the kernel, `ControlDetectedSplitDNS` and its rows in `ConduitShared` with their `ControlRuntimeSizing` measures and `ControlDisplayRecordCodec` caps, and the projection in `ProxyControlBridge`. In the kernel, `splitDNSBox` with the merged table rebuilt at init, in the `config` setter and in `applyDetectedSplitDNSRules`, and the forwarder's optional `splitDNSProvider`, which replaces `SplitDNSTable(entries: config.dnsEntries)`. `enabledDNSEntryDomain(containing:config:)` and `isInternalDomain(_:config:)` are deleted.
4. **App.** Settings groups, the duplicate-entry hint, wizard, `VPNDNSDetector` deleted, compositions supply the observer.
5. **Validation.** The owner validation above, recorded in decision 0044, which moves its statuses as each unit lands. The record itself lands with this design, and 0043's open question on the first server already points to #290 part 1 and to 0044.
