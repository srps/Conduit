// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum HelperProtocolVersion {
    public static let current = 4

    /// Oldest request version the helper still honours.
    ///
    /// The helper outlives the app that installed it. Rolling the app back —
    /// or running an older build alongside — leaves a newer helper answering
    /// older clients, and those clients are already in the field with an
    /// exact-match guard on the response version: they reject anything that is
    /// not their own number and, because the mismatch surfaces as
    /// `communicationFailed`, they rethrow instead of degrading to AppleScript.
    /// A helper that spoke only its own version therefore bricked *every*
    /// privileged operation for a rolled-back app until the helper was
    /// uninstalled by hand.
    ///
    /// 3 is the floor because v3 and v4 differ only by *added* commands — no
    /// v3 command changed shape — so honouring a v3 frame costs nothing. A
    /// future version that changes an existing command's arguments must raise
    /// this floor rather than silently reinterpret them.
    public static let minimumSupported = 3

    public static func isSupported(_ version: Int) -> Bool {
        (minimumSupported...current).contains(version)
    }

    /// The version to stamp on a reply.
    ///
    /// Deliberately the *requester's* version, not ours: the whole point is to
    /// satisfy an older client's exact-match guard. Returns `nil` for a version
    /// outside the supported range, where the caller must answer with `current`
    /// instead — a client we are refusing should be told what we actually
    /// speak, so a genuine mismatch stays diagnosable rather than being
    /// papered over by echoing whatever it asked for.
    public static func replyVersion(forRequest version: Int) -> Int? {
        isSupported(version) ? version : nil
    }
}

public enum HelperCommand: String, Codable, Sendable, CaseIterable {
    case applyDNS = "apply-dns"
    case removeDNS = "remove-dns"
    case applySystemProxy = "apply-system-proxy"
    case clearSystemProxy = "clear-system-proxy"
    case setProxyBypass = "set-proxy-bypass"
    case setAutoproxyURL = "set-autoproxy-url"
    case disableAutoproxy = "disable-autoproxy"
    /// Writes one manual-proxy endpoint and its on/off state, in that order.
    /// Values: `service, kind ("web" | "secure"), host, port, state ("on" | "off")`.
    ///
    /// The host argument carries three instructions, on the pattern
    /// `setProxyBypass` and `setDNSServers` already use: empty (with an empty
    /// port) writes only the state, the `Empty` sentinel clears the address,
    /// and a host/port pair writes that address.
    ///
    /// All three are needed, and none is expressible through
    /// `applySystemProxy`. `networksetup` keeps host and port on a *disabled*
    /// proxy, so putting a user's endpoint back without switching it on is a
    /// real requirement; so is putting back an asymmetric pair (web and secure
    /// at different addresses, or only one of them enabled); and so is blanking
    /// the address on a service that had none before us, which otherwise keeps
    /// Conduit's own address in a field the user can re-enable by hand.
    case setWebProxyEndpoint = "set-web-proxy-endpoint"
    /// Writes the autoproxy URL and its on/off state, in that order.
    /// Values: `service, url, state ("on" | "off")`. An empty URL writes only
    /// the state.
    ///
    /// The ordering is load-bearing, which is why it lives inside one command
    /// rather than being left to the caller: `-setautoproxyurl` **enables**
    /// autoproxy as a side effect (verified on macOS 26; documented in neither
    /// `man networksetup` nor the usage string), so the state must be written
    /// last or restoring a configured-but-disabled URL silently switches the
    /// user's automatic proxy configuration on.
    case setAutoproxy = "set-autoproxy"
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
    /// Bypass entries are not domains. Real lists carry `*.local`,
    /// `169.254/16`, `.example.com` and bare addresses, none of which pass
    /// `validateDomain` — which is why this argument went unvalidated until
    /// now, the only helper input that did. The set below is what
    /// `networksetup` actually accepts, minus everything that could be read as
    /// something other than a host pattern.
    ///
    /// A leading `-` is rejected separately: these reach `networksetup` as
    /// argv, so an entry that looks like a flag is the one shape that changes
    /// what the command does.
    ///
    /// Brackets are in the set because bracketed IPv6 literals are: `[::1]` is
    /// in this product's own shipped `routing.noProxyHosts` default, and a
    /// validator that rejects the value the app applies out of the box fails
    /// every admin-required apply on a stock install. They are also what a
    /// captured prior list carries back into a restore, since the bypass list
    /// is read off the machine verbatim. Neither `[` nor `]` is a shell
    /// metacharacter that survives `shellQuoted`, and as argv they are inert.
    private static let proxyBypassEntryRegex = try! NSRegularExpression(
        pattern: #"^[a-zA-Z0-9*._:/\[\]\-]+$"#
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

    /// The sentinel that clears a list-valued setting. `networksetup` spells it
    /// `Empty` for bypass domains and `empty` for DNS servers; both are matched
    /// case-insensitively so callers need not care which surface they are on.
    public static let emptyListSentinel = "Empty"

    public static func isEmptyListSentinel(_ value: String) -> Bool {
        value.lowercased() == "empty"
    }

    public static func validateProxyBypassEntry(_ entry: String) -> Bool {
        guard !entry.isEmpty, entry.count <= 253, !entry.hasPrefix("-") else { return false }
        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
        return proxyBypassEntryRegex.firstMatch(in: entry, range: range) != nil
    }

    /// Which of the two manual-proxy endpoints a `setWebProxyEndpoint` targets.
    public static func validateWebProxyKind(_ kind: String) -> Bool {
        kind == "web" || kind == "secure"
    }

    public static func validateProxyState(_ state: String) -> Bool {
        state == "on" || state == "off"
    }

    /// An endpoint argument pair, which encodes three instructions:
    ///
    /// - both empty — leave the address alone, write only the state
    /// - host == `Empty`, port empty — clear the address
    /// - host and port both set — write that address
    ///
    /// Host and port otherwise travel together: `networksetup -setwebproxy`
    /// takes both or neither, and a half-specified pair would either be
    /// rejected by the tool or — worse, with a port of `0`, which is what
    /// `-getwebproxy` reports for a service that never had one — written as a
    /// live but unusable endpoint.
    public static func validateOptionalEndpoint(host: String, port: String) -> Bool {
        if host.isEmpty && port.isEmpty { return true }
        if isEmptyListSentinel(host) { return port.isEmpty }
        guard !host.isEmpty, !port.isEmpty else { return false }
        guard validateIPAddress(host) || validateDomain(host) else { return false }
        return validatePort(port)
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
