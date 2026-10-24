// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

/// Projects kernel snapshot values onto the v2 control values. Each mapping is an
/// exhaustive switch, so a new kernel case fails to compile here until its wire
/// spelling is chosen. Free text is sanitized before it leaves the process, and a
/// URL loses its query and fragment.
///
/// The scalar snapshot is a read model of one orchestrator value. It is not the
/// configuration: no `ProxyConfig` value reaches it, so no URL in the configuration
/// can appear in its output.
package enum RuntimeSnapshotControlProjection {
    /// The scalar snapshot for one kernel snapshot. Lists are referenced by the
    /// revisions in `collectionRevisions`, never inlined.
    package static func snapshot(
        _ snapshot: ProxyOrchestratorSnapshot,
        stamp: ControlRuntimeStamp,
        profileName: String,
        collectionRevisions: ControlCollectionRevisions
    ) throws -> ControlRuntimeSnapshot {
        let status = snapshot.runtimeStatus
        return ControlRuntimeSnapshot(
            stamp: stamp,
            profileName: displayText(profileName),
            proxyState: proxyState(status.state),
            activeUpstream: status.activeUpstream.map(displayText),
            healthSummary: displayText(status.lastHealthSummary),
            proxyError: snapshot.proxyError.map(displayText),
            dnsRunState: moduleRunState(snapshot.dnsRunState),
            dnsError: snapshot.dnsError.map(displayText),
            tunnelsRunState: moduleRunState(snapshot.tunnelsRunState),
            tunnelsError: snapshot.tunnelsError.map(displayText),
            directModeCause: directModeCause(snapshot.directModeCause),
            vpnState: vpnState(snapshot.vpnState),
            vpnInterfaceName: snapshot.vpnInterfaceName.map(displayText),
            bindings: try runtimeBindings(snapshot.bindings),
            lastAuthOutcome: snapshot.lastAuthOutcome.map(authOutcome),
            lastAuthOutcomeAt: try snapshot.lastAuthOutcomeAt.map(timestamp),
            lastAuthFallbackReason: snapshot.lastAuthFallbackReason.map(displayText),
            metrics: try runtimeMetrics(status.metrics),
            dnsQueryCount: try ControlCount(snapshot.dnsQueryCount),
            dnsDoHFallbackCount: try ControlCount(snapshot.dnsDoHFallbackCount),
            dnsCacheHitCount: try ControlCount(snapshot.dnsCacheHitCount),
            tunnelActiveCount: try ControlCount(snapshot.tunnelActiveCount),
            tunnelSessionCount: try ControlCount(snapshot.tunnelSessionCount),
            tunnelDNSOverride: try tunnelDNSSummary(
                snapshot.tunnelDNSOverrideStatus,
                revision: collectionRevisions.tunnelDNSHosts
            ),
            vpnFlap: try vpnFlapMetrics(status.metrics),
            collections: try collections(snapshot, revisions: collectionRevisions),
            appliedState: .unavailable(.pendingAppliedStateSlice)
        )
    }

    // MARK: - Pages

    /// One page of connections, in the projection's stable order: newest first, then ID.
    /// The page names the host incarnation and answers the request's correlation.
    package static func connectionPage(
        _ connections: [ActiveConnectionInfo],
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        offset: Int,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        try ControlPagePacker.page(
            of: connectionRows(connections),
            offset: offset,
            incarnation: incarnation,
            revision: revision,
            correlation: correlation,
            limits: limits,
            wrap: ControlPageReply.activeConnections
        )
    }

    /// One page of upstream health rows.
    package static func upstreamPage(
        _ statuses: [UpstreamRuntimeStatus],
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        offset: Int,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        try ControlPagePacker.page(
            of: upstreamRows(statuses),
            offset: offset,
            incarnation: incarnation,
            revision: revision,
            correlation: correlation,
            limits: limits,
            wrap: ControlPageReply.upstreamHealth
        )
    }

    /// One page of tunnel binding rows.
    package static func tunnelBindingPage(
        _ bindings: [TunnelBindingInfo],
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        offset: Int,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        try ControlPagePacker.page(
            of: tunnelBindingRows(bindings),
            offset: offset,
            incarnation: incarnation,
            revision: revision,
            correlation: correlation,
            limits: limits,
            wrap: ControlPageReply.tunnelBindings
        )
    }

    /// One page of tunnel DNS override hosts.
    package static func tunnelDNSHostPage(
        _ status: TunnelDNSOverrideStatus,
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        offset: Int,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        try ControlPagePacker.page(
            of: tunnelDNSHostRows(status),
            offset: offset,
            incarnation: incarnation,
            revision: revision,
            correlation: correlation,
            limits: limits,
            wrap: ControlPageReply.tunnelDNSHosts
        )
    }

    /// Connection rows in the projection's stable order: newest start first, then ID.
    package static func connectionRows(_ connections: [ActiveConnectionInfo]) throws -> [ControlConnectionRow] {
        let ordered = connections.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return try ordered.map { connection in
            ControlConnectionRow(
                id: ControlConnectionID(rawValue: connection.id),
                destination: displayText(connection.destination),
                upstream: displayText(connection.upstream),
                method: displayText(connection.method),
                startedAt: try timestamp(connection.startedAt),
                lastActivityAt: try timestamp(connection.lastActivityAt),
                bytesSent: try ControlCount(connection.bytesSent),
                bytesReceived: try ControlCount(connection.bytesReceived),
                tunnel: connection.tunnel,
                authMethod: connection.authMethod.map(displayText)
            )
        }
    }

    package static func upstreamRows(_ statuses: [UpstreamRuntimeStatus]) throws -> [ControlUpstreamRow] {
        try statuses.map { status in
            ControlUpstreamRow(
                id: ControlUpstreamID(rawValue: status.id),
                name: displayText(status.name),
                endpoint: displayText(status.endpoint),
                circuitState: circuitState(status.circuitState),
                ewmaLatencyMilliseconds: try status.ewmaLatencyMS.map { try ControlNonNegativeNumber($0) },
                consecutiveFailures: try ControlCount(status.consecutiveFailures),
                openUntil: try status.openUntil.map(timestamp)
            )
        }
    }

    package static func tunnelBindingRows(_ bindings: [TunnelBindingInfo]) throws -> [ControlTunnelBindingRow] {
        try bindings.map { binding in
            ControlTunnelBindingRow(
                id: ControlTunnelID(rawValue: binding.id),
                label: displayText(binding.label),
                localHost: displayText(binding.localHost),
                localPort: try ControlPort(binding.localPort),
                remoteHost: displayText(binding.remoteHost),
                remotePort: try ControlPort(binding.remotePort),
                proxied: binding.proxied,
                healthy: binding.healthy
            )
        }
    }

    /// Successful hosts first, then failed ones, each in the kernel's order.
    package static func tunnelDNSHostRows(_ status: TunnelDNSOverrideStatus) -> [ControlTunnelDNSHostRow] {
        switch status {
        case .active(let hostnames):
            return hostnames.map { ControlTunnelDNSHostRow(hostname: displayText($0), outcome: .active) }
        case .partial(let succeeded, let failed):
            return succeeded.map { ControlTunnelDNSHostRow(hostname: displayText($0), outcome: .succeeded) }
                + failed.map { ControlTunnelDNSHostRow(hostname: displayText($0), outcome: .failed) }
        case .unavailable, .notNeeded:
            return []
        }
    }

    // MARK: - Scalars

    package static func runtimeBindings(_ bindings: ProxyOrchestratorBindings) throws -> ControlRuntimeBindings {
        ControlRuntimeBindings(
            proxy: try endpoint(host: bindings.proxyHost, port: bindings.proxyPort),
            socks: try endpoint(host: bindings.socksHost, port: bindings.socksPort),
            localPAC: try endpoint(host: bindings.localPACHost, port: bindings.localPACPort),
            dns: try endpoint(host: bindings.dnsHost, port: bindings.dnsPort),
            transparentProxy: try endpoint(host: bindings.transparentProxyHost, port: bindings.transparentProxyPort)
        )
    }

    /// A binding with neither part set is absent. One set part is kept as it is.
    private static func endpoint(host: String?, port: Int?) throws -> ControlEndpoint? {
        guard host != nil || port != nil else { return nil }
        return ControlEndpoint(
            host: host.map(displayText),
            port: try port.map { try ControlPort($0) }
        )
    }

    private static func runtimeMetrics(_ metrics: ProxyMetrics) throws -> ControlRuntimeMetrics {
        ControlRuntimeMetrics(
            requestsHandled: try ControlCount(metrics.requestsHandled),
            failedRequests: try ControlCount(metrics.failedRequests),
            successfulRecoveries: try ControlCount(metrics.successfulRecoveries),
            openConnections: try ControlCount(metrics.openConnections),
            inboundConnections: try ControlCount(metrics.inboundConnections),
            uptimeStartedAt: try metrics.uptimeStartedAt.map(timestamp),
            lastFailure: try metrics.lastFailure.map(timestamp)
        )
    }

    private static func vpnFlapMetrics(_ metrics: ProxyMetrics) throws -> ControlVPNFlapMetrics {
        ControlVPNFlapMetrics(
            count: try ControlCount(metrics.vpnFlapCount),
            totalDurationSeconds: try ControlNonNegativeNumber(metrics.vpnFlapTotalDuration),
            lastFlapAt: try metrics.lastVpnFlapAt.map(timestamp),
            streamsPreserved: try ControlCount(metrics.streamsPreservedAcrossFlaps)
        )
    }

    private static func tunnelDNSSummary(
        _ status: TunnelDNSOverrideStatus,
        revision: ControlCollectionRevision?
    ) throws -> ControlTunnelDNSSummary {
        let kind: ControlTunnelDNSKind
        let unavailableReason: String?
        switch status {
        case .active:
            kind = .active
            unavailableReason = nil
        case .partial:
            kind = .partial
            unavailableReason = nil
        case .unavailable(let reason):
            kind = .unavailable
            unavailableReason = displayText(reason)
        case .notNeeded:
            kind = .notNeeded
            unavailableReason = nil
        }
        return ControlTunnelDNSSummary(
            kind: kind,
            unavailableReason: unavailableReason,
            hosts: ControlCollectionReference(
                kind: .tunnelDNSHosts,
                totalCount: try ControlCount(tunnelDNSHostRows(status).count),
                state: collectionState(revision)
            )
        )
    }

    private static func collections(
        _ snapshot: ProxyOrchestratorSnapshot,
        revisions: ControlCollectionRevisions
    ) throws -> ControlRuntimeCollections {
        ControlRuntimeCollections(
            activeConnections: ControlCollectionReference(
                kind: .activeConnections,
                totalCount: try ControlCount(snapshot.activeConnections.count),
                state: collectionState(revisions.activeConnections)
            ),
            upstreamHealth: ControlCollectionReference(
                kind: .upstreamHealth,
                totalCount: try ControlCount(snapshot.upstreamStatuses.count),
                state: collectionState(revisions.upstreamHealth)
            ),
            tunnelBindings: ControlCollectionReference(
                kind: .tunnelBindings,
                totalCount: try ControlCount(snapshot.bindings.tunnels.count),
                state: collectionState(revisions.tunnelBindings)
            ),
            tunnelDNSHosts: ControlCollectionReference(
                kind: .tunnelDNSHosts,
                totalCount: try ControlCount(tunnelDNSHostRows(snapshot.tunnelDNSOverrideStatus).count),
                state: collectionState(revisions.tunnelDNSHosts)
            )
        )
    }

    /// A list with no revision reports that as explicit state; its count stays exact.
    private static func collectionState(_ revision: ControlCollectionRevision?) -> ControlCollectionState {
        guard let revision else { return .unavailable(.notCaptured) }
        return .available(revision)
    }

    // MARK: - Enum mappings

    private static func proxyState(_ state: ProxyConnectionState) -> ControlProxyState {
        switch state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .degraded: .degraded
        case .recovering: .recovering
        case .failed: .failed
        }
    }

    private static func moduleRunState(_ state: ModuleRunState) -> ControlModuleRunState {
        switch state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .warning: .warning
        case .failed: .failed
        }
    }

    private static func directModeCause(_ cause: DirectModeCause) -> ControlDirectModeCause {
        switch cause {
        case .none: .none
        case .transientNetworkChange: .transientNetworkChange
        case .vpnDisconnected: .vpnDisconnected
        case .noUpstreamsConfigured: .noUpstreamsConfigured
        case .upstreamsUnreachable: .upstreamsUnreachable
        }
    }

    private static func vpnState(_ state: VPNObservedState) -> ControlVPNState {
        switch state {
        case .unknown: .unknown
        case .connected: .connected
        case .reasserting: .reasserting
        case .disconnected(let reason): .disconnected(vpnDisconnectReason(reason))
        }
    }

    private static func vpnDisconnectReason(_ reason: VPNDisconnectReason) -> ControlVPNDisconnectReason {
        switch reason {
        case .userInitiated: .userInitiated
        case .networkLost: .networkLost
        case .unknown: .unknown
        }
    }

    private static func authOutcome(_ outcome: RuntimeAuthOutcome) -> ControlAuthOutcome {
        switch outcome {
        case .kerberos: .kerberos
        case .ntlmFallback: .ntlmFallback
        case .ntlmDirect: .ntlmDirect
        }
    }

    private static func circuitState(_ state: UpstreamCircuitState) -> ControlCircuitState {
        switch state {
        case .closed: .closed
        case .open: .open
        case .halfOpen: .halfOpen
        }
    }

    // MARK: - Helpers

    private static func timestamp(_ date: Date) throws -> ControlTimestamp {
        try ControlTimestamp(date.timeIntervalSince1970)
    }

    /// Sanitized display text, through the one policy the wire shares (`ControlDisplayText`).
    package static func displayText(_ value: String) -> String {
        ControlDisplayText.sanitize(value)
    }
}
