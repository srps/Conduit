// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ControlProtocolVersion {
    public static let current = 1
}

public enum ControlCommand: String, Codable, Sendable, Equatable, CaseIterable {
    case diag
    case events
    case reload
    case setProfile = "set-profile"
    case start
    case status
    case stop
    case testUpstream = "test-upstream"
}

public enum ControlErrorCode: String, Codable, Sendable, Equatable {
    case daemonUnavailable = "daemon_unavailable"
    case internalError = "internal_error"
    case invalidRequest = "invalid_request"
    case missingArgument = "missing_argument"
    case notImplemented = "not_implemented"
    case unknownUpstream = "unknown_upstream"
    case unsupportedVersion = "unsupported_version"
}

public struct ControlRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var command: ControlCommand
    public var arguments: [String]

    public init(
        protocolVersion: Int = ControlProtocolVersion.current,
        command: ControlCommand,
        arguments: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case command
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        command = try container.decode(ControlCommand.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var success: Bool
    public var status: ControlDaemonStatus?
    public var upstreamTest: ControlUpstreamTestResult?
    public var errorCode: ControlErrorCode?
    public var errorMessage: String?

    public static func status(_ status: ControlDaemonStatus) -> ControlResponse {
        ControlResponse(success: true, status: status)
    }

    public static func ok() -> ControlResponse {
        ControlResponse(success: true)
    }

    public static func upstreamTest(_ result: ControlUpstreamTestResult) -> ControlResponse {
        ControlResponse(success: true, upstreamTest: result)
    }

    public static func error(_ code: ControlErrorCode, _ message: String) -> ControlResponse {
        ControlResponse(success: false, errorCode: code, errorMessage: message)
    }

    public static func error(_ message: String) -> ControlResponse {
        ControlResponse(success: false, errorCode: .internalError, errorMessage: message)
    }

    public init(
        protocolVersion: Int = ControlProtocolVersion.current,
        success: Bool,
        status: ControlDaemonStatus? = nil,
        upstreamTest: ControlUpstreamTestResult? = nil,
        errorCode: ControlErrorCode? = nil,
        errorMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.success = success
        self.status = status
        self.upstreamTest = upstreamTest
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public struct ControlDaemonMetadata: Codable, Sendable, Equatable {
    public var processID: Int
    public var executableName: String
    public var startedAt: Date?

    public init(
        processID: Int,
        executableName: String,
        startedAt: Date? = nil
    ) {
        self.processID = processID
        self.executableName = executableName
        self.startedAt = startedAt
    }
}

public struct ControlDaemonStatus: Codable, Sendable, Equatable {
    public var daemon: ControlDaemonMetadata?
    public var configGeneration: Int
    public var profileName: String
    public var state: String
    public var activeUpstream: String?
    public var healthSummary: String
    public var directModeCause: String
    public var isDirectMode: Bool
    public var bindings: ControlBindings
    public var metrics: ControlMetrics
    public var dnsRunState: String
    public var dnsQueryCount: Int
    public var dnsCacheHitCount: Int
    public var tunnelsRunState: String
    public var tunnelActiveCount: Int
    public var tunnelSessionCount: Int
    public var lastAuthOutcome: String?
    public var lastAuthFallbackReason: String?

    private enum CodingKeys: String, CodingKey {
        case daemon
        case configGeneration
        case profileName
        case state
        case activeUpstream
        case healthSummary
        case directModeCause
        case isDirectMode
        case bindings
        case metrics
        case dnsRunState
        case dnsQueryCount
        case dnsCacheHitCount
        case tunnelsRunState
        case tunnelActiveCount
        case tunnelSessionCount
        case lastAuthOutcome
        case lastAuthFallbackReason
    }

    public init(
        daemon: ControlDaemonMetadata? = nil,
        configGeneration: Int = 0,
        profileName: String,
        state: String,
        activeUpstream: String? = nil,
        healthSummary: String,
        directModeCause: String,
        isDirectMode: Bool,
        bindings: ControlBindings,
        metrics: ControlMetrics,
        dnsRunState: String,
        dnsQueryCount: Int,
        dnsCacheHitCount: Int,
        tunnelsRunState: String,
        tunnelActiveCount: Int,
        tunnelSessionCount: Int,
        lastAuthOutcome: String? = nil,
        lastAuthFallbackReason: String? = nil
    ) {
        self.daemon = daemon
        self.configGeneration = configGeneration
        self.profileName = profileName
        self.state = state
        self.activeUpstream = activeUpstream
        self.healthSummary = healthSummary
        self.directModeCause = directModeCause
        self.isDirectMode = isDirectMode
        self.bindings = bindings
        self.metrics = metrics
        self.dnsRunState = dnsRunState
        self.dnsQueryCount = dnsQueryCount
        self.dnsCacheHitCount = dnsCacheHitCount
        self.tunnelsRunState = tunnelsRunState
        self.tunnelActiveCount = tunnelActiveCount
        self.tunnelSessionCount = tunnelSessionCount
        self.lastAuthOutcome = lastAuthOutcome
        self.lastAuthFallbackReason = lastAuthFallbackReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            daemon: try container.decodeIfPresent(ControlDaemonMetadata.self, forKey: .daemon),
            configGeneration: try container.decodeIfPresent(Int.self, forKey: .configGeneration) ?? 0,
            profileName: try container.decode(String.self, forKey: .profileName),
            state: try container.decode(String.self, forKey: .state),
            activeUpstream: try container.decodeIfPresent(String.self, forKey: .activeUpstream),
            healthSummary: try container.decode(String.self, forKey: .healthSummary),
            directModeCause: try container.decode(String.self, forKey: .directModeCause),
            isDirectMode: try container.decode(Bool.self, forKey: .isDirectMode),
            bindings: try container.decode(ControlBindings.self, forKey: .bindings),
            metrics: try container.decode(ControlMetrics.self, forKey: .metrics),
            dnsRunState: try container.decode(String.self, forKey: .dnsRunState),
            dnsQueryCount: try container.decode(Int.self, forKey: .dnsQueryCount),
            dnsCacheHitCount: try container.decode(Int.self, forKey: .dnsCacheHitCount),
            tunnelsRunState: try container.decode(String.self, forKey: .tunnelsRunState),
            tunnelActiveCount: try container.decode(Int.self, forKey: .tunnelActiveCount),
            tunnelSessionCount: try container.decode(Int.self, forKey: .tunnelSessionCount),
            lastAuthOutcome: try container.decodeIfPresent(String.self, forKey: .lastAuthOutcome),
            lastAuthFallbackReason: try container.decodeIfPresent(String.self, forKey: .lastAuthFallbackReason)
        )
    }
}

public struct ControlBindings: Codable, Sendable, Equatable {
    public var proxyHost: String?
    public var proxyPort: Int?
    public var socksHost: String?
    public var socksPort: Int?
    public var localPACHost: String?
    public var localPACPort: Int?
    public var dnsHost: String?
    public var dnsPort: Int?

    public init(
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        localPACHost: String? = nil,
        localPACPort: Int? = nil,
        dnsHost: String? = nil,
        dnsPort: Int? = nil
    ) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.localPACHost = localPACHost
        self.localPACPort = localPACPort
        self.dnsHost = dnsHost
        self.dnsPort = dnsPort
    }
}

public struct ControlMetrics: Codable, Sendable, Equatable {
    public var requestsHandled: Int
    public var failedRequests: Int
    public var openConnections: Int
    public var inboundConnections: Int
    public var successfulRecoveries: Int

    public init(
        requestsHandled: Int,
        failedRequests: Int,
        openConnections: Int,
        inboundConnections: Int,
        successfulRecoveries: Int
    ) {
        self.requestsHandled = requestsHandled
        self.failedRequests = failedRequests
        self.openConnections = openConnections
        self.inboundConnections = inboundConnections
        self.successfulRecoveries = successfulRecoveries
    }
}

public struct ControlUpstreamTestResult: Codable, Sendable, Equatable {
    public var name: String
    public var endpoint: String
    public var reachable: Bool
    public var latencyMS: Int

    public init(
        name: String,
        endpoint: String,
        reachable: Bool,
        latencyMS: Int
    ) {
        self.name = name
        self.endpoint = endpoint
        self.reachable = reachable
        self.latencyMS = latencyMS
    }
}

public enum ControlSocket {
    public static let fileName = "control.sock"
    public static let maxFrameBytes = 16 * 1024

    public static func path(in stateDirectory: URL) -> String {
        stateDirectory.appendingPathComponent(fileName).path
    }
}

public struct ControlRuntimeEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var kind: String
    public var event: String
    public var detail: String?

    public init(
        timestamp: Date,
        kind: String,
        event: String,
        detail: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.event = event
        self.detail = detail
    }

    public var humanDescription: String {
        let stamp = Self.formatTimestamp(timestamp)
        if let detail, !detail.isEmpty {
            return "\(stamp) [\(kind)] \(event) \(detail)"
        }
        return "\(stamp) [\(kind)] \(event)"
    }

    private static func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: timestamp)
    }
}

public enum ControlEventLog {
    public static let fileName = "events.ndjson"

    public static func path(in stateDirectory: URL) -> String {
        stateDirectory.appendingPathComponent(fileName).path
    }
}
