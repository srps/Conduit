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
        let state = AppState(
            runtimeEnvironment: environment,
            privilegeClient: machine,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            homeDirectory: homeDirectory,
            resolverDirectory: machine.resolverDirectory.path,
            loginItemManager: loginItems.manager,
            vpnStatusMonitor: vpn
        )
        appState = state
        return state
    }

    /// Reports `state` from the VPN observer and waits for the app to take it
    /// in. The handler updates the split-DNS gate synchronously before it
    /// hands the state to the orchestrator, so the snapshot is the signal.
    func setVPN(_ state: VPNObservedState, file: StaticString = #filePath, line: UInt = #line) async {
        vpn.emit(state)
        await settle("the app sees the VPN \(state)", file: file, line: line) {
            self.appState?.runtimeSnapshot.vpnState == state
        }
    }

    /// Polls until `condition` holds. The app's observers deliver through
    /// `Task { @MainActor }` hops, so a scenario that drives one waits here.
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
            ProxyConfigPersistence.loadAllMigrating(in: harness.environment).config.dnsForwarderEnabled,
            "and the flag reached disk, so the next launch brings DNS up with the proxy"
        )
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
        await harness.settle("the entry file is removed") { self.machine.resolverFile(for: "corp.example") == nil }
        XCTAssertTrue(isRunning(appState), "the proxy itself stays up")

        await harness.setVPN(.connected)
        await harness.settle("the entry file is back") { self.machine.resolverFile(for: "corp.example") != nil }
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
        await harness.settle("recovery restores the corporate proxy") {
            self.wifi.webProxy == FakeMachine.ProxyEndpoint(enabled: true, host: "proxy.corp.example", port: "8080")
        }
        XCTAssertEqual(wifi.bypassDomains, ["*.local"])
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy), "restored, so released")

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
