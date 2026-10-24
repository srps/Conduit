// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The lists too large or too volatile for a scalar snapshot. A snapshot refers to
/// each one by revision and total count; rows arrive in pages.
package enum ControlCollectionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case activeConnections
    case upstreamHealth
    case tunnelBindings
    case tunnelDNSHosts
}

/// Why a referenced collection has no readable revision.
package enum ControlCollectionUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    case notCaptured = "not_captured"
    case retentionBudgetExceeded = "retention_budget_exceeded"
    case expiredRevision = "expired_revision"
}

/// Whether a collection can be read at a revision, or why it cannot.
package enum ControlCollectionState: Codable, Sendable, Equatable {
    case available(ControlCollectionRevision)
    case unavailable(ControlCollectionUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case revision
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "available":
            self = .available(try container.decode(ControlCollectionRevision.self, forKey: .revision))
        case "unavailable":
            self = .unavailable(try container.decode(ControlCollectionUnavailableReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown collection state")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let revision):
            try container.encode("available", forKey: .type)
            try container.encode(revision, forKey: .revision)
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// A snapshot's reference to one collection: its exact total and its readable revision.
package struct ControlCollectionReference: Codable, Sendable, Equatable {
    package var kind: ControlCollectionKind
    package var totalCount: ControlCount
    package var state: ControlCollectionState

    package init(kind: ControlCollectionKind, totalCount: ControlCount, state: ControlCollectionState) {
        self.kind = kind
        self.totalCount = totalCount
        self.state = state
    }
}

/// The four references every snapshot carries. Counts are exact even when a list is
/// unavailable; only the rows are withheld.
package struct ControlRuntimeCollections: Codable, Sendable, Equatable {
    package var activeConnections: ControlCollectionReference
    package var upstreamHealth: ControlCollectionReference
    package var tunnelBindings: ControlCollectionReference
    package var tunnelDNSHosts: ControlCollectionReference

    package init(
        activeConnections: ControlCollectionReference,
        upstreamHealth: ControlCollectionReference,
        tunnelBindings: ControlCollectionReference,
        tunnelDNSHosts: ControlCollectionReference
    ) {
        self.activeConnections = activeConnections
        self.upstreamHealth = upstreamHealth
        self.tunnelBindings = tunnelBindings
        self.tunnelDNSHosts = tunnelDNSHosts
    }
}

/// The revisions a projection pins into its references. A nil revision reports
/// `notCaptured`; nothing here is inferred.
package struct ControlCollectionRevisions: Sendable, Equatable {
    package var activeConnections: ControlCollectionRevision?
    package var upstreamHealth: ControlCollectionRevision?
    package var tunnelBindings: ControlCollectionRevision?
    package var tunnelDNSHosts: ControlCollectionRevision?

    package init(
        activeConnections: ControlCollectionRevision? = nil,
        upstreamHealth: ControlCollectionRevision? = nil,
        tunnelBindings: ControlCollectionRevision? = nil,
        tunnelDNSHosts: ControlCollectionRevision? = nil
    ) {
        self.activeConnections = activeConnections
        self.upstreamHealth = upstreamHealth
        self.tunnelBindings = tunnelBindings
        self.tunnelDNSHosts = tunnelDNSHosts
    }
}

/// Where a page continues: the revision it belongs to and the row offset to resume at.
/// The incarnation that scopes it is the one the requesting page carries.
package struct ControlPageCursor: Codable, Sendable, Equatable {
    package var revision: ControlCollectionRevision
    package var offset: ControlCount

    package init(revision: ControlCollectionRevision, offset: ControlCount) {
        self.revision = revision
        self.offset = offset
    }
}

/// A request for one page of one collection, scoped to the incarnation the caller read
/// its revisions from. Without a cursor, the first page of the current revision is
/// returned. A cursor from another incarnation is never resumed.
package struct ControlPageRequest: Codable, Sendable, Equatable {
    package var expectedIncarnation: ControlHostIncarnation
    package var collection: ControlCollectionKind
    package var cursor: ControlPageCursor?

    package init(
        expectedIncarnation: ControlHostIncarnation,
        collection: ControlCollectionKind,
        cursor: ControlPageCursor? = nil
    ) {
        self.expectedIncarnation = expectedIncarnation
        self.collection = collection
        self.cursor = cursor
    }
}

/// The freshness of a page relative to the revision it names.
package enum ControlPageStatus: Codable, Sendable, Equatable {
    case current
    /// The pinned revision has been superseded; the rows still belong to it.
    case staleRevision(current: ControlCollectionRevision)
    /// The pinned revision left the bounded retained history.
    case expiredRevision
    /// No rows are available; the reason says why.
    case unavailable(ControlCollectionUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case current
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "current":
            self = .current
        case "staleRevision":
            self = .staleRevision(current: try container.decode(ControlCollectionRevision.self, forKey: .current))
        case "expiredRevision":
            self = .expiredRevision
        case "unavailable":
            self = .unavailable(try container.decode(ControlCollectionUnavailableReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown page status")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode("current", forKey: .type)
        case .staleRevision(let current):
            try container.encode("staleRevision", forKey: .type)
            try container.encode(current, forKey: .current)
        case .expiredRevision:
            try container.encode("expiredRevision", forKey: .type)
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// A row of a paged collection. Rows are value types that carry only sanitized,
/// typed fields. `measure` adds the row's free text to a frame budget before the row
/// is serialized, so an oversize row is refused without being copied.
package protocol ControlCollectionRow: Codable, Sendable, Equatable {
    func measure(into budget: inout ControlFrameBudget) throws
}

/// One live connection. Rows come from one pinned revision.
package struct ControlConnectionRow: ControlCollectionRow {
    package var id: ControlConnectionID
    package var destination: String
    package var upstream: String
    package var method: String
    package var startedAt: ControlTimestamp
    package var lastActivityAt: ControlTimestamp
    package var bytesSent: ControlCount
    package var bytesReceived: ControlCount
    package var tunnel: Bool
    package var authMethod: String?

    package init(
        id: ControlConnectionID,
        destination: String,
        upstream: String,
        method: String,
        startedAt: ControlTimestamp,
        lastActivityAt: ControlTimestamp,
        bytesSent: ControlCount,
        bytesReceived: ControlCount,
        tunnel: Bool,
        authMethod: String?
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
}

/// One upstream's health row.
package struct ControlUpstreamRow: ControlCollectionRow {
    package var id: ControlUpstreamID
    package var name: String
    package var endpoint: String
    package var circuitState: ControlCircuitState
    package var ewmaLatencyMilliseconds: ControlNonNegativeNumber?
    package var consecutiveFailures: ControlCount
    package var openUntil: ControlTimestamp?

    package init(
        id: ControlUpstreamID,
        name: String,
        endpoint: String,
        circuitState: ControlCircuitState,
        ewmaLatencyMilliseconds: ControlNonNegativeNumber?,
        consecutiveFailures: ControlCount,
        openUntil: ControlTimestamp?
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.circuitState = circuitState
        self.ewmaLatencyMilliseconds = ewmaLatencyMilliseconds
        self.consecutiveFailures = consecutiveFailures
        self.openUntil = openUntil
    }
}

/// One tunnel's binding.
package struct ControlTunnelBindingRow: ControlCollectionRow {
    package var id: ControlTunnelID
    package var label: String
    package var localHost: String
    package var localPort: ControlPort
    package var remoteHost: String
    package var remotePort: ControlPort
    package var proxied: Bool
    package var healthy: Bool

    package init(
        id: ControlTunnelID,
        label: String,
        localHost: String,
        localPort: ControlPort,
        remoteHost: String,
        remotePort: ControlPort,
        proxied: Bool,
        healthy: Bool
    ) {
        self.id = id
        self.label = label
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.proxied = proxied
        self.healthy = healthy
    }
}

/// How one host in the tunnel DNS override is currently answered.
package enum ControlTunnelDNSHostOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case succeeded
    case failed
}

/// One host in the tunnel DNS override.
package struct ControlTunnelDNSHostRow: ControlCollectionRow {
    package var hostname: String
    package var outcome: ControlTunnelDNSHostOutcome

    package init(hostname: String, outcome: ControlTunnelDNSHostOutcome) {
        self.hostname = hostname
        self.outcome = outcome
    }
}

/// One page of rows from one revision of one incarnation. Its counts are exact:
/// `offset + rows.count` never passes `totalCount`, and a page has a continuation
/// exactly when rows remain.
package struct ControlCollectionPage<Row: ControlCollectionRow>: Codable, Sendable, Equatable {
    package let incarnation: ControlHostIncarnation
    package let revision: ControlCollectionRevision
    package let offset: ControlCount
    package let totalCount: ControlCount
    package let rows: [Row]
    package let nextCursor: ControlPageCursor?
    package let status: ControlPageStatus

    package init(
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        offset: ControlCount,
        totalCount: ControlCount,
        rows: [Row],
        nextCursor: ControlPageCursor?,
        status: ControlPageStatus
    ) throws {
        guard Self.isConsistent(
            revision: revision, offset: offset, totalCount: totalCount,
            rowCount: rows.count, nextCursor: nextCursor, status: status
        ) else { throw ControlRuntimeWireError.invalidValue }
        self.incarnation = incarnation
        self.revision = revision
        self.offset = offset
        self.totalCount = totalCount
        self.rows = rows
        self.nextCursor = nextCursor
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case incarnation
        case revision
        case offset
        case totalCount
        case rows
        case nextCursor
        case status
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let incarnation = try container.decode(ControlHostIncarnation.self, forKey: .incarnation)
        let revision = try container.decode(ControlCollectionRevision.self, forKey: .revision)
        let offset = try container.decode(ControlCount.self, forKey: .offset)
        let totalCount = try container.decode(ControlCount.self, forKey: .totalCount)
        let rows = try container.decode([Row].self, forKey: .rows)
        let nextCursor = try container.decodeIfPresent(ControlPageCursor.self, forKey: .nextCursor)
        let status = try container.decode(ControlPageStatus.self, forKey: .status)
        guard Self.isConsistent(
            revision: revision, offset: offset, totalCount: totalCount,
            rowCount: rows.count, nextCursor: nextCursor, status: status
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .totalCount, in: container, debugDescription: "page counts and continuation disagree")
        }
        self.incarnation = incarnation
        self.revision = revision
        self.offset = offset
        self.totalCount = totalCount
        self.rows = rows
        self.nextCursor = nextCursor
        self.status = status
    }

    package func encode(to encoder: any Encoder) throws {
        guard Self.isConsistent(
            revision: revision, offset: offset, totalCount: totalCount,
            rowCount: rows.count, nextCursor: nextCursor, status: status
        ) else {
            throw EncodingError.invalidValue(rows.count, .init(
                codingPath: encoder.codingPath, debugDescription: "page counts and continuation disagree"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(revision, forKey: .revision)
        try container.encode(offset, forKey: .offset)
        try container.encode(totalCount, forKey: .totalCount)
        try container.encode(rows, forKey: .rows)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try container.encode(status, forKey: .status)
    }

    private static func isConsistent(
        revision: ControlCollectionRevision,
        offset: ControlCount,
        totalCount: ControlCount,
        rowCount: Int,
        nextCursor: ControlPageCursor?,
        status: ControlPageStatus
    ) -> Bool {
        if case .unavailable = status {
            return rowCount == 0 && nextCursor == nil
        }
        // Subtract before adding: an untrusted offset near Int.max must refuse, not trap.
        // Once the row count is known to fit in the remaining total, the end cannot overflow.
        guard offset.rawValue <= totalCount.rawValue,
              rowCount <= totalCount.rawValue - offset.rawValue
        else { return false }
        let end = offset.rawValue + rowCount
        if let nextCursor {
            return nextCursor.revision == revision
                && nextCursor.offset.rawValue == end
                && end < totalCount.rawValue
        }
        return end == totalCount.rawValue
    }
}

/// A page tagged with the collection it came from, so the reply's kind and its rows
/// cannot disagree.
package enum ControlPageReply: Codable, Sendable, Equatable {
    case activeConnections(ControlCollectionPage<ControlConnectionRow>)
    case upstreamHealth(ControlCollectionPage<ControlUpstreamRow>)
    case tunnelBindings(ControlCollectionPage<ControlTunnelBindingRow>)
    case tunnelDNSHosts(ControlCollectionPage<ControlTunnelDNSHostRow>)

    package var collection: ControlCollectionKind {
        switch self {
        case .activeConnections: .activeConnections
        case .upstreamHealth: .upstreamHealth
        case .tunnelBindings: .tunnelBindings
        case .tunnelDNSHosts: .tunnelDNSHosts
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case page
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ControlCollectionKind.self, forKey: .type) {
        case .activeConnections:
            self = .activeConnections(try container.decode(ControlCollectionPage<ControlConnectionRow>.self, forKey: .page))
        case .upstreamHealth:
            self = .upstreamHealth(try container.decode(ControlCollectionPage<ControlUpstreamRow>.self, forKey: .page))
        case .tunnelBindings:
            self = .tunnelBindings(try container.decode(ControlCollectionPage<ControlTunnelBindingRow>.self, forKey: .page))
        case .tunnelDNSHosts:
            self = .tunnelDNSHosts(try container.decode(ControlCollectionPage<ControlTunnelDNSHostRow>.self, forKey: .page))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(collection, forKey: .type)
        switch self {
        case .activeConnections(let page):
            try container.encode(page, forKey: .page)
        case .upstreamHealth(let page):
            try container.encode(page, forKey: .page)
        case .tunnelBindings(let page):
            try container.encode(page, forKey: .page)
        case .tunnelDNSHosts(let page):
            try container.encode(page, forKey: .page)
        }
    }
}

/// Byte-budgeted paging. A page takes as many whole rows as its frame allows, in
/// order. Rows that do not fit wait for the next page, so nothing is cut, sampled, or
/// silently dropped. A row that cannot fit even alone is an explicit oversize error.
package enum ControlPagePacker {
    /// One framed page reply for `rows` from `offset`. The page is sized from its
    /// own rows, not from the raw collection, and every row's free text is checked
    /// against the frame limit before the row is serialized.
    package static func page<Row: ControlCollectionRow>(
        of rows: [Row],
        offset: Int,
        incarnation: ControlHostIncarnation,
        revision: ControlCollectionRevision,
        correlation: ControlRequestID,
        limits: ControlFrameLimits,
        wrap: (ControlCollectionPage<Row>) -> ControlPageReply
    ) throws -> ControlRuntimeMessage {
        guard offset >= 0, offset <= rows.count else { throw ControlRuntimeWireError.invalidValue }
        let remaining = rows[offset...]

        // A continuation cursor is reserved in advance, so the byte bound holds whether or
        // not this page carries one. The reserve covers its keys and two numbers.
        let continuationReserve = 256
        // An empty, complete page at the widest offset it can report (the total). Every
        // real page reports an offset and totals no wider than this, so the probe bounds
        // their size.
        let total = try ControlCount(rows.count)
        let probe = try ControlCollectionPage<Row>(
            incarnation: incarnation, revision: revision, offset: total, totalCount: total,
            rows: [], nextCursor: nil, status: .current
        )
        let probeSize = try ControlRuntimeCodec.encodeBoundedPayload(
            ControlRuntimeMessage(correlation: correlation, body: .response(.page(wrap(probe)))),
            limits: limits
        ).count + continuationReserve

        // Rows are encoded one at a time, and the loop stops at the first row that does not
        // fit, so the work per page is the rows it takes plus one.
        var size = probeSize
        var fitting = 0
        for row in remaining {
            let rowSize = try ControlRuntimeCodec.encodeBoundedRow(row, limits: limits).count
            // Each row after the first adds a separating comma.
            let next = size + rowSize + (fitting == 0 ? 0 : 1)
            // The final line feed counts against the frame too.
            guard next + 1 <= limits.maxFrameBytes else { break }
            size = next
            fitting += 1
        }
        if fitting == 0, !remaining.isEmpty {
            throw ControlRuntimeWireError.frameTooLarge
        }

        let end = offset + fitting
        let nextCursor: ControlPageCursor?
        if end < rows.count {
            nextCursor = try ControlPageCursor(revision: revision, offset: ControlCount(end))
        } else {
            nextCursor = nil
        }
        let page = try ControlCollectionPage<Row>(
            incarnation: incarnation,
            revision: revision,
            offset: ControlCount(offset),
            totalCount: total,
            rows: Array(remaining.prefix(fitting)),
            nextCursor: nextCursor,
            status: .current
        )
        let message = ControlRuntimeMessage(correlation: correlation, body: .response(.page(wrap(page))))
        // The sizing above is an upper bound, so this encoding fits. Encoding it
        // again keeps the guarantee checked rather than assumed.
        _ = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
        return message
    }
}
