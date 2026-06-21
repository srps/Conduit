// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum HelperProtocolVersion {
    public static let current = 3
}

public enum HelperCommand: String, Codable, Sendable, CaseIterable {
    case applyDNS = "apply-dns"
    case removeDNS = "remove-dns"
    case applySystemProxy = "apply-system-proxy"
    case clearSystemProxy = "clear-system-proxy"
    case setProxyBypass = "set-proxy-bypass"
    case setAutoproxyURL = "set-autoproxy-url"
    case disableAutoproxy = "disable-autoproxy"
    case setDNSServers = "set-dns-servers"
    case startDNSRelay = "start-dns-relay"
    case stopDNSRelay = "stop-dns-relay"
    case startTCPRelay = "start-tcp-relay"
    case stopTCPRelay = "stop-tcp-relay"
    case ping = "ping"
}

public enum HelperInputValidator {
    private static let domainRegex = try! NSRegularExpression(
        pattern: #"^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$"#
    )
    private static let ipv6Regex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F:]+$"#
    )
    private static let serviceNameRegex = try! NSRegularExpression(
        pattern: #"^[a-zA-Z0-9 \-_\(\)\./]+$"#
    )

    public static func validateDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let range = NSRange(domain.startIndex..<domain.endIndex, in: domain)
        return domainRegex.firstMatch(in: domain, range: range) != nil
    }

    public static func validateIPAddress(_ address: String) -> Bool {
        if validateIPv4Address(address) { return true }
        let range = NSRange(address.startIndex..<address.endIndex, in: address)
        return ipv6Regex.firstMatch(in: address, range: range) != nil
    }

    public static func validateServiceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return serviceNameRegex.firstMatch(in: name, range: range) != nil
    }

    public static func validatePort(_ port: String) -> Bool {
        guard let p = Int(port), p >= 1, p <= 65535 else { return false }
        return true
    }

    public static func validateAutoproxyURL(_ url: String) -> Bool {
        guard url.count <= 2_048, !containsControlCharacters(url) else { return false }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              parsed.host != nil,
              parsed.user == nil,
              parsed.password == nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func validatePort(_ port: Int) -> Bool {
        port >= 1 && port <= 65535
    }

    public static func validateRelayBindHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "127.44.3.0"
    }

    private static func validateIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = Int(part) else {
                return false
            }
            return (0...255).contains(octet)
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var command: HelperCommand
    public var values: [String]

    public init(
        protocolVersion: Int = HelperProtocolVersion.current,
        command: HelperCommand,
        values: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.values = values
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case command
        case values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        command = try container.decode(HelperCommand.self, forKey: .command)
        values = try container.decodeIfPresent([String].self, forKey: .values) ?? []
    }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var success: Bool
    public var errorMessage: String?
    public var exitCode: Int32?
    public var standardOutput: String?
    public var standardError: String?

    public static func ok() -> HelperResponse {
        HelperResponse(protocolVersion: HelperProtocolVersion.current, success: true)
    }

    public static func error(_ message: String) -> HelperResponse {
        HelperResponse(protocolVersion: HelperProtocolVersion.current, success: false, errorMessage: message)
    }

    public static func scriptResult(exitCode: Int32, stdout: String, stderr: String) -> HelperResponse {
        HelperResponse(
            protocolVersion: HelperProtocolVersion.current,
            success: exitCode == 0,
            errorMessage: exitCode == 0 ? nil : "Script exited with code \(exitCode)",
            exitCode: exitCode,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    public init(
        protocolVersion: Int = HelperProtocolVersion.current,
        success: Bool,
        errorMessage: String? = nil,
        exitCode: Int32? = nil,
        standardOutput: String? = nil,
        standardError: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.success = success
        self.errorMessage = errorMessage
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case success
        case errorMessage
        case exitCode
        case standardOutput
        case standardError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? HelperProtocolVersion.current
        success = try container.decode(Bool.self, forKey: .success)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        standardOutput = try container.decodeIfPresent(String.self, forKey: .standardOutput)
        standardError = try container.decodeIfPresent(String.self, forKey: .standardError)
    }
}

public enum HelperConstants {
    public static let socketPath = "/var/run/io.github.srps.Conduit.Helper.sock"
    public static let binaryInstallPath = "/Library/PrivilegedHelperTools/io.github.srps.Conduit.Helper"
    public static let launchdPlistPath = "/Library/LaunchDaemons/io.github.srps.Conduit.Helper.plist"
    public static let serviceLabel = "io.github.srps.Conduit.Helper"
}
