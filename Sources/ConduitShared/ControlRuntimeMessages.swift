// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The v2 control envelope version. Independent of v1's `ControlProtocolVersion`,
/// which stays at 1. Helper IPC has its own version.
package enum ControlRuntimeProtocol {
    package static let version = 2
}

/// The request discriminators the v2 wire defines.
package enum ControlRuntimeRequestKind: String, Sendable, Equatable, CaseIterable {
    case submit
    case outcome
    case requestLookup
    case subscribe
    case readPage
    case readSnapshot
}

/// A client-to-host request.
package enum ControlRuntimeRequest: Codable, Sendable, Equatable {
    case submit(ControlOperationRequest)
    case outcome(ControlOperationQuery)
    case requestLookup(ControlRequestQuery)
    case subscribe(ControlSubscriptionRequest)
    case readPage(ControlPageRequest)
    /// Reads the scalar snapshot without opening a subscription. It carries no payload, so
    /// it needs no observer slot and answers when every subscription slot is full.
    case readSnapshot

    package var kind: ControlRuntimeRequestKind {
        switch self {
        case .submit: .submit
        case .outcome: .outcome
        case .requestLookup: .requestLookup
        case .subscribe: .subscribe
        case .readPage: .readPage
        case .readSnapshot: .readSnapshot
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case submit
        case outcome
        case requestLookup
        case subscribe
        case readPage
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = ControlRuntimeRequestKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown request")
        }
        switch kind {
        case .submit:
            self = .submit(try container.decode(ControlOperationRequest.self, forKey: .submit))
        case .outcome:
            self = .outcome(try container.decode(ControlOperationQuery.self, forKey: .outcome))
        case .requestLookup:
            self = .requestLookup(try container.decode(ControlRequestQuery.self, forKey: .requestLookup))
        case .subscribe:
            self = .subscribe(try container.decode(ControlSubscriptionRequest.self, forKey: .subscribe))
        case .readPage:
            self = .readPage(try container.decode(ControlPageRequest.self, forKey: .readPage))
        case .readSnapshot:
            self = .readSnapshot
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .submit(let request):
            try container.encode(request, forKey: .submit)
        case .outcome(let query):
            try container.encode(query, forKey: .outcome)
        case .requestLookup(let query):
            try container.encode(query, forKey: .requestLookup)
        case .subscribe(let subscription):
            try container.encode(subscription, forKey: .subscribe)
        case .readPage(let page):
            try container.encode(page, forKey: .readPage)
        case .readSnapshot:
            break
        }
    }
}

/// The response discriminators the v2 wire defines.
package enum ControlRuntimeResponseKind: String, Sendable, Equatable, CaseIterable {
    case admission
    case requestLookup
    case lookup
    case page
    case snapshot
    case failure
}

/// A host-to-client response to one request.
package enum ControlRuntimeResponse: Codable, Sendable, Equatable {
    case admission(ControlAdmission)
    case requestLookup(ControlRequestLookup)
    case lookup(ControlOperationLookup)
    case page(ControlPageReply)
    /// The answer to `readSnapshot`. Its stamp names the incarnation that a later
    /// mutation must expect.
    case snapshot(ControlRuntimeSnapshot)
    /// A failure at the wire boundary, such as a refused request. The code is stable;
    /// a client never reads it as an admitted or settled operation.
    case failure(ControlRuntimeErrorCode)

    package var kind: ControlRuntimeResponseKind {
        switch self {
        case .admission: .admission
        case .requestLookup: .requestLookup
        case .lookup: .lookup
        case .page: .page
        case .snapshot: .snapshot
        case .failure: .failure
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case admission
        case requestLookup
        case lookup
        case page
        case snapshot
        case failure
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = ControlRuntimeResponseKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown response")
        }
        switch kind {
        case .admission:
            self = .admission(try container.decode(ControlAdmission.self, forKey: .admission))
        case .requestLookup:
            self = .requestLookup(try container.decode(ControlRequestLookup.self, forKey: .requestLookup))
        case .lookup:
            self = .lookup(try container.decode(ControlOperationLookup.self, forKey: .lookup))
        case .page:
            self = .page(try container.decode(ControlPageReply.self, forKey: .page))
        case .snapshot:
            self = .snapshot(try container.decode(ControlRuntimeSnapshot.self, forKey: .snapshot))
        case .failure:
            self = .failure(try container.decode(ControlRuntimeErrorCode.self, forKey: .failure))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .admission(let admission):
            try container.encode(admission, forKey: .admission)
        case .requestLookup(let lookup):
            try container.encode(lookup, forKey: .requestLookup)
        case .lookup(let lookup):
            try container.encode(lookup, forKey: .lookup)
        case .page(let reply):
            try container.encode(reply, forKey: .page)
        case .snapshot(let snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case .failure(let code):
            try container.encode(code, forKey: .failure)
        }
    }
}

/// Whether a subscription can replay history from the cursor it resumes at.
package enum ControlReplayUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    case expiredHistory = "expired_history"
    case changedIncarnation = "changed_incarnation"
}

/// The replay range a baseline declares. A gap is explicit: a baseline restores
/// state but cannot recreate diagnostic events that have left the history.
package enum ControlReplayAvailability: Codable, Sendable, Equatable {
    case live
    case replay(from: ControlEventCursor, through: ControlEventCursor)
    case unavailable(ControlReplayUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case from
        case through
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "live":
            self = .live
        case "replay":
            let from = try container.decode(ControlEventCursor.self, forKey: .from)
            let through = try container.decode(ControlEventCursor.self, forKey: .through)
            guard from <= through else {
                throw DecodingError.dataCorruptedError(forKey: .through, in: container, debugDescription: "a replay range runs forward")
            }
            self = .replay(from: from, through: through)
        case "unavailable":
            self = .unavailable(try container.decode(ControlReplayUnavailableReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown replay range")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live:
            try container.encode("live", forKey: .type)
        case .replay(let from, let through):
            guard from <= through else {
                throw EncodingError.invalidValue(through, .init(
                    codingPath: encoder.codingPath, debugDescription: "a replay range runs forward"
                ))
            }
            try container.encode("replay", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(through, forKey: .through)
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// The first frame of a subscription. It names the incarnation, carries a complete
/// scalar snapshot from that incarnation, and declares the replay range that follows.
/// A live subscription bootstraps this way too, so its client learns the incarnation
/// without sending any mutation.
package struct ControlBaseline: Codable, Sendable, Equatable {
    package var incarnation: ControlHostIncarnation
    package var snapshot: ControlRuntimeSnapshot
    package var highWater: ControlEventCursor
    package var replay: ControlReplayAvailability

    package init(
        incarnation: ControlHostIncarnation,
        snapshot: ControlRuntimeSnapshot,
        highWater: ControlEventCursor,
        replay: ControlReplayAvailability
    ) throws {
        guard Self.isConsistent(incarnation: incarnation, snapshot: snapshot, highWater: highWater, replay: replay) else {
            throw ControlRuntimeWireError.invalidValue
        }
        self.incarnation = incarnation
        self.snapshot = snapshot
        self.highWater = highWater
        self.replay = replay
    }

    private enum CodingKeys: String, CodingKey {
        case incarnation
        case snapshot
        case highWater
        case replay
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let incarnation = try container.decode(ControlHostIncarnation.self, forKey: .incarnation)
        let snapshot = try container.decode(ControlRuntimeSnapshot.self, forKey: .snapshot)
        let highWater = try container.decode(ControlEventCursor.self, forKey: .highWater)
        let replay = try container.decode(ControlReplayAvailability.self, forKey: .replay)
        guard Self.isConsistent(incarnation: incarnation, snapshot: snapshot, highWater: highWater, replay: replay) else {
            throw DecodingError.dataCorruptedError(forKey: .highWater, in: container, debugDescription: "a baseline mixes incarnations or replay ranges")
        }
        self.incarnation = incarnation
        self.snapshot = snapshot
        self.highWater = highWater
        self.replay = replay
    }

    package func encode(to encoder: any Encoder) throws {
        guard Self.isConsistent(incarnation: incarnation, snapshot: snapshot, highWater: highWater, replay: replay) else {
            throw EncodingError.invalidValue(incarnation, .init(
                codingPath: encoder.codingPath, debugDescription: "a baseline mixes incarnations or replay ranges"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(highWater, forKey: .highWater)
        try container.encode(replay, forKey: .replay)
    }

    /// The snapshot must come from this incarnation, and a replay range, when it
    /// exists, must end at the high-water cursor the baseline reports.
    private static func isConsistent(
        incarnation: ControlHostIncarnation,
        snapshot: ControlRuntimeSnapshot,
        highWater: ControlEventCursor,
        replay: ControlReplayAvailability
    ) -> Bool {
        guard snapshot.stamp.incarnation == incarnation else { return false }
        if case .replay(_, let through) = replay {
            return through == highWater
        }
        return true
    }
}

/// A run of consecutive events. The cursor of each event is `firstCursor` plus its
/// position, so the batch cannot carry gaps. Each record is either a known event or
/// a bounded display record for a future informational event; see
/// `ControlRuntimeEventRecord`.
package struct ControlEventBatch: Codable, Sendable, Equatable {
    package let firstCursor: ControlEventCursor
    package let events: [ControlRuntimeEventRecord]

    package init(firstCursor: ControlEventCursor, events: [ControlRuntimeEventRecord]) throws {
        guard !events.isEmpty else { throw ControlRuntimeWireError.invalidValue }
        self.firstCursor = firstCursor
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case firstCursor
        case events
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let firstCursor = try container.decode(ControlEventCursor.self, forKey: .firstCursor)
        let events = try container.decode([ControlRuntimeEventRecord].self, forKey: .events)
        guard !events.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .events, in: container, debugDescription: "an event batch is not empty")
        }
        self.firstCursor = firstCursor
        self.events = events
    }

    package func encode(to encoder: any Encoder) throws {
        guard !events.isEmpty else {
            throw EncodingError.invalidValue(events, .init(
                codingPath: encoder.codingPath, debugDescription: "an event batch is not empty"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstCursor, forKey: .firstCursor)
        try container.encode(events, forKey: .events)
    }
}

/// An operation reached its settled outcome while a subscription was open.
package struct ControlOperationFinished: Codable, Sendable, Equatable {
    package var operationID: ControlOperationID
    package var outcome: ControlOperationOutcome

    package init(operationID: ControlOperationID, outcome: ControlOperationOutcome) {
        self.operationID = operationID
        self.outcome = outcome
    }
}

/// The stream frame discriminators the v2 wire defines.
package enum ControlRuntimeFrameKind: String, Sendable, Equatable, CaseIterable {
    case baseline
    case snapshot
    case events
    case replayCaughtUp
    case operationFinished
    case end
}

/// A frame of an open subscription. The baseline comes first. Snapshots replace
/// presentation state; events explain decisions and never act as commands.
package enum ControlRuntimeFrame: Codable, Sendable, Equatable {
    case baseline(ControlBaseline)
    case snapshot(ControlRuntimeSnapshot)
    case events(ControlEventBatch)
    case replayCaughtUp(ControlEventCursor)
    case operationFinished(ControlOperationFinished)
    case end(ControlStreamEnd)

    package var kind: ControlRuntimeFrameKind {
        switch self {
        case .baseline: .baseline
        case .snapshot: .snapshot
        case .events: .events
        case .replayCaughtUp: .replayCaughtUp
        case .operationFinished: .operationFinished
        case .end: .end
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case baseline
        case snapshot
        case events
        case cursor
        case operation
        case end
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = ControlRuntimeFrameKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown frame")
        }
        switch kind {
        case .baseline:
            self = .baseline(try container.decode(ControlBaseline.self, forKey: .baseline))
        case .snapshot:
            self = .snapshot(try container.decode(ControlRuntimeSnapshot.self, forKey: .snapshot))
        case .events:
            self = .events(try container.decode(ControlEventBatch.self, forKey: .events))
        case .replayCaughtUp:
            self = .replayCaughtUp(try container.decode(ControlEventCursor.self, forKey: .cursor))
        case .operationFinished:
            self = .operationFinished(try container.decode(ControlOperationFinished.self, forKey: .operation))
        case .end:
            self = .end(try container.decode(ControlStreamEnd.self, forKey: .end))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .baseline(let baseline):
            try container.encode(baseline, forKey: .baseline)
        case .snapshot(let snapshot):
            try container.encode(snapshot, forKey: .snapshot)
        case .events(let batch):
            try container.encode(batch, forKey: .events)
        case .replayCaughtUp(let cursor):
            try container.encode(cursor, forKey: .cursor)
        case .operationFinished(let finished):
            try container.encode(finished, forKey: .operation)
        case .end(let end):
            try container.encode(end, forKey: .end)
        }
    }
}

/// The body of one v2 message: a request, a response or a stream frame.
package enum ControlRuntimeBody: Sendable, Equatable {
    case request(ControlRuntimeRequest)
    case response(ControlRuntimeResponse)
    case frame(ControlRuntimeFrame)
}

/// One v2 message. A request names its exchange with `correlation`; each response and
/// each frame echoes the correlation of the request it answers. The wire carries
/// `version`, then `kind`, then `correlation`, then a `body` whose own `type` names the
/// value. The codec checks version and discriminators before it decodes any body.
package struct ControlRuntimeMessage: Codable, Sendable, Equatable {
    package var correlation: ControlRequestID
    package var body: ControlRuntimeBody

    package init(correlation: ControlRequestID, body: ControlRuntimeBody) {
        self.correlation = correlation
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case correlation
        case body
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == ControlRuntimeProtocol.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "an unsupported version")
        }
        correlation = try container.decode(ControlRequestID.self, forKey: .correlation)
        switch try container.decode(String.self, forKey: .kind) {
        case "request":
            body = .request(try container.decode(ControlRuntimeRequest.self, forKey: .body))
        case "response":
            body = .response(try container.decode(ControlRuntimeResponse.self, forKey: .body))
        case "frame":
            body = .frame(try container.decode(ControlRuntimeFrame.self, forKey: .body))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "an unknown envelope kind")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ControlRuntimeProtocol.version, forKey: .version)
        try container.encode(correlation, forKey: .correlation)
        switch body {
        case .request(let request):
            try container.encode("request", forKey: .kind)
            try container.encode(request, forKey: .body)
        case .response(let response):
            try container.encode("response", forKey: .kind)
            try container.encode(response, forKey: .body)
        case .frame(let frame):
            try container.encode("frame", forKey: .kind)
            try container.encode(frame, forKey: .body)
        }
    }
}
