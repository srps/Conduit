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
/// configuration: it never serializes a `ProxyConfig`. Runtime diagnostics may
/// contain configuration-derived URLs; their query and fragment are redacted too.
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

    // MARK: - Rows

    /// The one bounded projection of a collection's rows, read from one kernel snapshot in one owner turn. The exact count is checked
    /// before any row is mapped, so a collection past the row bound is refused without being copied or built. The rows that remain are
    /// then measured through `budget`, which stops at the first row past either bound. Every answer is closed: rows, over budget, or an
    /// internal failure. The production owner adapter and the tests both call this, so no second projection path exists.
    package static func projectRows(
        _ kind: ControlCollectionKind,
        from snapshot: ProxyOrchestratorSnapshot,
        within budget: ControlRowBudget
    ) -> ControlProjection {
        switch kind {
        case .activeConnections:
            let connections = snapshot.activeConnections
            guard connections.count <= budget.maxRows else { return .overBudget }
            return answer(budget.measure(orderedConnections(connections.ordered), connectionRow)) { .activeConnections($0) }
        case .upstreamHealth:
            guard snapshot.upstreamStatuses.count <= budget.maxRows else { return .overBudget }
            return answer(budget.measure(snapshot.upstreamStatuses, upstreamRow)) { .upstreamHealth($0) }
        case .tunnelBindings:
            guard snapshot.bindings.tunnels.count <= budget.maxRows else { return .overBudget }
            return answer(budget.measure(snapshot.bindings.tunnels, tunnelBindingRow)) { .tunnelBindings($0) }
        case .tunnelDNSHosts:
            return projectDNSHosts(snapshot.tunnelDNSOverrideStatus, within: budget)
        }
    }

    /// Connection rows in the projection's stable order: newest start first, then ID. Sorting copies the array, so it runs only
    /// after the count has passed the bound.
    private static func orderedConnections(_ connections: [ActiveConnectionInfo]) -> [ActiveConnectionInfo] {
        connections.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The hosts in row order, with the count taken from the same view, so the count the snapshot references and the rows cannot disagree.
    private static func projectDNSHosts(_ status: TunnelDNSOverrideStatus, within budget: ControlRowBudget) -> ControlProjection {
        let source = TunnelDNSHostSource(status)
        guard let count = source.count else { return .internalFailure }
        guard count <= budget.maxRows else { return .overBudget }
        return answer(budget.measure(source.hosts, { dnsHostRow($0.hostname, $0.outcome) })) { .tunnelDNSHosts($0) }
    }

    /// The number of hosts the override reports, which is the count the snapshot references. The sum is checked, so an overflowing
    /// count is an invariant failure and never a wrapped total.
    package static func tunnelDNSHostCount(_ status: TunnelDNSOverrideStatus) throws -> Int {
        guard let count = TunnelDNSHostSource(status).count else { throw ControlRuntimeWireError.invalidValue }
        return count
    }

    private static func answer<Row: ControlCollectionRow>(
        _ measured: ControlRowsMeasure<Row>,
        _ wrap: ([Row]) -> ControlProjectedRows
    ) -> ControlProjection {
        switch measured {
        case .complete(let rows, let bytes): .rows(wrap(rows), encodedBytes: bytes)
        case .overBudget: .overBudget
        case .internalFailure: .internalFailure
        }
    }

    private static func connectionRow(_ connection: ActiveConnectionInfo) throws -> ControlConnectionRow {
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

    private static func upstreamRow(_ status: UpstreamRuntimeStatus) throws -> ControlUpstreamRow {
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

    private static func tunnelBindingRow(_ binding: TunnelBindingInfo) throws -> ControlTunnelBindingRow {
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

    private static func dnsHostRow(_ hostname: String, _ outcome: ControlTunnelDNSHostOutcome) -> ControlTunnelDNSHostRow {
        ControlTunnelDNSHostRow(hostname: displayText(hostname), outcome: outcome)
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
                totalCount: try ControlCount(tunnelDNSHostCount(status)),
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
                totalCount: try ControlCount(tunnelDNSHostCount(snapshot.tunnelDNSOverrideStatus)),
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

/// One view of a tunnel DNS status: its host groups in row order, each with its outcome. The view shares the status's arrays and copies
/// nothing. Its count sums the groups with each addition checked, so counting costs one step per group, not one per host.
private struct TunnelDNSHostSource {
    let groups: [(hostnames: [String], outcome: ControlTunnelDNSHostOutcome)]

    init(_ status: TunnelDNSOverrideStatus) {
        switch status {
        case .active(let hostnames): groups = [(hostnames, .active)]
        case .partial(let succeeded, let failed): groups = [(succeeded, .succeeded), (failed, .failed)]
        case .unavailable, .notNeeded: groups = []
        }
    }

    /// The host count, or nil when the sum would overflow.
    var count: Int? {
        var total = 0
        for group in groups {
            let (sum, overflow) = total.addingReportingOverflow(group.hostnames.count)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// Every host in row order. It is lazy, so a bounded measure reads one host at a time and no mapped array is built.
    var hosts: some Sequence<(hostname: String, outcome: ControlTunnelDNSHostOutcome)> {
        groups.lazy.flatMap { group in group.hostnames.lazy.map { (hostname: $0, outcome: group.outcome) } }
    }
}
