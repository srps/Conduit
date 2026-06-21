// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum ModuleRunState: String, CaseIterable, Identifiable, Codable, Sendable {
    case stopped
    case starting
    case running
    case warning
    case failed

    package var id: String { rawValue }

    package var title: String { rawValue.capitalized }
}

package enum ProxyConnectionState: String, Codable, CaseIterable, Identifiable, Sendable {
    case stopped
    case starting
    case running
    case degraded
    case recovering
    case failed

    package var id: String { rawValue }

    package var title: String { rawValue.capitalized }
}

package struct ProxyMetrics: Codable, Equatable {
    package var requestsHandled: Int
    package var successfulRecoveries: Int
    package var failedRequests: Int
    package var openConnections: Int
    package var inboundConnections: Int
    package var uptimeStartedAt: Date?
    package var lastFailure: Date?

    /// Phase 7 — VPN flap telemetry. All four counters increment only on
    /// "super-min-visible" flaps (i.e. those that survive the
    /// `vpnFlapMinVisibleSeconds` debounce in `VPNStateFuser`). Sub-window
    /// blips never reach the orchestrator and are deliberately invisible
    /// here too — that matches the user's mental model of "the flap I
    /// noticed", not "every utun jitter the kernel saw".
    ///
    /// Read by `RuntimePresentationAdapter` for the MainView telemetry
    /// strip and serialized via `ProxyOrchestratorSnapshot` Codable for
    /// pm-proxy NDJSON consumers.
    package var vpnFlapCount: Int
    package var vpnFlapTotalDuration: TimeInterval
    package var lastVpnFlapAt: Date?
    /// Cumulative number of active CONNECT tunnels that survived a flap —
    /// summed across every `vpn.flap.recovered` event. The "value of the
    /// stream-preservation discipline" surfaced in one number.
    package var streamsPreservedAcrossFlaps: Int

    package init(
        requestsHandled: Int = 0,
        successfulRecoveries: Int = 0,
        failedRequests: Int = 0,
        openConnections: Int = 0,
        inboundConnections: Int = 0,
        uptimeStartedAt: Date? = nil,
        lastFailure: Date? = nil,
        vpnFlapCount: Int = 0,
        vpnFlapTotalDuration: TimeInterval = 0,
        lastVpnFlapAt: Date? = nil,
        streamsPreservedAcrossFlaps: Int = 0
    ) {
        self.requestsHandled = requestsHandled
        self.successfulRecoveries = successfulRecoveries
        self.failedRequests = failedRequests
        self.openConnections = openConnections
        self.inboundConnections = inboundConnections
        self.uptimeStartedAt = uptimeStartedAt
        self.lastFailure = lastFailure
        self.vpnFlapCount = vpnFlapCount
        self.vpnFlapTotalDuration = vpnFlapTotalDuration
        self.lastVpnFlapAt = lastVpnFlapAt
        self.streamsPreservedAcrossFlaps = streamsPreservedAcrossFlaps
    }

    package static let empty = ProxyMetrics()

    // Codable: explicit container so we can `decodeIfPresent ?? default` for
    // the Phase 7 additions. Snapshots persisted before Phase 7 (or NDJSON
    // produced by older builds piped into a newer reader) decode without the
    // new keys; the pre-existing fields stay strict to surface real schema
    // bugs. This mirrors the pattern in `ProxyConfig` for `HealthSection`.
    private enum CodingKeys: String, CodingKey {
        case requestsHandled
        case successfulRecoveries
        case failedRequests
        case openConnections
        case inboundConnections
        case uptimeStartedAt
        case lastFailure
        case vpnFlapCount
        case vpnFlapTotalDuration
        case lastVpnFlapAt
        case streamsPreservedAcrossFlaps
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.requestsHandled = try c.decode(Int.self, forKey: .requestsHandled)
        self.successfulRecoveries = try c.decode(Int.self, forKey: .successfulRecoveries)
        self.failedRequests = try c.decode(Int.self, forKey: .failedRequests)
        self.openConnections = try c.decode(Int.self, forKey: .openConnections)
        self.inboundConnections = try c.decode(Int.self, forKey: .inboundConnections)
        self.uptimeStartedAt = try c.decodeIfPresent(Date.self, forKey: .uptimeStartedAt)
        self.lastFailure = try c.decodeIfPresent(Date.self, forKey: .lastFailure)
        self.vpnFlapCount = try c.decodeIfPresent(Int.self, forKey: .vpnFlapCount) ?? 0
        self.vpnFlapTotalDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .vpnFlapTotalDuration) ?? 0
        self.lastVpnFlapAt = try c.decodeIfPresent(Date.self, forKey: .lastVpnFlapAt)
        self.streamsPreservedAcrossFlaps = try c.decodeIfPresent(Int.self, forKey: .streamsPreservedAcrossFlaps) ?? 0
    }
}

package struct ActiveConnectionInfo: Identifiable, Hashable, Codable, Sendable {
    package var id: UUID
    package var destination: String
    package var upstream: String
    package var method: String
    package var startedAt: Date
    package var lastActivityAt: Date
    package var bytesSent: Int
    package var bytesReceived: Int
    package var tunnel: Bool
    /// Upstream authentication mechanism used by this specific connection
    /// (`"Negotiate"`, `"NTLM"`, etc.). Nil for direct/no-auth flows and
    /// until the upstream handshake completes.
    package var authMethod: String?

    package init(
        id: UUID = UUID(),
        destination: String,
        upstream: String,
        method: String,
        startedAt: Date = .now,
        lastActivityAt: Date = .now,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        tunnel: Bool = false,
        authMethod: String? = nil
    ) {
        self.id = id
        self.destination = destination
        self.upstream = upstream
        self.method = method
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.tunnel = tunnel
        self.authMethod = authMethod
    }

    package mutating func applyActivity(_ activity: ConnectionActivity) {
        bytesSent += activity.bytesSent
        bytesReceived += activity.bytesReceived
        lastActivityAt = activity.timestamp
        if let authMethod = activity.authMethod {
            self.authMethod = authMethod
        }
    }
}

// MARK: - ActiveConnectionStore
//
// O(1) insert / remove-by-id / lookup-by-id container backing the
// orchestrator's `snapshot.activeConnections` field. The previous shape
// (`[ActiveConnectionInfo]`) forced an O(N) `firstIndex(where:)` linear
// scan on every connection-close and every byte-activity update — under a
// burst with N=200 active connections that translated to thousands of
// scans per second on the MainActor. This type encodes the ID→index
// invariant in one place so callers can't get it wrong.
//
// Wire compatibility: encodes/decodes as the bare `[ActiveConnectionInfo]`
// array so existing NDJSON consumers (pm-proxy `--status-interval`,
// `pmctl`) see no schema change.
//
// Equality compares only the visible `ordered` array — `indexByID` is
// derived state. The `RuntimePresentationAdapter`'s diff guard
// relies on this comparison being meaningful.
//
// Ordering caveat: `remove(id:)` uses swap-with-last for O(1), so element
// order is NOT insertion-order after the first removal. The UI displays
// up to 50 entries (`ConnectionsView`) with no ordering guarantee, and
// NDJSON consumers iterate the array without ordering assumptions, so
// this is acceptable. If a future caller needs stable ordering, switch
// to a different store shape — don't paper over it here.

package struct ActiveConnectionStore: Sendable {
    /// The materialised array of active connections. Read-only externally
    /// — mutations go through `insert` / `remove(id:)` / `update(id:_:)`
    /// so the parallel `indexByID` map stays in sync.
    package private(set) var ordered: [ActiveConnectionInfo]

    /// O(1) lookup map. Maintained alongside `ordered`; the swap-with-last
    /// removal in `remove(id:)` updates the index of the moved-from-end
    /// entry to keep the map consistent.
    private var indexByID: [UUID: Int]

    package init() {
        self.ordered = []
        self.indexByID = [:]
    }

    /// Build from an existing array (decode path, or the
    /// `preservedActiveConnections` filtered-rebuild path). Rebuilds
    /// `indexByID` from scratch.
    package init(_ initial: [ActiveConnectionInfo]) {
        self.ordered = initial
        self.indexByID = Dictionary(uniqueKeysWithValues: initial.enumerated().map { ($1.id, $0) })
    }

    package var count: Int { ordered.count }
    package var isEmpty: Bool { ordered.isEmpty }

    /// O(1) insert. The orchestrator allocates a fresh UUID per
    /// connection so `info.id` is guaranteed unique; we don't pay for
    /// a duplicate-key check.
    package mutating func insert(_ info: ActiveConnectionInfo) {
        indexByID[info.id] = ordered.endIndex
        ordered.append(info)
    }

    /// O(1) remove via swap-with-last. Returns true iff the id was present.
    /// Reorders `ordered` (see file-level "Ordering caveat" comment).
    @discardableResult
    package mutating func remove(id: UUID) -> Bool {
        guard let idx = indexByID.removeValue(forKey: id) else { return false }
        let last = ordered.count - 1
        if idx != last {
            ordered.swapAt(idx, last)
            indexByID[ordered[idx].id] = idx
        }
        ordered.removeLast()
        return true
    }

    /// O(1) in-place mutation by id. No-op if id is absent — matches the
    /// previous `if let idx = ... { ... }` guard pattern at the callsites
    /// (a stale activity event for a just-closed connection is normal and
    /// not an error).
    package mutating func update(id: UUID, _ body: (inout ActiveConnectionInfo) -> Void) {
        guard let idx = indexByID[id] else { return }
        body(&ordered[idx])
    }

    /// Drop everything. Used by the close-scope-`.all` / `.idleOnly`
    /// teardown paths and by `stopProxy()`.
    package mutating func removeAll() {
        ordered.removeAll(keepingCapacity: false)
        indexByID.removeAll(keepingCapacity: false)
    }
}

extension ActiveConnectionStore: Equatable {
    /// Compares only the visible ordered contents. `indexByID` is derived
    /// from `ordered`; identical `ordered` ⇒ identical `indexByID`.
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ordered == rhs.ordered
    }
}

extension ActiveConnectionStore: Codable {
    /// Wire shape is the bare `[ActiveConnectionInfo]` array — back-compat
    /// with existing NDJSON consumers that decode `activeConnections` as
    /// a JSON array. Decode rebuilds `indexByID` from scratch.
    package init(from decoder: Decoder) throws {
        let array = try [ActiveConnectionInfo](from: decoder)
        self.init(array)
    }

    package func encode(to encoder: Encoder) throws {
        try ordered.encode(to: encoder)
    }
}

/// Lightweight delta update for byte accounting. Designed for hot-path NIO handlers:
/// no heap allocation, no strings, just an ID + counters + timestamp.
package struct ConnectionActivity: Sendable {
    package let connectionID: UUID
    package let bytesSent: Int
    package let bytesReceived: Int
    package let timestamp: Date
    package let authMethod: String?

    package init(
        connectionID: UUID,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        timestamp: Date = .now,
        authMethod: String? = nil
    ) {
        self.connectionID = connectionID
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.timestamp = timestamp
        self.authMethod = authMethod
    }
}

package enum UpstreamCircuitState: String, Codable, Sendable {
    case closed
    case open
    case halfOpen
}

package struct UpstreamRuntimeStatus: Identifiable, Equatable, Codable, Sendable {
    package var id: UUID
    package var name: String
    package var endpoint: String
    package var circuitState: UpstreamCircuitState
    package var ewmaLatencyMS: Double?
    package var consecutiveFailures: Int
    package var openUntil: Date?

    package init(
        id: UUID,
        name: String,
        endpoint: String,
        circuitState: UpstreamCircuitState = .closed,
        ewmaLatencyMS: Double? = nil,
        consecutiveFailures: Int = 0,
        openUntil: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.circuitState = circuitState
        self.ewmaLatencyMS = ewmaLatencyMS
        self.consecutiveFailures = consecutiveFailures
        self.openUntil = openUntil
    }
}

package struct ProxyRuntimeStatus: Equatable, Codable, Sendable {
    package var state: ProxyConnectionState
    package var activeUpstream: String?
    package var lastHealthSummary: String
    package var metrics: ProxyMetrics

    package static let initial = ProxyRuntimeStatus(
        state: .stopped,
        activeUpstream: nil,
        lastHealthSummary: "Idle",
        metrics: .empty
    )
}
