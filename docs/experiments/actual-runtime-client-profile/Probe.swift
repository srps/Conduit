// Actual Conduit client/host resource probe. NOT product code, NOT a selected profile, NOT a benchmark product.
// It links the existing Release objects with `-package-name conduit` and drives the actual `RuntimeHost.open` facade over
// explicit fakes (the `pm-sim` runtime-host-effects composition) and an owned scratch state root, then the actual in-memory
// framed client and private editor client from `RuntimeHost.makeInMemoryControlClient`. No production adapter default,
// Keychain, GSS, helper, VPN, network-path or machine setting is touched. It prints numeric NDJSON only: fixed labels,
// counts, timings and memory. No URL, configuration value, credential or plaintext is printed.
//
// Modes (one fresh process each; see README.md): lifetime-open, lifetime-composed, lifetime-read, lifetime-save, lifetime-start,
// small, realistic-valid-64, realistic-valid-128, validator-widest, escape-maximum, padded-8mib, repeat, contention,
// contention-encode, contention-store, held, cancel, codec-bounds; any mode with `-nosampler` runs without the memory sampler.
// Usage: probe <mode>[-nosampler] <scratch-dir>. The scratch directory is removed only after every release proof agrees.
//
// `GenericDefaults.shared` is initialized by the actual store decode (`ProxyConfig.init(from:)`), which reads `NSUserName()`
// and the host name read-only; every fixture sets every value explicitly, so no default reaches a fixture, and nothing is printed.

import Darwin
import Foundation
import ConduitRuntime
import ConduitShared
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel

// MARK: - Output

struct ProbeError: Error {
    let label: String
    init(_ label: String) { self.label = label }
}

final class Output: @unchecked Sendable {
    let mode: String
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private(set) var failures: [String] = []
    private(set) var inconclusive: [String] = []

    init(mode: String) { self.mode = mode }

    /// Scoped in its own pool: bridged dictionaries are autoreleased and a command-line thread never drains them.
    func emit(_ record: [String: Any]) {
        writeLock.withLock {
            autoreleasepool {
                var labelled = record
                labelled["mode"] = mode
                do {
                    let data = try JSONSerialization.data(withJSONObject: labelled, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data + Data([0x0A]))
                } catch {
                    FileHandle.standardOutput.write(Data("{\"record\":\"emit-error\"}\n".utf8))
                }
            }
        }
    }

    func check(_ passed: Bool, _ name: String) {
        emit(["record": "check", "name": name, "passed": passed])
        if !passed { stateLock.withLock { failures.append(name) } }
    }

    func inconclusive(_ name: String) {
        emit(["record": "inconclusive", "name": name])
        stateLock.withLock { inconclusive.append(name) }
    }

    var failureList: [String] { stateLock.withLock { failures } }
    var inconclusiveList: [String] { stateLock.withLock { inconclusive } }
}

func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

func elapsedMS(since start: ContinuousClock.Instant) -> Double {
    milliseconds(start.duration(to: .now))
}

func waitEndLabel(_ end: RuntimeWaitEnd) -> String {
    switch end {
    case .deadlineExpired: "deadlineExpired"
    case .cancelled: "cancelled"
    case .transportBusy: "transportBusy"
    case .disconnected: "disconnected"
    case .invalidReply: "invalidReply"
    }
}

func errorLabel(_ error: any Error) -> String {
    switch error {
    case let error as ProbeError:
        return "probe.\(error.label)"
    case let error as RuntimeClientError:
        switch error {
        case .notSent(let end): return "client.notSent.\(waitEndLabel(end))"
        case .admissionUnknown(_, let end): return "client.admissionUnknown.\(waitEndLabel(end))"
        case .wire(let code): return "client.wire.\(code)"
        case .unexpectedReply: return "client.unexpectedReply"
        case .streamClosed(let reason): return "client.streamClosed.\(reason)"
        case .localRefusal(let code): return "client.localRefusal.\(code)"
        case .readAborted(let end): return "client.readAborted.\(waitEndLabel(end))"
        case .readInProgress: return "client.readInProgress"
        }
    case let error as PrivateConfigurationBridgeError:
        switch error {
        case .tooLarge: return "bridge.tooLarge"
        case .resourceLimit(let violation): return "bridge.resourceLimit.\(violation.field).\(violation.limit)"
        }
    case is PrivateConfigurationWireError:
        return "privateWire"
    case is ControlRuntimeWireError:
        return "controlWire"
    case is RuntimeOpenRefusal:
        return "host.openRefused"
    case is RuntimeStartRefusal:
        return "host.startRefused"
    default:
        return "unexpected.\(type(of: error))"
    }
}

func admissionLabel(_ admission: ControlAdmission) -> String {
    switch admission {
    case .accepted: "accepted"
    case .joined: "joined"
    case .rejected(let code): "rejected.\(code.rawValue)"
    }
}

func outcomeLabel(_ outcome: ControlOperationOutcome?) -> String {
    switch outcome {
    case nil: "none"
    case .completed(let completion)?: "completed.\(completion.command.rawValue)"
    case .superseded?: "superseded"
    case .partiallyCompleted?: "partiallyCompleted"
    case .failed(let code)?: "failed.\(code.rawValue)"
    case .configurationSettled?: "configurationSettled"
    case .preferencesSettled?: "preferencesSettled"
    }
}

func writeLabel(_ write: ControlConfigWorkflowWrite) -> String {
    switch write {
    case .persisted(let reported): "persisted.\(reported)"
    case .unchanged: "unchanged"
    case .notPersisted: "notPersisted"
    case .unknown(let cause, _): "unknown.\(cause.rawValue)"
    case .conflict: "conflict"
    case .notAttempted(let cause): "notAttempted.\(cause.rawValue)"
    }
}

// MARK: - Memory

struct MemoryReading {
    var resident = 0
    var footprint = 0
    var footprintPeak = 0
    var mallocInUse = 0
    var peakRSS = 0

    static func now() -> MemoryReading {
        var reading = MemoryReading()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            reading.resident = Int(clamping: info.resident_size)
            reading.footprint = Int(clamping: info.phys_footprint)
            reading.footprintPeak = Int(clamping: info.ledger_phys_footprint_peak)
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        reading.mallocInUse = Int(stats.size_in_use)
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { reading.peakRSS = Int(usage.ru_maxrss) }
        return reading
    }
}

/// A background thread that samples footprint, resident and malloc-in-use about every millisecond and keeps each phase's
/// maxima. The default allocator does not maintain `max_size_in_use`, so this is the only malloc peak available. Samples are
/// points: a copy that lives between two samples is not seen, so a phase maximum is a lower bound of the true transient peak.
final class PhaseSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maxFootprint = 0
    private var maxResident = 0
    private var maxMalloc = 0
    private var samples = 0
    private var stopped = false

    init() {
        let thread = Thread { [self] in loop() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func loop() {
        while !lock.withLock({ stopped }) {
            let reading = MemoryReading.now()
            lock.withLock {
                maxFootprint = max(maxFootprint, reading.footprint)
                maxResident = max(maxResident, reading.resident)
                maxMalloc = max(maxMalloc, reading.mallocInUse)
                samples += 1
            }
            usleep(1_000)
        }
    }

    /// The maxima since the previous call, folded with `current`, then reset to `current`.
    func take(folding current: MemoryReading) -> (footprint: Int, resident: Int, malloc: Int, samples: Int) {
        lock.withLock {
            let result = (max(maxFootprint, current.footprint), max(maxResident, current.resident), max(maxMalloc, current.mallocInUse), samples)
            maxFootprint = current.footprint
            maxResident = current.resident
            maxMalloc = current.mallocInUse
            samples = 0
            return result
        }
    }

    func stop() { lock.withLock { stopped = true } }
}

final class StageRecorder: @unchecked Sendable {
    let out: Output
    /// Nil in a `-nosampler` mode: the 1 ms sampler takes every malloc zone's lock, which can perturb sub-millisecond latencies.
    let sampler: PhaseSampler?
    private let start = ContinuousClock.now
    private var lastStage = ContinuousClock.now
    private var baseline: MemoryReading?
    private let lock = NSLock()

    init(out: Output, sampling: Bool) {
        self.out = out
        sampler = sampling ? PhaseSampler() : nil
    }

    /// One stage record: live values now, and the sampled maxima of the phase since the previous stage. `footprintPeakBytes`
    /// and `peakRSSBytes` are process-wide monotonic high-water marks.
    func stage(_ name: String, _ extra: [String: Any] = [:]) {
        let reading = MemoryReading.now()
        let phase = sampler?.take(folding: reading)
            ?? (footprint: reading.footprint, resident: reading.resident, malloc: reading.mallocInUse, samples: 0)
        let (phaseSeconds, base) = lock.withLock { () -> (Double, MemoryReading) in
            let now = ContinuousClock.now
            defer { lastStage = now }
            if baseline == nil { baseline = reading }
            return (milliseconds(lastStage.duration(to: now)) / 1_000, baseline!)
        }
        var record: [String: Any] = [
            "record": "stage", "stage": name,
            "seconds": milliseconds(start.duration(to: .now)) / 1_000, "phaseSeconds": phaseSeconds,
            "residentBytes": reading.resident, "physicalFootprintBytes": reading.footprint,
            "footprintPeakBytes": reading.footprintPeak, "peakRSSBytes": reading.peakRSS, "mallocInUseBytes": reading.mallocInUse,
            "phaseMaxFootprintBytes": phase.footprint, "phaseMaxResidentBytes": phase.resident,
            "phaseMaxMallocInUseBytes": phase.malloc, "phaseSamples": phase.samples,
            "mallocOverBaselineBytes": reading.mallocInUse - base.mallocInUse,
            "footprintOverBaselineBytes": reading.footprint - base.footprint,
        ]
        for (key, value) in extra { record[key] = value }
        out.emit(record)
    }
}

// MARK: - Explicit fakes (the pm-sim runtime-host-effects composition) and deterministic holds

/// A hold point. Disarmed it passes at once; armed, the first caller waits until `release()`.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var holding = false
    private var reached = 0

    func arm() { condition.withLock { armed = true } }

    func release() {
        condition.withLock {
            armed = false
            condition.broadcast()
        }
    }

    func pass() {
        condition.withLock {
            guard armed else { return }
            reached += 1
            holding = true
            while armed { condition.wait() }
            holding = false
        }
    }

    var isHolding: Bool { condition.withLock { holding } }
}

/// The privileged-operation fake, wrapped so a phase can hold the helper deterministically.
final class GatedPrivilege: PrivilegeClient, @unchecked Sendable {
    let base: FakeMachine
    let gate = Gate()

    init(base: FakeMachine) { self.base = base }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        gate.pass()
        try base.execute(operation, values: values)
    }

    func execute(batch: [PrivilegedBatchStep]) throws {
        gate.pass()
        try base.execute(batch: batch)
    }
}

/// The OS file adapter over the owned scratch root, counted, with a hold on runtime-file replacement.
final class CountingStateFiles: StateFileAccessing, @unchecked Sendable {
    private let base = StateFileAccess.operatingSystem()
    let replaceGate = Gate()
    private let lock = NSLock()
    private var reads = 0
    private var readBytes = 0
    private var widestRead = 0
    private var replaces = 0
    private var replaceBytes = 0

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        let result = base.readConfigurationFile(file, limit: limit)
        if case .success(let data) = result {
            lock.withLock {
                reads += 1
                readBytes += data.count
                widestRead = max(widestRead, data.count)
            }
        }
        return result
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        if file.role == .config { replaceGate.pass() }
        lock.withLock {
            replaces += 1
            replaceBytes += bytes.count
        }
        return base.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        base.entryPresence(file)
    }

    var counters: [String: Any] {
        lock.withLock {
            ["fileReads": reads, "fileReadBytes": readBytes, "widestFileReadBytes": widestRead,
             "fileReplaces": replaces, "fileReplaceBytes": replaceBytes]
        }
    }
}

final class RefusingGSS: GSSTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var calls: Int { lock.withLock { attempts } }

    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        lock.withLock { attempts += 1 }
        throw UnplannedFakeEffect(effect: "GSS token")
    }

    func resetContext() {}
}

struct Fakes: @unchecked Sendable {
    let machine: FakeMachine
    let privilege: GatedPrivilege
    let files: CountingStateFiles
    let probe = FakeListenerPortHolderProbe()
    let loopback = FakeLoopbackPortProbe()
    let pac = FakePacEvaluator()
    let gss = RefusingGSS()
    let helper = FakeHelperLifecycle()
    let secrets = InMemorySecretStore()
    let dns = FakeDNSProbe()
    let home: URL

    func effects() -> RuntimeHostEffects {
        let fakes = self
        return RuntimeHostEffects(
            privilege: { _ in RuntimePrivilegeAdapters(client: fakes.privilege, helperStatus: fakes.helper) },
            credentials: fakes.secrets,
            kerberosTicketRecovery: FakeKerberosTicketRecovery(),
            gss: .injected { fakes.gss },
            pacEvaluator: fakes.pac,
            portHolderProbe: fakes.probe,
            loopbackPortProbe: { port in fakes.loopback.isServed(port: port) },
            commandRunner: { launchPath, arguments in try fakes.machine.run(launchPath, arguments) },
            dnsResponds: { port in fakes.dns.responds(onPort: port) },
            networkPath: FakeNetworkPathObserver(),
            networkLocation: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil },
            vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
            homeDirectory: fakes.home,
            resolverDirectory: fakes.machine.resolverDirectory.path,
            stateFiles: fakes.files
        )
    }
}

final class ReleaseFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    var count: Int { lock.withLock { failures } }
    func record(_ failure: StateWriterReleaseFailure) { lock.withLock { failures += 1 } }
}

/// Objects kept for the rest of the process when a shutdown was not confirmed, so the root is never released early.
@MainActor
enum Pinned {
    static var objects: [AnyObject] = []
}

/// A free loopback port, chosen by the kernel and released at once. A fixed port, not 0, so the applied system-proxy endpoint
/// names the listener (the port-0 applied-endpoint issue).
func reserveLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProbeError("socket") }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw ProbeError("bind") }
    var chosen = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &chosen) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { throw ProbeError("getsockname") }
    return Int(UInt16(bigEndian: chosen.sin_port))
}

/// Whether a TCP listener accepts on the loopback port now: the physical evidence that a proxy listener is up or gone.
func loopbackAccepts(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return result == 0
}

// MARK: - Fixtures

func syntheticUUID(_ family: Int, _ index: Int) -> UUID {
    func hex(_ value: Int, _ width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: width - digits.count) + digits
    }
    return UUID(uuidString: "\(hex(family, 8))-0000-4000-8000-\(hex(index, 12))")!
}

let longestPreset = TunnelPreset.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!

/// The source's default `AuthSection` numbers, given explicitly: `AuthSection()` would read `NSUserName()` and the host name.
func syntheticAuth(username: String, domain: String, workstation: String) -> AuthSection {
    AuthSection(mode: AuthenticationMode.allCases[0], username: username, domain: domain, workstation: workstation,
                pendingHandshakeGlobalLimit: 512, pendingHandshakesPerSource: 128)
}

/// Current-shape synthetic configuration: a handful of entries per list, short valid values, every network name loopback or
/// `.invalid`, every upstream and tunnel disabled, PAC routing and DNS off. Semantically valid: it saves and Starts.
func makeSmallConfig(port: Int) -> ProxyConfig {
    var proxy = ProxySection()
    proxy.host = "127.0.0.1"
    proxy.port = port
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.allowedClients = ["127.0.0.1"]
    let upstreams = (0..<2).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: "u\(index)", host: "u\(index).invalid", port: 3128,
                      enabled: false, priority: index)
    }
    var routing = RoutingSection()
    routing.pacURL = "http://127.0.0.1:9/proxy.pac"
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    routing.noProxyHosts = ["localhost", "127.0.0.1", "*.local"]
    routing.forceProxyHosts = ["f0.invalid"]
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = ["https://127.0.0.1/dns-query"]
    dns.entries = (0..<2).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: "d\(index).invalid", servers: ["127.0.0.1"], enabled: false)
    }
    dns.interceptRules = [DNSInterceptRule(id: syntheticUUID(3, 0), pattern: "*.i0.invalid", interceptIP: "127.44.3.0", enabled: false)]
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<2).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 20_000 + index, remoteHost: "t\(index).invalid",
                         remotePort: 443, enabled: false, proxied: false, label: "t\(index)", preset: longestPreset)
    }
    var health = HealthSection()
    health.checkURL = "http://127.0.0.1:9/health"
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: "small-synthetic", proxy: proxy,
        auth: syntheticAuth(username: "synthetic-user", domain: "SYNTHETIC", workstation: "synthetic-ws"),
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: health, logging: logging
    )
}

func makeSmallPreferences() -> AppPreferences {
    AppPreferences(showMenuBarIcon: true, floatingWindowEnabled: false, globalShortcutEnabled: false,
                   preferredBrowserTestURL: "http://127.0.0.1:9/browser", fileLoggingEnabled: false, automaticUpdateChecks: false)
}

func makePlatform() -> PlatformIntegrationConfig {
    PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: false)
}

let allSaveOnly = PrivateModuleSlots<PrivateModuleIntent>(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)

// MARK: Largest fixtures

/// Distinct alphanumeric tags, so every value has its own storage.
final class Tags {
    private var next = 0
    func take() -> String {
        defer { next += 1 }
        let digits = String(next, radix: 36)
        return String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }
}

/// A valid DNS name of exactly `bytes` bytes (labels of at most 63), starting with the tag and ending in the reserved `.invalid`
/// top-level domain (RFC 6761), so a name that ever reached a resolver could not name a real host.
func dnsName(_ tag: String, bytes: Int) -> String {
    let suffix = ".invalid"
    let core = bytes - suffix.utf8.count
    var characters = Array(("x" + tag + String(repeating: "a", count: core - 1 - tag.utf8.count)).utf8)
    var index = 63
    while index < core - 1 {
        characters[index] = UInt8(ascii: ".")
        index += 64
    }
    return String(decoding: characters, as: UTF8.self) + suffix
}

/// Display text of exactly `bytes`: the tag, then quotes and backslashes, each a two-byte escape in both codecs.
func escapedDisplay(_ tag: String, bytes: Int) -> String {
    let fill = bytes - 1 - tag.utf8.count
    return "d" + tag + String((0..<fill).map { $0 % 2 == 0 ? Character("\"") : Character("\\") })
}

/// A loopback URL of exactly `bytes`: the prefix, the tag, then `/`, which the runtime file's canonical JSON escapes to two bytes.
func loopbackURL(_ prefix: String, _ tag: String, bytes: Int) -> String {
    prefix + tag + String(repeating: "/", count: bytes - prefix.utf8.count - tag.utf8.count)
}

func ulaAddress(_ family: Int, _ index: Int) -> String {
    String(format: "fd%02lx:0000:0000:0000:0000:0000:%04lx:%04lx", family, (index >> 16) & 0xFFFF, index & 0xFFFF)
}

/// A REALISTIC valid wide configuration (not the validator's widest; see `makeValidatorWidestConfig`): every collection at its
/// approved count, every value distinct and of a realistic kind chosen by this probe (253-byte `.invalid` DNS names, 39-byte
/// IPv6 addresses where a field names an address, IPv4 intercept targets, loopback URLs, display text of two-byte escapes).
/// Those choices are the probe's, not limits the product enforces. Upstreams and tunnels are disabled, PAC routing and DNS are
/// off, so it validates with no problem and Starts without external traffic.
func makeValidMaximumConfig(port: Int, auditPrefix: String, tunnels tunnelCount: Int = DomainResourceLimits.tunnelDefinitions) -> ProxyConfig {
    let limits = DomainResourceLimits.self
    let tags = Tags()
    var proxy = ProxySection()
    proxy.host = "127.0.0.1"
    proxy.port = port
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.allowedClients = (0..<limits.allowedClients).map { ulaAddress(1, $0) }
    let upstreams = (0..<limits.upstreams).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: escapedDisplay(tags.take(), bytes: limits.displayText),
                      host: dnsName(tags.take(), bytes: limits.hostText), port: 3128, enabled: false, priority: index)
    }
    var routing = RoutingSection()
    routing.pacURL = loopbackURL("http://127.0.0.1:9/", tags.take(), bytes: limits.urlText)
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    // 256 single-label names whose canonical list width is exactly the 8,192-byte aggregate.
    let content = limits.noProxyList - 2 - (limits.noProxyHosts - 1) - 2 * limits.noProxyHosts
    routing.noProxyHosts = (0..<limits.noProxyHosts).map { index in
        let width = content / limits.noProxyHosts + (index < content % limits.noProxyHosts ? 1 : 0)
        return dnsName(tags.take(), bytes: width)
    }
    routing.forceProxyHosts = (0..<limits.forceProxyHosts).map { _ in dnsName(tags.take(), bytes: limits.hostText) }
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = (0..<limits.dohProviders).map { _ in loopbackURL("https://127.0.0.1/dns-query/", tags.take(), bytes: limits.urlText) }
    dns.entries = (0..<limits.dnsEntries).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: dnsName(tags.take(), bytes: limits.hostText),
                       servers: (0..<limits.dnsServers).map { ulaAddress(2, index * limits.dnsServers + $0) }, enabled: false)
    }
    dns.interceptRules = (0..<limits.interceptRules).map { index in
        DNSInterceptRule(id: syntheticUUID(3, index), pattern: "*." + dnsName(tags.take(), bytes: limits.hostText),
                         interceptIP: "127.44.\(index / 256).\(index % 256)", enabled: false)
    }
    dns.transparentProxyIP = "127.44.3.0"
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<tunnelCount).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 20_000 + index, remoteHost: dnsName(tags.take(), bytes: limits.hostText),
                         remotePort: 443, enabled: false, proxied: false,
                         label: escapedDisplay(tags.take(), bytes: limits.displayText), preset: longestPreset)
    }
    var health = HealthSection()
    health.checkURL = loopbackURL("http://127.0.0.1:9/", tags.take(), bytes: limits.urlText)
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    let auditTag = tags.take()
    logging.auditLogPath = auditPrefix + "/" + auditTag + String(repeating: "a", count: limits.auditLogPath - auditPrefix.utf8.count - 1 - auditTag.utf8.count)
    func identity() -> String {
        let tag = tags.take()
        return "u" + tag + String(repeating: "a", count: limits.identity - 1 - tag.utf8.count)
    }
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: escapedDisplay(tags.take(), bytes: limits.displayText),
        proxy: proxy, auth: syntheticAuth(username: identity(), domain: identity(), workstation: identity()),
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: health, logging: logging
    )
}

func makeMaximumPreferences(_ url: String) -> AppPreferences {
    AppPreferences(showMenuBarIcon: false, floatingWindowEnabled: false, globalShortcutEnabled: false,
                   preferredBrowserTestURL: url, fileLoggingEnabled: false, automaticUpdateChecks: false)
}

/// Control bytes both writers spell as `\u00XX` (six bytes): 0x01...0x1F without the five short escapes.
let sixByteSymbols: [Unicode.Scalar] = (UInt8(0x01)...UInt8(0x1F))
    .filter { ![0x08, 0x09, 0x0A, 0x0C, 0x0D].contains($0) }
    .map { Unicode.Scalar($0) }

/// Format-only text (the private-editor-reply probe's unique-maximum): every value distinct, every byte a six-byte escape.
final class EscapeText {
    private var next = 0
    func text(_ bytes: Int, prefix: String = "") -> String {
        var tag = next
        next += 1
        var scalars = String.UnicodeScalarView()
        for _ in 0..<3 {
            scalars.append(sixByteSymbols[tag % sixByteSymbols.count])
            tag /= sixByteSymbols.count
        }
        return prefix + String(scalars) + String(repeating: "\u{01}", count: bytes - prefix.utf8.count - 3)
    }
}

/// The widest storable shape: every bounded text at its byte ceiling in six-byte escapes. It is a storable repair draft that
/// blocks Start (hosts and addresses fail validation), so it measures transfer, store and readback, and a Start that is held.
func makeEscapeMaximumConfig(port: Int) -> ProxyConfig {
    let limits = DomainResourceLimits.self
    let text = EscapeText()
    let wildcard = String(decoding: limits.wildcardPrefix, as: UTF8.self)
    var proxy = ProxySection()
    proxy.port = port
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.host = text.text(limits.hostText)
    proxy.allowedClients = (0..<limits.allowedClients).map { _ in text.text(limits.hostText) }
    let auth = syntheticAuth(username: text.text(limits.identity), domain: text.text(limits.identity), workstation: text.text(limits.identity))
    let upstreams = (0..<limits.upstreams).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: text.text(limits.displayText), host: text.text(limits.hostText),
                      port: 3128, enabled: false, priority: index)
    }
    var routing = RoutingSection()
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    routing.pacURL = text.text(limits.urlText)
    let content = limits.noProxyList - 2 - (limits.noProxyHosts - 1) - 2 * limits.noProxyHosts
    let symbols = content / 6
    routing.noProxyHosts = (0..<limits.noProxyHosts).map { index in
        var host = text.text(symbols / limits.noProxyHosts + (index < symbols % limits.noProxyHosts ? 1 : 0))
        if index == 0 { host += String(repeating: "x", count: content % 6) }
        return host
    }
    routing.forceProxyHosts = (0..<limits.forceProxyHosts).map { _ in text.text(limits.hostText) }
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = (0..<limits.dohProviders).map { _ in text.text(limits.urlText) }
    dns.entries = (0..<limits.dnsEntries).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: text.text(limits.hostText),
                       servers: (0..<limits.dnsServers).map { _ in text.text(limits.hostText) }, enabled: false)
    }
    dns.interceptRules = (0..<limits.interceptRules).map { index in
        DNSInterceptRule(id: syntheticUUID(3, index), pattern: text.text(limits.wildcardInterceptPattern, prefix: wildcard),
                         interceptIP: text.text(limits.hostText), enabled: false)
    }
    dns.transparentProxyIP = text.text(limits.hostText)
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<limits.tunnelDefinitions).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 20_000 + index, remoteHost: text.text(limits.hostText),
                         remotePort: 443, enabled: false, proxied: false, label: text.text(limits.displayText), preset: longestPreset)
    }
    var health = HealthSection()
    health.checkURL = text.text(limits.urlText)
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    logging.auditLogPath = text.text(limits.auditLogPath)
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: text.text(limits.displayText), proxy: proxy, auth: auth,
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: health, logging: logging
    )
}

let longestAuthMode = AuthenticationMode.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!

/// The widest configuration the CURRENT validator accepts (`validate()` reports nothing), so it saves and Starts:
/// - the fields `validate()` checks are valid: `proxy.host` loopback, the bypass list (safe tokens, exact 8,192 B aggregate),
///   the force-proxy hosts (253 B safe tokens), the intercept patterns (`*.` + a 253 B domain) and IPv4 intercept targets
///   (15 B), and a PAC URL without user info;
/// - every field it does not check carries six-byte `\u00XX` escapes at its byte ceiling: upstream names and hosts, tunnel labels
///   and hosts, DNS domains and servers, allowed clients, DoH, PAC and health-check URLs, identities, profile name, audit path and
///   the (disabled) transparent-proxy address;
/// - numbers and enums are widened within their validated ranges (ports 65535-n, upstream priorities near `Int.max`, the
///   longest auth mode and preset); durations stay at their defaults so none becomes invalid.
/// Every upstream and tunnel is disabled and PAC routing and DNS are off. With no enabled upstream, the direct-mode cause is
/// `noUpstreamsConfigured`, which runs no upstream health loop (`DirectModeCause.runsUpstreamHealthLoop`), so the escaped URLs
/// and hosts are never dispatched. This is not a proven absolute bound: it is the widest point this probe built.
func makeValidatorWidestConfig(port: Int) -> ProxyConfig {
    let limits = DomainResourceLimits.self
    let text = EscapeText()
    let tags = Tags()
    var proxy = ProxySection()
    proxy.host = "127.0.0.1"
    proxy.port = port
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.allowedClients = (0..<limits.allowedClients).map { _ in text.text(limits.hostText) }
    let upstreams = (0..<limits.upstreams).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: text.text(limits.displayText), host: text.text(limits.hostText),
                      port: 65_535 - index, enabled: false, priority: Int.max - index)
    }
    var routing = RoutingSection()
    routing.pacURL = text.text(limits.urlText)
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    let content = limits.noProxyList - 2 - (limits.noProxyHosts - 1) - 2 * limits.noProxyHosts
    routing.noProxyHosts = (0..<limits.noProxyHosts).map { index in
        dnsName(tags.take(), bytes: content / limits.noProxyHosts + (index < content % limits.noProxyHosts ? 1 : 0))
    }
    routing.forceProxyHosts = (0..<limits.forceProxyHosts).map { _ in dnsName(tags.take(), bytes: limits.hostText) }
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = (0..<limits.dohProviders).map { _ in text.text(limits.urlText) }
    dns.entries = (0..<limits.dnsEntries).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: text.text(limits.hostText),
                       servers: (0..<limits.dnsServers).map { _ in text.text(limits.hostText) }, enabled: false)
    }
    dns.interceptRules = (0..<limits.interceptRules).map { index in
        DNSInterceptRule(id: syntheticUUID(3, index), pattern: "*." + dnsName(tags.take(), bytes: limits.hostText),
                         interceptIP: String(format: "127.%03ld.%03ld.%03ld", 200, 100 + index / 2, 100 + index % 2), enabled: false)
    }
    dns.transparentProxyIP = text.text(limits.hostText)
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<limits.tunnelDefinitions).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 65_535 - index, remoteHost: text.text(limits.hostText),
                         remotePort: 65_535, enabled: false, proxied: false, label: text.text(limits.displayText), preset: longestPreset)
    }
    var health = HealthSection()
    health.checkURL = text.text(limits.urlText)
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    logging.auditLogPath = text.text(limits.auditLogPath)
    let auth = AuthSection(mode: longestAuthMode, username: text.text(limits.identity), domain: text.text(limits.identity),
                           workstation: text.text(limits.identity), pendingHandshakeGlobalLimit: 512, pendingHandshakesPerSource: 128)
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: text.text(limits.displayText), proxy: proxy, auth: auth,
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: health, logging: logging
    )
}

/// The small configuration's canonical runtime file, padded with JSON whitespace after its opening brace to exactly the
/// 8,388,608-byte runtime file budget. Whitespace is valid and ignored, so the typed values stay small.
func paddedRuntimeFile(_ config: ProxyConfig) throws -> Data {
    let staged = try ProxyConfigPersistence.stagedFile(for: config).bytes
    guard let brace = staged.firstIndex(of: UInt8(ascii: "{")) else { throw ProbeError("noBrace") }
    let padding = DomainResourceLimits.runtimeConfigurationFileBytes - staged.count
    guard padding >= 0 else { throw ProbeError("paddingNegative") }
    var padded = Data(capacity: DomainResourceLimits.runtimeConfigurationFileBytes)
    padded.append(staged[...brace])
    padded.append(Data(repeating: UInt8(ascii: " "), count: padding))
    padded.append(staged[staged.index(after: brace)...])
    return padded
}

/// What one flow mode runs over.
struct Fixture {
    let name: String
    let config: ProxyConfig
    let preferences: AppPreferences
    /// Whether the fixture is semantically valid, so a private Start must bring the proxy up.
    let startable: Bool
    /// Read and save cycles after the first save, sampled after each, for retention.
    let repeatCycles: Int
    /// Builds the bytes that replace the written runtime file before open, when set. Built at write time and dropped after it,
    /// so the probe does not hold the padded file through the mode.
    let runtimeFile: (() throws -> Data)?
}

// MARK: - Candidate profile

/// One explicit CANDIDATE control-service profile for this experiment. Every value is a bounded experimental constant, not a
/// shipping default or an owner decision. `retainedByteCeiling` is the actual initializer's own budget for these values, found by
/// bisecting the ceiling the initializer accepts (its budget member is internal, so it is not read directly).
enum CandidateProfile {
    static let maxRequestBytes = 65_536
    static let maxReplyBytes = 65_536
    static let aliasCapacityPerPartition = 64
    static let aliasByteCapacityPerPartition = 16_384
    /// Alias, outcome and collection-row retention. Short on purpose in this run: it also tests whether the composition, and so
    /// the host and its root, outlive the dropped clients until a retention wait ends.
    static let retentionSeconds: Int64 = 300

    static func limits(ceiling: Int, aliasBytes: Int = aliasByteCapacityPerPartition) throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: maxRequestBytes, maxReplyBytes: maxReplyBytes,
            aliasCapacityPerPartition: aliasCapacityPerPartition, aliasByteCapacityPerPartition: aliasBytes,
            ordinaryPendingCapacity: 4, outcomeCapacity: 64, outcomeByteCapacity: 65_536,
            retentionAge: .seconds(retentionSeconds), janitorBatch: 16,
            ordinaryLaneCapacity: 4, readLaneCapacity: 4, streamLaneCapacity: 4, stopLaneCapacityPerModule: 1, subscriberLimit: 4,
            ringCapacity: 256, ringByteCapacity: 262_144, maxEventBytes: 4_096,
            ingressCapacity: 256, ingressByteCapacity: 262_144, drainItemsPerTurn: 32, drainBytesPerTurn: 65_536,
            controlLogCapacity: 64, controlLogByteCapacity: 65_536, replayChunkItems: 32, replayChunkBytes: 32_768,
            collectionRowCapacity: 512, collectionByteCapacity: 262_144, collectionProofCapacityPerKind: 4,
            collectionRowRevisionsPerKind: 2, collectionRetainedByteCapacity: 524_288,
            collectionRowRetentionAge: .seconds(retentionSeconds),
            latestSnapshotByteCapacity: 32_768, subscriberRecordBytes: 1_024, retainedByteCeiling: ceiling
        )
    }

    /// The smallest ceiling the actual initializer accepts, or nil when even the widest is refused.
    static func bisectBudget(aliasBytes: Int = aliasByteCapacityPerPartition) -> Int? {
        func accepts(_ ceiling: Int) -> Bool {
            do {
                _ = try limits(ceiling: ceiling, aliasBytes: aliasBytes)
                return true
            } catch {
                return false
            }
        }
        var low = 0
        var high = 1 << 40
        guard accepts(high) else { return nil }
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if accepts(middle) { high = middle } else { low = middle }
        }
        return high
    }
}

// MARK: - Host run

@MainActor
final class HostRun {
    let out: Output
    let stages: StageRecorder
    let scratch: URL
    let environment: RuntimeEnvironment
    let fakes: Fakes
    let releaseFailures = ReleaseFailures()
    var session: StateRootSession?
    var host: RuntimeHost?
    weak var weakHost: RuntimeHost?
    var clients: RuntimeInMemoryClients?
    var incarnation: ControlHostIncarnation?

    init(out: Output, stages: StageRecorder, scratch: URL) throws {
        self.out = out
        self.stages = stages
        self.scratch = scratch
        environment = RuntimeEnvironment.isolated(stateDirectory: scratch.appendingPathComponent("state", isDirectory: true))
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
        fakes = Fakes(machine: machine, privilege: GatedPrivilege(base: machine), files: CountingStateFiles(), home: home)
    }

    func acquire() throws {
        let failures = releaseFailures
        let outcome = StateRootBootstrap.acquire(
            environment, createRootIfMissing: true, fileSystem: OSStateRootFileSystem(), leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failures.record($0) }
        )
        switch outcome {
        case .success(let acquired): session = acquired
        case .failure: throw ProbeError("rootRefused")
        }
    }

    func open() async throws {
        guard let session else { throw ProbeError("noSession") }
        let opened = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(), startupAllowsMissing: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), terminalExit: {}, effects: fakes.effects()
        )
        host = opened
        weakHost = opened
    }

    func compose(limits: RuntimeServiceLimits) throws {
        guard let host else { throw ProbeError("noHost") }
        clients = try host.makeInMemoryControlClient(
            limits: limits, clientFrameLimits: try ControlFrameLimits(maxFrameBytes: CandidateProfile.maxReplyBytes),
            wireBudgetCap: .seconds(30)
        )
    }

    var control: any RuntimeClient { clients!.control }
    var editor: PrivateEditorClient { clients!.editor }

    func deadline(_ seconds: Int = 60) -> RuntimeDeadline {
        RuntimeDeadline.after(.seconds(seconds), from: .now)
    }

    func readSnapshot() async throws -> (ControlRuntimeSnapshot, Double) {
        let start = ContinuousClock.now
        let snapshot = try await control.readSnapshot(deadline: deadline())
        return (snapshot, elapsedMS(since: start))
    }

    func read() async throws -> (PrivateEditorObservation, Double) {
        guard let incarnation else { throw ProbeError("noIncarnation") }
        let start = ContinuousClock.now
        let answer = try await editor.read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
            budget: try ControlWireBudget(60_000), deadline: deadline()
        )
        let elapsed = elapsedMS(since: start)
        switch answer {
        case .observation(let observation): return (observation, elapsed)
        case .refused(let code): throw ProbeError("readRefused.\(code.rawValue)")
        case .admission: throw ProbeError("readAnsweredAdmission")
        }
    }

    /// One frozen update through the private client. The request is mapped inside the client's reservation.
    func submitUpdate(
        config: ProxyConfig, platform: PlatformIntegrationConfig, observed: PrivateEditorObservation,
        modules: PrivateModuleSlots<PrivateModuleIntent>, requestID: ControlRequestID = ControlRequestID(rawValue: UUID())
    ) async throws -> (ControlAdmission, Double) {
        guard let incarnation else { throw ProbeError("noIncarnation") }
        guard let runtimeBaseline = observed.components.runtime.baseline,
              let platformBaseline = observed.components.platform.baseline else { throw ProbeError("noBaseline") }
        let start = ContinuousClock.now
        let admission = try await editor.submit(requestID: requestID, deadline: deadline()) {
            try PrivateConfigurationBridge.makeRequest(
                config: config, platform: platform, requestID: requestID, incarnation: incarnation,
                budget: try ControlWireBudget(60_000), runtimeBaseline: runtimeBaseline, platformBaseline: platformBaseline,
                modules: modules
            )
        }
        return (admission, elapsedMS(since: start))
    }

    func submitPreferences(_ preferences: AppPreferences, observed: PrivateEditorObservation) async throws -> (ControlAdmission, Double) {
        guard let incarnation else { throw ProbeError("noIncarnation") }
        guard let baseline = observed.components.preferences.baseline else { throw ProbeError("noPreferencesBaseline") }
        let requestID = ControlRequestID(rawValue: UUID())
        let start = ContinuousClock.now
        let admission = try await editor.submitPreferences(requestID: requestID, deadline: deadline()) {
            try PrivateConfigurationBridge.makePreferencesRequest(
                preferences: preferences, requestID: requestID, incarnation: incarnation,
                budget: try ControlWireBudget(60_000), preferencesBaseline: baseline
            )
        }
        return (admission, elapsedMS(since: start))
    }

    func submitControl(_ command: ControlRuntimeCommand, requestID: ControlRequestID = ControlRequestID(rawValue: UUID())) async throws
        -> (ControlAdmission, Double)
    {
        guard let incarnation else { throw ProbeError("noIncarnation") }
        let start = ContinuousClock.now
        let admission = try await control.submit(command, requestID: requestID, expectedIncarnation: incarnation, deadline: deadline())
        return (admission, elapsedMS(since: start))
    }

    /// Polls the actual outcome lookup about every millisecond until the operation finished. Completion is measured from `since`.
    func awaitOutcome(_ admission: ControlAdmission, since start: ContinuousClock.Instant, timeout: Int = 120) async throws
        -> (outcome: ControlOperationOutcome?, ms: Double, lookups: Int)
    {
        guard case .accepted(let operation) = admission else { return (nil, elapsedMS(since: start), 0) }
        guard let incarnation else { throw ProbeError("noIncarnation") }
        let end = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lookups = 0
        while ContinuousClock.now < end {
            lookups += 1
            let lookup = try await control.outcome(of: operation, expectedIncarnation: incarnation, deadline: deadline())
            switch lookup {
            case .finished(let outcome): return (outcome, elapsedMS(since: start), lookups)
            case .unknown: return (nil, elapsedMS(since: start), lookups)
            case .pending: try await Task.sleep(for: .milliseconds(1))
            }
        }
        return (nil, elapsedMS(since: start), lookups)
    }

    /// Settles the stopped host and confirms its diagnostic flush. Only then are the clients and host dropped, the host's
    /// deallocation observed, the session dropped and the lease proven closed by a fresh acquisition; the scratch root is removed
    /// only when every proof agrees. Anything unconfirmed is pinned until process exit and reported.
    func release() async -> Bool {
        guard host != nil else {
            out.check(false, "release.hostPresent")
            return false
        }
        // No strong local of the host: it must be droppable below.
        let settleStart = ContinuousClock.now
        let settled = await self.host!.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(10)))
        let settleMS = elapsedMS(since: settleStart)
        let flushStart = ContinuousClock.now
        let flush = await self.host!.flushEvents()
        let flushMS = elapsedMS(since: flushStart)
        out.emit(["record": "release-settle", "settled": settled == .settled, "settleMS": settleMS,
                  "flushConfirmed": flush.allConfirmed, "flushMS": flushMS])
        out.check(settled == .settled, "release.settled")
        out.check(flush.allConfirmed, "release.flushConfirmed")
        guard settled == .settled, flush.allConfirmed else {
            pinEverything()
            return false
        }
        clients = nil
        self.host = nil
        let dropStart = ContinuousClock.now
        let dropDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while weakHost != nil, ContinuousClock.now < dropDeadline {
            do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
        }
        let hostGone = weakHost == nil
        out.emit(["record": "release-host", "hostDeallocated": hostGone, "deallocationWaitMS": elapsedMS(since: dropStart)])
        out.check(hostGone, "release.hostDeallocated")
        // The lease test runs either way. A live host holds the session, so it can only fail then; it never unlocks anything.
        session = nil
        let leaseStart = ContinuousClock.now
        var closed = false
        var attempts = 0
        let leaseDeadline = ContinuousClock.now.advanced(by: .seconds(hostGone ? 5 : 1))
        let failures = releaseFailures
        func acquireProbe() -> StateRootSession? {
            let outcome = StateRootBootstrap.acquire(
                environment, createRootIfMissing: true, fileSystem: OSStateRootFileSystem(), leasing: OSStateWriterLeasing(),
                onReleaseFailure: { failures.record($0) }
            )
            if case .success(let acquired) = outcome { return acquired }
            return nil
        }
        while !closed, ContinuousClock.now < leaseDeadline {
            attempts += 1
            var probe = acquireProbe()
            if probe != nil {
                closed = true
                // The probe's own lease is released here, explicitly, before any failure count is read.
                probe = nil
            } else {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
            _ = probe
        }
        // A second acquisition succeeds only once the probe's lease has actually been released.
        var confirmation = closed ? acquireProbe() : nil
        let probeReleased = confirmation != nil
        confirmation = nil
        _ = confirmation
        let closeFailures = releaseFailures.count
        out.emit(["record": "release-lease", "leaseReacquired": closed, "probeLeaseReleasedAndReacquired": probeReleased,
                  "attempts": attempts, "leaseWaitMS": elapsedMS(since: leaseStart), "closeFailures": closeFailures])
        out.check(closed && probeReleased && closeFailures == 0, "release.leaseClosed")
        guard hostGone, closed, probeReleased, closeFailures == 0 else {
            if let alive = weakHost { Pinned.objects.append(alive) }
            out.emit(["record": "pinned", "reason": "host or lease not released; host kept until process exit; scratch kept"])
            return false
        }
        do {
            try FileManager.default.removeItem(at: scratch)
            out.check(true, "release.scratchRemoved")
        } catch {
            out.check(false, "release.scratchRemoved")
        }
        return true
    }

    func pinEverything() {
        if let host { Pinned.objects.append(host) }
        if let session { Pinned.objects.append(session) }
        out.emit(["record": "pinned", "reason": "unconfirmed shutdown; host and root kept until process exit; scratch kept"])
    }
}

// MARK: - Frame measurement (actual codecs, re-encoding the actual values the clients received)

/// The ordinary v2 frame bytes for one body, through the production codec.
func ordinaryFrameBytes(_ body: ControlRuntimeBody) -> Int {
    do {
        let message = ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: body)
        return try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: 1 << 24)).count
    } catch {
        return -1
    }
}

func privateReplyFrameBytes(_ observation: PrivateEditorObservation, incarnation: ControlHostIncarnation) -> Int {
    do {
        let reply = PrivateEditorReply(requestID: ControlRequestID(rawValue: UUID()), hostIncarnation: incarnation,
                                       answer: .observation(observation))
        return try PrivateConfigurationEncoder.encode(reply).count
    } catch {
        return -1
    }
}

func privateRequestFrameBytes(
    config: ProxyConfig, platform: PlatformIntegrationConfig, observed: PrivateEditorObservation, incarnation: ControlHostIncarnation,
    modules: PrivateModuleSlots<PrivateModuleIntent>
) -> Int {
    do {
        guard let runtime = observed.components.runtime.baseline, let platformBaseline = observed.components.platform.baseline else {
            return -1
        }
        let request = try PrivateConfigurationBridge.makeRequest(
            config: config, platform: platform, requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
            budget: try ControlWireBudget(60_000), runtimeBaseline: runtime, platformBaseline: platformBaseline, modules: modules
        )
        return try PrivateConfigurationEncoder.encode(request).count
    } catch {
        return -1
    }
}

// MARK: - Modes

@MainActor
func emitProfile(_ out: Output) -> RuntimeServiceLimits? {
    guard let budget = CandidateProfile.bisectBudget(),
          let widerAlias = CandidateProfile.bisectBudget(aliasBytes: CandidateProfile.aliasByteCapacityPerPartition + 1_024) else {
        out.check(false, "profile.initializerAccepts")
        return nil
    }
    let charged = (widerAlias - budget) / 1_024
    // `RuntimePartition.all` (internal) lists ordinary, quit and one stop partition per module: read from the linked source, not
    // measurable through the package. The initializer's charge is measured above; a difference is an accounting discrepancy.
    let partitionsInSource = 2 + ControlModule.allCases.count
    out.emit(["record": "profile", "label": "CANDIDATE experimental profile; not a shipping default",
              "initializerBudgetBytes": budget,
              "initializerBudgetStatus": charged != partitionsInSource
                  ? "undercounts alias partitions; not a ceiling" : "alias partitions match source; candidate value, not a default",
              "aliasPartitionsChargedByInitializer": charged, "aliasPartitionsInSource": partitionsInSource,
              "aliasPartitionAccountingDiscrepancy": charged != partitionsInSource,
              "retentionSeconds": Int(CandidateProfile.retentionSeconds), "maxRequestBytes": CandidateProfile.maxRequestBytes, "maxReplyBytes": CandidateProfile.maxReplyBytes,
              "aliasByteCapacityPerPartition": CandidateProfile.aliasByteCapacityPerPartition,
              "privateRequestFrameCap": PrivateConfigurationFrame.maxRequestFrameBytes,
              "privateReplyFrameCap": PrivateConfigurationFrame.maxEditorReplyFrameBytes,
              "runtimeFileBytes": DomainResourceLimits.runtimeConfigurationFileBytes,
              "sidecarFileBytes": DomainResourceLimits.sidecarFileBytes])
    do {
        return try CandidateProfile.limits(ceiling: budget)
    } catch {
        out.check(false, "profile.acceptsOwnBudget")
        return nil
    }
}

/// small: scratch session, actual host open, composition, private read, frozen save, readback, preferences save, a private
/// proxy Start on a live loopback listener, status reads, an ordinary Stop, then the framed Quit with its ID-bound final save,
/// and the confirmed release.
@MainActor
func runFlow(_ run: HostRun, limits: RuntimeServiceLimits, fixture: Fixture) async throws {
    let out = run.out
    let stages = run.stages
    let config = fixture.config
    let port = config.proxy.port
    let platform = makePlatform()
    let preferences = fixture.preferences
    let problems = config.validate()
    out.emit(["record": "fixture", "fixture": fixture.name, "validationProblems": problems.count,
              "startBlockingProblems": problems.filter(\.blocksProxyStart).count,
              "resourceViolation": config.resourceViolation() == nil ? "none" : "violated",
              "upstreams": config.upstreams.count, "tunnels": config.tunnels.definitions.count,
              "tunnelCase": config.tunnels.definitions.count == 64 ? "primary-performance-64"
                  : config.tunnels.definitions.count == DomainResourceLimits.tunnelDefinitions ? "hard-ceiling-128" : "current-shape",
              "dnsEntries": config.dns.entries.count, "dnsServersPerEntry": config.dns.entries.first?.servers.count ?? 0,
              "interceptRules": config.dns.interceptRules.count, "allowedClients": config.proxy.allowedClients.count,
              "forceProxyHosts": config.routing.forceProxyHosts.count, "noProxyHosts": config.routing.noProxyHosts.count,
              "dohProviders": config.dns.dohProviders.count,
              "browserURLBytes": preferences.preferredBrowserTestURL.utf8.count])
    out.check(config.resourceViolation() == nil, "fixture.withinApprovedCeilings")
    out.check(problems.isEmpty == fixture.startable, "fixture.validityAsDeclared")
    stages.stage("fixture-built", ["probeHeld": "fixture"])

    try run.acquire()
    try ProxyConfigPersistence.save(config, in: run.environment)
    try PlatformConfigPersistence.save(platform, in: run.environment)
    try AppPreferencesPersistence.save(preferences, in: run.environment)
    if let makeRuntimeFile = fixture.runtimeFile {
        try makeRuntimeFile().write(to: run.environment.configFile)
    }
    let writtenBytes = (try? FileManager.default.attributesOfItem(atPath: run.environment.configFile.path)[.size] as? Int) ?? -1
    stages.stage("root-acquired-files-written", ["runtimeFileBytes": writtenBytes])

    var start = ContinuousClock.now
    try await run.open()
    stages.stage("host-opened", ["openMS": elapsedMS(since: start)].merging(run.fakes.files.counters) { $1 })

    try run.compose(limits: limits)
    let (snapshot, snapshotMS) = try await run.readSnapshot()
    run.incarnation = snapshot.stamp.incarnation
    stages.stage("clients-composed", ["firstSnapshotMS": snapshotMS])

    // Copy discipline: across stages the probe holds only the fixture value (the stand-in for the UI's draft source). Each step's
    // observation and mapped draft (the client/UI copies) live inside one block; a stage taken inside a block says so in
    // `probeHeld`, and every other stage is taken after its block has ended.
    var codecSizes: [String: Any] = ["record": "codec-sizes", "fixture": fixture.name]
    var savedBaseline: PrivateBaseline?
    var expected = config
    expected.logging.verbose = true
    do {
        let (observed, readMS) = try await run.read()
        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        out.check(values.config == config && values.platform == platform && values.preferences == preferences, "read.valuesEqualSaved")
        stages.stage("private-read", ["readMS": readMS, "probeHeld": "fixture,observation,mapped-draft"])

        var edited = values.config
        edited.logging.verbose = true
        start = ContinuousClock.now
        let (saveAdmission, saveAdmissionMS) = try await run.submitUpdate(
            config: edited, platform: values.platform, observed: observed, modules: allSaveOnly
        )
        let saved = try await run.awaitOutcome(saveAdmission, since: start)
        var saveRecord: [String: Any] = ["admission": admissionLabel(saveAdmission), "admissionMS": saveAdmissionMS,
                                         "settledMS": saved.ms, "lookups": saved.lookups, "outcome": outcomeLabel(saved.outcome),
                                         "probeHeld": "fixture,observation,mapped-draft,edited-draft"]
        if case .configurationSettled(let receipt)? = saved.outcome {
            saveRecord["runtimeWrite"] = writeLabel(receipt.runtime.write)
            saveRecord["platformWrite"] = writeLabel(receipt.platform.write)
            saveRecord["runtimeBaselineVersion"] = receipt.runtime.baseline.map { Int(clamping: $0.version) } ?? -1
            saveRecord["lookupReplyFrameBytes"] = ordinaryFrameBytes(.response(.lookup(.finished(.configurationSettled(receipt)))))
            savedBaseline = receipt.runtime.baseline
        }
        out.check(savedBaseline != nil, "save.runtimeVerified")
        stages.stage("frozen-save-settled", saveRecord.merging(run.fakes.files.counters) { $1 })
        // Measured after the stage, inside the block, so the re-encodings never sit inside a measured phase of the host.
        codecSizes["readReplyFrameBytes"] = privateReplyFrameBytes(observed, incarnation: run.incarnation!)
        codecSizes["saveRequestFrameBytes"] = privateRequestFrameBytes(config: edited, platform: values.platform, observed: observed,
                                                                       incarnation: run.incarnation!, modules: allSaveOnly)
    }
    stages.stage("save-step-released", ["probeHeld": "fixture"])

    do {
        let (readback, readbackMS) = try await run.read()
        let readbackValues = try PrivateConfigurationBridge.makeValues(from: readback)
        out.check(readbackValues.config == expected, "readback.valuesEqualSaved")
        out.check(readback.components.runtime.baseline == savedBaseline, "readback.baselineIsReceiptBaseline")
        stages.stage("private-readback", ["readMS": readbackMS, "probeHeld": "fixture,observation,mapped-draft"])
    }

    // Retention: read and frozen-save cycles on the same host, each sampled once every copy of the cycle is released.
    @MainActor
    func cycle(_ index: Int) async throws -> (saved: Bool, readMS: Double, saveMS: Double) {
        let readStart = ContinuousClock.now
        let current = try await run.read().0
        let readMS = elapsedMS(since: readStart)
        var cycleConfig = try PrivateConfigurationBridge.makeValues(from: current).config
        cycleConfig.logging.verbose = index % 2 != 0
        let saveStart = ContinuousClock.now
        let (admission, _) = try await run.submitUpdate(config: cycleConfig, platform: platform, observed: current, modules: allSaveOnly)
        let settled = try await run.awaitOutcome(admission, since: saveStart)
        var saved = false
        if case .configurationSettled(let receipt)? = settled.outcome { saved = receipt.runtime.baseline != nil }
        return (saved, readMS, settled.ms)
    }
    for index in 0..<fixture.repeatCycles {
        let result = try await cycle(index)
        out.check(result.saved, "repeat.cycleSaved")
        stages.stage("repeat-cycle", ["cycle": index + 1, "readMS": result.readMS, "saveSettledMS": result.saveMS, "probeHeld": "fixture"])
    }

    var preferencesWritten = false
    var preferencesAdmissionMS = 0.0
    var preferencesSettledMS = 0.0
    do {
        let (afterCycles, _) = try await run.read()
        var editedPreferences = try PrivateConfigurationBridge.makeValues(from: afterCycles).preferences
        editedPreferences.automaticUpdateChecks = true
        start = ContinuousClock.now
        let (preferencesAdmission, admissionMS) = try await run.submitPreferences(editedPreferences, observed: afterCycles)
        let preferencesSaved = try await run.awaitOutcome(preferencesAdmission, since: start)
        if case .preferencesSettled(let receipt)? = preferencesSaved.outcome {
            preferencesWritten = receipt.preferences.write == .persisted(reportedError: false)
        }
        preferencesAdmissionMS = admissionMS
        preferencesSettledMS = preferencesSaved.ms
    }
    out.check(preferencesWritten, "preferences.persisted")
    stages.stage("preferences-save-settled", ["admissionMS": preferencesAdmissionMS, "settledMS": preferencesSettledMS,
                                              "probeHeld": "fixture"])

    // A private proxy Start with the frozen values, on a live loopback listener over the fake machine's system proxy.
    var proxyResult = "none"
    var startReceiptFrame = -1
    var startAdmissionMS = 0.0
    var started: (outcome: ControlOperationOutcome?, ms: Double, lookups: Int) = (nil, 0, 0)
    do {
        let (beforeStart, _) = try await run.read()
        let startValues = try PrivateConfigurationBridge.makeValues(from: beforeStart)
        start = ContinuousClock.now
        let (startAdmission, admissionMS) = try await run.submitUpdate(
            config: startValues.config, platform: startValues.platform, observed: beforeStart,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: beforeStart.modules.proxy.lifecycleRevision),
                                        dns: .saveOnly, tunnels: .saveOnly)
        )
        startAdmissionMS = admissionMS
        started = try await run.awaitOutcome(startAdmission, since: start)
        if case .configurationSettled(let receipt)? = started.outcome {
            proxyResult = receipt.modules.first { $0.module == .proxy }?.result.rawValue ?? "absent"
            startReceiptFrame = ordinaryFrameBytes(.response(.lookup(.finished(.configurationSettled(receipt)))))
        }
    }
    let applied = run.fakes.machine.service("Wi-Fi").webProxy
    if fixture.startable {
        out.check(proxyResult == "started", "start.proxyStarted")
        out.check(applied.enabled && applied.port == String(port), "start.systemProxyNamesListener")
    } else {
        out.check(proxyResult != "started" && !applied.enabled, "start.formatOnlyFixtureHeld")
    }
    stages.stage("private-start-settled", ["admissionMS": startAdmissionMS, "settledMS": started.ms,
                                           "outcome": outcomeLabel(started.outcome), "proxyResult": proxyResult,
                                           "lookupReplyFrameBytes": startReceiptFrame, "probeHeld": "fixture"])

    var statusMS: [Double] = []
    var snapshotFrame = 0
    for _ in 0..<20 {
        let (current, elapsed) = try await run.readSnapshot()
        statusMS.append(elapsed)
        snapshotFrame = ordinaryFrameBytes(.response(.snapshot(current)))
    }
    let (running, _) = try await run.readSnapshot()
    let proxyRunning = running.proxyState == .running
    out.check(proxyRunning == fixture.startable, "status.proxyStateAsExpected")
    // A format-only fixture's Start is held, so its status and Stop are NOT live-Stop responsiveness evidence.
    let condition = proxyRunning ? "idle-running" : "proxy-not-running-start-held"
    statusMS.sort()
    out.emit(["record": "status-latency", "condition": condition, "proxyRunning": proxyRunning, "samples": statusMS.count,
              "p50MS": statusMS[statusMS.count / 2], "maxMS": statusMS.last!, "snapshotReplyFrameBytes": snapshotFrame])

    start = ContinuousClock.now
    let (stopAdmission, stopAdmissionMS) = try await run.submitControl(.stop(.proxy))
    let stopped = try await run.awaitOutcome(stopAdmission, since: start)
    let (afterStop, _) = try await run.readSnapshot()
    let stopCompleted = if case .completed(let completion)? = stopped.outcome { completion.command == .stop } else { false }
    out.check(stopCompleted, "stop.completed")
    out.check(afterStop.proxyState != .running && !run.fakes.machine.service("Wi-Fi").webProxy.enabled
              && !loopbackAccepts(port), "stop.outcomeVerified")
    out.emit(["record": "stop-latency", "condition": condition, "proxyRunning": proxyRunning, "admission": admissionLabel(stopAdmission),
              "admissionMS": stopAdmissionMS, "completionMS": stopped.ms, "lookups": stopped.lookups])
    stages.stage("ordinary-stop-settled")

    // The framed Quit with its ID-bound reserved configuration save, under one total deadline.
    var quitRecord: [String: Any] = ["probeHeld": "fixture"]
    do {
        let (beforeQuit, _) = try await run.read()
        let quitValues = try PrivateConfigurationBridge.makeValues(from: beforeQuit)
        let finalSave = ControlRequestID(rawValue: UUID())
        start = ContinuousClock.now
        let (quitAdmission, quitAdmissionMS) = try await run.submitControl(
            .quit(total: try ControlWireBudget(60_000), flush: try ControlQuitFlush(configuration: finalSave, preferences: nil))
        )
        var finalConfig = quitValues.config
        finalConfig.logging.verbose = false
        let finalStart = ContinuousClock.now
        let (finalAdmission, _) = try await run.submitUpdate(
            config: finalConfig, platform: quitValues.platform, observed: beforeQuit, modules: allSaveOnly, requestID: finalSave
        )
        let finalSaved = try await run.awaitOutcome(finalAdmission, since: finalStart)
        let quitDone = try await run.awaitOutcome(quitAdmission, since: start)
        var finalPersisted = false
        if case .configurationSettled(let receipt)? = finalSaved.outcome {
            finalPersisted = receipt.runtime.write == .persisted(reportedError: false)
        }
        let quitCompleted = if case .completed(let completion)? = quitDone.outcome { completion.command == .quit } else { false }
        out.check(admissionLabel(finalAdmission) == "accepted" && finalPersisted, "quit.reservedFinalSavePersisted")
        out.check(quitCompleted, "quit.completed")
        quitRecord["quitAdmissionMS"] = quitAdmissionMS
        quitRecord["quitCompletionMS"] = quitDone.ms
        quitRecord["finalSaveMS"] = finalSaved.ms
    }
    stages.stage("framed-quit-settled", quitRecord)

    out.emit(codecSizes)
    out.emit(["record": "fakes", "pacFetches": run.fakes.pac.fetchCount, "gssCalls": run.fakes.gss.calls,
              "portHolderLookups": run.fakes.probe.lookupCount, "privilegedCommands": run.fakes.machine.privilege.commands.count])
    out.check(run.fakes.pac.fetchCount == 0 && run.fakes.gss.calls == 0, "fakes.noPACOrGSS")
}

/// Lifetime bisection at the package boundary: each mode goes one step further than the last, then quits through
/// `RuntimeHost.shutdown` and runs the same release proofs. Which step first leaves the host alive after its clients are dropped
/// names the holder's region without any internal hook.
let lifetimeModes = ["lifetime-open", "lifetime-composed", "lifetime-read", "lifetime-save", "lifetime-start"]

@MainActor
func runLifetime(_ run: HostRun, limits: RuntimeServiceLimits, depth: Int) async throws {
    let out = run.out
    let port = try reserveLoopbackPort()
    let config = makeSmallConfig(port: port)
    try run.acquire()
    try ProxyConfigPersistence.save(config, in: run.environment)
    try PlatformConfigPersistence.save(makePlatform(), in: run.environment)
    try AppPreferencesPersistence.save(makeSmallPreferences(), in: run.environment)
    try await run.open()
    if depth >= 1 {
        try run.compose(limits: limits)
        run.incarnation = try await run.readSnapshot().0.stamp.incarnation
    }
    var observed: PrivateEditorObservation?
    if depth >= 2 { observed = try await run.read().0 }
    if depth >= 3, let current = observed {
        var edited = config
        edited.logging.verbose = true
        let start = ContinuousClock.now
        let (admission, _) = try await run.submitUpdate(config: edited, platform: makePlatform(), observed: current, modules: allSaveOnly)
        let saved = try await run.awaitOutcome(admission, since: start)
        out.check(outcomeLabel(saved.outcome) == "configurationSettled", "lifetime.saveSettled")
        observed = try await run.read().0
    }
    if depth >= 4, let current = observed {
        let values = try PrivateConfigurationBridge.makeValues(from: current)
        var start = ContinuousClock.now
        let (admission, _) = try await run.submitUpdate(
            config: values.config, platform: values.platform, observed: current,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: current.modules.proxy.lifecycleRevision),
                                        dns: .saveOnly, tunnels: .saveOnly)
        )
        let started = try await run.awaitOutcome(admission, since: start)
        out.check(outcomeLabel(started.outcome) == "configurationSettled", "lifetime.startSettled")
        start = ContinuousClock.now
        let (stop, _) = try await run.submitControl(.stop(.proxy))
        let stopped = try await run.awaitOutcome(stop, since: start)
        out.check(outcomeLabel(stopped.outcome) == "completed.stop", "lifetime.stopCompleted")
    }
    await run.host?.shutdown()
    out.emit(["record": "lifetime-depth", "depth": depth])
}

// MARK: - Latency modes: contention, held phases, cancel

/// A frozen save-only or Start update through the private client, off the main actor.
func privateSubmit(
    _ editor: PrivateEditorClient, incarnation: ControlHostIncarnation, config: ProxyConfig, platform: PlatformIntegrationConfig,
    observed: PrivateEditorObservation, modules: PrivateModuleSlots<PrivateModuleIntent>,
    requestID: ControlRequestID = ControlRequestID(rawValue: UUID()), deadline: RuntimeDeadline,
    producerHold: (@Sendable () -> Void)? = nil
) async throws -> ControlAdmission {
    guard let runtimeBaseline = observed.components.runtime.baseline,
          let platformBaseline = observed.components.platform.baseline else { throw ProbeError("noBaseline") }
    return try await editor.submit(requestID: requestID, deadline: deadline) {
        producerHold?()
        return try PrivateConfigurationBridge.makeRequest(
            config: config, platform: platform, requestID: requestID, incarnation: incarnation,
            budget: try ControlWireBudget(60_000), runtimeBaseline: runtimeBaseline, platformBaseline: platformBaseline,
            modules: modules
        )
    }
}

func privateObservation(_ editor: PrivateEditorClient, incarnation: ControlHostIncarnation, deadline: RuntimeDeadline) async throws
    -> PrivateEditorObservation
{
    let answer = try await editor.read(requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                                       budget: try ControlWireBudget(60_000), deadline: deadline)
    guard case .observation(let observation) = answer else { throw ProbeError("readNotObservation") }
    return observation
}

func pollOutcome(_ control: any RuntimeClient, incarnation: ControlHostIncarnation, admission: ControlAdmission) async throws
    -> ControlOperationOutcome?
{
    guard case .accepted(let operation) = admission else { return nil }
    let end = ContinuousClock.now.advanced(by: .seconds(120))
    while ContinuousClock.now < end {
        let lookup = try await control.outcome(of: operation, expectedIncarnation: incarnation,
                                               deadline: RuntimeDeadline.after(.seconds(30), from: .now))
        switch lookup {
        case .finished(let outcome): return outcome
        case .unknown: return nil
        case .pending: try await Task.sleep(for: .milliseconds(2))
        }
    }
    return nil
}

final class WorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var completed = 0
    private var finished = false
    private var errors: [String] = []

    func set(inFlight value: Bool) { lock.withLock { inFlight = value } }
    func exchangeDone() { lock.withLock { completed += 1 } }
    func finish() { lock.withLock { finished = true } }
    func fail(_ label: String) { lock.withLock { errors.append(label) } }
    var snapshot: (inFlight: Bool, completed: Int, finished: Bool, errors: [String]) {
        lock.withLock { (inFlight, completed, finished, errors) }
    }
}

/// Large private work: alternating reads and frozen save-only updates of the escape maximum (about 7.4 MB per frame).
func largePrivateWork(
    _ editor: PrivateEditorClient, control: any RuntimeClient, incarnation: ControlHostIncarnation, config: ProxyConfig,
    platform: PlatformIntegrationConfig, iterations: Int, state: WorkerState
) async {
    var current = config
    for index in 0..<iterations {
        do {
            state.set(inFlight: true)
            let observed = try await privateObservation(editor, incarnation: incarnation, deadline: .after(.seconds(60), from: .now))
            state.exchangeDone()
            current.logging.verbose = index % 2 == 0
            let admission = try await privateSubmit(editor, incarnation: incarnation, config: current, platform: platform,
                                                    observed: observed, modules: allSaveOnly, deadline: .after(.seconds(60), from: .now))
            state.exchangeDone()
            state.set(inFlight: false)
            let outcome = try await pollOutcome(control, incarnation: incarnation, admission: admission)
            if outcomeLabel(outcome) != "configurationSettled" { state.fail("save.\(outcomeLabel(outcome))") }
        } catch {
            state.set(inFlight: false)
            state.fail(errorLabel(error))
        }
    }
    state.finish()
}

func percentiles(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["samples": 0] }
    let sorted = values.sorted()
    return ["samples": sorted.count, "p50MS": sorted[sorted.count / 2], "p90MS": sorted[(sorted.count * 9) / 10],
            "maxMS": sorted.last!]
}

extension HostRun {
    /// Opens the actual host over the valid maximum, composes the clients and Starts the proxy through a private update.
    func openRunningValidMaximum(limits: RuntimeServiceLimits) async throws -> (config: ProxyConfig, port: Int) {
        let port = try reserveLoopbackPort()
        return try await openRunning(limits: limits, config: makeValidMaximumConfig(port: port, auditPrefix: scratch.path + "/audit"))
    }

    /// Opens the actual host over `config`, composes the clients and Starts the proxy through a private update.
    func openRunning(limits: RuntimeServiceLimits, config: ProxyConfig) async throws -> (config: ProxyConfig, port: Int) {
        let port = config.proxy.port
        try acquire()
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(makePlatform(), in: environment)
        try AppPreferencesPersistence.save(makeSmallPreferences(), in: environment)
        try await open()
        try compose(limits: limits)
        incarnation = try await readSnapshot().0.stamp.incarnation
        let observed = try await read().0
        let start = ContinuousClock.now
        let (admission, _) = try await submitUpdate(
            config: config, platform: makePlatform(), observed: observed,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision),
                                        dns: .saveOnly, tunnels: .saveOnly)
        )
        let started = try await awaitOutcome(admission, since: start)
        var proxyStarted = false
        if case .configurationSettled(let receipt)? = started.outcome {
            proxyStarted = receipt.modules.contains { $0.module == .proxy && $0.result == .started }
        }
        out.check(proxyStarted, "setup.proxyStarted")
        return (config, port)
    }

    /// One ordinary Stop: admission latency, completion latency through the outcome lookup, and the verified outcome.
    func measuredStop(_ module: ControlModule, condition: String) async throws -> ControlOperationOutcome? {
        let start = ContinuousClock.now
        let (admission, admissionMS) = try await submitControl(.stop(module))
        let done = try await awaitOutcome(admission, since: start)
        out.emit(["record": "stop-latency", "condition": condition, "module": module.rawValue, "admission": admissionLabel(admission),
                  "admissionMS": admissionMS, "completionMS": done.ms, "lookups": done.lookups, "outcome": outcomeLabel(done.outcome)])
        return done.outcome
    }

    func statusSamples(_ count: Int, condition: String) async throws {
        var samples: [Double] = []
        for _ in 0..<count {
            samples.append(try await readSnapshot().1)
        }
        var record = percentiles(samples)
        record["record"] = "status-latency"
        record["condition"] = condition
        out.emit(record)
    }

    /// The framed Quit with no reserved save, for modes whose last state is not a save.
    func plainQuit() async throws {
        let start = ContinuousClock.now
        let (admission, _) = try await submitControl(.quit(total: try ControlWireBudget(60_000), flush: .none))
        let done = try await awaitOutcome(admission, since: start)
        out.check(outcomeLabel(done.outcome) == "completed.quit", "quit.completed")
    }
}

/// The observed stage of the one save-only transfer of B beside the live A.
final class TransferPhase: @unchecked Sendable {
    private let lock = NSLock()
    private var current = "not-started"
    private var boundaries: [String: Double] = [:]
    private var settled: [String: Any] = [:]
    private let start = ContinuousClock.now

    func enter(_ phase: String) {
        lock.withLock {
            current = phase
            boundaries[phase] = elapsedMS(since: start)
        }
    }

    func settle(_ facts: [String: Any]) { lock.withLock { settled = facts } }
    var phase: String { lock.withLock { current } }
    var record: (boundaries: [String: Double], settled: [String: Any]) { lock.withLock { (boundaries, settled) } }
}

/// One read of the live A, then one frozen SAVE-ONLY update carrying the escape-heavy B (about 7.4 MB), then its store work.
/// Phases are boundaries this task observes: `update-exchange` is the actual client mapping, encoding, transfer, host decode and
/// admission, with no hold; `store-save` is from admission to settlement (the store's stage, write and readback). B is never
/// applied: every module intent is save-only.
func transferB(
    _ editor: PrivateEditorClient, control: any RuntimeClient, incarnation: ControlHostIncarnation, b: ProxyConfig,
    platform: PlatformIntegrationConfig, phase: TransferPhase
) async {
    do {
        phase.enter("read-exchange")
        let observed = try await privateObservation(editor, incarnation: incarnation, deadline: .after(.seconds(60), from: .now))
        phase.enter("update-exchange")
        let admission = try await privateSubmit(editor, incarnation: incarnation, config: b, platform: platform, observed: observed,
                                                modules: allSaveOnly, deadline: .after(.seconds(60), from: .now))
        phase.enter("store-save")
        let outcome = try await pollOutcome(control, incarnation: incarnation, admission: admission)
        var facts: [String: Any] = ["admission": admissionLabel(admission), "outcome": outcomeLabel(outcome)]
        if case .configurationSettled(let receipt)? = outcome {
            facts["runtimeWrite"] = writeLabel(receipt.runtime.write)
            facts["appliedField"] = receipt.applied.map { $0 ? "true" : "false" } ?? "absent"
            facts["moduleReceipts"] = receipt.modules.count
        }
        phase.settle(facts)
    } catch {
        phase.settle(["error": errorLabel(error)])
    }
    phase.enter("done")
}

/// contention-encode / contention-store: a LIVE small A runs its loopback listener while the escape-heavy B is transferred and
/// saved save-only beside it. One ordinary proxy Stop is admitted when B's observed stage is `target`; its admission, completion
/// and physical effect (listener closed, fake system proxy cleared) are measured, and status is sampled through every stage.
@MainActor
func runLiveTransfer(_ run: HostRun, limits: RuntimeServiceLimits, target: String) async throws {
    let out = run.out
    let port = try reserveLoopbackPort()
    let a = makeSmallConfig(port: port)
    _ = try await run.openRunning(limits: limits, config: a)
    let (running, _) = try await run.readSnapshot()
    out.check(running.proxyState == .running && loopbackAccepts(port), "liveA.listenerAccepts")
    try await run.statusSamples(20, condition: "live-a-idle")
    run.stages.stage("live-a-running")

    let b = makeEscapeMaximumConfig(port: try reserveLoopbackPort())
    let phase = TransferPhase()
    let editor = run.editor
    let control = run.control
    let incarnation = run.incarnation!
    let transfer = Task.detached { await transferB(editor, control: control, incarnation: incarnation, b: b, platform: makePlatform(), phase: phase) }
    var samples: [String: [Double]] = [:]
    var stopFacts: [String: Any]?
    while phase.phase != "done" {
        let current = phase.phase
        let (_, elapsed) = try await run.readSnapshot()
        samples[current, default: []].append(elapsed)
        if stopFacts == nil, current == target {
            let start = ContinuousClock.now
            let (admission, admissionMS) = try await run.submitControl(.stop(.proxy))
            let atAdmission = phase.phase
            let done = try await run.awaitOutcome(admission, since: start)
            let listenerClosed = !loopbackAccepts(port)
            let cleared = !run.fakes.machine.service("Wi-Fi").webProxy.enabled
            let (after, _) = try await run.readSnapshot()
            stopFacts = ["record": "stop-latency", "condition": "live-a-during-b-\(target)", "proxyRunning": true,
                         "admission": admissionLabel(admission), "admissionMS": admissionMS, "completionMS": done.ms,
                         "outcome": outcomeLabel(done.outcome), "transferPhaseAtAdmission": atAdmission,
                         "transferPhaseAtCompletion": phase.phase, "listenerClosed": listenerClosed,
                         "systemProxyCleared": cleared, "snapshotStopped": after.proxyState != .running]
            out.emit(stopFacts!)
            out.check(outcomeLabel(done.outcome) == "completed.stop" && listenerClosed && cleared && after.proxyState != .running,
                      "liveStop.physicallyComplete")
            out.check(atAdmission == target, "liveStop.admittedInTargetPhase")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    await transfer.value
    for (name, values) in samples {
        var record = percentiles(values)
        record["record"] = "status-latency"
        record["condition"] = "live-a-b-\(name)"
        out.emit(record)
    }
    let (boundaries, settled) = phase.record
    var transferRecord: [String: Any] = ["record": "transfer-b", "label": "save-only escape-heavy B beside live A; never applied"]
    for (name, ms) in boundaries { transferRecord["enter_\(name)_MS"] = ms }
    for (key, value) in settled { transferRecord[key] = value }
    out.emit(transferRecord)
    out.check(stopFacts != nil, "liveStop.issued")
    out.check(settled["outcome"] as? String == "configurationSettled" && settled["appliedField"] as? String == "absent"
              && settled["moduleReceipts"] as? Int == 0, "transferB.savedNotApplied")
    let (after, _) = try await run.readSnapshot()
    out.check(after.profileName == a.profileName, "transferB.hostViewStillA")
    run.stages.stage("live-transfer-done")
    try await run.plainQuit()
}

/// contention: Stop and status through the ordinary client while large private reads and saves run beside them.
@MainActor
func runContention(_ run: HostRun, limits: RuntimeServiceLimits) async throws {
    let out = run.out
    _ = try await run.openRunningValidMaximum(limits: limits)
    run.stages.stage("running-valid-maximum")
    try await run.statusSamples(20, condition: "idle-running")
    let state = WorkerState()
    let editor = run.editor
    let control = run.control
    let incarnation = run.incarnation!
    let escape = makeEscapeMaximumConfig(port: try reserveLoopbackPort())
    let worker = Task.detached {
        await largePrivateWork(editor, control: control, incarnation: incarnation, config: escape, platform: makePlatform(),
                               iterations: 4, state: state)
    }
    // Status samples every 5 ms while the worker runs, labelled by whether a private exchange was in flight.
    var busy: [Double] = []
    var idle: [Double] = []
    var stopsIssued = false
    while !state.snapshot.finished {
        let inFlight = state.snapshot.inFlight
        let (_, elapsed) = try await run.readSnapshot()
        if inFlight { busy.append(elapsed) } else { idle.append(elapsed) }
        if !stopsIssued, state.snapshot.completed >= 1, state.snapshot.inFlight {
            stopsIssued = true
            let proxy = try await run.measuredStop(.proxy, condition: "during-large-private-work")
            let (afterStop, _) = try await run.readSnapshot()
            out.check(outcomeLabel(proxy) == "completed.stop" && afterStop.proxyState != .running
                      && !run.fakes.machine.service("Wi-Fi").webProxy.enabled, "contention.proxyStopVerified")
            _ = try await run.measuredStop(.tunnels, condition: "during-large-private-work")
            // Whether a private exchange was in flight when the DNS Stop was admitted. This is not evidence that its disable
            // save overlapped a store save; that overlap is not observed.
            let exchangeInFlight = state.snapshot.inFlight
            let dns = try await run.measuredStop(.dns, condition: "during-large-private-work")
            out.emit(["record": "dns-stop", "outcome": outcomeLabel(dns), "privateExchangeInFlightAtAdmission": exchangeInFlight,
                      "storeOverlapObserved": false])
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    await worker.value
    let worked = state.snapshot
    var busyRecord = percentiles(busy)
    busyRecord["record"] = "status-latency"
    busyRecord["condition"] = "private-exchange-in-flight"
    out.emit(busyRecord)
    var idleRecord = percentiles(idle)
    idleRecord["record"] = "status-latency"
    idleRecord["condition"] = "worker-between-exchanges"
    out.emit(idleRecord)
    out.emit(["record": "worker", "exchanges": worked.completed, "errors": worked.errors])
    out.check(stopsIssued, "contention.stopsIssuedDuringWork")
    out.check(worked.errors.isEmpty, "contention.workerSettled")
    run.stages.stage("contention-done")
    try await run.plainQuit()
}

/// held: deterministic producer, store and helper holds, each through an existing protocol seam or the caller's own closure.
@MainActor
func runHeld(_ run: HostRun, limits: RuntimeServiceLimits) async throws {
    let out = run.out
    let (config, _) = try await run.openRunningValidMaximum(limits: limits)
    let editor = run.editor
    let incarnation = run.incarnation!
    let platform = makePlatform()

    // (a) Held PRODUCER: the caller's request-mapping closure blocks inside the private reservation. This is the caller's producer,
    // not an encoder stall.
    let producer = DispatchSemaphore(value: 0)
    let producerReached = WorkerState()
    let observed = try await run.read().0
    let held = Task.detached { () -> ControlAdmission in
        try await privateSubmit(editor, incarnation: incarnation, config: config, platform: platform, observed: observed,
                                modules: allSaveOnly, deadline: .after(.seconds(60), from: .now),
                                producerHold: { producerReached.set(inFlight: true); producer.wait() })
    }
    let reachDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !producerReached.snapshot.inFlight, ContinuousClock.now < reachDeadline { try await Task.sleep(for: .milliseconds(1)) }
    out.check(producerReached.snapshot.inFlight, "producer.reached")
    try await run.statusSamples(20, condition: "held-producer")
    var secondRead = "none"
    do { _ = try await run.read() ; secondRead = "observation" } catch { secondRead = errorLabel(error) }
    var secondUpdate = "none"
    do {
        let admission = try await privateSubmit(editor, incarnation: incarnation, config: config, platform: platform,
                                                observed: observed, modules: allSaveOnly, deadline: .after(.seconds(5), from: .now))
        secondUpdate = admissionLabel(admission)
    } catch { secondUpdate = errorLabel(error) }
    out.emit(["record": "held-producer", "secondRead": secondRead, "secondUpdate": secondUpdate])
    out.check(secondRead == "client.notSent.transportBusy" && secondUpdate == "client.notSent.transportBusy",
              "producer.privateTransferRefusesBeforeSend")
    let proxyStop = try await run.measuredStop(.proxy, condition: "held-producer")
    out.check(outcomeLabel(proxyStop) == "completed.stop" && !run.fakes.machine.service("Wi-Fi").webProxy.enabled,
              "producer.stopCompletesWhileHeld")
    let releaseStart = ContinuousClock.now
    producer.signal()
    let heldAdmission = try await held.value
    let heldOutcome = try await pollOutcome(run.control, incarnation: incarnation, admission: heldAdmission)
    out.emit(["record": "held-producer-release", "admission": admissionLabel(heldAdmission), "outcome": outcomeLabel(heldOutcome),
              "releaseToSettledMS": elapsedMS(since: releaseStart)])
    out.check(outcomeLabel(heldOutcome) == "configurationSettled", "producer.updateSettlesAfterRelease")
    run.stages.stage("held-producer-done")

    // (b) Held STORE: the runtime file's replacement waits inside the store's worker, under the explicit file-access seam.
    let observed2 = try await run.read().0
    var stored = config
    stored.logging.verbose = true
    run.fakes.files.replaceGate.arm()
    let storeHeld = Task.detached { () -> ControlAdmission in
        try await privateSubmit(editor, incarnation: incarnation, config: stored, platform: platform, observed: observed2,
                                modules: allSaveOnly, deadline: .after(.seconds(60), from: .now))
    }
    let storeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !run.fakes.files.replaceGate.isHolding, ContinuousClock.now < storeDeadline { try await Task.sleep(for: .milliseconds(1)) }
    out.check(run.fakes.files.replaceGate.isHolding, "store.holdReached")
    try await run.statusSamples(20, condition: "held-store")
    var readDuringStore = "none"
    do { _ = try await run.read(); readDuringStore = "observation" } catch { readDuringStore = errorLabel(error) }
    var updateDuringStore = "none"
    do {
        let admission = try await privateSubmit(editor, incarnation: incarnation, config: stored, platform: platform,
                                                observed: observed2, modules: allSaveOnly, deadline: .after(.seconds(5), from: .now))
        updateDuringStore = admissionLabel(admission)
    } catch { updateDuringStore = errorLabel(error) }
    out.emit(["record": "held-store", "readDuringHold": readDuringStore, "secondUpdateDuringHold": updateDuringStore])
    let tunnelsStop = try await run.measuredStop(.tunnels, condition: "held-store")
    out.check(outcomeLabel(tunnelsStop) == "completed.stop", "store.stopCompletesWhileHeld")
    let storeRelease = ContinuousClock.now
    run.fakes.files.replaceGate.release()
    let storeAdmission = try await storeHeld.value
    let storeOutcome = try await pollOutcome(run.control, incarnation: incarnation, admission: storeAdmission)
    var storePersisted = false
    if case .configurationSettled(let receipt)? = storeOutcome { storePersisted = receipt.runtime.write == .persisted(reportedError: false) }
    out.emit(["record": "held-store-release", "outcome": outcomeLabel(storeOutcome), "releaseToSettledMS": elapsedMS(since: storeRelease)])
    out.check(storePersisted, "store.savePersistsAfterRelease")
    run.stages.stage("held-store-done")

    // (c) Held HELPER: an ordinary proxy Restart whose system-proxy apply waits in the privileged-operation seam.
    let (snapshot, _) = try await run.readSnapshot()
    run.fakes.privilege.gate.arm()
    let restartStart = ContinuousClock.now
    let (restart, restartAdmissionMS) = try await run.submitControl(.restart(.proxy, ifLifecycleRevision: snapshot.stamp.lifecycleRevision))
    let helperDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !run.fakes.privilege.gate.isHolding, ContinuousClock.now < helperDeadline { try await Task.sleep(for: .milliseconds(1)) }
    let helperHeld = run.fakes.privilege.gate.isHolding
    out.check(helperHeld, "helper.holdReached")
    try await run.statusSamples(20, condition: "held-helper")
    let stopStart = ContinuousClock.now
    let (stop, stopAdmissionMS) = try await run.submitControl(.stop(.proxy))
    try await Task.sleep(for: .milliseconds(200))
    let pendingAfterHold: Bool
    if case .accepted(let operation) = stop {
        pendingAfterHold = try await run.control.outcome(of: operation, expectedIncarnation: incarnation,
                                                         deadline: run.deadline()) == .pending
    } else {
        pendingAfterHold = false
    }
    let helperRelease = ContinuousClock.now
    run.fakes.privilege.gate.release()
    let stopDone = try await run.awaitOutcome(stop, since: stopStart)
    // Taken at once: the Stop's outcome was just observed, before the Restart's wait or any snapshot read. Polling quantizes it.
    let stopAfterReleaseMS = elapsedMS(since: helperRelease)
    let restartDone = try await run.awaitOutcome(restart, since: restartStart)
    let (after, _) = try await run.readSnapshot()
    out.emit(["record": "held-helper", "restartAdmission": admissionLabel(restart), "restartAdmissionMS": restartAdmissionMS,
              "restartOutcome": outcomeLabel(restartDone.outcome), "stopAdmission": admissionLabel(stop),
              "stopAdmissionMS": stopAdmissionMS, "stopPendingWhileHelperHeld": pendingAfterHold,
              "stopOutcomeObservedAfterReleaseMS": stopAfterReleaseMS, "stopTotalMS": stopDone.ms,
              "stopOutcome": outcomeLabel(stopDone.outcome)])
    out.check(outcomeLabel(stopDone.outcome) == "completed.stop" && after.proxyState != .running
              && !run.fakes.machine.service("Wi-Fi").webProxy.enabled, "helper.stopVerifiedAfterRelease")
    run.stages.stage("held-helper-done")
    try await run.plainQuit()
}

/// cancel: lost waits and a cancelled caller, with the actual main actor held so the owner round cannot claim; then physical
/// cleanup is evidenced by when the composition's one private transfer accepts the next exchange.
@MainActor
func runCancel(_ run: HostRun, limits: RuntimeServiceLimits) async throws {
    let out = run.out
    // A small live A, so a retry read is cheap and its own duration does not dominate the bounds below.
    let (config, _) = try await run.openRunning(limits: limits, config: makeSmallConfig(port: try reserveLoopbackPort()))
    let editor = run.editor
    let control = run.control
    let incarnation = run.incarnation!
    let platform = makePlatform()

    /// Retries a small read about every millisecond, from the moment the lost wait's caller returned, until the transfer accepts
    /// one. This does not observe the release itself. It bounds it: the transfer was still held at the last `transportBusy`
    /// refusal (a lower bound, or none observed), and it was free by the time the accepted attempt reserved it, which is that
    /// attempt's first step, after its start and before its end (an upper bound).
    func transferReleaseBounds() async throws -> [String: Any] {
        let start = ContinuousClock.now
        var refusals = 0
        var lastRefusedMS = -1.0
        while ContinuousClock.now < start.advanced(by: .seconds(10)) {
            let attemptStart = elapsedMS(since: start)
            do {
                _ = try await privateObservation(editor, incarnation: incarnation, deadline: .after(.seconds(30), from: .now))
                return ["busyRefusals": refusals, "lastBusyRefusalMS": lastRefusedMS,
                        "acceptedAttemptStartMS": attemptStart, "acceptedAttemptEndMS": elapsedMS(since: start),
                        "retryIntervalMS": 1]
            } catch RuntimeClientError.notSent(.transportBusy) {
                refusals += 1
                lastRefusedMS = elapsedMS(since: start)
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        return ["busyRefusals": refusals, "lastBusyRefusalMS": lastRefusedMS, "acceptedAttemptStartMS": -1, "acceptedAttemptEndMS": -1]
    }

    // (a) A read whose deadline ends while the owner cannot claim.
    let lostRead = Task.detached { () -> String in
        do {
            _ = try await privateObservation(editor, incarnation: incarnation, deadline: .after(.milliseconds(20), from: .now))
            return "observation"
        } catch { return errorLabel(error) }
    }
    usleep(150_000)
    let lostReadResult = await lostRead.value
    var afterLostRead = try await transferReleaseBounds()
    afterLostRead["record"] = "cancel"
    afterLostRead["case"] = "read-deadline-main-held"
    afterLostRead["result"] = lostReadResult
    out.emit(afterLostRead)

    // (b) A read whose caller task is cancelled while the owner cannot claim.
    let cancelled = Task.detached { () -> String in
        do {
            _ = try await privateObservation(editor, incarnation: incarnation, deadline: .after(.seconds(30), from: .now))
            return "observation"
        } catch { return errorLabel(error) }
    }
    usleep(20_000)
    cancelled.cancel()
    usleep(100_000)
    let cancelledResult = await cancelled.value
    var afterCancel = try await transferReleaseBounds()
    afterCancel["record"] = "cancel"
    afterCancel["case"] = "read-cancelled-main-held"
    afterCancel["result"] = cancelledResult
    out.emit(afterCancel)

    // (c) An update whose deadline ends while the owner cannot claim; recovered by request lookup, never resent.
    let observed = try await run.read().0
    var edited = config
    edited.logging.verbose = true
    let requestID = ControlRequestID(rawValue: UUID())
    let lostUpdate = Task.detached { () -> String in
        do {
            let admission = try await privateSubmit(editor, incarnation: incarnation, config: edited, platform: platform,
                                                    observed: observed, modules: allSaveOnly, requestID: requestID,
                                                    deadline: .after(.milliseconds(20), from: .now))
            return admissionLabel(admission)
        } catch { return errorLabel(error) }
    }
    usleep(150_000)
    let lostUpdateResult = await lostUpdate.value
    var afterUpdate = try await transferReleaseBounds()
    let lookup = try await control.lookupAdmission(of: requestID, expectedIncarnation: incarnation, deadline: run.deadline())
    var lookupLabel = "unknown"
    var recovered = "none"
    if case .admission(let admission) = lookup {
        lookupLabel = admissionLabel(admission)
        recovered = outcomeLabel(try await pollOutcome(control, incarnation: incarnation, admission: admission))
    } else if case .unknown(let reason) = lookup {
        lookupLabel = "unknown.\(reason.rawValue)"
    }
    afterUpdate["record"] = "cancel"
    afterUpdate["case"] = "update-deadline-main-held"
    afterUpdate["result"] = lostUpdateResult
    afterUpdate["lookup"] = lookupLabel
    afterUpdate["recoveredOutcome"] = recovered
    out.emit(afterUpdate)
    let accepted = [afterLostRead, afterCancel, afterUpdate].allSatisfy { ($0["acceptedAttemptEndMS"] as? Double ?? -1) >= 0 }
    out.check(accepted, "cancel.transferAcceptedAgainAfterEachLostWait")
    // A fresh update after the lost one is admitted: the frozen-input slot was released.
    let fresh = try await run.read().0
    let start = ContinuousClock.now
    let (freshAdmission, _) = try await run.submitUpdate(config: config, platform: platform, observed: fresh, modules: allSaveOnly)
    let freshDone = try await run.awaitOutcome(freshAdmission, since: start)
    out.check(outcomeLabel(freshDone.outcome) == "configurationSettled", "cancel.inputSlotFreeForNextUpdate")
    run.stages.stage("cancel-done")
    _ = try await run.measuredStop(.proxy, condition: "after-cancel-cases")
    try await run.plainQuit()
}

/// codec-bounds: no host. The actual codecs over the widest metadata the types admit, as separate counts from the measured
/// frames (whose versions are small store versions, not `UInt64.max`).
@MainActor
func runCodecBounds(_ out: Output) throws {
    let namespace = PrivateBaselineNamespace(rawValue: syntheticUUID(92, 1))
    let incarnation = ControlHostIncarnation(rawValue: syntheticUUID(91, 1))
    func baseline(_ file: ControlConfigWorkflowFile, _ version: UInt64) -> PrivateBaseline {
        PrivateBaseline(namespace: namespace, component: file, version: version)
    }
    guard let zeroRevision = ControlLifecycleRevision(rawValue: 0), let maxRevision = ControlLifecycleRevision(rawValue: Int.max)
    else { throw ProbeError("revision") }
    let config = makeSmallConfig(port: 40_000)
    let platform = makePlatform()
    let preferences = makeSmallPreferences()

    // Observation reply: the shape the store issues first (version 1, revision 0), then each member at its widest.
    func replyBytes(_ components: PrivateComponentSlots<PrivateComponentState>, _ module: PrivateModuleState, terminal: Bool) throws -> Int {
        let observation = try PrivateConfigurationBridge.makeObservation(
            config: config, platform: platform, preferences: preferences, terminal: terminal, components: components,
            modules: PrivateModuleSlots(proxy: module, dns: module, tunnels: module)
        )
        return try PrivateConfigurationEncoder.encode(PrivateEditorReply(
            requestID: ControlRequestID(rawValue: syntheticUUID(93, 1)), hostIncarnation: incarnation, answer: .observation(observation)
        )).count
    }
    let firstIssued = PrivateComponentSlots<PrivateComponentState>(
        runtime: .verified(baseline(.runtime, 1)), platform: .verified(baseline(.platform, 1)), preferences: .verified(baseline(.preferences, 1))
    )
    let firstModule = PrivateModuleState(lifecycleRevision: zeroRevision, enabled: true, fenced: true)
    let actualShape = try replyBytes(firstIssued, firstModule, terminal: true)
    var widest = firstIssued
    for file in ControlConfigWorkflowFile.allCases {
        let choices: [PrivateComponentState] = [.verified(baseline(file, .max)), .absent(baseline(file, .max))]
            + PrivateRetainedReason.allCases.map { .retained($0) }
        var best = (bytes: -1, state: choices[0])
        for choice in choices {
            var trial = widest
            trial[file] = choice
            let bytes = try replyBytes(trial, firstModule, terminal: true)
            if bytes > best.bytes { best = (bytes, choice) }
        }
        widest[file] = best.state
    }
    var widestModule = firstModule
    var widestBytes = 0
    for enabled in [false, true] {
        for fenced in [false, true] {
            let module = PrivateModuleState(lifecycleRevision: maxRevision, enabled: enabled, fenced: fenced)
            for terminal in [false, true] {
                let bytes = try replyBytes(widest, module, terminal: terminal)
                if bytes > widestBytes {
                    widestBytes = bytes
                    widestModule = module
                }
            }
        }
    }
    _ = widestModule
    out.emit(["record": "metadata-reply", "label": "actual private reply codec over a small observation",
              "firstIssuedShapeFrameBytes": actualShape, "widestMetadataFrameBytes": widestBytes,
              "widestMetadataDeltaBytes": widestBytes - actualShape])

    // Request metadata: budget, baselines and module intents at their widest, against the probe's measured request shape.
    func requestBytes(budget: Int, version: UInt64, modules: PrivateModuleSlots<PrivateModuleIntent>) throws -> Int {
        try PrivateConfigurationEncoder.encode(try PrivateConfigurationBridge.makeRequest(
            config: config, platform: platform, requestID: ControlRequestID(rawValue: syntheticUUID(94, 1)), incarnation: incarnation,
            budget: try ControlWireBudget(budget), runtimeBaseline: baseline(.runtime, version), platformBaseline: baseline(.platform, version),
            modules: modules
        )).count
    }
    let measuredShape = try requestBytes(budget: 60_000, version: 2, modules: allSaveOnly)
    var widestRequest = 0
    for intent in [PrivateModuleIntent.saveOnly, .applyWhileRunning(ifLifecycleRevision: maxRevision), .start(ifLifecycleRevision: maxRevision)] {
        widestRequest = max(widestRequest, try requestBytes(budget: Int(Int32.max), version: .max,
                                                            modules: PrivateModuleSlots(proxy: intent, dns: intent, tunnels: intent)))
    }
    out.emit(["record": "metadata-request", "label": "actual private request codec over a small configuration",
              "measuredShapeFrameBytes": measuredShape, "widestMetadataFrameBytes": widestRequest,
              "widestMetadataDeltaBytes": widestRequest - measuredShape])

    // Safe receipts through the ordinary codec, at their widest: verified writes with UInt64.max baselines, every module.
    let longestResult = ControlLifecycleModuleResult.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!
    let longestUnknown = ControlConfigWorkflowUnknownCause.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!
    let modules = ControlModule.allCases.map { ControlModuleReceipt(module: $0, result: longestResult) }
    let verified = try ControlConfigurationReceipt(
        requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
        runtime: try ControlComponentWrite(write: .persisted(reportedError: false), baseline: baseline(.runtime, .max)),
        platform: try ControlComponentWrite(write: .persisted(reportedError: false), baseline: baseline(.platform, .max)),
        committedDNSForwarderEnabled: false, modules: modules, applied: false
    )
    let unknown = try ControlConfigurationReceipt(
        requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
        runtime: try ControlComponentWrite(write: .unknown(longestUnknown, reportedError: false), baseline: nil),
        platform: try ControlComponentWrite(write: .unknown(longestUnknown, reportedError: false), baseline: nil),
        committedDNSForwarderEnabled: nil, modules: modules, applied: false
    )
    let preferencesReceipt = try ControlPreferencesReceipt(
        requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
        preferences: try ControlComponentWrite(write: .persisted(reportedError: false), baseline: baseline(.preferences, .max))
    )
    var widestOutcome = 0
    var widestLookup = 0
    var widestFinished = 0
    for outcome in [ControlOperationOutcome.configurationSettled(verified), .configurationSettled(unknown), .preferencesSettled(preferencesReceipt)] {
        widestOutcome = max(widestOutcome, try ControlRuntimeCodec.makeEncoder().encode(outcome).count)
        widestLookup = max(widestLookup, ordinaryFrameBytes(.response(.lookup(.finished(outcome)))))
        widestFinished = max(widestFinished, ordinaryFrameBytes(.frame(.operationFinished(
            ControlOperationFinished(operationID: ControlOperationID(rawValue: UUID()), outcome: outcome)))))
    }
    out.emit(["record": "receipt-bounds", "widestOutcomeBytes": widestOutcome, "widestLookupReplyFrameBytes": widestLookup,
              "widestOperationFinishedFrameBytes": widestFinished, "candidateMaxReplyBytes": CandidateProfile.maxReplyBytes,
              "candidateOutcomeByteCapacity": 65_536, "candidateControlLogByteCapacity": 65_536])
    out.check(widestLookup <= CandidateProfile.maxReplyBytes && widestFinished <= CandidateProfile.maxReplyBytes
              && widestOutcome <= 65_536, "receipt.widestFitsCandidateOrdinaryAndOutcomeBounds")

    // Widest ordinary requests the clients send.
    let maxBudget = try ControlWireBudget(Int(Int32.max))
    let commands: [ControlRuntimeCommand] = [
        .stop(.tunnels),
        .restart(.proxy, ifLifecycleRevision: maxRevision, conditionalDNSRevision: maxRevision),
        .setLaunchAtLogin(false, ifPlatformBaseline: baseline(.platform, .max)),
        .quit(total: maxBudget, flush: try ControlQuitFlush(configuration: ControlRequestID(rawValue: UUID()),
                                                            preferences: ControlRequestID(rawValue: UUID()))),
    ]
    var widestRequestFrame = 0
    for command in commands {
        widestRequestFrame = max(widestRequestFrame, ordinaryFrameBytes(.request(ControlRuntimeRequest(budget: maxBudget, call: .submit(
            ControlOperationRequest(requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, command: command))))))
    }
    out.emit(["record": "ordinary-request-bounds", "widestSubmitFrameBytes": widestRequestFrame,
              "candidateMaxRequestBytes": CandidateProfile.maxRequestBytes])
    out.check(widestRequestFrame <= CandidateProfile.maxRequestBytes, "ordinary.widestRequestFitsCandidate")
    _ = zeroRevision
}

let latencyModes = ["contention", "contention-encode", "contention-store", "held", "cancel", "codec-bounds"]

let flowModes = ["small", "realistic-valid-64", "realistic-valid-128", "validator-widest", "escape-maximum", "padded-8mib", "repeat"]

func makeFixture(_ mode: String, scratch: URL) throws -> Fixture {
    let port = try reserveLoopbackPort()
    let limits = DomainResourceLimits.self
    switch mode {
    case "realistic-valid-128":
        return Fixture(name: mode, config: makeValidMaximumConfig(port: port, auditPrefix: scratch.path + "/audit"),
                       preferences: makeMaximumPreferences(loopbackURL("http://127.0.0.1:9/", "browser", bytes: limits.urlText)),
                       startable: true, repeatCycles: 0, runtimeFile: nil)
    case "validator-widest":
        return Fixture(name: mode, config: makeValidatorWidestConfig(port: port),
                       preferences: makeMaximumPreferences(EscapeText().text(limits.urlText)),
                       startable: true, repeatCycles: 0, runtimeFile: nil)
    case "realistic-valid-64":
        return Fixture(name: mode, config: makeValidMaximumConfig(port: port, auditPrefix: scratch.path + "/audit", tunnels: 64),
                       preferences: makeMaximumPreferences(loopbackURL("http://127.0.0.1:9/", "browser", bytes: limits.urlText)),
                       startable: true, repeatCycles: 0, runtimeFile: nil)
    case "escape-maximum":
        return Fixture(name: mode, config: makeEscapeMaximumConfig(port: port),
                       preferences: makeMaximumPreferences(EscapeText().text(limits.urlText)),
                       startable: false, repeatCycles: 0, runtimeFile: nil)
    case "padded-8mib":
        let config = makeSmallConfig(port: port)
        return Fixture(name: mode, config: config, preferences: makeSmallPreferences(), startable: true, repeatCycles: 0,
                       runtimeFile: { try paddedRuntimeFile(config) })
    case "repeat":
        return Fixture(name: mode, config: makeEscapeMaximumConfig(port: port),
                       preferences: makeMaximumPreferences(EscapeText().text(limits.urlText)),
                       startable: false, repeatCycles: 6, runtimeFile: nil)
    default:
        return Fixture(name: mode, config: makeSmallConfig(port: port), preferences: makeSmallPreferences(), startable: true,
                       repeatCycles: 0, runtimeFile: nil)
    }
}

let noSamplerSuffix = "-nosampler"

// MARK: - Entry

@main
struct ProbeMain {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        // `<mode>-nosampler` runs `<mode>` without the 1 ms memory sampler, for latency without its allocator-lock interference.
        let sampling = !(arguments.count == 3 && arguments[1].hasSuffix(noSamplerSuffix))
        let requested = arguments.count == 3 ? String(arguments[1].dropLast(sampling ? 0 : noSamplerSuffix.count)) : ""
        guard arguments.count == 3, (flowModes + lifetimeModes + latencyModes).contains(requested) else {
            FileHandle.standardError.write(Data("usage: probe <mode>[-nosampler] <scratch-dir>\n".utf8))
            exit(64)
        }
        let mode = requested
        let out = Output(mode: arguments[1])
        let stages = StageRecorder(out: out, sampling: sampling)
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            out.emit(["record": "summary", "outcome": "mode-deadline-expired"])
            exit(4)
        }
        stages.stage("baseline")
        out.emit(["record": "measurement-method", "samplerEnabled": sampling, "samplerIntervalMS": 1,
                  "samplerTakesMallocZoneLocks": sampling, "outcomePollIntervalMS": 1, "workerOutcomePollIntervalMS": 2,
                  "statusSampleIntervalMS": 2, "clientAndHostShareOneProcess": true])
        guard let limits = emitProfile(out) else {
            finish(out, released: false)
        }
        let scratch = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if mode == "codec-bounds" {
            do {
                try runCodecBounds(out)
                try FileManager.default.removeItem(at: scratch)
            } catch {
                out.emit(["record": "error", "error": errorLabel(error)])
                out.check(false, "mode.completed")
            }
            finish(out, released: true)
        }
        var released = false
        do {
            let run = try HostRun(out: out, stages: stages, scratch: scratch)
            do {
                if let depth = lifetimeModes.firstIndex(of: mode) {
                    try await runLifetime(run, limits: limits, depth: depth)
                } else if mode == "contention-encode" {
                    try await runLiveTransfer(run, limits: limits, target: "update-exchange")
                } else if mode == "contention-store" {
                    try await runLiveTransfer(run, limits: limits, target: "store-save")
                } else if mode == "contention" {
                    try await runContention(run, limits: limits)
                } else if mode == "held" {
                    try await runHeld(run, limits: limits)
                } else if mode == "cancel" {
                    try await runCancel(run, limits: limits)
                } else {
                    try await runFlow(run, limits: limits, fixture: try makeFixture(mode, scratch: scratch))
                }
            } catch {
                out.emit(["record": "error", "error": errorLabel(error)])
                out.check(false, "mode.completed")
                if run.host != nil {
                    // Join the host's work before anything is released: a quit, then the release proofs.
                    await run.host?.shutdown()
                }
            }
            if run.host != nil {
                released = await run.release()
            } else if run.session != nil {
                out.emit(["record": "error", "error": "probe.hostNotOpened"])
                run.session = nil
            }
            stages.stage("after-release", ["released": released])
        } catch {
            out.emit(["record": "error", "error": errorLabel(error)])
            out.check(false, "setup.completed")
        }
        finish(out, released: released)
    }

    static func finish(_ out: Output, released: Bool) -> Never {
        let failures = out.failureList
        let inconclusive = out.inconclusiveList
        out.emit(["record": "summary", "failedChecks": failures.count, "failures": failures, "inconclusive": inconclusive,
                  "released": released])
        exit(failures.isEmpty && released ? (inconclusive.isEmpty ? 0 : 3) : 1)
    }
}
