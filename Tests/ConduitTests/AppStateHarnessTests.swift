// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ConduitShared
@testable import Conduit
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyAuth
@testable import ProxyKernel
import RuntimeEvents

// MARK: - Harness

/// Stands up the actual app composition (decision 0031): the one `RuntimeHost` the app opens, its framed client and private editor client
/// under the shipping profile, and `AppState` over them, all over a `FakeMachine`, scratch directories and fakes for every other machine
/// effect. Scenarios drive the entry points the views call and wait on what the app observes through its clients; they assert on the
/// machine, the files and the app's own state. Nothing reaches the host except through the clients.
@MainActor
final class AppStateHarness {
    let stateDirectory: URL
    /// The scratch root's writer authority, taken before the first seed write. The harness's own reference goes in `dropOwnReferences`;
    /// the app and its host keep theirs until they end.
    private var retainedSession: StateRootSession?
    let environment: RuntimeEnvironment
    let machine: FakeMachine
    let vpn = FakeVPNStatusObserver()
    let locationObserver = FakeNetworkLocationObserver()
    /// The host starts its wake observer when it is built, so its start count says whether a host was built at all.
    let wake = FakeSystemWakeObserver()
    var locationStore: FakeNetworkLocationStore?
    let loginItems = FakeLoginItems()
    let helper = FakeHelperLifecycle()
    let secrets = InMemorySecretStore()
    /// The updater seam: never the real process.
    let updater = FakeUpdaterLauncher()
    var currentVersion = "0.5.0"
    /// Long waits by default, so an autosave or a re-read never lands inside a scenario about something else.
    var timing = AppTiming(settingsSaveDebounce: .seconds(3600), helperSocketBindWait: .zero, helperBusyRecheckDelay: .seconds(3600))
    var overrides = AppLaunchOverrides()
    /// The host's repair schedules: long by default, so no retry or drift tick lands inside a scenario about something else.
    var hostSchedules = AppHostSchedules(
        environmentDriftInterval: .seconds(3600),
        reapplyRetrySchedule: ConfigReapplyRetry.Schedule(delays: [.seconds(3600)]),
        splitDNSHelperCheckInterval: .seconds(3600)
    )
    /// Holds one machine call, subprocess or privileged, when armed.
    let hold = HeldCall()
    /// Holds the app's file log at its next open while armed, inside the composition's app-log guard effect, before the authoritative
    /// guard is asked. Nothing is held unless a scenario arms it.
    let appLogHold = HeldDestinationGuard(holds: 0)
    /// Fetches no PAC from the network; a scenario that plans PAC work injects its own before `launch()`.
    var pacEvaluator: any PacEvaluator = FakePacEvaluator()
    /// The host store's file access; a scenario that holds or refuses a store step names its own before `launch()`.
    var stateFiles: any StateFileAccessing = StateFileAccess.operatingSystem()
    private(set) var appState: AppState?

    init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) throws {
        let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appstate-harness-\(UUID().uuidString)", isDirectory: true)
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("home", isDirectory: true), withIntermediateDirectories: true
        )
        // An established install: the files a previous launch left, written before this process takes the root.
        let fixture = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)
        try ProxyConfigPersistence.save(config, in: fixture)
        try PlatformConfigPersistence.save(platformConfig, in: fixture)
        try AppPreferencesPersistence.save(AppPreferences(), in: fixture)
        let session = try acquireScratchStateRoot(fixture)
        retainedSession = session
        environment = session.environment
        machine = FakeMachine(resolverDirectory: stateDirectory.appendingPathComponent("resolver", isDirectory: true))
    }

    /// The harness's session, until `dropOwnReferences`.
    var stateSession: StateRootSession {
        guard let retainedSession else { preconditionFailure("the harness dropped its session") }
        return retainedSession
    }

    var homeDirectory: URL { stateDirectory.appendingPathComponent("home", isDirectory: true) }

    /// A fresh reader over the journal file, as the next launch reads it.
    var journal: PlatformStateJournal { PlatformStateJournal(fileURL: environment.platformStateFile) }

    var savedConfig: ProxyConfig {
        get throws { try ProxyConfigPersistence.load(from: environment.configFile) }
    }

    var savedPlatform: PlatformIntegrationConfig {
        get throws { try PlatformConfigPersistence.load(in: environment) }
    }

    /// The composition, every collaborator named.
    func composition() -> AppComposition {
        let machine = self.machine
        let hold = self.hold
        let vpn = self.vpn
        let wake = self.wake
        let helper = self.helper
        let locationStore = self.locationStore
        let appLogHold = self.appLogHold
        return AppComposition(
            effects: RuntimeHostEffects(
                privilege: { _ in RuntimePrivilegeAdapters(client: HoldingPrivilegeClient(base: machine, hold: hold), helperStatus: helper) },
                credentials: secrets,
                kerberosTicketRecovery: FakeKerberosTicketRecovery(),
                gss: .injected { HarnessRefusingGSS() },
                pacEvaluator: pacEvaluator,
                portHolderProbe: FakeListenerPortHolderProbe(),
                loopbackPortProbe: FakeLoopbackPortProbe().isServed(port:),
                commandRunner: { launchPath, arguments in
                    hold.pass(launchPath, arguments)
                    return try machine.run(launchPath, arguments)
                },
                // No resolver answers on the fake machine's loopback; the real port 53 is never probed.
                dnsResponds: FakeDNSProbe().responds(onPort:),
                networkPath: FakeNetworkPathObserver(),
                networkLocation: locationObserver,
                networkLocationStoreFactory: { _ in locationStore },
                vpnStatusMonitor: { _, _ in vpn },
                wake: wake,
                homeDirectory: homeDirectory,
                resolverDirectory: machine.resolverDirectory.path,
                stateFiles: stateFiles
            ),
            appLogGuard: AppLogGuardEffect { HoldingAppLogGuard(authoritative: $0, hold: appLogHold) },
            helperLifecycle: helper,
            credentialStore: secrets,
            loginItemManager: loginItems.manager,
            pacEvaluator: pacEvaluator,
            updaterLauncher: updater,
            updateReports: FakeUpdateReports(),
            updaterAvailability: .available,
            currentVersion: currentVersion,
            launchOverrides: overrides,
            timing: timing,
            hostSchedules: hostSchedules
        )
    }

    /// The host's own `events.ndjson`, as written so far.
    var hostEventsText: String {
        (try? String(contentsOf: environment.eventsFile, encoding: .utf8)) ?? ""
    }

    @discardableResult
    func launch() -> AppState {
        precondition(appState == nil, "one app per harness")
        let state = AppState(stateSession: stateSession, composition: composition())
        appState = state
        return state
    }

    /// Launches and waits for meaningful readiness: the opening finished ready and the observation delivered a baseline.
    func ready(file: StaticString = #filePath, line: UInt = #line) async -> AppState {
        let state = launch()
        await state.opening?.value
        XCTAssertEqual(state.phase, .ready, "the app opened", file: file, line: line)
        await settle("the observation is live", file: file, line: line) { state.runtime.isLive }
        return state
    }

    /// Polls until `condition` holds, for edges the app observes asynchronously through its stream.
    func settle(
        _ what: String,
        timeoutMilliseconds: Int = 5_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutMilliseconds where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)", file: file, line: line)
    }

    /// How long teardown waits for the root's lease to come free once the harness and its app have let go. A Quit's caller is let go at
    /// its deadline while the host's work runs on, through at most one diagnostic flush phase and the logger's own wait. A bound on the
    /// proof, not a policy: a lease still held after it fails the test and keeps the root.
    static let leaseCloseBound: Duration = DiagnosticFlushPhase.defaultBudget + DiagnosticFlushPhase.writerWait + .seconds(2)

    private let rootProbe = PlatformWork(label: "io.github.srps.Conduit.test.root-probe")
    private var tornDown = false

    /// Quits the way AppKit's terminate-later does and lets go of the root. The scratch state is removed only once a fresh acquisition
    /// of the root proves the lease closed, so the host's own work, which holds its session until it ends, is never raced; otherwise the
    /// test fails and the root is kept.
    func tearDown() async {
        guard !tornDown else { return }
        tornDown = true
        hold.releaseAll()
        XCTAssertFalse(hold.takenOnCooperativePool, "a held call was let through on the concurrency pool instead of held")
        // A held file log would block the close below.
        appLogHold.release()
        if let appState {
            await appState.opening?.value
            // An unsettled Quit let its caller go at the deadline; the proof below waits for the host's work instead.
            if appState.beginQuit() { _ = await appState.finishQuit() }
            appState.logStore.logFileURL = nil
        }
        dropOwnReferences()
        guard await rootReacquires(within: Self.leaseCloseBound) else {
            XCTFail("the scratch root's lease did not come free within \(Self.leaseCloseBound); the root is kept at \(stateDirectory.path)")
            return
        }
        removeScratch([stateDirectory])
    }

    /// Lets go of the harness's own app and session, so only what still holds them (a test's own references, the host's work) keeps the
    /// root's lease.
    func dropOwnReferences() {
        appState = nil
        retainedSession = nil
    }

    /// Whether a fresh acquisition of the root succeeds within `limit`. Busy is expected while some owner still holds the lease, and is
    /// tried again; any other refusal is reported and ends the wait.
    func rootReacquires(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while true {
            switch await probeRoot() {
            case .success(let release):
                XCTAssertEqual(release, .released, "the proof's own session closed")
                return release == .released
            case .failure(.busy) where ContinuousClock.now < deadline:
                try? await Task.sleep(for: .milliseconds(5))
            case .failure(.busy):
                return false
            case .failure(let failure):
                XCTFail("the scratch root was refused: \(failure)")
                return false
            }
        }
    }

    /// One acquisition of the root through the production bootstrap and the real lease, off the main actor, creating nothing. A session
    /// it takes is released before it returns, with the release's outcome, so the probe never keeps the root itself.
    func probeRoot() async -> Result<StateWriterRelease, StateRootAcquisitionFailure> {
        let environment = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)
        return await rootProbe.run {
            StateRootBootstrap.acquire(
                environment,
                createRootIfMissing: false,
                fileSystem: OSStateRootFileSystem(),
                leasing: OSStateWriterLeasing(),
                onReleaseFailure: { failure in XCTFail("the root probe's lease could not be closed: errno \(failure.errno)") }
            ).map { $0.releaseForTesting() }
        }
    }
}

/// The harness's app-log guard effect: each destination admission first passes `hold`, which waits there while armed, and is then
/// judged by the authoritative guard the app built. A descriptor is judged by the authoritative guard alone. Nothing is admitted that
/// the authoritative guard refuses.
final class HoldingAppLogGuard: RecordFileDestinationGuarding, @unchecked Sendable {
    private let authoritative: any RecordFileDestinationGuarding
    private let hold: HeldDestinationGuard

    init(authoritative: any RecordFileDestinationGuarding, hold: HeldDestinationGuard) {
        self.authoritative = authoritative
        self.hold = hold
    }

    func admit(destination: URL) throws {
        try hold.admit(destination: destination)
        try authoritative.admit(destination: destination)
    }

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        try authoritative.admit(openedDescriptor: descriptor, destination: destination)
    }
}

/// The operating system's state-file access with every platform-file replacement refused, as a read-only or full volume would.
final class RefusingPlatformWrites: StateFileAccessing, @unchecked Sendable {
    private let inner = StateFileAccess.operatingSystem()

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        file.role == .platformConfig ? .failure(.writeFailed(errno: EACCES)) : inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}

/// The operating system's state-file access with every replacement of one file refused while `refusing` is set, as a destination the
/// user can repair would be.
final class RefusingWrites: StateFileAccessing, @unchecked Sendable {
    private let inner = StateFileAccess.operatingSystem()
    private let role: StateRootRole
    private let lock = NSLock()
    private var _refusing = true

    init(of role: StateRootRole) {
        self.role = role
    }

    var refusing: Bool {
        get { lock.withLock { _refusing } }
        set { lock.withLock { _refusing = newValue } }
    }

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        file.role == role && refusing ? .failure(.writeFailed(errno: EACCES)) : inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}

/// A free loopback TCP port, found by binding and releasing it, for a listener whose port a configuration must name. Shared with the
/// host suites.
func reserveLoopbackPort() throws -> Int {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(fd) }
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
    guard bound == 0, named == 0 else { throw CocoaError(.fileWriteUnknown) }
    return Int(UInt16(bigEndian: chosen.sin_port))
}

/// The harness's Kerberos token source: every token is refused, so no handshake reaches the system GSS stack.
final class HarnessRefusingGSS: GSSTokenProvider, @unchecked Sendable {
    struct Refused: Error {}
    func generateToken(host: String, inputToken: Data?) throws -> Data? { throw Refused() }
    func resetContext() {}
}

// MARK: - Scenarios

/// Thin app/client scenarios over the actual host. Lifecycle, recovery and persistence policy are the host's and are pinned by its own
/// suites; these pin what the app composes and sends, and what it does with the answers.
@MainActor
final class AppStateHarnessTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func makeConfig() -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        return config
    }

    private func makeHarness(
        platform: PlatformIntegrationConfig = PlatformIntegrationConfig(),
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) throws -> AppStateHarness {
        var config = makeConfig()
        configure(&config)
        harness = try AppStateHarness(config: config, platformConfig: platform)
        return harness
    }

    private var wifi: FakeMachine.Service { harness.machine.service("Wi-Fi") }

    // MARK: Opening

    /// The drafts and their baselines come from one editor observation of the files the host opened; nothing was written, and the
    /// controls are enabled only after readiness.
    func testOpeningSeedsTheDraftsFromOneObservationBeforeEnablingTheControls() async throws {
        let harness = try makeHarness { $0.profileName = "Opening witness" }
        let bytes = try Data(contentsOf: harness.environment.configFile)
        let state = harness.launch()
        XCTAssertEqual(state.phase, .opening)
        XCTAssertFalse(state.controlsEnabled, "nothing acts before the opening is ready")
        state.toggleProxy()
        await state.opening?.value
        await harness.settle("the observation is live") { state.runtime.isLive }
        XCTAssertTrue(state.controlsEnabled)
        XCTAssertEqual(harness.wake.startCount, 1, "the built host started its wake observer, so a count of zero elsewhere means no host")
        XCTAssertEqual(state.config.profileName, "Opening witness")
        XCTAssertFalse(state.hasUnsavedEdit, "seeding the drafts is not an edit")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), bytes, "opening wrote nothing")
        XCTAssertEqual(state.runtime.runtimeStatus.state, .stopped, "the toggle before readiness started nothing")
    }

    /// A corrupt configuration refuses the open: the bytes stay, the journal's configless recovery restores the machine, the banner
    /// shows, and no control or save acts.
    func testACorruptConfigIsRefusedKeepsItsBytesAndStillRestoresTheJournaledProxy() async throws {
        let harness = try makeHarness()
        let prior = ProxyServiceState(
            webHost: "prior.example.test", webPort: "8080", webEnabled: true,
            secureHost: "prior.example.test", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false, bypassDomains: ["*.local"]
        )
        harness.journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: prior.journalValues)
        harness.journal.markApplied(surface: .systemProxy)
        harness.machine.describe("Wi-Fi") {
            $0.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            $0.secureWebProxy = $0.webProxy
        }
        let corrupt = Data("{".utf8)
        try corrupt.write(to: harness.environment.configFile)
        let state = harness.launch()
        await state.opening?.value

        XCTAssertEqual(state.phase, .refused)
        XCTAssertEqual(wifi.webProxy.host, "prior.example.test", "journal recovery proceeds despite the invalid configuration")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.load_rejected" })
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "platform.launch_recovery_restored" })
        XCTAssertNotNil(state.lastErrorMessage)
        state.config.localPort = 9
        state.saveConfig()
        state.toggleProxy()
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), corrupt, "the refused file keeps its bytes")
        XCTAssertFalse(state.controlsEnabled)
    }

    /// An established install whose configuration was deleted is not a first run: no default replaces the missing policy.
    func testADeletedConfigInAnEstablishedStateIsRefusedNotDefaulted() async throws {
        let harness = try makeHarness()
        try FileManager.default.removeItem(at: harness.environment.configFile)
        let state = harness.launch()
        await state.opening?.value
        XCTAssertEqual(state.phase, .refused)
        state.saveConfig()
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.configFile.path))
    }

    /// `--port`, `--no-system-proxy` and `--no-env` are written save-only before the controls are enabled, so the saved Start uses them.
    func testLaunchOverridesAreSavedBeforeTheControlsAreEnabled() async throws {
        let harness = try makeHarness(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
        harness.overrides = AppLaunchOverrides(port: 0, disableSystemProxy: true, disableEnvironment: true)
        let state = await harness.ready()
        XCTAssertFalse(try harness.savedPlatform.manageSystemProxy)
        XCTAssertFalse(try harness.savedPlatform.manageEnvironmentVariables)
        XCTAssertFalse(state.hasUnsavedEdit, "the override's own receipt rebased the draft")
        state.toggleProxy()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty,
                      "the saved override, not the file's earlier switch, governed the Start")
    }

    /// An override the store did not verify holds every Start: the launch's own input was not saved, so nothing may run the input it
    /// replaced. The refusal is reported; Quit is unaffected.
    func testAnUnsavedLaunchOverrideHoldsEveryStart() async throws {
        let harness = try makeHarness(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        harness.overrides = AppLaunchOverrides(disableSystemProxy: true)
        harness.stateFiles = RefusingPlatformWrites()
        let state = await harness.ready()
        XCTAssertNotNil(state.activationHeld)
        XCTAssertTrue(try harness.savedPlatform.manageSystemProxy, "the refused write left the file as it was")
        state.toggleProxy()
        state.toggleDNS()
        XCTAssertEqual(state.lastErrorMessage, state.activationHeld, "the held Start says why")
        XCTAssertEqual(state.runtime.runtimeStatus.state, .stopped)
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
        XCTAssertTrue(state.beginQuit())
        guard case .settled(.completed)? = await state.finishQuit()?.quit else { return XCTFail("the quit completed") }
    }

    /// A journaled proxy a crashed run left on Wi-Fi: launch recovery, which only a built host runs, would restore the prior.
    private func leaveACrashedRunsProxy(_ harness: AppStateHarness) {
        let prior = ProxyServiceState(
            webHost: "prior.example.test", webPort: "8080", webEnabled: true,
            secureHost: "prior.example.test", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false, bypassDomains: ["*.local"]
        )
        harness.journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: prior.journalValues)
        harness.journal.markApplied(surface: .systemProxy)
        harness.machine.describe("Wi-Fi") {
            $0.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            $0.secureWebProxy = $0.webProxy
        }
    }

    /// The explicit reload runs one at a time, refusing a second with a message, and re-evaluates the launch options' hold from what it
    /// read: a file repaired outside the app to hold `--no-system-proxy` releases it, and the Start then runs without the system proxy.
    func testAReloadIsSingleFlightAndReevaluatesTheLaunchOptionsHold() async throws {
        let harness = try makeHarness(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        harness.overrides = AppLaunchOverrides(disableSystemProxy: true)
        harness.stateFiles = RefusingPlatformWrites()
        let state = await harness.ready()
        XCTAssertNotNil(state.activationHeld)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemProxy: false), in: harness.environment)
        state.reloadConfigurationFromDisk()
        state.reloadConfigurationFromDisk()
        XCTAssertEqual(state.lastErrorMessage, "A reload from disk is already running.")
        await state.reloadTask?.value
        XCTAssertNil(state.activationHeld, "the saved values now hold the launch option")
        XCTAssertFalse(state.platformConfig.manageSystemProxy)
        state.toggleProxy()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
    }

    /// A quit while the host's startup read is held joins the opening within its own total. The opening was cancelled in the quit's
    /// turn, so once the read is released the factory refuses before construction: no host, no launch recovery, no observer, and the
    /// opening never finishes ready.
    func testAQuitDuringAHeldOpeningBuildsNoHostAndTheOpeningNeverBecomesReady() async throws {
        let harness = try makeHarness()
        leaveACrashedRunsProxy(harness)
        let held = HeldStateFileRead()
        harness.stateFiles = held
        harness.timing.quitTotal = .seconds(5)
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, _ in name == "read" }
        let state = harness.launch()
        await held.hold.waitUntilReached()
        let begun = ContinuousClock.now
        XCTAssertTrue(state.beginQuit())
        XCTAssertFalse(state.beginQuit(), "a second request joins the first")
        let release = Task { @MainActor in
            defer { held.hold.release() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = await state.finishQuit()
        let waited = begun.duration(to: .now)
        try await release.value
        XCTAssertLessThan(waited, .seconds(5), "the quit ended within its total")
        XCTAssertNil(result, "no host was built, so there was nothing to fence")
        await state.opening?.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.wake.startCount, 0, "no host was constructed")
        XCTAssertEqual(harness.machine.service("Wi-Fi").webProxy.port, "47113", "no launch recovery ran")
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "the recovery record is kept for the next launch")
        XCTAssertFalse(harness.hostEventsText.contains("phase=startup"), "the startup observation was never emitted by a host")
        XCTAssertEqual(state.phase, .quitting)
        XCTAssertNil(state.editor, "the fenced opening seeded nothing")
        XCTAssertFalse(state.controlsEnabled)
        XCTAssertEqual(state.runtime.observation, .ended)
    }

    /// A quit whose total ends while the host's startup read is still held returns at that deadline, with nothing fenced or saved. The
    /// read, released only after the quit returned, builds no host: no recovery mutation, no observer start, no phase change.
    func testAQuitWhoseTotalEndsDuringAHeldOpeningReturnsAtItsDeadlineAndALateReleaseBuildsNothing() async throws {
        let harness = try makeHarness()
        leaveACrashedRunsProxy(harness)
        let held = HeldStateFileRead()
        harness.stateFiles = held
        harness.timing.quitTotal = .milliseconds(300)
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, _ in name == "read" }
        let state = harness.launch()
        await held.hold.waitUntilReached()
        let begun = ContinuousClock.now
        XCTAssertTrue(state.beginQuit())
        XCTAssertEqual(state.phase, .quitting, "fenced in the same turn")
        let result = await state.finishQuit()
        let waited = begun.duration(to: .now)
        XCTAssertNil(result, "no client existed when the total ended")
        XCTAssertLessThan(waited, .seconds(2), "the quit returned at its deadline while the opening was still held")
        held.hold.release()
        await state.opening?.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.wake.startCount, 0, "the late release constructed no host")
        XCTAssertEqual(harness.machine.service("Wi-Fi").webProxy.port, "47113", "no launch recovery ran after the quit")
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "the recovery record is kept for the next launch")
        XCTAssertEqual(state.phase, .quitting)
        XCTAssertNil(state.editor)
        XCTAssertFalse(state.controlsEnabled)
    }

    /// The app's observer and editor session can outlive it: a read or a settlement wait can still be out when the quit returns and the
    /// app is released. Their callbacks hold it weakly, so nothing keeps it after the quit; what an observer read still out would hand on
    /// does not reach it, and the closed session starts no write however it is triggered.
    func testAQuitAppIsReleasedAndLateObservationOrEditorWorkNeitherReachesItNorWrites() async throws {
        let harness = try makeHarness()
        weak var released: AppState?
        let observer: RuntimeObserver
        let editor: RuntimeEditorSession
        do {
            let state = await harness.ready()
            released = state
            observer = try XCTUnwrap(state.observer)
            editor = try XCTUnwrap(state.editor)
            state.config.profileName = "Frozen at quit"
            XCTAssertTrue(state.beginQuit())
            guard case .settled(.completed)? = await state.finishQuit()?.quit else { return XCTFail("the quit completed") }
        }
        XCTAssertEqual(try harness.savedConfig.profileName, "Frozen at quit", "the quit saved the draft it froze")
        // The observer and editor this test keeps hold the host through their clients, so the root is proved free only at teardown.
        harness.dropOwnReferences()
        await harness.settle("nothing keeps the app after its quit") { released == nil }

        // Every callback the observer holds, as a read still out after the quit would call it.
        observer.onSnapshot?(try WireSnapshotFixture.snapshot(ProxyOrchestratorSnapshot()))
        observer.onEvents?([ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event")])
        observer.onFailure?("a page read the quit cancelled")
        // Every trigger the app or the observer could still pull on the closed session.
        editor.edited(.configuration)
        editor.save(.configuration)
        editor.save(.preferences)
        editor.revisionsMayHaveMoved()
        XCTAssertFalse(editor.setLaunchAtLogin(true), "the closed session admits no write")
        await editor.settle()
        XCTAssertTrue(editor.isIdle)
        XCTAssertNil(editor.ledger.active, "nothing was submitted after the quit")
    }

    /// A Quit's deadline is not the end of its work. The Quit's teardown is held on the platform worker, so its caller is let go at the
    /// deadline and the app is released, with the harness's own references gone too. The host's held work still holds the root: a fresh
    /// acquisition is busy. Released, that work ends, the host lets go, and the root is acquired again.
    func testTheRootStaysLeasedWhileTheHostsQuitWorkIsHeldAndComesFreeOnceItEnds() async throws {
        let harness = try makeHarness(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
        harness.timing.quitTotal = .seconds(1)
        weak var released: AppState?
        do {
            let state = await harness.ready()
            released = state
            state.toggleProxy()
            await harness.settle("the Start's surfaces applied") { harness.machine.launchdEnvironment["HTTP_PROXY"] != nil }
            harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
                name == "/bin/launchctl" && arguments.first == "unsetenv"
            }
            XCTAssertTrue(state.beginQuit())
            await harness.hold.waitUntilReached()
            XCTAssertTrue(harness.hold.reachedOnArmedQueue, "the Quit's teardown is held on the platform worker")
            guard case .unsettled? = await state.finishQuit()?.quit else {
                return XCTFail("the Quit's caller was let go at its deadline")
            }
        }
        harness.dropOwnReferences()
        await harness.settle("nothing keeps the app after its quit") { released == nil }
        XCTAssertTrue(harness.hold.isHolding, "the host's teardown is still held")
        let whileHeld = await harness.probeRoot()
        XCTAssertEqual(whileHeld, .failure(.busy), "the host's held work keeps the root")
        harness.hold.release()
        let reacquired = await harness.rootReacquires(within: AppStateHarness.leaseCloseBound)
        XCTAssertTrue(reacquired, "the root comes free once the held work ends")
    }

    /// A diagnostic write still queued under the root keeps the root's authority after its app, its host and the harness have let go
    /// (decision 0017). The app's file log is held at its open, the Quit completes around it, and every own reference is dropped, so
    /// only the held write's writer is left: a fresh acquisition of the root is busy. Released, the write lands and the root comes free.
    func testAHeldDiagnosticWriteKeepsTheRootLeasedAfterEveryOwnerLetGo() async throws {
        let harness = try makeHarness()
        harness.timing.quitTotal = .seconds(4)
        weak var released: AppState?
        do {
            let state = await harness.ready()
            released = state
            holdTheAppLogOpen(state, harness, witness: "held authority witness")
            XCTAssertTrue(state.beginQuit())
            guard case .settled(.completed)? = await state.finishQuit()?.quit else {
                return XCTFail("the Quit completed around the held write")
            }
        }
        harness.dropOwnReferences()
        await harness.settle("nothing keeps the app after its quit") { released == nil }
        let whileHeld = await harness.probeRoot()
        XCTAssertEqual(whileHeld, .failure(.busy), "the held write's writer keeps the root")
        harness.appLogHold.release()
        let reacquired = await harness.rootReacquires(within: AppStateHarness.leaseCloseBound)
        XCTAssertTrue(reacquired, "the root comes free once the held write ends")
        let log = try String(contentsOf: harness.environment.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("held authority witness"), "the held write landed before the root came free")
    }

    // MARK: Saves

    /// An edit saves once edits pause; its own receipt makes the draft clean, and the file holds it.
    func testASettingsEditSavesWhenEditsPauseAndItsOwnReceiptCleansIt() async throws {
        let harness = try makeHarness()
        harness.timing.settingsSaveDebounce = .milliseconds(10)
        let state = await harness.ready()
        state.config.health.checkInterval = 47
        XCTAssertTrue(state.hasUnsavedEdit)
        await harness.settle("the save settled") { !state.hasUnsavedEdit }
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 47)
    }

    /// An edit made after a save froze its values survives that save's receipt: the receipt advances the baselines the save was submitted
    /// under and never marks the newer draft clean. The next save carries the newer value under those baselines.
    func testAnEditMadeWhileASaveIsInFlightStaysUnsavedAfterItsReceipt() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let editor = try XCTUnwrap(state.editor)
        state.config.health.checkInterval = 47
        state.saveConfig()
        await harness.settle("the save is in flight") { editor.ledger.active != nil }
        state.config.health.checkInterval = 53
        await editor.settle()
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 47, "the receipt is the first save's")
        XCTAssertTrue(state.hasUnsavedEdit, "the newer edit keeps its own version")
        XCTAssertEqual(state.config.health.checkInterval, 53, "no receipt rewrites a draft")
        state.saveConfig()
        await editor.settle()
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 53)
        XCTAssertFalse(state.hasUnsavedEdit)
        XCTAssertTrue(editor.ledger.filesNeedingReload.isEmpty, "the causal chain held: no own write read as a conflict")
    }

    /// A refused preferences write names only the file (no value, no private path), leaves the runtime save beside it saved, keeps the
    /// preferences draft unsaved, and the quit's own preferences final save writes it once the file takes writes again.
    func testARefusedPreferencesWriteNamesOnlyTheFileAndTheQuitTriesItAgain() async throws {
        let harness = try makeHarness()
        let refusing = RefusingWrites(of: .preferences)
        harness.stateFiles = refusing
        let state = await harness.ready()
        state.appPreferences.floatingWindowEnabled.toggle()
        let wanted = state.appPreferences.floatingWindowEnabled
        state.config.health.checkInterval = 47
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 47, "the runtime save is independent of the preferences file")
        XCTAssertNotEqual(try AppPreferencesPersistence.load(in: harness.environment).floatingWindowEnabled, wanted)
        XCTAssertTrue(state.hasUnsavedEdit, "the preferences draft stays unsaved")
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.save_unverified" && ($0.detail ?? "").contains("file=preferences") })
        let banner = try XCTUnwrap(state.lastErrorMessage)
        XCTAssertTrue(banner.hasPrefix("Preferences were not saved"), banner)
        XCTAssertFalse(banner.contains(harness.stateDirectory.path), "no private path in the banner")

        refusing.refusing = false
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.preferencesSettled(let receipt)) = result.preferences else {
            return XCTFail("the quit's preferences save settled: \(result.preferences)")
        }
        XCTAssertTrue(receipt.preferences.write.isVerified)
        XCTAssertEqual(try AppPreferencesPersistence.load(in: harness.environment).floatingWindowEnabled, wanted)
    }

    /// A pause does not save an edit that would block a start or replace a listener; a commit does, save-only for the blocking one.
    func testAPauseHoldsAStartBlockingEditAndACommitSavesItWithoutApplying() async throws {
        let harness = try makeHarness()
        harness.timing.settingsSaveDebounce = .milliseconds(10)
        let state = await harness.ready()
        state.config.proxy.port = 70_000
        await harness.settle("the pause decided") {
            state.eventLog.events.contains { $0.event == "config.autosave_held" }
        }
        XCTAssertNotEqual(try harness.savedConfig.proxy.port, 70_000)
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.proxy.port, 70_000)
        XCTAssertEqual(state.eventLog.events.filter { $0.event == "config.apply_held" }.count, 1)
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.edit_committed" })
    }

    func testAListenerEditWaitsForACommit() async throws {
        let harness = try makeHarness()
        harness.timing.settingsSaveDebounce = .milliseconds(10)
        let state = await harness.ready()
        state.config.socksEnabled.toggle()
        XCTAssertTrue(state.listenerEditAwaitingCommit)
        await harness.settle("the pause decided") {
            state.eventLog.events.contains { $0.event == "config.autosave_held" && ($0.detail ?? "").contains("listener_change") }
        }
        state.commitPendingEdit(trigger: .apply)
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.socksEnabled, state.config.socksEnabled)
        XCTAssertFalse(state.listenerEditAwaitingCommit)
    }

    /// The menu's Start carries no Settings value: an unsaved edit stays a draft, and the runtime binds the saved port.
    func testTheMenuStartSendsNoUnsavedSettingsValue() async throws {
        let harness = try makeHarness(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        let state = await harness.ready()
        state.config.localPort = 1
        state.toggleProxy()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        XCTAssertNotEqual(state.runtime.bindings.proxyPort, 1)
        XCTAssertEqual(try harness.savedConfig.localPort, 0)
        XCTAssertTrue(state.hasUnsavedEdit)
        // The host reports the proxy running once its listener binds, before the Start applies the surfaces.
        await harness.settle("the saved Start applied the system proxy") { self.wifi.webProxy.host == "127.0.0.1" }
        state.toggleProxy()
        await harness.settle("the proxy stopped") { state.runtime.runtimeStatus.state == .stopped }
        // The host reports the listener stopped before its teardown clears the surfaces (`tearDownProxy`), so the clear is its own edge.
        await harness.settle("the Stop's clear landed") { !self.wifi.routesThroughAProxy && !harness.journal.hasRecords(for: .systemProxy) }
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy), "the Stop cleared what the Start applied")
    }

    /// An import passes the startup gate; a newer file is refused and the editor is unchanged.
    func testAnImportOfANewerFileLeavesTheEditorUnchanged() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let before = state.config
        let newer = harness.stateDirectory.appendingPathComponent("newer.json")
        try Data(#"{"schemaVersion": 999}"#.utf8).write(to: newer)
        XCTAssertThrowsError(try state.importConfiguration(from: newer))
        XCTAssertEqual(state.config, before)
        XCTAssertFalse(state.hasUnsavedEdit)
    }

    /// Export is the user's document; it may not write a runtime file of the root, and writes anywhere else.
    func testAnExportRefusesAStateFileAndWritesElsewhere() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let configBytes = try Data(contentsOf: harness.environment.configFile)
        XCTAssertThrowsError(try state.exportConfiguration(to: harness.environment.configFile))
        XCTAssertThrowsError(try state.exportConfiguration(to: harness.environment.platformStateFile))
        XCTAssertThrowsError(try state.exportConfiguration(to: harness.stateSession.writerLeaseFile))
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), configBytes)
        let elsewhere = harness.homeDirectory.appendingPathComponent("Conduit-config.json")
        try state.exportConfiguration(to: elsewhere)
        XCTAssertEqual(try ProxyConfigPersistence.loadImport(from: elsewhere), state.config)
    }

    // MARK: Quit

    /// The client Quit writes the final edit save-only within its total, applies nothing, and settles.
    func testQuitFlushesTheFinalEditSaveOnlyWithinItsTotal() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        state.toggleProxy()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        state.config.health.checkInterval = 61
        XCTAssertTrue(state.beginQuit())
        // In the same turn: the fence holds and the final intent is frozen.
        XCTAssertEqual(state.phase, .quitting)
        XCTAssertFalse(state.controlsEnabled)
        state.config.health.checkInterval = 99
        state.toggleProxy()
        XCTAssertFalse(state.beginQuit(), "one quit")
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.completed) = result.quit else { return XCTFail("the quit completed: \(result.quit)") }
        guard case .settled(.configurationSettled(let receipt)) = result.configuration else {
            return XCTFail("the final save settled: \(result.configuration)")
        }
        XCTAssertTrue(receipt.runtime.write.isVerified)
        XCTAssertTrue(receipt.modules.isEmpty, "the final save started nothing")
        XCTAssertNil(receipt.applied, "the final save applied nothing")
        XCTAssertEqual(result.preferences, .notDeclared, "clean preferences are not saved")
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 61, "the draft frozen when the quit began, not a later edit")
        XCTAssertEqual(state.runtime.observation, .ended)
    }

    /// A runtime draft that blocks a start is not the next launch's configuration; the platform edit beside it is still written.
    func testQuitDiscardsAStartBlockingRuntimeDraftButWritesThePlatformEdit() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let savedPort = try harness.savedConfig.proxy.port
        state.config.proxy.port = 70_000
        state.platformConfig.manageEnvironmentVariables = true
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.configurationSettled) = result.configuration else {
            return XCTFail("the final save settled: \(result.configuration)")
        }
        XCTAssertEqual(try harness.savedConfig.proxy.port, savedPort)
        XCTAssertTrue(try harness.savedPlatform.manageEnvironmentVariables)
        let discarded = try XCTUnwrap(state.eventLog.events.first { $0.event == "config.edit_discarded" })
        XCTAssertTrue(discarded.detail?.hasPrefix("trigger=quit reason=start_blocking_problems check=") == true, discarded.detail ?? "")
        XCTAssertFalse(discarded.detail?.contains("70000") ?? true, "the check is named, never the value")
        XCTAssertFalse(state.eventLog.events.contains { $0.event == "config.edit_committed" && ($0.detail ?? "").contains("trigger=quit") })
    }

    /// A save out when the quit begins meets an outside edit and settles as a conflict, which drops the file's baseline in its own
    /// settlement. The final save of the newer draft is still declared under the verified baseline it was frozen with, as for an
    /// unsettled prior: the host compares it with the moved file and refuses it unwritten, and the quit ends on that answer instead of
    /// holding the host's flush window open to its total.
    func testAFinalSaveWhosePriorDroppedItsBaselineIsRefusedByTheHostNotLeftToTheDeadline() async throws {
        let harness = try makeHarness()
        let held = HeldStateFileRead()
        harness.stateFiles = held
        harness.timing.quitTotal = .seconds(6)
        let state = await harness.ready()
        let configName = harness.environment.configFile.lastPathComponent
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, values in
            name == "read" && values.first?.hasSuffix(configName) == true
        }
        state.config.health.checkInterval = 47
        state.saveConfig()
        let reached = await held.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached, "the save is held at its read of the file")
        var external = try harness.savedConfig
        external.profileName = "edited outside"
        try ProxyConfigPersistence.save(external, in: harness.environment)
        let externalBytes = try Data(contentsOf: harness.environment.configFile)
        state.config.health.checkInterval = 53
        let begun = ContinuousClock.now
        XCTAssertTrue(state.beginQuit())
        let release = Task { @MainActor in
            defer { held.hold.release() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finished = await state.finishQuit()
        let waited = begun.duration(to: .now)
        try await release.value
        let result = try XCTUnwrap(finished)
        XCTAssertLessThan(waited, .seconds(4), "the quit ended on the host's answer, not at its total")
        guard case .settled(.configurationSettled(let prior)) = result.priorUpdate, case .conflict = prior.runtime.write else {
            return XCTFail("the save out at the quit met the outside edit: \(result.priorUpdate)")
        }
        guard case .settled(.configurationSettled(let final)) = result.configuration else {
            return XCTFail("the final save was declared, admitted and answered: \(result.configuration)")
        }
        XCTAssertFalse(final.runtime.write.isVerified, "the host refused the moved file")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), externalBytes, "the outside edit was not overwritten")
        guard case .settled(.completed) = result.quit else { return XCTFail("the quit completed: \(result.quit)") }
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.save_unverified" && ($0.detail ?? "").contains("trigger=quit ") },
                      "the refused final save is reported, not dropped silently")
    }

    // MARK: Administration

    /// The login item is registered only after its platform write verified; a failed registration is reported, and nothing retries it
    /// until a later trigger (`testARefusedRegistrationIsRetriedOnTheNextSaveAndRepairedByAStart`).
    func testLaunchAtLoginRegistersOnlyAfterItsVerifiedWrite() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        state.setLaunchAtLogin(true)
        await harness.settle("the registration followed the write") { harness.loginItems.registrations == [true] }
        XCTAssertTrue(try harness.savedPlatform.launchAtLogin)
        XCTAssertTrue(state.platformConfig.launchAtLogin)
        XCTAssertFalse(state.hasUnsavedEdit, "the admin write is not a draft edit")

        harness.loginItems.fails = true
        state.setLaunchAtLogin(false)
        await harness.settle("the failure was reported") { state.lastErrorMessage != nil }
        XCTAssertEqual(harness.loginItems.registrations, [true, false], "nothing retried the refused registration by itself")
    }

    /// After the quit's fence no app administration starts, whatever entry point a late panel or click reaches: the credential store is
    /// neither written nor cleared, no helper change, update check, PAC preview, login-item write, import or export runs, and a
    /// preference change starts no automatic checks.
    func testNoAppAdministrationStartsAfterTheQuitsFence() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let updaterStarts = harness.updater.starts.count
        XCTAssertTrue(state.beginQuit())

        state.savePassword("after-the-fence")
        XCTAssertFalse(state.credentialManager.hasSavedCredentials(for: state.config), "no Keychain save after the fence")
        try state.credentialManager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: state.config)
        state.clearCredentials()
        XCTAssertTrue(state.credentialManager.hasSavedCredentials(for: state.config), "no Keychain clear after the fence")

        state.installHelper()
        state.uninstallHelper()
        state.checkForUpdates()
        state.appPreferences.automaticUpdateChecks.toggle()
        state.config.routing.pacURL = "https://pac.example.test/p.pac"
        state.refreshPACResolutionPreview()
        state.setLaunchAtLogin(true)
        let exported = harness.homeDirectory.appendingPathComponent("after-the-fence.json")
        try state.exportConfiguration(to: exported)
        let before = state.config
        try state.importConfiguration(from: harness.environment.configFile)
        _ = await state.finishQuit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.helper.installs, 0)
        XCTAssertEqual(harness.helper.uninstalls, 0)
        XCTAssertEqual(harness.updater.starts.count, updaterStarts)
        XCTAssertFalse(state.isPACPreviewRunning)
        XCTAssertNil(state.pacPreviewMessage)
        XCTAssertTrue(harness.loginItems.registrations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path), "no export after the fence")
        XCTAssertEqual(state.config, before, "no import after the fence")
    }

    /// A login-item write already out when the quit begins is the quit's prior update: it settles within the quit, and no registration
    /// starts from its late receipt after the fence (decisions 0015 and 0039).
    func testALoginItemWriteOutAtQuitRegistersNothingAfterTheFence() async throws {
        let harness = try makeHarness()
        let held = HeldStateFileRead()
        harness.stateFiles = held
        let state = await harness.ready()
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, values in
            name == "read" && values.first?.hasSuffix("platform.json") == true
        }
        state.setLaunchAtLogin(true)
        let reached = await held.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached, "the admin write reached the store")
        XCTAssertTrue(state.beginQuit())
        let release = Task { @MainActor in
            defer { held.hold.release() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finished = await state.finishQuit()
        try await release.value
        let result = try XCTUnwrap(finished)
        guard case .settled(.completed) = result.priorUpdate else {
            return XCTFail("the admin write settled as the quit's prior: \(result.priorUpdate)")
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(harness.loginItems.registrations.isEmpty, "no registration after the fence")
    }

    /// A login-item flip while a save is out is refused, not queued where a quit would drop it; the refusal is an event.
    func testALoginItemFlipWhileASaveIsOutIsRefusedNotQueued() async throws {
        let harness = try makeHarness()
        let held = HeldStateFileRead()
        harness.stateFiles = held
        let state = await harness.ready()
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, _ in name == "read" }
        state.config.health.checkInterval = 47
        state.saveConfig()
        let reached = await held.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached)
        state.setLaunchAtLogin(true)
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.save_rejected" && $0.detail == "file=platform reason=editor_busy" })
        XCTAssertNotNil(state.lastErrorMessage)
        held.hold.release()
        await state.awaitPendingSave()
        XCTAssertFalse(try harness.savedPlatform.launchAtLogin, "the refused flip was never written")
        XCTAssertTrue(harness.loginItems.registrations.isEmpty)
    }

    /// A registration the login item refused is owed for the session: the next verified Settings save tries it again, and a proxy Start
    /// that comes up repairs the registration to the saved flag. Nothing at quit.
    func testARefusedRegistrationIsRetriedOnTheNextSaveAndRepairedByAStart() async throws {
        let harness = try makeHarness()
        harness.timing.settingsSaveDebounce = .milliseconds(10)
        let state = await harness.ready()
        harness.loginItems.fails = true
        state.setLaunchAtLogin(true)
        await harness.settle("the refusal was reported") { harness.loginItems.registrations == [true] && state.lastErrorMessage != nil }
        XCTAssertTrue(try harness.savedPlatform.launchAtLogin, "the flag was saved; only the registration failed")
        harness.loginItems.fails = false
        state.config.health.checkInterval = 47
        await harness.settle("the next save retried it") { harness.loginItems.registrations == [true, true] }
        state.toggleProxy()
        await harness.settle("the Start that came up repaired it") { harness.loginItems.registrations == [true, true, true] }
        XCTAssertTrue(state.beginQuit())
        _ = await state.finishQuit()
        XCTAssertEqual(harness.loginItems.registrations, [true, true, true], "nothing registers at quit")
    }

    /// Install is the app's; the host is told the helper was replaced and reads it again.
    func testHelperInstallTellsTheHostTheHelperWasReplaced() async throws {
        let harness = try makeHarness()
        harness.helper.status = .outdated
        let state = await harness.ready()
        await harness.settle("the first preflight read") { state.helperStatus == .outdated }
        harness.helper.callerPolicy = .unenforced
        state.installHelper()
        await harness.settle("the replaced helper was read") { state.helperStatus == .installed }
        XCTAssertEqual(harness.helper.installs, 1)
        XCTAssertEqual(state.helperCallerPolicy, .unenforced)
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "helper.installed" && $0.detail == "caller_policy=unenforced" })
    }

    func testAFailedHelperUninstallIsReported() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        harness.helper.fails = true
        state.uninstallHelper()
        await harness.settle("the failure was reported") { state.eventLog.events.contains { $0.event == "helper.uninstall_failed" } }
        XCTAssertEqual(state.lastErrorMessage, FakeHelperLifecycle.Refused().localizedDescription)
    }

    /// A busy reading keeps the held verdict and asks for one more read; a conclusive one ends the re-read.
    func testABusyHelperKeepsItsVerdictAndIsReadAgain() async throws {
        let harness = try makeHarness()
        harness.timing.helperBusyRecheckDelay = .milliseconds(20)
        let state = await harness.ready()
        await harness.settle("the first preflight read") { state.helperStatus == .installed }
        harness.helper.status = .busy
        state.refreshPreflight()
        await harness.settle("the busy reading arrived") { state.helperCheckingAgain }
        XCTAssertEqual(state.helperStatus, .installed, "a busy reading is no verdict")
        harness.helper.status = .installed
        await harness.settle("the re-read was conclusive") { !state.helperCheckingAgain }
        XCTAssertEqual(state.helperStatus, .installed)
    }

    // MARK: App log

    /// The app log's refusal lands in the app's own event log, and the config keeps its bytes.
    func testAnAppLogAliasOfTheConfigIsRefusedThroughTheAppEventLog() async throws {
        let harness = try makeHarness()
        let config = harness.environment.configFile
        XCTAssertEqual(link(config.path, harness.environment.logFile.path), 0)
        let state = await harness.ready()
        let before = try Data(contentsOf: config)
        state.logStore.log(.notice, "composition witness")
        state.logStore.flushFileLog()
        let refusals = state.eventLog.events.filter { $0.event == RecordFileDestinationGate.eventName }
        XCTAssertEqual(refusals.map(\.detail), ["sink=log reason=protected_identity resource=config"])
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testAnAppLogAliasOfTheWriterLeaseIsRefusedAndTheLeaseKeepsItsAuthority() async throws {
        let harness = try makeHarness()
        let lease = harness.stateSession.writerLeaseFile
        let before = try writerLeaseFingerprint(lease)
        XCTAssertEqual(link(lease.path, harness.environment.logFile.path), 0)
        let state = await harness.ready()
        state.logStore.log(.notice, "lease witness")
        state.logStore.flushFileLog()
        let refusals = state.eventLog.events.filter { $0.event == RecordFileDestinationGate.eventName }
        XCTAssertEqual(refusals.map(\.detail), ["sink=log reason=protected_identity resource=writer_lease"])
        XCTAssertEqual(try writerLeaseFingerprint(lease), before, "the lock keeps its bytes and its inode")
        assertSecondWriterIsBusy(RuntimeEnvironment.isolated(stateDirectory: harness.stateDirectory))
    }

    // MARK: App log at Quit

    /// Settings' own toggle gives the file log a fresh writer, and its open is held in the composition's app-log guard effect, before the
    /// authoritative guard. The line logged next waits there, on the writer's queue, never on main.
    private func holdTheAppLogOpen(_ state: AppState, _ harness: AppStateHarness, witness: String) {
        state.logStore.logFileURL = nil
        harness.appLogHold.arm(1)
        state.logStore.logFileURL = harness.environment.logFile
        state.logStore.log(.notice, witness)
        XCTAssertEqual(Self.joined(harness.appLogHold.entered), .success, "the file log's open is held")
    }

    /// The bounded join for a hold, in a synchronous function: the compiler rejects the wait inside async code.
    private static func joined(_ signal: DispatchSemaphore) -> DispatchTimeoutResult {
        signal.wait(timeout: .now() + 10)
    }

    private func logFlushOutcomes(_ state: AppState, source: LifecycleLogFlushSource) -> [LifecycleLogFlushOutcome] {
        state.eventLog.events.compactMap { event in
            guard case .lifecycle(.logFlushUnconfirmed(let value))? = event.typed, value.source == source else { return nil }
            return value.outcome
        }
    }

    /// A held file log through the Quit. The host's logger drain ends at its own bounded wait, inside the Quit's deadline, and records
    /// its typed fact; the app's tail drain, under the same deadline, finds that wait's reservation still held and records `busy`
    /// without waiting again. The Quit still completes inside its one budget. Released, the held lines reach the file: nothing was lost.
    func testAHeldAppLogLeavesBothFinalDrainsUnconfirmedInsideTheQuitBudget() async throws {
        let harness = try makeHarness()
        harness.timing.quitTotal = .seconds(4)
        let state = await harness.ready()
        holdTheAppLogOpen(state, harness, witness: "held tail witness")

        let started = ContinuousClock.now
        XCTAssertTrue(state.beginQuit())
        let result = await state.finishQuit()
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "the Quit ended inside its one budget")
        guard case .settled(.completed)? = result?.quit else { return XCTFail("the Quit completed: \(String(describing: result?.quit))") }

        let hostLine = "Lifecycle: lifecycle.log_flush_unconfirmed source=host outcome=timed_out"
        // The host logs from its owner, so its line reaches the app's history through the store's off-main hand-off.
        await harness.settle("the host's derived line") { state.logStore.entries.contains { $0.message == hostLine } }
        XCTAssertEqual(logFlushOutcomes(state, source: .app), [.busy], "the app's tail did not wait a second time")
        let appLine = "Lifecycle: lifecycle.log_flush_unconfirmed source=app outcome=busy"
        XCTAssertEqual(state.logStore.entries.filter { $0.message == appLine }.count, 1, "the app's event has its one derived line")
        // The host drains its logger before its artifact flush, so a completed Quit's confirmed events flush already covered the fact.
        XCTAssertTrue(harness.hostEventsText.contains(#""detail":"source=host outcome=timed_out""#), "the host's event is in its own file")

        harness.appLogHold.release()
        XCTAssertTrue(state.logStore.flushFileLog(timeout: 5), "the held writes drained once released")
        let file = try String(contentsOf: harness.environment.logFile, encoding: .utf8)
        for line in ["held tail witness", hostLine, appLine] {
            XCTAssertTrue(file.contains(line), "\(line) reached the file")
        }
        XCTAssertEqual(state.logStore.statistics.droppedRecords, 0, "slowness is not loss")
    }

    /// A Quit whose deadline passes while the host still waits on the held file log. The host's drain is cut to the quit's deadline, and
    /// the app's tail, past that same deadline, records `skipped_budget` and waits for nothing: no step gets a fresh budget.
    func testAQuitPastItsDeadlineGivesTheAppLogTailNoFreshBudget() async throws {
        let harness = try makeHarness()
        harness.timing.quitTotal = .seconds(1)
        let state = await harness.ready()
        holdTheAppLogOpen(state, harness, witness: "expired tail witness")

        let started = ContinuousClock.now
        XCTAssertTrue(state.beginQuit())
        _ = await state.finishQuit()
        // The host's own 2 s logger wait, or any fresh tail wait, would end later than this.
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(1_900), "the Quit and its tail ended with the one deadline")
        XCTAssertEqual(logFlushOutcomes(state, source: .app), [.skippedBudget])
        // The host logs from its owner, so its line reaches the app's history through the store's off-main hand-off.
        await harness.settle("the host's drain was cut to the quit's deadline") {
            state.logStore.entries.contains { $0.message == "Lifecycle: lifecycle.log_flush_unconfirmed source=host outcome=timed_out" }
        }
    }

    // MARK: Updates

    /// The first launch of a new version records the change once, as its typed value, and the update state remembers this version.
    func testTheFirstLaunchOfANewVersionRecordsTheChange() async throws {
        let harness = try makeHarness()
        try UpdateStateStore(file: harness.environment.updateStateFile).save(UpdateState(lastLaunchedVersion: "0.4.1"))
        harness.currentVersion = "0.5.0"
        let state = await harness.ready()
        let changes = state.eventLog.events.compactMap(\.typed).filter {
            if case .lifecycle(.versionChanged) = $0 { true } else { false }
        }
        XCTAssertEqual(changes, [.lifecycle(.versionChanged(LifecycleVersionChanged(from: "0.4.1", to: "0.5.0")))])
        XCTAssertEqual(UpdateStateStore(file: harness.environment.updateStateFile).load().0.lastLaunchedVersion, "0.5.0")
    }

    /// Automatic checks are off by default, so the launch schedules none. Turning the preference on reaches the coordinator's schedule:
    /// it waits the launch delay (the coordinator's own wait, passed through the composition and answered at once here) and then runs a
    /// background check; the edit itself saves through its own verified receipt. Turning it off again schedules nothing more.
    func testAutomaticChecksFollowThePreference() async throws {
        let harness = try makeHarness()
        let waits = LockedLog<TimeInterval>()
        harness.timing.updateCheckSleep = { delay in
            waits.append(delay)
            // Only the first wait is answered at once; the one the check schedules after it waits until cancelled.
            if waits.values.count > 1 { try await Task.sleep(for: .seconds(3600)) }
        }
        let state = await harness.ready()
        XCTAssertFalse(state.appPreferences.automaticUpdateChecks, "off by default")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(waits.values.isEmpty, "nothing is scheduled while they are off")
        state.appPreferences.automaticUpdateChecks = true
        await harness.settle("the preference scheduled a background check") { harness.updater.starts == [.background] }
        XCTAssertEqual(waits.values.first ?? 0, UpdateCheckSchedule.launchDelay, accuracy: 5, "the first waits the launch delay")
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "update.check_requested" && $0.detail == "source=schedule" })
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertTrue(try AppPreferencesPersistence.load(in: harness.environment).automaticUpdateChecks)
        XCTAssertFalse(state.hasUnsavedEdit)
        let scheduled = waits.values.count
        state.appPreferences.automaticUpdateChecks = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(waits.values.count, scheduled, "turned off, nothing more is scheduled")
        XCTAssertEqual(harness.updater.starts, [.background])
    }

    func testCheckForUpdatesStartsTheInjectedUpdater() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let before = harness.updater.starts.count
        state.checkForUpdates()
        await harness.settle("the updater was started") { harness.updater.starts.count == before + 1 }
        XCTAssertEqual(harness.updater.starts.last, .interactive, "a check the user asked for is interactive")
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "update.check_requested" }, "event first")
    }

    // MARK: Helper policy (L1)

    /// The caller policy the last install reported is kept through a failed install, which is an event; an uninstall clears it; a second
    /// uninstall while one runs is dropped.
    func testTheCallerPolicySurvivesAFailedInstallAndAnUninstallClearsItOnce() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        harness.helper.callerPolicy = .unenforced
        state.installHelper()
        await harness.settle("the install reported its policy") { state.helperCallerPolicy == .unenforced }
        harness.helper.fails = true
        state.installHelper()
        await harness.settle("the failed install is an event") { state.eventLog.events.contains { $0.event == "helper.install_failed" } }
        XCTAssertEqual(state.helperCallerPolicy, .unenforced, "a failed install keeps the last policy")
        harness.helper.fails = false
        state.uninstallHelper()
        state.uninstallHelper()
        await harness.settle("the uninstall cleared the policy") { state.helperCallerPolicy == nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.helper.uninstalls, 1, "a second uninstall while one runs is dropped")
    }

    /// A reinstalled helper whose first reading is busy does not keep the old helper's verdict: the app tells the host the helper was
    /// replaced, so the busy reading of the new one is what shows.
    func testAReinstalledHelperThatIsBusyDoesNotKeepTheOldVerdict() async throws {
        let harness = try makeHarness()
        harness.helper.status = .outdated
        let state = await harness.ready()
        await harness.settle("the old helper's verdict") { state.helperStatus == .outdated }
        harness.helper.statusAfterInstall = .busy
        state.installHelper()
        await harness.settle("the replaced helper's busy reading shows") { state.helperStatus == .busy }
    }

    // MARK: Import, banners and Apply (L3)

    /// A valid import passes the startup gate, becomes the draft and is saved as a commit; the source file keeps its bytes.
    func testAnImportPassesTheGateAndIsSavedAndTheSourceKeepsItsBytes() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        var imported = state.config
        imported.profileName = "Imported witness"
        let source = harness.homeDirectory.appendingPathComponent("import.json")
        try ProxyConfigPersistence.save(imported, to: source)
        let bytes = try Data(contentsOf: source)
        try state.importConfiguration(from: source)
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.profileName, "Imported witness")
        XCTAssertFalse(state.hasUnsavedEdit)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    /// The configuration problem a save showed is cleared by a later save that validates; an error shown since is left alone.
    func testFixingAnInvalidEditClearsOnlyItsOwnConfigurationProblem() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        state.config.proxy.port = 70_000
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertTrue(state.lastErrorMessage?.hasPrefix("Configuration problem") == true)
        state.config.proxy.port = 8_080
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertNil(state.lastErrorMessage, "the fixed edit cleared its own problem")

        state.config.proxy.port = 70_000
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        state.lastErrorMessage = "a later error"
        state.config.proxy.port = 8_081
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(state.lastErrorMessage, "a later error", "only the problem's own banner is cleared")
    }

    /// Apply commits the text the active field hands over when editing ends, one hop later.
    func testApplyCommitsTheTextAFieldWritesWhenEditingEnds() async throws {
        let harness = try makeHarness()
        let state = await harness.ready()
        let commit = state.commitPendingEdit(trigger: .apply) { state.config.health.checkInterval = 49 }
        await commit.value
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 49)
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.edit_committed" && ($0.detail ?? "").contains("trigger=apply") })
    }
}
