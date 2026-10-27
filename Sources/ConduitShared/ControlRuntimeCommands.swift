// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A runtime module a lifecycle command addresses.
package enum ControlModule: String, Codable, Sendable, Equatable, CaseIterable {
    case proxy
    case dns
    case tunnels
}

/// The discriminator of each command the v2 wire defines. A discriminator not
/// listed here is refused as an unknown command.
package enum ControlRuntimeCommandKind: String, Codable, Sendable, Equatable, CaseIterable {
    case stop
    case restart
    case testDNS = "test-dns"
    case testUpstream = "test-upstream"
    case refreshPreflight = "refresh-preflight"
    case setLaunchAtLogin = "set-launch-at-login"
    case quit
}

/// The final saves a Quit's reserved flush window admits (decision 0015): the runtime and platform save and the preferences save, each named
/// by the request ID the client minted for it before mapping, and each admitted once. Any other update after the latch, an older autosave or
/// another client's save, is not the reservation's and is refused as ordinary work. The two IDs differ, and the host refuses a Quit that
/// names its own ID. A nil part reserves nothing; none is reserved when the client has nothing unsaved.
package struct ControlQuitFlush: Codable, Sendable, Equatable {
    package let configuration: ControlRequestID?
    package let preferences: ControlRequestID?

    /// Throws `invalidValue` when both parts name the same request.
    package init(configuration: ControlRequestID?, preferences: ControlRequestID?) throws {
        if let configuration, configuration == preferences { throw ControlRuntimeWireError.invalidValue }
        self.configuration = configuration
        self.preferences = preferences
    }

    /// No reserved save.
    package static let none = try! ControlQuitFlush(configuration: nil, preferences: nil)

    private enum CodingKeys: String, CodingKey {
        case configuration
        case preferences
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                configuration: try container.decodeIfPresent(ControlRequestID.self, forKey: .configuration),
                preferences: try container.decodeIfPresent(ControlRequestID.self, forKey: .preferences)
            )
        } catch is ControlRuntimeWireError {
            throw DecodingError.dataCorruptedError(forKey: .preferences, in: container, debugDescription: "the two saves name one request")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(preferences, forKey: .preferences)
    }

    /// Whether either part names `requestID`.
    package func names(_ requestID: ControlRequestID) -> Bool {
        configuration == requestID || preferences == requestID
    }
}

/// An upstream named together with the configuration revision it belongs to, so
/// a test cannot silently run against a newer or older upstream list.
package struct ControlUpstreamReference: Codable, Sendable, Equatable {
    package var configRevision: ControlConfigRevision
    package var upstreamID: ControlUpstreamID

    package init(configRevision: ControlConfigRevision, upstreamID: ControlUpstreamID) {
        self.configRevision = configRevision
        self.upstreamID = upstreamID
    }
}

/// An explicit intent. Start and config apply are not defined on this wire yet:
/// their payloads wait for the source inventory and an owner checkpoint, and until
/// then a `start` discriminator is an unknown command.
package enum ControlRuntimeCommand: Codable, Sendable, Equatable {
    /// Stops one module for this session. Admission sets the session fence.
    case stop(ControlModule)
    /// Restarts one module only if the whole-host lifecycle revision still matches. `conditionalDNSRevision`, valid only for the proxy,
    /// asks for DNS's conditional companion (decision 0036) at the DNS revision the client observed; absent, the Restart has no companion,
    /// as before. A non-proxy Restart that names one is refused on decode and on encode.
    case restart(
        ControlModule,
        ifLifecycleRevision: ControlLifecycleRevision,
        conditionalDNSRevision: ControlLifecycleRevision? = nil
    )
    case testDNS
    case testUpstream(ControlUpstreamReference)
    case refreshPreflight
    /// The app's login-item administration (decision 0018): it saves only the platform file's `launchAtLogin`, under the exact platform
    /// baseline the client observed, and applies nothing. It carries no configuration value beyond the flag.
    case setLaunchAtLogin(Bool, ifPlatformBaseline: PrivateBaseline)
    /// The process quit (decision 0015). Admission latches the terminal stop and opens the reserved flush window for `flush`. `total` is the
    /// one remaining budget, counted from the Quit's admission, that the flush, the store join, the teardown and the diagnostic flush share: the
    /// operation completes when they end, or fails `cleanupIncomplete` at that deadline, while the work still runs and owns the root until
    /// it ends; the operation quiesces only then.
    case quit(total: ControlWireBudget, flush: ControlQuitFlush)

    package var kind: ControlRuntimeCommandKind {
        switch self {
        case .stop: .stop
        case .restart: .restart
        case .testDNS: .testDNS
        case .testUpstream: .testUpstream
        case .refreshPreflight: .refreshPreflight
        case .setLaunchAtLogin: .setLaunchAtLogin
        case .quit: .quit
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case module
        case lifecycleRevision
        case conditionalDNSRevision
        case upstream
        case enabled
        case baseline
        case totalMilliseconds
        case flush
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = ControlRuntimeCommandKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown command")
        }
        switch kind {
        case .stop:
            self = .stop(try container.decode(ControlModule.self, forKey: .module))
        case .restart:
            let module = try container.decode(ControlModule.self, forKey: .module)
            let companion = try container.decodeIfPresent(ControlLifecycleRevision.self, forKey: .conditionalDNSRevision)
            guard companion == nil || module == .proxy else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conditionalDNSRevision, in: container, debugDescription: "only a proxy restart has a DNS companion"
                )
            }
            self = .restart(
                module,
                ifLifecycleRevision: try container.decode(ControlLifecycleRevision.self, forKey: .lifecycleRevision),
                conditionalDNSRevision: companion
            )
        case .testDNS:
            self = .testDNS
        case .testUpstream:
            self = .testUpstream(try container.decode(ControlUpstreamReference.self, forKey: .upstream))
        case .refreshPreflight:
            self = .refreshPreflight
        case .setLaunchAtLogin:
            let baseline = try container.decode(PrivateBaseline.self, forKey: .baseline)
            guard baseline.component == .platform else {
                throw DecodingError.dataCorruptedError(forKey: .baseline, in: container, debugDescription: "the flag is the platform file's")
            }
            self = .setLaunchAtLogin(try container.decode(Bool.self, forKey: .enabled), ifPlatformBaseline: baseline)
        case .quit:
            self = .quit(
                total: try container.decode(ControlWireBudget.self, forKey: .totalMilliseconds),
                flush: try container.decode(ControlQuitFlush.self, forKey: .flush)
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .stop(let module):
            try container.encode(module, forKey: .module)
        case .restart(let module, let revision, let companion):
            guard companion == nil || module == .proxy else {
                throw EncodingError.invalidValue(module, .init(
                    codingPath: encoder.codingPath, debugDescription: "only a proxy restart has a DNS companion"
                ))
            }
            try container.encode(module, forKey: .module)
            try container.encode(revision, forKey: .lifecycleRevision)
            try container.encodeIfPresent(companion, forKey: .conditionalDNSRevision)
        case .testDNS, .refreshPreflight:
            break
        case .testUpstream(let reference):
            try container.encode(reference, forKey: .upstream)
        case .setLaunchAtLogin(let enabled, let baseline):
            guard baseline.component == .platform else {
                throw EncodingError.invalidValue(baseline, .init(codingPath: encoder.codingPath, debugDescription: "the flag is the platform file's"))
            }
            try container.encode(enabled, forKey: .enabled)
            try container.encode(baseline, forKey: .baseline)
        case .quit(let total, let flush):
            try container.encode(total, forKey: .totalMilliseconds)
            try container.encode(flush, forKey: .flush)
        }
    }
}

/// One submitted command. The expected incarnation is the host lifetime the caller
/// read its preconditions from; a host that restarted refuses the command rather than
/// applying an ordinal from the previous lifetime. The time the caller grants is the
/// request envelope's budget, not a field of the command.
package struct ControlOperationRequest: Codable, Sendable, Equatable {
    package var requestID: ControlRequestID
    package var expectedIncarnation: ControlHostIncarnation
    package var command: ControlRuntimeCommand

    package init(
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        command: ControlRuntimeCommand
    ) {
        self.requestID = requestID
        self.expectedIncarnation = expectedIncarnation
        self.command = command
    }
}

/// A lookup of one admitted operation's state or settled outcome, scoped to the
/// incarnation the caller admitted it in. A different incarnation answers
/// `changedIncarnation`, never the outcome of an unrelated operation.
package struct ControlOperationQuery: Codable, Sendable, Equatable {
    package var expectedIncarnation: ControlHostIncarnation
    package var operationID: ControlOperationID

    package init(expectedIncarnation: ControlHostIncarnation, operationID: ControlOperationID) {
        self.expectedIncarnation = expectedIncarnation
        self.operationID = operationID
    }
}

/// A lookup of the admission the host recorded for one request, used after an
/// `admissionUnknown` outcome when the caller never learned the operation ID. Scoped
/// to an incarnation like every other reference.
package struct ControlRequestQuery: Codable, Sendable, Equatable {
    package var expectedIncarnation: ControlHostIncarnation
    package var requestID: ControlRequestID

    package init(expectedIncarnation: ControlHostIncarnation, requestID: ControlRequestID) {
        self.expectedIncarnation = expectedIncarnation
        self.requestID = requestID
    }
}

/// The result of one upstream probe, carried in a completed `test-upstream`.
package struct ControlUpstreamProbe: Codable, Sendable, Equatable {
    package var upstreamID: ControlUpstreamID
    package var name: String
    package var endpoint: String
    package var reachable: Bool
    package var latencyMilliseconds: ControlCount
    /// The notices of `name` and `endpoint`, in canonical order.
    package var displayNotices: [ControlDisplayNotice]

    package init(
        upstreamID: ControlUpstreamID,
        name: String,
        endpoint: String,
        reachable: Bool,
        latencyMilliseconds: ControlCount,
        displayNotices: [ControlDisplayNotice] = []
    ) {
        self.upstreamID = upstreamID
        self.name = name
        self.endpoint = endpoint
        self.reachable = reachable
        self.latencyMilliseconds = latencyMilliseconds
        self.displayNotices = displayNotices
    }
}

/// The result of a single DNS liveness probe on the local resolver. `answered` is the
/// probe's own reading: it says whether the port replied, not whether DNS is healthy.
package struct ControlDNSLivenessProbe: Codable, Sendable, Equatable {
    package var port: ControlPort
    package var answered: Bool

    package init(port: ControlPort, answered: Bool) {
        self.port = port
        self.answered = answered
    }
}

/// The value a settled command reports beyond its settled revision. Each command has
/// exactly one result kind, which `ControlCompletion` enforces. `settled` belongs only
/// to lifecycle commands, whose result is the revision they settle at; no command
/// reports a generic success in place of its observation.
package enum ControlCommandResult: Codable, Sendable, Equatable {
    case settled
    case upstreamProbe(ControlUpstreamProbe)
    case dnsLiveness(ControlDNSLivenessProbe)
    case preflight(ControlPreflightObservation)
    /// A login-item administration's platform write, with the new verified baseline only when it verified.
    case platformWrite(ControlComponentWrite)

    private enum CodingKeys: String, CodingKey {
        case type
        case probe
        case liveness
        case observation
        case write
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "settled":
            self = .settled
        case "upstream-probe":
            self = .upstreamProbe(try container.decode(ControlUpstreamProbe.self, forKey: .probe))
        case "dns-liveness":
            self = .dnsLiveness(try container.decode(ControlDNSLivenessProbe.self, forKey: .liveness))
        case "preflight":
            self = .preflight(try container.decode(ControlPreflightObservation.self, forKey: .observation))
        case "platform-write":
            self = .platformWrite(try container.decode(ControlComponentWrite.self, forKey: .write))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown result")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .settled:
            try container.encode("settled", forKey: .type)
        case .upstreamProbe(let probe):
            try container.encode("upstream-probe", forKey: .type)
            try container.encode(probe, forKey: .probe)
        case .dnsLiveness(let probe):
            try container.encode("dns-liveness", forKey: .type)
            try container.encode(probe, forKey: .liveness)
        case .preflight(let observation):
            try container.encode("preflight", forKey: .type)
            try container.encode(observation, forKey: .observation)
        case .platformWrite(let write):
            try container.encode("platform-write", forKey: .type)
            try container.encode(write, forKey: .write)
        }
    }
}
