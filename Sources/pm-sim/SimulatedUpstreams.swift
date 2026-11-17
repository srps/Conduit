// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// The upstream probe the actual-host scenarios inject (decision 0033). Their configured upstream, 127.0.0.1:9, is no
/// listener a scenario owns, so none dials it; the probe answers as a refused connection would.
enum SimulatedUpstreams {
    @Sendable static func unreachable(_ upstreams: [UpstreamProxy]) async -> UpstreamProbeSummary {
        UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: false) })
    }
}
