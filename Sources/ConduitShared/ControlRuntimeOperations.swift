// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why the host refused to admit a command. Admission and settlement are
/// separate: a rejection never reaches an operation outcome.
package enum ControlRejectionCode: String, Codable, Sendable, Equatable, CaseIterable {
    case notImplemented = "not_implemented"
    case staleRevision = "stale_revision"
    case unknownUpstream = "unknown_upstream"
    case queueFull = "queue_full"
    case hostStopping = "host_stopping"
    case deadlineExpired = "deadline_expired"
    /// The request names another host incarnation, so none of its preconditions can be applied here.
    case changedIncarnation = "changed_incarnation"
    /// The request ID was recorded with a different payload. The earlier admission is never reused for it.
    case requestConflict = "request_conflict"
    /// The request ID already names a private editor request, or a private request reuses a recorded ID. A private ID is lookup-only:
    /// look the admission up and never resend. Nothing derived from a private body is kept to compare.
    case requestReused = "request_reused"
    /// The command is larger than the request cap the host accepts, so it cannot be recorded. Nothing was admitted.
    case commandTooLarge = "command_too_large"
    /// The host failed to record the command for a reason of its own. Nothing was admitted, and the cause is not reported.
    case internalFailure = "internal_failure"

    /// Sanitized text for display. The code, not this text, carries the meaning.
    package var humanDescription: String {
        switch self {
        case .notImplemented: "This command is not available in this runtime yet."
        case .staleRevision: "The command was made against a revision that is no longer current."
        case .unknownUpstream: "The upstream is not in the referenced configuration."
        case .queueFull: "The runtime has no free command slot right now."
        case .hostStopping: "The runtime is shutting down and admits no new commands."
        case .deadlineExpired: "The time budget ended before the command was admitted."
        case .changedIncarnation: "The runtime restarted since the command was read, so it was not applied."
        case .requestConflict: "This request ID was already used for a different command."
        case .requestReused: "This request ID was already admitted; look it up rather than send it again."
        case .commandTooLarge: "The command is larger than the runtime accepts, so it was not admitted."
        case .internalFailure: "The runtime could not record this command, so it was not admitted."
        }
    }
}

/// The host's answer at admission. `accepted` and `joined` both name the operation
/// to observe; `rejected` means no operation exists for this request.
package enum ControlAdmission: Codable, Sendable, Equatable {
    case accepted(ControlOperationID)
    case joined(ControlOperationID)
    case rejected(ControlRejectionCode)

    private enum CodingKeys: String, CodingKey {
        case type
        case operation
        case rejection
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "accepted":
            self = .accepted(try container.decode(ControlOperationID.self, forKey: .operation))
        case "joined":
            self = .joined(try container.decode(ControlOperationID.self, forKey: .operation))
        case "rejected":
            self = .rejected(try container.decode(ControlRejectionCode.self, forKey: .rejection))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown admission")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let operation):
            try container.encode("accepted", forKey: .type)
            try container.encode(operation, forKey: .operation)
        case .joined(let operation):
            try container.encode("joined", forKey: .type)
            try container.encode(operation, forKey: .operation)
        case .rejected(let code):
            try container.encode("rejected", forKey: .type)
            try container.encode(code, forKey: .rejection)
        }
    }
}

/// Why an operation failed to reach its intended state.
package enum ControlFailureCode: String, Codable, Sendable, Equatable, CaseIterable {
    case effectFailed = "effect_failed"
    case cleanupIncomplete = "cleanup_incomplete"
    case staleRevision = "stale_revision"
    case internalFailure = "internal_failure"
    /// The configuration store's one slot was taken by another operation, so nothing was captured or written. A capacity answer, not a
    /// persistence failure: a later explicit request may succeed.
    case storeBusy = "store_busy"

    /// Sanitized text for display. The code, not this text, carries the meaning.
    package var humanDescription: String {
        switch self {
        case .storeBusy: "The configuration store was busy, so nothing was saved; try again."
        case .effectFailed: "The change did not take effect."
        case .cleanupIncomplete: "Cleanup did not finish; recovery work remains."
        case .staleRevision: "The operation was superseded by a newer revision."
        case .internalFailure: "The runtime hit an internal error."
        }
    }
}

/// One module's result within a partially completed operation. This is module-level
/// partial completion only. It is not evidence about any machine surface (system
/// proxy, DNS resolver, login item and so on): that per-surface applied state waits
/// for #194 and is reported as unavailable until then.
package enum ControlModuleResult: Codable, Sendable, Equatable {
    case succeeded
    case failed(ControlFailureCode)
    case cleanupPending

    private enum CodingKeys: String, CodingKey {
        case type
        case failure
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "succeeded":
            self = .succeeded
        case "failed":
            self = .failed(try container.decode(ControlFailureCode.self, forKey: .failure))
        case "cleanupPending":
            self = .cleanupPending
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown module result")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded:
            try container.encode("succeeded", forKey: .type)
        case .failed(let code):
            try container.encode("failed", forKey: .type)
            try container.encode(code, forKey: .failure)
        case .cleanupPending:
            try container.encode("cleanupPending", forKey: .type)
        }
    }
}

/// One module's entry in a partially completed operation.
package struct ControlModuleOutcome: Codable, Sendable, Equatable {
    package var module: ControlModule
    package var result: ControlModuleResult

    package init(module: ControlModule, result: ControlModuleResult) {
        self.module = module
        self.result = result
    }
}

/// The module results of a partially completed operation. Each module appears at most
/// once, and the list is never empty.
package struct ControlModuleOutcomes: Codable, Sendable, Equatable {
    package let entries: [ControlModuleOutcome]

    package init(_ entries: [ControlModuleOutcome]) throws {
        guard Self.isValid(entries) else { throw ControlRuntimeWireError.invalidValue }
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([ControlModuleOutcome].self, forKey: .entries)
        guard Self.isValid(decoded) else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: container, debugDescription: "modules must be unique and non-empty")
        }
        self.entries = decoded
    }

    package func encode(to encoder: any Encoder) throws {
        guard Self.isValid(entries) else {
            throw EncodingError.invalidValue(entries, .init(
                codingPath: encoder.codingPath, debugDescription: "modules must be unique and non-empty"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    private static func isValid(_ entries: [ControlModuleOutcome]) -> Bool {
        !entries.isEmpty
            && entries.count <= ControlModule.allCases.count
            && Set(entries.map(\.module)).count == entries.count
    }
}

/// A settled success: the command it answers, the presentation revision that reflects
/// it, and its result. The result kind must belong to the command, so a probe that was
/// never run cannot settle as a generic success.
package struct ControlCompletion: Codable, Sendable, Equatable {
    package let command: ControlRuntimeCommandKind
    package let presentationRevision: ControlPresentationRevision
    package let result: ControlCommandResult

    package init(
        command: ControlRuntimeCommandKind,
        presentationRevision: ControlPresentationRevision,
        result: ControlCommandResult
    ) throws {
        guard Self.pairs(command: command, result: result) else { throw ControlRuntimeWireError.invalidValue }
        self.command = command
        self.presentationRevision = presentationRevision
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case presentationRevision
        case result
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decode(ControlRuntimeCommandKind.self, forKey: .command)
        let result = try container.decode(ControlCommandResult.self, forKey: .result)
        guard Self.pairs(command: command, result: result) else {
            throw DecodingError.dataCorruptedError(forKey: .result, in: container, debugDescription: "a result belongs to a different command")
        }
        self.command = command
        self.presentationRevision = try container.decode(ControlPresentationRevision.self, forKey: .presentationRevision)
        self.result = result
    }

    package func encode(to encoder: any Encoder) throws {
        guard Self.pairs(command: command, result: result) else {
            throw EncodingError.invalidValue(result, .init(
                codingPath: encoder.codingPath, debugDescription: "a result belongs to a different command"
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(presentationRevision, forKey: .presentationRevision)
        try container.encode(result, forKey: .result)
    }

    /// Stop, quit and a credentials invalidation settle with no payload. Each observation command reports its own. A saved Start or Restart never completes here: it
    /// settles with its causal receipt (`configurationSettled`), or fails with its closed cause when no commit ran.
    private static func pairs(command: ControlRuntimeCommandKind, result: ControlCommandResult) -> Bool {
        switch (command, result) {
        case (.stop, .settled), (.quit, .settled), (.credentialsChanged, .settled): true
        case (.stop, .dnsDisable): true
        case (.testUpstream, .upstreamProbe): true
        case (.testDNS, .dnsLiveness): true
        case (.refreshPreflight, .preflight): true
        case (.setLaunchAtLogin, .platformWrite): true
        default: false
        }
    }
}

/// The settled outcome of an admitted operation. Only these four exist; every
/// other state is either `pending` or an explicit `unknown` lookup.
package enum ControlOperationOutcome: Codable, Sendable, Equatable {
    case completed(ControlCompletion)
    case superseded(by: ControlOperationID)
    /// Some modules completed and others did not. See `ControlModuleOutcomes`.
    case partiallyCompleted(ControlModuleOutcomes)
    case failed(ControlFailureCode)
    /// A private editor update, or a saved Start or Restart whose preparation ran its commit, settled: its causal receipt, whatever each
    /// file and module came to. It is settlement, never admission or success, and it carries no configuration value.
    case configurationSettled(ControlConfigurationReceipt)
    /// A private preferences update settled: its causal receipt. Settlement only, with no configuration value.
    case preferencesSettled(ControlPreferencesReceipt)

    private enum CodingKeys: String, CodingKey {
        case type
        case completion
        case by
        case modules
        case failure
        case receipt
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "completed":
            self = .completed(try container.decode(ControlCompletion.self, forKey: .completion))
        case "superseded":
            self = .superseded(by: try container.decode(ControlOperationID.self, forKey: .by))
        case "partiallyCompleted":
            self = .partiallyCompleted(try container.decode(ControlModuleOutcomes.self, forKey: .modules))
        case "failed":
            self = .failed(try container.decode(ControlFailureCode.self, forKey: .failure))
        case "configurationSettled":
            self = .configurationSettled(try container.decode(ControlConfigurationReceipt.self, forKey: .receipt))
        case "preferencesSettled":
            self = .preferencesSettled(try container.decode(ControlPreferencesReceipt.self, forKey: .receipt))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown outcome")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let completion):
            try container.encode("completed", forKey: .type)
            try container.encode(completion, forKey: .completion)
        case .superseded(let operation):
            try container.encode("superseded", forKey: .type)
            try container.encode(operation, forKey: .by)
        case .partiallyCompleted(let modules):
            try container.encode("partiallyCompleted", forKey: .type)
            try container.encode(modules, forKey: .modules)
        case .failed(let code):
            try container.encode("failed", forKey: .type)
            try container.encode(code, forKey: .failure)
        case .configurationSettled(let receipt):
            try container.encode("configurationSettled", forKey: .type)
            try container.encode(receipt, forKey: .receipt)
        case .preferencesSettled(let receipt):
            try container.encode("preferencesSettled", forKey: .type)
            try container.encode(receipt, forKey: .receipt)
        }
    }
}

/// Why a lookup cannot name a state or outcome. Each reason is explicit; a caller
/// must not treat any of them as proof that nothing ran.
package enum ControlUnknownOutcomeReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The outcome existed but was evicted from the bounded retained history.
    case expiredHistory = "expired_history"
    /// The host restarted, so this operation belonged to a previous incarnation.
    case changedIncarnation = "changed_incarnation"
    /// This incarnation has no record of the operation.
    case notRecorded = "not_recorded"
}

/// The answer to an outcome lookup.
package enum ControlOperationLookup: Codable, Sendable, Equatable {
    case pending
    case finished(ControlOperationOutcome)
    case unknown(ControlUnknownOutcomeReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case outcome
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pending":
            self = .pending
        case "finished":
            self = .finished(try container.decode(ControlOperationOutcome.self, forKey: .outcome))
        case "unknown":
            self = .unknown(try container.decode(ControlUnknownOutcomeReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown lookup")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try container.encode("pending", forKey: .type)
        case .finished(let outcome):
            try container.encode("finished", forKey: .type)
            try container.encode(outcome, forKey: .outcome)
        case .unknown(let reason):
            try container.encode("unknown", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// The answer to a request lookup: the admission the host recorded for that request in
/// this incarnation, or why it cannot say. `unknown` is never proof that nothing ran.
package enum ControlRequestLookup: Codable, Sendable, Equatable {
    case admission(ControlAdmission)
    case unknown(ControlUnknownOutcomeReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case admission
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "admission":
            self = .admission(try container.decode(ControlAdmission.self, forKey: .admission))
        case "unknown":
            self = .unknown(try container.decode(ControlUnknownOutcomeReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown request lookup")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .admission(let admission):
            try container.encode("admission", forKey: .type)
            try container.encode(admission, forKey: .admission)
        case .unknown(let reason):
            try container.encode("unknown", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// How a stream begins. A live subscription starts after the baseline's high-water
/// cursor; a resume asks for replay from a cursor in one incarnation.
package enum ControlSubscriptionRequest: Codable, Sendable, Equatable {
    case live
    case resume(incarnation: ControlHostIncarnation, from: ControlEventCursor)

    private enum CodingKeys: String, CodingKey {
        case type
        case incarnation
        case cursor
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "live":
            self = .live
        case "resume":
            self = .resume(
                incarnation: try container.decode(ControlHostIncarnation.self, forKey: .incarnation),
                from: try container.decode(ControlEventCursor.self, forKey: .cursor)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown subscription")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .live:
            try container.encode("live", forKey: .type)
        case .resume(let incarnation, let cursor):
            try container.encode("resume", forKey: .type)
            try container.encode(incarnation, forKey: .incarnation)
            try container.encode(cursor, forKey: .cursor)
        }
    }
}

/// Why a stream ended. Each reason is typed so a client can resubscribe or report
/// honestly; none of them stops the runtime.
package enum ControlStreamEndReason: String, Codable, Sendable, Equatable, CaseIterable {
    case slowConsumer = "slow_consumer"
    case resyncRequired = "resync_required"
    case hostShutdown = "host_shutdown"
}

/// The last frame of a stream.
package struct ControlStreamEnd: Codable, Sendable, Equatable {
    package var reason: ControlStreamEndReason

    package init(reason: ControlStreamEndReason) {
        self.reason = reason
    }
}
