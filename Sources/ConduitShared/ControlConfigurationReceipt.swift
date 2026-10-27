// SPDX-License-Identifier: Apache-2.0
import Foundation

// The causal settlement of one private editor update or saved Start (decisions 0015, 0018, 0025, 0035 and 0037). It carries safe facts
// only: the request and host it answers, each file's write result with the new verified baseline, the DNS bit the runtime file now
// holds, and each module's result. No configuration value or private URL is in it, so the ordinary lookup retains it like any outcome,
// and only the client that sent this request ID rebases a draft from it.

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

    /// Whether the new baseline, when there is one, is `file`'s.
    package func names(_ file: ControlConfigWorkflowFile) -> Bool {
        baseline.map { $0.component == file } ?? true
    }

    /// Whether this write can be the one conditional on `prior` in `file`: both baselines are `file`'s, and with no prior, which is a file
    /// the store held no baseline for, nothing verified.
    package func follows(_ prior: PrivateBaseline?, in file: ControlConfigWorkflowFile) -> Bool {
        names(file) && (prior.map { $0.component == file } ?? !write.isVerified)
    }
}

/// The runtime file's write from a session DNS Stop's disable save (decision 0015): the exact baseline the write was conditional on, and
/// the write with its new baseline only when it verified. It is a causal fact, not a refresh: only a draft whose runtime baseline is that
/// same `prior` may move it to the new one, and the DNS bit it then holds is false. A draft at any other baseline keeps its own, so a
/// write another client made in between still conflicts. `prior` is nil when the store held no runtime baseline, and then nothing was written.
package struct ControlDNSDisableWrite: Codable, Sendable, Equatable {
    package let prior: PrivateBaseline?
    package let runtime: ControlComponentWrite

    package init(prior: PrivateBaseline?, runtime: ControlComponentWrite) throws {
        guard runtime.follows(prior, in: .runtime) else { throw ControlRuntimeWireError.invalidValue }
        self.prior = prior
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case prior
        case runtime
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                prior: try container.decodeIfPresent(PrivateBaseline.self, forKey: .prior),
                runtime: try container.decode(ControlComponentWrite.self, forKey: .runtime)
            )
        } catch is ControlRuntimeWireError {
            throw DecodingError.dataCorruptedError(forKey: .prior, in: container, debugDescription: "an inconsistent disable write")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(prior, forKey: .prior)
        try container.encode(runtime, forKey: .runtime)
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
        guard preferences.names(.preferences) else { throw ControlRuntimeWireError.invalidValue }
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

/// The exact baselines a saved Start's or Restart's commit was conditional on (decision 0037), taken in the store's slot in the same turn
/// its preparation captured the saved pair. Nil for a file the store held no baseline for, which was then not written.
package struct ControlCommitPrior: Codable, Sendable, Equatable {
    package let runtime: PrivateBaseline?
    package let platform: PrivateBaseline?

    package init(runtime: PrivateBaseline?, platform: PrivateBaseline?) {
        self.runtime = runtime
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case runtime
        case platform
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try container.decodeIfPresent(PrivateBaseline.self, forKey: .runtime)
        platform = try container.decodeIfPresent(PrivateBaseline.self, forKey: .platform)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(platform, forKey: .platform)
    }
}

/// The causal settlement of one private update, or of one saved Start or Restart whose preparation ran its commit. Only the client that
/// submitted `requestID` to `incarnation` may rebase a draft from it. A private update rebases only the draft it submitted: later local
/// edits stay. A saved command submitted no draft, so `prior` names what its writes were conditional on: a draft moves a file to its new
/// baseline only while it holds that file's prior exactly, and a draft at any other baseline keeps its own, so a write another client made
/// in between still conflicts.
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
    /// For a proxy Start that asked for DNS's conditional companion only: the companion's own closed result, kept apart from the members,
    /// so its no-op never reads as a DNS member's result. `superseded` when the Start ended before the companion ran. Nil when none was asked.
    package let conditionalDNS: ControlLifecycleConditionalDNSResult?
    /// For a saved Start or Restart only: the baselines its commit was conditional on. Nil for a private update, whose submitted baselines
    /// are its own.
    package let prior: ControlCommitPrior?

    package init(
        requestID: ControlRequestID,
        incarnation: ControlHostIncarnation,
        runtime: ControlComponentWrite,
        platform: ControlComponentWrite,
        committedDNSForwarderEnabled: Bool?,
        modules: [ControlModuleReceipt],
        applied: Bool? = nil,
        conditionalDNS: ControlLifecycleConditionalDNSResult? = nil,
        prior: ControlCommitPrior? = nil
    ) throws {
        guard runtime.names(.runtime), platform.names(.platform),
              prior.map({ runtime.follows($0.runtime, in: .runtime) && platform.follows($0.platform, in: .platform) }) ?? true,
              (committedDNSForwarderEnabled != nil) == runtime.write.isVerified,
              modules.count <= ControlModule.allCases.count, Set(modules.map(\.module)).count == modules.count,
              conditionalDNS == nil || !modules.contains(where: { $0.module == .dns })
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
        self.conditionalDNS = conditionalDNS
        self.prior = prior
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case incarnation
        case runtime
        case platform
        case committedDNSForwarderEnabled
        case modules
        case applied
        case conditionalDNS
        case prior
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
                applied: try container.decodeIfPresent(Bool.self, forKey: .applied),
                conditionalDNS: try container.decodeIfPresent(ControlLifecycleConditionalDNSResult.self, forKey: .conditionalDNS),
                prior: try container.decodeIfPresent(ControlCommitPrior.self, forKey: .prior)
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
        try container.encodeIfPresent(conditionalDNS, forKey: .conditionalDNS)
        try container.encodeIfPresent(prior, forKey: .prior)
    }
}
