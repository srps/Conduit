// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

/// Projects kernel snapshot values onto the v2 control values. Each mapping is an
/// exhaustive switch, so a new kernel case fails to compile here until its wire
/// spelling is chosen. Free text is redacted and bounded through the one display
/// policy (decision 0029), and every cut or omission becomes a notice of its record.
/// A URL loses its query and fragment.
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
        var notices = ControlDisplayNoticeSink(owner: .snapshot)
        let shownProfileName = notices.text(profileName, .profileName)
        let shownActiveUpstream = notices.optionalText(status.activeUpstream, .activeUpstream)
        let shownHealthSummary = notices.text(status.lastHealthSummary, .healthSummary)
        let shownProxyError = notices.optionalText(snapshot.proxyError, .proxyError)
        let shownDNSError = notices.optionalText(snapshot.dnsError, .dnsError)
        let shownTunnelsError = notices.optionalText(snapshot.tunnelsError, .tunnelsError)
        let shownVPNInterface = notices.optionalText(snapshot.vpnInterfaceName, .vpnInterfaceName)
        let shownAuthFallback = notices.optionalText(snapshot.lastAuthFallbackReason, .lastAuthFallbackReason)
        let shownBindings = try runtimeBindings(snapshot.bindings, notices: &notices)
        let shownTunnelDNS = try tunnelDNSSummary(
            snapshot.tunnelDNSOverrideStatus,
            revision: collectionRevisions.tunnelDNSHosts,
            notices: &notices
        )
        return ControlRuntimeSnapshot(
            stamp: stamp,
            profileName: shownProfileName,
            proxyState: proxyState(status.state),
            activeUpstream: shownActiveUpstream,
            healthSummary: shownHealthSummary,
            proxyError: shownProxyError,
            dnsRunState: moduleRunState(snapshot.dnsRunState),
            dnsError: shownDNSError,
            tunnelsRunState: moduleRunState(snapshot.tunnelsRunState),
            tunnelsError: shownTunnelsError,
            directModeCause: directModeCause(snapshot.directModeCause),
            vpnState: vpnState(snapshot.vpnState),
            vpnInterfaceName: shownVPNInterface,
            bindings: shownBindings,
            lastAuthOutcome: snapshot.lastAuthOutcome.map(authOutcome),
            lastAuthOutcomeAt: try snapshot.lastAuthOutcomeAt.map(timestamp),
            lastAuthFallbackReason: shownAuthFallback,
            metrics: try runtimeMetrics(status.metrics),
            dnsQueryCount: try ControlCount(snapshot.dnsQueryCount),
            dnsDoHFallbackCount: try ControlCount(snapshot.dnsDoHFallbackCount),
            dnsCacheHitCount: try ControlCount(snapshot.dnsCacheHitCount),
            tunnelActiveCount: try ControlCount(snapshot.tunnelActiveCount),
            tunnelSessionCount: try ControlCount(snapshot.tunnelSessionCount),
            tunnelDNSOverride: shownTunnelDNS,
            vpnFlap: try vpnFlapMetrics(status.metrics),
            collections: try collections(snapshot, revisions: collectionRevisions),
            appliedState: .unavailable(.pendingAppliedStateSlice),
            displayNotices: notices.canonicalNotices
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
        var notices = ControlDisplayNoticeSink(owner: .connectionRow)
        let destination = notices.text(connection.destination, .connectionDestination)
        let upstream = notices.text(connection.upstream, .connectionUpstream)
        let method = notices.text(connection.method, .connectionMethod)
        let authMethod = notices.optionalText(connection.authMethod, .connectionAuthMethod)
        return ControlConnectionRow(
            id: ControlConnectionID(rawValue: connection.id),
            destination: destination,
            upstream: upstream,
            method: method,
            startedAt: try timestamp(connection.startedAt),
            lastActivityAt: try timestamp(connection.lastActivityAt),
            bytesSent: try ControlCount(connection.bytesSent),
            bytesReceived: try ControlCount(connection.bytesReceived),
            tunnel: connection.tunnel,
            authMethod: authMethod,
            displayNotices: notices.canonicalNotices
        )
    }

    private static func upstreamRow(_ status: UpstreamRuntimeStatus) throws -> ControlUpstreamRow {
        var notices = ControlDisplayNoticeSink(owner: .upstreamRow)
        let name = notices.text(status.name, .upstreamName)
        let endpoint = notices.text(status.endpoint, .upstreamEndpoint)
        return ControlUpstreamRow(
            id: ControlUpstreamID(rawValue: status.id),
            name: name,
            endpoint: endpoint,
            circuitState: circuitState(status.circuitState),
            ewmaLatencyMilliseconds: try status.ewmaLatencyMS.map { try ControlNonNegativeNumber($0) },
            consecutiveFailures: try ControlCount(status.consecutiveFailures),
            openUntil: try status.openUntil.map(timestamp),
            displayNotices: notices.canonicalNotices
        )
    }

    private static func tunnelBindingRow(_ binding: TunnelBindingInfo) throws -> ControlTunnelBindingRow {
        var notices = ControlDisplayNoticeSink(owner: .tunnelBindingRow)
        let label = notices.text(binding.label, .tunnelLabel)
        let localHost = notices.text(binding.localHost, .tunnelLocalHost)
        let remoteHost = notices.text(binding.remoteHost, .tunnelRemoteHost)
        return ControlTunnelBindingRow(
            id: ControlTunnelID(rawValue: binding.id),
            label: label,
            localHost: localHost,
            localPort: try ControlPort(binding.localPort),
            remoteHost: remoteHost,
            remotePort: try ControlPort(binding.remotePort),
            proxied: binding.proxied,
            healthy: binding.healthy,
            displayNotices: notices.canonicalNotices
        )
    }

    private static func dnsHostRow(_ hostname: String, _ outcome: ControlTunnelDNSHostOutcome) -> ControlTunnelDNSHostRow {
        var notices = ControlDisplayNoticeSink(owner: .dnsHostRow)
        let shown = notices.text(hostname, .dnsHostname)
        return ControlTunnelDNSHostRow(hostname: shown, outcome: outcome, displayNotices: notices.canonicalNotices)
    }

    // MARK: - Scalars

    /// The bindings, with each host bounded as a diagnostic endpoint. The notices of all five hosts go to the snapshot's sink.
    private static func runtimeBindings(
        _ bindings: ProxyOrchestratorBindings,
        notices: inout ControlDisplayNoticeSink
    ) throws -> ControlRuntimeBindings {
        let proxy = try endpoint(host: bindings.proxyHost, port: bindings.proxyPort, field: .proxyHost, notices: &notices)
        let socks = try endpoint(host: bindings.socksHost, port: bindings.socksPort, field: .socksHost, notices: &notices)
        let localPAC = try endpoint(host: bindings.localPACHost, port: bindings.localPACPort, field: .localPACHost, notices: &notices)
        let dns = try endpoint(host: bindings.dnsHost, port: bindings.dnsPort, field: .dnsHost, notices: &notices)
        let transparent = try endpoint(
            host: bindings.transparentProxyHost,
            port: bindings.transparentProxyPort,
            field: .transparentProxyHost,
            notices: &notices
        )
        return ControlRuntimeBindings(
            proxy: proxy,
            socks: socks,
            localPAC: localPAC,
            dns: dns,
            transparentProxy: transparent
        )
    }

    /// A binding with neither part set is absent. One set part is kept as it is, with its host bounded.
    private static func endpoint(
        host: String?,
        port: Int?,
        field: ControlDisplayField,
        notices: inout ControlDisplayNoticeSink
    ) throws -> ControlEndpoint? {
        guard host != nil || port != nil else { return nil }
        let shownHost = notices.optionalText(host, field)
        return ControlEndpoint(
            host: shownHost,
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
        revision: ControlCollectionRevision?,
        notices: inout ControlDisplayNoticeSink
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
            unavailableReason = notices.text(reason, .tunnelDNSUnavailableReason)
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
}

/// Collects the notices of one record while its display text is projected. It is the only producer of display notices: each text goes
/// through `ControlDisplayText.bounded` once, under the field's own cap, and each cut or omission becomes one notice.
struct ControlDisplayNoticeSink {
    private let owner: ControlDisplayOwner
    private var notices: [ControlDisplayNotice] = []

    init(owner: ControlDisplayOwner) {
        self.owner = owner
    }

    /// The display form of a present value. The field must belong to this sink's record, and each field is projected once, so a record
    /// holds at most one notice per field. A violation is a programmer error in the projection, so it stops here rather than publishing.
    mutating func text(_ value: String, _ field: ControlDisplayField) -> String {
        precondition(field.owner == owner, "\(field) is a field of \(field.owner), not \(owner)")
        precondition(!notices.contains { $0.field == field }, "\(field) is projected once per record")
        let shown = ControlDisplayText.bounded(value, maxBytes: field.maxBytes)
        if let treatment = shown.treatment {
            notices.append(ControlDisplayNotice(field: field, treatment: treatment))
        }
        return shown.text
    }

    /// The display form of an optional value. An absent value stays absent, with no notice.
    mutating func optionalText(_ value: String?, _ field: ControlDisplayField) -> String? {
        guard let value else { return nil }
        return text(value, field)
    }

    /// The notices in canonical field order, which the record's check requires.
    var canonicalNotices: [ControlDisplayNotice] {
        notices.sorted { $0.field.ordinal < $1.field.ordinal }
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
