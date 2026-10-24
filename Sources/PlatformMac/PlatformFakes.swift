// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel
import ConduitShared

package struct FakeUpdatePreflight: UpdatePreflighting {
    package let failure: String?
    package init(failure: String? = nil) { self.failure = failure }
    package func check(_ candidate: UpdateCandidate) async throws {
        if let failure { throw UpdatePreflightError(failure) }
    }
}

// The doubles the platform managers and both runtime hosts are tested
// against, and the machine the app's `--dev` launch mode runs over. They
// live in Sources rather than Tests for the same reason
// `FakeVPNStatusObserver` sits next to its protocol in `ProxyKernel`: the
// dev instance is an executable, and SwiftPM lets nothing but a test
// target import another executable or a test target. One copy each: the
// suite used to carry a private recording privilege client per test file,
// and the host harness needs the same recorder plus a machine model behind
// it.

// MARK: - RecordingPrivilegeClient

/// Records every privileged operation in order and fails the ones it is told
/// to. Recording happens before the failure, so a test can see what was
/// attempted as well as what landed.
package final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    /// The refusal a scripted failure throws. Names the domain when the
    /// operation carried one, because the resolver tests match on it.
    package struct Refused: Error, LocalizedError {
        let operation: PrivilegedOperation
        let subject: String?
        package var errorDescription: String? { "helper refused \(subject ?? operation.rawValue)" }
    }

    private let lock = NSLock()
    private var _commands: [(command: PrivilegedOperation, values: [String])] = []
    private var _batches: [[PrivilegedBatchStep]] = []
    private var _mainThreadOperations: [PrivilegedOperation] = []
    private var _failing: Set<PrivilegedOperation> = []
    private var _failingDomains: Set<String> = []
    private let error: Error?

    /// - Parameter error: thrown by every call, for a client that is down
    ///   altogether (no helper installed, socket refused).
    package init(error: Error? = nil) {
        self.error = error
    }

    /// Every operation, batched or not, in the order it was requested.
    package var commands: [(command: PrivilegedOperation, values: [String])] {
        lock.withLock { _commands }
    }

    /// One entry per elevation, so a test can pin how many times a user
    /// would be prompted rather than only what was run.
    package var batches: [[PrivilegedBatchStep]] {
        lock.withLock { _batches }
    }

    /// The operations that were asked for on the main thread, where a real
    /// client's wait on the helper is a window that does not draw. A host
    /// that moved a path off the main actor pins it by finding none here.
    package var mainThreadOperations: [PrivilegedOperation] {
        lock.withLock { _mainThreadOperations }
    }

    /// Operations that fail whatever their values.
    package var failing: Set<PrivilegedOperation> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    /// Operations whose first value (the domain, for the resolver writes)
    /// is in this set fail, so a test can put a failure in the middle of a
    /// batch and see what the rest of it did.
    package var failingDomains: Set<String> {
        get { lock.withLock { _failingDomains } }
        set { lock.withLock { _failingDomains = newValue } }
    }

    /// Answers as the helper does at the loginwindow: operations that set a
    /// value are refused with `.noConsoleUser`; clear, remove and stop land.
    package var atLoginwindow: Bool {
        get { lock.withLock { _atLoginwindow } }
        set { lock.withLock { _atLoginwindow = newValue } }
    }
    private var _atLoginwindow = false

    /// The value lists of every recorded `operation`.
    package func commands(matching operation: PrivilegedOperation) -> [[String]] {
        commands.filter { $0.command == operation }.map(\.values)
    }

    package func reset() {
        lock.withLock { _commands.removeAll(); _batches.removeAll(); _mainThreadOperations.removeAll() }
    }

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    package func execute(batch: [PrivilegedBatchStep]) throws {
        let onMainThread = Thread.isMainThread
        let refusal: Error? = lock.withLock {
            _batches.append(batch)
            if onMainThread { _mainThreadOperations.append(contentsOf: batch.map(\.operation)) }
            _commands.append(contentsOf: batch.map { ($0.operation, $0.values) })
            if let error { return error }
            for step in batch {
                if _atLoginwindow {
                    let command = HelperCommand(step.operation)
                    if !HelperAdmission.isTeardownOnly(command), !HelperAdmission.isDNSReset(command, values: step.values) {
                        return PrivilegeClientError.refused(.noConsoleUser, "no console user yet")
                    }
                }
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
package final class FakeMachine: PrivilegeClient, @unchecked Sendable {
    package struct ProxyEndpoint: Equatable {
        var enabled = false
        var host = ""
        var port = ""
    }

    package struct Service: Equatable {
        var connected = true
        var webProxy = ProxyEndpoint()
        var secureWebProxy = ProxyEndpoint()
        var autoproxyURL = ""
        var autoproxyEnabled = false
        var bypassDomains: [String] = []
        var dnsServers: [String] = []

        /// Whether anything on the service routes traffic through a proxy.
        package var routesThroughAProxy: Bool {
            webProxy.enabled || secureWebProxy.enabled || autoproxyEnabled
        }
    }

    /// Every privileged write, in order, and the failure switches.
    package let privilege = RecordingPrivilegeClient()
    /// Where the resolver files land. Hand this to the manager under test.
    package let resolverDirectory: URL

    private let lock = NSLock()
    private var serviceNames: [String]
    private var _services: [String: Service]
    private var _launchdEnvironment: [String: String] = [:]
    private var _dnsRelayRunning = false
    private var _refusedScripts: [String] = []
    private var _failingSetenv: Set<String> = []

    package init(services: [String] = ["Wi-Fi"], resolverDirectory: URL) {
        self.serviceNames = services
        self._services = Dictionary(uniqueKeysWithValues: services.map { ($0, Service()) })
        self.resolverDirectory = resolverDirectory
        try? FileManager.default.createDirectory(at: resolverDirectory, withIntermediateDirectories: true)
    }

    // MARK: State

    package func service(_ name: String) -> Service {
        lock.withLock { _services[name] ?? Service() }
    }

    package func describe(_ name: String, _ mutate: (inout Service) -> Void) {
        lock.withLock {
            var service = _services[name] ?? Service()
            mutate(&service)
            _services[name] = service
            if !serviceNames.contains(name) { serviceNames.append(name) }
        }
    }

    package var launchdEnvironment: [String: String] {
        get { lock.withLock { _launchdEnvironment } }
        set { lock.withLock { _launchdEnvironment = newValue } }
    }

    package var dnsRelayRunning: Bool {
        lock.withLock { _dnsRelayRunning }
    }

    /// Variable names whose `launchctl setenv` fails, as a launchd that
    /// refuses the write would: the environment apply's partial outcome.
    package var failingSetenv: Set<String> {
        get { lock.withLock { _failingSetenv } }
        set { lock.withLock { _failingSetenv = newValue } }
    }

    /// The `networksetup` scripts that were refused for lack of admin rights.
    package var refusedScripts: [String] {
        lock.withLock { _refusedScripts }
    }

    /// Contents of the resolver file for `domain`, or `nil` when none exists.
    package func resolverFile(for domain: String) -> String? {
        try? String(contentsOf: resolverDirectory.appendingPathComponent(domain), encoding: .utf8)
    }

    /// Writes a resolver file as a previous run would have, without recording
    /// anything: residue for a scenario to find.
    package func strandResolverFile(for domain: String, contents: String) throws {
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

    package func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
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
            case "setenv" where arguments.count >= 3 && _failingSetenv.contains(arguments[1]):
                return Self.failure("launchctl setenv \(arguments[1]): refused")
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

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    package func execute(batch: [PrivilegedBatchStep]) throws {
        // Recorded first, and a scripted refusal stops the batch before any of
        // it lands — the helper validates the whole batch up front too.
        try privilege.execute(batch: batch)
        for step in batch {
            try apply(step.operation, step.values)
        }
    }

    private func apply(_ operation: PrivilegedOperation, _ values: [String]) throws {
        switch operation {
        case .compareNetworkSettings:
            throw PrivilegeClientError.executionFailed("Inject FakeNetworkLocationStore for location writes")
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
package final class FakeLoginItems: @unchecked Sendable {
    package init() {}

    private let lock = NSLock()
    private var _registrations: [Bool] = []
    private var _fails = false

    /// Every change requested, in order.
    package var registrations: [Bool] { lock.withLock { _registrations } }
    package var isRegistered: Bool { registrations.last ?? false }
    package var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    package struct Refused: Error {}

    package func setRegistered(_ enabled: Bool) throws {
        let refused: Bool = lock.withLock {
            _registrations.append(enabled)
            return _fails
        }
        if refused { throw Refused() }
    }

    /// A manager wired to this fake, for the host under test.
    package var manager: LoginItemManager {
        LoginItemManager(setRegistered: { [self] enabled in try self.setRegistered(enabled) })
    }
}

// MARK: - FakeHelperLifecycle

/// Stands in for the installed helper's lifecycle: the status the Settings
/// section shows, and install / uninstall, recorded and never reaching
/// `/Library/PrivilegedHelperTools`. Installed by default, so a host over
/// it sees the machine a helper-backed user does.
package final class FakeHelperLifecycle: HelperLifecycleManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: HelperToolPrivilegeClient.Status
    private var _statusReads = 0
    private var _installs = 0
    private var _uninstalls = 0
    private var _fails = false
    private var _callerPolicy: HelperPinOutcome = .enforced
    private var _statusAfterInstall: HelperToolPrivilegeClient.Status = .installed

    package struct Refused: Error, LocalizedError {
        package var errorDescription: String? { "helper lifecycle refused" }
    }

    package init(status: HelperToolPrivilegeClient.Status = .installed) {
        _status = status
    }

    package var status: HelperToolPrivilegeClient.Status {
        get {
            lock.withLock {
                _statusReads += 1
                return _status
            }
        }
        set { lock.withLock { _status = newValue } }
    }

    /// How many times the status was read, so a test can count re-checks.
    package var statusReads: Int { lock.withLock { _statusReads } }

    package var installs: Int { lock.withLock { _installs } }
    package var uninstalls: Int { lock.withLock { _uninstalls } }
    package var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    /// What the helper reads as once an install succeeds; `busy` stands in
    /// for a new helper whose first ping times out.
    package var statusAfterInstall: HelperToolPrivilegeClient.Status {
        get { lock.withLock { _statusAfterInstall } }
        set { lock.withLock { _statusAfterInstall = newValue } }
    }

    /// What the next install reports, as the installer would have.
    package var callerPolicy: HelperPinOutcome {
        get { lock.withLock { _callerPolicy } }
        set { lock.withLock { _callerPolicy = newValue } }
    }

    package func installHelper() throws -> HelperPinOutcome {
        let (refused, policy): (Bool, HelperPinOutcome) = lock.withLock {
            _installs += 1
            if !_fails { _status = _statusAfterInstall }
            return (_fails, _callerPolicy)
        }
        if refused { throw Refused() }
        return policy
    }

    package func uninstallHelper() throws {
        let refused: Bool = lock.withLock {
            _uninstalls += 1
            if !_fails { _status = .notInstalled }
            return _fails
        }
        if refused { throw Refused() }
    }
}

// MARK: - FakeKerberosTicketRecovery

/// Never launches a process or reads the user's ticket cache.
package final class FakeKerberosTicketRecovery: KerberosTicketRecovering, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    package init() {}
    package var calls: Int { lock.withLock { count } }
    package func primeServiceTicket(host: String) throws {
        lock.withLock { count += 1 }
        throw KerberosTicketRecoveryError.executableUnavailable
    }
}

// MARK: - FakeDNSProbe

/// Answers whether a resolver responds on a loopback port without sending a
/// query. The real probe reaches the machine's port 53, where the installed
/// Conduit's relay may answer for a dev instance or a harness.
package final class FakeDNSProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var answering: Set<Int>
    package init(answering: Set<Int> = []) { self.answering = answering }
    package func setAnswering(_ ports: Set<Int>) { lock.withLock { answering = ports } }
    package func responds(onPort port: Int) -> Bool { lock.withLock { answering.contains(port) } }
}

// MARK: - InMemorySecretStore

/// A `SecretStore` that forgets on exit, for a host whose credential
/// controls must not reach the login Keychain. Counts its reads, and can be
/// told to fail or to take a while, so a test can see how often a caller
/// goes to the store.
package final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: SecretBytes] = [:]
    private var _loads = 0
    private var _existsCalls = 0
    private var _loadFailure: (any Error)?
    private var _loadDelay: TimeInterval = 0

    package init() {}

    package var accounts: [String] { lock.withLock { Array(secrets.keys) } }

    /// How many times `load(account:)` has been called.
    package var loads: Int { lock.withLock { _loads } }

    /// How many times `exists(account:)` has been called.
    package var existsCalls: Int { lock.withLock { _existsCalls } }

    /// Thrown by every `load(account:)` while set.
    package var loadFailure: (any Error)? {
        get { lock.withLock { _loadFailure } }
        set { lock.withLock { _loadFailure = newValue } }
    }

    /// How long each `load(account:)` blocks before answering, as a Keychain
    /// read showing an access prompt would.
    package var loadDelay: TimeInterval {
        get { lock.withLock { _loadDelay } }
        set { lock.withLock { _loadDelay = newValue } }
    }

    package func save(secret: SecretBytes, account: String) throws {
        lock.withLock { secrets[account] = secret }
    }

    private let holdCondition = NSCondition()
    private var _held = false

    /// Makes every `load(account:)` block until `releaseLoads()`, as a read
    /// behind a Keychain prompt nobody answers does.
    package func holdLoads() {
        holdCondition.withLock { _held = true }
    }

    package func releaseLoads() {
        holdCondition.withLock {
            _held = false
            holdCondition.broadcast()
        }
    }

    package func load(account: String) throws -> SecretBytes? {
        let (failure, delay) = lock.withLock { () -> ((any Error)?, TimeInterval) in
            _loads += 1
            return (_loadFailure, _loadDelay)
        }
        holdCondition.withLock {
            while _held { holdCondition.wait() }
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let failure { throw failure }
        return lock.withLock { secrets[account] }
    }

    package func exists(account: String) throws -> Bool {
        lock.withLock {
            _existsCalls += 1
            return secrets[account] != nil
        }
    }

    package func delete(account: String) throws {
        lock.withLock { _ = secrets.removeValue(forKey: account) }
    }
}

// MARK: - Network locations

package final class FakeNetworkLocationStore: NetworkLocationStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var state: NetworkLocationSnapshot
    private var failWrites = false
    private var _atLoginwindow = false
    package var atLoginwindow: Bool {
        get { lock.withLock { _atLoginwindow } }
        set { lock.withLock { _atLoginwindow = newValue } }
    }
    private var nextActiveLocation: String?
    package init(snapshot: NetworkLocationSnapshot) { state = snapshot }
    package func snapshot() throws -> NetworkLocationSnapshot { lock.withLock { state } }
    package func edit(_ body: (inout NetworkLocationSnapshot) -> Void) { lock.withLock { body(&state) } }
    package func refuseWrites(_ refuse: Bool) { lock.withLock { failWrites = refuse } }
    private var compareFailuresRemaining = 0
    package var pendingCompareFailures: Int { lock.withLock { compareFailuresRemaining } }
    package func conflictNextWrites(_ count: Int) {
        precondition((0...64).contains(count))
        lock.withLock { compareFailuresRemaining = count }
    }
    package func switchDuringNextWrite(to locationID: String) { lock.withLock { nextActiveLocation = locationID } }
    private var refusedServices: Set<String> = []
    /// Writes to these services fail while others succeed: a partial apply.
    package func refuseWrites(toService serviceID: String, _ refuse: Bool) {
        lock.withLock { if refuse { refusedServices.insert(serviceID) } else { refusedServices.remove(serviceID) } }
    }
    private var _committedWrites = 0
    package var committedWrites: Int { lock.withLock { _committedWrites } }
    package func compareAndWrite(_ request: NetworkSettingsRequest) throws {
        try request.validate()
        try lock.withLock {
            if let nextActiveLocation { state.activeLocationID = nextActiveLocation; self.nextActiveLocation = nil }
            guard !failWrites, !refusedServices.contains(request.serviceID) else { throw NetworkSettingsError.unavailable }
            if compareFailuresRemaining > 0 {
                compareFailuresRemaining -= 1
                throw NetworkSettingsError.changed
            }
            if _atLoginwindow && !request.isCleanup { throw PrivilegeClientError.refused(.noConsoleUser, "No console user") }
            guard !request.requireActive || state.activeLocationID == request.locationID,
                  let index = state.services.firstIndex(where: {
                      $0.locationID == request.locationID && $0.serviceID == request.serviceID
                  }) else { throw NetworkSettingsError.changed }
            let current = request.kind == .proxies ? state.services[index].proxies : state.services[index].dns
            guard current == request.expected else { throw NetworkSettingsError.changed }
            if request.kind == .proxies { state.services[index].proxies = request.replacement }
            else { state.services[index].dns = request.replacement }
            _committedWrites += 1
        }
    }
}

package final class FakeNetworkLocationObserver: NetworkLocationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<String, NetworkSettingsError>) -> Void)?
    private var settingsCallback: (@Sendable () -> Void)?
    package init() {}
    package func start(onChange: @escaping @Sendable (Result<String, NetworkSettingsError>) -> Void,
                       onSettingsChange: @escaping @Sendable () -> Void) {
        lock.withLock { callback = onChange; settingsCallback = onSettingsChange }
    }
    package func stop() { lock.withLock { callback = nil; settingsCallback = nil } }
    package func emit(_ locationID: String) { lock.withLock { callback }?(.success(locationID)) }
    package func emitSettingsChange() { lock.withLock { settingsCallback }?() }
    package func pendingSettingsDelivery() -> (@Sendable () -> Void)? { lock.withLock { settingsCallback } }
    /// Models a callback already in flight when observation is stopped.
    package func pendingDelivery(_ locationID: String) -> (@Sendable () -> Void)? {
        guard let callback = lock.withLock({ callback }) else { return nil }
        return { callback(.success(locationID)) }
    }
}

/// Test/sim injection point for `NetworkMonitor`. `emit(_:)` delivers a
/// synthetic path report only between `start()` and `stop()`, as the
/// production observer gates its callbacks. The callback runs on the caller's
/// thread. A delivery already selected when `stop()` runs still completes
/// after it, as a debounced callback already queued on `NetworkMonitor`'s
/// queue does in production; `stop()` does not wait for it, so the host must
/// gate such a report on its own state.
package final class FakeNetworkPathObserver: NetworkPathObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (NetworkPathState) -> Void)?
    private var started = false
    package init() {}

    package func setOnChange(_ onChange: @Sendable @escaping (NetworkPathState) -> Void) {
        lock.withLock { callback = onChange }
    }

    package func start() { lock.withLock { started = true } }

    package func stop() { lock.withLock { started = false } }

    /// Whether `start()` has been called since the last `stop()`.
    package var isObserving: Bool { lock.withLock { started } }

    package func emit(_ state: NetworkPathState) {
        let delivery = lock.withLock { started ? callback : nil }
        delivery?(state)
    }
}

// MARK: - Updates

/// Stands in for the nested updater: records each start, can refuse them,
/// and never launches a process, so a `--dev` instance or a test host cannot
/// start the installed app's updater.
package final class FakeUpdaterLauncher: UpdaterLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [UpdaterContract.LaunchMode] = []
    private var _failure: String?

    package init() {}

    /// Every start requested, in order.
    package var starts: [UpdaterContract.LaunchMode] { lock.withLock { _starts } }
    /// When set, starts fail with this reason.
    package var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    package func start(_ mode: UpdaterContract.LaunchMode) async throws {
        let failure: String? = lock.withLock {
            _starts.append(mode)
            return _failure
        }
        if let failure { throw UpdaterLaunchError(failure) }
    }
}

/// Stands in for the distributed-notification channel: `deliver` runs a
/// userInfo through the same contract parsing as production, so tests can
/// send well-formed, malformed and other-host reports.
@MainActor
package final class FakeUpdateReports: UpdateReportSource {
    private var handler: (@MainActor (Result<UpdaterContract.ParsedReport, UpdaterContract.Rejection>) -> Void)?
    private var hostPath = ""

    package init() {}

    package var isSubscribed: Bool { handler != nil }

    package func subscribe(
        hostIdentifier: String,
        hostPath: String,
        _ handler: @escaping @MainActor (Result<UpdaterContract.ParsedReport, UpdaterContract.Rejection>) -> Void
    ) {
        self.hostPath = hostPath
        self.handler = handler
    }

    package func cancel() {
        handler = nil
    }

    package func deliver(_ userInfo: [AnyHashable: Any]?) {
        handler?(UpdaterContract.parseReport(userInfo, hostPath: hostPath))
    }
}

// MARK: - State root and writer lease

/// A scripted directory tree for `StateRootLayout`, built per test. Entries are
/// keyed by absolute path, a symbolic link resolves through one table (a link
/// to a link is not modelled), and any path can be made to fail with an errno.
///
/// Each entry has an inode, and `addHardLink` shares one. Lookups fold case unless
/// the volume is scripted as case-sensitive, with the same folding the layout uses,
/// so final sigma, long s and micro sign are one name. A volume scripted as unknown
/// (nil) folds case and answers nil to the case query, so the layout must refuse
/// rather than assume either answer.
package final class FakeStateRootFileSystem: StateRootFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let caseSensitiveNames: Bool?
    private var entries: [String: StateRootEntryKind] = [:]
    private var links: [String: String] = [:]
    private var inodes: [String: UInt64] = [:]
    private var nextInode: UInt64 = 1
    private var failures: [String: Int32] = [:]
    private var caseQueryFailure: Int32?

    /// - Parameter caseSensitiveNames: the volume's answer to the case query. Nil
    ///   is an unknown volume.
    package init(caseSensitiveNames: Bool? = true) {
        self.caseSensitiveNames = caseSensitiveNames
    }

    /// The key a path is stored under. A volume that does not distinguish case
    /// stores every spelling of a name under one key.
    private func key(_ path: String) -> String {
        caseSensitiveNames == true
            ? path
            : path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Caller holds `lock`. Gives the entry `inode`, or a fresh one.
    private func store(_ kind: StateRootEntryKind, at path: String, inode: UInt64? = nil) {
        let name = key(path)
        entries[name] = kind
        if let inode {
            inodes[name] = inode
        } else {
            inodes[name] = nextInode
            nextInode += 1
        }
    }

    package func addDirectory(_ path: String) {
        lock.withLock { store(.directory, at: path) }
    }

    package func addFile(_ path: String) {
        lock.withLock { store(.regularFile, at: path) }
    }

    package func addSymbolicLink(_ path: String, to target: String) {
        lock.withLock {
            store(.symbolicLink, at: path)
            links[key(path)] = target
        }
    }

    /// A second name for the object `existing` already names, as `link(2)` makes one.
    package func addHardLink(_ path: String, to existing: String) {
        lock.withLock {
            guard let inode = inodes[key(existing)] else {
                preconditionFailure("hard link target \(existing) is not in the tree")
            }
            store(.regularFile, at: path, inode: inode)
        }
    }

    package func failPath(_ path: String, errno: Int32) {
        lock.withLock { failures[path] = errno }
    }

    /// Every case query fails with this errno.
    package func failCaseQuery(errno: Int32) {
        lock.withLock { caseQueryFailure = errno }
    }

    package func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind {
        let (failure, kind) = lock.withLock { (failures[path], entries[key(path)] ?? .missing) }
        if let failure { throw StateRootFileSystemError(errno: failure) }
        return kind
    }

    package func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity? {
        let (failure, inode) = lock.withLock { () -> (Int32?, UInt64?) in
            guard entries[key(path)] != nil else { return (failures[path], nil) }
            return (failures[path], inodes[key(path)])
        }
        if let failure { throw StateRootFileSystemError(errno: failure) }
        return inode.map { StateRootFileIdentity(device: 1, inode: $0) }
    }

    package func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String {
        let (failure, resolved) = lock.withLock { () -> (Int32?, String?) in
            guard entries[key(path)] != nil else { return (failures[path], nil) }
            return (failures[path], links[key(path)] ?? path)
        }
        if let failure { throw StateRootFileSystemError(errno: failure) }
        guard let resolved else { throw StateRootFileSystemError(errno: ENOENT) }
        return resolved
    }

    package func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool? {
        let failure = lock.withLock { caseQueryFailure }
        if let failure { throw StateRootFileSystemError(errno: failure) }
        return caseSensitiveNames
    }

    package func createDirectory(at path: String) throws(StateRootFileSystemError) {
        let failure: Int32? = lock.withLock { () -> Int32? in
            if let failure = failures[path] { return failure }
            if entries[key(path)] != nil { return EEXIST }
            store(.directory, at: path)
            return nil
        }
        if let failure { throw StateRootFileSystemError(errno: failure) }
    }
}

/// A scripted writer lease: one holder per canonical root, counted attempts and
/// refusals, and injected failures for the next acquisition or close. Nothing
/// touches the disk. A close that reports failure still releases the root in
/// the fake, as the OS does when close(2) returns an error.
package final class FakeStateWriterLeasing: StateWriterLeasing, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var nextFailure: StateWriterFailure?
    private var nextClose: StateWriterRelease?
    private var attempts = 0
    private var refusals = 0

    package init() {}

    package var acquireCount: Int { lock.withLock { attempts } }
    package var busyCount: Int { lock.withLock { refusals } }

    package func isHeld(_ root: CanonicalStateRoot) -> Bool {
        lock.withLock { held.contains(root.path) }
    }

    package func failNextAcquisition(_ failure: StateWriterFailure) {
        lock.withLock { nextFailure = failure }
    }

    /// The next close reports `releaseUnknown` with this errno.
    package func failNextRelease(errno: Int32) {
        lock.withLock { nextClose = .releaseUnknown(errno: errno) }
    }

    package func acquire(
        root: CanonicalStateRoot,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void
    ) -> StateWriterAcquisition {
        let refusal: StateWriterAcquisition? = lock.withLock { () -> StateWriterAcquisition? in
            attempts += 1
            if let failure = nextFailure {
                nextFailure = nil
                return .failed(failure)
            }
            if held.contains(root.path) {
                refusals += 1
                return .busy
            }
            held.insert(root.path)
            return nil
        }
        if let refusal { return refusal }
        return .acquired(StateWriterLease(root: root, onReleaseFailure: onReleaseFailure) { [self] in
            finishRelease(root)
        })
    }

    private func finishRelease(_ root: CanonicalStateRoot) -> StateWriterRelease {
        lock.withLock { () -> StateWriterRelease in
            held.remove(root.path)
            let outcome = nextClose ?? .released
            nextClose = nil
            return outcome
        }
    }
}
