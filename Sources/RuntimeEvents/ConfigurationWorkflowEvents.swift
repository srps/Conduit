// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The typed `config.workflow.*` events (decisions 0015, 0025, 0027, 0031 and 0032; design in
/// `docs/design-runtime-store-workflow.md`). Each event has its own narrow enums, and the cases that carry a reason or a cause
/// reject contradictory phase/component/reason combinations at construction and decoding. Every field is closed. No field takes free text, so
/// a URL, an error description, a configuration value, an errno or a content fingerprint has nowhere to go.
///
/// Producers build these values in `ConduitRuntime`'s workflow. The kernel's `RuntimeEvent(payload:)` derives the name, kind and
/// detail from them. The wire mirror (`ConduitShared`) applies the same predicates on decode and encode.

/// The configuration file an observation or a write is about. The preferences sidecar is independent of the apply unit.
package enum ConfigurationWorkflowFile: String, Codable, Sendable, Equatable, CaseIterable {
    case runtime
    case platform
    case preferences
}

/// What an apply is held on. `unit` is the coupled runtime and platform pair that one apply waits on (decision 0025).
/// Preferences never hold an apply, so they have no case here.
package enum ConfigurationWorkflowHeldInput: String, Codable, Sendable, Equatable, CaseIterable {
    case unit
    case runtime
    case platform
}

/// The phases that observe the inputs. A startup observes before the host's baselines exist.
package enum ConfigurationWorkflowObservationPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case startup
    case reload
}

/// The phases that admit intent. A Start and a reload can each be held or superseded. A Stop is never held or superseded as a whole: its
/// fence holds at admission. Only the disable save a session DNS Stop owes can be held, when the store's one slot is busy.
package enum ConfigurationWorkflowIntentPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case start
    case reload
    case stop
}

/// Why an observation was refused. Only the file-scoped cases name a file.
package enum ConfigurationWorkflowRefusal: Equatable, Sendable {
    case unreadable(ConfigurationWorkflowFile)
    case versionExhausted(ConfigurationWorkflowFile)
    case invalidContent
    case journalPresenceUnknown
    case unexpected
    /// Another store operation held the slot, so the observation was refused without queueing.
    case busy
}

/// The result of an observation: the store adopted the bytes, or it refused them and kept its last values.
package enum ConfigurationWorkflowObservation: Equatable, Sendable {
    case adopted
    case refused(ConfigurationWorkflowRefusal)
}

/// Why a write did not start. Every case is one the workflow's store path can produce.
package enum ConfigurationWorkflowNotAttemptedCause: String, Codable, Sendable, Equatable, CaseIterable {
    case noBaseline = "no_baseline"
    case baselineMismatch = "baseline_mismatch"
    case stagingRefused = "staging_refused"
    case preReadFailed = "pre_read_failed"
    case replacementRefused = "replacement_refused"
    case heldBehindPlatform = "held_behind_platform"
    case heldBehindRuntime = "held_behind_runtime"
    case preservationHeld = "preservation_held"
    /// A missing sidecar's first write was held because the runtime file it takes its values from changed since the store established it.
    case sourceChanged = "source_changed"
    /// A missing sidecar's first write was held because the runtime file it takes its values from could not be read.
    case sourceUnreadable = "source_unreadable"
    case versionExhausted = "version_exhausted"
    /// A newer intent was admitted before the replacement started, so the workflow's claim refused it.
    case superseded
}

/// Why a write's outcome is unknown. The read-back could not establish the file's state (decision 0015).
package enum ConfigurationWorkflowUnknownCause: String, Codable, Sendable, Equatable, CaseIterable {
    case readbackDiffers = "readback_differs"
    case readbackMissing = "readback_missing"
    case readbackFailed = "readback_failed"
}

/// One component's write result. `reportedError` keeps a fact the replacement reported even when read-back verified it, so a
/// true partial result is not discarded (decision 0015).
package enum ConfigurationWorkflowWrite: Equatable, Sendable {
    case persisted(reportedError: Bool)
    case unchanged
    /// A verified not-persisted result. Read-back shows the prior, and the replacement reported an error.
    case notPersisted
    case unknown(ConfigurationWorkflowUnknownCause, reportedError: Bool)
    /// The file changed outside the store since its baseline, so the write was refused (decision 0027).
    case conflict
    case notAttempted(ConfigurationWorkflowNotAttemptedCause)
}

/// Why an apply, a Start or a reload held its input. The prior applied configuration keeps running (decision 0025).
package enum ConfigurationWorkflowHoldReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The runtime input has a problem that blocks a proxy start. The draft is kept for editing.
    case startBlocking = "start_blocking"
    /// A required file is absent, so its defaults are not verified persisted.
    case uncommitted
    /// The Stop fence is in force. Only a newer explicit Start can clear it.
    case stopFenced = "stop_fenced"
    /// A required commit did not verify, so no apply follows it.
    case commitFailed = "commit_failed"
    /// The runtime write was not attempted because the required platform step did not verify.
    case heldBehind = "held_behind"
    /// The workflow's intent generation is at its maximum, so this Start was not admitted.
    case intentExhausted = "intent_exhausted"
    /// A terminal stop has latched, so no Start is admitted again in this process (the quit policy).
    case terminating
    /// The saved input this Start captured at preparation no longer stands, so its remaining effects hold: a newer observation, write or
    /// intent changed it, or a refused reload or a lost baseline left the store without the baselines its receipts name. It is not rebound
    /// or retried (decision 0037).
    case inputReplaced = "input_replaced"
    /// DNS still owes a session Stop's disable save, which a facade Start may not displace, so the whole Start was refused at admission.
    case stopSaveOwed = "stop_save_owed"
    /// Another operation held the store's one slot when this Start's preparation began, so it captured no input and wrote nothing.
    case storeBusy = "store_busy"
    /// A lifecycle revision the request named moved since its caller observed it, so the whole request was refused at admission before any
    /// persistence or intent change (decision 0035).
    case staleRevision = "stale_revision"
}

/// `config.workflow.observed`: an open or a reload observed the inputs, and the store adopted or refused the observation.
package struct ConfigurationWorkflowObserved: Equatable, Sendable {
    package let phase: ConfigurationWorkflowObservationPhase
    package let observation: ConfigurationWorkflowObservation

    package init(phase: ConfigurationWorkflowObservationPhase, observation: ConfigurationWorkflowObservation) {
        self.phase = phase
        self.observation = observation
    }
}

/// `config.workflow.committed`: one file's write result from a required commit.
package struct ConfigurationWorkflowCommitted: Equatable, Sendable {
    package let file: ConfigurationWorkflowFile
    package let write: ConfigurationWorkflowWrite

    package init(file: ConfigurationWorkflowFile, write: ConfigurationWorkflowWrite) {
        self.file = file
        self.write = write
    }
}

/// `config.workflow.held`: an apply, a Start or a reload held its input. Only the combinations `isValid` admits can be built.
package struct ConfigurationWorkflowHeld: Equatable, Sendable {
    package let phase: ConfigurationWorkflowIntentPhase
    package let input: ConfigurationWorkflowHeldInput
    package let reason: ConfigurationWorkflowHoldReason

    /// The combinations the workflow produces. A Stop fence holds the whole unit in a Start or a reload, a held runtime write belongs to
    /// a Start, and an exhausted generation refuses a Start for the whole unit. The Stop phase holds only the runtime-only disable save a
    /// busy store slot kept from running.
    package static func isValid(
        phase: ConfigurationWorkflowIntentPhase,
        input: ConfigurationWorkflowHeldInput,
        reason: ConfigurationWorkflowHoldReason
    ) -> Bool {
        switch reason {
        case .stopFenced: phase != .stop && input == .unit
        case .heldBehind: phase == .start && input == .runtime
        case .commitFailed: phase == .start
        case .intentExhausted: phase == .start && input == .unit
        case .startBlocking: phase != .stop && input == .runtime
        case .uncommitted: phase == .reload && input == .unit
        case .terminating: phase == .start && input == .unit
        case .inputReplaced: phase == .start && input == .unit
        case .stopSaveOwed: phase == .start && input == .unit
        case .storeBusy: (phase == .start && input == .unit) || (phase == .stop && input == .runtime)
        case .staleRevision: phase == .start && input == .unit
        }
    }

    package init(phase: ConfigurationWorkflowIntentPhase, input: ConfigurationWorkflowHeldInput, reason: ConfigurationWorkflowHoldReason) {
        precondition(Self.isValid(phase: phase, input: input, reason: reason), "a hold reason is produced only for its own input and phase")
        self.phase = phase
        self.input = input
        self.reason = reason
    }
}

/// `config.workflow.superseded`: a Start or a reload stopped because a newer intent was admitted after it. A reload may have captured
/// generation 0, before any Start or Stop was admitted, so its floor is 0; a Start is always admitted at 1 or more.
package struct ConfigurationWorkflowSuperseded: Equatable, Sendable {
    package let phase: ConfigurationWorkflowIntentPhase
    /// The intent generation the operation captured or was admitted under.
    package let generation: Int
    /// The workflow's latest generation when the operation stopped. Strictly newer than `generation`.
    package let current: Int

    /// A Stop is never superseded.
    package static func isValid(phase: ConfigurationWorkflowIntentPhase, generation: Int, current: Int) -> Bool {
        phase != .stop && (phase == .start ? generation >= 1 : generation >= 0) && current > generation
    }

    package init(phase: ConfigurationWorkflowIntentPhase, generation: Int, current: Int) {
        precondition(
            Self.isValid(phase: phase, generation: generation, current: current),
            "a superseded generation is older than current, and a start's is at least 1"
        )
        self.phase = phase
        self.generation = generation
        self.current = current
    }
}

package enum ConfigurationWorkflowEventName: String, Sendable, CaseIterable {
    case observed = "config.workflow.observed"
    case committed = "config.workflow.committed"
    case held = "config.workflow.held"
    case superseded = "config.workflow.superseded"
}

package enum ConfigurationWorkflowEvent: Equatable, Sendable {
    case observed(ConfigurationWorkflowObserved)
    case committed(ConfigurationWorkflowCommitted)
    case held(ConfigurationWorkflowHeld)
    case superseded(ConfigurationWorkflowSuperseded)

    /// The stable event name.
    package var name: String {
        switch self {
        case .observed: ConfigurationWorkflowEventName.observed.rawValue
        case .committed: ConfigurationWorkflowEventName.committed.rawValue
        case .held: ConfigurationWorkflowEventName.held.rawValue
        case .superseded: ConfigurationWorkflowEventName.superseded.rawValue
        }
    }

    /// The human detail, derived from the typed fields. Every value is a closed raw value, a boolean or an integer.
    package var detail: String {
        switch self {
        case .observed(let event):
            switch event.observation {
            case .adopted:
                "phase=\(event.phase.rawValue) outcome=adopted"
            case .refused(let refusal):
                "phase=\(event.phase.rawValue) outcome=refused \(refusal.detail)"
            }
        case .committed(let event):
            "file=\(event.file.rawValue) \(event.write.detail)"
        case .held(let event):
            "phase=\(event.phase.rawValue) component=\(event.input.rawValue) reason=\(event.reason.rawValue)"
        case .superseded(let event):
            "phase=\(event.phase.rawValue) generation=\(event.generation) current=\(event.current)"
        }
    }
}

extension ConfigurationWorkflowRefusal {
    /// The closed refusal reason and, where the refusal names one, its file.
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

extension ConfigurationWorkflowWrite {
    /// The closed outcome and the closed cause that explains it. Never a raw error.
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

/// Wire layout is one flat object per event, with `type` first. `Codable` below validates each combination through the same
/// predicates the constructors check, so a malformed known value throws rather than becoming some other value.
extension ConfigurationWorkflowEvent: Codable {
    private enum WireType: String, Codable, CaseIterable {
        case observed
        case committed
        case held
        case superseded
    }

    private enum CodingKeys: String, CodingKey {
        case type, phase, component, outcome, reason, file, cause, reportedError = "reported_error", generation, current
    }

    private static func decodeRefusal(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ConfigurationWorkflowRefusal {
        switch try container.decode(String.self, forKey: .reason) {
        case "unreadable": .unreadable(try container.decode(ConfigurationWorkflowFile.self, forKey: .file))
        case "version_exhausted": .versionExhausted(try container.decode(ConfigurationWorkflowFile.self, forKey: .file))
        case "invalid_content": .invalidContent
        case "journal_presence_unknown": .journalPresenceUnknown
        case "unexpected": .unexpected
        case "busy": .busy
        default: throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "an unknown refusal reason")
        }
    }

    private static func encodeRefusal(_ refusal: ConfigurationWorkflowRefusal, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
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

    private static func decodeWrite(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ConfigurationWorkflowWrite {
        switch try container.decode(String.self, forKey: .outcome) {
        case "persisted": .persisted(reportedError: try container.decode(Bool.self, forKey: .reportedError))
        case "unchanged": .unchanged
        case "not_persisted": .notPersisted
        case "unknown": .unknown(
            try container.decode(ConfigurationWorkflowUnknownCause.self, forKey: .cause),
            reportedError: try container.decode(Bool.self, forKey: .reportedError)
        )
        case "conflict": .conflict
        case "not_attempted": .notAttempted(try container.decode(ConfigurationWorkflowNotAttemptedCause.self, forKey: .cause))
        default: throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "an unknown write outcome")
        }
    }

    private static func encodeWrite(_ write: ConfigurationWorkflowWrite, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
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

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .observed:
            let phase = try container.decode(ConfigurationWorkflowObservationPhase.self, forKey: .phase)
            let outcome = try container.decode(String.self, forKey: .outcome)
            let observation: ConfigurationWorkflowObservation
            switch outcome {
            case "adopted":
                guard !container.contains(.reason) else {
                    throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "an adopted observation has no reason")
                }
                observation = .adopted
            case "refused":
                observation = .refused(try Self.decodeRefusal(container))
            default:
                throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "an observation is adopted or refused")
            }
            self = .observed(ConfigurationWorkflowObserved(phase: phase, observation: observation))
        case .committed:
            let file = try container.decode(ConfigurationWorkflowFile.self, forKey: .file)
            self = .committed(ConfigurationWorkflowCommitted(file: file, write: try Self.decodeWrite(container)))
        case .held:
            let phase = try container.decode(ConfigurationWorkflowIntentPhase.self, forKey: .phase)
            let input = try container.decode(ConfigurationWorkflowHeldInput.self, forKey: .component)
            let reason = try container.decode(ConfigurationWorkflowHoldReason.self, forKey: .reason)
            guard ConfigurationWorkflowHeld.isValid(phase: phase, input: input, reason: reason) else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "a hold reason is produced only for its own input and phase")
            }
            self = .held(ConfigurationWorkflowHeld(phase: phase, input: input, reason: reason))
        case .superseded:
            let phase = try container.decode(ConfigurationWorkflowIntentPhase.self, forKey: .phase)
            let generation = try container.decode(Int.self, forKey: .generation)
            let current = try container.decode(Int.self, forKey: .current)
            guard ConfigurationWorkflowSuperseded.isValid(phase: phase, generation: generation, current: current) else {
                throw DecodingError.dataCorruptedError(forKey: .current, in: container, debugDescription: "a superseded generation is older than current, and a start's is at least 1")
            }
            self = .superseded(ConfigurationWorkflowSuperseded(phase: phase, generation: generation, current: current))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observed(let event):
            try container.encode(WireType.observed, forKey: .type)
            try container.encode(event.phase, forKey: .phase)
            switch event.observation {
            case .adopted:
                try container.encode("adopted", forKey: .outcome)
            case .refused(let refusal):
                try container.encode("refused", forKey: .outcome)
                try Self.encodeRefusal(refusal, into: &container)
            }
        case .committed(let event):
            try container.encode(WireType.committed, forKey: .type)
            try container.encode(event.file, forKey: .file)
            try Self.encodeWrite(event.write, into: &container)
        case .held(let event):
            try container.encode(WireType.held, forKey: .type)
            try container.encode(event.phase, forKey: .phase)
            try container.encode(event.input, forKey: .component)
            try container.encode(event.reason, forKey: .reason)
        case .superseded(let event):
            try container.encode(WireType.superseded, forKey: .type)
            try container.encode(event.phase, forKey: .phase)
            try container.encode(event.generation, forKey: .generation)
            try container.encode(event.current, forKey: .current)
        }
    }
}
