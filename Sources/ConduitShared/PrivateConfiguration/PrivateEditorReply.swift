// SPDX-License-Identifier: Apache-2.0
import Foundation

// The editor's read and the host's private answers (decisions 0014, 0018 and 0034). A read asks for one coherent memory
// observation. An update (`PrivateConfigurationRequest`) is answered by its admission only: accepted, joined or rejected.
// Settlement is a separate answer, found through the ordinary request and operation lookups, so a lost admission is
// recovered by the request ID and never by re-sending values. The causal receipt that lets a client rebase a submitted
// draft is not defined here: it waits for the workflow that merges lifecycle intent into saves (see the codec notes).
//
// Every answer is correlated: it names the request it answers and the host incarnation that answered. Like the other
// private values these are not `Codable`, and every type that holds a configuration value redacts its reflection.

// MARK: - Preferences

/// The fields of `AppPreferences`. `preferredBrowserTestURL` may carry a token.
package struct PrivatePreferences: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    package var showMenuBarIcon: Bool
    package var floatingWindowEnabled: Bool
    package var globalShortcutEnabled: Bool
    package var preferredBrowserTestURL: PrivateURLValue
    package var fileLoggingEnabled: Bool
    package var automaticUpdateChecks: Bool

    package init(
        showMenuBarIcon: Bool, floatingWindowEnabled: Bool, globalShortcutEnabled: Bool,
        preferredBrowserTestURL: PrivateURLValue, fileLoggingEnabled: Bool, automaticUpdateChecks: Bool
    ) {
        self.showMenuBarIcon = showMenuBarIcon
        self.floatingWindowEnabled = floatingWindowEnabled
        self.globalShortcutEnabled = globalShortcutEnabled
        self.preferredBrowserTestURL = preferredBrowserTestURL
        self.fileLoggingEnabled = fileLoggingEnabled
        self.automaticUpdateChecks = automaticUpdateChecks
    }

    package var description: String { "PrivatePreferences(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

// MARK: - Observation

/// Why a component holds no baseline. Each is a closed fact the store latched; none carries a value.
package enum PrivateRetainedReason: String, Sendable, Equatable, CaseIterable {
    /// The last load was refused, so all three components hold their last values for display only.
    case observationRefused
    /// A write conflict, a verification that found a change, or a changed sidecar during preservation.
    case changedSinceBaseline
    /// A write whose read-back could not say which state the file is in.
    case writeUnknown
}

/// What the store holds for one component now. It is not a fresh per-component verification.
package enum PrivateComponentState: Sendable, Equatable {
    /// The store holds this baseline, and the file was present.
    case verified(PrivateBaseline)
    /// The store holds this baseline for an observed absence. The values are loader defaults or a legacy fallback.
    case absent(PrivateBaseline)
    /// No baseline. The values are the last known ones, for display only, and authorize no write.
    case retained(PrivateRetainedReason)

    /// The baseline a write may name, or nil when the store holds none.
    package var baseline: PrivateBaseline? {
        switch self {
        case .verified(let baseline), .absent(let baseline): baseline
        case .retained: nil
        }
    }
}

/// One value per configuration file, in a fixed shape.
package struct PrivateComponentSlots<Value: Sendable>: Sendable {
    package var runtime: Value
    package var platform: Value
    package var preferences: Value

    package init(runtime: Value, platform: Value, preferences: Value) {
        self.runtime = runtime
        self.platform = platform
        self.preferences = preferences
    }

    package subscript(component: ControlConfigWorkflowFile) -> Value {
        get {
            switch component {
            case .runtime: runtime
            case .platform: platform
            case .preferences: preferences
            }
        }
        set {
            switch component {
            case .runtime: runtime = newValue
            case .platform: platform = newValue
            case .preferences: preferences = newValue
            }
        }
    }
}

extension PrivateComponentSlots: Equatable where Value: Equatable {}

/// One module's current explicit lifecycle intent, as the host holds it: the revision a later apply or start names, the
/// selected enable intent and whether a Stop fence is in force. It is not a persisted value.
package struct PrivateModuleState: Sendable, Equatable {
    package var lifecycleRevision: ControlLifecycleRevision
    package var enabled: Bool
    package var fenced: Bool

    package init(lifecycleRevision: ControlLifecycleRevision, enabled: Bool, fenced: Bool) {
        self.lifecycleRevision = lifecycleRevision
        self.enabled = enabled
        self.fenced = fenced
    }
}

/// One coherent memory observation: the values, per-file baselines and per-module intent the host held in one owner turn.
/// It holds one full set of values. A client uses it to start or rebuild a clean draft; it never retokenizes a dirty
/// draft from it, because only the causal answer to that draft's own update may advance its baselines.
package struct PrivateEditorObservation: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// A terminal stop has latched, so no Start runs again in this host.
    package var terminal: Bool
    package var runtime: PrivateRuntimeConfiguration
    package var platform: PrivatePlatformConfiguration
    package var preferences: PrivatePreferences
    /// The stored login-item value. It is app administration, read-only here: an update never carries it.
    package var launchAtLogin: Bool
    /// Always matched to their slots: the initializer refuses a baseline that names another file.
    package private(set) var components: PrivateComponentSlots<PrivateComponentState>
    package var modules: PrivateModuleSlots<PrivateModuleState>

    /// Throws `invalidValue` when a component's baseline names another file than its slot.
    package init(
        terminal: Bool, runtime: PrivateRuntimeConfiguration, platform: PrivatePlatformConfiguration,
        preferences: PrivatePreferences, launchAtLogin: Bool,
        components: PrivateComponentSlots<PrivateComponentState>, modules: PrivateModuleSlots<PrivateModuleState>
    ) throws {
        for component in ControlConfigWorkflowFile.allCases {
            if let baseline = components[component].baseline, baseline.component != component {
                throw PrivateConfigurationWireError.invalidValue
            }
        }
        self.terminal = terminal
        self.runtime = runtime
        self.platform = platform
        self.preferences = preferences
        self.launchAtLogin = launchAtLogin
        self.components = components
        self.modules = modules
    }

    /// Baselines and lifecycle state only. The values never appear in a description.
    package var description: String {
        "PrivateEditorObservation(terminal: \(terminal), components: \(components), modules: \(modules), <redacted values>)"
    }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

// MARK: - Read

/// A request for one observation. It carries no value, so its reflection is not redacted.
package struct PrivateEditorReadRequest: Sendable, Equatable {
    package var requestID: ControlRequestID
    package var incarnation: ControlHostIncarnation
    package var budget: ControlWireBudget

    package init(requestID: ControlRequestID, incarnation: ControlHostIncarnation, budget: ControlWireBudget) {
        self.requestID = requestID
        self.incarnation = incarnation
        self.budget = budget
    }
}

// MARK: - Reply

/// The one answer a reply carries. An update is answered by `admission` only; a read by `observation` or `refused`.
package enum PrivateEditorAnswer: Sendable, Equatable {
    /// The admission of an update. It names the operation to observe, or why none exists. It is never settlement.
    case admission(ControlAdmission)
    /// The observation a read asked for.
    case observation(PrivateEditorObservation)
    /// Why a read was not served. A read admits no operation, so its refusal is not an admission.
    case refused(ControlRejectionCode)
}

/// One private answer from the host, correlated with the request it answers. `requestID` echoes that request, and
/// `hostIncarnation` is the incarnation that answered, which differs from the request's only when the answer says so.
package struct PrivateEditorReply: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    package var requestID: ControlRequestID
    package var hostIncarnation: ControlHostIncarnation
    package var answer: PrivateEditorAnswer

    package init(requestID: ControlRequestID, hostIncarnation: ControlHostIncarnation, answer: PrivateEditorAnswer) {
        self.requestID = requestID
        self.hostIncarnation = hostIncarnation
        self.answer = answer
    }

    package var description: String {
        let answered = switch answer {
        case .admission(let admission): "admission: \(admission)"
        case .observation(let observation): "observation: \(observation)"
        case .refused(let code): "refused: \(code.rawValue)"
        }
        return "PrivateEditorReply(requestID: \(requestID), hostIncarnation: \(hostIncarnation), \(answered))"
    }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

/// Why a reply is not the answer to a client's request. A client drops such a reply; it never applies it to a draft.
package enum PrivateEditorReplyMismatch: Error, Sendable, Equatable {
    /// The reply answers another request ID.
    case otherRequest
    /// The reply comes from another host incarnation, and its answer does not say the incarnation changed.
    case otherIncarnation
    /// The answer is not one this kind of request can receive.
    case unpairedAnswer
}

extension PrivateEditorReply {
    /// The admission of `request`, when this reply answers it. Only an admission answers an update. Only a rejection for
    /// a changed incarnation may name another incarnation than the request's.
    package func admission(answering request: PrivateConfigurationRequest) throws -> ControlAdmission {
        guard case .admission(let admission) = answer else {
            throw PrivateEditorReplyMismatch.unpairedAnswer
        }
        try requireCorrelation(
            requestID: request.requestID, incarnation: request.incarnation,
            incarnationMayDiffer: admission == .rejected(.changedIncarnation)
        )
        return admission
    }

    /// The answer to `request`, when this reply answers it: an observation or a refusal, never an admission. Only a
    /// refusal for a changed incarnation may name another incarnation than the request's.
    package func answer(answering request: PrivateEditorReadRequest) throws -> PrivateEditorAnswer {
        let incarnationMayDiffer: Bool
        switch answer {
        case .admission:
            throw PrivateEditorReplyMismatch.unpairedAnswer
        case .observation:
            incarnationMayDiffer = false
        case .refused(let code):
            incarnationMayDiffer = code == .changedIncarnation
        }
        try requireCorrelation(
            requestID: request.requestID, incarnation: request.incarnation, incarnationMayDiffer: incarnationMayDiffer
        )
        return answer
    }

    private func requireCorrelation(
        requestID: ControlRequestID,
        incarnation: ControlHostIncarnation,
        incarnationMayDiffer: Bool
    ) throws {
        guard self.requestID == requestID else {
            throw PrivateEditorReplyMismatch.otherRequest
        }
        guard incarnationMayDiffer || hostIncarnation == incarnation else {
            throw PrivateEditorReplyMismatch.otherIncarnation
        }
    }
}
