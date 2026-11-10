// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// Ceilings on the detected split-DNS set (owner decision 6).
package struct SplitDNSLimits: Hashable, Sendable {
    package static let standard = SplitDNSLimits(
        maxDetectedResolvers: 16,
        maxDetectedDomains: 16,
        maxServersPerDomain: DomainResourceLimits.dnsServers
    )

    /// Also the Settings display's row cap.
    package var maxDetectedResolvers: Int
    package var maxDetectedDomains: Int
    /// Caps each resolver's servers and each detected domain's list.
    package var maxServersPerDomain: Int

    package init(maxDetectedResolvers: Int, maxDetectedDomains: Int, maxServersPerDomain: Int) {
        self.maxDetectedResolvers = maxDetectedResolvers
        self.maxDetectedDomains = maxDetectedDomains
        self.maxServersPerDomain = maxServersPerDomain
    }
}

/// Which pushed resolvers are in use right now, as a pure function of the
/// `SplitDNSVPNGate` verdict, the connected tunnels and the last store
/// reading, and the detected rules and Settings display that follow from
/// them. The kernel merges the rules with the manual entries
/// (`SplitDNSTable(manual:detected:)`). Sibling of `SplitDNSVPNGate`; see
/// `docs/design-live-vpn-split-dns.md`.
package struct LiveSplitDNSPolicy: Hashable, Sendable {
    package let limits: SplitDNSLimits

    /// The last reading `update` was given, whatever the gate said. A host
    /// that gets a verdict with no new reading passes this back in.
    package private(set) var lastReading = PushedResolverReading()

    /// The last non-empty reading in use since the last `.disconnected`, the
    /// only verdict that clears it whole. Tunnel clients withdraw and
    /// republish their DNS key inside a flap, and a flap must change nothing a
    /// client can see, whichever observer reports first. Under `.connected`
    /// an empty reading drops the resolvers whose tunnel is no longer live,
    /// so a second tunnel staying up does not keep the first one's servers
    /// in use. `.reasserting` and `.unknown` do not filter: the grace window
    /// bounds the first, and under the second no tunnel is admitted yet.
    private var heldThroughFlap: [PushedResolver] = []

    /// `[]` while the gate withholds (`.disconnected`); the held set otherwise,
    /// in resolver order: `searchOrder` ascending, missing last, then `serviceID`.
    package private(set) var detectedInUse: [PushedResolver] = []

    /// `detectedInUse` as rules: one per domain in resolver order, capped,
    /// every origin `.detected(interface:)`. `[]` while the gate withholds.
    package private(set) var detectedRules: [SplitDNSRule] = []

    /// `detectedInUse` with its state, or the last reading as `.idle` while
    /// the gate withholds. Idle rows take the same order and caps and add
    /// nothing to `ignored`, because that set is unused.
    package private(set) var display = DetectedSplitDNSDisplay.none

    /// The last reading's rejections plus every `over_limit` cut from
    /// `detectedInUse`. The host reports the members that were not in the
    /// set before an update.
    package private(set) var ignored: Set<PushedResolverRejection> = []

    package init(limits: SplitDNSLimits) {
        self.limits = limits
    }

    /// Records the inputs. `liveInterfaces` is the VPN observer's
    /// `liveInterfaceNames`, read with the verdict the gate last recorded.
    /// Returns whether `detectedRules` or `display` changed, so a repeated
    /// input returns false.
    package mutating func update(
        gate: SplitDNSVPNGate,
        liveInterfaces: Set<String>,
        reading: PushedResolverReading
    ) -> Bool {
        let before = (detectedRules, display)
        lastReading = reading
        let fresh = Self.resolverOrder(reading.resolvers)
        switch gate.lastVPNState {
        case .disconnected:
            heldThroughFlap = []
        case .connected where fresh.isEmpty:
            heldThroughFlap.removeAll { !liveInterfaces.contains($0.interface) }
        case .connected, .reasserting, .unknown:
            if !fresh.isEmpty { heldThroughFlap = fresh }
        }

        let withheld = !gate.entriesWanted
        detectedInUse = withheld ? [] : heldThroughFlap
        let bounded = Self.bound(detectedInUse, limits)
        detectedRules = bounded.rules
        ignored = Set(reading.rejections).union(bounded.excess)
        if withheld {
            display = DetectedSplitDNSDisplay(state: .idle, rows: Self.bound(fresh, limits).rows)
        } else {
            let held = fresh.isEmpty && !detectedInUse.isEmpty
            display = DetectedSplitDNSDisplay(state: held ? .held : .inUse, rows: bounded.rows)
        }
        return (detectedRules, display) != before
    }

    private static func resolverOrder(_ resolvers: [PushedResolver]) -> [PushedResolver] {
        resolvers.sorted { ($0.searchOrder ?? .max, $0.serviceID) < ($1.searchOrder ?? .max, $1.serviceID) }
    }

    /// The first `maxDetectedResolvers` resolvers, each with its first
    /// `maxServersPerDomain` servers, and the first `maxDetectedDomains`
    /// distinct domains, each with at most `maxServersPerDomain` servers.
    /// Two resolvers naming one domain share its rule, the first's servers
    /// first, each once. Every cut is an `over_limit` rejection.
    private static func bound(
        _ resolvers: [PushedResolver],
        _ limits: SplitDNSLimits
    ) -> (rules: [SplitDNSRule], rows: [DetectedSplitDNSDisplay.Row], excess: [PushedResolverRejection]) {
        var order: [String] = []
        var servers: [String: [(server: String, origin: SplitDNSOrigin)]] = [:]
        var rows: [DetectedSplitDNSDisplay.Row] = []
        var excess: [PushedResolverRejection] = []
        for (index, resolver) in resolvers.enumerated() {
            func cut(_ value: String?) {
                excess.append(.init(
                    serviceID: resolver.serviceID, interface: resolver.interface, value: value, reason: .overLimit
                ))
            }
            guard index < limits.maxDetectedResolvers else {
                cut(nil)
                continue
            }
            let kept = Array(resolver.servers.prefix(limits.maxServersPerDomain))
            resolver.servers.dropFirst(limits.maxServersPerDomain).forEach { cut($0) }
            var rowDomains: [String] = []
            for domain in resolver.domains {
                if servers[domain] == nil {
                    guard order.count < limits.maxDetectedDomains else {
                        cut(domain)
                        continue
                    }
                    order.append(domain)
                    servers[domain] = []
                    rowDomains.append(domain)
                }
                for server in kept where !(servers[domain] ?? []).contains(where: { $0.server == server }) {
                    guard (servers[domain] ?? []).count < limits.maxServersPerDomain else {
                        cut(server)
                        continue
                    }
                    servers[domain, default: []].append((server, .detected(interface: resolver.interface)))
                }
            }
            if !rowDomains.isEmpty {
                rows.append(.init(interface: resolver.interface, domains: rowDomains, servers: kept))
            }
        }
        let rules = order.map { domain in
            let list = servers[domain] ?? []
            return SplitDNSRule(domain: domain, servers: list.map(\.server), origins: list.map(\.origin))
        }
        return (rules, rows, excess)
    }
}
