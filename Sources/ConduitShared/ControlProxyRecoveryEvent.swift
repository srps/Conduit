// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The control wire's `proxy_recovery.*` values (decision 0013). They mirror the domain layout in `RuntimeEvents` without importing
/// it, so `ProxyControlBridge` maps the domain values onto these types exhaustively. The only field is a closed Boolean, and the
/// derived `name` and `detail` match the domain's byte for byte, because the outer record must agree.
package enum ControlProxyRecoveryEvent: Codable, Sendable, Equatable {
    case recovered
    case failed(authenticationLikely: Bool)

    private enum WireType: String, Codable, CaseIterable {
        case recovered
        case failed
    }

    /// The stable event names, spelled once here. The domain's `ProxyRecoveryEventName` pins the same two.
    private enum EventName: String, CaseIterable {
        case recovered = "proxy_recovery.recovered"
        case failed = "proxy_recovery.failed"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case authenticationLikely = "authentication_likely"
    }

    /// The `type` spellings this build decodes. The record classifier reads this set, so it cannot drift.
    package static let knownWireTypes: Set<String> = Set(WireType.allCases.map(\.rawValue))

    /// The event names this build emits and decodes. The record classifier reads this set, so it cannot drift.
    package static let knownEventNames: Set<String> = Set(EventName.allCases.map(\.rawValue))

    /// The stable event name, the same spelling the domain derives.
    package var name: String {
        switch self {
        case .recovered: EventName.recovered.rawValue
        case .failed: EventName.failed.rawValue
        }
    }

    /// The human detail, byte for byte what the domain derives.
    package var detail: String {
        switch self {
        case .recovered: "outcome=recovered"
        case .failed(let authenticationLikely): "outcome=failed authentication_likely=\(authenticationLikely)"
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .recovered:
            guard !container.contains(.authenticationLikely) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .authenticationLikely, in: container, debugDescription: "a recovery carries no authentication verdict"
                )
            }
            self = .recovered
        case .failed:
            self = .failed(authenticationLikely: try container.decode(Bool.self, forKey: .authenticationLikely))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recovered:
            try container.encode(WireType.recovered, forKey: .type)
        case .failed(let authenticationLikely):
            try container.encode(WireType.failed, forKey: .type)
            try container.encode(authenticationLikely, forKey: .authenticationLikely)
        }
    }
}
