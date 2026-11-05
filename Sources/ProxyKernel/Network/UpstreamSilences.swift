// SPDX-License-Identifier: Apache-2.0

/// The origins one upstream has left unanswered since it last answered anything.
///
/// Slowness is per origin; a proxy that forwards nothing is silent across origins. One slow origin never
/// produces silences on two distinct origins, so a silence counts against the upstream only once the ledger
/// holds `decisiveOrigins` distinct origins with no answer in between. An answer from any origin empties it.
package struct UpstreamSilences: Equatable, Sendable {
    /// The distinct origins that make a silence count, and the most the ledger ever holds.
    package static let decisiveOrigins = 2

    package private(set) var origins: [ExchangeOrigin] = []

    package init() {}

    /// Whether this silence counts against the upstream.
    package mutating func recordSilence(origin: ExchangeOrigin) -> Bool {
        if !origins.contains(origin), origins.count < Self.decisiveOrigins { origins.append(origin) }
        return origins.count >= Self.decisiveOrigins
    }

    package mutating func recordAnswer() { origins = [] }
}
