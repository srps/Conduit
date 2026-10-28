// SPDX-License-Identifier: Apache-2.0
import Combine
import ConduitShared
import Foundation
import ProxyKernel

/// SwiftUI's view of the runtime, built only from what the framed client delivers: the wire snapshot and the revision-qualified pages of
/// its collections (decision 0031). It holds no runtime object and grants no authority. Nothing here decides a command; the host checks
/// every precondition a command names, and a stale value here is refused there.
///
/// While the observation is not live (opening, after a stream ended, before a resubscription's baseline) the adapter claims nothing: the
/// views say the status is unavailable rather than show the last value or "stopped".
@MainActor
final class RuntimePresentationAdapter: ObservableObject {
    /// Whether the values below are current claims.
    enum Observation: Equatable {
        /// The runtime is opening, or refused to open.
        case unavailable
        /// A subscription delivered a baseline and has not ended since.
        case live
        /// The stream ended or failed; a resubscription is pending. The last values are cleared.
        case lost
        /// The runtime shut down. Nothing will be observed again.
        case ended
    }

    @Published private(set) var observation: Observation = .unavailable
    var isLive: Bool { observation == .live }

    // MARK: - Scalars

    @Published private(set) var runtimeStatus = RuntimeStatusDisplay.unobserved
    @Published private(set) var dnsRunState: ModuleRunState = .stopped
    @Published private(set) var tunnelsRunState: ModuleRunState = .stopped
    var directMode: Bool { directModeCause.isDirect }
    @Published private(set) var directModeCause: DirectModeCause = .none
    @Published private(set) var vpnState: VPNObservedState = .unknown
    @Published private(set) var vpnInterfaceName: String?
    @Published private(set) var proxyError: String?
    @Published private(set) var dnsError: String?
    @Published private(set) var tunnelsError: String?
    @Published private(set) var bindings = RuntimeBindingsDisplay()
    @Published private(set) var lastAuthOutcome: RuntimeAuthOutcome?
    @Published private(set) var lastAuthOutcomeAt: Date?
    @Published private(set) var lastAuthFallbackReason: String?
    @Published private(set) var requestsHandled = 0
    @Published private(set) var failedRequests = 0
    @Published private(set) var successfulRecoveries = 0
    @Published private(set) var uptimeStartedAt: Date?
    @Published private(set) var dnsQueryCount = 0
    @Published private(set) var dnsDoHFallbackCount = 0
    @Published private(set) var dnsCacheHitCount = 0
    @Published private(set) var tunnelActiveCount = 0
    @Published private(set) var tunnelSessionCount = 0
    @Published private(set) var vpnFlapCount = 0
    @Published private(set) var vpnFlapTotalDuration: TimeInterval = 0
    @Published private(set) var lastVpnFlapAt: Date?
    @Published private(set) var streamsPreservedAcrossFlaps = 0

    // MARK: - Collections

    /// What the rows of one collection are, relative to the latest snapshot.
    enum RowsState: Equatable {
        /// No rows were read for the snapshot's revision yet, or no view shows the list.
        case notRead
        /// The rows are the snapshot's current revision.
        case current
        /// The rows shown belong to an older revision; a read of the current one is due.
        case stale
        /// The host could not serve the list as a whole (decision 0038). No rows are shown; the count stays the snapshot's exact one and
        /// the connections are still served.
        case unavailable
    }

    /// The exact number of live connections the snapshot reports, whether or not their rows were read.
    @Published private(set) var activeConnectionCount = 0
    /// The rows of the latest revision read, empty until one is.
    @Published private(set) var activeConnections: [ConnectionDisplay] = []
    @Published private(set) var rowsState: [ControlCollectionKind: RowsState] = [:]
    @Published private(set) var upstreamStatuses: [UpstreamStatusDisplay] = []
    @Published private(set) var tunnelDNSOverrideStatus: TunnelDNSOverrideDisplay = .notNeeded

    func rows(_ kind: ControlCollectionKind) -> RowsState { rowsState[kind] ?? .notRead }

    /// The stamp of the latest snapshot: the incarnation and the revisions a command names. Not published; read when a command is built.
    private(set) var stamp: ControlRuntimeStamp?
    /// The latest snapshot's collection references, and the revision of the rows each kind holds.
    private(set) var collections: ControlRuntimeCollections?
    private var heldRevisions: [ControlCollectionKind: ControlCollectionRevision] = [:]
    private var tunnelDNSKind: ControlTunnelDNSKind = .notNeeded
    private var tunnelDNSHosts: [ControlTunnelDNSHostRow]?
    /// The collections a view shows now, by how many views show each. The upstream list is always shown by the menu bar.
    private var demand: [ControlCollectionKind: Int] = [.upstreamHealth: 1]
    /// The revision each kind was answered unavailable at: it is not read again until the snapshot names another.
    private var unavailableAt: [ControlCollectionKind: ControlCollectionRevision] = [:]

    // MARK: - Activity baseline

    // The host's counters are cumulative for its lifetime. Reset is presentational: the raw values at reset are remembered and the
    // delta published; a counter that goes backwards (a new host) clears its baseline.
    private var rawRequestsHandled = 0
    private var rawFailedRequests = 0
    private var requestsHandledBaseline = 0
    private var failedRequestsBaseline = 0

    func resetActivityCounters() {
        requestsHandledBaseline = rawRequestsHandled
        failedRequestsBaseline = rawFailedRequests
        if requestsHandled != 0 { requestsHandled = 0 }
        if failedRequests != 0 { failedRequests = 0 }
    }

    // MARK: - Observation

    /// One snapshot, from a baseline or a later frame. A snapshot of another incarnation replaces every held row.
    func apply(snapshot: ControlRuntimeSnapshot) {
        if stamp?.incarnation != snapshot.stamp.incarnation {
            clearRows()
        }
        stamp = snapshot.stamp
        collections = snapshot.collections
        if observation != .live { observation = .live }
        applyScalars(snapshot)
        applyCounters(snapshot)
        set(\.activeConnectionCount, snapshot.collections.activeConnections.totalCount.rawValue)
        tunnelDNSKind = snapshot.tunnelDNSOverride.kind
        for kind in ControlCollectionKind.allCases {
            switch snapshot.collections[kind].state {
            case .unavailable:
                dropRows(of: kind)
                setRows(kind, .unavailable)
            case .available(let revision):
                // A revision whose read the host answered unavailable is not read again, so it stays shown as unavailable.
                guard heldRevisions[kind] != revision, unavailableAt[kind] != revision else { continue }
                setRows(kind, heldRevisions[kind] == nil ? .notRead : .stale)
            }
        }
        refreshTunnelDNSDisplay()
    }

    /// The stream ended or failed. Every current claim is cleared until a new baseline arrives; nothing here implies the runtime stopped.
    func observationLost() {
        guard observation != .ended else { return }
        clearAll()
        observation = .lost
    }

    /// The runtime shut down.
    func observationEnded() {
        clearAll()
        observation = .ended
    }

    /// The collections whose held rows are older than the latest snapshot's revision and that a view shows now.
    var collectionsToRefresh: [ControlCollectionKind] {
        guard let collections, isLive else { return [] }
        return ControlCollectionKind.allCases.filter { kind in
            guard demand[kind, default: 0] > 0 else { return false }
            switch collections[kind].state {
            case .available(let revision): return heldRevisions[kind] != revision && unavailableAt[kind] != revision
            case .unavailable: return false
            }
        }
    }

    /// Told when a view begins showing a list, so its rows are read without waiting for the next snapshot.
    var onDemand: (@MainActor () -> Void)?

    /// A view begins or stops showing `kind`. Counted, so two views showing one list keep it read.
    func showing(_ kind: ControlCollectionKind, _ shown: Bool) {
        let count = max(0, demand[kind, default: 0] + (shown ? 1 : -1))
        demand[kind] = count
        if count == 0, kind != .upstreamHealth { dropRows(of: kind) }
        if shown { onDemand?() }
    }

    /// The complete rows of one revision, read page by page under one incarnation. Taken only while that revision is still the latest
    /// snapshot's for its kind; false otherwise, and nothing changes.
    @discardableResult
    func apply(rows: ControlProjectedRows, revision: ControlCollectionRevision, incarnation: ControlHostIncarnation) -> Bool {
        guard stamp?.incarnation == incarnation, isLive, case .available(revision)? = collections?[rows.kind].state else { return false }
        heldRevisions[rows.kind] = revision
        setRows(rows.kind, .current)
        switch rows {
        case .activeConnections(let list):
            activeConnections = list.map(ConnectionDisplay.init)
        case .upstreamHealth(let list):
            let mapped = list.map(UpstreamStatusDisplay.init)
            if upstreamStatuses != mapped { upstreamStatuses = mapped }
        case .tunnelBindings:
            break
        case .tunnelDNSHosts(let list):
            tunnelDNSHosts = list
            refreshTunnelDNSDisplay()
        }
        return true
    }

    /// The host could not serve `kind` as a whole. Its rows are withheld; the snapshot's exact total stays.
    func rowsUnavailable(_ kind: ControlCollectionKind, knownTotal: ControlCount?) {
        dropRows(of: kind)
        setRows(kind, .unavailable)
        if case .available(let revision)? = collections?[kind].state { unavailableAt[kind] = revision }
    }

    /// The rows held for `kind` are not the current revision's: a read failed, or answered an older revision.
    func rowsNotCurrent(_ kind: ControlCollectionKind) {
        guard heldRevisions[kind] != nil || rows(kind) == .current else { return }
        heldRevisions[kind] = nil
        setRows(kind, .stale)
    }

    private func setRows(_ kind: ControlCollectionKind, _ state: RowsState) {
        if rowsState[kind] != state { rowsState[kind] = state }
    }

    // MARK: - Internals

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<RuntimePresentationAdapter, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func applyScalars(_ snapshot: ControlRuntimeSnapshot) {
        set(\.runtimeStatus, RuntimeStatusDisplay(
            state: ProxyConnectionState(snapshot.proxyState),
            activeUpstream: snapshot.activeUpstream,
            lastHealthSummary: snapshot.healthSummary
        ))
        set(\.dnsRunState, ModuleRunState(snapshot.dnsRunState))
        set(\.tunnelsRunState, ModuleRunState(snapshot.tunnelsRunState))
        set(\.directModeCause, DirectModeCause(snapshot.directModeCause))
        set(\.vpnState, VPNObservedState(snapshot.vpnState))
        set(\.vpnInterfaceName, snapshot.vpnInterfaceName)
        set(\.proxyError, snapshot.proxyError)
        set(\.dnsError, snapshot.dnsError)
        set(\.tunnelsError, snapshot.tunnelsError)
        set(\.bindings, RuntimeBindingsDisplay(snapshot.bindings, tunnelCount: snapshot.collections.tunnelBindings.totalCount.rawValue))
        set(\.lastAuthOutcome, snapshot.lastAuthOutcome.map(RuntimeAuthOutcome.init))
        set(\.lastAuthOutcomeAt, snapshot.lastAuthOutcomeAt.map(Date.init(controlTimestamp:)))
        set(\.lastAuthFallbackReason, snapshot.lastAuthFallbackReason)
    }

    private func applyCounters(_ snapshot: ControlRuntimeSnapshot) {
        let metrics = snapshot.metrics
        rawRequestsHandled = metrics.requestsHandled.rawValue
        rawFailedRequests = metrics.failedRequests.rawValue
        if rawRequestsHandled < requestsHandledBaseline { requestsHandledBaseline = 0 }
        if rawFailedRequests < failedRequestsBaseline { failedRequestsBaseline = 0 }
        set(\.requestsHandled, rawRequestsHandled - requestsHandledBaseline)
        set(\.failedRequests, rawFailedRequests - failedRequestsBaseline)
        set(\.successfulRecoveries, metrics.successfulRecoveries.rawValue)
        set(\.uptimeStartedAt, metrics.uptimeStartedAt.map(Date.init(controlTimestamp:)))
        set(\.dnsQueryCount, snapshot.dnsQueryCount.rawValue)
        set(\.dnsDoHFallbackCount, snapshot.dnsDoHFallbackCount.rawValue)
        set(\.dnsCacheHitCount, snapshot.dnsCacheHitCount.rawValue)
        set(\.tunnelActiveCount, snapshot.tunnelActiveCount.rawValue)
        set(\.tunnelSessionCount, snapshot.tunnelSessionCount.rawValue)
        set(\.vpnFlapCount, snapshot.vpnFlap.count.rawValue)
        set(\.vpnFlapTotalDuration, snapshot.vpnFlap.totalDurationSeconds.rawValue)
        set(\.lastVpnFlapAt, snapshot.vpnFlap.lastFlapAt.map(Date.init(controlTimestamp:)))
        set(\.streamsPreservedAcrossFlaps, snapshot.vpnFlap.streamsPreserved.rawValue)
    }

    private func refreshTunnelDNSDisplay() {
        let total = collections?.tunnelDNSHosts.totalCount.rawValue ?? 0
        set(\.tunnelDNSOverrideStatus, TunnelDNSOverrideDisplay(kind: tunnelDNSKind, hosts: tunnelDNSHosts, total: total))
    }

    private func dropRows(of kind: ControlCollectionKind) {
        heldRevisions[kind] = nil
        // Read again when shown again: an unavailable answer is not kept for a list no view shows.
        unavailableAt[kind] = nil
        setRows(kind, .notRead)
        switch kind {
        case .activeConnections: if !activeConnections.isEmpty { activeConnections = [] }
        case .upstreamHealth: if !upstreamStatuses.isEmpty { upstreamStatuses = [] }
        case .tunnelDNSHosts:
            tunnelDNSHosts = nil
            refreshTunnelDNSDisplay()
        case .tunnelBindings: break
        }
    }

    private func clearRows() {
        heldRevisions = [:]
        unavailableAt = [:]
        if !rowsState.isEmpty { rowsState = [:] }
        if !activeConnections.isEmpty { activeConnections = [] }
        if !upstreamStatuses.isEmpty { upstreamStatuses = [] }
        tunnelDNSHosts = nil
    }

    private func clearAll() {
        clearRows()
        stamp = nil
        collections = nil
        tunnelDNSKind = .notNeeded
        set(\.runtimeStatus, .unobserved)
        set(\.dnsRunState, .stopped)
        set(\.tunnelsRunState, .stopped)
        set(\.directModeCause, .none)
        set(\.vpnState, .unknown)
        set(\.vpnInterfaceName, nil)
        set(\.proxyError, nil)
        set(\.dnsError, nil)
        set(\.tunnelsError, nil)
        set(\.bindings, RuntimeBindingsDisplay())
        set(\.activeConnectionCount, 0)
        set(\.tunnelDNSOverrideStatus, .notNeeded)
        set(\.uptimeStartedAt, nil)
    }
}

// MARK: - Display values

/// What the views say instead of runtime values while none is current.
enum RuntimeStatusText {
    /// Nil while the observation is live and the app ready.
    static func unavailable(phase: AppState.Phase, observation: RuntimePresentationAdapter.Observation) -> String? {
        switch (phase, observation) {
        case (.opening, _): "Opening the runtime…"
        case (.refused, _): "The runtime did not open. Repair the configuration file and restart Conduit."
        case (.quitting, _): "Quitting…"
        case (.ready, .live): nil
        case (.ready, .unavailable), (.ready, .lost): "Runtime status unavailable; reconnecting…"
        case (.ready, .ended): "The runtime has shut down."
        }
    }
}

/// The proxy's state line inputs. App-local display values from the wire snapshot.
struct RuntimeStatusDisplay: Equatable {
    var state: ProxyConnectionState
    var activeUpstream: String?
    var lastHealthSummary: String

    static let unobserved = RuntimeStatusDisplay(state: .stopped, activeUpstream: nil, lastHealthSummary: "")
}

/// The endpoints the runtime listens on, from the wire bindings.
struct RuntimeBindingsDisplay: Equatable {
    var proxyHost: String?
    var proxyPort: Int?
    var socksHost: String?
    var socksPort: Int?
    var localPACHost: String?
    var localPACPort: Int?
    var dnsHost: String?
    var dnsPort: Int?
    var transparentProxyPort: Int?
    /// The exact number of tunnel bindings the snapshot reports.
    var tunnelCount = 0

    init() {}

    init(_ wire: ControlRuntimeBindings, tunnelCount: Int) {
        proxyHost = wire.proxy?.host
        proxyPort = wire.proxy?.port?.rawValue
        socksHost = wire.socks?.host
        socksPort = wire.socks?.port?.rawValue
        localPACHost = wire.localPAC?.host
        localPACPort = wire.localPAC?.port?.rawValue
        dnsHost = wire.dns?.host
        dnsPort = wire.dns?.port?.rawValue
        transparentProxyPort = wire.transparentProxy?.port?.rawValue
        self.tunnelCount = tunnelCount
    }

    var localPACURL: String? {
        guard let localPACHost, let localPACPort else { return nil }
        return "http://\(localPACHost):\(localPACPort)\(LocalPACServer.pacPath)"
    }
}

/// One upstream's health row.
struct UpstreamStatusDisplay: Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var circuitState: UpstreamCircuitState
    var ewmaLatencyMS: Double?
    var consecutiveFailures: Int
    var openUntil: Date?

    init(id: UUID, name: String, endpoint: String, circuitState: UpstreamCircuitState, ewmaLatencyMS: Double?,
         consecutiveFailures: Int, openUntil: Date?) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.circuitState = circuitState
        self.ewmaLatencyMS = ewmaLatencyMS
        self.consecutiveFailures = consecutiveFailures
        self.openUntil = openUntil
    }

    init(_ row: ControlUpstreamRow) {
        self.init(
            id: row.id.rawValue, name: row.name, endpoint: row.endpoint, circuitState: UpstreamCircuitState(row.circuitState),
            ewmaLatencyMS: row.ewmaLatencyMilliseconds?.rawValue, consecutiveFailures: row.consecutiveFailures.rawValue,
            openUntil: row.openUntil.map(Date.init(controlTimestamp:))
        )
    }
}

/// One live connection.
struct ConnectionDisplay: Identifiable, Equatable {
    let id: UUID
    var destination: String
    var upstream: String
    var method: String
    var tunnel: Bool

    init(_ row: ControlConnectionRow) {
        id = row.id.rawValue
        destination = row.destination
        upstream = row.upstream
        method = row.method
        tunnel = row.tunnel
    }
}

/// The tunnel DNS override, with its hosts when they were read.
enum TunnelDNSOverrideDisplay: Equatable {
    case notNeeded
    case unavailable
    case active(hostnames: [String])
    case partial(succeeded: [String], failed: [String])
    /// The override is active or partial and its hosts were not read, or could not be served whole. The count is the snapshot's exact one.
    case hostsNotRead(hostCount: Int)

    init(kind: ControlTunnelDNSKind, hosts: [ControlTunnelDNSHostRow]?, total: Int) {
        switch kind {
        case .notNeeded: self = .notNeeded
        case .unavailable: self = .unavailable
        case .active, .partial:
            guard let hosts else {
                self = .hostsNotRead(hostCount: total)
                return
            }
            let failed = hosts.filter { $0.outcome == .failed }.map(\.hostname)
            let succeeded = hosts.filter { $0.outcome != .failed }.map(\.hostname)
            self = kind == .active ? .active(hostnames: succeeded) : .partial(succeeded: succeeded, failed: failed)
        }
    }
}

// MARK: - Wire to display enums

// One case for one, with no default, so a new wire case fails to compile here.

extension ProxyConnectionState {
    init(_ wire: ControlProxyState) {
        switch wire {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .running: self = .running
        case .degraded: self = .degraded
        case .recovering: self = .recovering
        case .failed: self = .failed
        }
    }
}

extension ModuleRunState {
    init(_ wire: ControlModuleRunState) {
        switch wire {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .running: self = .running
        case .warning: self = .warning
        case .failed: self = .failed
        }
    }
}

extension DirectModeCause {
    init(_ wire: ControlDirectModeCause) {
        switch wire {
        case .none: self = .none
        case .transientNetworkChange: self = .transientNetworkChange
        case .vpnDisconnected: self = .vpnDisconnected
        case .noUpstreamsConfigured: self = .noUpstreamsConfigured
        case .upstreamsUnreachable: self = .upstreamsUnreachable
        }
    }
}

extension VPNObservedState {
    init(_ wire: ControlVPNState) {
        switch wire {
        case .unknown: self = .unknown
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnected(.userInitiated): self = .disconnected(reason: .userInitiated)
        case .disconnected(.networkLost): self = .disconnected(reason: .networkLost)
        case .disconnected(.unknown): self = .disconnected(reason: .unknown)
        }
    }
}

extension RuntimeAuthOutcome {
    init(_ wire: ControlAuthOutcome) {
        switch wire {
        case .kerberos: self = .kerberos
        case .ntlmFallback: self = .ntlmFallback
        case .ntlmDirect: self = .ntlmDirect
        }
    }
}

extension UpstreamCircuitState {
    init(_ wire: ControlCircuitState) {
        switch wire {
        case .closed: self = .closed
        case .open: self = .open
        case .halfOpen: self = .halfOpen
        }
    }
}

extension Date {
    init(controlTimestamp: ControlTimestamp) {
        self.init(timeIntervalSince1970: controlTimestamp.rawValue)
    }
}

extension ControlRuntimeCollections {
    subscript(kind: ControlCollectionKind) -> ControlCollectionReference {
        switch kind {
        case .activeConnections: activeConnections
        case .upstreamHealth: upstreamHealth
        case .tunnelBindings: tunnelBindings
        case .tunnelDNSHosts: tunnelDNSHosts
        }
    }
}
