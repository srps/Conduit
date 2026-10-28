// Actual Conduit client/host resource probe. Not product code or a benchmark product. Host modes consume the shipping profile.
// It links the existing Release objects with `-package-name conduit` and drives the actual `RuntimeHost.open` facade over
// explicit fakes (the `pm-sim` runtime-host-effects composition) and an owned scratch state root, then the actual in-memory
// framed client and private editor client from `RuntimeHost.makeInMemoryControlClient`. No production adapter default,
// Keychain, GSS, helper, VPN, network-path or machine setting is touched. It prints numeric NDJSON only: fixed labels,
// counts, timings and memory. No URL, configuration value, credential or plaintext is printed.
//
// Modes (one fresh process each; see README.md): lifetime-open, lifetime-composed, lifetime-read, lifetime-save, lifetime-start,
// small, realistic-valid-64, realistic-valid-128, validator-widest, escape-maximum, padded-8mib, repeat, contention,
// contention-encode, contention-store, held, cancel, client-quit-widest (the actual `RuntimeClientQuit.quit` routine), codec-bounds,
// profile-sizing (no host: the candidate's constructor terms, rows and snapshot), pressure-candidate (one bounded pressure run at the
// candidate profile); any mode with `-nosampler` runs without the memory sampler.
//
// Every host mode runs at ONE measured CANDIDATE profile (`CandidateProfile`), built through the actual `RuntimeServiceLimits`
// initializer from codec measurements. It is an experiment profile, not a shipping default; only its collection caps are selected
// (decision 0038).
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

/// The helper-status fake, wrapped so a phase can hold the preflight pass's read-only helper read. The host reads it on a global queue
/// (`RuntimeHostPreflight`), so a hold never blocks the main actor. This is the fake `HelperLifecycleManaging` seam, not the installed helper.
final class GatedHelperLifecycle: HelperLifecycleManaging, @unchecked Sendable {
    let base = FakeHelperLifecycle()
    let gate = Gate()

    var status: HelperToolPrivilegeClient.Status {
        gate.pass()
        return base.status
    }

    func installHelper() throws -> HelperPinOutcome { try base.installHelper() }
    func uninstallHelper() throws { try base.uninstallHelper() }
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
    let helper = GatedHelperLifecycle()
    let secrets = InMemorySecretStore()
    let dns = FakeDNSProbe()
    /// The wake source the host observes from open until its quit. The probe never fires it.
    let wake = FakeSystemWakeObserver()
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
            wake: fakes.wake,
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

// MARK: - Measured sizes (actual codecs and projections)

/// The encoded size of a value through the ordinary codec's encoder, the one `RuntimeWireSize` (internal) uses for every byte bound.
/// -1 when the value cannot be encoded; a caller checks it, so -1 never reaches a total silently.
func encodedSize<Value: Encodable>(_ value: Value) -> Int {
    do {
        return try ControlRuntimeCodec.makeEncoder().encode(value).count
    } catch {
        return -1
    }
}

/// The candidate with the longest encoding; a tie keeps the first. Every candidate is encoded.
func widestEncoded<Value: Encodable>(_ candidates: [Value]) throws -> Value {
    var best: (value: Value, bytes: Int)?
    for candidate in candidates {
        let bytes = try ControlRuntimeCodec.makeEncoder().encode(candidate).count
        if bytes > (best?.bytes ?? -1) { best = (candidate, bytes) }
    }
    guard let best else { throw ProbeError("noCandidate") }
    return best.value
}

/// The event log's `maximumPosition` (`Int.max - 1`, internal; read from `RuntimeObservationLog.swift`): the widest cursor it issues.
let widestCursorRaw = Int.max - 1
let widestID = syntheticUUID(0xFFFF_FFF, 0xFFFF_FFFF_FFFF)

/// The kernel date whose wire timestamp encodes widest, chosen by encoding each candidate as the projection would.
func widestDate() throws -> Date {
    let candidates = [-Double.greatestFiniteMagnitude, -1.2345678901234567e+300, 1_761_600_000.123456]
        .map { Date(timeIntervalSince1970: $0) }
    let stamps = try candidates.map { try ControlTimestamp($0.timeIntervalSince1970) }
    let widest = try widestEncoded(stamps)
    return candidates[stamps.firstIndex(of: widest) ?? 0]
}

func widestNonNegative() throws -> Double {
    let candidates = [Double.greatestFiniteMagnitude, 2.2250738585072014e-308, 1.2345678901234567e+300, 0.1 + 0.2]
    return try widestEncoded(try candidates.map { try ControlNonNegativeNumber($0) }).rawValue
}

// MARK: Collection rows (actual kernel types through the actual Bridge projection)

/// The row shapes measured for each collection kind. `widest` is the widest the probe built (NUL text past each display cap, which
/// is cut to the cap and escapes to six bytes per byte; numbers and dates at their widest encodings); it is not a proven maximum.
/// `mixed-escape` rotates four bodies past the cap (NUL, quote, backslash, two-byte `é`) across the text fields, so each row holds a mix
/// (connections rotate per row; other kinds take the quote body). `realistic-wide` uses 253-byte `.invalid` names; `typical` uses short
/// `.invalid` names. All are the probe's choices.
enum RowBasis: String, CaseIterable {
    case widest = "widest-probe-built"
    case mixed = "mixed-escape"
    case realisticWide = "realistic-wide"
    case typical
}

let nulDiagnostic = String(repeating: "\u{0}", count: 1_025)
let nulDisplay = String(repeating: "\u{0}", count: 2_049)
let mixedBodies = [nulDiagnostic, String(repeating: "\"", count: 1_025), String(repeating: "\\", count: 1_025),
                   String(repeating: "é", count: 513)]

/// One kernel snapshot holding `count` rows of `kind` in `basis`. Rows share their text bodies, so the kernel holds one body per field.
func rowKernel(_ kind: ControlCollectionKind, _ basis: RowBasis, count: Int = 1, pick: Int = 0) throws -> ProxyOrchestratorSnapshot {
    var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
    let wideHost = dnsName("r", bytes: 253)
    switch (kind, basis) {
    case (.activeConnections, _):
        let date = try basis == .widest ? widestDate() : Date(timeIntervalSince1970: 1_761_600_000.123456)
        kernel.activeConnections = ActiveConnectionStore((0..<count).map { index -> ActiveConnectionInfo in
            switch basis {
            case .widest:
                return ActiveConnectionInfo(id: syntheticUUID(5, index), destination: nulDiagnostic, upstream: nulDiagnostic,
                                            method: nulDiagnostic, startedAt: date, lastActivityAt: date, bytesSent: .max,
                                            bytesReceived: .max, tunnel: pick % 2 == 0 ? false : true, authMethod: nulDiagnostic)
            case .mixed:
                return ActiveConnectionInfo(id: syntheticUUID(5, index), destination: mixedBodies[index % 4], upstream: mixedBodies[(index + 1) % 4],
                                            method: mixedBodies[(index + 2) % 4], startedAt: date, lastActivityAt: date, bytesSent: 1_024,
                                            bytesReceived: 4_096, tunnel: false, authMethod: mixedBodies[(index + 3) % 4])
            case .realisticWide:
                return ActiveConnectionInfo(id: syntheticUUID(5, index), destination: wideHost + ":443", upstream: wideHost + ":8080",
                                            method: "CONNECT", startedAt: date, lastActivityAt: date, bytesSent: 1_099_511_627_776,
                                            bytesReceived: 1_099_511_627_776, tunnel: true, authMethod: "Negotiate")
            case .typical:
                return ActiveConnectionInfo(id: syntheticUUID(5, index), destination: "host\(index).corp.invalid:443",
                                            upstream: "proxy\(index % 4).corp.invalid:8080", method: "CONNECT",
                                            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                                            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                                            bytesSent: index * 1_024, bytesReceived: index * 4_096, tunnel: index % 2 == 0,
                                            authMethod: index % 3 == 0 ? nil : "Negotiate")
            }
        })
    case (.upstreamHealth, _):
        let states: [UpstreamCircuitState] = [.closed, .open, .halfOpen]
        let widestNumber = try widestNonNegative()
        let widestUntil = try widestDate()
        kernel.upstreamStatuses = (0..<count).map { index -> UpstreamRuntimeStatus in
            switch basis {
            case .widest:
                return UpstreamRuntimeStatus(id: syntheticUUID(6, index), name: nulDisplay, endpoint: nulDiagnostic,
                                             circuitState: states[pick % states.count], ewmaLatencyMS: widestNumber,
                                             consecutiveFailures: .max, openUntil: widestUntil)
            case .mixed:
                return UpstreamRuntimeStatus(id: syntheticUUID(6, index), name: mixedBodies[1] + mixedBodies[1], endpoint: mixedBodies[1],
                                             circuitState: .halfOpen, ewmaLatencyMS: 1_234.5678, consecutiveFailures: 12,
                                             openUntil: Date(timeIntervalSince1970: 1_761_600_030.5))
            case .realisticWide:
                return UpstreamRuntimeStatus(id: syntheticUUID(6, index), name: String(repeating: "u", count: 64), endpoint: wideHost + ":8080",
                                             circuitState: .halfOpen, ewmaLatencyMS: 1_234.5678, consecutiveFailures: 12,
                                             openUntil: Date(timeIntervalSince1970: 1_761_600_030.5))
            case .typical:
                return UpstreamRuntimeStatus(id: syntheticUUID(6, index), name: "Proxy \(index)", endpoint: "proxy\(index).corp.invalid:8080",
                                             circuitState: .closed, ewmaLatencyMS: 12.5, consecutiveFailures: 0, openUntil: nil)
            }
        }
    case (.tunnelBindings, _):
        kernel.bindings.tunnels = (0..<count).map { index -> TunnelBindingInfo in
            switch basis {
            case .widest:
                return TunnelBindingInfo(id: syntheticUUID(7, index), label: nulDisplay, localHost: nulDiagnostic, localPort: 65_535,
                                         remoteHost: nulDiagnostic, remotePort: 65_535, proxied: pick % 2 == 0 ? false : true,
                                         healthy: pick / 2 % 2 == 0 ? false : true)
            case .mixed:
                return TunnelBindingInfo(id: syntheticUUID(7, index), label: mixedBodies[1] + mixedBodies[1], localHost: mixedBodies[1],
                                         localPort: 65_535, remoteHost: mixedBodies[1], remotePort: 443, proxied: true, healthy: true)
            case .realisticWide:
                return TunnelBindingInfo(id: syntheticUUID(7, index), label: String(repeating: "t", count: 64), localHost: "127.0.0.1",
                                         localPort: 65_535, remoteHost: wideHost, remotePort: 443, proxied: true, healthy: true)
            case .typical:
                return TunnelBindingInfo(id: syntheticUUID(7, index), label: "db\(index)", localHost: "127.0.0.1", localPort: 15_432,
                                         remoteHost: "db\(index).corp.invalid", remotePort: 5_432, proxied: false, healthy: true)
            }
        }
    case (.tunnelDNSHosts, _):
        let host = switch basis {
        case .widest: nulDiagnostic
        case .mixed: mixedBodies[1]
        case .realisticWide: wideHost
        case .typical: "db.corp.invalid"
        }
        let hosts = Array(repeating: host, count: count)
        let statuses: [TunnelDNSOverrideStatus] = [.active(hostnames: hosts), .partial(succeeded: hosts, failed: []),
                                                   .partial(succeeded: [], failed: hosts)]
        kernel.tunnelDNSOverrideStatus = statuses[basis == .widest ? pick % statuses.count : 0]
    }
    return kernel
}

/// How many variants `rowKernel` builds for a kind's widest basis (enums and booleans); each is measured and the widest kept.
func widestPicks(_ kind: ControlCollectionKind) -> Int {
    switch kind {
    case .activeConnections: 2
    case .upstreamHealth: 3
    case .tunnelBindings: 4
    case .tunnelDNSHosts: 3
    }
}

/// The encoded bytes of the rows the actual projection keeps, through `ControlRowBudget`, or nil when it refuses.
func projectedRowBytes(_ kind: ControlCollectionKind, _ kernel: ProxyOrchestratorSnapshot, maxRows: Int = 1, maxBytes: Int = Int.max) -> Int? {
    switch RuntimeSnapshotControlProjection.projectRows(kind, from: kernel, within: ControlRowBudget(maxRows: maxRows, maxBytes: maxBytes)) {
    case .rows(let rows, encodedBytes: let bytes): rows.kind == kind ? bytes : nil
    case .overBudget, .internalFailure: nil
    }
}

/// One encoded row of `kind` in `basis`, the widest of the basis's variants.
func measuredRowBytes(_ kind: ControlCollectionKind, _ basis: RowBasis) throws -> Int {
    var widest = -1
    for pick in 0..<(basis == .widest ? widestPicks(kind) : 1) {
        guard let bytes = projectedRowBytes(kind, try rowKernel(kind, basis, pick: pick)) else { throw ProbeError("rowRefused") }
        widest = max(widest, bytes)
    }
    return widest
}

/// The widest basis's variant whose single row encodes widest.
func widestPick(_ kind: ControlCollectionKind) throws -> Int {
    var best = (pick: 0, bytes: -1)
    for pick in 0..<widestPicks(kind) {
        guard let bytes = projectedRowBytes(kind, try rowKernel(kind, .widest, pick: pick)) else { throw ProbeError("rowRefused") }
        if bytes > best.bytes { best = (pick, bytes) }
    }
    return best.pick
}

/// The first `count` rows of `full`'s `kind`, as the same kernel holds them. The bodies stay shared.
func prefixKernel(_ full: ProxyOrchestratorSnapshot, _ kind: ControlCollectionKind, _ count: Int) -> ProxyOrchestratorSnapshot {
    var kernel = full
    switch kind {
    case .activeConnections:
        kernel.activeConnections = ActiveConnectionStore(Array(full.activeConnections.ordered.prefix(count)))
    case .upstreamHealth:
        kernel.upstreamStatuses = Array(full.upstreamStatuses.prefix(count))
    case .tunnelBindings:
        kernel.bindings.tunnels = Array(full.bindings.tunnels.prefix(count))
    case .tunnelDNSHosts:
        switch full.tunnelDNSOverrideStatus {
        case .active(let hosts):
            kernel.tunnelDNSOverrideStatus = .active(hostnames: Array(hosts.prefix(count)))
        case .partial(let succeeded, let failed):
            let kept = Array(succeeded.prefix(count))
            kernel.tunnelDNSOverrideStatus = .partial(succeeded: kept, failed: Array(failed.prefix(count - kept.count)))
        case .unavailable, .notNeeded:
            break
        }
    }
    return kernel
}

// MARK: Widest ordinary calls and outcomes (the product evidence tests' shapes, rebuilt here; no test target is linked)

/// Every ordinary request the clients can send, each at its widest legal form. The switches are exhaustive over the request and command
/// kinds, so a new kind fails to compile here until it is measured.
func widestCalls() throws -> [(label: String, call: ControlRuntimeCall)] {
    let incarnation = ControlHostIncarnation(rawValue: widestID)
    let requestID = ControlRequestID(rawValue: widestID)
    guard let config = ControlConfigRevision(rawValue: Int.max), let lifecycle = ControlLifecycleRevision(rawValue: Int.max),
          let revision = ControlCollectionRevision(rawValue: Int.max), let cursor = ControlEventCursor(rawValue: widestCursorRaw)
    else { throw ProbeError("revision") }
    let platformBaseline = PrivateBaseline(namespace: PrivateBaselineNamespace(rawValue: widestID), component: .platform, version: .max)
    let flush = try ControlQuitFlush(configuration: ControlRequestID(rawValue: widestID),
                                     preferences: ControlRequestID(rawValue: syntheticUUID(0xFFFF_FFF, 0xFFFF_FFFF_FFFE)))
    var commands: [(label: String, command: ControlRuntimeCommand)] = []
    func add(_ label: String, _ command: ControlRuntimeCommand) { commands.append((label, command)) }
    for kind in ControlRuntimeCommandKind.allCases {
        switch kind {
        case .stop:
            for module in ControlModule.allCases { add("submit-stop-" + module.rawValue, .stop(module)) }
        case .start:
            add("submit-saved-start-proxy-companion", .start(.proxy, ifModuleRevision: lifecycle, conditionalDNSRevision: lifecycle))
            add("submit-saved-start-tunnels", .start(.tunnels, ifModuleRevision: lifecycle))
        case .restart:
            add("submit-restart-proxy-companion", .restart(.proxy, ifLifecycleRevision: lifecycle, conditionalDNSRevision: lifecycle))
            add("submit-restart-tunnels", .restart(.tunnels, ifLifecycleRevision: lifecycle))
        case .testDNS:
            add("submit-test-dns", .testDNS)
        case .testUpstream:
            add("submit-test-upstream", .testUpstream(ControlUpstreamReference(configRevision: config, upstreamID: ControlUpstreamID(rawValue: widestID))))
        case .refreshPreflight:
            add("submit-refresh-preflight-helper-replaced", .refreshPreflight(helperReplaced: true))
            add("submit-refresh-preflight", .refreshPreflight(helperReplaced: false))
        case .setLaunchAtLogin:
            add("submit-set-launch-at-login-false", .setLaunchAtLogin(false, ifPlatformBaseline: platformBaseline))
            add("submit-set-launch-at-login-true", .setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline))
        case .credentialsChanged:
            add("submit-credentials-changed", .credentialsChanged)
        case .reload:
            add("submit-reload", .reload)
        case .quit:
            add("submit-quit-both-flushes", .quit(total: try ControlWireBudget(Int(Int32.max)), flush: flush))
        }
    }
    var calls: [(label: String, call: ControlRuntimeCall)] = []
    func call(_ label: String, _ value: ControlRuntimeCall) { calls.append((label, value)) }
    for kind in ControlRuntimeRequestKind.allCases {
        switch kind {
        case .submit:
            for entry in commands {
                call(entry.label, .submit(ControlOperationRequest(requestID: requestID, expectedIncarnation: incarnation, command: entry.command)))
            }
        case .outcome:
            call("outcome", .outcome(ControlOperationQuery(expectedIncarnation: incarnation, operationID: ControlOperationID(rawValue: widestID))))
        case .requestLookup:
            call("request-lookup", .requestLookup(ControlRequestQuery(expectedIncarnation: incarnation, requestID: requestID)))
        case .subscribe:
            call("subscribe-live", .subscribe(.live))
            call("subscribe-resume", .subscribe(.resume(incarnation: incarnation, from: cursor)))
        case .readPage:
            let offset = try ControlCount(Int.max)
            for collection in ControlCollectionKind.allCases {
                call("read-page-" + collection.rawValue, .readPage(ControlPageRequest(
                    expectedIncarnation: incarnation, collection: collection, cursor: ControlPageCursor(revision: revision, offset: offset))))
            }
        case .readSnapshot:
            call("read-snapshot", .readSnapshot)
        }
    }
    return calls
}

/// Every write one file can report, each with its full-version baseline exactly when it verified.
func componentWrites(_ component: ControlConfigWorkflowFile, namespace: PrivateBaselineNamespace) throws -> [ControlComponentWrite] {
    let baseline = PrivateBaseline(namespace: namespace, component: component, version: .max)
    var writes: [ControlConfigWorkflowWrite] = [.persisted(reportedError: false), .persisted(reportedError: true), .unchanged, .notPersisted, .conflict]
    for cause in ControlConfigWorkflowUnknownCause.allCases {
        writes += [.unknown(cause, reportedError: false), .unknown(cause, reportedError: true)]
    }
    writes += ControlConfigWorkflowNotAttemptedCause.allCases.map { ControlConfigWorkflowWrite.notAttempted($0) }
    return try writes.map { try ControlComponentWrite(write: $0, baseline: $0.isVerified ? baseline : nil) }
}

/// Every observed preflight reading the wire contract accepts: each held helper verdict with and without the busy-read flag, items at
/// their widest privilege level. The items' initializer refuses a pair no pass produces with `invalidValue`; that pair is counted, not
/// measured. Any other failure, including an encoding refusal of an accepted pair, is unexpected and propagates.
func preflightReadingCandidates() throws -> (busy: [ControlPreflightReading], conclusive: [ControlPreflightReading], refused: Int) {
    let status = ControlIntegrationStatus(enabled: false, alreadyApplied: false, privilegeLevel: try widestEncoded(ControlPrivilegeLevel.allCases))
    let encoder = ControlRuntimeCodec.makeEncoder()
    var result = (busy: [ControlPreflightReading](), conclusive: [ControlPreflightReading](), refused: 0)
    for helper in ControlHelperStatus.allCases {
        for readBusy in [true, false] {
            let items: ControlPreflightItems
            do {
                items = try ControlPreflightItems(systemProxy: status, environmentVariables: status, splitDNS: status, helper: helper,
                                                  helperReadBusy: readBusy)
            } catch ControlRuntimeWireError.invalidValue {
                result.refused += 1
                continue
            }
            let reading = ControlPreflightReading.observed(items)
            _ = try encoder.encode(reading)
            if readBusy { result.busy.append(reading) } else { result.conclusive.append(reading) }
        }
    }
    return result
}

/// Every reload answer the wire carries (decision 0032), a finite set: each refusal (per file where it names one), a superseded and
/// both reconcile-attempted adoptions, and each held input and reason the workflow admits for the reload phase. A held pair
/// `isValidHeld(phase: .reload, …)` refuses is counted, not built.
func reloadResults() -> (results: [ControlReloadResult], heldPairsRefused: Int) {
    var refusals: [ControlConfigWorkflowRefusal] = [.invalidContent, .journalPresenceUnknown, .unexpected, .busy]
    for file in ControlConfigWorkflowFile.allCases { refusals += [.unreadable(file), .versionExhausted(file)] }
    var results = refusals.map { ControlReloadResult.refused($0) }
    results += [.adopted(.superseded), .adopted(.reconcileAttempted(currentAtEnd: true)), .adopted(.reconcileAttempted(currentAtEnd: false))]
    var refused = 0
    for input in ControlConfigWorkflowHeldInput.allCases {
        for reason in ControlConfigWorkflowHoldReason.allCases {
            if ControlConfigWorkflowEvent.isValidHeld(phase: .reload, input: input, reason: reason) {
                results.append(.adopted(.held(input, reason)))
            } else {
                refused += 1
            }
        }
    }
    return (results, refused)
}

/// Each settled outcome kind at its widest legal form, labelled: every configuration receipt shape (the companion, all three members,
/// a saved Start with both priors), the preflight observation with its busy-read field, the upstream probe through the actual Bridge
/// projection, and every completion and failure.
func widestOutcomes() throws -> [(label: String, outcome: ControlOperationOutcome)] {
    let namespace = PrivateBaselineNamespace(rawValue: widestID)
    let requestID = ControlRequestID(rawValue: widestID)
    let incarnation = ControlHostIncarnation(rawValue: widestID)
    guard let revision = ControlPresentationRevision(rawValue: Int.max), let config = ControlConfigRevision(rawValue: Int.max),
          let lifecycle = ControlLifecycleRevision(rawValue: Int.max)
    else { throw ProbeError("revision") }
    func completed(_ command: ControlRuntimeCommandKind, _ result: ControlCommandResult) throws -> ControlOperationOutcome {
        .completed(try ControlCompletion(command: command, presentationRevision: revision, result: result))
    }
    let runtimeWrites = try componentWrites(.runtime, namespace: namespace)
    let platform = try widestEncoded(try componentWrites(.platform, namespace: namespace))
    let member = try widestEncoded(ControlLifecycleModuleResult.allCases)
    let companion = try widestEncoded(ControlLifecycleConditionalDNSResult.allCases)
    let savedPrior = ControlCommitPrior(runtime: PrivateBaseline(namespace: namespace, component: .runtime, version: .max),
                                        platform: PrivateBaseline(namespace: namespace, component: .platform, version: .max))
    func receipt(_ modules: [ControlModule], conditionalDNS: ControlLifecycleConditionalDNSResult?, prior: ControlCommitPrior? = nil) throws
        -> ControlConfigurationReceipt
    {
        try widestEncoded(try runtimeWrites.map { runtime in
            try ControlConfigurationReceipt(
                requestID: requestID, incarnation: incarnation, runtime: runtime, platform: platform,
                committedDNSForwarderEnabled: runtime.write.isVerified ? false : nil,
                modules: modules.map { ControlModuleReceipt(module: $0, result: member) },
                applied: prior == nil ? false : nil, conditionalDNS: conditionalDNS, prior: prior
            )
        })
    }
    let disable = try widestEncoded(try runtimeWrites.map {
        try ControlDNSDisableWrite(prior: PrivateBaseline(namespace: namespace, component: .runtime, version: .max), runtime: $0)
    })
    let probe = try RuntimeProbeControlProjection.upstreamProbe(ProbeResult(
        proxy: UpstreamProxy(id: widestID, name: nulDisplay, host: nulDiagnostic, port: 65_535, enabled: false, priority: 0),
        latencyMS: Int.max, reachable: false
    ))
    let pairs = try preflightReadingCandidates()
    guard !pairs.busy.isEmpty else { throw ProbeError("noBusyPreflightPair") }
    let busyReading = try widestEncoded(pairs.busy)
    let reading = try widestEncoded(pairs.busy + pairs.conclusive
                                    + ControlPreflightUnavailableReason.allCases.map { ControlPreflightReading.unavailable($0) })
    let observedAt = try widestEncoded([try ControlTimestamp(-Double.greatestFiniteMagnitude), try ControlTimestamp(-2.2250738585072014e-308),
                                        try ControlTimestamp(-1.2345678901234567e-300)])
    let preflightStamp = ControlRuntimeStamp(incarnation: incarnation, presentationRevision: revision, configRevision: config,
                                             lifecycleRevision: lifecycle,
                                             modules: ControlModuleRevisions(proxy: lifecycle, dns: lifecycle, tunnels: lifecycle))
    let preflight = ControlPreflightObservation(stamp: preflightStamp, observedAt: observedAt, reading: reading)
    let busyPreflight = ControlPreflightObservation(stamp: preflightStamp, observedAt: observedAt, reading: busyReading)
    let moduleResult = try widestEncoded([ControlModuleResult.succeeded, .cleanupPending]
                                         + ControlFailureCode.allCases.map { ControlModuleResult.failed($0) })
    let partial = try ControlModuleOutcomes(ControlModule.allCases.map { ControlModuleOutcome(module: $0, result: moduleResult) })
    let preferences = try ControlPreferencesReceipt(requestID: requestID, incarnation: incarnation,
                                                    preferences: try widestEncoded(try componentWrites(.preferences, namespace: namespace)))
    return [
        ("configuration-receipt-conditional-dns", .configurationSettled(try receipt([.proxy, .tunnels], conditionalDNS: companion))),
        ("configuration-receipt-three-members", .configurationSettled(try receipt(ControlModule.allCases, conditionalDNS: nil))),
        ("saved-start-receipt-prior-conditional-dns", .configurationSettled(try receipt([.proxy], conditionalDNS: companion, prior: savedPrior))),
        ("saved-start-receipt-prior-tunnels", .configurationSettled(try receipt([.tunnels], conditionalDNS: nil, prior: savedPrior))),
        ("preferences-receipt", .preferencesSettled(preferences)),
        ("stop-dns-disable", try completed(.stop, .dnsDisable(disable))),
        ("stop-settled", try completed(.stop, .settled)),
        ("credentials-changed", try completed(.credentialsChanged, .settled)),
        ("reload-widest", try completed(.reload, .reload(try widestEncoded(reloadResults().results)))),
        ("quit-settled", try completed(.quit, .settled)),
        ("test-dns", try completed(.testDNS, .dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(65_535), answered: false)))),
        ("test-upstream", try completed(.testUpstream, .upstreamProbe(probe))),
        ("refresh-preflight-widest-reading", try completed(.refreshPreflight, .preflight(preflight))),
        ("refresh-preflight-busy-read", try completed(.refreshPreflight, .preflight(busyPreflight))),
        ("set-launch-at-login", try completed(.setLaunchAtLogin, .platformWrite(platform))),
        ("partially-completed", .partiallyCompleted(partial)),
        ("failed", .failed(try widestEncoded(ControlFailureCode.allCases))),
        ("superseded", .superseded(by: ControlOperationID(rawValue: widestID))),
    ]
}

/// The widest outcome and control-log entry over `widestOutcomes`, each measured with the codec as the service retains it.
func widestRetained() throws -> (outcome: Int, outcomeLabel: String, finished: Int, finishedLabel: String) {
    var result = (outcome: -1, outcomeLabel: "none", finished: -1, finishedLabel: "none")
    for (label, outcome) in try widestOutcomes() {
        let outcomeBytes = encodedSize(outcome)
        let finishedBytes = encodedSize(ControlOperationFinished(operationID: ControlOperationID(rawValue: widestID), outcome: outcome))
        guard outcomeBytes > 0, finishedBytes > 0 else { throw ProbeError("outcomeNotEncodable") }
        if outcomeBytes > result.outcome { result.outcome = outcomeBytes; result.outcomeLabel = label }
        if finishedBytes > result.finished { result.finished = finishedBytes; result.finishedLabel = label }
    }
    return result
}

// MARK: - Candidate profile

/// ONE measured CANDIDATE control-service profile for this experiment, not a shipping default. Its collection caps (10,000 rows, 4 MiB
/// capture, 8 MiB retained) are the ones decision 0038 selected; every other term follows the input proposal and is not selected.
/// Every byte term that depends on a record is derived from a codec measurement or found by bisecting the actual initializer, whose
/// budget and record-size members are internal in a Release build. Nothing here widens product access.
enum CandidateProfile {
    static let label = "CANDIDATE-4K-64K-10K-4M experiment profile; collection caps selected by decision 0038, other terms proposed only"
    static let maxRequestBytes = 4_096
    static let maxReplyBytes = 65_536
    static let aliasCapacityPerPartition = 64
    static let ordinaryPendingCapacity = 8
    static let outcomeCapacity = 64
    static let controlLogCapacity = 64
    static let retentionSeconds: Int64 = 300
    static let laneCapacity = 4
    static let subscriberLimit = 4
    static let ringCapacity = 256
    static let ringBytes = 262_144
    /// The probe's explicit event cap, NOT derived from a catalogue sweep; the run reports the widest event it observed.
    static let maxEventBytes = 8_192
    static let drainItems = 32
    static let drainBytes = 65_536
    /// The collection bounds are this experiment's only; the owner has not chosen the list behaviour. The row COUNT is the product's
    /// default active-connection limit (10,000), and the capture and retained BYTE caps are independent of it: a capture over 4 MiB is
    /// refused whole with its exact total, whatever its count. No row count times worst row is reserved.
    static let collectionRowCapacity = 10_000
    static let collectionCaptureBytes = 4_194_304
    static let collectionRetainedBytes = 8_388_608
    static let collectionProofsPerKind = 4
    static let collectionRowRevisionsPerKind = 2
    static let collectionRowRetentionSeconds: Int64 = 60
    static let subscriberRecordBytes = 1_024

    /// The byte terms one construction takes. The defaults are provisional values for the bisections only.
    struct Terms {
        var aliasBytes = 16_384
        var outcomeBytes = 1 << 20
        var controlLogBytes = 1 << 20
        var rows = CandidateProfile.collectionRowCapacity
        var captureBytes = 1 << 20
        var retainedBytes = 1 << 21
        var latestSnapshot = 32_768
        var subscriberRecord = CandidateProfile.subscriberRecordBytes
        var ceiling = 1 << 50
    }

    static func limits(_ terms: Terms) throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: maxRequestBytes, maxReplyBytes: maxReplyBytes,
            aliasCapacityPerPartition: aliasCapacityPerPartition, aliasByteCapacityPerPartition: terms.aliasBytes,
            ordinaryPendingCapacity: ordinaryPendingCapacity, outcomeCapacity: outcomeCapacity, outcomeByteCapacity: terms.outcomeBytes,
            retentionAge: .seconds(retentionSeconds), janitorBatch: 16,
            ordinaryLaneCapacity: laneCapacity, readLaneCapacity: laneCapacity, streamLaneCapacity: laneCapacity,
            stopLaneCapacityPerModule: 1, subscriberLimit: subscriberLimit,
            ringCapacity: ringCapacity, ringByteCapacity: ringBytes, maxEventBytes: maxEventBytes,
            ingressCapacity: ringCapacity, ingressByteCapacity: ringBytes, drainItemsPerTurn: drainItems, drainBytesPerTurn: drainBytes,
            controlLogCapacity: controlLogCapacity, controlLogByteCapacity: terms.controlLogBytes, replayChunkItems: 32, replayChunkBytes: 32_768,
            collectionRowCapacity: terms.rows, collectionByteCapacity: terms.captureBytes, collectionProofCapacityPerKind: collectionProofsPerKind,
            collectionRowRevisionsPerKind: collectionRowRevisionsPerKind, collectionRetainedByteCapacity: terms.retainedBytes,
            collectionRowRetentionAge: .seconds(collectionRowRetentionSeconds),
            latestSnapshotByteCapacity: terms.latestSnapshot, subscriberRecordBytes: terms.subscriberRecord, retainedByteCeiling: terms.ceiling
        )
    }

    static func accepts(_ terms: Terms) -> Bool {
        do {
            _ = try limits(terms)
            return true
        } catch {
            return false
        }
    }

    /// The smallest value in `low...high` the initializer accepts, for a term it accepts from some value upward; nil when `high` is refused.
    static func smallestAccepted(_ low: Int, _ high: Int, _ terms: (Int) -> Terms) -> Int? {
        guard accepts(terms(high)) else { return nil }
        if accepts(terms(low)) { return low }
        var refused = low
        var accepted = high
        while accepted - refused > 1 {
            let middle = refused + (accepted - refused) / 2
            if accepts(terms(middle)) { accepted = middle } else { refused = middle }
        }
        return accepted
    }

    /// The largest value in `low...high` the initializer accepts, for a term it accepts up to some value; nil when `low` is refused.
    static func largestAccepted(_ low: Int, _ high: Int, _ terms: (Int) -> Terms) -> Int? {
        guard accepts(terms(low)) else { return nil }
        if accepts(terms(high)) { return high }
        var accepted = low
        var refused = high
        while refused - accepted > 1 {
            let middle = accepted + (refused - accepted) / 2
            if accepts(terms(middle)) { accepted = middle } else { refused = middle }
        }
        return accepted
    }

    /// The constructor's budget for `terms`: the smallest ceiling it accepts.
    static func budget(_ terms: Terms) -> Int? {
        smallestAccepted(1, 1 << 50) { var trial = terms; trial.ceiling = $0; return trial }
    }
}

/// The candidate as built, with every measured input it was derived from.
struct CandidateBuild {
    let limits: RuntimeServiceLimits
    let terms: CandidateProfile.Terms
    let budget: Int
    let aliasRecordBytes: Int
    let subscriberRecordMinimumBytes: Int
    let latestSnapshotMaximumBytes: Int
    let widestOutcomeBytes: Int
    let widestOutcomeLabel: String
    let widestFinishedBytes: Int
    let widestFinishedLabel: String
    let widestRowBytes: Int
    let widestRowKind: String
    let aliasPartitionsCharged: Int

    static func derive() throws -> CandidateBuild {
        var terms = CandidateProfile.Terms()
        // The worst alias record, the subscriber record's layout and the largest snapshot a 64 KiB baseline frame carries are each the
        // initializer's own measured bound, found by bisection.
        guard let alias = CandidateProfile.smallestAccepted(1, 1 << 20, { var t = terms; t.aliasBytes = $0; return t }),
              let subscriber = CandidateProfile.smallestAccepted(1, 1 << 20, { var t = terms; t.subscriberRecord = $0; return t }),
              let snapshot = CandidateProfile.largestAccepted(1, CandidateProfile.maxReplyBytes, { var t = terms; t.latestSnapshot = $0; return t })
        else { throw ProbeError("profileBisection") }
        terms.aliasBytes = CandidateProfile.aliasCapacityPerPartition * alias
        terms.latestSnapshot = snapshot
        // The stated 1 KiB charge, or the measured layout if that is larger: the initializer refuses a charge below the record.
        terms.subscriberRecord = max(CandidateProfile.subscriberRecordBytes, subscriber)
        let retained = try widestRetained()
        terms.outcomeBytes = CandidateProfile.outcomeCapacity * retained.outcome
        terms.controlLogBytes = CandidateProfile.controlLogCapacity * retained.finished
        var widestRow = (bytes: -1, kind: "none")
        for kind in ControlCollectionKind.allCases {
            let bytes = try measuredRowBytes(kind, .widest)
            if bytes > widestRow.bytes { widestRow = (bytes, kind.rawValue) }
        }
        // Independent byte caps: the widest row is measured and reported, never multiplied by the row count here.
        terms.captureBytes = CandidateProfile.collectionCaptureBytes
        terms.retainedBytes = CandidateProfile.collectionRetainedBytes
        guard widestRow.bytes > 0, widestRow.bytes <= terms.captureBytes else { throw ProbeError("widestRowOverCapture") }
        var widerAlias = terms
        widerAlias.aliasBytes += 1_024
        guard let budget = CandidateProfile.budget(terms), let widerBudget = CandidateProfile.budget(widerAlias) else {
            throw ProbeError("profileBudget")
        }
        terms.ceiling = budget
        return CandidateBuild(
            limits: try CandidateProfile.limits(terms), terms: terms, budget: budget, aliasRecordBytes: alias,
            subscriberRecordMinimumBytes: subscriber, latestSnapshotMaximumBytes: snapshot,
            widestOutcomeBytes: retained.outcome, widestOutcomeLabel: retained.outcomeLabel,
            widestFinishedBytes: retained.finished, widestFinishedLabel: retained.finishedLabel,
            widestRowBytes: widestRow.bytes, widestRowKind: widestRow.kind, aliasPartitionsCharged: (widerBudget - budget) / 1_024
        )
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
        let profile = try RuntimeServiceProfile.inProcessApp()
        // Keep independent codec sizing: a changed shipping term must not silently replace the measured candidate.
        guard profile.limits == limits else { throw ProbeError("shippingProfileMismatch") }
        clients = try host.makeInMemoryControlClient(profile: profile)
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
        // The host starts observing wake once, at open, and stops once, in the quit's admission turn. The probe never fires a wake.
        let wake = fakes.wake
        out.emit(["record": "wake-observer", "starts": wake.startCount, "stops": wake.stopCount, "observingAfterRelease": wake.isObserving,
                  "wakesFired": 0])
        out.check(wake.startCount == 1 && wake.stopCount == 1 && !wake.isObserving, "release.wakeObservedOnceAndStopped")
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

/// Whether the production codec frames `body` under a cap of `cap` bytes: the codec's own refusal is the check, not arithmetic.
func framesWithin(_ body: ControlRuntimeBody, cap: Int, correlation: ControlRequestID = ControlRequestID(rawValue: widestID)) -> Bool {
    do {
        _ = try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: body),
                                                limits: try ControlFrameLimits(maxFrameBytes: cap))
        return true
    } catch {
        return false
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
func emitProfile(_ out: Output) -> CandidateBuild? {
    let build: CandidateBuild
    do {
        build = try CandidateBuild.derive()
    } catch {
        out.emit(["record": "error", "error": errorLabel(error)])
        out.check(false, "profile.initializerAccepts")
        return nil
    }
    // `RuntimePartition.all` (internal) lists ordinary, quit and one stop partition per module: read from the linked source, not
    // measurable through the package. The initializer's charge is measured above; a difference is an accounting discrepancy.
    let partitionsInSource = 2 + ControlModule.allCases.count
    let terms = build.terms
    out.emit(["record": "profile", "label": CandidateProfile.label,
              "initializerBudgetBytes": build.budget, "retainedByteCeilingBytes": terms.ceiling,
              "budgetKind": "encoded-byte reservation from the actual initializer; not an allocation and not an RSS bound",
              "aliasPartitionsChargedByInitializer": build.aliasPartitionsCharged, "aliasPartitionsInSource": partitionsInSource,
              "aliasPartitionAccountingDiscrepancy": build.aliasPartitionsCharged != partitionsInSource,
              "maxRequestBytes": CandidateProfile.maxRequestBytes, "maxReplyBytes": CandidateProfile.maxReplyBytes,
              "laneCapacityEach": CandidateProfile.laneCapacity, "stopLanePerModule": 1, "subscriberLimit": CandidateProfile.subscriberLimit,
              "ordinaryPendingCapacity": CandidateProfile.ordinaryPendingCapacity,
              "aliasCapacityPerPartition": CandidateProfile.aliasCapacityPerPartition, "aliasRecordBytesMeasured": build.aliasRecordBytes,
              "aliasByteCapacityPerPartition": terms.aliasBytes,
              "outcomeCapacity": CandidateProfile.outcomeCapacity, "widestOutcomeBytes": build.widestOutcomeBytes,
              "widestOutcomeKind": build.widestOutcomeLabel, "outcomeByteCapacity": terms.outcomeBytes,
              "controlLogCapacity": CandidateProfile.controlLogCapacity, "widestFinishedBytes": build.widestFinishedBytes,
              "widestFinishedKind": build.widestFinishedLabel, "controlLogByteCapacity": terms.controlLogBytes,
              "retentionSeconds": Int(CandidateProfile.retentionSeconds),
              "ringCapacity": CandidateProfile.ringCapacity, "ringBytes": CandidateProfile.ringBytes,
              "ingressCapacity": CandidateProfile.ringCapacity, "ingressBytes": CandidateProfile.ringBytes,
              "drainItemsPerTurn": CandidateProfile.drainItems, "drainBytesPerTurn": CandidateProfile.drainBytes,
              "maxEventBytes": CandidateProfile.maxEventBytes, "maxEventBytesBasis": "probe choice; not derived from a catalogue sweep",
              "latestSnapshotByteCapacity": terms.latestSnapshot,
              "baselineFrameOverheadBytesMeasured": CandidateProfile.maxReplyBytes - build.latestSnapshotMaximumBytes,
              "subscriberRecordBytes": terms.subscriberRecord, "subscriberRecordMinimumAccepted": build.subscriberRecordMinimumBytes,
              "collectionRowCapacity": terms.rows, "collectionRowCapacityBasis": "selected by decision 0038; count and byte caps independent; over-budget list unavailable whole",
              "widestRowBytes": build.widestRowBytes, "widestRowKind": build.widestRowKind,
              "collectionCaptureBytes": terms.captureBytes, "collectionRetainedBytes": terms.retainedBytes,
              "collectionProofsPerKind": CandidateProfile.collectionProofsPerKind,
              "collectionRowRevisionsPerKind": CandidateProfile.collectionRowRevisionsPerKind,
              "collectionRowRetentionSeconds": Int(CandidateProfile.collectionRowRetentionSeconds),
              "privateRequestFrameCap": PrivateConfigurationFrame.maxRequestFrameBytes,
              "privateReplyFrameCap": PrivateConfigurationFrame.maxEditorReplyFrameBytes,
              "privateCustodyKind": "one transfer and one admitted input, outside the service budget",
              "runtimeFileBytes": DomainResourceLimits.runtimeConfigurationFileBytes,
              "sidecarFileBytes": DomainResourceLimits.sidecarFileBytes])
    out.check(build.aliasPartitionsCharged == partitionsInSource, "profile.aliasPartitionsMatchSource")
    return build
}

/// small: scratch session, actual host open, composition, private read, frozen save, readback, preferences save, a private
/// proxy Start on a live loopback listener, status reads, an ordinary Stop, then the framed Quit with its ID-bound final save
/// (composed here from the clients' primitives, not the client quit routine), and the confirmed release.
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

    // The framed Quit with its ID-bound reserved configuration save, under one total deadline. This step composes the Quit and the
    // final save from the clients' primitives itself; it is NOT `RuntimeClientQuit.quit`, which `client-quit-widest` exercises.
    var quitRecord: [String: Any] = ["probeHeld": "fixture", "quitPath": "manual-composition-not-RuntimeClientQuit"]
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
    // The ordinary Restart is the saved Restart (decision 0037): it settles with its causal receipt, or fails with a closed cause.
    var restartPrior = "no-receipt"
    if case .configurationSettled(let receipt)? = restartDone.outcome { restartPrior = receipt.prior == nil ? "absent" : "present" }
    out.emit(["record": "held-helper", "restartAdmission": admissionLabel(restart), "restartAdmissionMS": restartAdmissionMS,
              "restartPath": "saved-restart", "restartReceiptPrior": restartPrior,
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

// MARK: - The actual client quit routine

func quitStepLabel(_ step: RuntimeQuitStep) -> String {
    switch step {
    case .notDeclared: "notDeclared"
    case .settled(let outcome): "settled.\(outcomeLabel(outcome))"
    case .rejected(let code): "rejected.\(code.rawValue)"
    case .notRecorded(let reason): "notRecorded.\(reason.rawValue)"
    case .clientFailure(let error): "clientFailure.\(errorLabel(error))"
    case .unsettled: "unsettled"
    case .skipped: "skipped"
    }
}

/// The caller's own record of when the routine invoked each final-save producer and which prior step it handed over. The
/// producers are the caller's closures, so recording inside them adds no hook to the routine.
final class ProducerLog: @unchecked Sendable {
    struct Entry {
        let name: String
        let at: ContinuousClock.Instant
        let handed: String
        let rebasedRuntime: Bool
        let rebasedPlatform: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ name: String, _ handed: RuntimeQuitStep, rebasedRuntime: Bool = false, rebasedPlatform: Bool = false) {
        let entry = Entry(name: name, at: .now, handed: quitStepLabel(handed), rebasedRuntime: rebasedRuntime, rebasedPlatform: rebasedPlatform)
        lock.withLock { entries.append(entry) }
    }

    var all: [Entry] { lock.withLock { entries } }
}

/// client-quit-widest: the ACTUAL client quit routine, `RuntimeClientQuit.quit` from ConduitShared, over the real framed and
/// private clients. Its commands are not composed here. The validator-widest fixture runs with the proxy started. An earlier wide save-only
/// update P is held in its runtime-file replacement (the file-access seam), the routine is started with P named as its prior
/// update, and only then is P released. The final-save producers are the caller's: all save-only, the configuration at the exact
/// baselines read before the quit and rebased only from P's settled receipt, the preferences at their exact baseline. Measured:
/// the routine's duration, when each producer ran after the release, memory at each stage, every declared step, the files on
/// disk and the physical cleanup (listener closed, fake system proxy cleared, host runtime state down).
@MainActor
func runClientQuit(_ run: HostRun, limits: RuntimeServiceLimits) async throws {
    let out = run.out
    let stages = run.stages
    let gate = run.fakes.files.replaceGate
    // Never leave the store held on an error path: the error handler's shutdown would wait on it.
    defer { gate.release() }
    let port = try reserveLoopbackPort()
    let widest = makeValidatorWidestConfig(port: port)
    let priorDraft = { var draft = widest; draft.logging.verbose = true; return draft }()
    // Distinct from the fixture and from P, at the same width: one upstream priority, still within its validated range.
    let finalDraft = { var draft = widest; draft.upstreams[0].priority = Int.max - 1_000; return draft }()
    let platform = makePlatform()
    let finalPreferences = { var preferences = makeSmallPreferences(); preferences.automaticUpdateChecks = true; return preferences }()
    out.emit(["record": "fixture", "fixture": "validator-widest", "quitPath": "RuntimeClientQuit.quit",
              "validationProblems": widest.validate().count, "priorDraftValidationProblems": priorDraft.validate().count,
              "finalDraftValidationProblems": finalDraft.validate().count,
              "resourceViolation": widest.resourceViolation() == nil && finalDraft.resourceViolation() == nil ? "none" : "violated",
              "upstreams": widest.upstreams.count, "tunnels": widest.tunnels.definitions.count, "tunnelCase": "hard-ceiling-128"])
    out.check(widest.validate().isEmpty && priorDraft.validate().isEmpty && finalDraft.validate().isEmpty
              && widest.resourceViolation() == nil && finalDraft.resourceViolation() == nil, "fixture.validatorAccepts")
    _ = try await run.openRunning(limits: limits, config: widest)
    out.check(loopbackAccepts(port) && run.fakes.machine.service("Wi-Fi").webProxy.enabled, "setup.listenerAndSystemProxyLive")
    stages.stage("running-validator-widest", ["probeHeld": "fixture,prior-draft,final-draft"])

    let editor = run.editor
    let control = run.control
    guard let incarnation = run.incarnation else { throw ProbeError("noIncarnation") }
    let priorID = ControlRequestID(rawValue: UUID())
    let baselines: (runtime: PrivateBaseline, platform: PrivateBaseline, preferences: PrivateBaseline)
    var priorTask: Task<String, Never>?
    gate.arm()
    do {
        let observed = try await run.read().0
        guard let runtime = observed.components.runtime.baseline, let platformBaseline = observed.components.platform.baseline,
              let preferences = observed.components.preferences.baseline else { throw ProbeError("noBaseline") }
        baselines = (runtime, platformBaseline, preferences)
        priorTask = Task.detached { () -> String in
            do {
                return admissionLabel(try await privateSubmit(
                    editor, incarnation: incarnation, config: priorDraft, platform: platform, observed: observed, modules: allSaveOnly,
                    requestID: priorID, deadline: .after(.seconds(60), from: .now)
                ))
            } catch { return errorLabel(error) }
        }
    }
    let holdDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !gate.isHolding, ContinuousClock.now < holdDeadline { try await Task.sleep(for: .milliseconds(1)) }
    out.check(gate.isHolding, "prior.heldInRuntimeFileReplacement")
    guard gate.isHolding else { throw ProbeError("priorNotHeld") }
    stages.stage("prior-held", ["probeHeld": "fixture,prior-draft,final-draft,observation-until-prior-admitted"])

    let log = ProducerLog()
    let configurationProducer: @Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest = { requestID, handed in
        var runtimeBaseline = baselines.runtime
        var platformBaseline = baselines.platform
        var rebasedRuntime = false
        var rebasedPlatform = false
        // A settled receipt of the prior update is the only fact a submitted baseline may be rebased from.
        if case .settled(.configurationSettled(let receipt)) = handed {
            if let baseline = receipt.runtime.baseline { runtimeBaseline = baseline; rebasedRuntime = true }
            if let baseline = receipt.platform.baseline { platformBaseline = baseline; rebasedPlatform = true }
        }
        log.record("configuration", handed, rebasedRuntime: rebasedRuntime, rebasedPlatform: rebasedPlatform)
        return try PrivateConfigurationBridge.makeRequest(
            config: finalDraft, platform: platform, requestID: requestID, incarnation: incarnation,
            budget: try ControlWireBudget(60_000), runtimeBaseline: runtimeBaseline, platformBaseline: platformBaseline,
            modules: allSaveOnly
        )
    }
    let preferencesProducer: @Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivatePreferencesRequest = { requestID, handed in
        log.record("preferences", handed)
        return try PrivateConfigurationBridge.makePreferencesRequest(
            preferences: finalPreferences, requestID: requestID, incarnation: incarnation,
            budget: try ControlWireBudget(60_000), preferencesBaseline: baselines.preferences
        )
    }
    let total: Duration = .seconds(10) // Decision 0039: one total, also pinned by the app composition tests.
    let quitStart = ContinuousClock.now
    var quitting: Task<RuntimeClientQuitResult, Never>? = Task.detached {
        await RuntimeClientQuit.quit(
            control: control, editor: editor, incarnation: incarnation, total: total, now: quitStart, priorUpdate: priorID,
            configuration: configurationProducer, preferences: preferencesProducer
        )
    }

    // While P still holds the one frozen input: the host keeps serving status, the Quit has fenced, and no final save is mapped.
    try await Task.sleep(for: .milliseconds(50))
    try await run.statusSamples(20, condition: "client-quit-waiting-on-held-prior")
    var hold: [String: Any] = ["record": "client-quit-hold"]
    do {
        let (during, readMS) = try await run.read()
        hold["readDuringHold"] = "observation"
        hold["terminalLatched"] = during.terminal
        hold["readMS"] = readMS
    } catch {
        hold["readDuringHold"] = errorLabel(error)
    }
    do {
        hold["proxyRunningDuringHold"] = try await run.readSnapshot().0.proxyState == .running
    } catch {
        hold["snapshotDuringHold"] = errorLabel(error)
    }
    hold["listenerAcceptsDuringHold"] = loopbackAccepts(port)
    hold["producerCallsDuringHold"] = log.all.count
    hold["priorStillHeld"] = gate.isHolding
    hold["heldForMS"] = elapsedMS(since: quitStart)
    out.emit(hold)
    out.check(log.all.isEmpty && gate.isHolding, "routine.noFinalSaveMappedWhilePriorHoldsInput")
    out.check(hold["terminalLatched"] as? Bool == true, "routine.quitFencedBeforePriorReleased")
    stages.stage("routine-waiting-on-held-prior", ["probeHeld": "fixture,prior-draft,final-draft"])

    let releasedAt = ContinuousClock.now
    gate.release()
    let result = await quitting!.value
    let routineMS = elapsedMS(since: quitStart)
    let releaseToReturnMS = elapsedMS(since: releasedAt)
    quitting = nil
    let priorAdmission = await priorTask!.value
    priorTask = nil
    stages.stage("client-quit-returned", ["routineMS": routineMS, "releaseToReturnMS": releaseToReturnMS,
                                          "probeHeld": "fixture,prior-draft,final-draft,result"])

    let entries = log.all
    var routine: [String: Any] = [
        "record": "client-quit", "path": "RuntimeClientQuit.quit", "totalDeadlineMS": milliseconds(total),
        "quit": quitStepLabel(result.quit), "priorUpdate": quitStepLabel(result.priorUpdate),
        "configuration": quitStepLabel(result.configuration), "preferences": quitStepLabel(result.preferences),
        "observationFailure": result.observationFailure.map { errorLabel($0) } ?? "none", "priorAdmission": priorAdmission,
        "routineMS": routineMS, "releaseToReturnMS": releaseToReturnMS,
        "returnedBeforeFinalReadReserve": routineMS < milliseconds(total) - 200, "producerCalls": entries.count,
        "producerOrder": entries.map(\.name).joined(separator: ","),
    ]
    for entry in entries {
        routine["\(entry.name)ProducerAfterReleaseMS"] = milliseconds(releasedAt.duration(to: entry.at))
        routine["\(entry.name)ProducerHanded"] = entry.handed
    }
    let configurationEntry = entries.first { $0.name == "configuration" }
    routine["configurationRebasedRuntimeFromPriorReceipt"] = configurationEntry?.rebasedRuntime ?? false
    routine["configurationRebasedPlatformFromPriorReceipt"] = configurationEntry?.rebasedPlatform ?? false
    if case .settled(.configurationSettled(let receipt)) = result.priorUpdate {
        routine["priorRuntimeWrite"] = writeLabel(receipt.runtime.write)
        routine["priorPlatformWrite"] = writeLabel(receipt.platform.write)
    }
    var finalPersisted = false
    var finalSaveOnly = false
    if case .settled(.configurationSettled(let receipt)) = result.configuration {
        finalPersisted = receipt.runtime.write == .persisted(reportedError: false)
        finalSaveOnly = receipt.applied == nil && receipt.modules.isEmpty
        routine["finalRuntimeWrite"] = writeLabel(receipt.runtime.write)
        routine["finalPlatformWrite"] = writeLabel(receipt.platform.write)
        routine["finalAppliedField"] = receipt.applied.map { $0 ? "true" : "false" } ?? "absent"
        routine["finalModuleReceipts"] = receipt.modules.count
        routine["finalLookupReplyFrameBytes"] = ordinaryFrameBytes(.response(.lookup(.finished(.configurationSettled(receipt)))))
    }
    var preferencesPersisted = false
    if case .settled(.preferencesSettled(let receipt)) = result.preferences {
        preferencesPersisted = receipt.preferences.write == .persisted(reportedError: false)
        routine["finalPreferencesWrite"] = writeLabel(receipt.preferences.write)
    }
    // Physical cleanup, read from the fakes and the loopback port, not from the routine's answer.
    let listenerClosed = !loopbackAccepts(port)
    let systemProxyCleared = !run.fakes.machine.service("Wi-Fi").webProxy.enabled
    let hostProxyDown = run.host?.runtimeState().proxyIsUp == false
    routine["listenerClosed"] = listenerClosed
    routine["systemProxyCleared"] = systemProxyCleared
    routine["hostRuntimeProxyDown"] = hostProxyDown
    out.emit(routine)

    out.check(quitStepLabel(result.quit) == "settled.completed.quit", "routine.quitCompleted")
    out.check(quitStepLabel(result.priorUpdate) == "settled.configurationSettled", "routine.priorUpdateSettled")
    out.check(finalPersisted && finalSaveOnly, "routine.finalConfigurationPersistedSaveOnly")
    out.check(preferencesPersisted, "routine.finalPreferencesPersisted")
    out.check(result.observationFailure == nil, "routine.noObservationFailure")
    out.check(entries.map(\.name) == ["configuration", "preferences"]
              && entries.allSatisfy { releasedAt.duration(to: $0.at) >= .zero }, "routine.eachProducerOnceAfterRelease")
    out.check(configurationEntry?.handed == quitStepLabel(result.priorUpdate), "routine.producerHandedPriorSettlement")
    out.check(listenerClosed && systemProxyCleared && hostProxyDown, "routine.physicalCleanup")

    // The files on disk, read after every step settled. Re-encoding the final request measures the frame the routine sent.
    do {
        let onDisk = try ProxyConfigPersistence.load(in: run.environment, allowMissing: false)
        let preferencesOnDisk = try AppPreferencesPersistence.load(in: run.environment)
        out.check(onDisk == finalDraft, "disk.runtimeFileIsFinalDraft")
        out.check(preferencesOnDisk == finalPreferences, "disk.preferencesAreFinalDraft")
        let request = try PrivateConfigurationBridge.makeRequest(
            config: finalDraft, platform: platform, requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
            budget: try ControlWireBudget(60_000), runtimeBaseline: baselines.runtime, platformBaseline: baselines.platform,
            modules: allSaveOnly
        )
        out.emit(["record": "codec-sizes", "fixture": "validator-widest", "finalSaveRequestFrameBytes": try PrivateConfigurationEncoder.encode(request).count])
    }
    stages.stage("client-quit-verified", ["probeHeld": "fixture,prior-draft,final-draft"])
    out.emit(["record": "fakes", "pacFetches": run.fakes.pac.fetchCount, "gssCalls": run.fakes.gss.calls,
              "privilegedCommands": run.fakes.machine.privilege.commands.count])
    out.check(run.fakes.pac.fetchCount == 0 && run.fakes.gss.calls == 0, "fakes.noPACOrGSS")
}

/// codec-bounds: no host. The actual codecs over the widest metadata the types admit, as separate counts from the measured
/// frames (whose versions are small store versions, not `UInt64.max`); then every final ordinary request, every settled outcome and
/// every other reply and stream frame at its widest, each checked against the candidate's caps by the codec.
@MainActor
func runCodecBounds(_ out: Output, build: CandidateBuild) throws {
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
    // DNS's conditional companion is valid only in its own slot beside a proxy Start (decision 0036).
    var companionRequest = "measured"
    do {
        widestRequest = max(widestRequest, try requestBytes(
            budget: Int(Int32.max), version: .max,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: maxRevision), dns: .conditionalStart(ifLifecycleRevision: maxRevision),
                                        tunnels: .start(ifLifecycleRevision: maxRevision))
        ))
    } catch {
        companionRequest = "refused." + errorLabel(error)
    }
    out.emit(["record": "metadata-request", "label": "actual private request codec over a small configuration",
              "measuredShapeFrameBytes": measuredShape, "widestMetadataFrameBytes": widestRequest,
              "widestMetadataDeltaBytes": widestRequest - measuredShape, "conditionalStartCompanion": companionRequest])

    // Every ordinary request the clients can send, each at its widest legal form, framed by the production codec. The candidate's
    // request cap is checked by encoding at that cap.
    let maxBudget = try ControlWireBudget(Int(Int32.max))
    let calls = try widestCalls()
    var widestOrdinary = (bytes: -1, label: "none")
    var requestsWithinCap = true
    for (label, call) in calls {
        let body = ControlRuntimeBody.request(ControlRuntimeRequest(budget: maxBudget, call: call))
        let bytes = ordinaryFrameBytes(body)
        let fits = bytes > 0 && framesWithin(body, cap: CandidateProfile.maxRequestBytes)
        requestsWithinCap = requestsWithinCap && fits
        if bytes > widestOrdinary.bytes { widestOrdinary = (bytes, label) }
        out.emit(["record": "ordinary-request", "call": label, "frameBytes": bytes, "framesWithinCandidateRequestCap": fits])
    }
    out.emit(["record": "ordinary-request-bounds", "label": "widest legal forms the probe built; not a proven absolute maximum",
              "calls": calls.count, "widestRequestFrameBytes": widestOrdinary.bytes, "widestRequestCall": widestOrdinary.label,
              "candidateMaxRequestBytes": CandidateProfile.maxRequestBytes])
    out.check(requestsWithinCap, "ordinary.everyRequestFramesWithinCandidateCap")

    // Every settled outcome at its widest, as the service retains it (outcome and control-log entry) and as it is framed: the lookup
    // reply and the stream's settlement frame. Each is checked against the candidate's own caps by the codec and by the measured sizes.
    let replyCap = CandidateProfile.maxReplyBytes
    var outcomesWithin = true
    var widestLookup = (bytes: -1, label: "none")
    var widestStream = (bytes: -1, label: "none")
    for (label, outcome) in try widestOutcomes() {
        let finished = ControlOperationFinished(operationID: ControlOperationID(rawValue: widestID), outcome: outcome)
        let outcomeBytes = encodedSize(outcome)
        let finishedBytes = encodedSize(finished)
        let lookup = ControlRuntimeBody.response(.lookup(.finished(outcome)))
        let stream = ControlRuntimeBody.frame(.operationFinished(finished))
        let lookupBytes = ordinaryFrameBytes(lookup)
        let streamBytes = ordinaryFrameBytes(stream)
        let fits = framesWithin(lookup, cap: replyCap) && framesWithin(stream, cap: replyCap)
            && outcomeBytes > 0 && outcomeBytes <= build.terms.outcomeBytes && finishedBytes > 0 && finishedBytes <= build.terms.controlLogBytes
        outcomesWithin = outcomesWithin && fits
        if lookupBytes > widestLookup.bytes { widestLookup = (lookupBytes, label) }
        if streamBytes > widestStream.bytes { widestStream = (streamBytes, label) }
        out.emit(["record": "outcome-bounds", "kind": label, "outcomeBytes": outcomeBytes, "finishedBytes": finishedBytes,
                  "lookupReplyFrameBytes": lookupBytes, "operationFinishedFrameBytes": streamBytes, "withinCandidateBounds": fits])
    }
    out.emit(["record": "receipt-bounds", "widestLookupReplyFrameBytes": widestLookup.bytes, "widestLookupKind": widestLookup.label,
              "widestOperationFinishedFrameBytes": widestStream.bytes, "widestOperationFinishedKind": widestStream.label,
              "candidateMaxReplyBytes": replyCap, "candidateOutcomeByteCapacity": build.terms.outcomeBytes,
              "candidateControlLogByteCapacity": build.terms.controlLogBytes])
    out.check(outcomesWithin, "receipt.everyWidestOutcomeFitsCandidateBounds")
    let pairs = try preflightReadingCandidates()
    out.emit(["record": "preflight-pairs", "helperStatuses": ControlHelperStatus.allCases.count, "acceptedBusyRead": pairs.busy.count,
              "acceptedConclusiveRead": pairs.conclusive.count, "refusedByItemsOrCodec": pairs.refused])

    // Every reload answer, finite: each framed as its completed lookup reply at the candidate's reply cap and decoded back through the
    // actual codec, which must give the same message.
    let reloads = reloadResults()
    guard let revision = ControlPresentationRevision(rawValue: Int.max) else { throw ProbeError("revision") }
    let replyLimits = try ControlFrameLimits(maxFrameBytes: replyCap)
    var reloadRoundTrips = 0
    var widestReloadLookup = -1
    for result in reloads.results {
        let completion = try ControlCompletion(command: .reload, presentationRevision: revision, result: .reload(result))
        let message = ControlRuntimeMessage(correlation: ControlRequestID(rawValue: widestID),
                                            body: .response(.lookup(.finished(.completed(completion)))))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: replyLimits)
        if try ControlRuntimeCodec.decodeFullFrame(frame, limits: replyLimits) == message { reloadRoundTrips += 1 }
        widestReloadLookup = max(widestReloadLookup, frame.count)
    }
    out.emit(["record": "reload-variants", "variants": reloads.results.count, "heldPairsRefusedForReloadPhase": reloads.heldPairsRefused,
              "roundTripped": reloadRoundTrips, "widestLookupReplyFrameBytes": widestReloadLookup])
    out.check(reloadRoundTrips == reloads.results.count && reloads.results.count > 0, "reload.everyVariantFramesAndRoundTrips")

    // The other replies and stream frames, each at its widest closed value.
    guard let cursor = ControlEventCursor(rawValue: widestCursorRaw) else { throw ProbeError("cursor") }
    let admission = try widestEncoded([ControlAdmission.accepted(ControlOperationID(rawValue: widestID)), .joined(ControlOperationID(rawValue: widestID))]
                                      + ControlRejectionCode.allCases.map { ControlAdmission.rejected($0) })
    let unknownReason = try widestEncoded(ControlUnknownOutcomeReason.allCases)
    let others: [(String, ControlRuntimeBody)] = [
        ("admission-reply", .response(.admission(admission))),
        ("request-lookup-reply", .response(.requestLookup(try widestEncoded([ControlRequestLookup.admission(admission), .unknown(unknownReason)])))),
        ("lookup-pending-reply", .response(.lookup(.pending))),
        ("lookup-unknown-reply", .response(.lookup(.unknown(unknownReason)))),
        ("failure-reply", .response(.failure(try widestEncoded(ControlRuntimeErrorCode.allCases)))),
        ("page-unavailable-reply", .response(.page(.unavailable(try widestEncoded(ControlCollectionKind.allCases),
                                                                try widestEncoded(ControlCollectionUnavailableReason.allCases),
                                                                knownTotal: try ControlCount(Int.max))))),
        ("stream-end-frame", .frame(.end(try widestEncoded(ControlStreamEndReason.allCases.map { ControlStreamEnd(reason: $0) })))),
        ("replay-caught-up-frame", .frame(.replayCaughtUp(cursor))),
    ]
    var othersWithin = true
    for (label, body) in others {
        let bytes = ordinaryFrameBytes(body)
        let fits = bytes > 0 && framesWithin(body, cap: replyCap)
        othersWithin = othersWithin && fits
        out.emit(["record": "reply-bounds", "kind": label, "frameBytes": bytes, "framesWithinCandidateReplyCap": fits])
    }
    out.check(othersWithin, "reply.everyOtherReplyAndFrameFitsCandidateCap")
    _ = zeroRevision
}

// MARK: - Profile sizing (no host)

typealias KernelEdit = (inout ProxyOrchestratorSnapshot) -> Void

/// The widest scalar snapshot the probe built through the actual projection: every displayed text past its cap in NUL, every counter at
/// `Int.max`, every date and number at its widest encoding, every binding present, the stamp and its module revisions at `Int.max`,
/// every collection revision available at `Int.max`, and each closed state chosen by encoding every case. It is not a proven maximum:
/// collection totals stay at the fixture's small counts, since a wider total needs that many kernel rows.
func widestSnapshot() throws -> ControlRuntimeSnapshot {
    let date = try widestDate()
    let number = try widestNonNegative()
    guard let presentation = ControlPresentationRevision(rawValue: Int.max), let config = ControlConfigRevision(rawValue: Int.max),
          let lifecycle = ControlLifecycleRevision(rawValue: Int.max), let collection = ControlCollectionRevision(rawValue: Int.max)
    else { throw ProbeError("revision") }
    let stamp = ControlRuntimeStamp(incarnation: ControlHostIncarnation(rawValue: widestID), presentationRevision: presentation,
                                    configRevision: config, lifecycleRevision: lifecycle,
                                    modules: ControlModuleRevisions(proxy: lifecycle, dns: lifecycle, tunnels: lifecycle))
    let revisions = ControlCollectionRevisions(activeConnections: collection, upstreamHealth: collection, tunnelBindings: collection,
                                               tunnelDNSHosts: collection)
    var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .unavailable(reason: nulDiagnostic))
    kernel.runtimeStatus.activeUpstream = nulDiagnostic
    kernel.runtimeStatus.lastHealthSummary = nulDiagnostic
    kernel.runtimeStatus.metrics = ProxyMetrics(
        requestsHandled: .max, successfulRecoveries: .max, failedRequests: .max, openConnections: .max, inboundConnections: .max,
        uptimeStartedAt: date, lastFailure: date, vpnFlapCount: .max, vpnFlapTotalDuration: number, lastVpnFlapAt: date,
        streamsPreservedAcrossFlaps: .max
    )
    kernel.proxyError = nulDiagnostic
    kernel.dnsError = nulDiagnostic
    kernel.tunnelsError = nulDiagnostic
    kernel.vpnInterfaceName = nulDiagnostic
    kernel.lastAuthFallbackReason = nulDiagnostic
    kernel.lastAuthOutcomeAt = date
    kernel.dnsQueryCount = .max
    kernel.dnsDoHFallbackCount = .max
    kernel.dnsCacheHitCount = .max
    kernel.tunnelActiveCount = .max
    kernel.tunnelSessionCount = .max
    kernel.bindings = ProxyOrchestratorBindings(
        proxyHost: nulDiagnostic, proxyPort: 65_535, socksHost: nulDiagnostic, socksPort: 65_535, localPACHost: nulDiagnostic,
        localPACPort: 65_535, dnsHost: nulDiagnostic, dnsPort: 65_535, transparentProxyHost: nulDiagnostic, transparentProxyPort: 65_535
    )
    func project(_ value: ProxyOrchestratorSnapshot) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(value, stamp: stamp, profileName: nulDisplay, collectionRevisions: revisions)
    }
    let causes: [DirectModeCause] = [.none, .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured, .upstreamsUnreachable]
    let vpnStates: [VPNObservedState] = [.unknown, .connected, .reasserting, .disconnected(reason: .userInitiated),
                                         .disconnected(reason: .networkLost), .disconnected(reason: .unknown)]
    let authOutcomes: [RuntimeAuthOutcome?] = [nil, .kerberos, .ntlmFallback, .ntlmDirect]
    let choices: [[KernelEdit]] = [
        ProxyConnectionState.allCases.map { state -> KernelEdit in { $0.runtimeStatus.state = state } },
        ModuleRunState.allCases.map { state -> KernelEdit in { $0.dnsRunState = state } },
        ModuleRunState.allCases.map { state -> KernelEdit in { $0.tunnelsRunState = state } },
        causes.map { cause -> KernelEdit in { $0.directModeCause = cause } },
        vpnStates.map { state -> KernelEdit in { $0.vpnState = state } },
        authOutcomes.map { outcome -> KernelEdit in { $0.lastAuthOutcome = outcome } },
    ]
    for options in choices {
        var best = (bytes: -1, kernel: kernel)
        for edit in options {
            var trial = kernel
            edit(&trial)
            let bytes = encodedSize(try project(trial))
            if bytes > best.bytes { best = (bytes, trial) }
        }
        kernel = best.kernel
    }
    return try project(kernel)
}

/// Packs `rows` page by page through the actual `ControlPagePacker` and codec at `cap`. Every row must land in exactly one page.
func packConnectionRows(_ rows: [ControlConnectionRow], cap: Int) throws
    -> (pages: Int, firstPageRows: Int, pagesForFirst50: Int, maxFrameBytes: Int, packedRows: Int)
{
    guard let revision = ControlCollectionRevision(rawValue: 1) else { throw ProbeError("revision") }
    let limits = try ControlFrameLimits(maxFrameBytes: cap)
    let incarnation = ControlHostIncarnation(rawValue: widestID)
    var result = (pages: 0, firstPageRows: 0, pagesForFirst50: 0, maxFrameBytes: 0, packedRows: 0)
    while result.packedRows < rows.count {
        let message = try ControlPagePacker.page(of: rows, offset: result.packedRows, incarnation: incarnation, revision: revision,
                                                 correlation: ControlRequestID(rawValue: widestID), limits: limits) {
            ControlPageReply.activeConnections($0)
        }
        guard case .response(.page(.activeConnections(let page))) = message.body, !page.rows.isEmpty else { throw ProbeError("unexpectedPage") }
        result.maxFrameBytes = max(result.maxFrameBytes, try ControlRuntimeCodec.encodeFrame(message, limits: limits).count)
        if result.pages == 0 { result.firstPageRows = page.rows.count }
        result.packedRows += page.rows.count
        result.pages += 1
        if result.pagesForFirst50 == 0, result.packedRows >= min(50, rows.count) { result.pagesForFirst50 = result.pages }
    }
    return result
}

/// profile-sizing: the candidate's constructor-bound terms, the widest snapshot and its baseline frame, every collection row kind, the
/// constructor's encoded custody budget for several row bounds, and 1,024-row pages. Nothing here is allocated at those budgets: they are
/// encoded-byte reservations the initializer computes, not RSS.
@MainActor
func runProfileSizing(_ out: Output, build: CandidateBuild) throws {
    let replyCap = CandidateProfile.maxReplyBytes
    let terms = build.terms

    // The snapshot bound: the largest the initializer accepts beside a 64 KiB reply, and the widest snapshot the probe built.
    let snapshot = try widestSnapshot()
    guard let cursor = ControlEventCursor(rawValue: widestCursorRaw) else { throw ProbeError("cursor") }
    let baseline = try ControlBaseline(incarnation: snapshot.stamp.incarnation, snapshot: snapshot, highWater: cursor,
                                       replay: .replay(from: cursor, through: cursor))
    let payload = encodedSize(snapshot)
    let baselineBody = ControlRuntimeBody.frame(.baseline(baseline))
    var onePastCapacity = terms
    onePastCapacity.latestSnapshot += 1
    let baselineFits = framesWithin(baselineBody, cap: replyCap)
    out.emit(["record": "widest-snapshot", "label": "widest snapshot the probe built through the actual projection; not a proven maximum",
              "payloadBytes": payload, "snapshotFrameBytes": ordinaryFrameBytes(.frame(.snapshot(snapshot))),
              "readSnapshotReplyFrameBytes": ordinaryFrameBytes(.response(.snapshot(snapshot))),
              "baselineFrameBytesWidestCursorAndReplay": ordinaryFrameBytes(baselineBody),
              "latestSnapshotByteCapacity": terms.latestSnapshot, "capacityPlusOneRefusedByInitializer": !CandidateProfile.accepts(onePastCapacity),
              "baselineFrameOverheadBytesMeasured": replyCap - build.latestSnapshotMaximumBytes,
              "capacityMarginOverPayloadBytes": terms.latestSnapshot - payload, "baselineFramesWithinReplyCap": baselineFits,
              "displayNotices": snapshot.displayNotices.count])
    out.check(payload > 0 && payload <= terms.latestSnapshot && baselineFits && !CandidateProfile.accepts(onePastCapacity),
              "snapshot.widestFitsCandidateAndCapacityIsTheInitializersLargest")

    // One encoded row of each kind, in each basis, through the actual projection.
    var connectionRow: [RowBasis: Int] = [:]
    for kind in ControlCollectionKind.allCases {
        for basis in RowBasis.allCases {
            let bytes = try measuredRowBytes(kind, basis)
            if kind == .activeConnections { connectionRow[basis] = bytes }
            out.emit(["record": "collection-row", "kind": kind.rawValue, "basis": basis.rawValue, "encodedRowBytes": bytes])
        }
    }

    // The initializer's encoded custody budget for the candidate's independent caps, against reserving a row count times the widest row.
    // Only the constructor runs for these: no row array of those sizes is built.
    let candidateOption = ("candidate-count-10000-capture-4MiB-retained-8MiB", terms.rows, terms.captureBytes, terms.retainedBytes, -1)
    var options = [candidateOption]
    for rows in [1_024, 4_096, 10_000] {
        let capture = rows * build.widestRowBytes
        options.append(("count-\(rows)-times-widest-row", rows, capture, CandidateProfile.collectionRowRevisionsPerKind * capture, build.widestRowBytes))
    }
    for basis in [RowBasis.realisticWide, .typical] {
        let rowBytes = connectionRow[basis] ?? -1
        let capture = terms.rows * rowBytes
        options.append(("count-10000-times-\(basis.rawValue)-connection-row", terms.rows, capture,
                        CandidateProfile.collectionRowRevisionsPerKind * capture, rowBytes))
    }
    var optionsBuilt = true
    for (label, rows, capture, retained, rowBytes) in options {
        var option = terms
        option.rows = rows
        option.captureBytes = capture
        option.retainedBytes = retained
        let budget = CandidateProfile.budget(option) ?? -1
        optionsBuilt = optionsBuilt && budget > 0 && capture > 0
        out.emit(["record": "collection-option", "option": label, "rows": rows, "rowBytesMultiplied": rowBytes,
                  "captureBytes": capture, "retainedBytes": retained, "constructorBudgetBytes": budget,
                  "candidateBudgetBytes": build.budget, "budgetDeltaFromCandidateBytes": budget - build.budget,
                  "kind": "encoded reservation from the initializer; nothing allocated; not RSS"])
    }
    out.check(optionsBuilt, "collections.everyOptionConstructs")

    // How many rows of each kind and shape the candidate's bounds actually admit, decided by the actual projection under its
    // `ControlRowBudget` (count first, then encoded bytes), never by dividing sizes. One kernel per kind and shape is built at the kind's
    // count limit, sharing its text bodies; smaller counts are prefixes of it. A count past the byte cap is refused whole, as the service
    // would answer `retention_budget_exceeded` with the exact total. Transient probe arrays only; no RAM bound is implied.
    var fitsMeasured = true
    for kind in ControlCollectionKind.allCases {
        let limit: Int = switch kind {
        case .activeConnections, .tunnelDNSHosts: terms.rows
        case .upstreamHealth: DomainResourceLimits.upstreams
        case .tunnelBindings: DomainResourceLimits.tunnelDefinitions
        }
        let limitBasis = switch kind {
        case .activeConnections: "product default active-connection limit"
        case .upstreamHealth: "configuration upstream ceiling"
        case .tunnelBindings: "configuration tunnel ceiling"
        case .tunnelDNSHosts: "candidate row bound; no host-count bound measured"
        }
        for basis in RowBasis.allCases {
            let pick = try basis == .widest ? widestPick(kind) : 0
            let full = try rowKernel(kind, basis, count: limit, pick: pick)
            func admitted(_ count: Int) -> Int? {
                projectedRowBytes(kind, prefixKernel(full, kind, count), maxRows: terms.rows, maxBytes: terms.captureBytes)
            }
            var fitting = limit
            if admitted(limit) == nil {
                var accepted = 0
                var refused = limit
                while refused - accepted > 1 {
                    let middle = accepted + (refused - accepted) / 2
                    if admitted(middle) != nil { accepted = middle } else { refused = middle }
                }
                fitting = accepted
            }
            var record: [String: Any] = ["record": "collection-fit", "kind": kind.rawValue, "basis": basis.rawValue, "countLimit": limit,
                                         "countLimitBasis": limitBasis, "rowCapacity": terms.rows, "captureBytes": terms.captureBytes,
                                         "largestAdmittedCount": fitting, "admittedBytesAtLargest": admitted(fitting) ?? -1,
                                         "countLimitAdmitted": fitting == limit, "method": "actual projection under ControlRowBudget"]
            if kind == .activeConnections {
                for count in [50, 1_001, 3_548] where count <= limit {
                    record["admitsCount\(count)"] = admitted(count) != nil
                }
            }
            fitsMeasured = fitsMeasured && fitting >= 1
            out.emit(record)
        }
    }
    out.check(fitsMeasured, "collections.atLeastOneRowOfEveryKindAndShapeFits")

    // 1,024 connection rows of each shape through the projection (count and bytes unbounded here, so every shape is packed), then
    // through the packer at the reply cap: pages per list and pages to read the first 50 rows the UI shows.
    var pagesBuilt = true
    let packedRows = 1_024
    for basis in RowBasis.allCases {
        let kernel = try rowKernel(.activeConnections, basis, count: packedRows)
        let answer = RuntimeSnapshotControlProjection.projectRows(.activeConnections, from: kernel,
                                                                 within: ControlRowBudget(maxRows: packedRows, maxBytes: Int.max))
        guard case .rows(.activeConnections(let rows), encodedBytes: let bytes) = answer else {
            pagesBuilt = false
            out.emit(["record": "collection-pages", "basis": basis.rawValue, "rows": packedRows, "projection": "refused"])
            continue
        }
        let packed = try packConnectionRows(rows, cap: replyCap)
        pagesBuilt = pagesBuilt && packed.packedRows == rows.count && packed.maxFrameBytes <= replyCap
        out.emit(["record": "collection-pages", "basis": basis.rawValue, "rows": rows.count, "projection": "rows",
                  "projectedEncodedBytes": bytes, "pages": packed.pages, "firstPageRows": packed.firstPageRows,
                  "pagesForFirst50Rows": packed.pagesForFirst50, "maxPageFrameBytes": packed.maxFrameBytes, "replyCap": replyCap])
    }
    out.check(pagesBuilt, "collections.candidateRowsPackIntoReplyCapPages")
    // One row past the bound: the projection refuses the whole list rather than cutting it.
    let over = RuntimeSnapshotControlProjection.projectRows(.activeConnections, from: try rowKernel(.activeConnections, .typical, count: terms.rows + 1),
                                                            within: ControlRowBudget(maxRows: terms.rows, maxBytes: terms.captureBytes))
    let overLabel: String = switch over {
    case .rows: "rows"
    case .overBudget: "overBudget"
    case .internalFailure: "internalFailure"
    }
    out.emit(["record": "collection-over-bound", "rows": terms.rows + 1, "rowBound": terms.rows, "projection": overLabel,
              "serviceAnswer": "unavailable retention_budget_exceeded with the exact total, read from RuntimeServiceCore; not exercised here"])
    out.check(overLabel == "overBudget", "collections.onePastTheBoundIsRefusedWhole")
}

// MARK: - Pressure at the candidate profile

/// The caller's own tally of one subscription: frames by kind, each re-encoded, the widest event record seen, and how it ended.
final class SubscriberTally: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCounts: [String: Int] = [:]
    private var widestFrames: [String: Int] = [:]
    private var events = 0
    private var widestEvent = 0
    private var eventEncodeFailures = 0
    /// Event records by family: typed lifecycle, typed configuration workflow, other typed families, untyped known, and unknown display.
    private var families: [String: Int] = [:]
    private var busyRetries = 0
    private var ending = "none"
    private var endedBeforeStopRequest = false
    private var stopRequested = false
    private var done = false

    func record(_ frame: ControlRuntimeFrame) {
        let bytes = ordinaryFrameBytes(.frame(frame))
        var sizes: [Int] = []
        var labels: [String] = []
        if case .events(let batch) = frame {
            sizes = batch.events.map { encodedSize($0) }
            labels = batch.events.map(Self.family)
        }
        let kind = frame.kind.rawValue
        lock.withLock {
            frameCounts[kind, default: 0] += 1
            widestFrames[kind] = max(widestFrames[kind] ?? 0, bytes)
            for size in sizes {
                if size < 0 { eventEncodeFailures += 1 } else { events += 1; widestEvent = max(widestEvent, size) }
            }
            for label in labels { families[label, default: 0] += 1 }
        }
    }

    /// The family of one record. Lifecycle and configuration-workflow records are the families a real Start, Stop or save emits.
    static func family(_ record: ControlRuntimeEventRecord) -> String {
        switch record {
        case .known(let event):
            guard let typed = event.typed else { return "untypedKnown" }
            if case .lifecycle = typed { return "typedLifecycle" }
            if case .configWorkflow = typed { return "typedConfigWorkflow" }
            return "typedOther"
        case .unknown:
            return "unknownDisplay"
        }
    }

    /// The first end only, and whether it came before the probe asked the pull to stop.
    func end(_ label: String) {
        lock.withLock {
            guard ending == "none" else { return }
            ending = label
            endedBeforeStopRequest = !stopRequested
        }
    }
    func busyRetry() { lock.withLock { busyRetries += 1 } }
    func requestStop() { lock.withLock { stopRequested = true } }
    func finish() { lock.withLock { done = true } }
    var shouldStop: Bool { lock.withLock { stopRequested } }
    var isDone: Bool { lock.withLock { done } }
    var sawBaseline: Bool { lock.withLock { (frameCounts["baseline"] ?? 0) > 0 } }
    var widestEventBytes: Int { lock.withLock { widestEvent } }
    var eventCount: Int { lock.withLock { events } }
    var familyCounts: [String: Int] { lock.withLock { families } }
    /// The stream ended by the host's shutdown, before the probe asked the pull to stop: a `host_shutdown` end frame, or the client's
    /// typed close for it.
    var endedByHostShutdownFirst: Bool {
        lock.withLock {
            endedBeforeStopRequest && (ending == "frame.end." + ControlStreamEndReason.hostShutdown.rawValue
                                       || ending == "client.streamClosed.\(ControlStreamEndReason.hostShutdown)")
        }
    }

    var summary: [String: Any] {
        lock.withLock {
            var record: [String: Any] = ["events": events, "widestEventRecordBytes": widestEvent, "eventEncodeFailures": eventEncodeFailures,
                                         "busyRetries": busyRetries, "ending": ending, "endedBeforeStopRequest": endedBeforeStopRequest,
                                         "done": done]
            for (family, count) in families { record["events_\(family)"] = count }
            for (kind, count) in frameCounts { record["frames_\(kind)"] = count }
            for (kind, bytes) in widestFrames { record["widestFrameBytes_\(kind)"] = bytes }
            return record
        }
    }
}

/// Pulls one subscription until it ends or the probe asks it to stop. Each wait is bounded, so the task always ends.
func pullSubscription(_ subscription: RuntimeSubscription, tally: SubscriberTally) async {
    pulling: while !tally.shouldStop {
        do {
            let frame = try await subscription.next(.after(.seconds(2), from: .now))
            tally.record(frame)
            if case .end(let end) = frame {
                tally.end("frame.end.\(end.reason.rawValue)")
                break pulling
            }
        } catch let error as RuntimeClientError {
            switch error {
            case .readAborted(.deadlineExpired), .notSent(.deadlineExpired):
                continue pulling
            case .readAborted(.transportBusy), .notSent(.transportBusy):
                // A pull whose earlier reservation has not quiesced yet consumed nothing; it is not terminal for a stream.
                tally.busyRetry()
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break pulling }
            default:
                tally.end(errorLabel(error))
                break pulling
            }
        } catch {
            tally.end(errorLabel(error))
            break pulling
        }
    }
    tally.finish()
}

final class LaneTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ lane: String, _ label: String) { lock.withLock { counts["\(lane):\(label)", default: 0] += 1 } }
    var all: [String: Int] { lock.withLock { counts } }
}

/// The safe facts of a configuration receipt, and its framed sizes.
func receiptFacts(_ outcome: ControlOperationOutcome?, module: ControlModule) -> [String: Any] {
    guard case .configurationSettled(let receipt)? = outcome else { return ["receipt": "absent"] }
    let settled = ControlOperationOutcome.configurationSettled(receipt)
    return ["receipt": "present", "runtimeWrite": writeLabel(receipt.runtime.write), "platformWrite": writeLabel(receipt.platform.write),
            "prior": receipt.prior == nil ? "absent" : "present",
            "priorRuntime": receipt.prior?.runtime == nil ? "absent" : "present",
            "priorPlatform": receipt.prior?.platform == nil ? "absent" : "present",
            "moduleResult": receipt.modules.first { $0.module == module }?.result.rawValue ?? "absent",
            "moduleReceipts": receipt.modules.count, "conditionalDNS": receipt.conditionalDNS.map { "\($0)" } ?? "absent",
            "appliedField": receipt.applied.map { $0 ? "true" : "false" } ?? "absent",
            "lookupReplyFrameBytes": ordinaryFrameBytes(.response(.lookup(.finished(settled)))),
            "operationFinishedFrameBytes": ordinaryFrameBytes(.frame(.operationFinished(
                ControlOperationFinished(operationID: ControlOperationID(rawValue: widestID), outcome: settled))))]
}

/// The reading of a preflight completion: observed or not, the verdict shown, and the busy-read flag.
func preflightFacts(_ outcome: ControlOperationOutcome?) -> (reading: String, helper: String, busy: Bool, frameBytes: Int) {
    guard let outcome, case .completed(let completion) = outcome, case .preflight(let observation) = completion.result else {
        return ("none", "none", false, -1)
    }
    let frame = ordinaryFrameBytes(.response(.lookup(.finished(outcome))))
    switch observation.reading {
    case .observed(let items): return ("observed", items.helper.rawValue, items.helperReadBusy, frame)
    case .unavailable(let reason): return ("unavailable.\(reason.rawValue)", "none", false, frame)
    }
}

@MainActor
func waitUntil(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
    return condition()
}

/// pressure-candidate: ONE bounded pressure run at the candidate profile, through the actual framed clients and the existing seams only.
/// The validator-widest configuration is Started by the saved-value Start; four subscribers fill the stream lane; one wide private update
/// holds the admitted input in its runtime-file replacement (`StateFileAccessing`); one preflight pass holds its read-only helper read
/// (the fake `HelperLifecycleManaging` seam); preflight joiners fill the ordinary pending capacity until the service refuses one; a
/// main-held window fills the ordinary and read lanes while a Stop is sent. Status and a proxy Stop are measured under every hold. The
/// holds are then released one at a time, quiescence is checked by fresh commands, the busy helper read and the login-item save are
/// exercised, and the host quits by the hand-composed Quit (not `RuntimeClientQuit`). Every subscriber must have received actual runtime
/// events, at least one of a typed lifecycle or configuration-workflow family, from those real actions (the probe injects none), and
/// must be ended by the host's shutdown before the probe asks it to stop. Each collection is also read once through `readPage`; the
/// service's over-bound answer is not reachable on these fixtures and is recorded as untested. These are fake holds: they show the service's
/// separation and bounds on this machine, not scheduler latency guarantees, real helper or OS latency, or a memory bound.
@MainActor
func runPressure(_ run: HostRun, build: CandidateBuild) async throws {
    let out = run.out
    let stages = run.stages
    let storeGate = run.fakes.files.replaceGate
    let helperGate = run.fakes.helper.gate
    // Never leave a gate held on an error path: the error handler's shutdown would wait on it.
    defer {
        storeGate.release()
        helperGate.release()
    }
    let port = try reserveLoopbackPort()
    let widest = makeValidatorWidestConfig(port: port)
    let prior = { var draft = widest; draft.logging.verbose = true; return draft }()
    let platform = makePlatform()
    out.emit(["record": "fixture", "fixture": "validator-widest", "validationProblems": widest.validate().count,
              "resourceViolation": widest.resourceViolation() == nil ? "none" : "violated", "tunnelCase": "hard-ceiling-128",
              "profile": CandidateProfile.label])
    out.check(widest.validate().isEmpty && widest.resourceViolation() == nil, "fixture.validatorAccepts")
    try run.acquire()
    try ProxyConfigPersistence.save(widest, in: run.environment)
    try PlatformConfigPersistence.save(platform, in: run.environment)
    try AppPreferencesPersistence.save(makeSmallPreferences(), in: run.environment)
    try await run.open()
    try run.compose(limits: build.limits)
    let (opened, _) = try await run.readSnapshot()
    run.incarnation = opened.stamp.incarnation
    guard let incarnation = run.incarnation, let modules = opened.stamp.modules else { throw ProbeError("noModuleRevisions") }
    let control = run.control
    let editor = run.editor
    stages.stage("pressure-host-opened", ["probeHeld": "fixture,prior-draft"])

    // The saved-value Start through the ordinary client (decision 0037): it carries no editor value and settles with its causal receipt.
    var start = ContinuousClock.now
    let startCommand = ControlRuntimeCommand.start(.proxy, ifModuleRevision: modules.proxy)
    let (startAdmission, startAdmissionMS) = try await run.submitControl(startCommand)
    let started = try await run.awaitOutcome(startAdmission, since: start)
    var startRecord = receiptFacts(started.outcome, module: .proxy)
    startRecord["record"] = "saved-start"
    startRecord["admission"] = admissionLabel(startAdmission)
    startRecord["admissionMS"] = startAdmissionMS
    startRecord["settledMS"] = started.ms
    startRecord["outcome"] = outcomeLabel(started.outcome)
    startRecord["requestFrameBytesAtClientWireCap"] = ordinaryFrameBytes(.request(ControlRuntimeRequest(
        budget: try ControlWireBudget(30_000),
        call: .submit(ControlOperationRequest(requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, command: startCommand))
    )))
    out.emit(startRecord)
    let applied = run.fakes.machine.service("Wi-Fi").webProxy
    out.check(outcomeLabel(started.outcome) == "configurationSettled" && startRecord["moduleResult"] as? String == "started"
              && startRecord["prior"] as? String == "present" && loopbackAccepts(port) && applied.enabled && applied.port == String(port),
              "pressure.savedStartSettledWithCausalReceipt")
    stages.stage("pressure-saved-start", ["probeHeld": "fixture,prior-draft"])

    // Four subscribers, each pulled by its own task: the subscriber limit and the stream lane at their capacity.
    var subscribers: [(subscription: RuntimeSubscription, tally: SubscriberTally, task: Task<Void, Never>)] = []
    for _ in 0..<CandidateProfile.subscriberLimit {
        let subscription = try await control.subscribe(.live, deadline: run.deadline(30))
        let tally = SubscriberTally()
        let first = try await subscription.next(run.deadline(30))
        tally.record(first)
        let task = Task.detached { await pullSubscription(subscription, tally: tally) }
        subscribers.append((subscription, tally, task))
    }
    out.check(subscribers.allSatisfy { $0.tally.sawBaseline }, "pressure.everySubscriberOpenedWithBaseline")
    var fifth = "none"
    do {
        let extra = try await control.subscribe(.live, deadline: run.deadline(5))
        do {
            let frame = try await extra.next(run.deadline(5))
            fifth = "frame." + frame.kind.rawValue
        } catch { fifth = errorLabel(error) }
        extra.cancel()
    } catch {
        fifth = errorLabel(error)
    }
    out.emit(["record": "fifth-subscriber", "result": fifth, "subscriberLimit": CandidateProfile.subscriberLimit])
    out.check(fifth != "frame.baseline", "pressure.subscriberLimitRefusesAFifth")

    // Each collection read through the actual `RuntimeClient.readPage` on this real host. Its lists stay far inside the candidate's
    // bounds, so this shows the actual answers only. The service's over-bound answer (`retention_budget_exceeded` with the exact
    // total) is NOT witnessed: these fixtures cannot exceed the row or byte bound without network dispatch or many sockets.
    var pagesAnswered = true
    var pageRecord: [String: Any] = ["record": "real-host-pages",
                                     "overBoundWitness": "untested; real-host fixtures cannot exceed the bounds without network dispatch or many sockets"]
    for collection in ControlCollectionKind.allCases {
        let key = collection.rawValue
        do {
            let reply = try await control.readPage(ControlPageRequest(expectedIncarnation: incarnation, collection: collection), deadline: run.deadline(10))
            switch reply {
            case .activeConnections(let page): pageRecord[key] = "page"; pageRecord[key + "Rows"] = page.rows.count; pageRecord[key + "Total"] = page.totalCount.rawValue
            case .upstreamHealth(let page): pageRecord[key] = "page"; pageRecord[key + "Rows"] = page.rows.count; pageRecord[key + "Total"] = page.totalCount.rawValue
            case .tunnelBindings(let page): pageRecord[key] = "page"; pageRecord[key + "Rows"] = page.rows.count; pageRecord[key + "Total"] = page.totalCount.rawValue
            case .tunnelDNSHosts(let page): pageRecord[key] = "page"; pageRecord[key + "Rows"] = page.rows.count; pageRecord[key + "Total"] = page.totalCount.rawValue
            case .unavailable(_, let reason, let knownTotal):
                pageRecord[key] = "unavailable." + reason.rawValue
                pageRecord[key + "Total"] = knownTotal?.rawValue ?? -1
            }
        } catch {
            pagesAnswered = false
            pageRecord[key] = errorLabel(error)
        }
    }
    out.emit(pageRecord)
    out.check(pagesAnswered, "pressure.realHostPagesAnsweredWithoutClientError")
    stages.stage("pressure-subscribers-open", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // The one admitted private input, held: a wide save-only update P waits in its runtime-file replacement.
    let priorID = ControlRequestID(rawValue: UUID())
    var priorTask: Task<String, Never>?
    storeGate.arm()
    do {
        let observed = try await run.read().0
        priorTask = Task.detached { () -> String in
            do {
                return admissionLabel(try await privateSubmit(
                    editor, incarnation: incarnation, config: prior, platform: platform, observed: observed, modules: allSaveOnly,
                    requestID: priorID, deadline: .after(.seconds(120), from: .now)
                ))
            } catch { return errorLabel(error) }
        }
    }
    let inputHeld = try await waitUntil(seconds: 10) { storeGate.isHolding }
    out.check(inputHeld, "pressure.privateInputHeldInStore")

    // The read-only helper work, held: the preflight pass's helper read, on its global queue.
    helperGate.arm()
    let (firstPreflight, _) = try await run.submitControl(.refreshPreflight(helperReplaced: true))
    var preflights: [ControlAdmission] = [firstPreflight]
    let helperHeld = try await waitUntil(seconds: 10) { helperGate.isHolding }
    out.check(helperHeld, "pressure.helperReadHeld")
    // Preflight joiners until the service refuses one: the ordinary pending capacity, visibly bounded.
    var pendingRefusal = "none"
    for _ in 0..<(2 * CandidateProfile.ordinaryPendingCapacity) {
        let (admission, _) = try await run.submitControl(.refreshPreflight(helperReplaced: false))
        if case .rejected = admission {
            pendingRefusal = admissionLabel(admission)
            break
        }
        preflights.append(admission)
    }
    let (credentialsWhileFull, _) = try await run.submitControl(.credentialsChanged)
    out.emit(["record": "pending-capacity", "preflightsAdmitted": preflights.count, "firstRefusal": pendingRefusal,
              "credentialsChangedWhileFull": admissionLabel(credentialsWhileFull),
              "ordinaryPendingCapacity": CandidateProfile.ordinaryPendingCapacity, "privateUpdateHeld": storeGate.isHolding,
              "helperReadHeld": helperGate.isHolding])
    out.check(pendingRefusal == "rejected.queue_full", "pressure.pendingCapacityRefusalVisible")
    stages.stage("pressure-all-held", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // Status and the private client while every hold is in place.
    try await run.statusSamples(20, condition: "pressure-all-held")
    var readDuringHold = "none"
    var updateDuringHold = "skipped-no-observation"
    do {
        let (observed, readMS) = try await run.read()
        readDuringHold = "observation"
        out.emit(["record": "pressure-read", "readMS": readMS])
        do {
            let admission = try await privateSubmit(editor, incarnation: incarnation, config: prior, platform: platform, observed: observed,
                                                    modules: allSaveOnly, deadline: .after(.seconds(5), from: .now))
            updateDuringHold = admissionLabel(admission)
        } catch { updateDuringHold = errorLabel(error) }
    } catch {
        readDuringHold = errorLabel(error)
    }
    out.emit(["record": "pressure-private", "readDuringHold": readDuringHold, "secondUpdateDuringHold": updateDuringHold])
    stages.stage("pressure-private-tried", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // The lane window: the main thread sleeps, so the owner cannot claim and each exchange keeps its lane reservation. Twice each lane's
    // capacity of reads and ordinary commands is sent, then one Stop. The Stop's own lane must not refuse it.
    let lanes = LaneTally()
    var burst: [Task<Void, Never>] = []
    for _ in 0..<(2 * CandidateProfile.laneCapacity) {
        burst.append(Task.detached {
            do {
                _ = try await control.readSnapshot(deadline: .after(.seconds(10), from: .now))
                lanes.add("read", "ok")
            } catch { lanes.add("read", errorLabel(error)) }
        })
        burst.append(Task.detached {
            do {
                lanes.add("ordinary", admissionLabel(try await control.submit(
                    .credentialsChanged, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                    deadline: .after(.seconds(10), from: .now)
                )))
            } catch { lanes.add("ordinary", errorLabel(error)) }
        })
    }
    let stopInWindow = Task.detached { () -> String in
        do {
            return admissionLabel(try await control.submit(.stop(.tunnels), requestID: ControlRequestID(rawValue: UUID()),
                                                           expectedIncarnation: incarnation, deadline: .after(.seconds(10), from: .now)))
        } catch { return errorLabel(error) }
    }
    usleep(100_000)
    for task in burst { await task.value }
    let stopLabel = await stopInWindow.value
    let counts = lanes.all
    var laneRecord: [String: Any] = ["record": "lane-window", "method": "main thread slept 100 ms; owner could not claim",
                                     "laneCapacityEach": CandidateProfile.laneCapacity, "requestsPerLane": 2 * CandidateProfile.laneCapacity,
                                     "stopInWindow": stopLabel,
                                     "readLaneFillObserved": counts["read:client.notSent.transportBusy", default: 0] > 0,
                                     "ordinaryLaneFillObserved": counts["ordinary:client.notSent.transportBusy", default: 0] > 0]
    for (key, count) in counts { laneRecord["count " + key] = count }
    out.emit(laneRecord)
    out.check(stopLabel == "accepted" || stopLabel == "joined", "pressure.stopNotRefusedWhileOrdinaryAndReadLanesFull")
    stages.stage("pressure-lane-window", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // A proxy Stop while the private input, the helper read, the pending capacity and the stream lane are all held.
    start = ContinuousClock.now
    let (stopAdmission, stopAdmissionMS) = try await run.submitControl(.stop(.proxy))
    let stopped = try await run.awaitOutcome(stopAdmission, since: start, timeout: 10)
    let listenerClosed = !loopbackAccepts(port)
    let cleared = !run.fakes.machine.service("Wi-Fi").webProxy.enabled
    let (afterStop, _) = try await run.readSnapshot()
    out.emit(["record": "stop-latency", "condition": "pressure-all-held", "module": "proxy", "admission": admissionLabel(stopAdmission),
              "admissionMS": stopAdmissionMS, "completionMS": stopped.ms, "lookups": stopped.lookups, "outcome": outcomeLabel(stopped.outcome),
              "listenerClosed": listenerClosed, "systemProxyCleared": cleared, "snapshotStopped": afterStop.proxyState != .running,
              "storeStillHeld": storeGate.isHolding, "helperStillHeld": helperGate.isHolding])
    out.check(outcomeLabel(stopped.outcome) == "completed.stop" && listenerClosed && cleared && afterStop.proxyState != .running
              && storeGate.isHolding && helperGate.isHolding, "pressure.proxyStopCompletedWhileEveryHoldStood")
    stages.stage("pressure-stop-done", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // Causal release, one hold at a time: the helper read first, then the private input.
    let helperRelease = ContinuousClock.now
    helperGate.release()
    var preflightOutcomes: [String: Int] = [:]
    for admission in preflights {
        let outcome = try await pollOutcome(control, incarnation: incarnation, admission: admission)
        preflightOutcomes[outcomeLabel(outcome), default: 0] += 1
    }
    var preflightRecord: [String: Any] = ["record": "preflight-release", "releaseToAllSettledMS": elapsedMS(since: helperRelease),
                                          "admitted": preflights.count]
    for (label, count) in preflightOutcomes { preflightRecord["outcome " + label] = count }
    out.emit(preflightRecord)
    out.check(preflightOutcomes["none"] == nil, "pressure.everyPreflightSettledAfterHelperRelease")

    let storeRelease = ContinuousClock.now
    storeGate.release()
    let priorAdmission = await priorTask?.value ?? "none"
    priorTask = nil
    var priorOutcome: ControlOperationOutcome?
    let priorLookup = try await control.lookupAdmission(of: priorID, expectedIncarnation: incarnation, deadline: run.deadline())
    if case .admission(let admission) = priorLookup {
        priorOutcome = try await pollOutcome(control, incarnation: incarnation, admission: admission)
    }
    var priorPersisted = false
    if case .configurationSettled(let receipt)? = priorOutcome { priorPersisted = receipt.runtime.write == .persisted(reportedError: false) }
    out.emit(["record": "prior-release", "admission": priorAdmission, "outcome": outcomeLabel(priorOutcome), "persisted": priorPersisted,
              "releaseToSettledMS": elapsedMS(since: storeRelease)])
    out.check(priorPersisted, "pressure.priorPersistedAfterStoreRelease")
    stages.stage("pressure-released", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    // Quiescence: the pending capacity is free again, so a fresh ordinary command is admitted and settles.
    start = ContinuousClock.now
    let (fresh, _) = try await run.submitControl(.credentialsChanged)
    let freshDone = try await run.awaitOutcome(fresh, since: start)
    out.emit(["record": "pressure-quiescence", "admission": admissionLabel(fresh), "outcome": outcomeLabel(freshDone.outcome),
              "settledMS": freshDone.ms])
    out.check(outcomeLabel(freshDone.outcome) == "completed." + ControlRuntimeCommandKind.credentialsChanged.rawValue,
              "pressure.pendingCapacityFreeAfterRelease")

    // The bounded busy indicator: a busy helper read keeps the held verdict on display and says it was busy.
    run.fakes.helper.base.status = .busy
    start = ContinuousClock.now
    let (busyPreflight, _) = try await run.submitControl(.refreshPreflight(helperReplaced: false))
    let busyDone = try await run.awaitOutcome(busyPreflight, since: start)
    run.fakes.helper.base.status = .installed
    let busy = preflightFacts(busyDone.outcome)
    out.emit(["record": "preflight-busy-read", "outcome": outcomeLabel(busyDone.outcome), "reading": busy.reading, "helperShown": busy.helper,
              "helperReadBusy": busy.busy, "lookupReplyFrameBytes": busy.frameBytes, "settledMS": busyDone.ms])
    out.check(busy.reading == "observed" && busy.busy, "pressure.busyHelperReadIndicated")

    // The login-item administration's platform save, under the exact platform baseline the client observed.
    var launchOutcome = "none"
    do {
        let observed = try await run.read().0
        guard let platformBaseline = observed.components.platform.baseline else { throw ProbeError("noPlatformBaseline") }
        start = ContinuousClock.now
        let (launch, _) = try await run.submitControl(.setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline))
        let launchDone = try await run.awaitOutcome(launch, since: start)
        launchOutcome = outcomeLabel(launchDone.outcome)
        var write = "none"
        if case .completed(let completion)? = launchDone.outcome, case .platformWrite(let platformWrite) = completion.result {
            write = writeLabel(platformWrite.write)
        }
        out.emit(["record": "launch-at-login", "outcome": launchOutcome, "platformWrite": write, "settledMS": launchDone.ms,
                  "loginItemEffect": "none; the host ignores the flag (RuntimeHost reconcile)"])
    }
    out.check(launchOutcome == "completed." + ControlRuntimeCommandKind.setLaunchAtLogin.rawValue, "pressure.launchAtLoginSaved")
    stages.stage("pressure-quiesced", ["probeHeld": "fixture,prior-draft,subscriber-tallies"])

    out.emit(["record": "quit-path", "quitPath": "manual-composition-not-RuntimeClientQuit"])
    try await run.plainQuit()
    // The host's shutdown must end every stream on its own: the probe waits for that first, and only then asks any pull still
    // running to stop, so a stream the probe stopped never counts as ended by the host.
    let quitEnd = ContinuousClock.now
    let endedByHost = try await waitUntil(seconds: 10) { subscribers.allSatisfy { $0.tally.isDone } }
    let hostEndWaitMS = elapsedMS(since: quitEnd)
    for subscriber in subscribers { subscriber.tally.requestStop() }
    _ = try await waitUntil(seconds: 10) { subscribers.allSatisfy { $0.tally.isDone } }
    for subscriber in subscribers { subscriber.subscription.cancel() }
    for subscriber in subscribers { await subscriber.task.value }
    var widestEvent = 0
    var totalEvents = 0
    var familyTotals: [String: Int] = [:]
    for (index, subscriber) in subscribers.enumerated() {
        var record = subscriber.tally.summary
        record["record"] = "subscriber"
        record["index"] = index
        record["endedByHostShutdownBeforeProbeStop"] = subscriber.tally.endedByHostShutdownFirst
        out.emit(record)
        widestEvent = max(widestEvent, subscriber.tally.widestEventBytes)
        totalEvents += subscriber.tally.eventCount
        for (family, count) in subscriber.tally.familyCounts { familyTotals[family, default: 0] += count }
    }
    var eventRecord: [String: Any] = ["record": "observed-events", "widestEventRecordBytesObserved": widestEvent, "eventsAcrossSubscribers": totalEvents,
                                      "candidateMaxEventBytes": CandidateProfile.maxEventBytes, "label": "events this run produced; not a catalogue sweep",
                                      "allEndedWithinHostWait": endedByHost, "hostEndWaitMS": hostEndWaitMS]
    for (family, count) in familyTotals { eventRecord["events_\(family)"] = count }
    out.emit(eventRecord)
    out.check(subscribers.allSatisfy { $0.tally.isDone }, "pressure.everySubscriberEnded")
    // Each subscriber was open across the proxy Stop, the preflights, the private saves, the login-item save and the Quit, all real
    // actions through the clients; none of its events was injected by the probe.
    out.check(subscribers.allSatisfy { $0.tally.eventCount > 0 }, "pressure.everySubscriberReceivedRuntimeEvents")
    out.check(subscribers.allSatisfy {
        let families = $0.tally.familyCounts
        return families["typedLifecycle", default: 0] + families["typedConfigWorkflow", default: 0] > 0
    }, "pressure.everySubscriberReceivedATypedLifecycleOrConfigEvent")
    out.check(subscribers.allSatisfy { $0.tally.endedByHostShutdownFirst }, "pressure.everySubscriberEndedByHostShutdownBeforeProbeStop")
    subscribers = []
    stages.stage("pressure-subscribers-ended", ["probeHeld": "fixture,prior-draft"])
    out.emit(["record": "fakes", "pacFetches": run.fakes.pac.fetchCount, "gssCalls": run.fakes.gss.calls,
              "privilegedCommands": run.fakes.machine.privilege.commands.count, "helperStatusReads": run.fakes.helper.base.statusReads])
    out.check(run.fakes.pac.fetchCount == 0 && run.fakes.gss.calls == 0, "fakes.noPACOrGSS")
}

let latencyModes = ["contention", "contention-encode", "contention-store", "held", "cancel", "client-quit-widest", "codec-bounds",
                    "profile-sizing", "pressure-candidate"]

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
                  "statusSampleIntervalMS": 2, "clientAndHostShareOneProcess": true, "profile": CandidateProfile.label])
        guard let build = emitProfile(out) else {
            finish(out, released: false)
        }
        let limits = build.limits
        let scratch = URL(fileURLWithPath: arguments[2], isDirectory: true)
        if mode == "codec-bounds" || mode == "profile-sizing" {
            do {
                if mode == "codec-bounds" {
                    try runCodecBounds(out, build: build)
                } else {
                    try runProfileSizing(out, build: build)
                }
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
                } else if mode == "client-quit-widest" {
                    try await runClientQuit(run, limits: limits)
                } else if mode == "pressure-candidate" {
                    try await runPressure(run, build: build)
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
