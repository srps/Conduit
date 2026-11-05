// SPDX-License-Identifier: Apache-2.0

/// Who left the exchange unanswered. A health check asks the liveness probe at its first silence; the data path
/// waits for `UpstreamSilences.probeAfter` in a row. A health check's fresh retry follows a probe that answered,
/// so it never asks again.
package enum SilenceSource: Equatable, Sendable { case exchange, healthCheck, healthCheckRetry }

/// The silences one upstream left since its last answered exchange.
///
/// Slowness is per origin; egress death is across origins. One slow origin
/// never produces silences on two distinct origins, so two distinct silent
/// origins (`host:port`) with no exchange answered in between are the verdict
/// that the upstream forwards nothing, whether or not it answers the liveness
/// probe for itself. Two silences in a row, or one after a conclusive failure,
/// only ask the probe.
package struct UpstreamSilences: Equatable, Sendable {
    package static let probeAfter = 2
    package static let decisiveOrigins = 2

    package private(set) var consecutive = 0
    package private(set) var failureStanding = false
    package private(set) var origins: [ExchangeOrigin] = []

    package struct Record: Equatable, Sendable {
        package let consecutive: Int
        package let origins: Int
        package let asksProbe: Bool
        package var acrossOrigins: Bool { origins >= UpstreamSilences.decisiveOrigins }
    }

    package init() {}

    /// A nil `origin` counts toward the probe trigger and names no origin.
    package mutating func recordUnanswered(origin: ExchangeOrigin?, source: SilenceSource) -> Record {
        consecutive += 1
        if let origin, !origins.contains(origin), origins.count < Self.decisiveOrigins { origins.append(origin) }
        let asksProbe = source != .healthCheckRetry && (source == .healthCheck || consecutive >= Self.probeAfter || failureStanding)
        return Record(consecutive: consecutive, origins: origins.count, asksProbe: asksProbe)
    }

    /// A conclusive failure says nothing about which origins answer, so the ledger stays.
    package mutating func recordFailure() {
        consecutive = 0
        failureStanding = true
    }

    package mutating func recordAnswer() {
        consecutive = 0
        failureStanding = false
        origins = []
    }

    /// The proxy answered for itself, which proves nothing about its egress: the ledger stays.
    package mutating func recordProbeAnswer() {
        consecutive = 0
        failureStanding = false
    }

    package mutating func reset() { recordAnswer() }
}
