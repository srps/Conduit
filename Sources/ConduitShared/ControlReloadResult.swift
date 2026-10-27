// SPDX-License-Identifier: Apache-2.0
import Foundation

/// An explicit reload's typed answer (decision 0032), the authoritative counterpart of its best-effort `config.workflow.*` events. It
/// reuses the workflow's closed refusal and hold vocabulary, and names no configuration value, path, baseline, token or generation, so
/// it grants no write authority: a client takes adopted values and their baselines only from a fresh private editor read.
package enum ControlReloadResult: Codable, Sendable, Equatable {
    /// Nothing was adopted: the store's one slot was busy, or the observation was refused whole. Every component keeps its last values.
    case refused(ControlConfigWorkflowRefusal)
    /// The store adopted this observation, the preferences among it. `apply` says what became of the runtime and platform inputs.
    case adopted(ControlReloadApply)

    private enum CodingKeys: String, CodingKey {
        case type, reason, file, apply, input, currentAtEnd
    }

    private enum WireType: String, Codable {
        case refused
        case adopted
    }

    private enum WireApply: String, Codable {
        case superseded
        case held
        case reconcileAttempted = "reconcile_attempted"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded: ControlReloadResult
        switch try container.decode(WireType.self, forKey: .type) {
        case .refused:
            let reason = try container.decode(String.self, forKey: .reason)
            guard let refusal = try ControlConfigWorkflowRefusal(
                wireReason: reason, file: { try container.decode(ControlConfigWorkflowFile.self, forKey: .file) }
            ) else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "an unknown refusal reason")
            }
            decoded = .refused(refusal)
        case .adopted:
            switch try container.decode(WireApply.self, forKey: .apply) {
            case .superseded:
                decoded = .adopted(.superseded)
            case .held:
                let input = try container.decode(ControlConfigWorkflowHeldInput.self, forKey: .input)
                let reason = try container.decode(ControlConfigWorkflowHoldReason.self, forKey: .reason)
                guard ControlConfigWorkflowEvent.isValidHeld(phase: .reload, input: input, reason: reason) else {
                    throw DecodingError.dataCorruptedError(forKey: .reason, in: container, debugDescription: "a reload never holds for this reason")
                }
                decoded = .adopted(.held(input, reason))
            case .reconcileAttempted:
                decoded = .adopted(.reconcileAttempted(currentAtEnd: try container.decode(Bool.self, forKey: .currentAtEnd)))
            }
        }
        // An unknown key is additive and ignored. A known key the decoded case does not carry belongs to another case, so the value is
        // inconsistent.
        guard Set(container.allKeys).isSubset(of: decoded.keys) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "a field of another reload result")
        }
        self = decoded
    }

    /// Refuses to write a hold that decoding would reject.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refused(let refusal):
            try container.encode(WireType.refused, forKey: .type)
            try container.encode(refusal.wireReason, forKey: .reason)
            try container.encodeIfPresent(refusal.file, forKey: .file)
        case .adopted(let apply):
            try container.encode(WireType.adopted, forKey: .type)
            switch apply {
            case .superseded:
                try container.encode(WireApply.superseded, forKey: .apply)
            case .held(let input, let reason):
                guard ControlConfigWorkflowEvent.isValidHeld(phase: .reload, input: input, reason: reason) else {
                    throw EncodingError.invalidValue(self, .init(
                        codingPath: encoder.codingPath, debugDescription: "a reload never holds for this reason"
                    ))
                }
                try container.encode(WireApply.held, forKey: .apply)
                try container.encode(input, forKey: .input)
                try container.encode(reason, forKey: .reason)
            case .reconcileAttempted(let currentAtEnd):
                try container.encode(WireApply.reconcileAttempted, forKey: .apply)
                try container.encode(currentAtEnd, forKey: .currentAtEnd)
            }
        }
    }

    /// Exactly the keys this case encodes.
    private var keys: Set<CodingKeys> {
        switch self {
        case .refused(let refusal):
            let keys: Set<CodingKeys> = [.type, .reason]
            return refusal.file == nil ? keys : keys.union([.file])
        case .adopted(.superseded):
            return [.type, .apply]
        case .adopted(.held):
            return [.type, .apply, .input, .reason]
        case .adopted(.reconcileAttempted):
            return [.type, .apply, .currentAtEnd]
        }
    }
}

/// What an adopted reload did to the runtime and platform inputs.
package enum ControlReloadApply: Sendable, Equatable {
    /// A newer Start or Stop was admitted during the read, so nothing applied. The observation stays the store's durable one.
    case superseded
    /// The applied view stays where it was, for the reason named; only pairs `isValidHeld(phase: .reload, …)` admits travel.
    case held(ControlConfigWorkflowHeldInput, ControlConfigWorkflowHoldReason)
    /// The host view adopted the observation, and one reconcile pass under this reload's admission was submitted and drained. That is
    /// an attempt, not proof that each effect landed: per-surface results stay in the snapshot and the reapply events. `currentAtEnd` is
    /// false when a newer intent or a Stop fence arrived before the drain ended, so the pass may have stopped early.
    case reconcileAttempted(currentAtEnd: Bool)
}
