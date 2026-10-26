// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The control wire's `config.workflow.*` values (decisions 0031 and 0032). They mirror the domain layout in `RuntimeEvents`
/// without importing it, so `ProxyControlBridge` maps the domain values onto these types exhaustively. The JSON layout and the
/// combination rules are the domain's: decoding and encoding apply the same predicates, so a malformed known value throws.
/// The derived `name` and `detail` match the domain's byte for byte, because the outer record must agree.
package enum ControlConfigWorkflowFile: String, Codable, Sendable, Equatable, CaseIterable {
    case runtime
    case platform
    case preferences
}

package enum ControlConfigWorkflowHeldInput: String, Codable, Sendable, Equatable, CaseIterable {
    case unit
    case runtime
    case platform
}

package enum ControlConfigWorkflowObservationPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case startup
    case reload
}

package enum ControlConfigWorkflowIntentPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case start
    case reload
}

package enum ControlConfigWorkflowRefusal: Sendable, Equatable {
    case unreadable(ControlConfigWorkflowFile)
    case versionExhausted(ControlConfigWorkflowFile)
    case invalidContent
    case journalPresenceUnknown
    case unexpected
    case busy
}

package enum ControlConfigWorkflowObservation: Sendable, Equatable {
    case adopted
    case refused(ControlConfigWorkflowRefusal)
}

package enum ControlConfigWorkflowNotAttemptedCause: String, Codable, Sendable, Equatable, CaseIterable {
    case noBaseline = "no_baseline"
    case baselineMismatch = "baseline_mismatch"
    case stagingRefused = "staging_refused"
    case preReadFailed = "pre_read_failed"
    case replacementRefused = "replacement_refused"
    case heldBehindPlatform = "held_behind_platform"
    case heldBehindRuntime = "held_behind_runtime"
    case preservationHeld = "preservation_held"
    case versionExhausted = "version_exhausted"
    case superseded
}

package enum ControlConfigWorkflowUnknownCause: String, Codable, Sendable, Equatable, CaseIterable {
    case readbackDiffers = "readback_differs"
    case readbackMissing = "readback_missing"
    case readbackFailed = "readback_failed"
}

package enum ControlConfigWorkflowWrite: Sendable, Equatable {
    case persisted(reportedError: Bool)
    case unchanged
    case notPersisted
    case unknown(ControlConfigWorkflowUnknownCause, reportedError: Bool)
    case conflict
    case notAttempted(ControlConfigWorkflowNotAttemptedCause)
}

extension ControlConfigWorkflowRefusal {
    /// The mirror of the domain's refusal detail, byte for byte.
    var detail: String {
        switch self {
        case .unreadable(let file): "reason=unreadable file=\(file.rawValue)"
        case .versionExhausted(let file): "reason=version_exhausted file=\(file.rawValue)"
        case .invalidContent: "reason=invalid_content"
        case .journalPresenceUnknown: "reason=journal_presence_unknown"
        case .unexpected: "reason=unexpected"
        case .busy: "reason=busy"
        }
    }
}

extension ControlConfigWorkflowWrite {
    /// The mirror of the domain's write detail, byte for byte.
    var detail: String {
        switch self {
        case .persisted(let reportedError): "outcome=persisted reported_error=\(reportedError)"
        case .unchanged: "outcome=unchanged"
        case .notPersisted: "outcome=not_persisted"
        case .unknown(let cause, let reportedError): "outcome=unknown cause=\(cause.rawValue) reported_error=\(reportedError)"
        case .conflict: "outcome=conflict"
        case .notAttempted(let cause): "outcome=not_attempted cause=\(cause.rawValue)"
        }
    }
}

package enum ControlConfigWorkflowHoldReason: String, Codable, Sendable, Equatable, CaseIterable {
    case startBlocking = "start_blocking"
    case uncommitted
    case stopFenced = "stop_fenced"
    case commitFailed = "commit_failed"
    case heldBehind = "held_behind"
    case intentExhausted = "intent_exhausted"
    case terminating
}

package enum ControlConfigWorkflowEvent: Codable, Sendable, Equatable {
    case observed(phase: ControlConfigWorkflowObservationPhase, observation: ControlConfigWorkflowObservation)
    case committed(file: ControlConfigWorkflowFile, write: ControlConfigWorkflowWrite)
    case held(phase: ControlConfigWorkflowIntentPhase, input: ControlConfigWorkflowHeldInput, reason: ControlConfigWorkflowHoldReason)
    case superseded(phase: ControlConfigWorkflowIntentPhase, generation: Int, current: Int)

    private enum WireType: String, Codable, CaseIterable {
        case observed
        case committed
        case held
        case superseded
    }

    /// The stable event names, spelled once here. The domain's `ConfigurationWorkflowEventName` pins the same four.
    private enum EventName: String, CaseIterable {
        case observed = "config.workflow.observed"
        case committed = "config.workflow.committed"
        case held = "config.workflow.held"
        case superseded = "config.workflow.superseded"
    }

    private enum CodingKeys: String, CodingKey {
        case type, phase, component, outcome, reason, file, cause, reportedError = "reported_error", generation, current
    }

    /// The `type` spellings this build decodes. The record classifier reads this set, so it cannot drift.
    package static let knownWireTypes: Set<String> = Set(WireType.allCases.map(\.rawValue))

    /// The event names this build emits and decodes. The record classifier reads this set, so it cannot drift.
    package static let knownEventNames: Set<String> = Set(EventName.allCases.map(\.rawValue))

    /// The mirror of the domain's `ConfigurationWorkflowHeld.isValid`.
    package static func isValidHeld(
        phase: ControlConfigWorkflowIntentPhase,
        input: ControlConfigWorkflowHeldInput,
        reason: ControlConfigWorkflowHoldReason
    ) -> Bool {
        switch reason {
        case .stopFenced: input == .unit
        case .heldBehind: phase == .start && input == .runtime
        case .commitFailed: phase == .start
        case .intentExhausted: phase == .start && input == .unit
        case .startBlocking: input == .runtime
        case .uncommitted: phase == .reload && input == .unit
        case .terminating: phase == .start && input == .unit
        }
    }

    /// The mirror of the domain's `ConfigurationWorkflowSuperseded.isValid`: a reload's floor is 0, and a start's is 1.
    package static func isValidSuperseded(phase: ControlConfigWorkflowIntentPhase, generation: Int, current: Int) -> Bool {
        (phase == .start ? generation >= 1 : generation >= 0) && current > generation
    }

    /// The stable event name, the same spelling the domain derives.
    package var name: String {
        switch self {
        case .observed: EventName.observed.rawValue
        case .committed: EventName.committed.rawValue
        case .held: EventName.held.rawValue
        case .superseded: EventName.superseded.rawValue
        }
    }

    /// The human detail, byte for byte what the domain derives.
    package var detail: String {
        switch self {
        case .observed(let phase, let observation):
            switch observation {
            case .adopted: "phase=\(phase.rawValue) outcome=adopted"
            case .refused(let refusal): "phase=\(phase.rawValue) outcome=refused \(refusal.detail)"
            }
        case .committed(let file, let write):
            "file=\(file.rawValue) \(write.detail)"
        case .held(let phase, let input, let reason):
            "phase=\(phase.rawValue) component=\(input.rawValue) reason=\(reason.rawValue)"
        case .superseded(let phase, let generation, let current):
            "phase=\(phase.rawValue) generation=\(generation) current=\(current)"
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .observed:
            let phase = try container.decode(ControlConfigWorkflowObservationPhase.self, forKey: .phase)
            let observation: ControlConfigWorkflowObservation
            switch try container.decode(String.self, forKey: .outcome) {
            case "adopted":
                // An adopted observation names no reason, so a reason present here is a malformed value.
                guard !container.contains(.reason) else {
                    throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "an adopted observation has no reason")
                }
                observation = .adopted
            case "refused":
                observation = .refused(try Self.decodeRefusal(container))
            default:
                throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "an observation is adopted or refused")
            }
            self = .observed(phase: phase, observation: observation)
        case .committed:
            self = .committed(
                file: try container.decode(ControlConfigWorkflowFile.self, forKey: .file),
                write: try Self.decodeWrite(container)
            )
        case .held:
            let phase = try container.decode(ControlConfigWorkflowIntentPhase.self, forKey: .phase)
            let input = try container.decode(ControlConfigWorkflowHeldInput.self, forKey: .component)
            let reason = try container.decode(ControlConfigWorkflowHoldReason.self, forKey: .reason)
            guard Self.isValidHeld(phase: phase, input: input, reason: reason) else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "a hold reason is produced only for its own input and phase")
            }
            self = .held(phase: phase, input: input, reason: reason)
        case .superseded:
            let phase = try container.decode(ControlConfigWorkflowIntentPhase.self, forKey: .phase)
            let generation = try container.decode(Int.self, forKey: .generation)
            let current = try container.decode(Int.self, forKey: .current)
            guard Self.isValidSuperseded(phase: phase, generation: generation, current: current) else {
                throw DecodingError.dataCorruptedError(forKey: .current, in: container, debugDescription: "a superseded generation is older than current, and a start's is at least 1")
            }
            self = .superseded(phase: phase, generation: generation, current: current)
        }
    }

    /// Refuses to write a known value that decoding would reject.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observed(let phase, let observation):
            try container.encode(WireType.observed, forKey: .type)
            try container.encode(phase, forKey: .phase)
            switch observation {
            case .adopted:
                try container.encode("adopted", forKey: .outcome)
            case .refused(let refusal):
                try container.encode("refused", forKey: .outcome)
                try Self.encodeRefusal(refusal, into: &container)
            }
        case .committed(let file, let write):
            try container.encode(WireType.committed, forKey: .type)
            try container.encode(file, forKey: .file)
            try Self.encodeWrite(write, into: &container)
        case .held(let phase, let input, let reason):
            guard Self.isValidHeld(phase: phase, input: input, reason: reason) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a hold reason is produced only for its own input and phase"
                ))
            }
            try container.encode(WireType.held, forKey: .type)
            try container.encode(phase, forKey: .phase)
            try container.encode(input, forKey: .component)
            try container.encode(reason, forKey: .reason)
        case .superseded(let phase, let generation, let current):
            guard Self.isValidSuperseded(phase: phase, generation: generation, current: current) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a superseded generation is older than current, and a start's is at least 1"
                ))
            }
            try container.encode(WireType.superseded, forKey: .type)
            try container.encode(phase, forKey: .phase)
            try container.encode(generation, forKey: .generation)
            try container.encode(current, forKey: .current)
        }
    }

    private static func decodeRefusal(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ControlConfigWorkflowRefusal {
        switch try container.decode(String.self, forKey: .reason) {
        case "unreadable": .unreadable(try container.decode(ControlConfigWorkflowFile.self, forKey: .file))
        case "version_exhausted": .versionExhausted(try container.decode(ControlConfigWorkflowFile.self, forKey: .file))
        case "invalid_content": .invalidContent
        case "journal_presence_unknown": .journalPresenceUnknown
        case "unexpected": .unexpected
        case "busy": .busy
        default: throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "an unknown refusal reason")
        }
    }

    private static func encodeRefusal(_ refusal: ControlConfigWorkflowRefusal, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch refusal {
        case .unreadable(let file):
            try container.encode("unreadable", forKey: .reason)
            try container.encode(file, forKey: .file)
        case .versionExhausted(let file):
            try container.encode("version_exhausted", forKey: .reason)
            try container.encode(file, forKey: .file)
        case .invalidContent: try container.encode("invalid_content", forKey: .reason)
        case .journalPresenceUnknown: try container.encode("journal_presence_unknown", forKey: .reason)
        case .unexpected: try container.encode("unexpected", forKey: .reason)
        case .busy: try container.encode("busy", forKey: .reason)
        }
    }

    private static func decodeWrite(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ControlConfigWorkflowWrite {
        switch try container.decode(String.self, forKey: .outcome) {
        case "persisted": .persisted(reportedError: try container.decode(Bool.self, forKey: .reportedError))
        case "unchanged": .unchanged
        case "not_persisted": .notPersisted
        case "unknown": .unknown(
            try container.decode(ControlConfigWorkflowUnknownCause.self, forKey: .cause),
            reportedError: try container.decode(Bool.self, forKey: .reportedError)
        )
        case "conflict": .conflict
        case "not_attempted": .notAttempted(try container.decode(ControlConfigWorkflowNotAttemptedCause.self, forKey: .cause))
        default: throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "an unknown write outcome")
        }
    }

    private static func encodeWrite(_ write: ControlConfigWorkflowWrite, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch write {
        case .persisted(let reportedError):
            try container.encode("persisted", forKey: .outcome)
            try container.encode(reportedError, forKey: .reportedError)
        case .unchanged:
            try container.encode("unchanged", forKey: .outcome)
        case .notPersisted:
            try container.encode("not_persisted", forKey: .outcome)
        case .unknown(let cause, let reportedError):
            try container.encode("unknown", forKey: .outcome)
            try container.encode(cause, forKey: .cause)
            try container.encode(reportedError, forKey: .reportedError)
        case .conflict:
            try container.encode("conflict", forKey: .outcome)
        case .notAttempted(let cause):
            try container.encode("not_attempted", forKey: .outcome)
            try container.encode(cause, forKey: .cause)
        }
    }
}
