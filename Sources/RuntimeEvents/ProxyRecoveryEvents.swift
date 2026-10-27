// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The typed `proxy_recovery.*` events (decision 0013): the outcome of one admitted recovery ladder, recorded by the kernel at the
/// two sites where that outcome decides the runtime state. A ladder that a VPN transition, Start or Stop superseded records neither, and
/// neither does an exhausted ladder whose follow-up probe hands the state to direct mode or finds an upstream reachable again. The only
/// field is a closed Boolean, so an endpoint, a health summary or an error text has nowhere to go.
///
/// The kernel's `RuntimeEvent(payload:)` derives the name, the `health` kind and the detail from these values. The wire mirror
/// (`ConduitShared`) is a separate closed set that `ProxyControlBridge` maps onto exhaustively.

/// The names the typed family emits.
package enum ProxyRecoveryEventName: String, Sendable, CaseIterable {
    case recovered = "proxy_recovery.recovered"
    case failed = "proxy_recovery.failed"
}

package enum ProxyRecoveryEvent: Equatable, Sendable {
    /// `proxy_recovery.recovered`: a ladder step's health check passed, so the runtime is running again.
    case recovered
    /// `proxy_recovery.failed`: the ladder ran out, and its follow-up probe found no reachable upstream while routing stayed on the
    /// upstream path, so the runtime failed. `authenticationLikely` is the kernel's verdict that the last health failure was an
    /// authentication rejection.
    case failed(authenticationLikely: Bool)

    /// The stable event name.
    package var name: String {
        switch self {
        case .recovered: ProxyRecoveryEventName.recovered.rawValue
        case .failed: ProxyRecoveryEventName.failed.rawValue
        }
    }

    /// The human detail, derived from the typed fields only.
    package var detail: String {
        switch self {
        case .recovered: "outcome=recovered"
        case .failed(let authenticationLikely): "outcome=failed authentication_likely=\(authenticationLikely)"
        }
    }
}

/// Wire layout: `{"type": "recovered"}` or `{"type": "failed", "authentication_likely": …}`. An unknown type, a failure without its
/// Boolean, or a recovery that carries one throws rather than becoming some other value.
extension ProxyRecoveryEvent: Codable {
    private enum WireType: String, Codable {
        case recovered
        case failed
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case authenticationLikely = "authentication_likely"
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
