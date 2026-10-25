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
    /// Restarts one module only if the lifecycle revision still matches.
    case restart(ControlModule, ifLifecycleRevision: ControlLifecycleRevision)
    case testDNS
    case testUpstream(ControlUpstreamReference)
    case refreshPreflight

    package var kind: ControlRuntimeCommandKind {
        switch self {
        case .stop: .stop
        case .restart: .restart
        case .testDNS: .testDNS
        case .testUpstream: .testUpstream
        case .refreshPreflight: .refreshPreflight
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case module
        case lifecycleRevision
        case upstream
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
            self = .restart(
                try container.decode(ControlModule.self, forKey: .module),
                ifLifecycleRevision: try container.decode(ControlLifecycleRevision.self, forKey: .lifecycleRevision)
            )
        case .testDNS:
            self = .testDNS
        case .testUpstream:
            self = .testUpstream(try container.decode(ControlUpstreamReference.self, forKey: .upstream))
        case .refreshPreflight:
            self = .refreshPreflight
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .stop(let module):
            try container.encode(module, forKey: .module)
        case .restart(let module, let revision):
            try container.encode(module, forKey: .module)
            try container.encode(revision, forKey: .lifecycleRevision)
        case .testDNS, .refreshPreflight:
            break
        case .testUpstream(let reference):
            try container.encode(reference, forKey: .upstream)
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

    private enum CodingKeys: String, CodingKey {
        case type
        case probe
        case liveness
        case observation
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
        }
    }
}
