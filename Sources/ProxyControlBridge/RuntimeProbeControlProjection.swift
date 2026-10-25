// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

/// Maps one upstream probe onto the v2 `test-upstream` result (decision 0029). It is the one v2 probe producer, and it applies the same
/// display policy as the snapshot and the rows. It is not adopted: no owner adapter answers `test-upstream` on the v2 wire yet, so nothing
/// in the host calls this mapping. The legacy v1 mapping, `ControlUpstreamTestResult(ProbeResult)`, is unchanged.
package enum RuntimeProbeControlProjection {
    package static func upstreamProbe(_ result: ProbeResult) throws -> ControlUpstreamProbe {
        var notices = ControlDisplayNoticeSink(owner: .upstreamProbe)
        let name = notices.text(result.proxy.name, .probeName)
        let endpoint = notices.text(result.proxy.endpoint, .probeEndpoint)
        return ControlUpstreamProbe(
            upstreamID: ControlUpstreamID(rawValue: result.proxy.id),
            name: name,
            endpoint: endpoint,
            reachable: result.reachable,
            latencyMilliseconds: try ControlCount(result.latencyMS),
            displayNotices: notices.canonicalNotices
        )
    }
}
