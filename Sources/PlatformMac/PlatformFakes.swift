// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

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
    private var _installs: [String] = []
    private var _uninstalls = 0
    private var _fails = false

    package struct Refused: Error, LocalizedError {
        package var errorDescription: String? { "helper lifecycle refused" }
    }

    package init(status: HelperToolPrivilegeClient.Status = .installed) {
        _status = status
    }

    package var status: HelperToolPrivilegeClient.Status {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    /// The source paths of every install requested, in order.
    package var installs: [String] { lock.withLock { _installs } }
    package var uninstalls: Int { lock.withLock { _uninstalls } }
    package var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }

    package func installHelper(from sourcePath: String) throws {
        let refused: Bool = lock.withLock {
            _installs.append(sourcePath)
            if !_fails { _status = .installed }
            return _fails
        }
        if refused { throw Refused() }
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
