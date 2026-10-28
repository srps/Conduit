// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
import ProxyAuth
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import RuntimeEvents

/// The process start the harnesses report. Fixed, so no test reads the clock.
private let testStartedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A host test never ends the process. A terminal stop that reaches this hook is a failure.
private let unexpectedTerminalExit: @MainActor () -> Void = { XCTFail("the runtime host ended the process") }

/// A test asked a harness for a second host while it still owns the first. The request fails before anything is built.
private enum HarnessHostOwnershipError: Error {
    case secondHost
    /// A harness whose shutdown could not be confirmed is still held in the retention slot, so no new one is built.
    case retainedUnconfirmed
    /// The loopback socket the test holds open could not be created or bound.
    case heldPortUnavailable
}

/// A synthetic satisfied path, the report `FakeNetworkPathObserver` delivers in place of `NWPathMonitor`.
private func satisfiedPath() -> NetworkPathState {
    NetworkPathState(
        status: .satisfied, interfaces: [], gateways: [],
        supportsIPv4: true, supportsIPv6: false, supportsDNS: true,
        isExpensive: false, isConstrained: false
    )
}

/// A resolver directory the test owns, created empty, so a host never scans the machine's `/etc/resolver`.
private func scratchResolverDirectory(_ environment: RuntimeEnvironment) throws -> String {
    let url = environment.configDirectory.appendingPathComponent("resolver", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// The token provider a host test injects for `.injected`: a Kerberos handshake fails here, and the system GSS stack is never reached.
private final class UnscriptedGSSProvider: GSSTokenProvider, @unchecked Sendable {
    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        throw UnplannedFakeEffect(effect: "GSS token for \(host)")
    }

    func resetContext() {}
}

/// Every machine effect a host test runs against (decision 0033). There is one construction path: `makeHostEffects` names
/// every adapter, with no default. The Kerberos and port-probe fakes are fixed inside it, since no test varies them yet. A test that does
/// not fire wake gets a fresh wake fake nobody fires.
private func makeHostEffects(
    loopbackPortProbe: FakeLoopbackPortProbe,
    privilege: @escaping RuntimePrivilegeAdaptersFactory,
    credentials: any SecretStore,
    gss: RuntimeGSSSource,
    pacEvaluator: any PacEvaluator,
    commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult,
    networkPath: any NetworkPathObserving,
    networkLocation: any NetworkLocationObserving,
    networkLocationStoreFactory: @escaping @Sendable (any PrivilegeClient) -> (any NetworkLocationStoring)?,
    vpnStatusMonitor: @escaping RuntimeVPNStatusMonitorFactory,
    dnsResponds: @escaping @Sendable (Int) -> Bool,
    homeDirectory: URL,
    resolverDirectory: String,
    stateFiles: any StateFileAccessing = StateFileAccess.operatingSystem(),
    wake: any SystemWakeObserving = FakeSystemWakeObserver()
) -> RuntimeHostEffects {
    RuntimeHostEffects(
        privilege: privilege,
        credentials: credentials,
        kerberosTicketRecovery: FakeKerberosTicketRecovery(),
        gss: gss,
        pacEvaluator: pacEvaluator,
        portHolderProbe: FakeListenerPortHolderProbe(),
        loopbackPortProbe: loopbackPortProbe.isServed(port:),
        commandRunner: commandRunner,
        dnsResponds: dnsResponds,
        networkPath: networkPath,
        networkLocation: networkLocation,
        networkLocationStoreFactory: networkLocationStoreFactory,
        vpnStatusMonitor: vpnStatusMonitor,
        wake: wake,
        homeDirectory: homeDirectory,
        resolverDirectory: resolverDirectory,
        stateFiles: stateFiles
    )
}

/// The operating system's state-file access, with one configuration read that parks its worker until the test releases it. Unarmed, it
/// passes every call through, so a test can keep the store's one slot busy at a chosen point.
private final class ParkingStateFiles: StateFileAccessing, @unchecked Sendable {
    private let inner = StateFileAccess.operatingSystem()
    private let condition = NSCondition()
    private var armed = false
    private var parked = false
    private var released = false

    func armRead() {
        condition.withLock {
            armed = true
            parked = false
            released = false
        }
    }

    /// Waits, bounded, until a read is parked.
    func waitUntilParked() async -> Bool {
        for _ in 0..<2_000 {
            if condition.withLock({ parked }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        condition.withLock {
            guard armed else { return }
            armed = false
            parked = true
            condition.broadcast()
            while !released { condition.wait() }
            parked = false
        }
        return inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}

/// The machine effects of a test that does not vary the GSS, PAC or VPN seams: each of those fails or records, and
/// never reaches the system GSS stack, the network or a real VPN observer.
private func hostEffects(
    loopbackPortProbe: FakeLoopbackPortProbe,
    pacEvaluator: any PacEvaluator,
    privilege: @escaping RuntimePrivilegeAdaptersFactory,
    credentials: any SecretStore,
    commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult,
    networkPath: any NetworkPathObserving,
    networkLocation: any NetworkLocationObserving,
    networkLocationStoreFactory: @escaping @Sendable (any PrivilegeClient) -> (any NetworkLocationStoring)?,
    vpnStatus: any VPNStatusObserving,
    dnsResponds: @escaping @Sendable (Int) -> Bool,
    homeDirectory: URL,
    resolverDirectory: String,
    stateFiles: any StateFileAccessing = StateFileAccess.operatingSystem(),
    wake: any SystemWakeObserving = FakeSystemWakeObserver()
) -> RuntimeHostEffects {
    makeHostEffects(
        loopbackPortProbe: loopbackPortProbe,
        privilege: privilege,
        credentials: credentials,
        gss: .injected { UnscriptedGSSProvider() },
        pacEvaluator: pacEvaluator,
        commandRunner: commandRunner,
        networkPath: networkPath,
        networkLocation: networkLocation,
        networkLocationStoreFactory: networkLocationStoreFactory,
        vpnStatusMonitor: { _, _ in vpnStatus },
        dnsResponds: dnsResponds,
        homeDirectory: homeDirectory,
        resolverDirectory: resolverDirectory,
        stateFiles: stateFiles,
        wake: wake
    )
}

/// A saved-password store whose read waits until `open()`, so a credential warm-up stays in flight for as long as a test
/// needs. Reads are counted, so a test sees that the warm-up made its read.
private final class GatedSecretStore: SecretStore, @unchecked Sendable {
    /// The read a gated store refuses once it opens, as a store with an unavailable entry would.
    struct RefusedRead: Error {}

    private let base = InMemorySecretStore()
    private let condition = NSCondition()
    private var isOpen = false
    private var refusesReads = false
    private var reads = 0

    /// Saved-password reads started so far, including the ones still waiting.
    var loadCount: Int { condition.withLock { reads } }

    /// Lets every read, waiting or future, through, or refuses them when `refusing` is true.
    func open(refusing: Bool = false) {
        condition.withLock {
            isOpen = true
            refusesReads = refusing
            condition.broadcast()
        }
    }

    func save(secret: SecretBytes, account: String) throws {
        try base.save(secret: secret, account: account)
    }

    func load(account: String) throws -> SecretBytes? {
        let refused = condition.withLock { () -> Bool in
            reads += 1
            while !isOpen { condition.wait() }
            return refusesReads
        }
        if refused { throw RefusedRead() }
        return try base.load(account: account)
    }

    func exists(account: String) throws -> Bool {
        try base.exists(account: account)
    }

    func delete(account: String) throws {
        try base.delete(account: account)
    }
}

/// A configuration with a fixed saved-password identity, so a warm-up test names the account its read uses.
private func identityConfig(profileName: String) -> ProxyConfig {
    var config = GenericDefaults.shared.makeConfig()
    config.domain = "DOMAIN"
    config.username = "user"
    config.profileName = profileName
    return config
}

/// Counts the events a warm-up sink receives, so a test sees which request's sink ran.
private final class CountingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0

    var count: Int { lock.withLock { received } }

    func record(_ event: RuntimeEvent) {
        lock.withLock { received += 1 }
    }
}

/// Emits one structured event per command through the sink its host gave the privilege factory, then forwards the
/// command to a recording client, so no command reaches the machine.
private final class EmittingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let base = RecordingPrivilegeClient()
    private let emit: @Sendable (RuntimeEvent) -> Void

    init(emit: @escaping @Sendable (RuntimeEvent) -> Void) {
        self.emit = emit
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        emit(RuntimeEvent(kind: .config, event: "platform.settings_observed", detail: "witness=command"))
        try base.execute(operation, values: values)
    }
}

/// Whether the root's lease can be taken now. A success gives the lease back at once, so the probe holds nothing.
private func leaseIsFree(_ environment: RuntimeEnvironment) -> Bool {
    let outcome = StateRootBootstrap.acquire(
        environment,
        createRootIfMissing: true,
        fileSystem: OSStateRootFileSystem(),
        leasing: OSStateWriterLeasing(),
        onReleaseFailure: { failure in XCTFail("a probe lease could not be closed: errno \(failure.errno)") }
    )
    if case .success = outcome { return true }
    return false
}

private enum GatedSettleFixtureError: Error {
    case retainedSlotOccupied
}

/// The fixture of the gated settle tests, and their one teardown path. The teardown opens the gate, joins the settle the
/// test started, stops the host, and settles it with a bounded wait. The final diagnostic flush must be confirmed. Only
/// then does the owner drop the host and session, and a fresh acquisition prove the lease free, before the directory goes.
/// Otherwise the fixture is kept in one retention slot, with its host and root. Nothing in the teardown waits unbounded.
@MainActor
private final class GatedSettleFixture {
    /// The fixture an unconfirmed teardown kept. One slot: no new gated fixture is built while it is occupied.
    private static var retained: GatedSettleFixture?

    let store = GatedSecretStore()
    let directory: URL
    let environment: RuntimeEnvironment
    private var session: StateRootSession?
    var host: RuntimeHost?
    /// The one settle the test started, which the teardown awaits before it stops anything. A host admits one settle join
    /// at a time, so one slot matches it.
    private var settle: Task<StoppedEffectsSettlement, Never>?

    init() throws {
        guard Self.retained == nil else { throw GatedSettleFixtureError.retainedSlotOccupied }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-gated-settle-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        do {
            session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        } catch {
            // Taking the root failed, so nothing is held. Only the directory this fixture named can remain.
            removeScratch([directory])
            throw error
        }
        environment = session!.environment
    }

    /// Builds the host over the fixture's root. It runs once, before the test's first step.
    func start(_ build: (StateRootSession, GatedSecretStore) async throws -> RuntimeHost) async throws {
        host = try await build(session!, store)
    }

    /// Records the test's one settle, so the teardown joins it. A second call is a test bug and traps.
    @discardableResult
    func track(_ task: Task<StoppedEffectsSettlement, Never>) -> Task<StoppedEffectsSettlement, Never> {
        precondition(settle == nil, "a gated settle fixture tracks one settle")
        settle = task
        return task
    }

    /// The one teardown. See the type's comment for the order and the retention rule.
    func teardown() async {
        store.open()
        if let settle {
            _ = await settle.value
        }
        settle = nil
        var confirmed = true
        // Which step left the shutdown unconfirmed, for the retention failure: the settle's last outcome and attempt count, then the
        // flush's per-writer results. Numeric and enum values only.
        var why = ""
        if let host {
            await host.stopRuntime()
            var outcome = StoppedEffectsSettlement.busy
            var attempts = 0
            while outcome == .busy, attempts < 200 {
                attempts += 1
                outcome = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(1)))
                if outcome == .busy {
                    do {
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        break
                    }
                }
            }
            confirmed = outcome == .settled
            why = "settle \(outcome) after \(attempts) attempt(s), joins pending \(host.stoppedEffectsJoinCount), "
                + "admissions pending \(host.pendingAdmissions), lanes idle \(host.lanesIdle), workflow idle \(host.workflow.isIdle)"
            if confirmed {
                let report = await host.flushEvents()
                confirmed = report.allConfirmed
                why += "; flush audit \(report.audit), events \(report.events), eventsRetry \(String(describing: report.eventsRetry)), "
                    + "snapshot \(report.snapshot), snapshotEvent \(report.snapshotEvent)"
            }
        }
        guard confirmed else {
            Self.retain(self, why: "the shutdown is not confirmed (\(why))")
            return
        }
        host = nil
        session = nil
        var free = false
        var attempts = 0
        while !free, attempts < 200 {
            attempts += 1
            free = leaseIsFree(environment)
            if !free {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    break
                }
            }
        }
        guard free else {
            Self.retain(self, why: "the root's lease did not close")
            return
        }
        removeScratch([directory])
    }

    private static func retain(_ fixture: GatedSettleFixture, why: String) {
        XCTFail("gated settle fixture kept because \(why): its host and root stay claimed")
        if retained == nil {
            retained = fixture
        }
    }
}

/// Runs one gated settle test over its fixture. The teardown runs on every path: after the body returns, and after a
/// thrown error from the body or from the host's construction.
@MainActor
private func withGatedSettleFixture(
    build: (StateRootSession, GatedSecretStore) async throws -> RuntimeHost,
    _ body: (GatedSettleFixture) async throws -> Void
) async throws {
    let fixture = try GatedSettleFixture()
    do {
        try await fixture.start(build)
        try await body(fixture)
    } catch {
        await fixture.teardown()
        throw error
    }
    await fixture.teardown()
}

/// The SplitMix64 step of `LifecycleLaneModelTests`, kept private here because that file's type of the same name is
/// private too, so the two cannot share one declaration.
private struct WarmupBatchGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// A bounded model of the credential warm-up producer's coalescing, run over the real `CredentialManager` and the gated
/// store fixture. Only one state is explored: a first physical read held open, a batch of requests sent meanwhile, then
/// the release. The alphabet is three request choices, one per counting sink. The oracle is computed from the batch
/// alone and never calls the producer. The model does not explore thread interleavings; the actual-host scenario covers
/// the production effects around it.
final class DaemonRuntimeHostWarmupModelTests: XCTestCase {
    private enum Choice: CaseIterable, Hashable {
        case a, b, c
    }

    /// Every batch of length 0 through 3: 1 + 3 + 9 + 27 = 40 traces.
    private func exhaustiveBatches() -> [[Choice]] {
        var batches: [[Choice]] = []
        for length in 0...3 {
            var prefixes: [[Choice]] = [[]]
            for _ in 0..<length {
                prefixes = prefixes.flatMap { prefix in Choice.allCases.map { prefix + [$0] } }
            }
            batches += prefixes
        }
        return batches
    }

    /// Sixteen batches of eight requests, drawn from the same alphabet with a fixed seed.
    private func seededBatches() -> [[Choice]] {
        var generator = WarmupBatchGenerator(seed: 0x0033_5EED)
        return (0..<16).map { _ in (0..<8).map { _ in Choice.allCases.randomElement(using: &generator)! } }
    }

    private func describe(_ batch: [Choice]) -> String {
        batch.isEmpty ? "(empty)" : batch.map { "\($0)".uppercased() }.joined(separator: " ")
    }

    /// One trace. The first physical read is held, the batch is sent, the read is released, and the handle returned
    /// first is awaited alone. Its answer must already cover the pending request.
    private func runTrace(_ batch: [Choice], label: String) async throws {
        let store = GatedSecretStore()
        // Opened on every exit, so a cancelled wait cannot leave the warm-up's read thread blocked on the gate.
        defer { store.open(refusing: true) }
        let config = identityConfig(profileName: "Model")
        let manager = CredentialManager(
            identityProvider: { (domain: config.domain, username: config.username, profileName: config.profileName) },
            store: store
        )
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        let sinks: [Choice: CountingSink] = [.a: CountingSink(), .b: CountingSink(), .c: CountingSink()]

        // Oracle, from the batch alone: the active request's sink runs once, and the latest pending request's sink runs
        // once if there is one. A reading is one physical read, plus one more if a request waits behind it.
        var expected: [Choice: Int] = [.a: 1, .b: 0, .c: 0]
        if let latest = batch.last { expected[latest, default: 0] += 1 }
        let expectedReads = batch.isEmpty ? 1 : 2

        let active = manager.warmCacheInBackground(eventSink: sinks[.a]!.record)
        var attempts = 0
        while store.loadCount < 1, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        var handles = [active]
        for request in batch {
            handles.append(manager.warmCacheInBackground(eventSink: sinks[request]!.record))
        }
        if store.loadCount != 1 {
            XCTFail("\(label): \(store.loadCount) physical reads while the first read is blocked, expected 1")
        }

        store.open(refusing: true)
        await active.value
        let actual = Dictionary(uniqueKeysWithValues: Choice.allCases.map { ($0, sinks[$0]!.count) })
        if actual != expected {
            XCTFail("\(label): sinks ran \(actual.sorted { "\($0.key)" < "\($1.key)" }), expected \(expected.sorted { "\($0.key)" < "\($1.key)" })")
        }
        if store.loadCount != expectedReads {
            XCTFail("\(label): \(store.loadCount) physical reads after release, expected \(expectedReads)")
        }
        for handle in handles {
            await handle.value
        }
    }

    func testWarmupCoalescingModelOverFiftySixBoundedTraces() async throws {
        let exhaustive = exhaustiveBatches()
        let seeded = seededBatches()
        XCTAssertEqual(exhaustive.count, 40)
        XCTAssertEqual(seeded.count, 16)
        for (index, batch) in exhaustive.enumerated() {
            try await runTrace(batch, label: "exhaustive \(index) [\(describe(batch))]")
        }
        for (index, batch) in seeded.enumerated() {
            try await runTrace(batch, label: "seeded \(index) [\(describe(batch))]")
        }
        print("warmup coalescing model: traces=\(exhaustive.count + seeded.count) exhaustive=\(exhaustive.count) seeded=\(seeded.count)")
    }
}

/// Holds the adapter a privilege factory built, so a test can drive it after the host exists.
private final class PrivilegeAdapterBox: @unchecked Sendable {
    var client: EmittingPrivilegeClient?
}

/// Records what the host's flap-window readers return, so a test sees the values the monitor reads after a reload.
private final class FlapWindowRecorder: @unchecked Sendable {
    var grace: (@Sendable () -> TimeInterval)?
    var minVisible: (@Sendable () -> TimeInterval)?
}

/// A token provider that returns one fixed token and records the hosts it was asked for.
private final class FixedGSSProvider: GSSTokenProvider, @unchecked Sendable {
    static let token = Data([0x60, 0x03, 0x06, 0x01])
    private let lock = NSLock()
    private var hosts: [String] = []

    var requestedHosts: [String] { lock.withLock { hosts } }

    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        lock.withLock { hosts.append(host) }
        return Self.token
    }

    func resetContext() {}
}

/// A PAC evaluator whose fetch returns a fixed script and records each URL it was asked for. The URL is a scratch
/// file, so a wrong wiring that reached the system's fetcher would still read only the test's own file.
private final class RecordingPACEvaluator: PacEvaluator, @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [String] = []

    var fetchedURLs: [String] { lock.withLock { fetched } }

    func fetchPAC(from urlString: String) async throws -> String {
        lock.withLock { fetched.append(urlString) }
        return "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        FixedPACRoute()
    }

    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { _ in nil }
    }
}

private struct FixedPACRoute: PacScriptEvaluating {
    func resolveProxyChain(for url: URL) throws -> [String] {
        ["DIRECT"]
    }
}

@MainActor
final class DaemonRuntimeHostTests: XCTestCase {
    /// The runner for a host whose test does not script any command. It
    /// fails every one: a host left on the default ran the real `launchctl`
    /// and `networksetup` and edited the real home's shell profiles, and a
    /// failed start's revert cleared the developer's own environment block.
    private static let offMachine: @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
        throw UnscriptedCommand(launchPath: launchPath, arguments: arguments)
    }

    private struct UnscriptedCommand: Error {
        let launchPath: String
        let arguments: [String]
    }


    /// The daemon's credentials come from the injected store, not the login
    /// Keychain. Without the seam a host over a fake machine read and wrote
    /// the installed app's Keychain entries, the gap #24's review closed in
    /// `AppState`.
    // MARK: - Stopped-effects settle (decision 0033)

    /// A host over a scratch root whose saved-password read waits on `store`, so the credential warm-up its start makes
    /// stays in flight until the test opens the store. Its machine is the fake, and its listeners are ephemeral.
    private func gatedHost(_ session: StateRootSession, store: GatedSecretStore) async throws -> RuntimeHost {
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        try ProxyConfigPersistence.save(config, in: environment)
        // A reload applies only verified inputs (decision 0032), so the platform sidecar a real install carries is written too.
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)
        let saved = config
        try CredentialManager(
            identityProvider: { (domain: saved.domain, username: saved.username, profileName: saved.profileName) },
            store: store
        ).saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: saved)
        let machine = FakeMachine(resolverDirectory: environment.configDirectory.appendingPathComponent("resolver", isDirectory: true))
        return try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: store,
                gss: .injected { UnscriptedGSSProvider() },
                pacEvaluator: FakePacEvaluator(),
                commandRunner: { path, arguments in try machine.run(path, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: machine.resolverDirectory.path
            )
        )
    }

    /// A stopped host's warm-up and deliveries join before its flush. Only `.settled` lets a test go on to the flush.
    private func quiesce(_ host: RuntimeHost) async {
        let outcome = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(outcome, .settled)
        await host.flushEvents()
    }

    /// A deadline that passes first returns `.deadlineExpired`, and that is not quiescence. The owner keeps the host and
    /// the root through its own settle and its final flush, and drops them only after both. A timed-out wait is not an
    /// owner release, so the root is removed only when a fresh acquisition proves the lease free.
    func testASettleDeadlineIsNotQuiescenceAndTheOwnerKeepsTheRootThroughItsFinalFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-settle-deadline-\(UUID().uuidString)", isDirectory: true)
        var removable = false
        defer { if removable { removeScratch([directory]) } }
        var session: StateRootSession? = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        let environment = session!.environment
        let store = GatedSecretStore()
        // Opened on every path, so no gated read outlives the test. Opening only lets the warm-up finish; it releases nothing.
        defer { store.open() }
        var host: RuntimeHost? = try await gatedHost(session!, store: store)
        session = nil
        try await host!.startRuntime()
        await host!.stopRuntime()

        let timedOut = await host!.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .milliseconds(200)))
        XCTAssertEqual(timedOut, .deadlineExpired)
        XCTAssertFalse(leaseIsFree(environment), "the owner's host still holds the root while the warm-up is gated")

        store.open()
        // Bounded: the join frees its slot when the warm-up ends, so a settle is busy until then. 200 tries, 10 ms apart.
        var settled = StoppedEffectsSettlement.busy
        var attempts = 0
        while settled == .busy, attempts < 200 {
            attempts += 1
            settled = await host!.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(1)))
            if settled == .busy { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(settled, .settled)
        XCTAssertEqual(store.loadCount, 1, "the warm-up made its one read")

        let finalFlush = await host!.flushEvents()
        XCTAssertTrue(finalFlush.allConfirmed, "the owner's final flush is confirmed before the owner drops anything")

        host = nil
        var free = false
        attempts = 0
        while !free, attempts < 200 {
            attempts += 1
            free = leaseIsFree(environment)
            if !free { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(free, "the root is taken again once the owner has dropped its host")
        removable = free
    }

    /// An adopted reload while a settle's join is pending makes that settle's result `.superseded`, since the host view the
    /// settle observed has changed. A settle after the gate opens then reports `.settled` for the reloaded host.
    func testAnAdoptedReloadWhileTheJoinIsPendingSupersedesIt() async throws {
        try await withGatedSettleFixture(build: { try await self.gatedHost($0, store: $1) }) { fixture in
            let host = fixture.host!
            try await host.startRuntime()
            await host.stopRuntime()
            let first = fixture.track(Task { @MainActor in
                await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            })
            // Wait, bounded, until the first settle has been admitted: its join is then the one in flight.
            var admitted = 0
            while host.stoppedEffectsJoinCount == 0, admitted < 200 {
                admitted += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(host.stoppedEffectsJoinCount, 1, "the first settle was admitted before the reload")
            await host.reloadConfiguration()
            let firstOutcome = await first.value
            XCTAssertEqual(firstOutcome, .superseded)
        }
    }

    /// A settle that follows the gate's opening returns `.settled` once the warm-up has made its read, and the flush comes after it.
    func testASettleSettlesOnlyAfterTheWarmupReadAndBeforeTheFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-settle-ok-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let store = GatedSecretStore()
        let host = try await gatedHost(session, store: store)
        try await host.startRuntime()
        await host.stopRuntime()
        store.open()
        let outcome = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(outcome, .settled)
        XCTAssertEqual(store.loadCount, 1, "the warm-up made its read before the settle returned")
        await host.flushEvents()
    }

    /// While one settle's join is pending, a second settle returns `.busy` before it allocates anything. The first
    /// settle still ends `.settled` once the gate opens.
    func testASecondSettleIsBusyWhileTheFirstJoinIsPending() async throws {
        try await withGatedSettleFixture(build: { try await self.gatedHost($0, store: $1) }) { fixture in
            let host = fixture.host!
            try await host.startRuntime()
            await host.stopRuntime()
            let first = fixture.track(Task { @MainActor in
                await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            })
            // Wait, bounded, until the first settle has been admitted: its join is then the one in flight.
            var admitted = 0
            while host.stoppedEffectsJoinCount == 0, admitted < 200 {
                admitted += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(host.stoppedEffectsJoinCount, 1, "the first settle was admitted before the second")
            let second = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            XCTAssertEqual(second, .busy)
            fixture.store.open()
            let firstOutcome = await first.value
            XCTAssertEqual(firstOutcome, .settled)
        }
    }

    /// A start admitted while a settle's join is pending makes that settle's result `.superseded`, not `.settled`. The
    /// join itself runs on until its gated warm-up ends, and then a settle of the newer stop succeeds.
    func testAStartAdmittedWhileTheJoinIsPendingSupersedesIt() async throws {
        try await withGatedSettleFixture(build: { try await self.gatedHost($0, store: $1) }) { fixture in
            let host = fixture.host!
            try await host.startRuntime()
            await host.stopRuntime()
            let first = fixture.track(Task { @MainActor in
                await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            })
            // Wait, bounded, until the first settle has been admitted: its join is then the one in flight.
            var admitted = 0
            while host.stoppedEffectsJoinCount == 0, admitted < 200 {
                admitted += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(host.stoppedEffectsJoinCount, 1, "the first settle was admitted before the start")
            try await host.startRuntime()
            let firstOutcome = await first.value
            XCTAssertEqual(firstOutcome, .superseded)
            // The teardown opens the gate, stops the started host, and settles it with a bounded wait before the flush.
        }
    }

    // MARK: - Credential warm-up coalescing (decision 0033)

    /// While the store blocks the first read, repeated warm-ups start no second producer. One request waits behind the
    /// active read and the newest one replaces the older waiting ones, so two reads happen, not three, and the middle
    /// request's sink never runs.
    func testRepeatedWarmupsWhileTheStoreBlocksRunOneWorkerAndOneWaitingRequest() async throws {
        let store = GatedSecretStore()
        let config = identityConfig(profileName: "Coalesce")
        let manager = CredentialManager(
            identityProvider: { (domain: config.domain, username: config.username, profileName: config.profileName) },
            store: store
        )
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        let sinks = [CountingSink(), CountingSink(), CountingSink()]

        let first = manager.warmCacheInBackground(eventSink: sinks[0].record)
        var attempts = 0
        while store.loadCount < 1, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.loadCount, 1, "the first warm-up is reading the store")

        let second = manager.warmCacheInBackground(eventSink: sinks[1].record)
        let third = manager.warmCacheInBackground(eventSink: sinks[2].record)
        XCTAssertEqual(store.loadCount, 1, "no second producer starts while the first read is blocked")

        // Refused reads make each warm-up report through its own sink, so the counts show which requests ran.
        store.open(refusing: true)
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(store.loadCount, 2, "one active read and one waiting request: two reads, not three")
        XCTAssertEqual(sinks.map(\.count), [1, 0, 1], "the newest waiting request ran, and the middle one was replaced")

        // Once the worker has ended, a new request starts a new one, so nothing is stuck behind the old handle.
        let fourth = manager.warmCacheInBackground(eventSink: nil)
        await fourth.value
        XCTAssertEqual(store.loadCount, 3)
    }

    /// A warm-up requested while nothing is blocked runs, and is reported once, through its own sink.
    func testAWarmupWithNothingBlockedRunsOnceThroughItsOwnSink() async throws {
        let store = GatedSecretStore()
        store.open(refusing: true)
        let config = identityConfig(profileName: "Single")
        let manager = CredentialManager(
            identityProvider: { (domain: config.domain, username: config.username, profileName: config.profileName) },
            store: store
        )
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        let sink = CountingSink()
        await manager.warmCacheInBackground(eventSink: sink.record).value
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(sink.count, 1)
    }

    // MARK: - Effect witnesses (decision 0033)

    /// The log's sink is bound before the privilege factory runs, so an event from the adapter's construction and one from
    /// its later command each reach the in-memory log and `events.ndjson` exactly once.
    func testAnAdapterEventFromConstructionAndFromACommandIsRecordedOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-witness-events-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)

        let adapter = PrivilegeAdapterBox()
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { emit in
                    emit(RuntimeEvent(kind: .config, event: "platform.settings_observed", detail: "witness=construction"))
                    let client = EmittingPrivilegeClient(emit: emit)
                    adapter.client = client
                    return RuntimePrivilegeAdapters(client: client, helperStatus: nil)
                },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        try XCTUnwrap(adapter.client).execute(.removeDNS, values: ["witness.example"])
        await quiesce(host)

        let inMemory = host.orchestrator.eventLog.events
        XCTAssertEqual(inMemory.filter { $0.detail == "witness=construction" }.count, 1)
        XCTAssertEqual(inMemory.filter { $0.detail == "witness=command" }.count, 1)
        let written = try String(contentsOf: environment.eventsFile, encoding: .utf8)
        XCTAssertEqual(written.components(separatedBy: "witness=construction").count - 1, 1)
        XCTAssertEqual(written.components(separatedBy: "witness=command").count - 1, 1)
    }

    /// The VPN monitor reads the flap-window timings through the host's readers, so a reload's new values reach it
    /// without a restart. A recording factory sees the readers the host passes.
    func testTheVPNMonitorReadsTheFlapWindowAsAReloadLeavesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-witness-flap-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        config.vpnFlapGraceSeconds = 2
        config.vpnFlapMinVisibleSeconds = 0.5
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let recorder = FlapWindowRecorder()
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(),
                gss: .injected { UnscriptedGSSProvider() },
                pacEvaluator: FakePacEvaluator(),
                commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { grace, minVisible in
                    recorder.grace = grace
                    recorder.minVisible = minVisible
                    return FakeVPNStatusObserver()
                },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        await host.awaitLaunchRecovery()
        XCTAssertEqual(recorder.grace?(), 2)
        XCTAssertEqual(recorder.minVisible?(), 0.5)

        config.vpnFlapGraceSeconds = 7
        config.vpnFlapMinVisibleSeconds = 3
        try ProxyConfigPersistence.save(config, in: environment)
        await host.reloadConfiguration()
        XCTAssertEqual(recorder.grace?(), 7)
        XCTAssertEqual(recorder.minVisible?(), 3)
        // The stopped effects join before the flush, or a late writer recreates files in the scratch directory.
        await quiesce(host)
    }

    /// A Start after a reload the Stop fence held adopts the input it commits through the one host-view path, as a reload does: status
    /// reports it, `configGeneration` counts it, and the VPN monitor reads its flap window. A Start that leaves the accepted pair as it
    /// was counts nothing, and an eligible reload still counts even when unchanged. The kernel's later config echo moves none of it.
    func testAStartAfterAFenceHeldReloadAdoptsTheCommittedInputAsTheHostView() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-start-adopts-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.profileName = "Y"
        config.vpnFlapGraceSeconds = 2
        config.vpnFlapMinVisibleSeconds = 0.5
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let recorder = FlapWindowRecorder()
        let machine = FakeMachine(resolverDirectory: environment.configDirectory.appendingPathComponent("resolver", isDirectory: true))
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(),
                gss: .injected { UnscriptedGSSProvider() },
                pacEvaluator: FakePacEvaluator(),
                commandRunner: { path, arguments in try machine.run(path, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { grace, minVisible in
                    recorder.grace = grace
                    recorder.minVisible = minVisible
                    return FakeVPNStatusObserver()
                },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: machine.resolverDirectory.path
            )
        )
        await host.awaitLaunchRecovery()

        try await host.startRuntime()
        XCTAssertEqual(host.configGeneration, 0, "a Start that keeps the accepted pair counts nothing")
        await host.stopRuntime()

        var edited = config
        edited.profileName = "X"
        edited.vpnFlapGraceSeconds = 7
        edited.vpnFlapMinVisibleSeconds = 3
        try ProxyConfigPersistence.save(edited, in: environment)
        await host.reloadConfiguration()
        let decisions = host.orchestrator.eventLog.events.compactMap { event -> ConfigurationWorkflowEvent? in
            guard case .configWorkflow(let decision) = event.typed else { return nil }
            return decision
        }
        XCTAssertEqual(decisions.last, .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)))
        XCTAssertEqual(host.status().profileName, "Y", "the fence held the reload, so the view is unchanged")
        XCTAssertEqual(host.configGeneration, 0)
        XCTAssertEqual(recorder.grace?(), 2)

        try await host.startRuntime()
        // The kernel's echo of the pushed config is delivered later; it must not have moved the view, so join it before reading.
        await host.deliveries.drain()
        XCTAssertEqual(host.status().profileName, "X")
        XCTAssertEqual(host.status().configGeneration, 1)
        XCTAssertEqual(recorder.grace?(), 7)
        XCTAssertEqual(recorder.minVisible?(), 3)

        await host.reloadConfiguration()
        XCTAssertEqual(host.configGeneration, 2, "an eligible reload counts, an unchanged one included")

        await host.stopRuntime()
        // The stopped effects join before the flush, or a late writer recreates files in the scratch directory.
        await quiesce(host)
    }

    /// Negotiated auth takes its token from the injected provider, through the host's own authenticator provider, and the
    /// system GSS stack is never reached.
    func testNegotiatedAuthTakesItsTokenFromTheInjectedProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-witness-gss-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        let upstream = UpstreamProxy(name: "Synthetic", host: "upstream.example", port: 9, priority: 0)
        config.authMode = .systemNegotiated
        config.upstreams = [upstream]
        try ProxyConfigPersistence.save(config, in: environment)

        let gss = FixedGSSProvider()
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(),
                gss: .injected { gss },
                pacEvaluator: FakePacEvaluator(),
                commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        await host.awaitLaunchRecovery()

        let authenticator = try host.orchestrator.lateBoundAuthenticatorProvider(upstream)
        XCTAssertEqual(authenticator.scheme, "Negotiate")
        XCTAssertEqual(try authenticator.initialToken(for: "upstream.example"),
                       "Negotiate " + FixedGSSProvider.token.base64EncodedString())
        XCTAssertEqual(gss.requestedHosts, ["upstream.example"])
        // The stopped effects join before the flush, or a late writer recreates files in the scratch directory.
        await quiesce(host)
    }

    /// A PAC refresh fetches through the injected evaluator, the production path `refreshPACRouting` takes. The URL is a
    /// scratch file, so a wrong wiring would still read only the test's own file.
    func testAPACRefreshFetchesThroughTheInjectedEvaluator() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-witness-pac-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        let pacFile = directory.appendingPathComponent("proxy.pac")
        try "function FindProxyForURL(url, host) { return \"DIRECT\"; }".write(to: pacFile, atomically: true, encoding: .utf8)
        var config = GenericDefaults.shared.makeConfig()
        config.pacRoutingEnabled = true
        config.pacURL = pacFile.absoluteString
        try ProxyConfigPersistence.save(config, in: environment)

        let pac = RecordingPACEvaluator()
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(),
                gss: .injected { UnscriptedGSSProvider() },
                pacEvaluator: pac,
                commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        await host.awaitLaunchRecovery()
        await host.orchestrator.refreshPACRouting(force: true)
        XCTAssertEqual(pac.fetchedURLs, [pacFile.absoluteString])
        // The stopped effects join before the flush, or a late writer recreates files in the scratch directory.
        await quiesce(host)
    }

    /// #246: an external edit that only respells the PAC URL (see `Respelled`), then a reload. The reload adopts the new bytes into the
    /// host view, and the reconciler, the orchestrator and the PAC fetch must take the same bytes, not keep the old spelling.
    func testAReloadThatOnlyRespellsThePACURLAppliesAndFetchesTheNewBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-respelled-pac-\(UUID().uuidString)", isDirectory: true)
        defer { removeScratch([directory]) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        let composed = "https://pac.example.test/\(Respelled.composed).pac"
        let decomposed = "https://pac.example.test/\(Respelled.decomposed).pac"
        Respelled.assertRespelling(composed, decomposed)
        var config = GenericDefaults.shared.makeConfig()
        config.pacRoutingEnabled = true
        config.pacURL = composed
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let pac = LastFetchPACEvaluator()
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: makeHostEffects(loopbackPortProbe: FakeLoopbackPortProbe(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(),
                gss: .injected { UnscriptedGSSProvider() },
                pacEvaluator: pac,
                commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        await host.awaitLaunchRecovery()
        await host.orchestrator.refreshPACRouting(force: true)
        XCTAssertEqual(pac.lastFetchedUTF8, Array(composed.utf8))

        config.pacURL = decomposed
        try ProxyConfigPersistence.save(config, in: environment)
        await host.reloadConfiguration()

        assertSameUTF8(host.config.pacURL, decomposed, "the reload adopted the persisted bytes into the host view")
        assertSameUTF8(host.orchestrator.config.pacURL, decomposed, "the reconciler pushed them to the orchestrator")
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "config.routing_changed" },
                      "\(host.orchestrator.eventLog.events.map(\.event))")
        XCTAssertEqual(pac.fetchCount, 2, "the respelled URL is fetched")
        XCTAssertEqual(pac.lastFetchedUTF8, Array(decomposed.utf8))
        // The stopped effects join before the flush, or a late writer recreates files in the scratch directory.
        await quiesce(host)
    }

    func testCredentialsComeFromTheInjectedStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-credential-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        let upstream = UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Seam \(UUID().uuidString)"
        config.username = "user"
        config.domain = "DOMAIN"
        config.authMode = .ntlmv2
        config.upstreams = [upstream]
        try ProxyConfigPersistence.save(config, in: environment)
        let secrets = InMemorySecretStore()
        let profileName = config.profileName
        try CredentialManager(identityProvider: { (domain: "DOMAIN", username: "user", profileName: profileName) }, store: secrets)
            .saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)

        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: secrets, commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        // Recovery writes the journal under `directory`; let it land before
        // the `defer` removes it.
        await host.awaitLaunchRecovery()

        let authenticator = try host.orchestrator.lateBoundAuthenticatorProvider(upstream)
        XCTAssertEqual(authenticator.scheme, "NTLM")
    }

    func testMalformedSidecarsRejectReloadWithoutReplacingAnyConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-sidecar-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Last good runtime"
        let platform = PlatformIntegrationConfig(manageSystemProxy: true)
        var preferences = AppPreferences()
        preferences.showMenuBarIcon = false
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(platform, in: environment)
        try AppPreferencesPersistence.save(preferences, in: environment)
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: { path, arguments in try machine.run(path, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: directory.appendingPathComponent("home"), resolverDirectory: machine.resolverDirectory.path
            )
        )
        var candidate = config
        candidate.profileName = "Must not replace the active runtime"
        try ProxyConfigPersistence.save(candidate, in: environment)
        for path in [environment.platformConfigFile, environment.preferencesFile] {
            let original = try Data(contentsOf: path)
            let corrupt = Data("{".utf8)
            try corrupt.write(to: path)
            await host.reloadConfiguration()
            XCTAssertEqual(host.config, config)
            XCTAssertEqual(host.platformConfig, platform)
            XCTAssertEqual(host.workflow.editorCapture().values.preferences, preferences, "the store keeps its last values")
            XCTAssertEqual(host.workflow.editorCapture().components.preferences, .retained(.observationRefused))
            XCTAssertEqual(host.configGeneration, 0)
            XCTAssertEqual(try Data(contentsOf: path), corrupt)
            XCTAssertEqual(host.orchestrator.eventLog.events.last?.event, "config.workflow.observed")
            try original.write(to: path)
        }
        await host.reloadConfiguration()
        XCTAssertEqual(host.config, candidate)
        XCTAssertEqual(host.configGeneration, 1)
    }

    func testRefusedAndHeldReloadsPreserveTheAppliedConfigurationAndFiles() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Last good config"
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        let environment = harness.environment
        let originalPlatform = try Data(contentsOf: environment.platformConfigFile)
        let originalPreferences = try Data(contentsOf: environment.preferencesFile)
        let cases: [(String, [ConfigurationWorkflowEvent])] = [
            ("{", [.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.invalidContent)))]),
            ("{\"localHost\":\"192.0.2.1\",\"manageSystemProxy\":true,\"showMenuBarIcon\":false}", [
                .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .adopted)),
                .held(ConfigurationWorkflowHeld(phase: .reload, input: .runtime, reason: .startBlocking)),
            ]),
        ]
        for (content, expected) in cases {
            try Data(content.utf8).write(to: environment.configFile)
            await host.reloadConfiguration()
            XCTAssertEqual(host.config, config)
            XCTAssertEqual(host.configGeneration, 0)
            let decisions = host.orchestrator.eventLog.events.compactMap { event -> ConfigurationWorkflowEvent? in
                guard case .configWorkflow(let decision) = event.typed else { return nil }
                return decision
            }
            XCTAssertEqual(Array(decisions.suffix(expected.count)), expected)
            XCTAssertEqual(try Data(contentsOf: environment.configFile), Data(content.utf8))
            XCTAssertEqual(try Data(contentsOf: environment.platformConfigFile), originalPlatform)
            XCTAssertEqual(try Data(contentsOf: environment.preferencesFile), originalPreferences)
        }
        try FileManager.default.removeItem(at: environment.configFile)
        await host.reloadConfiguration()
        XCTAssertEqual(host.config, config)
        XCTAssertEqual(host.configGeneration, 0)
    }

    func testConfigGenerationStartsAtZeroAndIncrementsOnReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Initial"
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let host = try await RuntimeHost.open(
            stateSession: session,
            logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )

        XCTAssertEqual(host.status().configGeneration, 0)

        config.profileName = "Reloaded"
        try ProxyConfigPersistence.save(config, in: environment)
        await host.reloadConfiguration()

        XCTAssertEqual(host.status().configGeneration, 1)
        XCTAssertEqual(host.status().profileName, "Reloaded")
    }

    func testVPNObserverDrivesOrchestratorState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        let observer = FakeVPNStatusObserver()
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let host = try await RuntimeHost.open(
            stateSession: session,
            logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: observer,
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        // Recovery writes the journal under the state directory; let it land
        // before the `defer` removes it.
        await host.awaitLaunchRecovery()

        // The host wires the observer callback during init. Drive the fake
        // observer directly rather than starting the full runtime (which may
        // perform network listener work depending on local config).
        observer.start()
        defer { observer.stop() }

        observer.emit(.connected)
        await host.deliveries.drain()

        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .connected)
    }

    /// Twin of the app's burst scenario: reports delivered without waiting
    /// for each other are stamped on the observer's turn, all applied in
    /// order, and the last one decides (#155).
    func testABurstOfVPNReportsEndsOnTheLastOneAndDropsNone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        let observer = FakeVPNStatusObserver()
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let host = try await RuntimeHost.open(
            stateSession: session,
            logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: observer,
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        await host.awaitLaunchRecovery()
        observer.start()
        defer { observer.stop() }

        for state: VPNObservedState in [.connected, .disconnected(reason: .userInitiated), .connected, .disconnected(reason: .networkLost)] {
            observer.emit(state)
        }
        await host.deliveries.drain()

        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .disconnected(reason: .networkLost))
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "vpn.observation_stale" }.count, 0)
    }

    /// The interface name belongs to the delivery it came with. The host
    /// hops to the main actor between the observer's callback and the
    /// orchestrator, so a name read after the hop would be whatever the
    /// monitor had moved on to.
    func testVPNInterfaceNameIsTheOneDeliveredWithTheState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        let observer = FakeVPNStatusObserver()
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let host = try await RuntimeHost.open(
            stateSession: session,
            logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: RecordingPrivilegeClient(), helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: observer,
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )
        // Recovery writes the journal under the state directory; let it land
        // before the `defer` removes it.
        await host.awaitLaunchRecovery()
        observer.start()
        defer { observer.stop() }

        observer.connectedInterfaceName = "utun4"
        observer.emit(.connected)
        // A later transition's refresh, before the queued task has run.
        observer.connectedInterfaceName = "utun9"
        await host.deliveries.drain()

        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .connected)
        XCTAssertEqual(host.orchestrator.snapshot.vpnInterfaceName, "utun4")

        // The same verdict delivered again with the new name follows it.
        observer.emit(.connected)
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.snapshot.vpnInterfaceName, "utun9")
    }

    /// A representable draft that blocks a start is saved and held from runtime apply, and the start refuses before any effect runs. Nothing
    /// is written to the resolver directory, the privilege client or the machine. The bind-failure cleanup, where a start that has already
    /// begun reverts what it touched, is covered by `testAFailedStartWithAReloadPassQueuedBehindItDoesNotDeadlock` and by the
    /// `runtime-host-effects` simulator scenario.
    func testAStartRefusedForAStartBlockingConfigAppliesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        var config = GenericDefaults.shared.makeConfig()
        config.dnsEntries = [DomainDNSEntry(domain: "revert-test.example", servers: ["10.9.9.9"])]
        // Rejected by `ProxyConfig.validate()`, so the start fails immediately
        // instead of spending the bind retry budget on a contended port.
        config.maxConnections = 0

        let recording = RecordingPrivilegeClient()
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageDNSResolvers: true), in: environment)
        let host = try await RuntimeHost.open(
            stateSession: session,
            logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: recording, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: Self.offMachine,
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: environment.configDirectory.appendingPathComponent("home"),
                resolverDirectory: try scratchResolverDirectory(environment)
            )
        )

        // The start-blocking input is refused at admission, before any apply, so nothing is written and nothing needs reverting.
        do {
            try await host.startRuntime()
            XCTFail("start should be refused on a config the kernel rejects")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .held)
        }

        XCTAssertEqual(
            recording.commands(matching: .removeDNS).compactMap(\.first),
            [],
            "a refused start applies nothing, so it strands no resolver files"
        )
    }

    /// The platform sidecar is missing, so its values come from the runtime file. An editor outside the host adds a legacy platform value to
    /// that file after the open. The Start's first platform write checks the runtime bytes it was opened with, holds, and creates no sidecar
    /// over the edited value. The runtime write is held behind it, both files are latched until a reload, and no machine effect runs.
    func testAStartAfterAnExternalRuntimeEditBesideAMissingPlatformSidecarHoldsWithoutCreatingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        try ProxyConfigPersistence.save(config, in: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.platformConfigFile.path), "the platform sidecar starts missing")
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let host = try await RuntimeHost.open(
            stateSession: session, logger: DiscardingLogSink(),
            startupAllowsMissing: true,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit,
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: { path, arguments in try machine.run(path, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: directory.appendingPathComponent("home"), resolverDirectory: machine.resolverDirectory.path
            )
        )

        // The outside editor adds a legacy platform value to the owned scratch runtime file.
        let saved = try Data(contentsOf: environment.configFile)
        guard var object = try JSONSerialization.jsonObject(with: saved) as? [String: Any] else { return XCTFail("the runtime file is an object") }
        object["manageSystemProxy"] = true
        let edited = try JSONSerialization.data(withJSONObject: object)
        try edited.write(to: environment.configFile)

        func startDecisions() async -> [ConfigurationWorkflowEvent] {
            let before = host.orchestrator.eventLog.events.count
            do {
                try await host.startRuntime()
                XCTFail("the start must hold")
            } catch let refusal as RuntimeStartRefusal {
                XCTAssertEqual(refusal, .held)
            } catch {
                XCTFail("unexpected start error: \(error)")
            }
            return host.orchestrator.eventLog.events.dropFirst(before).compactMap { event -> ConfigurationWorkflowEvent? in
                guard case .configWorkflow(let decision) = event.typed else { return nil }
                return decision
            }
        }

        let first = await startDecisions()
        XCTAssertEqual(first.filter { if case .committed = $0 { true } else { false } }, [
            .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.heldBehindPlatform))),
            .committed(ConfigurationWorkflowCommitted(file: .platform, write: .notAttempted(.sourceChanged))),
        ])
        XCTAssertTrue(first.contains(.held(ConfigurationWorkflowHeld(phase: .start, input: .platform, reason: .commitFailed))), "\(first)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.platformConfigFile.path), "no platform sidecar is created")
        XCTAssertEqual(try Data(contentsOf: environment.configFile), edited, "the edited runtime file is kept")
        XCTAssertFalse(machine.service("Wi-Fi").webProxy.enabled, "a held start applies no system proxy")

        // Both files latched: the next start is refused for each with no baseline, before any I/O, until a reload.
        let second = await startDecisions()
        XCTAssertEqual(second.filter { if case .committed = $0 { true } else { false } }, [
            .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.noBaseline))),
            .committed(ConfigurationWorkflowCommitted(file: .platform, write: .notAttempted(.noBaseline))),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.platformConfigFile.path))
        await host.flushEvents()
    }

    // MARK: - Ownership guards, twins of the `AppState` scenarios

    /// A host over a `FakeMachine`, the way `AppStateHarness` builds the app:
    /// every subprocess and privileged write lands on the model, resolver
    /// files in a scratch directory, and the journal file under the
    /// isolated environment.
    @MainActor
    private final class DaemonHarness {
        /// The scratch root's writer authority, taken before any seed write. Released by `tearDown`, after the host's work.
        let stateSession: StateRootSession
        let environment: RuntimeEnvironment
        let machine: FakeMachine
        let vpn = FakeVPNStatusObserver()
        let locationObserver = FakeNetworkLocationObserver()
        let pathObserver = FakeNetworkPathObserver()
        /// The system wake source the host observes from open until its quit.
        let wake = FakeSystemWakeObserver()
        /// Ends a terminal stop. Replaced by a test that asserts on the exit.
        var terminalExit: @MainActor () -> Void = unexpectedTerminalExit
        var locationStore: FakeNetworkLocationStore?
        var locationLimits = NetworkLocationLimits()
        /// As `AppStateHarness.reapplyRetrySchedule`.
        var reapplyRetrySchedule = ConfigReapplyRetry.Schedule(delays: [.seconds(3600)])
        /// Holds the machine's `networksetup` listings when armed, so a
        /// scenario can keep one system DNS reconcile out while more arrive.
        let listings = HeldListings()
        /// Holds one machine call, subprocess or privileged, when armed.
        let hold = HeldCall()
        /// The configuration store's file access. Unarmed it is the operating system's; armed, one read parks the store's slot.
        let stateFiles = ParkingStateFiles()
        /// The one host `makeHost` built, owned until `tearDown` has stopped and flushed it.
        private var ownedHost: RuntimeHost?
        let secrets = InMemorySecretStore()
        /// The helper status the split-DNS check reads; never the installed helper.
        let helper = FakeHelperLifecycle()
        /// The loopback listener probe the host's system proxy manager asks. It serves no port, and it records what it was asked.
        let listenerProbe = FakeLoopbackPortProbe()
        /// The PAC evaluator the host's orchestrator fetches through. Fails any fetch unless a test names a scripted one.
        var pacEvaluator: any PacEvaluator = FakePacEvaluator()
        /// Long, so a split-DNS helper check never lands inside a scenario
        /// about something else; the check's own scenario passes a short one.
        var splitDNSHelperCheckInterval: Duration = .seconds(3600)
        private let stateDirectory: URL
        /// The scratch home the host edits shell profiles in.
        var homeDirectory: URL { stateDirectory.appendingPathComponent("home", isDirectory: true) }

        /// The harness whose shutdown was not confirmed. It keeps its host and root, and fails the test that owned it. One
        /// slot: a second unconfirmed shutdown never overwrites it, and no new harness is built while it is occupied.
        private static var retainedUnconfirmed: DaemonHarness?

        init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) throws {
            guard DaemonHarness.retainedUnconfirmed == nil else { throw HarnessHostOwnershipError.retainedUnconfirmed }
            let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pm-daemon-harness-\(UUID().uuidString)", isDirectory: true)
            self.stateDirectory = stateDirectory
            try FileManager.default.createDirectory(
                at: stateDirectory.appendingPathComponent("home", isDirectory: true),
                withIntermediateDirectories: true
            )
            // An established install: the files a previous launch left, written before this process takes the root,
            // so the session reads the configuration as predating the launch.
            let fixture = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)
            try ProxyConfigPersistence.save(config, in: fixture)
            try PlatformConfigPersistence.save(platformConfig, in: fixture)
            try AppPreferencesPersistence.save(AppPreferences(), in: fixture)
            stateSession = try acquireScratchStateRoot(fixture)
            environment = stateSession.environment
            machine = FakeMachine(resolverDirectory: stateDirectory.appendingPathComponent("resolver", isDirectory: true))
        }

        /// A fresh reader over the journal file; the host's own instance
        /// caches what it loaded.
        var journal: PlatformStateJournal { PlatformStateJournal(fileURL: environment.platformStateFile) }

        var wifi: FakeMachine.Service { machine.service("Wi-Fi") }

        /// Builds the test's one host and keeps it owned, so `tearDown` stops and flushes it before the root's authority ends.
        /// A second request throws before anything is built, so the owned host is never overwritten or left unstopped.
        func makeHost() async throws -> RuntimeHost {
            guard ownedHost == nil else { throw HarnessHostOwnershipError.secondHost }
            let host = try await buildHost()
            ownedHost = host
            return host
        }

        private func buildHost() async throws -> RuntimeHost {
            let machine = self.machine
            let listings = self.listings
            let hold = self.hold
            let helper = self.helper
            return try await RuntimeHost.open(
                stateSession: stateSession,
                logger: DiscardingLogSink(),
                startupAllowsMissing: true,
                startedAt: testStartedAt, terminalExit: terminalExit,
                effects: hostEffects(loopbackPortProbe: listenerProbe, pacEvaluator: pacEvaluator,
                    privilege: { _ in RuntimePrivilegeAdapters(client: HoldingPrivilegeClient(base: machine, hold: hold), helperStatus: helper) },
                    credentials: secrets,
                    commandRunner: { launchPath, arguments in
                        if arguments.first == "-listallnetworkservices" { listings.passThrough() }
                        hold.pass(launchPath, arguments)
                        return try machine.run(launchPath, arguments)
                    },
                    networkPath: pathObserver, networkLocation: locationObserver,
                    networkLocationStoreFactory: { [locationStore] _ in locationStore }, vpnStatus: vpn,
                    // As `AppStateHarness`: never the real port 53.
                    dnsResponds: FakeDNSProbe().responds(onPort:),
                    homeDirectory: stateDirectory.appendingPathComponent("home", isDirectory: true),
                    resolverDirectory: machine.resolverDirectory.path,
                    stateFiles: stateFiles,
                    wake: wake
                ),
                networkLocationLimits: locationLimits,
                reapplyRetrySchedule: reapplyRetrySchedule,
                splitDNSHelperCheckInterval: splitDNSHelperCheckInterval
            )
        }

        /// The switch goes off on disk, the way the app or a hand edit
        /// changes it for the daemon, and the daemon reloads.
        func flip(_ platformConfig: PlatformIntegrationConfig, on host: RuntimeHost) async throws {
            try PlatformConfigPersistence.save(platformConfig, in: environment)
            await host.reloadConfiguration()
        }

        /// Both record queues are empty of in-flight records. Recorded loss is not checked, since a test may expect a refused
        /// destination. `eventsRetry` can be the early retry, spent before the snapshot's marker is appended, so a drained
        /// retry does not prove the marker's queue state. `snapshotSettled` covers the marker.
        private static func recordQueuesDrained(_ report: DiagnosticFlushReport) -> Bool {
            report.audit == .drained && (report.events == .drained || report.eventsRetry == .drained)
        }

        /// A writer's counters, numeric only, for the unconfirmed-shutdown failure.
        private static func describe(_ statistics: RecordWriterStatistics) -> String {
            "pending=\(statistics.pendingRecords) pendingBytes=\(statistics.pendingBytes) written=\(statistics.writtenRecords) "
                + "dropped=\(statistics.droppedRecords) failed=\(statistics.failedRecords) flushTimeouts=\(statistics.flushTimeouts)"
        }

        /// The snapshot write is physically complete, and any unconfirmed-result marker is covered by a later events drain.
        /// `.current` is a successful replacement with no marker. `.refused`, `.writeFailed` and `.noSubmission` come after
        /// the writer's group drained, or before any submission, so no write is in flight. The marker is then covered only
        /// by the one late events drain (`.confirmed`). The other outcomes end without a result, so a write may still be in
        /// flight, and none of them is proven here.
        private static func snapshotSettled(_ report: DiagnosticFlushReport) -> Bool {
            switch report.snapshot {
            case .current:
                return true
            case .refused, .writeFailed, .noSubmission:
                return report.snapshotEvent == .confirmed
            case .timedOut, .busy, .skippedBudget, .cancelled, .exhausted:
                return false
            }
        }

        /// Stops and flushes the owned host, then ends the root's authority and removes the directory. The flush joins the
        /// host's audit, event and snapshot writers before removal, which is what this fixture relies on. It is not a
        /// general proof that nothing else can write under the root.
        func tearDown() async {
            // A test that failed mid-hold leaves the hold armed, and the stop would wait on it. Releasing is harmless when
            // nothing waits.
            hold.release()
            listings.release()
            if let host = ownedHost {
                await host.stopRuntime()
                // The stopped effects join before the flush, so a late writer cannot land after the root is released.
                let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
                let report = await host.flushEvents()
                let flushed = Self.recordQueuesDrained(report) && Self.snapshotSettled(report)
                guard settled == .settled, flushed else {
                    // Unknown: keep the host, the session and the root claimed, and fail the owning test.
                    XCTFail("the harness's shutdown is unconfirmed (settle \(settled), flush confirmed \(flushed), "
                        + "audit \(report.audit), events \(report.events), eventsRetry \(String(describing: report.eventsRetry)), "
                        + "snapshot \(report.snapshot), snapshotEvent \(report.snapshotEvent), "
                        + "audit statistics \(Self.describe(report.auditStatistics)), "
                        + "events statistics \(Self.describe(report.eventsStatistics))): its host and root are kept")
                    DaemonHarness.retainedUnconfirmed = self
                    return
                }
            }
            ownedHost = nil
            // The release is checked before the directory goes. A release that is not confirmed keeps the directory.
            let release = releaseScratchStateRoot(stateSession)
            guard release == .released else {
                XCTFail("the harness's root lease did not close (\(release)): its directory is kept")
                return
            }
            removeScratch([stateDirectory])
        }
    }

    /// A gate on the `networksetup` service listing, which every system DNS
    /// reconcile begins with. Armed, the first listing waits for `release()`
    /// and every listing is counted.
    private final class HeldListings: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var counted = 0
        private var waiting = false
        private let gate = DispatchSemaphore(value: 0)

        var count: Int { lock.withLock { counted } }
        var isHoldingOne: Bool { lock.withLock { waiting } }

        func arm() { lock.withLock { armed = true; counted = 0 } }

        /// Opens the hold. Listings go on being counted.
        func release() { gate.signal() }

        func passThrough() {
            let holds = lock.withLock { () -> Bool in
                guard armed else { return false }
                counted += 1
                guard !waiting else { return false }
                waiting = true
                return true
            }
            if holds { gate.wait() }
        }
    }

    /// A loopback listener the test holds open on a port it chose, so a start's bind on that port fails as a contended port does.
    /// Released when the test drops it.
    private final class HeldLoopbackPort {
        let port: Int
        private let descriptor: Int32

        init() throws {
            // Qualified: the test class's own `bind` would otherwise shadow the socket call.
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HarnessHostOwnershipError.heldPortUnavailable }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            var chosen = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &chosen) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard bound == 0, named == 0, Darwin.listen(fd, 1) == 0 else {
                Darwin.close(fd)
                throw HarnessHostOwnershipError.heldPortUnavailable
            }
            descriptor = fd
            port = Int(UInt16(bigEndian: chosen.sin_port))
        }

        deinit {
            Darwin.close(descriptor)
        }
    }

    private var harness: DaemonHarness!

    // The async override runs on the main actor, where `harness` lives.
    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Ephemeral ports, one split-DNS entry: the same config the app
    /// scenarios run on.
    private func launch(platform: PlatformIntegrationConfig, dnsForwarderEnabled: Bool = false) async throws -> RuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = dnsForwarderEnabled
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: platform)
        return try await harness.makeHost()
    }

    /// A terminal stop hands the process exit to the injected hook once, after
    /// its snapshot is written. A plain stop never reaches the hook.
    func testTerminalStopEndsTheProcessOnceAfterItsSnapshot() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let snapshotFile = harness.environment.snapshotFile
        var snapshotWrittenAtExit: [Bool] = []
        harness.terminalExit = { snapshotWrittenAtExit.append(FileManager.default.fileExists(atPath: snapshotFile.path)) }
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        await host.stopRuntime()
        XCTAssertEqual(snapshotWrittenAtExit, [], "a stop that does not exit leaves the process running")

        // The ordinary stop submits its snapshot without waiting, so file currency is confirmed by the explicit
        // diagnostic flush. Then remove it, so the hook can only see the one the terminal stop writes before it exits.
        await host.flushEvents()
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path), "the ordinary stop wrote a snapshot")
        try FileManager.default.removeItem(at: snapshotFile)

        await host.stopRuntime(exitAfterStop: true)
        XCTAssertEqual(snapshotWrittenAtExit, [true], "the exit comes once, after the snapshot is written")
    }

    /// The `ConduitDaemon --exit-after-ready --start-runtime` sequence, run through the FakeMachine harness rather
    /// than the executable. It is the process quit: the shutdown latches, never calls the terminal exit, and its own
    /// flush confirms the stopped state, since the readiness flush happened before the stop.
    func testExitAfterReadySequenceConfirmsTheStoppedStateInTheFile() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let snapshotFile = harness.environment.snapshotFile
        var exits = 0
        harness.terminalExit = { exits += 1 }
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        try await host.startRuntime()
        await host.markReady(mode: "runtime-started")
        await host.flushEvents()
        await host.shutdown()
        XCTAssertEqual(exits, 0, "the shutdown returns and never exits")
        do {
            try await host.startRuntime()
            XCTFail("no Start runs after the process quit")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .terminated)
        }
        // Observer deliveries from earlier changes are joined first, so the final state is the one compared.
        await host.deliveries.drain()
        await host.flushEvents()

        // Compared as bytes under the writer's own encoding: a decoded value can differ from the live one at sub-second precision.
        let expected = try CanonicalJSON.encoder(prettyPrinted: true).encode(host.orchestrator.snapshot)
        XCTAssertEqual(try Data(contentsOf: snapshotFile), expected, "the file holds the final stopped state")
    }

    /// A snapshot delivery that reaches the main actor only after the final stop was submitted must not write the
    /// older state it was emitted with. The callback reads canonical state when it runs, so the file keeps the
    /// final state after the explicit flush.
    func testDeferredOlderSnapshotDeliveryCannotResurrectTheFileAfterTheFinalStop() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let snapshotFile = harness.environment.snapshotFile
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        await host.stopRuntime()
        // An older state, delivered after the final stop was already submitted.
        var older = host.orchestrator.snapshot
        older.dnsQueryCount = 999
        host.orchestrator.onSnapshotChange?(older)
        await host.deliveries.drain()
        await host.flushEvents()

        let expected = try CanonicalJSON.encoder(prettyPrinted: true).encode(host.orchestrator.snapshot)
        XCTAssertEqual(try Data(contentsOf: snapshotFile), expected, "the late delivery wrote the canonical state, not its own")
        XCTAssertFalse(String(decoding: try Data(contentsOf: snapshotFile), as: UTF8.self).contains("\"dnsQueryCount\" : 999"))
    }

    /// `status()` reports the start the entry point passed in and reads no
    /// clock of its own.
    func testStatusReportsTheInjectedStartTime() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig())
        await host.awaitLaunchRecovery()

        XCTAssertEqual(host.status().daemon?.startedAt, testStartedAt)
        await host.stopRuntime()
    }

    /// The runtime starts and stops the injected path observer, and a report
    /// it delivers reaches the orchestrator as a path decision.
    func testRuntimeDrivesTheInjectedPathObserver() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig())
        await host.awaitLaunchRecovery()

        try await host.startRuntime()
        XCTAssertTrue(harness.pathObserver.isObserving)

        harness.pathObserver.emit(satisfiedPath())
        await host.deliveries.drain()
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "network.path_changed" })

        await host.stopRuntime()
        XCTAssertFalse(harness.pathObserver.isObserving)
    }

    func testLocationSwitchWithoutVPNOrPathChangeRestoresInactiveStateAndPreservesExternalEdits() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = true
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, manageSystemDNS: true))
        let locations = NetworkLocationFixture.store()
        let original = try locations.snapshot()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let vpnBefore = host.orchestrator.snapshot.vpnState
        locations.edit { $0.activeLocationID = NetworkLocationFixture.office }
        harness.locationObserver.emit(NetworkLocationFixture.office)
        await host.deliveries.drain()
        let switched = try locations.snapshot()
        XCTAssertEqual(switched.services[0].proxies, original.services[0].proxies)
        XCTAssertEqual(switched.services[0].dns, original.services[0].dns)
        XCTAssertEqual(switched.services[1].proxies["HTTPProxy"], .text("127.0.0.1"))
        XCTAssertEqual(switched.services[1].dns["ServerAddresses"], .list(["127.0.0.1"]))
        let boundDNSPort = try XCTUnwrap(host.orchestrator.snapshot.bindings.dnsPort)
        XCTAssertEqual(harness.machine.privilege.commands(matching: .startDNSRelay).last, [String(boundDNSPort)])
        XCTAssertEqual(host.orchestrator.snapshot.vpnState, vpnBefore)
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "platform.location_observed" })
        locations.edit { $0.services[1].dns["ServerAddresses"] = .list(["192.0.2.9"]) }
        await host.stopRuntime()
        XCTAssertEqual(try locations.snapshot().services[1].dns["ServerAddresses"], .list(["192.0.2.9"]))
        XCTAssertEqual(try locations.snapshot().services[1].proxies, original.services[1].proxies)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
    }

    func testVPNReportRepairsFailedPACApplicationAndLaterRewriteWithoutRestartingRuntime() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac))
        let locations = NetworkLocationFixture.store()
        locations.refuseWrites(true)
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let bindings = host.orchestrator.snapshot.bindings
        let url = try XCTUnwrap(bindings.localPACURL)
        XCTAssertNotEqual(try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        locations.refuseWrites(false)
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        let corporatePAC = NetworkSettingValue.text("http://corporate.example/proxy.pac")
        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = corporatePAC }
        harness.vpn.emit(.disconnected(reason: .userInitiated))
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        XCTAssertEqual(host.orchestrator.snapshot.bindings, bindings)
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "platform.location_reconcile" })
        await host.stopRuntime()
        XCTAssertEqual(try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"], corporatePAC)
    }

    func testContendedRepairRetriesWhenTheWindowReopensWithoutAnotherNotification() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac))
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        harness.locationLimits = NetworkLocationLimits(maximumDriftRepairs: 1, driftRepairWindow: .milliseconds(300))
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        // The first path report also reconciles; let it land first, so only
        // the scheduled retry can repair the withheld write below.
        harness.pathObserver.emit(satisfiedPath())
        await host.deliveries.drain()
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "network.path_changed" })
        let url = try XCTUnwrap(host.orchestrator.snapshot.bindings.localPACURL)
        let enforced = NetworkSettingValue.text("http://enforced.example/proxy.pac")
        func pac() throws -> NetworkSettingValue? { try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"] }
        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = enforced }
        harness.locationObserver.emitSettingsChange()
        await host.deliveries.drain()
        XCTAssertEqual(try pac(), .text(url))
        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = enforced }
        harness.locationObserver.emitSettingsChange()
        await host.deliveries.drain()
        XCTAssertEqual(try pac(), enforced)
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "platform.location_contended" }.count, 1)
        var restored = false
        for _ in 0..<5_000 where !restored {
            try await Task.sleep(for: .milliseconds(1))
            restored = try pac() == .text(url)
        }
        XCTAssertTrue(restored, "the withheld repair ran when the window reopened")
        await host.stopRuntime()
        XCTAssertEqual(try pac(), enforced)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
    }

    func testLatePACRewriteRepairsOnSettingsNotificationWithoutAnotherVPNOrPathReport() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac))
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        let bindings = host.orchestrator.snapshot.bindings
        let url = try XCTUnwrap(bindings.localPACURL)
        let corporatePAC = NetworkSettingValue.text("http://corporate.example/late.pac")
        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = corporatePAC }
        harness.locationObserver.emitSettingsChange()
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        XCTAssertEqual(host.orchestrator.snapshot.bindings, bindings)
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "platform.settings_observed" })
        // Our own preferences notifications cannot trigger another write.
        let failuresBefore = host.orchestrator.eventLog.events.filter { $0.event == "platform.location_failed" }.count
        locations.refuseWrites(true)
        for _ in 0..<20 { harness.locationObserver.emitSettingsChange() }
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "platform.location_failed" }.count, failuresBefore)
        locations.refuseWrites(false)
        let pending = try XCTUnwrap(harness.locationObserver.pendingSettingsDelivery())
        await host.stopRuntime()
        let stopped = try locations.snapshot()
        pending()
        harness.locationObserver.emitSettingsChange()
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot(), stopped)
        XCTAssertEqual(stopped.services[0].proxies["ProxyAutoConfigURLString"], corporatePAC)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
    }

    func testVPNReconcileRetriesDNSInSameLocationAfterInitiallyDisabledService() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = true
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemDNS: true))
        let locations = NetworkLocationFixture.store()
        locations.edit { $0.services[0].enabled = false }
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
        locations.edit { $0.services[0].enabled = true }
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services[0].dns["ServerAddresses"], .list(["127.0.0.1"]))
        let port = try XCTUnwrap(host.orchestrator.snapshot.bindings.dnsPort)
        XCTAssertEqual(harness.machine.privilege.commands(matching: .startDNSRelay).last, [String(port)])
        await host.stopRuntime()
    }

    func testLocationNotificationDuringRuntimeStopCannotRepinStoppedListeners() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = true
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, manageSystemDNS: true))
        let locations = NetworkLocationFixture.store()
        let original = try locations.snapshot()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let notification = harness.locationObserver.pendingDelivery(NetworkLocationFixture.office)
        XCTAssertNotNil(notification)
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }
        let stop = Task { await host.stopRuntime() }
        await harness.hold.waitUntilReached()
        defer { harness.hold.release() }
        locations.edit { $0.activeLocationID = NetworkLocationFixture.office }
        notification?()
        for _ in 0..<5_000 where !host.orchestrator.eventLog.events.contains(where: { $0.event == "platform.location_observed" }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "platform.location_observed" })
        harness.hold.release()
        await stop.value
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services, original.services)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
    }

    func testVPNNotificationDuringRuntimeStopCannotRepinStoppedListeners() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = true
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, manageSystemDNS: true))
        let locations = NetworkLocationFixture.store()
        let original = try locations.snapshot()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let notification = try XCTUnwrap(harness.vpn.pendingDelivery(.connected))
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }
        let stop = Task { await host.stopRuntime() }
        await harness.hold.waitUntilReached()
        defer { harness.hold.release() }
        notification()
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(host.passesWaitingForLifecycle, 0)
        harness.hold.release()
        await stop.value
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services, original.services)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
    }

    /// A captured settings callback can arrive after observation stops;
    /// it must wait for teardown and never restore a dead listener's PAC.
    func testSettingsNotificationDuringRuntimeStopCannotRepinStoppedListeners() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = true
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, manageSystemDNS: true))
        let locations = NetworkLocationFixture.store()
        let original = try locations.snapshot()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let notification = try XCTUnwrap(harness.locationObserver.pendingSettingsDelivery())
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }
        let stop = Task { await host.stopRuntime() }
        await harness.hold.waitUntilReached()
        defer { harness.hold.release() }
        notification()
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(host.passesWaitingForLifecycle, 0)
        for _ in 0..<1_000 { notification() }
        harness.hold.release()
        await stop.value
        await host.deliveries.drain()
        XCTAssertEqual(try locations.snapshot().services, original.services)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
        XCTAssertLessThanOrEqual(host.orchestrator.eventLog.events.filter { $0.event == "platform.settings_observed" }.count, 2)
    }

    // MARK: - System wake (twin of `AppState.handleSystemWake`)

    /// How many times the kernel's wake path ran: it records one DNS transport reset for each, before it awaits anything.
    private func kernelWakes(_ host: RuntimeHost) -> Int {
        host.orchestrator.eventLog.events.filter { $0.event == "dns.transports_reset" && $0.detail == "source=system_wake" }.count
    }

    /// Wake is observed from open until the quit, as `AppState` observes it from init until termination. A wake before any Start and
    /// one after a Stop both reach the kernel's wake path, as the app's do. A Stop that leaves every module down keeps observing. The
    /// quit's admission ends observation in its own turn, and a wake already in flight then does nothing.
    func testWakeIsObservedFromOpenUntilTheQuitsAdmissionAndNotPastIt() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig())
        XCTAssertTrue(harness.wake.isObserving, "observed from open, before any Start")
        XCTAssertEqual(harness.wake.startCount, 1)
        await host.awaitLaunchRecovery()

        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(kernelWakes(host), 1, "a wake before any Start reaches the kernel's wake path")

        try await host.startRuntime()
        await host.stopRuntime()
        XCTAssertTrue(harness.wake.isObserving, "a Stop that leaves every module down keeps observing")
        XCTAssertEqual(harness.wake.stopCount, 0)
        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(kernelWakes(host), 2, "a wake after a Stop reaches the kernel's wake path")

        let inFlight = try XCTUnwrap(harness.wake.pendingWake())
        let quit = host.admitQuit(until: nil, flushing: .none)
        XCTAssertFalse(harness.wake.isObserving, "the quit's admission turn ends observation, before its teardown runs")
        XCTAssertEqual(harness.wake.stopCount, 1)
        inFlight()
        harness.wake.emitWake()
        await quit.value
        await host.deliveries.drain()
        XCTAssertEqual(kernelWakes(host), 2, "a wake in flight at the quit does nothing")
        XCTAssertEqual(harness.wake.stopCount, 1, "observation ends once")
    }

    /// While the proxy runs, a wake repairs a system proxy rewritten during sleep, through the same bounded reconcile as a settings
    /// notification, and runs the kernel's wake path. After a Stop, a wake repairs nothing.
    func testWakeRepairsARewrittenSystemProxyOnlyWhileTheProxyRuns() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac))
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        await host.deliveries.drain()
        let url = try XCTUnwrap(host.orchestrator.snapshot.bindings.localPACURL)
        func pac() throws -> NetworkSettingValue? { try locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"] }
        let corporatePAC = NetworkSettingValue.text("http://corporate.example/asleep.pac")

        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = corporatePAC }
        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(try pac(), .text(url), "the wake's proxy reconcile restores the running listener's PAC")
        XCTAssertEqual(kernelWakes(host), 1)

        await host.stopRuntime()
        locations.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = corporatePAC }
        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(try pac(), corporatePAC, "a wake after the Stop repairs nothing")
        XCTAssertEqual(kernelWakes(host), 2)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
    }

    /// While the forwarder runs, a wake re-pins an interface a VPN client re-asserted its own resolvers on during sleep, through the
    /// coalesced system DNS reconcile. After a Stop, a wake writes no DNS.
    func testWakeRepinsSystemDNSOnlyWhileTheForwarderRuns() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        await host.deliveries.drain()
        XCTAssertEqual(harness.wifi.dnsServers, ["127.0.0.1"], "the Start pinned the interface")

        harness.machine.describe("Wi-Fi") { $0.dnsServers = ["10.9.9.9"] }
        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(harness.wifi.dnsServers, ["127.0.0.1"], "the wake's DNS reconcile re-pins the interface")
        XCTAssertEqual(kernelWakes(host), 1)

        await host.stopRuntime()
        let restored = harness.wifi.dnsServers
        let writes = harness.machine.privilege.commands(matching: .setDNSServers).count
        harness.wake.emitWake()
        await host.deliveries.drain()
        XCTAssertEqual(harness.machine.privilege.commands(matching: .setDNSServers).count, writes, "a wake while DNS is down writes no DNS")
        XCTAssertEqual(harness.wifi.dnsServers, restored)
        XCTAssertEqual(kernelWakes(host), 2)
    }

    /// A burst of wakes is bounded before any task exists: one tracked delivery per repair, one coalesced pass each. The repairs are
    /// independent: a DNS pass held on the machine does not hold the kernel's wake path, and a burst while it is held adds no DNS delivery.
    /// A quit admitted in the same turn as a burst drops every pass that runs after it, the pending ones included.
    func testABurstOfWakesIsBoundedPerRepairIndependentAndDroppedByTheQuit() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        await host.deliveries.drain()
        XCTAssertEqual(host.deliveries.inFlightCount, 0)

        // One synchronous turn: no delivery has run yet.
        for _ in 0..<100 { harness.wake.emitWake() }
        XCTAssertEqual(host.deliveries.inFlightCount, 3, "one tracked delivery per repair, not one per wake")
        await host.deliveries.drain()
        XCTAssertEqual(kernelWakes(host), 1, "the burst ran the kernel's wake path once")

        // The DNS pass is held on its machine listing; the kernel's pass goes on without it.
        harness.listings.arm()
        harness.wake.emitWake()
        for _ in 0..<5_000 where !harness.listings.isHoldingOne || kernelWakes(host) < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(harness.listings.isHoldingOne, "the DNS pass is held")
        XCTAssertEqual(kernelWakes(host), 2, "the kernel's wake path ran while the DNS pass was held")

        // A burst while the DNS pass is held starts at most one delivery for each of the other two repairs and none for DNS, and the
        // quit admitted in the same turn drops whatever runs after it.
        let before = host.deliveries.inFlightCount
        for _ in 0..<100 { harness.wake.emitWake() }
        XCTAssertLessThanOrEqual(host.deliveries.inFlightCount - before, 2, "no delivery for the held DNS repair, at most one for each other")
        let quit = host.admitQuit(until: nil, flushing: .none)
        harness.listings.release()
        await quit.value
        await host.deliveries.drain()
        XCTAssertEqual(host.deliveries.inFlightCount, 0)
        XCTAssertEqual(kernelWakes(host), 2, "no kernel pass runs after the quit's admission, running or pending")
    }

    /// #98, as in `AppState`: the runtime start reads the saved password
    /// once, and the handshakes after it are answered from that read.
    func testRuntimeStartReadsASavedPasswordOnce() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig())
        let config = host.config
        try CredentialManager(
            identityProvider: { (domain: config.domain, username: config.username, profileName: config.profileName) },
            store: harness.secrets
        ).saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        try await host.startRuntime()
        await host.credentialWarmup?.value
        XCTAssertEqual(harness.secrets.loads, 1)
        await host.stopRuntime()
    }

    /// #246, the Start's own adoption: an external edit that only respells the PAC URL (see `Respelled`), and a reload the Stop fence
    /// holds. The store has the new bytes, the host view keeps the old ones, and the next Start commits the store's pair and adopts it.
    func testAStartAfterAFenceHeldReloadThatOnlyRespellsThePACURLAdoptsTheNewBytes() async throws {
        let composed = "https://pac.example.test/\(Respelled.composed).pac"
        let decomposed = "https://pac.example.test/\(Respelled.decomposed).pac"
        Respelled.assertRespelling(composed, decomposed)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = false
        config.pacURL = composed
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let host = try await harness.makeHost()

        try await host.startRuntime()
        XCTAssertEqual(host.configGeneration, 0, "a Start that keeps the accepted pair counts nothing")
        await host.stopRuntime()

        config.pacURL = decomposed
        try ProxyConfigPersistence.save(config, in: harness.environment)
        await host.reloadConfiguration()
        let decisions = host.orchestrator.eventLog.events.compactMap { event -> ConfigurationWorkflowEvent? in
            guard case .configWorkflow(let decision) = event.typed else { return nil }
            return decision
        }
        XCTAssertEqual(decisions.last, .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)))
        assertSameUTF8(host.config.pacURL, composed, "the fence held the reload, so the host view keeps the old bytes")
        XCTAssertEqual(host.configGeneration, 0)
        assertSameUTF8(host.orchestrator.config.pacURL, composed, "a held reload pushes nothing")

        try await host.startRuntime()
        // Join the observer deliveries queued by Start before checking the accepted view.
        await host.deliveries.drain()
        assertSameUTF8(host.config.pacURL, decomposed, "the Start adopted the committed bytes into the host view")
        XCTAssertEqual(host.status().configGeneration, 1)
        assertSameUTF8(host.orchestrator.config.pacURL, decomposed, "the Start pushed them to the orchestrator")
        await host.stopRuntime()
    }

    /// The `AppState` scenario of the same name, against its twin. This
    /// used to be a strict expected failure listing what the daemon lacked:
    /// a journal behind its resolver manager, a reconcile pass on a flag
    /// flip, and a stop that clears by ownership. All three came over; the
    /// reload's pass removes the file, and stop has nothing left to do.
    func testStopRemovesAResolverFileTheSwitchNoLongerNamesWhenTheHostWroteIt() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
        try await host.startRuntime()
        XCTAssertEqual(harness.machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53")
        XCTAssertTrue(harness.journal.hasRecords(for: .resolverFile), "the file is recorded as ours")

        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: false), on: host)
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the reload's pass removed it, no stop needed")
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))

        await host.stopRuntime()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"))
    }

    /// Same guard when the flip's own clear did not land: the switch is off,
    /// the flag is left unreconciled, and the journal still names the file.
    /// Stop must remove it anyway, by ownership rather than by the switch.
    func testStopRemovesAResolverFileTheSwitchNoLongerNamesWhenTheJournalOwnsIt() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
        try await host.startRuntime()

        harness.machine.privilege.failingDomains = ["corp.example"]
        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: false), on: host)
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "the removal did not land")
        XCTAssertTrue(harness.journal.hasRecords(for: .resolverFile), "so the file is still recorded as ours")

        harness.machine.privilege.failingDomains = []
        await host.stopRuntime()

        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "stop removed it by ownership")
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
    }

    /// A file for a configured domain that nothing recorded is the user's:
    /// with the switch off, stop leaves it alone.
    func testStopLeavesAResolverFileTheUserWroteWhenTheSwitchIsOff() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageDNSResolvers: false))
        try harness.machine.strandResolverFile(for: "corp.example", contents: "nameserver 192.168.1.1")
        try await host.startRuntime()
        await host.stopRuntime()

        XCTAssertEqual(harness.machine.resolverFile(for: "corp.example"), "nameserver 192.168.1.1")
    }

    /// The system proxy through the whole stack: the start applies it, a
    /// reload with the switch off clears it while the proxy keeps running,
    /// and the journal is released.
    func testASystemProxySwitchFlippedOffOnReloadClearsItWithoutAStop() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        try await host.startRuntime()
        XCTAssertTrue(harness.wifi.routesThroughAProxy)
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "the journal holds the prior state")

        try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: false), on: host)

        XCTAssertFalse(harness.wifi.routesThroughAProxy, "cleared while the proxy keeps running")
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "and the journal was released")
        await host.stopRuntime()
    }

    /// The guard from #13 for the system proxy: the flip's clear was
    /// refused, so the switch is off and the journal still holds the prior.
    /// Stop clears it anyway.
    func testStopClearsASystemProxyTheSwitchNoLongerNamesWhenTheJournalOwnsIt() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        try await host.startRuntime()

        harness.machine.privilege.failing = [.setWebProxyEndpoint]
        try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: false), on: host)
        XCTAssertTrue(harness.wifi.routesThroughAProxy, "the clear did not land")
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "so the records were kept")

        harness.machine.privilege.failing = []
        await host.stopRuntime()

        XCTAssertFalse(harness.wifi.routesThroughAProxy, "stop cleared by ownership, not by the switch")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
    }

    /// Twin of `AppStateHarnessTests.testLaunchRestoresTheProxyACrashedRunLeftBehind`,
    /// seeded the same way: the journal holds the corporate proxy a run
    /// recorded before it applied its own, and the machine still points at
    /// that run's port, 47113, which nothing serves. That is what a `SIGKILL`
    /// with the system proxy applied leaves.
    ///
    /// Without launch recovery the host left Wi-Fi on the dead port until its
    /// next start or stop, and in runtime-host mode it starts nothing. The
    /// start's capture is not where it went wrong: `recordPrior` is
    /// first-write-wins, so the crashed run's record survives a start either
    /// way, and the last assertion holds with or without recovery.
    func testLaunchRestoresTheProxyACrashedRunLeftBehind() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))

        let corporate = ProxyServiceState(
            webHost: "proxy.corp.example", webPort: "8080", webEnabled: true,
            secureHost: "proxy.corp.example", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false,
            bypassDomains: ["*.local"]
        )
        let seeded = harness.journal
        seeded.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: corporate.journalValues)
        seeded.markApplied(surface: .systemProxy)
        harness.machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
            service.bypassDomains = ["localhost"]
        }

        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        XCTAssertEqual(
            harness.wifi.webProxy,
            FakeMachine.ProxyEndpoint(enabled: true, host: "proxy.corp.example", port: "8080"),
            "recovery restores the corporate proxy"
        )
        XCTAssertEqual(harness.wifi.bypassDomains, ["*.local"])
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "restored, so released")
        let recovery = host.orchestrator.eventLog.events.filter { $0.event.hasPrefix("platform.launch_recovery_") }
        XCTAssertEqual(
            recovery.map(\.event),
            ["platform.launch_recovery_nothing_to_do", "platform.launch_recovery_restored", "platform.launch_recovery_adopted"],
            "one event per surface, in recovery's order, as in the app"
        )
        XCTAssertEqual(recovery.map { $0.detail?.split(separator: " ").first }, ["surface=systemDNS", "surface=systemProxy", "surface=resolverFile"])
        XCTAssertEqual(recovery.dropFirst().first?.detail, "surface=systemProxy stale=false")

        try await host.startRuntime()
        XCTAssertEqual(harness.wifi.webProxy, FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "0"))
        guard case .wasPresent(let prior) = harness.journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("the start recorded a prior for Wi-Fi")
        }
        XCTAssertEqual(
            ProxyServiceState(journalValues: prior).webHost,
            "proxy.corp.example",
            "the prior the start captured is the user's proxy, not the crashed run's port"
        )

        await host.stopRuntime()
        XCTAssertEqual(
            harness.wifi.webProxy,
            FakeMachine.ProxyEndpoint(enabled: true, host: "proxy.corp.example", port: "8080"),
            "and the stop hands it back"
        )
    }

    /// Twin of `AppStateHarnessTests.testAJournalFromANewerConduitIsReportedAndKeptAtLaunch`.
    func testAJournalFromANewerConduitIsReportedAndKeptAtLaunch() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        try newer.write(to: harness.environment.platformStateFile)

        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        XCTAssertEqual(
            host.orchestrator.eventLog.events.filter { $0.event == "platform.journal_unreadable" }.map(\.detail),
            ["file=platform-state.json reason=unsupported_version version=2 supported=1"]
        )
        XCTAssertEqual(try Data(contentsOf: harness.environment.platformStateFile), newer)
    }

    /// The broken-config path builds its own journal, and reports through
    /// the same `emit` that writes `events.ndjson`.
    func testRecoveryWithoutConfigurationReportsAJournalFromANewerConduit() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        try newer.write(to: harness.environment.platformStateFile)

        let machine = harness.machine
        let events = await RuntimeHost.recoverWithoutConfiguration(
            stateSession: harness.stateSession,
            logger: DiscardingLogSink(),
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: harness.homeDirectory, resolverDirectory: machine.resolverDirectory.path
            )
        )

        XCTAssertEqual(events.filter { $0.event == "platform.journal_unreadable" }.count, 1)
        let written = try String(contentsOf: harness.environment.eventsFile, encoding: .utf8)
        XCTAssertTrue(written.contains("platform.journal_unreadable"), "the event reaches events.ndjson: \(written)")
        XCTAssertEqual(try Data(contentsOf: harness.environment.platformStateFile), newer)
    }

    /// The broken-config recovery writes its events through the adopted guard. An events alias of the lease is refused
    /// into the returned events, and the lock keeps its bytes, its inode and its holder.
    func testRecoveryWithoutConfigurationRefusesAnEventsAliasOfTheWriterLease() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let lease = harness.stateSession.writerLeaseFile
        let before = try writerLeaseFingerprint(lease)
        XCTAssertEqual(link(lease.path, harness.environment.eventsFile.path), 0)

        let machine = harness.machine
        let events = await RuntimeHost.recoverWithoutConfiguration(
            stateSession: harness.stateSession,
            logger: DiscardingLogSink(),
            effects: hostEffects(loopbackPortProbe: FakeLoopbackPortProbe(), pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: harness.homeDirectory, resolverDirectory: machine.resolverDirectory.path
            )
        )

        XCTAssertEqual(
            events.filter { $0.event == RecordFileDestinationGate.eventName }.map(\.detail),
            ["sink=events reason=protected_identity resource=writer_lease"]
        )
        XCTAssertEqual(try writerLeaseFingerprint(lease), before, "the lock keeps its bytes and its inode")
        assertSecondWriterIsBusy(harness.environment)
    }

    /// The host's events writer refuses an alias of the lease through its own log. The readiness flush joins every writer
    /// before the lock is checked, so the refusal and the lock's state are both settled.
    func testAnEventsAliasOfTheWriterLeaseIsRefusedByTheHostAndTheLeaseKeepsItsAuthority() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let lease = harness.stateSession.writerLeaseFile
        let before = try writerLeaseFingerprint(lease)
        XCTAssertEqual(link(lease.path, harness.environment.eventsFile.path), 0)

        let host = try await harness.makeHost()
        await host.markReady(mode: "runtime-host")
        await host.flushEvents()

        XCTAssertEqual(
            host.orchestrator.eventLog.events.filter { $0.event == RecordFileDestinationGate.eventName }.map(\.detail),
            ["sink=events reason=protected_identity resource=writer_lease"]
        )
        XCTAssertEqual(try writerLeaseFingerprint(lease), before, "the lock keeps its bytes and its inode")
        assertSecondWriterIsBusy(harness.environment)
    }

    /// The host's snapshot writer refuses an alias of the lease the same way. Readiness writes the snapshot, and the flush
    /// joins that write before the lock is checked.
    func testASnapshotAliasOfTheWriterLeaseIsRefusedByTheHostAndTheLeaseKeepsItsAuthority() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let lease = harness.stateSession.writerLeaseFile
        let before = try writerLeaseFingerprint(lease)
        XCTAssertEqual(link(lease.path, harness.environment.snapshotFile.path), 0)

        let host = try await harness.makeHost()
        await host.markReady(mode: "runtime-host")
        await host.flushEvents()

        XCTAssertEqual(
            host.orchestrator.eventLog.events.filter { $0.event == RecordFileDestinationGate.eventName }.map(\.detail),
            ["sink=snapshot reason=protected_identity resource=writer_lease"]
        )
        XCTAssertEqual(try writerLeaseFingerprint(lease), before, "the lock keeps its bytes and its inode")
        assertSecondWriterIsBusy(harness.environment)
    }

    /// Readiness never precedes recovery. `daemon.ready` and
    /// `daemon-ready.json` tell a consumer startup is over; published while
    /// recovery was still out, they announced a machine that could still be
    /// pointed at a crashed run's dead proxy port.
    func testReadinessIsPublishedOnlyAfterLaunchRecovery() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        seedCrashedRunProxy()

        let host = try await harness.makeHost()
        await host.markReady(mode: "runtime-host")

        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "restored by the time readiness is published")
        XCTAssertEqual(harness.listenerProbe.lastAsked, 47113, "the stale-listener check asked the injected probe about the recorded port")
        let names = host.orchestrator.eventLog.events.map(\.event)
        let ready = try XCTUnwrap(names.firstIndex(of: "daemon.ready"))
        let restored = try XCTUnwrap(names.firstIndex(of: "platform.launch_recovery_restored"))
        XCTAssertLessThan(restored, ready, "recovery's events come first: \(names)")
    }

    /// A stop admitted while a start is suspended before its listener binds. The stop finds no listener, the start then binds one, and the
    /// stop has already run. The stopped host must not be left running a listener. The start is held on a PAC fetch, which the kernel awaits
    /// before `localProxyServer.start()`, so this reaches the window with no new seam.
    func testAStopAdmittedBeforeTheBindLeavesNoListenerRunning() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.pacURL = "https://pac.example.test/held.pac"
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let fetch = HeldPACFetch()
        harness.pacEvaluator = fetch
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        let start = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where !fetch.isHeld {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(fetch.isHeld, "the start is suspended before its listener binds")

        await host.stopRuntime()
        fetch.release()
        await assertSuperseded(start, "the stop overtook the start")

        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "a stopped host runs no listener")
        XCTAssertNil(host.orchestrator.snapshot.bindings.proxyPort, "no listener stayed bound after the stop")
    }

    /// A stop, then a newer start, while the first start is held before its bind. The newer start has an unchanged config, so it queues no
    /// reconcile pass and does not wait on the older start's lane token. Its listener is published, and then the older start is released.
    /// That older start is superseded, so it binds nothing and cleans up nothing: the newer listener must survive, and the stop must not have
    /// closed the newer start's listener. The system proxy is managed, and the surface names the configured port, so the port is a free one
    /// the newer listener binds: the stale start must not clear the newer start's surface either.
    func testAStaleStartReleasedAfterANewerStartLeavesTheNewerListenerRunning() async throws {
        let configured = try reserveLoopbackPort()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = configured
        config.dnsForwarderPort = 0
        config.pacURL = "https://pac.example.test/held.pac"
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let fetch = HeldPACFetch()
        harness.pacEvaluator = fetch
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        let older = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where !fetch.isHeld {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(fetch.isHeld, "the older start is suspended before its listener binds")
        await host.stopRuntime()

        // The newer start joins the same PAC refresh the older one holds: the engine coalesces refreshes. So it cannot finish until the gate
        // opens, and awaiting it first would wait on the gate this test has not yet released. It is started, and admitted (the kernel publishes
        // `starting` at admission), before the gate opens. Every task is awaited after the release.
        let newer = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where host.orchestrator.snapshot.runtimeStatus.state != .starting {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .starting, "the newer start is admitted behind the held refresh")

        fetch.release()
        // Each task's outcome is read on its own, so a failure names the start that threw and what the kernel reported then.
        if case .failure(let error) = await newer.result {
            XCTFail("the newer start threw \(error); state=\(host.orchestrator.snapshot.runtimeStatus.state) proxyError=\(host.orchestrator.snapshot.proxyError ?? "none")")
        }
        let listenerPort = host.orchestrator.snapshot.bindings.proxyPort
        XCTAssertNotNil(listenerPort, "the newer start binds a listener")
        XCTAssertEqual(listenerPort, configured, "on the configured port")
        await assertSuperseded(older, "the stop and the newer start overtook the older start")

        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the released stale start does not overwrite the newer one")
        XCTAssertEqual(host.orchestrator.snapshot.bindings.proxyPort, listenerPort, "the stale start neither binds nor closes the newer listener")
        // Every lane is idle, so no platform work of either start is still out when the machine is read.
        await host.awaitLifecycleIdle()
        XCTAssertTrue(host.lanesIdle)
        XCTAssertEqual(harness.wifi.webProxy, FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: String(configured)),
                       "the newer start's system proxy survives the stale start, and names its listener")
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "the journal holds the prior state the newer start captured")
        await host.stopRuntime()
        await host.awaitLifecycleIdle()
        XCTAssertNil(host.orchestrator.snapshot.bindings.proxyPort, "a final stop closes the listener")
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "and clears the system proxy")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "and releases the surface it restored")
    }

    /// The journal and machine a crashed run leaves: the prior proxy recorded and applied, and the machine still pointed at a dead loopback
    /// proxy. Launch recovery restores the prior settings from it.
    private func seedCrashedRunProxy() {
        let prior = ProxyServiceState(
            webHost: "prior.example.test", webPort: "8080", webEnabled: true,
            secureHost: "prior.example.test", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false, bypassDomains: ["*.local"]
        )
        let seeded = harness.journal
        seeded.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: prior.journalValues)
        seeded.markApplied(surface: .systemProxy)
        harness.machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
        }
    }

    /// A host built over the crashed-run seed, with launch recovery held on its first `networksetup` listing. Recovery is in flight until
    /// the test releases the hold, so whatever the test admits now waits behind it. The hold is armed before the host exists, because the
    /// host starts recovery as it is built, on a detached utility task (not the platform queue).
    private func makeHostWithHeldRecovery(terminalExit: @escaping @MainActor () -> Void) async throws -> RuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        seedCrashedRunProxy()
        harness.terminalExit = terminalExit
        harness.hold.arm { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        return try await harness.makeHost()
    }

    /// A Start a Stop, a newer Start or a replaced input overtook reports the typed refusal, never success.
    private func assertSuperseded(
        _ start: Task<Void, Error>,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await start.value
            XCTFail("\(message): the overtaken start reported success", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RuntimeStartRefusal, .superseded, message, file: file, line: line)
        }
    }

    /// Waits, bounded, until the host has admitted exactly `count` start or stop calls that have not yet returned.
    private func waitForPendingAdmissions(_ host: RuntimeHost, _ count: Int) async throws {
        for _ in 0..<5_000 where host.pendingAdmissions != count {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.pendingAdmissions, count, "the calls reached admission while recovery is held")
    }

    /// A start admitted during held recovery, then a stop: the stop is the newer intent, so the start stops without applying anything,
    /// and the stop finds nothing running. Both are admitted before recovery finishes.
    func testAStartThenAStopAdmittedDuringRecoveryLeavesTheRuntimeDownAndAppliesNothing() async throws {
        let host = try await makeHostWithHeldRecovery(terminalExit: unexpectedTerminalExit)
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        try await waitForPendingAdmissions(host, 1)
        let stop = Task { await host.stopRuntime() }
        try await waitForPendingAdmissions(host, 2)
        XCTAssertEqual(host.lifecycleGeneration, 0, "neither call has reached the lane while recovery is held")

        harness.hold.release()
        await assertSuperseded(start, "the stop admitted during recovery overtook the start")
        await stop.value

        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "the machine keeps the prior proxy recovery restored, not the start's listener")
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.superseded(ConfigurationWorkflowSuperseded(
                phase: .start, generation: 1, current: 2
            )))),
            "the start reports it was superseded by the stop"
        )
        XCTAssertEqual(host.pendingAdmissions, 0)
    }

    /// A stop admitted during held recovery, then a start: the start is the newer intent, so the stop does nothing and the start runs.
    func testAStopThenAStartAdmittedDuringRecoveryLeavesTheStartRunning() async throws {
        let host = try await makeHostWithHeldRecovery(terminalExit: unexpectedTerminalExit)
        let stop = Task { await host.stopRuntime() }
        await harness.hold.waitUntilReached()
        try await waitForPendingAdmissions(host, 1)
        let start = Task { try await host.startRuntime() }
        try await waitForPendingAdmissions(host, 2)

        harness.hold.release()
        await stop.value
        try await start.value

        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.wifi.routesThroughAProxy, "the newer start applied the proxy")
        XCTAssertEqual(host.lifecycleGeneration, 1, "only the start reached the lane; the older stop did nothing")
        await host.stopRuntime()
    }

    /// A terminal stop admitted during held recovery latches the refusal while recovery is still out: a start called then is refused as
    /// terminating, admits nothing, and the terminal stop exits exactly once after recovery.
    func testAStartIsRefusedDuringAHeldTerminalStopAndTheTerminalStopExitsOnce() async throws {
        var exits = 0
        let host = try await makeHostWithHeldRecovery(terminalExit: { exits += 1 })
        let stop = Task { await host.stopRuntime(exitAfterStop: true) }
        await harness.hold.waitUntilReached()
        try await waitForPendingAdmissions(host, 1)

        do {
            try await host.startRuntime()
            XCTFail("a start while the terminal stop is held must be refused")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .terminated)
        }
        XCTAssertEqual(host.pendingAdmissions, 1, "the refused start admitted nothing")
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                phase: .start, input: .unit, reason: .terminating
            )))),
            "the refusal names its own reason, not an exhausted intent"
        )

        harness.hold.release()
        await stop.value
        XCTAssertEqual(exits, 1, "the terminal stop exits once, after recovery")
        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "no start ran, so the restored prior proxy is all there is")
    }

    /// A start admitted before recovery finishes counts as pending: settle does not report the host settled while that admission is still
    /// waiting, and once the runtime has run and stopped, settle reports it.
    func testASettleIsNotSettledWhileAnAdmittedStartWaitsForRecovery() async throws {
        let host = try await makeHostWithHeldRecovery(terminalExit: unexpectedTerminalExit)
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        try await waitForPendingAdmissions(host, 1)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let whileWaiting = await host.settleStoppedEffects(until: deadline)
        XCTAssertEqual(whileWaiting, .runtimeActive, "an admitted start is not a settled host")

        harness.hold.release()
        try await start.value
        await host.stopRuntime()
        let afterStop = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(afterStop, .settled)
    }

    /// A reload whose pass is queued behind a held start keeps a settle from reporting settled. The pass is in flight, but the start and
    /// the reload are calls still pending and the lane is busy, and `stoppedEffectsPending` answers those before a pass in flight, so the
    /// answer is `runtimeActive`. `reconcilePending` is left for a pass in flight once no call is pending and the runtime is down.
    func testASettleIsNotSettledWhileAReloadPassWaitsBehindAHeldStart() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        await host.awaitLaunchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()

        let harness = self.harness!
        let reload = Task {
            try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true), on: host)
        }
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.passesWaitingForLifecycle, 1, "the reload's pass waits behind the start")
        let whileWaiting = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(whileWaiting, .runtimeActive, "a queued pass and a running start are not a settled host")

        harness.hold.release()
        // The reload replaced the platform file the start captured, so the start holds the rest of its work (decision 0037).
        await assertSuperseded(start, "the reload replaced the start's captured input")
        try await reload.value
        await host.stopRuntime()
        let afterStop = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertEqual(afterStop, .settled)
    }

    /// Twin of `AppStateHarnessTests.testCorruptConfigStillRestoresJournaledProxyOnLaunch`.
    /// The daemon builds no host from a failed load, so `ConduitDaemon.main`
    /// runs the journal restores through `recoverWithoutConfiguration` before
    /// it exits; this drives that function over the same crashed-run seed.
    /// Only the resolver scan needs the config, so it alone is skipped.
    func testABrokenConfigStillRestoresTheJournaledProxyBeforeExiting() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let prior = ProxyServiceState(
            webHost: "prior.example.test", webPort: "8080", webEnabled: true,
            secureHost: "prior.example.test", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false, bypassDomains: ["*.local"]
        )
        let seeded = harness.journal
        seeded.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: prior.journalValues)
        seeded.markApplied(surface: .systemProxy)
        harness.machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
        }
        try Data("{".utf8).write(to: harness.environment.configFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadAllMigrating(in: harness.environment), "the load main rejects")

        let machine = harness.machine
        let events = await RuntimeHost.recoverWithoutConfiguration(
            stateSession: harness.stateSession,
            logger: DiscardingLogSink(),
            effects: hostEffects(loopbackPortProbe: harness.listenerProbe, pacEvaluator: FakePacEvaluator(),
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(), commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
                networkPath: FakeNetworkPathObserver(), networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil }, vpnStatus: FakeVPNStatusObserver(),
                dnsResponds: FakeDNSProbe().responds(onPort:),
                homeDirectory: harness.homeDirectory, resolverDirectory: machine.resolverDirectory.path
            )
        )

        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "journal recovery proceeds despite the broken file")
        XCTAssertEqual(harness.wifi.bypassDomains, ["*.local"])
        // The stale-listener check asked the injected probe about the port the machine was pointed at, and no real port was touched.
        XCTAssertEqual(harness.listenerProbe.lastAsked, 47113)
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        let expected = ["surface=systemDNS reason=nothing_recorded", "surface=systemProxy stale=false", "surface=resolverFile reason=config_unavailable"]
        XCTAssertEqual(events.filter { $0.event.hasPrefix("platform.launch_recovery_") }.map(\.detail), expected)
        let written = try String(contentsOf: harness.environment.eventsFile, encoding: .utf8)
        XCTAssertTrue(written.contains("platform.launch_recovery_restored"), "the events reach events.ndjson: \(written)")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), Data("{".utf8), "the broken file is left for the user")
    }

    /// Twin of `AppStateHarnessTests.testAFailedLivenessProbeRestartsTheRelayOffTheMainThread`.
    func testAFailedLivenessProbeRestartsTheRelayOffTheMainThread() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        try await host.startRuntime()
        let privilege = harness.machine.privilege
        XCTAssertTrue(harness.machine.dnsRelayRunning, "system DNS came up through the relay")
        let startsBefore = privilege.commands(matching: .startDNSRelay).count
        let onMainBefore = privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count

        let token = host.lanes.dns.observationToken
        host.handleDNSHealthResult(alive: false, forwarderPort: 5353, armedBy: token)
        host.handleDNSHealthResult(alive: false, forwarderPort: 5353, armedBy: token)
        await host.deliveries.drain()

        XCTAssertEqual(privilege.commands(matching: .startDNSRelay).count, startsBefore + 1, "one restart for the two ticks")
        XCTAssertEqual(privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count, onMainBefore)
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testARelayRestartThatFindsSystemDNSReleasedStartsNothing`.
    func testARelayRestartThatFindsSystemDNSReleasedStartsNothing() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        try await host.startRuntime()
        await host.stopRuntime()
        let privilege = harness.machine.privilege
        let startsBefore = privilege.commands(matching: .startDNSRelay).count

        host.handleDNSHealthResult(alive: false, forwarderPort: 5353, armedBy: host.lanes.dns.observationToken)
        await host.deliveries.drain()

        XCTAssertEqual(privilege.commands(matching: .startDNSRelay).count, startsBefore)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
    }

    /// Every VPN and path notification is its own delivery, and each used to
    /// put a reconcile on the platform work queue. While a helper is held
    /// they would pile up there and drain later as so many stale passes.
    func testSystemDNSReconcilesCoalesceWhileOneIsOut() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        try await host.startRuntime()

        harness.listings.arm()
        harness.vpn.emit(.connected)
        for _ in 0..<2_000 where !harness.listings.isHoldingOne {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(harness.listings.isHoldingOne, "the first reconcile is out, reading the machine")
        for state in [VPNObservedState.reasserting, .connected, .reasserting, .connected] {
            harness.vpn.emit(state)
        }
        // The four handlers reach the gate behind the pass that is out and
        // return, which leaves that pass's delivery as the only one in flight.
        for _ in 0..<5_000 where host.deliveries.inFlightCount != 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.deliveries.inFlightCount, 1)
        let listingsPerPass = 2
        harness.listings.release()
        await host.deliveries.drain()

        XCTAssertEqual(
            harness.listings.count,
            2 * listingsPerPass,
            "the pass that was out and one more for the four that arrived meanwhile"
        )
        await host.stopRuntime()
    }

    // MARK: - Start and stop off the main actor (#47)

    /// Twin of `AppStateHarnessTests.testProxyAndDNSStartAndStopWaitOnTheHelperOffTheMainThread`:
    /// every privileged write a start and a stop make, system DNS included,
    /// is asked for from the platform work queue.
    func testStartAndStopWaitOnTheHelperOffTheMainThread() async throws {
        let host = try await launch(
            platform: PlatformIntegrationConfig(
                manageSystemProxy: true,
                manageEnvironmentVariables: true,
                manageDNSResolvers: true,
                manageSystemDNS: true
            ),
            dnsForwarderEnabled: true
        )
        let privilege = harness.machine.privilege

        try await host.startRuntime()
        XCTAssertTrue(harness.wifi.routesThroughAProxy)
        XCTAssertTrue(harness.machine.dnsRelayRunning)
        await host.stopRuntime()
        XCTAssertFalse(harness.wifi.routesThroughAProxy)
        XCTAssertFalse(harness.machine.dnsRelayRunning)

        let asked = Set(privilege.commands.map(\.command))
        XCTAssertTrue(
            asked.isSuperset(of: [.applySystemProxy, .setDNSServers, .startDNSRelay, .stopDNSRelay, .setWebProxyEndpoint]),
            "the start and the stop reached the helper: \(asked)"
        )
        XCTAssertEqual(privilege.mainThreadOperations, [], "and none of it from the main thread")
    }

    /// Twin of `AppStateHarnessTests.testAStopIssuedWhileTheStartAppliesLandsLastAndTheStartGoesNoFurther`.
    /// The start's surface work is held on the queue; a stop issued then
    /// queues its clears behind it. Released, the apply lands and the clear
    /// lands after it, and the start, overtaken, starts nothing more: the
    /// monitors it would start are what put resolver files back on the next
    /// VPN transition.
    func testAStopIssuedWhileTheStartAppliesLandsLastAndTheStartGoesNoFurther() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        await host.awaitLaunchRecovery()
        // The start's first read of the machine, once its listeners are up.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }

        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the start's surface work is off the main thread")
        let stop = Task { await host.stopRuntime() }
        for _ in 0..<5_000 where host.lifecycleGeneration < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.lifecycleGeneration, 2, "the stop has begun")
        harness.hold.release()
        await assertSuperseded(start, "the stop overtook the applying start")
        await stop.value

        XCTAssertFalse(harness.wifi.routesThroughAProxy, "the stop's clear landed after the start's apply")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .stopped)
        XCTAssertEqual(
            host.orchestrator.eventLog.events.supersededValues,
            [LifecycleSuperseded(operation: .runtimeStart, generation: 1, current: 2, reason: .superseded)]
        )
        XCTAssertEqual(
            host.orchestrator.eventLog.events.filter { $0.event == "lifecycle.superseded" }.map(\.detail),
            ["operation=runtime_start generation=1 current=2 reason=superseded"],
            "golden: the human line operators read"
        )

        // The overtaken start never started the VPN monitor, so a transition
        // now reaches nothing.
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertNotEqual(host.orchestrator.snapshot.vpnState, .connected)
    }

    /// Was the twin of `AppStateHarnessTests.testASettingsChangeWhileTheStartAppliesIsReconciledAfterIt`, which keeps the legacy
    /// behavior until AppState activates the shared owner. Decision 0037 changes it here: a reload that replaces the start's captured
    /// pair while the start applies holds the rest of the start, which ends as failed and clears what it applied. It is not rebound to the
    /// reloaded input, and the reload's own pass, admitted under the ended start, applies nothing.
    func testAReloadReplacingTheInputWhileTheStartAppliesHoldsTheRestOfTheStart() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
        await host.awaitLaunchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)

        let reloaded = LockedCount()
        let harness = self.harness!
        let reload = Task {
            try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: false), on: host)
            reloaded.set(1)
        }
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 && reloaded.value != 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.passesWaitingForLifecycle, 1, "the reload's pass waits for the start's platform work")
        harness.hold.release()
        await assertSuperseded(start, "the reload replaced the start's captured input")
        try await reload.value

        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the held start left no runtime running")
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "and cleared the proxy it applied")
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                phase: .start, input: .unit, reason: .inputReplaced
            )))),
            "the start reports the replaced input"
        )
        await host.stopRuntime()
    }

    /// A second identical Start while the first applies joins it on the lane. Its admission ends the first Start's group in the workflow,
    /// but the lane still orders the first Start, which finishes for both; the joiner then settles its own authorized group with that result.
    func testAnIdenticalStartThatJoinsTheOneApplyingReportsItsSuccess() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
        await host.awaitLaunchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let first = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        let second = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where !host.orchestrator.eventLog.events.contains(where: { $0.event == "lifecycle.coalesced" }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(host.orchestrator.eventLog.events.contains { $0.event == "lifecycle.coalesced" }, "the second start joined the first")
        harness.hold.release()
        if case .failure(let error) = await first.result { XCTFail("the first start threw \(error)") }
        if case .failure(let error) = await second.result { XCTFail("the joining start threw \(error)") }
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.wifi.routesThroughAProxy, "the first start applied its surfaces for both")
        let settled = host.orchestrator.eventLog.events.settledValues
        XCTAssertEqual(settled.map(\.settlement.module), [.proxy, .dns, .tunnels],
                       "the joined effect records each member once, and the joiner records none of its own")
        XCTAssertEqual(Set(settled.map(\.group)), [host.workflow.generation], "under the joiner's group, which adopted the effect")
        await host.stopRuntime()
        XCTAssertFalse(harness.wifi.routesThroughAProxy)
    }

    /// A newer Start that ends an authorized Start's group and then holds before the lane (its store slot is busy) leaves no authority.
    /// The older Start still holds the lane and its receipts, but the owner check stops it at its next step and it tears down what it
    /// activated: nothing is left running and no permission is resurrected.
    func testANewerStartHeldBeforeTheLaneEndsTheAuthorizedStartItSuperseded() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
        await host.awaitLaunchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let older = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()

        // An unchanged reload parks in the store, so the store's one slot is busy and the receipts stay as they are.
        harness.stateFiles.armRead()
        let reload = Task { await host.reloadConfiguration() }
        let parked = await harness.stateFiles.waitUntilParked()
        XCTAssertTrue(parked, "the reload holds the store's slot")
        let newer = Task { try await host.startRuntime() }
        do {
            try await newer.value
            XCTFail("the newer start found the store busy, so it does not start")
        } catch {
            XCTAssertEqual(error as? RuntimeStartRefusal, .held, "the newer start holds before the lane")
        }
        harness.stateFiles.release()
        _ = await reload.value

        harness.hold.release()
        await assertSuperseded(older, "the newer admission ended the older start's group")
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "no activation outlives its authority")
        XCTAssertNil(host.orchestrator.snapshot.bindings.proxyPort)
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "the older start cleared the system proxy it applied")
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                phase: .start, input: .unit, reason: .storeBusy
            )))),
            "the newer start reports the busy store"
        )
        // A later Start is admitted normally: nothing was left fenced or authorized.
        try await host.startRuntime()
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        await host.stopRuntime()
    }

    /// Decision 0035's scoped cleanup: a held Start tears down only the modules it owns. A second Start over a running proxy owns no proxy,
    /// so when a reload replaces its captured input while it reapplies, the running listener and its system proxy stay as they were.
    func testAHeldStartOverARunningProxyLeavesTheRunningProxyUp() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
        try await host.startRuntime()
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.wifi.routesThroughAProxy)
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()

        let reloaded = LockedCount()
        let harness = self.harness!
        let reload = Task {
            try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: false), on: host)
            reloaded.set(1)
        }
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 && reloaded.value != 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.passesWaitingForLifecycle, 1, "the reload's pass waits for the start's platform work")
        harness.hold.release()
        await assertSuperseded(start, "the reload replaced the second start's captured input")
        try await reload.value

        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the held start owned no proxy, so it stopped none")
        XCTAssertTrue(harness.wifi.routesThroughAProxy, "and cleared no system proxy")
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                phase: .start, input: .unit, reason: .inputReplaced
            )))),
            "the start reports the replaced input"
        )
        // The observers follow the modules that stay up, so the VPN monitor still reaches the running proxy.
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .connected, "the held start left the runtime's observers running")
        await host.stopRuntime()
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "a Stop still owns every module")
    }

    /// A start whose bind fails while a reload's pass waits behind its lane. The start reverts under its own token and the pass then finds its
    /// admission ended, so nothing waits on the other and no surface is written after the failure.
    func testAFailedStartWithAReloadPassQueuedBehindItDoesNotDeadlock() async throws {
        let held = try HeldLoopbackPort()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = held.port
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        // The bind retries for seconds on the held port, so the start holds the lane long enough for a reload to queue behind it.
        let start = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where host.lifecycleGeneration == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.lifecycleGeneration, 1, "the start holds the lane while its bind retries")

        let harness = self.harness!
        let reload = Task {
            try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true), on: host)
        }
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.passesWaitingForLifecycle, 1, "the reload's pass waits behind the start")

        // Bounded: the start gives up after its bind retries, and must return on its own, not wait on the pass.
        let finished = LockedCount()
        let watcher = Task {
            _ = await start.result
            finished.set(1)
        }
        for _ in 0..<3_000 where finished.value != 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(finished.value, 1, "the failed start returned: nothing waits on the lane it held")
        guard finished.value == 1 else { return }
        if case .failure = await start.result {} else { XCTFail("the bind on the held port must fail the start") }
        try await reload.value
        await watcher.value

        XCTAssertEqual(host.passesWaitingForLifecycle, 0)
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "the failed start left no system proxy behind")
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"], "the reload's pass acted on nothing after the start failed")
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        withExtendedLifetime(held) {}
    }

    /// A terminal stop latches: a Start after it is refused as terminating, not as an exhausted intent, and it applies nothing.
    func testAStartAfterATerminalStopIsRefusedAsTerminating() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        harness.terminalExit = {}
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()

        await host.stopRuntime(exitAfterStop: true)
        do {
            try await host.startRuntime()
            XCTFail("a Start after a terminal stop must be refused")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .terminated)
        }
        XCTAssertTrue(
            host.orchestrator.eventLog.events.compactMap(\.typed).contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                phase: .start, input: .unit, reason: .terminating
            )))),
            "the refusal names its own reason, not an exhausted intent"
        )
        XCTAssertFalse(harness.wifi.routesThroughAProxy)
    }

    /// A stop issued while a reload's surface re-apply is out waits for that re-apply, then clears what it left.
    func testAStopWaitsForAnInFlightSurfaceReapplyAndThenClears() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .manual))
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        XCTAssertTrue(harness.wifi.routesThroughAProxy)

        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        var edited = host.config
        edited.noProxyHosts.append("bypass.example")
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        let reload = Task { await host.reloadConfiguration() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)

        let stopped = LockedCount()
        let stop = Task {
            await host.stopRuntime()
            stopped.set(1)
        }
        for _ in 0..<5_000 where host.lifecycleGeneration < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.lifecycleGeneration, 2, "the stop is admitted")
        XCTAssertNotEqual(stopped.value, 1, "the stop waits for the re-apply that is out")

        harness.hold.release()
        _ = await reload.value
        await stop.value
        XCTAssertFalse(harness.wifi.routesThroughAProxy, "the stop's clear landed after the re-apply")
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .stopped)
    }

    /// Twin of `AppStateHarnessTests.testABypassEditReachesTheAdvertisedSurfacesInManualMode`.
    func testABypassReloadReachesTheAdvertisedSurfacesInManualMode() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(
            manageSystemProxy: true, manageEnvironmentVariables: true, systemProxyMode: .manual))
        await host.awaitLaunchRecovery()
        try await host.startRuntime()

        var edited = host.config
        edited.noProxyHosts.append("bypass.example")
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()

        XCTAssertTrue(harness.machine.launchdEnvironment["NO_PROXY"]?.contains("bypass.example") == true)
        XCTAssertTrue(harness.wifi.bypassDomains.contains("bypass.example"))
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "config.advertised_bypass_changed" }.map(\.detail),
                       ["surfaces=environment,system_proxy"])
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testALocalPACPortEditRepointsTheSystemProxy`.
    func testALocalPACPortReloadRepointsTheSystemProxy() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac))
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        XCTAssertEqual(harness.wifi.autoproxyURL, host.orchestrator.snapshot.bindings.localPACURL)

        let port = try reserveLoopbackPort()
        var edited = host.config
        edited.localPACPort = port
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()

        XCTAssertEqual(host.orchestrator.snapshot.bindings.localPACPort, port)
        XCTAssertEqual(harness.wifi.autoproxyURL, host.orchestrator.snapshot.bindings.localPACURL)
        XCTAssertTrue(harness.wifi.autoproxyURL.contains(":\(port)/"))
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "config.advertised_pac_changed" }.map(\.detail),
                       ["surfaces=system_proxy"])
        await host.stopRuntime()
    }

    private func reapplyEvents(_ host: RuntimeHost) -> [String] {
        host.orchestrator.eventLog.events.filter { $0.event.hasPrefix("config.reapply_") }.map { "\($0.event) \($0.detail ?? "")" }
    }

    private static let shortRetries = ConfigReapplyRetry.Schedule(delays: [.milliseconds(100), .milliseconds(100), .milliseconds(100)])

    /// Twin of `AppStateHarnessTests.testAFailedSystemProxyReapplyIsReportedAndRetried`.
    func testAFailedSystemProxyReapplyOnReloadIsReportedAndRetried() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        harness.reapplyRetrySchedule = Self.shortRetries
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let port = try reserveLoopbackPort()

        locations.refuseWrites(true)
        var edited = host.config
        edited.localPort = port
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()
        XCTAssertNotEqual(try locations.snapshot().services[0].proxies["HTTPPort"], .number(port))
        let failed = try XCTUnwrap(reapplyEvents(host).first)
        XCTAssertTrue(failed.hasPrefix("config.reapply_failed surface=system_proxy cause=config_change retry_in_seconds=1 attempts=3 reason="), failed)

        locations.refuseWrites(false)
        await host.reapplyRetry.drain()

        XCTAssertEqual(try locations.snapshot().services[0].proxies["HTTPPort"], .number(port))
        let events = reapplyEvents(host)
        XCTAssertEqual(events.filter { $0.hasPrefix("config.reapply_recovered surface=system_proxy") }.count, 1, "\(events)")
        XCTAssertFalse(events.contains { $0.hasPrefix("config.reapply_abandoned") }, "\(events)")
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testASystemProxySwitchThatFailsToApplyIsRetried`.
    func testASystemProxySwitchThatFailsToApplyOnReloadIsRetried() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = try reserveLoopbackPort()
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        harness.reapplyRetrySchedule = Self.shortRetries
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let port = config.localPort

        locations.refuseWrites(true)
        try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true), on: host)
        XCTAssertEqual(reapplyEvents(host).first?.hasPrefix("config.reapply_failed surface=system_proxy cause=switch_on"), true,
                       "\(reapplyEvents(host))")

        locations.refuseWrites(false)
        await host.reapplyRetry.drain()

        XCTAssertEqual(try locations.snapshot().services[0].proxies["HTTPPort"], .number(port))
        XCTAssertEqual(reapplyEvents(host).filter { $0.hasPrefix("config.reapply_recovered surface=system_proxy") }.count, 1,
                       "\(reapplyEvents(host))")
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testAFailedSystemProxyModeChangeIsReportedAsOne`.
    func testAFailedSystemProxyModeChangeOnReloadIsReportedAsOne() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .manual))
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()

        locations.refuseWrites(true)
        try await harness.flip(PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac), on: host)

        XCTAssertEqual(reapplyEvents(host).first?.hasPrefix("config.reapply_failed surface=system_proxy cause=mode_change"), true,
                       "\(reapplyEvents(host))")
        locations.refuseWrites(false)
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testAPartialEnvironmentReapplyIsReportedAndRetried`
    /// and `…RecoversOnTheRetry`.
    func testAPartialEnvironmentReapplyOnReloadIsReportedAndRetried() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageEnvironmentVariables: true))
        harness.reapplyRetrySchedule = Self.shortRetries
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let port = try reserveLoopbackPort()

        harness.machine.failingSetenv = ["HTTP_PROXY"]
        var edited = host.config
        edited.localPort = port
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()
        XCTAssertEqual(reapplyEvents(host).first,
                       "config.reapply_failed surface=environment cause=config_change retry_in_seconds=1 attempts=3 "
                           + "reason=partial profiles_left= launchd_left=HTTP_PROXY")

        harness.machine.failingSetenv = []
        await host.reapplyRetry.drain()

        XCTAssertEqual(harness.machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:\(port)")
        let events = reapplyEvents(host)
        XCTAssertEqual(events.filter { $0.hasPrefix("config.reapply_recovered surface=environment") }.count, 1, "\(events)")
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testAStopAfterAFailedReapplyAbandonsTheRetry`.
    func testAStopAfterAFailedReloadReapplyAbandonsTheRetry() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        harness.reapplyRetrySchedule = Self.shortRetries
        let locations = NetworkLocationFixture.store()
        harness.locationStore = locations
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()

        locations.refuseWrites(true)
        var edited = host.config
        edited.localPort = try reserveLoopbackPort()
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()
        locations.refuseWrites(false)
        await host.stopRuntime()
        let afterStop = try locations.snapshot().services[0].proxies
        await host.reapplyRetry.drain()

        XCTAssertEqual(try locations.snapshot().services[0].proxies, afterStop, "nothing written after the stop")
        XCTAssertEqual(reapplyEvents(host).last?.hasPrefix("config.reapply_abandoned surface=system_proxy reason=superseded"), true,
                       "\(reapplyEvents(host))")
    }

    /// Twin of `AppStateHarnessTests.testABypassEditReappliesOffTheMainActor`.
    func testABypassReloadReappliesOffTheMainActor() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, values in
            name == "/bin/launchctl" && values.first == "setenv" && values.dropFirst().first == "NO_PROXY"
        }

        var edited = host.config
        edited.noProxyHosts.append("bypass.example")
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        let reload = Task { await host.reloadConfiguration() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        harness.hold.release()
        _ = await reload.value

        XCTAssertTrue(harness.machine.launchdEnvironment["NO_PROXY"]?.contains("bypass.example") == true)
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testABypassEditInPACModeLeavesTheSystemProxyAlone`.
    func testABypassReloadInPACModeLeavesTheSystemProxyAlone() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(
            manageSystemProxy: true, manageEnvironmentVariables: true, systemProxyMode: .pac))
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let bypassBefore = harness.wifi.bypassDomains

        var edited = host.config
        edited.noProxyHosts.append("bypass.example")
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()

        XCTAssertTrue(harness.machine.launchdEnvironment["NO_PROXY"]?.contains("bypass.example") == true)
        XCTAssertEqual(harness.wifi.bypassDomains, bypassBefore)
        XCTAssertEqual(host.orchestrator.eventLog.events.filter { $0.event == "config.advertised_bypass_changed" }.map(\.detail),
                       ["surfaces=environment"])
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testAWipedEnvironmentIsRepairedOnTheNextSettingsNotification`.
    func testAWipedEnvironmentIsRepairedOnTheNextSettingsNotification() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        let zshrc = harness.homeDirectory.appendingPathComponent(".zshrc")
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        _ = try harness.machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])

        harness.locationObserver.emitSettingsChange()
        await host.deliveries.drain()

        XCTAssertNotNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains("# >>> Conduit >>>"))
        XCTAssertEqual(host.orchestrator.eventLog.events.map(\.event).filter { $0.hasPrefix("platform.environment_") },
                       ["platform.environment_drift", "platform.environment_repaired"])
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testRepeatedDNSStopsWhileTheFirstIsHeldRunOneTeardown`:
    /// stops while a stop is held join it instead of queueing teardowns.
    func testRepeatedStopsWhileTheFirstIsHeldRunOneTeardown() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        try await host.startRuntime()
        XCTAssertTrue(harness.wifi.routesThroughAProxy)
        // The system proxy clear, the stop's second block.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let first = Task { await host.stopRuntime() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        let more = (0..<4).map { _ in Task { await host.stopRuntime() } }
        let events = host.orchestrator.eventLog
        for _ in 0..<5_000 where events.events.coalescedValues.count < 4 && host.lifecycleGeneration < 6 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        harness.hold.release()
        await first.value
        for task in more { await task.value }

        XCTAssertEqual(host.lifecycleGeneration, 2, "the start and one stop")
        XCTAssertEqual(
            events.events.coalescedValues,
            Array(repeating: LifecycleCoalesced(operation: .runtimeStop, joined: 2), count: 4)
        )
        XCTAssertEqual(
            events.events.filter { $0.event == "lifecycle.coalesced" }.map(\.detail),
            Array(repeating: "operation=runtime_stop joined=2", count: 4),
            "golden: the human line operators read"
        )
        XCTAssertFalse(harness.wifi.routesThroughAProxy)
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
    }

    /// Codex review of #90: a VPN drop handled while the start's apply is
    /// out finds no entry files yet, and the apply then writes them from the
    /// gate it was queued with. The monitor this host starts is not running
    /// during its first start, so the drop here is emitted through a fake
    /// the test starts itself, standing in for a delivery already queued.
    /// Twin of `AppStateHarnessTests.testAVPNDropWhileTheStartAppliesLeavesNoEntryFile`.
    /// #165 in this host, which hears of no helper install: the removal on a
    /// VPN drop is refused, and the check that runs while the repair is
    /// pending finds the helper available and removes the entry file. While
    /// the helper still refuses, nothing is retried. Twin of
    /// `AppStateHarnessTests.testThePendingRepairsHelperCheckFindsAHelperInstalledOutsideTheApp`.
    /// PR #211 review, twin of
    /// `AppStateHarnessTests.testARefusedRemovalOnAConfigEditIsRetriedWhenTheHelperIsAvailable`:
    /// a reload renames the entry while the helper refuses; the old file,
    /// named only by the journal, is swept once the check finds the helper.
    func testARefusedRemovalOnAConfigReloadIsRetriedWhenTheHelperIsAvailable() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageDNSResolvers: true))
        harness.splitDNSHelperCheckInterval = .milliseconds(20)
        harness.helper.status = .callerNotAccepted(message: "caller identity is not the pinned one")
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"))

        harness.machine.privilege.failingDomains = ["corp.example"]
        config.dnsEntries = [DomainDNSEntry(domain: "renamed.example", servers: ["10.0.0.53"])]
        try ProxyConfigPersistence.save(config, in: harness.environment)
        await host.reloadConfiguration()
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "the removal was refused")
        XCTAssertNotNil(harness.machine.resolverFile(for: "renamed.example"))
        let events = host.orchestrator.eventLog
        XCTAssertEqual(events.events.first { $0.event == "platform.split_dns_failed" }?.detail?
            .hasPrefix("operation=apply source=config_change attempt=1"), true)

        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        for _ in 0..<3_000 where harness.machine.resolverFile(for: "corp.example") != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        await host.deliveries.drain()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the old domain's file is swept")
        XCTAssertNotNil(harness.machine.resolverFile(for: "renamed.example"))
        XCTAssertEqual(events.events.filter { $0.event == "platform.split_dns_repaired" }.count, 1)
        await host.stopRuntime()
    }

    /// PR #211 review, twin of
    /// `AppStateHarnessTests.testAFailedSwitchOffTeardownIsRetriedWhenTheHelperIsAvailable`:
    /// a reload turns the switch off while the helper refuses; the check
    /// finds the helper and the retry runs the teardown.
    func testAFailedSwitchOffTeardownOnAReloadIsRetriedWhenTheHelperIsAvailable() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageDNSResolvers: true))
        harness.splitDNSHelperCheckInterval = .milliseconds(20)
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"))

        harness.helper.status = .callerNotAccepted(message: "caller identity is not the pinned one")
        harness.machine.privilege.failingDomains = ["corp.example"]
        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: false), on: host)
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "the teardown did not land")
        let events = host.orchestrator.eventLog
        XCTAssertEqual(events.events.last { $0.event == "platform.split_dns_failed" }?.detail?
            .hasPrefix("operation=remove source=switch_off attempt=1"), true)

        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        for _ in 0..<3_000 where harness.machine.resolverFile(for: "corp.example") != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        await host.deliveries.drain()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the retry ran the teardown")
        XCTAssertEqual(events.events.filter { $0.event == "platform.split_dns_repaired" }.count, 1)

        // Codex review: the repaired teardown is the switch's action landing,
        // so a reload turning it back on is a flip the reconciler acts on.
        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: true), on: host)
        await host.deliveries.drain()
        XCTAssertEqual(harness.machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53", "switching back on writes the entry")
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testASwitchOnSettledByAVPNFlipIsTornDownWhenTheSwitchTurnsOff`.
    func testASwitchOnSettledByAVPNFlipIsTornDownWhenAReloadTurnsItOff() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageDNSResolvers: false))
        harness.helper.status = .callerNotAccepted(message: "caller identity is not the pinned one")
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()

        harness.machine.privilege.failingDomains = ["corp.example"]
        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: true), on: host)
        await host.deliveries.drain()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the write was refused")

        harness.machine.privilege.failingDomains = []
        harness.vpn.emit(.disconnected(reason: .networkLost))
        await host.deliveries.drain()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "the reconnect wrote the entry")

        try await harness.flip(PlatformIntegrationConfig(manageDNSResolvers: false), on: host)
        await host.deliveries.drain()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "switching off tears the entry down")
        await host.stopRuntime()
    }

    func testAFailedRemovalIsRetriedWhenTheHelperCheckFindsTheHelperAvailable() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageDNSResolvers: true))
        harness.splitDNSHelperCheckInterval = .milliseconds(20)
        harness.helper.status = .callerNotAccepted(message: "caller identity is not the pinned one")
        let host = try await harness.makeHost()
        await host.awaitLaunchRecovery()
        try await host.startRuntime()
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"))

        harness.machine.privilege.failingDomains = ["corp.example"]
        harness.vpn.emit(.disconnected(reason: .networkLost))
        await host.deliveries.drain()
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "the removal was refused")
        let events = host.orchestrator.eventLog
        XCTAssertEqual(events.events.filter { $0.event == "platform.split_dns_failed" }.count, 1)
        let removals = harness.machine.privilege.commands(matching: .removeDNS).count
        try await Task.sleep(for: .milliseconds(200))
        await host.deliveries.drain()
        XCTAssertEqual(harness.machine.privilege.commands(matching: .removeDNS).count, removals, "no retry while the helper refuses")

        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        for _ in 0..<3_000 where harness.machine.resolverFile(for: "corp.example") != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        await host.deliveries.drain()
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "no entry file with the tunnel down")
        XCTAssertEqual(events.events.filter { $0.event == "platform.split_dns_retry" }.map(\.detail),
                       ["operation=remove trigger=helper_check managed=true attempt=2"])
        XCTAssertEqual(events.events.filter { $0.event == "platform.split_dns_repaired" }.map(\.detail),
                       ["operation=remove by=retry failed=remove attempts=1"])
        await host.stopRuntime()
    }

    func testAVPNDropWhileTheStartAppliesLeavesNoEntryFile() async throws {
        let host = try await launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageDNSResolvers: true))
        await host.awaitLaunchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        harness.vpn.start()
        harness.vpn.emit(.disconnected(reason: .userInitiated))
        // The proxy repair waits for this start, so drain after releasing it.
        for _ in 0..<5_000 where host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(host.passesWaitingForLifecycle, 0)
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the drop found nothing to remove yet")
        harness.hold.release()
        try await start.value
        await host.deliveries.drain()

        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "no entry file with the tunnel down")
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
        await host.stopRuntime()
    }
}
