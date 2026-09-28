// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One network-path report as plain values. `NetworkMonitor` (PlatformMac)
/// maps each `NWPath` into this, so the fingerprint and the diff below can be
/// tested without `Network`, which cannot construct an `NWPath`.
///
/// `NWPathMonitor` reports updates in which nothing the proxy depends on has
/// moved (#101: a pair every ~75 s for hours, with the VPN off). Only the
/// `materialFields` decide whether the orchestrator resets DNS transports and
/// refetches PAC. `isExpensive` and `isConstrained` are carried for the log
/// line but are not material: they are cost hints (hotspot, Low Data Mode)
/// that change no route, resolver or gateway, and a switch to a hotspot that
/// does change the route also changes the interfaces and gateways.
package struct NetworkPathState: Sendable, Equatable {
    package enum Status: String, Sendable, Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection = "requires_connection"
    }

    package struct Interface: Sendable, Equatable {
        package let name: String
        /// `wifi`, `wired`, `cellular`, `loopback` or `other` (a VPN's utun).
        package let type: String

        package init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// The fields whose change drives a reset. Raw values are the
    /// `changed=` tokens of `network.path_changed`, and each is also the key
    /// of that field's `old->new` token, so none may collide with the event's
    /// other keys (`satisfied`, `dns`, `pac`, `path`).
    package enum Field: String, Sendable, Equatable, CaseIterable {
        case status
        case interfaces
        case gateways
        case supportsIPv4 = "supports_ipv4"
        case supportsIPv6 = "supports_ipv6"
        case supportsDNS = "supports_dns"
    }

    package let status: Status
    /// Sorted by name, then type. `availableInterfaces` order is not a
    /// documented route preference, so the same set in another order is not
    /// a change, and the set renders the same way for the `old->new` tokens.
    package let interfaces: [Interface]
    /// Sorted, so a report that lists the same gateways in another order is
    /// not a change.
    package let gateways: [String]
    package let supportsIPv4: Bool
    package let supportsIPv6: Bool
    package let supportsDNS: Bool
    package let isExpensive: Bool
    package let isConstrained: Bool

    package init(
        status: Status,
        interfaces: [Interface],
        gateways: [String],
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        supportsDNS: Bool,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.status = status
        self.interfaces = interfaces.sorted { ($0.name, $0.type) < ($1.name, $1.type) }
        self.gateways = gateways.sorted()
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    package var satisfied: Bool { status == .satisfied }

    /// The material fields that differ from `previous`, in `Field` order.
    /// Empty means the update changes nothing the proxy acts on.
    package func changedFields(from previous: NetworkPathState) -> [Field] {
        Field.allCases.filter { render($0) != previous.render($0) }
    }

    /// One field's value with no spaces, so it can sit in a `key=value`
    /// event token.
    package func render(_ field: Field) -> String {
        switch field {
        case .status:
            return status.rawValue
        case .interfaces:
            return interfaces.isEmpty ? "none" : interfaces.map { "\($0.name)/\($0.type)" }.joined(separator: ",")
        case .gateways:
            return gateways.isEmpty ? "none" : gateways.joined(separator: ",")
        case .supportsIPv4:
            return String(supportsIPv4)
        case .supportsIPv6:
            return String(supportsIPv6)
        case .supportsDNS:
            return String(supportsDNS)
        }
    }

    /// Every field, for the `path=` token and the log line. It holds no `=`,
    /// so a token parser never mistakes it for another key.
    package var description: String {
        let supported = [
            supportsIPv4 ? "ipv4" : nil,
            supportsIPv6 ? "ipv6" : nil,
            supportsDNS ? "dns" : nil,
        ].compactMap { $0 }
        var parts = [
            status.rawValue,
            "interfaces \(render(.interfaces))",
            "gateways \(render(.gateways))",
            "supports \(supported.isEmpty ? "none" : supported.joined(separator: ","))",
        ]
        if isExpensive { parts.append("expensive") }
        if isConstrained { parts.append("constrained") }
        return parts.joined(separator: "; ")
    }
}

/// A path update that differs materially from the last one acted on, and
/// so drives the DNS transport reset, the PAC refresh and the DNS reconcile.
package struct NetworkPathChange: Sendable, Equatable {
    package let path: NetworkPathState
    /// `nil` for the first path the runtime sees.
    package let previous: NetworkPathState?
    /// Empty only when `previous` is `nil`.
    package let changedFields: [NetworkPathState.Field]
    /// Updates that changed nothing material since the last change.
    package let unchangedBefore: Int

    /// `changed=` token value: the field names, or `initial`.
    package var changedToken: String {
        changedFields.isEmpty ? "initial" : changedFields.map(\.rawValue).joined(separator: ",")
    }

    /// One `field=old->new` token per changed field, space-separated.
    package var diffTokens: [String] {
        guard let previous else { return [] }
        return changedFields.map { "\($0.rawValue)=\(previous.render($0))->\(path.render($0))" }
    }
}

/// Decides, per path update, whether anything material changed since the
/// last update that was acted on, and counts the ones that did not.
///
/// State is one path and one counter, whatever the update rate. The unchanged
/// updates are reported for emission at counts 1, 2, 4 … `steadyStateInterval`
/// and then every `steadyStateInterval`, so a network that churns all day
/// produces a handful of events rather than one per update, while each event
/// still carries the running count.
package struct NetworkPathTracker: Sendable {
    package enum Decision: Sendable, Equatable {
        case changed(NetworkPathChange)
        /// `count` unchanged updates since the last change; `emit` says
        /// whether this one is due a `network.path_unchanged` event.
        case unchanged(count: Int, emit: Bool)
    }

    package static let steadyStateInterval = 64

    package private(set) var current: NetworkPathState?
    private var unchangedCount = 0

    package init() {}

    package mutating func admit(_ path: NetworkPathState) -> Decision {
        guard let previous = current else {
            current = path
            return .changed(NetworkPathChange(path: path, previous: nil, changedFields: [], unchangedBefore: 0))
        }
        let fields = path.changedFields(from: previous)
        guard fields.isEmpty else {
            let before = unchangedCount
            current = path
            unchangedCount = 0
            return .changed(NetworkPathChange(path: path, previous: previous, changedFields: fields, unchangedBefore: before))
        }
        // The non-material fields (`isExpensive`, `isConstrained`) follow the
        // newest report, so the next log line describes the path as it is.
        current = path
        unchangedCount += 1
        return .unchanged(count: unchangedCount, emit: Self.isDue(unchangedCount))
    }

    private static func isDue(_ count: Int) -> Bool {
        if count >= steadyStateInterval { return count % steadyStateInterval == 0 }
        return count & (count - 1) == 0
    }
}
