// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Harness

/// Stands up a real `AppState` — real orchestrator on ephemeral ports, real
/// managers, real journal file — over a `FakeMachine`, scratch directories,
/// a fake VPN observer and fake login items. Scenarios drive the same entry
/// points the views call and assert on the machine and the journal, the way
/// the daemon host's tests do, not on AppState internals.
///
/// The tested parts of `AppState` were already the pieces pulled out as pure
/// or narrow types: the flag table, the reconcile chain, the VPN gate, launch
/// recovery. What this covers is the composition: start and stop, the
/// ownership guards, termination cleanup, the failed-start revert, and the
/// wiring between the reconciler and the editor.
@MainActor
final class AppStateHarness {
    let stateDirectory: URL
    let environment: RuntimeEnvironment
    let machine: FakeMachine
    let vpn = FakeVPNStatusObserver()
    let loginItems = FakeLoginItems()
    let helper = FakeHelperLifecycle()
    let secrets = InMemorySecretStore()
    /// Holds one machine call, subprocess or privileged, when armed.
    let hold = HeldCall()
    private(set) var appState: AppState?

    init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) throws {
        let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appstate-harness-\(UUID().uuidString)", isDirectory: true)
        self.stateDirectory = stateDirectory
        try FileManager.default.createDirectory(
            at: stateDirectory.appendingPathComponent("home", isDirectory: true),
            withIntermediateDirectories: true
        )
        environment = .isolated(stateDirectory: stateDirectory)
        machine = FakeMachine(resolverDirectory: stateDirectory.appendingPathComponent("resolver", isDirectory: true))
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(platformConfig, in: environment)
        try AppPreferencesPersistence.save(AppPreferences(), in: environment)
    }

    var homeDirectory: URL { stateDirectory.appendingPathComponent("home", isDirectory: true) }

    /// A fresh reader over the journal file. The app's own instance caches
    /// what it loaded, so assertions read the file the way the next launch
    /// will, and seeding before `launch()` writes what a crashed run left.
    var journal: PlatformStateJournal { PlatformStateJournal(fileURL: environment.platformStateFile) }

    @discardableResult
    func launch() -> AppState {
        let machine = self.machine
        let hold = self.hold
        let state = AppState(
            runtimeEnvironment: environment,
            privilegeClient: HoldingPrivilegeClient(base: machine, hold: hold),
            helperLifecycle: helper,
            credentialStore: secrets,
            commandRunner: { launchPath, arguments in
                hold.pass(launchPath, arguments)
                return try machine.run(launchPath, arguments)
            },
            homeDirectory: homeDirectory,
            resolverDirectory: machine.resolverDirectory.path,
            loginItemManager: loginItems.manager,
            vpnStatusMonitor: vpn
        )
        appState = state
        return state
    }

    /// Reports `state` from the VPN observer and waits for the app to take it
    /// in: the hop onto the main actor, the handler, the orchestrator work it
    /// starts and the snapshot that comes back. The observer calls its
    /// handler from inside `emit`, so the delivery is counted by the time
    /// `emit` returns and the drain cannot slip past it.
    func setVPN(_ state: VPNObservedState, file: StaticString = #filePath, line: UInt = #line) async {
        vpn.emit(state)
        await deliveries()
        XCTAssertEqual(appState?.runtimeSnapshot.vpnState, state, "the app sees the VPN \(state)", file: file, line: line)
    }

    /// Waits for every observer delivery in flight, and what each started.
    func deliveries() async {
        await appState?.deliveries.drain()
    }

    /// Joins launch-time crash recovery. Recovery restores the machine and
    /// then releases the journal, off the main actor; a scenario that polled
    /// for the first asserted on the second before it happened, four runs in
    /// twenty (#19).
    func launchRecovery() async {
        await appState?.awaitLaunchRecovery()
    }

    /// Polls until `condition` holds. For the edges that still have no
    /// handle, which today is the listener shutdown `tearDown` waits for;
    /// observer deliveries have `deliveries()` and recovery has
    /// `launchRecovery()`.
    func settle(
        _ what: String,
        timeoutMilliseconds: Int = 3000,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutMilliseconds where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)", file: file, line: line)
    }

    /// Quits the way the app delegate does, then removes the scratch state.
    /// `performTerminationCleanup` queues the listener shutdown on a task
    /// that holds the orchestrator weakly, so the app is kept alive until
    /// the snapshot reports everything stopped; dropped earlier, the real
    /// NIO listeners the scenario bound would outlive the test.
    func tearDown() async {
        if let appState {
            appState.performTerminationCleanup()
            await settle("the runtime has shut down", timeoutMilliseconds: 5_000) {
                appState.runtimeSnapshot.runtimeStatus.state == .stopped
                    && appState.runtimeSnapshot.dnsRunState == .stopped
            }
        }
        appState = nil
        try? FileManager.default.removeItem(at: stateDirectory)
    }
}

// MARK: - Scenarios

@MainActor
final class AppStateHarnessTests: XCTestCase {

    func testDeletedConfigInEstablishedStateCannotBecomeFirstRunDefaults() async throws {
        harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig())
        try FileManager.default.removeItem(at: harness.environment.configFile)
        let state = harness.launch()
        do {
            try await state.startProxy()
            XCTFail("Deleted policy was replaced with first-run defaults")
        } catch is ConfigurationLoadError {}
        state.saveConfig()
        XCTAssertFalse(isRunning(state))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.configFile.path))
    }

    func testLocalhostIsPinnedInListenersAndAdvertisedClientSettings() async throws {
        let state = try launch(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true),
            configure: { $0.localHost = "localhost" }
        )
        try await state.startProxy()
        XCTAssertEqual(state.runtimeSnapshot.bindings.proxyHost, "127.0.0.1")
        XCTAssertEqual(wifi.webProxy.host, "127.0.0.1")
        XCTAssertEqual(wifi.secureWebProxy.host, "127.0.0.1")
        XCTAssertEqual(URL(string: machine.launchdEnvironment["HTTP_PROXY"] ?? "")?.host, "127.0.0.1")
        XCTAssertEqual(URL(string: machine.launchdEnvironment["HTTPS_PROXY"] ?? "")?.host, "127.0.0.1")
    }

    func testCorruptConfigStillRestoresJournaledProxyOnLaunch() async throws {
        harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig())
        let prior = ProxyServiceState(
            webHost: "prior.example.test", webPort: "8080", webEnabled: true,
            secureHost: "prior.example.test", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false, bypassDomains: ["*.local"]
        )
        let journal = harness.journal
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: prior.journalValues)
        journal.markApplied(surface: .systemProxy)
        machine.describe("Wi-Fi") {
            $0.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            $0.secureWebProxy = $0.webProxy
        }
        let corrupt = Data("{".utf8)
        try corrupt.write(to: harness.environment.configFile)
        let state = harness.launch()
        await harness.launchRecovery()
        XCTAssertEqual(wifi.webProxy.host, "prior.example.test", "journal recovery proceeds despite invalid configuration")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        XCTAssertEqual(
            state.eventLog.events.filter { $0.event.hasPrefix("platform.launch_recovery_") }.map(\.detail),
            ["surface=systemDNS reason=nothing_recorded", "surface=systemProxy stale=false", "surface=resolverFile reason=config_unavailable"],
            "the resolver scan needs the config, so it alone is skipped"
        )
        XCTAssertEqual(wifi.bypassDomains, ["*.local"])
        do {
            try await state.startProxy()
            XCTFail("Invalid configuration allowed activation after recovery")
        } catch is ConfigurationLoadError {}
        state.saveConfig()
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), corrupt)
        XCTAssertFalse(isRunning(state))
    }

    func testMalformedPlatformSidecarBlocksActivationAndSaving() async throws {
        try await assertMalformedSidecarBlocksActivation("platform.json")
    }

    func testMalformedPreferencesSidecarBlocksActivationAndSaving() async throws {
        try await assertMalformedSidecarBlocksActivation("preferences.json")
    }

    private func assertMalformedSidecarBlocksActivation(_ filename: String) async throws {
        harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig())
        let path = harness.stateDirectory.appendingPathComponent(filename)
        let corrupt = Data("{".utf8)
        let runtimeBytes = try Data(contentsOf: harness.environment.configFile)
        try corrupt.write(to: path)
        let state = harness.launch()
        do {
            try await state.startProxy()
            XCTFail("Malformed sidecar allowed activation")
        } catch is ConfigurationLoadError {}
        state.saveConfig()
        XCTAssertFalse(isRunning(state))
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), runtimeBytes)
    }

    func testCorruptConfigurationCannotStartOrOverwriteTheFile() async throws {
        harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig())
        let corrupt = Data("{".utf8)
        try corrupt.write(to: harness.environment.configFile)
        let state = harness.launch()
        do {
            try await state.startProxy()
            XCTFail("Corrupt configuration started the proxy")
        } catch is ConfigurationLoadError {}
        await state.startDNS()
        await state.startTunnels()
        state.saveConfig()
        XCTAssertFalse(isRunning(state))
        XCTAssertNotEqual(state.runtimeSnapshot.dnsRunState, .running)
        XCTAssertNotEqual(state.runtimeSnapshot.tunnelsRunState, .running)
        XCTAssertNotNil(state.lastErrorMessage)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), corrupt)
        XCTAssertTrue(machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
    }

    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Ephemeral ports throughout: the harness runs beside whatever else the
    /// machine has bound. One split-DNS entry, so the resolver surface has
    /// a file to write.
    private func makeConfig() -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        return config
    }

    private func launch(
        platform: PlatformIntegrationConfig = PlatformIntegrationConfig(),
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) throws -> AppState {
        var config = makeConfig()
        configure(&config)
        harness = try AppStateHarness(config: config, platformConfig: platform)
        return harness.launch()
    }

    private var machine: FakeMachine { harness.machine }
    private var wifi: FakeMachine.Service { machine.service("Wi-Fi") }

    private func isRunning(_ appState: AppState) -> Bool {
        appState.runtimeSnapshot.runtimeStatus.state == .running
    }

    // MARK: Saves and the editor

    /// The first item on this harness's list. The orchestrator echoes the
    /// config a pass applies through `onConfigChange`, and wiring that echo
    /// back into the editor replaced edits made after the save with the
    /// older save. The reconciler tests cannot reach this: it is wiring.
    func testAnEditMadeAfterASaveSurvivesTheSavesPass() async throws {
        let appState = try launch()

        appState.config.profileName = "saved"
        appState.saveConfig()
        // Before the pass runs: it is a task queued behind this call.
        appState.config.profileName = "edited afterwards"
        await appState.reconciler.drain()

        XCTAssertEqual(appState.config.profileName, "edited afterwards", "the pass must not write its save over newer edits")
        XCTAssertEqual(appState.reconciler.lastReconciledConfig.profileName, "saved", "the pass applied its own save")
        XCTAssertTrue(
            appState.eventLog.events.contains { $0.event == "config.metadata_changed" },
            "and the runtime took the save: \(appState.eventLog.events.map(\.event))"
        )
    }

    /// `startDNS` flips `dnsForwarderEnabled` and saves. That flip is the
    /// lifecycle's own work, already live in the runtime; a pass that
    /// treated it as an edit would restart the forwarder it just started.
    func testStartingTheDNSForwarderAbsorbsItsOwnSave() async throws {
        let appState = try launch()

        await appState.startDNS()

        XCTAssertEqual(appState.runtimeSnapshot.dnsRunState, .running)
        XCTAssertTrue(appState.config.dnsForwarderEnabled, "the persisted intent follows the lifecycle")
        XCTAssertFalse(appState.reconciler.hasPassInFlight, "the save queued no pass")
        XCTAssertFalse(
            appState.eventLog.events.contains { $0.event == "config.dns_restart" },
            "the forwarder was not restarted by its own save"
        )
        XCTAssertTrue(
            try ProxyConfigPersistence.loadAllMigrating(in: harness.environment).config.dnsForwarderEnabled,
            "and the flag reached disk, so the next launch brings DNS up with the proxy"
        )
    }

    // MARK: Off the main actor

    /// The relay restart is a helper round trip and then a probe of up to
    /// two seconds, every thirty seconds while the pipeline is down. It ran
    /// on the main actor (#47).
    func testAFailedLivenessProbeRestartsTheRelayOffTheMainThread() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true))
        await appState.startDNS()
        XCTAssertTrue(machine.dnsRelayRunning, "system DNS came up through the relay")
        let startsBefore = machine.privilege.commands(matching: .startDNSRelay).count
        let onMainBefore = machine.privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count
        XCTAssertEqual(onMainBefore, 0, "`startDNS` asks from the platform work queue too")

        appState.handleDNSHealthResult(alive: false)
        // A second tick while the first restart is out adds nothing.
        appState.handleDNSHealthResult(alive: false)
        await harness.deliveries()

        XCTAssertEqual(machine.privilege.commands(matching: .startDNSRelay).count, startsBefore + 1, "one restart for the two ticks")
        XCTAssertEqual(
            machine.privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count,
            onMainBefore,
            "and the main thread did not wait on the helper for it"
        )
    }

    /// The start and stop surface work: 15 to 30 helper round trips and
    /// `networksetup` reads on a machine with several services, which held
    /// the main thread for as long as they took (#47). Every privileged
    /// write the four paths make is asked for from the platform work queue.
    func testProxyAndDNSStartAndStopWaitOnTheHelperOffTheMainThread() async throws {
        let appState = try launch(
            platform: PlatformIntegrationConfig(
                manageSystemProxy: true,
                manageEnvironmentVariables: true,
                manageDNSResolvers: true,
                manageSystemDNS: true
            )
        )
        await harness.setVPN(.connected)

        try await appState.startProxy()
        await appState.startDNS()
        XCTAssertTrue(wifi.routesThroughAProxy)
        XCTAssertTrue(machine.dnsRelayRunning)
        XCTAssertEqual(machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53")
        await appState.stopDNS()
        await appState.stopProxy()
        XCTAssertFalse(wifi.routesThroughAProxy)
        XCTAssertFalse(machine.dnsRelayRunning)
        XCTAssertNil(machine.resolverFile(for: "corp.example"))

        let asked = Set(machine.privilege.commands.map(\.command))
        XCTAssertTrue(
            asked.isSuperset(of: [.applySystemProxy, .applyDNS, .removeDNS, .setDNSServers, .startDNSRelay, .stopDNSRelay, .setWebProxyEndpoint]),
            "the starts and the stops reached the helper: \(asked)"
        )
        XCTAssertEqual(machine.privilege.mainThreadOperations, [], "and none of it from the main thread")
    }

    /// The start's surface work is held on the queue, and a stop is issued
    /// then. The stop's clear is queued behind the start's apply, so the
    /// machine ends cleared; and the start, overtaken, goes no further — no
    /// login-item repair, no save, no "Proxy Enabled" for a proxy that is
    /// down.
    func testAStopIssuedWhileTheStartAppliesLandsLastAndTheStartGoesNoFurther() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        await harness.launchRecovery()
        // The start's first read of the machine, once its listeners are up.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }

        let start = Task { try await appState.startProxy() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the start's surface work is off the main thread")
        let stop = Task { await appState.stopProxy() }
        // The stop takes the listeners down and then queues its clear, which
        // waits behind the held apply.
        await harness.settle("the stop has taken the listeners down") {
            appState.runtimeSnapshot.runtimeStatus.state == .stopped
        }
        harness.hold.release()
        try await start.value
        await stop.value

        XCTAssertFalse(wifi.routesThroughAProxy, "the stop's clear landed after the start's apply")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        XCTAssertEqual(harness.loginItems.registrations, [], "the overtaken start did nothing after its apply")
        let superseded = appState.eventLog.events.filter { $0.event == "lifecycle.superseded" }
        XCTAssertEqual(superseded.map(\.detail), ["operation=proxy_start generation=1 current=2 reason=superseded"])
    }

    /// A VPN drop handled while the start's apply is out reconciles the
    /// entry files before the apply has written them, and the apply then
    /// writes them for the tunnel as it was when it was queued. The start
    /// puts them where the gate is once its apply returns: a split-DNS file
    /// left with the tunnel down sends its domain, the VPN gateway's own
    /// name included, to servers only the tunnel reaches.
    func testAVPNDropWhileTheStartAppliesLeavesNoEntryFile() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageDNSResolvers: true))
        await harness.setVPN(.connected)
        await harness.launchRecovery()
        // The start's first read of the machine: the entry files come after.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }

        let start = Task { try await appState.startProxy() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the start's surface work is off the main thread")
        await harness.setVPN(.disconnected(reason: .userInitiated))
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "the drop found nothing to remove yet")
        harness.hold.release()
        try await start.value

        XCTAssertTrue(isRunning(appState))
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "no entry file with the tunnel down")
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
    }

    /// Quit while a start's apply is out. The apply goes one manager after
    /// another, and the managers' locks order one operation, not the
    /// sequence, so a quit that cleared in between could clear a surface the
    /// apply then wrote. Termination waits for the platform queue before its
    /// first clear.
    /// Repeated DNS stops while the first is held on a slow helper. Each
    /// used to queue its own teardown behind the first, unbounded; now they
    /// join the one in flight, and one teardown runs.
    func testRepeatedDNSStopsWhileTheFirstIsHeldRunOneTeardown() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true))
        await appState.startDNS()
        XCTAssertTrue(machine.dnsRelayRunning)
        let relayStopsBefore = machine.privilege.commands(matching: .stopDNSRelay).count
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }

        let first = Task { await appState.stopDNS() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        let more = (0..<4).map { _ in Task { await appState.stopDNS() } }
        await harness.settle("the four later stops have arrived") {
            appState.eventLog.events.filter { $0.event == "lifecycle.coalesced" }.count == 4
                || appState.lifecycleGenerations.dns >= 6
        }
        harness.hold.release()
        await first.value
        for task in more { await task.value }

        XCTAssertEqual(machine.privilege.commands(matching: .stopDNSRelay).count - relayStopsBefore, 1, "one teardown for five stops")
        XCTAssertEqual(appState.lifecycleGenerations.dns, 2, "the start and one stop")
        XCTAssertEqual(appState.eventLog.events.filter { $0.event == "lifecycle.coalesced" }.map(\.detail), Array(repeating: "operation=dns_stop joined=2", count: 4))
        XCTAssertFalse(machine.dnsRelayRunning)
        XCTAssertEqual(appState.runtimeSnapshot.dnsRunState, .stopped)
    }

    /// Quit while a start's platform step is held on a slow helper. Quit
    /// waits for the queue only so long, then clears; the held step's own
    /// manager is cleared after the step, by that manager's lock, and the
    /// start stops at its next step.
    func testQuitWhileAStartIsHeldProceedsAfterTheDeadline() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageDNSResolvers: true))
        appState.terminationDrainDeadlineMilliseconds = 200
        await harness.setVPN(.connected)
        await harness.launchRecovery()
        // The environment step: the system proxy is already applied.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/bin/launchctl" && arguments.first == "setenv"
        }
        let start = Task { try await appState.startProxy() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        XCTAssertTrue(wifi.routesThroughAProxy, "the system proxy step landed before the hold")

        // Quit blocks the main thread, so the hold is watched and let go from
        // another. It releases as soon as quit has cleared the system proxy
        // with the start still held; the cap only ends a quit that never does.
        let machine = self.machine
        let hold = harness.hold
        let clearedWhileHeld = LockedCount()
        DispatchQueue.global().async {
            var cleared = 0
            for _ in 0..<10_000 {
                if !machine.service("Wi-Fi").routesThroughAProxy { cleared = 1; break }
                usleep(1_000)
            }
            clearedWhileHeld.set(cleared)
            hold.release()
        }
        appState.performTerminationCleanup()
        try await start.value

        XCTAssertEqual(clearedWhileHeld.value, 1, "quit cleared the system proxy while the start was still held")
        XCTAssertTrue(
            appState.eventLog.events.contains { $0.event == "lifecycle.termination_drain_expired" && $0.detail == "deadline_ms=200" },
            "and said it stopped waiting"
        )
        XCTAssertFalse(wifi.routesThroughAProxy)
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"], "the held environment step was cleared after it landed")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.launchdEnvironment))
        XCTAssertEqual(machine.privilege.commands(matching: .applyDNS), [], "the step after the held one never ran")
        XCTAssertNil(machine.resolverFile(for: "corp.example"))
    }

    /// A restart whose start a stop overtakes did not restart anything, and
    /// must not say it did.
    func testARestartOvertakenByAStopDoesNotReportARestart() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        await harness.launchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let restart = Task { await appState.restartProxyLifecycle() }
        await harness.hold.waitUntilReached()
        let stop = Task { await appState.stopProxy() }
        await harness.settle("the stop has begun") { appState.lifecycleGenerations.proxy == 2 }
        harness.hold.release()
        let outcome = await restart.value
        await stop.value

        XCTAssertEqual(outcome, .notStarted, "no \"Proxy Restarted\" for a proxy the stop took down")
        XCTAssertFalse(wifi.routesThroughAProxy)
    }

    func testQuittingWhileAStartAppliesClearsAfterTheApply() async throws {
        let appState = try launch(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)
        )
        await harness.launchRecovery()
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await appState.startProxy() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the start's surface work is off the main thread")

        // Termination blocks the main thread, so the hold is let go from
        // another. What it finds is counted: with the wait, termination has
        // asked the helper for nothing while the apply is still held. The
        // pause only gives a termination that does not wait the time to
        // show it; one that waits passes whatever it is.
        let machine = self.machine
        let hold = harness.hold
        let commandsBefore = machine.privilege.commands.count
        let commandsAtRelease = LockedCount()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            commandsAtRelease.set(machine.privilege.commands.count)
            hold.release()
        }
        appState.performTerminationCleanup()
        try await start.value

        XCTAssertEqual(commandsAtRelease.value, commandsBefore, "termination asked for nothing while the apply was out")
        XCTAssertFalse(wifi.routesThroughAProxy, "termination's clear landed after the start's apply")
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.launchdEnvironment))
        XCTAssertEqual(harness.loginItems.registrations, [], "and the start went no further")
    }

    /// The same for the DNS forwarder: a stop issued while the start points
    /// the interfaces at the relay restores them after it, and the start
    /// neither persists "DNS on" nor leaves a health timer that would
    /// restart the relay the stop took down.
    func testADNSStopIssuedWhileTheStartAppliesLandsLast() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true))
        machine.describe("Wi-Fi") { $0.dnsServers = ["192.0.2.53"] }
        await harness.launchRecovery()
        // The relay start inside `SystemDNSManager.apply`, after the capture.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.startDNSRelay.rawValue }

        let start = Task { await appState.startDNS() }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the start's surface work is off the main thread")
        let stop = Task { await appState.stopDNS() }
        await harness.settle("the stop has begun") { appState.lifecycleGenerations.dns == 2 }
        harness.hold.release()
        await start.value
        await stop.value

        XCTAssertFalse(machine.dnsRelayRunning, "the stop's restore landed after the start's apply")
        XCTAssertEqual(wifi.dnsServers, ["192.0.2.53"])
        XCTAssertFalse(appState.config.dnsForwarderEnabled, "the overtaken start did not persist DNS as on")
        XCTAssertFalse(appState.hasDNSHealthTimer, "nor start a health timer")
        XCTAssertEqual(appState.runtimeSnapshot.dnsRunState, .stopped)
        let superseded = appState.eventLog.events.filter { $0.event == "lifecycle.superseded" }
        XCTAssertEqual(superseded.map(\.detail), ["operation=dns_start generation=1 current=2 reason=superseded"])
    }

    /// The probe that asks for a restart ran a moment ago. A stop that
    /// finished since has released the surface, and a relay started after it
    /// would hold :53 and forward to a port nothing listens on.
    func testARelayRestartThatFindsSystemDNSReleasedStartsNothing() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true))
        await appState.startDNS()
        await appState.stopDNS()
        XCTAssertFalse(machine.dnsRelayRunning)
        let startsBefore = machine.privilege.commands(matching: .startDNSRelay).count

        appState.handleDNSHealthResult(alive: false)
        await harness.deliveries()

        XCTAssertEqual(machine.privilege.commands(matching: .startDNSRelay).count, startsBefore)
        XCTAssertFalse(machine.dnsRelayRunning)
    }

    /// An uninstall waits on an admin password dialog. The window that asked
    /// for it keeps drawing, and a failure still reaches the user.
    func testHelperUninstallRunsOffTheMainActorAndReportsFailure() async throws {
        let appState = try launch()

        appState.uninstallHelper()
        // Dropped: the first is still out.
        appState.uninstallHelper()
        await harness.deliveries()
        XCTAssertEqual(harness.helper.uninstalls, 1)
        XCTAssertNil(appState.lastErrorMessage)

        harness.helper.fails = true
        appState.uninstallHelper()
        await harness.deliveries()
        XCTAssertNotNil(appState.lastErrorMessage, "the refusal is shown, not dropped")
    }

    // MARK: Flags and the machine

    /// The login item needs no runtime and must not wait for the pass: a
    /// quit right after the save would lose it. Pins the registration seam.
    func testFlippingLaunchAtLoginRegistersBeforeThePassRuns() throws {
        let appState = try launch()

        appState.platformConfig.launchAtLogin = true
        appState.saveConfig()
        XCTAssertEqual(harness.loginItems.registrations, [true], "registered synchronously, inside saveConfig")

        appState.platformConfig.launchAtLogin = false
        appState.saveConfig()
        XCTAssertEqual(harness.loginItems.registrations, [true, false])
    }

    /// The system proxy follows its switch through the whole stack: the
    /// start applies it, the switch-off save clears it, and the machine
    /// ends where the last save said, with the journal released.
    func testTheSystemProxyFollowsItsSwitch() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))

        try await appState.startProxy()
        XCTAssertTrue(isRunning(appState))
        XCTAssertEqual(wifi.webProxy, FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "0"))
        XCTAssertEqual(wifi.secureWebProxy.enabled, true)
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "the journal holds the prior state")

        appState.platformConfig.manageSystemProxy = false
        appState.saveConfig()
        await appState.reconciler.drain()

        XCTAssertFalse(wifi.routesThroughAProxy, "cleared while the proxy keeps running")
        XCTAssertTrue(isRunning(appState))
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "and the journal was released")
    }

    // MARK: Ownership guards on stop

    /// The guard from #13: a stop clears a surface when the switch is on
    /// *or* the journal says the surface is ours. Here the switch-off pass
    /// tried to clear and the machine refused, so the switch is off, the
    /// flag is left unreconciled, and the journal still holds the prior.
    /// Stop must clear it anyway.
    func testStopClearsASystemProxyTheSwitchNoLongerNamesWhenTheJournalOwnsIt() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        try await appState.startProxy()

        machine.privilege.failing = [.setWebProxyEndpoint]
        appState.platformConfig.manageSystemProxy = false
        appState.saveConfig()
        await appState.reconciler.drain()
        XCTAssertTrue(wifi.routesThroughAProxy, "the clear did not land")
        XCTAssertFalse(harness.journal.knowsSurfaceIsIdle(.systemProxy), "so the records were kept")
        XCTAssertTrue(appState.reconciler.lastReconciledPlatformConfig.manageSystemProxy, "and the flag is unreconciled")

        machine.privilege.failing = []
        await appState.stopProxy()

        XCTAssertFalse(wifi.routesThroughAProxy, "stop cleared by ownership, not by the switch")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
    }

    /// Same guard, resolver files: with the switch off only the journal can
    /// tell our file from one the user keeps by hand for the same domain.
    func testStopRemovesAResolverFileTheSwitchNoLongerNamesWhenTheJournalOwnsIt() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
        await harness.setVPN(.connected)
        try await appState.startProxy()
        XCTAssertEqual(machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53")

        machine.privilege.failingDomains = ["corp.example"]
        appState.platformConfig.manageDNSResolvers = false
        appState.saveConfig()
        await appState.reconciler.drain()
        XCTAssertNotNil(machine.resolverFile(for: "corp.example"), "the removal did not land")
        XCTAssertTrue(harness.journal.hasRecords(for: .resolverFile), "so the file is still recorded as ours")

        machine.privilege.failingDomains = []
        await appState.stopProxy()

        XCTAssertNil(machine.resolverFile(for: "corp.example"), "stop removed it by ownership")
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
    }

    /// A user's own resolver file for a configured domain, with the switch
    /// off, is not ours: nothing recorded it, so stop leaves it alone.
    func testStopLeavesAResolverFileTheUserWroteWhenTheSwitchIsOff() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: false))
        try machine.strandResolverFile(for: "corp.example", contents: "nameserver 10.0.0.53")
        try await appState.startProxy()

        await appState.stopProxy()

        XCTAssertEqual(machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53", "not ours, not touched")
        XCTAssertTrue(machine.privilege.commands(matching: .removeDNS).isEmpty)
    }

    // MARK: Quit

    /// The pass is a task queued behind the save. A quit that lands before
    /// it runs must still clear the surface: termination clears whatever
    /// the journal says is ours, whatever the switch says now.
    func testQuittingBeforeAQueuedPassRunsStillClearsTheSurface() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        try await appState.startProxy()
        XCTAssertTrue(wifi.routesThroughAProxy)

        appState.platformConfig.manageSystemProxy = false
        appState.saveConfig()
        XCTAssertTrue(appState.reconciler.hasPassInFlight, "the pass has not run yet")
        appState.performTerminationCleanup()

        XCTAssertFalse(wifi.routesThroughAProxy, "quit cleared it before the pass ran")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))

        // The pass still runs; its clear finds nothing to do and nothing to undo.
        await appState.reconciler.drain()
        XCTAssertFalse(wifi.routesThroughAProxy)
        XCTAssertEqual(wifi.webProxy.host, "", "the prior had no address, so ours did not stay behind disabled")
    }

    // MARK: Failed start

    /// A start that fails reverts whatever it finds applied, whether or not
    /// this process applied it. The residue here is what a killed run
    /// leaves: a proxied service, a published launchd variable and a
    /// resolver file, none of it recorded.
    func testAFailedStartRevertsEverySurfaceItFindsApplied() async throws {
        let appState = try launch(
            platform: PlatformIntegrationConfig(
                manageSystemProxy: true,
                manageEnvironmentVariables: true,
                manageDNSResolvers: true
            )
        )
        machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
        }
        machine.launchdEnvironment = ["HTTP_PROXY": "http://127.0.0.1:47113", "https_proxy": "http://127.0.0.1:47113"]
        try machine.strandResolverFile(for: "corp.example", contents: "nameserver 10.0.0.53")

        // Rejected by `ProxyConfig.validate()`, so the start fails at once
        // instead of spending the bind retry budget. Edited, not saved, so
        // the failure is the start's alone.
        appState.config.maxConnections = 0
        do {
            try await appState.startProxy()
            XCTFail("a config the kernel rejects must fail the start")
        } catch {
            // Expected.
        }

        XCTAssertFalse(isRunning(appState))
        XCTAssertFalse(wifi.routesThroughAProxy, "the proxied service was switched off")
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"], "the launchd variables were cleared")
        XCTAssertNil(machine.launchdEnvironment["https_proxy"])
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "the resolver file was removed")
    }

    // MARK: VPN

    /// Entry files live and die with the tunnel their servers sit behind.
    /// A drop removes them while the proxy keeps running; a reconnect puts
    /// them back.
    func testEntryFilesFollowTheVPN() async throws {
        let appState = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
        await harness.setVPN(.connected)
        try await appState.startProxy()
        XCTAssertEqual(machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53")

        await harness.setVPN(.disconnected(reason: .userInitiated))
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "the entry file is removed")
        XCTAssertTrue(isRunning(appState), "the proxy itself stays up")

        await harness.setVPN(.connected)
        XCTAssertNotNil(machine.resolverFile(for: "corp.example"), "the entry file is back")
    }

    /// The interface name belongs to the delivery it came with, read on the
    /// observer's turn rather than after the main-actor hop.
    func testVPNInterfaceNameIsTheOneDeliveredWithTheState() async throws {
        let appState = try launch()
        harness.vpn.connectedInterfaceName = "utun4"
        harness.vpn.emit(.connected)
        harness.vpn.connectedInterfaceName = "utun9"
        await harness.deliveries()

        XCTAssertEqual(appState.runtimeSnapshot.vpnState, .connected)
        XCTAssertEqual(appState.runtimeSnapshot.vpnInterfaceName, "utun4")
    }

    // MARK: Launch

    /// Crash recovery: a journal recording the user's proxy, a machine still
    /// pointed at a port nothing serves. Launch restores the user's settings
    /// before anything else touches the surface, and the start that follows
    /// captures the user's proxy as the prior — not our own dead port.
    func testLaunchRestoresTheProxyACrashedRunLeftBehind() async throws {
        var config = makeConfig()
        config.localPort = 0
        let platform = PlatformIntegrationConfig(manageSystemProxy: true)
        harness = try AppStateHarness(config: config, platformConfig: platform)

        let corporate = ProxyServiceState(
            webHost: "proxy.corp.example", webPort: "8080", webEnabled: true,
            secureHost: "proxy.corp.example", securePort: "8080", secureEnabled: true,
            autoURL: "", autoEnabled: false,
            bypassDomains: ["*.local"]
        )
        let seeded = harness.journal
        seeded.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: corporate.journalValues)
        seeded.markApplied(surface: .systemProxy)
        machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
            service.bypassDomains = ["localhost"]
        }

        let appState = harness.launch()
        await harness.launchRecovery()
        XCTAssertEqual(
            wifi.webProxy,
            FakeMachine.ProxyEndpoint(enabled: true, host: "proxy.corp.example", port: "8080"),
            "recovery restores the corporate proxy"
        )
        XCTAssertEqual(wifi.bypassDomains, ["*.local"])
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "restored, so released")
        let recovery = appState.eventLog.events.filter { $0.event.hasPrefix("platform.launch_recovery_") }
        XCTAssertEqual(
            recovery.map(\.event),
            ["platform.launch_recovery_nothing_to_do", "platform.launch_recovery_restored", "platform.launch_recovery_adopted"],
            "one event per surface, in recovery's order"
        )
        XCTAssertEqual(recovery.map { $0.detail?.split(separator: " ").first }, ["surface=systemDNS", "surface=systemProxy", "surface=resolverFile"])
        XCTAssertEqual(recovery.dropFirst().first?.detail, "surface=systemProxy stale=false")

        try await appState.startProxy()
        XCTAssertEqual(wifi.webProxy, FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "0"))
        guard case .wasPresent(let prior) = harness.journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("the start recorded a prior for Wi-Fi")
        }
        XCTAssertEqual(
            ProxyServiceState(journalValues: prior).webHost,
            "proxy.corp.example",
            "the prior the start captured is the user's proxy, not the crashed run's port"
        )
    }
}
