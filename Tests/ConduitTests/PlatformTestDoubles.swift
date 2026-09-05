// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

// The doubles the platform managers and both runtime hosts are tested
// against. One copy each: the suite used to carry a private recording
// privilege client per test file, and the host harness needs the same
// recorder plus a machine model behind it.

// MARK: - RecordingPrivilegeClient

/// Records every privileged operation in order and fails the ones it is told
/// to. Recording happens before the failure, so a test can see what was
/// attempted as well as what landed.
final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    /// The refusal a scripted failure throws. Names the domain when the
    /// operation carried one, because the resolver tests match on it.
    struct Refused: Error, LocalizedError {
        let operation: PrivilegedOperation
        let subject: String?
        var errorDescription: String? { "helper refused \(subject ?? operation.rawValue)" }
    }

    private let lock = NSLock()
    private var _commands: [(command: PrivilegedOperation, values: [String])] = []
    private var _batches: [[PrivilegedBatchStep]] = []
    private var _failing: Set<PrivilegedOperation> = []
    private var _failingDomains: Set<String> = []
    private let error: Error?

    /// - Parameter error: thrown by every call, for a client that is down
    ///   altogether (no helper installed, socket refused).
    init(error: Error? = nil) {
        self.error = error
    }

    /// Every operation, batched or not, in the order it was requested.
    var commands: [(command: PrivilegedOperation, values: [String])] {
        lock.withLock { _commands }
    }

    /// One entry per elevation, so a test can pin how many times a user
    /// would be prompted rather than only what was run.
    var batches: [[PrivilegedBatchStep]] {
        lock.withLock { _batches }
    }

    /// Operations that fail whatever their values.
    var failing: Set<PrivilegedOperation> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    /// Operations whose first value (the domain, for the resolver writes)
    /// is in this set fail, so a test can put a failure in the middle of a
    /// batch and see what the rest of it did.
    var failingDomains: Set<String> {
        get { lock.withLock { _failingDomains } }
        set { lock.withLock { _failingDomains = newValue } }
    }

    /// The value lists of every recorded `operation`.
    func commands(matching operation: PrivilegedOperation) -> [[String]] {
        commands.filter { $0.command == operation }.map(\.values)
    }

    func reset() {
        lock.withLock { _commands.removeAll(); _batches.removeAll() }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    func execute(batch: [PrivilegedBatchStep]) throws {
        let refusal: Error? = lock.withLock {
            _batches.append(batch)
            _commands.append(contentsOf: batch.map { ($0.operation, $0.values) })
            if let error { return error }
            for step in batch {
                if _failing.contains(step.operation) {
                    return Refused(operation: step.operation, subject: nil)
                }
                if let subject = step.values.first, _failingDomains.contains(subject) {
                    return Refused(operation: step.operation, subject: subject)
                }
            }
            return nil
        }
        if let refusal { throw refusal }
    }
}

// MARK: - FakeMachine

/// A described macOS machine standing in for the real one behind every
/// platform manager: it answers the `networksetup` and `launchctl` reads the
/// managers make and applies the privileged writes to its own model, so
/// `isApplied` / `isCleared` / `hasManagedState` read back what a scenario
/// actually did to it. Resolver files are written for real, into a scratch
/// directory, because `DNSManager` reads them straight off disk.
///
/// Unprivileged `networksetup` writes (the `/bin/sh` scripts) are refused
/// with the "requires admin" answer, so every write reaches the model
/// through the privilege client and is recorded there. That is also the
/// configuration a machine without admin rights presents.
final class FakeMachine: PrivilegeClient, @unchecked Sendable {
    struct ProxyEndpoint: Equatable {
        var enabled = false
        var host = ""
        var port = ""
    }

    struct Service: Equatable {
        var connected = true
        var webProxy = ProxyEndpoint()
        var secureWebProxy = ProxyEndpoint()
        var autoproxyURL = ""
        var autoproxyEnabled = false
        var bypassDomains: [String] = []
        var dnsServers: [String] = []

        /// Whether anything on the service routes traffic through a proxy.
        var routesThroughAProxy: Bool {
            webProxy.enabled || secureWebProxy.enabled || autoproxyEnabled
        }
    }

    /// Every privileged write, in order, and the failure switches.
    let privilege = RecordingPrivilegeClient()
    /// Where the resolver files land. Hand this to the manager under test.
    let resolverDirectory: URL

    private let lock = NSLock()
    private var serviceNames: [String]
    private var _services: [String: Service]
    private var _launchdEnvironment: [String: String] = [:]
    private var _dnsRelayRunning = false
    private var _refusedScripts: [String] = []

    init(services: [String] = ["Wi-Fi"], resolverDirectory: URL) {
        self.serviceNames = services
        self._services = Dictionary(uniqueKeysWithValues: services.map { ($0, Service()) })
        self.resolverDirectory = resolverDirectory
        try? FileManager.default.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)
    }

    // MARK: State

    func service(_ name: String) -> Service {
        lock.withLock { _services[name] ?? Service() }
    }

    func describe(_ name: String, _ mutate: (inout Service) -> Void) {
        lock.withLock {
            var service = _services[name] ?? Service()
            mutate(&service)
            _services[name] = service
            if !serviceNames.contains(name) { serviceNames.append(name) }
        }
    }

    var launchdEnvironment: [String: String] {
        get { lock.withLock { _launchdEnvironment } }
        set { lock.withLock { _launchdEnvironment = newValue } }
    }

    var dnsRelayRunning: Bool {
        lock.withLock { _dnsRelayRunning }
    }

    /// The `networksetup` scripts that were refused for lack of admin rights.
    var refusedScripts: [String] {
        lock.withLock { _refusedScripts }
    }

    /// Contents of the resolver file for `domain`, or `nil` when none exists.
    func resolverFile(for domain: String) -> String? {
        try? String(contentsOf: resolverDirectory.appendingPathComponent(domain), encoding: .utf8)
    }

    /// Writes a resolver file as a previous run would have, without recording
    /// anything: residue for a scenario to find.
    func strandResolverFile(for domain: String, contents: String) throws {
        try contents.write(to: resolverDirectory.appendingPathComponent(domain), atomically: true, encoding: .utf8)
    }

    // MARK: Command runner

    private static let adminRequired = CommandResult(
        exitCode: 14,
        standardOutput: "",
        standardError: "** Error: The parameters were not valid. This operation requires admin privileges."
    )

    private static func failure(_ message: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: message)
    }

    private static func success(_ output: String) -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        switch launchPath {
        case "/bin/sh":
            lock.withLock { _refusedScripts.append(arguments.count == 2 ? arguments[1] : "") }
            return Self.adminRequired
        case "/bin/launchctl":
            return runLaunchctl(arguments)
        case "/usr/sbin/networksetup":
            return runNetworksetup(arguments)
        default:
            return Self.failure("unexpected command \(launchPath)")
        }
    }

    private func runLaunchctl(_ arguments: [String]) -> CommandResult {
        guard let verb = arguments.first else { return Self.failure("launchctl: no verb") }
        return lock.withLock {
            switch verb {
            case "setenv" where arguments.count >= 3:
                _launchdEnvironment[arguments[1]] = arguments[2]
                return Self.success("")
            case "unsetenv" where arguments.count >= 2:
                _launchdEnvironment.removeValue(forKey: arguments[1])
                return Self.success("")
            case "getenv" where arguments.count >= 2:
                // Real launchctl prints nothing and still exits 0 for an unset name.
                return Self.success(_launchdEnvironment[arguments[1]] ?? "")
            default:
                return Self.failure("unexpected launchctl verb \(verb)")
            }
        }
    }

    private func runNetworksetup(_ arguments: [String]) -> CommandResult {
        guard let command = arguments.first else { return Self.failure("networksetup: no command") }
        return lock.withLock {
            if command == "-listallnetworkservices" {
                let lines = ["An asterisk (*) denotes that a network service is disabled."] + serviceNames
                return Self.success(lines.joined(separator: "\n"))
            }
            let name = arguments.count > 1 ? arguments[1] : ""
            guard let service = _services[name] else {
                return Self.failure("** Error: The parameters were not valid.")
            }
            switch command {
            case "-getinfo":
                return Self.success(service.connected ? "IP address: 192.0.2.10" : "IP address:\nSubnet mask:")
            case "-getwebproxy":
                return Self.success(Self.render(service.webProxy))
            case "-getsecurewebproxy":
                return Self.success(Self.render(service.secureWebProxy))
            case "-getautoproxyurl":
                return Self.success("URL: \(service.autoproxyURL)\nEnabled: \(service.autoproxyEnabled ? "Yes" : "No")")
            case "-getproxybypassdomains":
                return Self.success(
                    service.bypassDomains.isEmpty
                        ? "There aren't any bypass domains set on this network service."
                        : service.bypassDomains.joined(separator: "\n")
                )
            case "-getdnsservers":
                return Self.success(
                    service.dnsServers.isEmpty
                        ? "There aren't any DNS Servers set on \(name)."
                        : service.dnsServers.joined(separator: "\n")
                )
            default:
                return Self.failure("unexpected networksetup command \(command)")
            }
        }
    }

    private static func render(_ endpoint: ProxyEndpoint) -> String {
        "Enabled: \(endpoint.enabled ? "Yes" : "No")\nServer: \(endpoint.host)\nPort: \(endpoint.port)"
    }

    // MARK: PrivilegeClient

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    func execute(batch: [PrivilegedBatchStep]) throws {
        // Recorded first, and a scripted refusal stops the batch before any of
        // it lands — the helper validates the whole batch up front too.
        try privilege.execute(batch: batch)
        for step in batch {
            try apply(step.operation, step.values)
        }
    }

    private func apply(_ operation: PrivilegedOperation, _ values: [String]) throws {
        switch operation {
        case .applyDNS:
            guard values.count >= 2 else { throw PrivilegeClientError.executionFailed("apply-dns: missing values") }
            let servers = values[1].split(separator: ",").map(String.init)
            var content = servers.map { "nameserver \($0)" }.joined(separator: "\n")
            if values.count >= 3, let port = Int(values[2]), (1...65535).contains(port) {
                content += "\nport \(port)"
            }
            try content.write(to: resolverDirectory.appendingPathComponent(values[0]), atomically: true, encoding: .utf8)
        case .removeDNS:
            guard let domain = values.first else { return }
            try? FileManager.default.removeItem(at: resolverDirectory.appendingPathComponent(domain))
        case .startDNSRelay:
            lock.withLock { _dnsRelayRunning = true }
        case .stopDNSRelay:
            lock.withLock { _dnsRelayRunning = false }
        case .startTCPRelay, .stopTCPRelay, .ping:
            break
        case .applySystemProxy, .clearSystemProxy, .setProxyBypass, .setAutoproxyURL,
             .disableAutoproxy, .setWebProxyEndpoint, .setAutoproxy, .setDNSServers:
            try applyToService(operation, values)
        }
    }

    private func applyToService(_ operation: PrivilegedOperation, _ values: [String]) throws {
        guard let name = values.first else {
            throw PrivilegeClientError.executionFailed("\(operation.rawValue): no service")
        }
        try lock.withLock {
            guard var service = _services[name] else {
                throw PrivilegeClientError.executionFailed("\(operation.rawValue): unknown service \(name)")
            }
            defer { _services[name] = service }
            let rest = Array(values.dropFirst())
            switch operation {
            case .applySystemProxy:
                guard rest.count >= 2 else { throw PrivilegeClientError.executionFailed("apply-system-proxy: missing host/port") }
                service.webProxy = ProxyEndpoint(enabled: true, host: rest[0], port: rest[1])
                service.secureWebProxy = ProxyEndpoint(enabled: true, host: rest[0], port: rest[1])
            case .clearSystemProxy:
                service.webProxy.enabled = false
                service.secureWebProxy.enabled = false
                service.autoproxyEnabled = false
            case .setProxyBypass:
                service.bypassDomains = rest.count == 1 && HelperInputValidator.isEmptyListSentinel(rest[0]) ? [] : rest
            case .setAutoproxyURL:
                guard let url = rest.first else { throw PrivilegeClientError.executionFailed("set-autoproxy-url: missing url") }
                service.autoproxyURL = url
                service.autoproxyEnabled = true
            case .disableAutoproxy:
                service.autoproxyEnabled = false
            case .setWebProxyEndpoint:
                // [kind, host, port, state]: an empty host leaves the address
                // alone, the `Empty` sentinel clears it. See `ProxyWriteStep`.
                guard rest.count >= 4 else { throw PrivilegeClientError.executionFailed("set-web-proxy-endpoint: missing values") }
                var endpoint = rest[0] == WebProxyKind.secure.rawValue ? service.secureWebProxy : service.webProxy
                if HelperInputValidator.isEmptyListSentinel(rest[1]) {
                    endpoint.host = ""
                    endpoint.port = ""
                } else if !rest[1].isEmpty {
                    endpoint.host = rest[1]
                    endpoint.port = rest[2]
                }
                endpoint.enabled = rest[3] == "on"
                if rest[0] == WebProxyKind.secure.rawValue { service.secureWebProxy = endpoint } else { service.webProxy = endpoint }
            case .setAutoproxy:
                // [url, state]: an empty url writes only the state.
                guard rest.count >= 2 else { throw PrivilegeClientError.executionFailed("set-autoproxy: missing values") }
                if !rest[0].isEmpty { service.autoproxyURL = rest[0] }
                service.autoproxyEnabled = rest[1] == "on"
            case .setDNSServers:
                service.dnsServers = rest.count == 1 && HelperInputValidator.isEmptyListSentinel(rest[0]) ? [] : rest
            default:
                break
            }
        }
    }
}

// MARK: - FakeLoginItems

/// Stands in for `SMAppService`: records each registration change and can
/// refuse them, so a host test can flip launch-at-login without registering
/// the test runner to start at login.
final class FakeLoginItems: @unchecked Sendable {
    private let lock = NSLock()
    private var _registrations: [Bool] = []
    private var _fails = false

    /// Every change requested, in order.
    var registrations: [Bool] { lock.withLock { _registrations } }
    var isRegistered: Bool { registrations.last ?? false }
    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    struct Refused: Error {}

    func setRegistered(_ enabled: Bool) throws {
        let refused: Bool = lock.withLock {
            _registrations.append(enabled)
            return _fails
        }
        if refused { throw Refused() }
    }

    /// A manager wired to this fake, for the host under test.
    var manager: LoginItemManager {
        LoginItemManager(setRegistered: { [self] enabled in try self.setRegistered(enabled) })
    }
}
