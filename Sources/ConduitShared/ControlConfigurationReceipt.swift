// SPDX-License-Identifier: Apache-2.0
import Foundation

// The causal settlement of one private editor update (decisions 0015, 0018, 0025 and 0035). It carries safe facts only: the
// request and host it answers, each file's write result with the new verified baseline, the DNS bit the runtime file now holds,
// and each module's result. No configuration value or private URL is in it, so the ordinary lookup retains it like any outcome,
// and a client rebases only the draft it submitted under this request ID.

/// The ordinary-wire form of a store baseline: the same members as the private codec writes, with the version as an exact `UInt64`
/// number. It holds no configuration value.
extension PrivateBaseline: Codable {
    private enum CodingKeys: String, CodingKey {
        case namespace
        case component
        case version
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try container.decode(PrivateBaselineNamespace.self, forKey: .namespace),
            component: try container.decode(ControlConfigWorkflowFile.self, forKey: .component),
            version: try container.decode(UInt64.self, forKey: .version)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(component, forKey: .component)
        try container.encode(version, forKey: .version)
    }
}

extension ControlConfigWorkflowWrite: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case cause
        case reportedError
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "persisted": self = .persisted(reportedError: try container.decode(Bool.self, forKey: .reportedError))
        case "unchanged": self = .unchanged
        case "not_persisted": self = .notPersisted
        case "unknown":
            self = .unknown(
                try container.decode(ControlConfigWorkflowUnknownCause.self, forKey: .cause),
                reportedError: try container.decode(Bool.self, forKey: .reportedError)
            )
        case "conflict": self = .conflict
        case "not_attempted": self = .notAttempted(try container.decode(ControlConfigWorkflowNotAttemptedCause.self, forKey: .cause))
        default:
            throw DecodingError.dataCorruptedError(forKey: .outcome, in: container, debugDescription: "an unknown write outcome")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .persisted(let reported):
            try container.encode("persisted", forKey: .outcome)
            try container.encode(reported, forKey: .reportedError)
        case .unchanged:
            try container.encode("unchanged", forKey: .outcome)
        case .notPersisted:
            try container.encode("not_persisted", forKey: .outcome)
        case .unknown(let cause, let reported):
            try container.encode("unknown", forKey: .outcome)
            try container.encode(cause, forKey: .cause)
            try container.encode(reported, forKey: .reportedError)
        case .conflict:
            try container.encode("conflict", forKey: .outcome)
        case .notAttempted(let cause):
            try container.encode("not_attempted", forKey: .outcome)
            try container.encode(cause, forKey: .cause)
        }
    }

    /// Whether the file's current verified bytes are the candidate, by a save or by verification alone.
    package var isVerified: Bool {
        switch self {
        case .persisted, .unchanged: true
        case .notPersisted, .unknown, .conflict, .notAttempted: false
        }
    }
}

/// One file's result: its write, and the new verified baseline only when the write verified.
package struct ControlComponentWrite: Codable, Sendable, Equatable {
    package let write: ControlConfigWorkflowWrite
    package let baseline: PrivateBaseline?

    package init(write: ControlConfigWorkflowWrite, baseline: PrivateBaseline?) throws {
        guard write.isVerified == (baseline != nil) else { throw ControlRuntimeWireError.invalidValue }
        self.write = write
        self.baseline = baseline
    }

    private enum CodingKeys: String, CodingKey {
        case write
        case baseline
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                write: try container.decode(ControlConfigWorkflowWrite.self, forKey: .write),
                baseline: try container.decodeIfPresent(PrivateBaseline.self, forKey: .baseline)
            )
        } catch is ControlRuntimeWireError {
            throw DecodingError.dataCorruptedError(forKey: .baseline, in: container, debugDescription: "a baseline names only a verified write")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(write, forKey: .write)
        try container.encodeIfPresent(baseline, forKey: .baseline)
    }
}

/// One explicit member's result in an update's Start.
package struct ControlModuleReceipt: Codable, Sendable, Equatable {
    package let module: ControlModule
    package let result: ControlLifecycleModuleResult

    package init(module: ControlModule, result: ControlLifecycleModuleResult) {
        self.module = module
        self.result = result
    }
}

/// The causal settlement of one private preferences update: the preferences file's write, with its new baseline only when it verified.
/// Like the configuration receipt it carries no value, and only the client that submitted `requestID` rebases its preferences draft from it.
package struct ControlPreferencesReceipt: Codable, Sendable, Equatable {
    package let requestID: ControlRequestID
    package let incarnation: ControlHostIncarnation
    package let preferences: ControlComponentWrite

    package init(requestID: ControlRequestID, incarnation: ControlHostIncarnation, preferences: ControlComponentWrite) throws {
        guard preferences.baseline.map({ $0.component == .preferences }) ?? true else { throw ControlRuntimeWireError.invalidValue }
        self.requestID = requestID
        self.incarnation = incarnation
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case incarnation
        case preferences
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                requestID: try container.decode(ControlRequestID.self, forKey: .requestID),
                incarnation: try container.decode(ControlHostIncarnation.self, forKey: .incarnation),
                preferences: try container.decode(ControlComponentWrite.self, forKey: .preferences)
            )
        } catch is ControlRuntimeWireError {
            throw DecodingError.dataCorruptedError(forKey: .preferences, in: container, debugDescription: "a baseline of another file")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(preferences, forKey: .preferences)
    }
}

/// The causal settlement of one private update. Only the client that submitted `requestID` to `incarnation` may rebase a draft from it,
/// and only the draft it submitted: later local edits stay.
package struct ControlConfigurationReceipt: Codable, Sendable, Equatable {
    package let requestID: ControlRequestID
    package let incarnation: ControlHostIncarnation
    package let runtime: ControlComponentWrite
    package let platform: ControlComponentWrite
    /// The `forwarderEnabled` the runtime file holds after this update: the DNS lifecycle intent merged in its claim. Nil unless the runtime
    /// file verified.
    package let committedDNSForwarderEnabled: Bool?
    /// Each explicit Start member's result, in module order, at most one per module. Empty for a save.
    package let modules: [ControlModuleReceipt]
    /// For an apply-while-running update only: whether the runtime's applied input is now its verified pair. Nil when none was asked. True
    /// says the runtime took the input, not that every listener came up: a failed one shows in the snapshot and its lifecycle state. False
    /// means the runtime did not take the whole pair: a named module stopped, moved or went down before the pass completed (its runtime input
    /// may already be held, as the snapshot shows), a flag action did not land, or the pair did not verify.
    package let applied: Bool?

    package init(
        requestID: ControlRequestID,
        incarnation: ControlHostIncarnation,
        runtime: ControlComponentWrite,
        platform: ControlComponentWrite,
        committedDNSForwarderEnabled: Bool?,
        modules: [ControlModuleReceipt],
        applied: Bool? = nil
    ) throws {
        guard runtime.baseline.map({ $0.component == .runtime }) ?? true,
              platform.baseline.map({ $0.component == .platform }) ?? true,
              (committedDNSForwarderEnabled != nil) == runtime.write.isVerified,
              modules.count <= ControlModule.allCases.count, Set(modules.map(\.module)).count == modules.count
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        self.requestID = requestID
        self.incarnation = incarnation
        self.runtime = runtime
        self.platform = platform
        self.committedDNSForwarderEnabled = committedDNSForwarderEnabled
        self.modules = modules
        self.applied = applied
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case incarnation
        case runtime
        case platform
        case committedDNSForwarderEnabled
        case modules
        case applied
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                requestID: try container.decode(ControlRequestID.self, forKey: .requestID),
                incarnation: try container.decode(ControlHostIncarnation.self, forKey: .incarnation),
                runtime: try container.decode(ControlComponentWrite.self, forKey: .runtime),
                platform: try container.decode(ControlComponentWrite.self, forKey: .platform),
                committedDNSForwarderEnabled: try container.decodeIfPresent(Bool.self, forKey: .committedDNSForwarderEnabled),
                modules: try container.decode([ControlModuleReceipt].self, forKey: .modules),
                applied: try container.decodeIfPresent(Bool.self, forKey: .applied)
            )
        } catch is ControlRuntimeWireError {
            throw DecodingError.dataCorruptedError(forKey: .modules, in: container, debugDescription: "an inconsistent receipt")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(committedDNSForwarderEnabled, forKey: .committedDNSForwarderEnabled)
        try container.encode(modules, forKey: .modules)
        try container.encodeIfPresent(applied, forKey: .applied)
    }
}
