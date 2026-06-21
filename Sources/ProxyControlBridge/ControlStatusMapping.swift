// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

extension ControlDaemonStatus {
    package init(snapshot: ProxyOrchestratorSnapshot, config: ProxyConfig) {
        let metrics = snapshot.runtimeStatus.metrics
        self.init(
            profileName: config.profileName,
            state: snapshot.runtimeStatus.state.rawValue,
            activeUpstream: snapshot.runtimeStatus.activeUpstream,
            healthSummary: snapshot.runtimeStatus.lastHealthSummary,
            directModeCause: snapshot.directModeCause.rawValue,
            isDirectMode: snapshot.directModeCause.isDirect,
            bindings: ControlBindings(snapshot.bindings),
            metrics: ControlMetrics(metrics),
            dnsRunState: snapshot.dnsRunState.rawValue,
            dnsQueryCount: snapshot.dnsQueryCount,
            dnsCacheHitCount: snapshot.dnsCacheHitCount,
            tunnelsRunState: snapshot.tunnelsRunState.rawValue,
            tunnelActiveCount: snapshot.tunnelActiveCount,
            tunnelSessionCount: snapshot.tunnelSessionCount,
            lastAuthOutcome: snapshot.lastAuthOutcome?.rawValue,
            lastAuthFallbackReason: snapshot.lastAuthFallbackReason
        )
    }
}

extension ControlBindings {
    package init(_ bindings: ProxyOrchestratorBindings) {
        self.init(
            proxyHost: bindings.proxyHost,
            proxyPort: bindings.proxyPort,
            socksHost: bindings.socksHost,
            socksPort: bindings.socksPort,
            localPACHost: bindings.localPACHost,
            localPACPort: bindings.localPACPort,
            dnsHost: bindings.dnsHost,
            dnsPort: bindings.dnsPort
        )
    }
}

extension ControlMetrics {
    package init(_ metrics: ProxyMetrics) {
        self.init(
            requestsHandled: metrics.requestsHandled,
            failedRequests: metrics.failedRequests,
            openConnections: metrics.openConnections,
            inboundConnections: metrics.inboundConnections,
            successfulRecoveries: metrics.successfulRecoveries
        )
    }
}

extension ControlUpstreamTestResult {
    package init(_ result: ProbeResult) {
        self.init(
            name: result.proxy.name,
            endpoint: result.proxy.endpoint,
            reachable: result.reachable,
            latencyMS: result.latencyMS
        )
    }
}
