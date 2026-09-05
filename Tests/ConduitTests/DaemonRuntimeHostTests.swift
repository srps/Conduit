// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitDaemon
@testable import PlatformMac
@testable import ProxyKernel

@MainActor
final class DaemonRuntimeHostTests: XCTestCase {

    func testConfigGenerationStartsAtZeroAndIncrementsOnReload() async throws {
        let environment = RuntimeEnvironment.isolated(
            stateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: environment.configDirectory) }

        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Initial"
        try ProxyConfigPersistence.save(config, in: environment)

        let loaded = ProxyConfigPersistence.loadAllMigrating(in: environment)
        let host = DaemonRuntimeHost(
            environment: environment,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            vpnStatusMonitor: FakeVPNStatusObserver()
        )

        XCTAssertEqual(host.status().configGeneration, 0)

        config.profileName = "Reloaded"
        try ProxyConfigPersistence.save(config, in: environment)
        await host.reloadConfiguration()

        XCTAssertEqual(host.status().configGeneration, 1)
        XCTAssertEqual(host.status().profileName, "Reloaded")
    }

    func testVPNObserverDrivesOrchestratorState() async {
        let environment = RuntimeEnvironment.isolated(
            stateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: environment.configDirectory) }

        let observer = FakeVPNStatusObserver()
        let loaded = RuntimeConfigurationLoadResult(
            config: GenericDefaults.shared.makeConfig(),
            platformConfig: PlatformIntegrationConfig(),
            appPreferences: AppPreferences(),
            migrated: false,
            warnings: []
        )
        let host = DaemonRuntimeHost(
            environment: environment,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            vpnStatusMonitor: observer
        )

        // The host wires the observer callback during init. Drive the fake
        // observer directly rather than starting the full runtime (which may
        // perform network listener work depending on local config).
        observer.start()
        defer { observer.stop() }

        observer.emit(.connected)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .connected)
    }

    /// A start that fails must revert the platform side effects rather than
    /// leave them naming listeners that are not running.
    ///
    /// The old `startRuntime` let the error out of `orchestrator.startProxy()`
    /// untouched, so anything a previous run had applied stayed applied:
    /// `/etc/resolver/<domain>` files pointing at a forwarder that is down, and
    /// a system PAC setting naming a PAC port nothing serves. Those outlive the
    /// process and break DNS and proxying for *every* client on the machine,
    /// and nothing else clears them — the only other cleanup path is an
    /// explicit stop, which nobody issues for a runtime that never came up.
    ///
    /// Only `manageDNSResolvers` is enabled here: it is the one side effect
    /// that runs entirely through the injected privilege client. System-proxy
    /// and environment cleanup shell out to `networksetup`/`launchctl` against
    /// the real machine, which a test must not do.
    func testFailedStartRevertsPlatformSideEffects() async throws {
        let environment = RuntimeEnvironment.isolated(
            stateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: environment.configDirectory) }

        var config = GenericDefaults.shared.makeConfig()
        config.dnsEntries = [DomainDNSEntry(domain: "revert-test.example", servers: ["10.9.9.9"])]
        // Rejected by `ProxyConfig.validate()`, so the start fails immediately
        // instead of spending the bind retry budget on a contended port.
        config.maxConnections = 0

        let recording = RecordingPrivilegeClient()
        let host = DaemonRuntimeHost(
            environment: environment,
            logger: DiscardingLogSink(),
            loadedConfiguration: RuntimeConfigurationLoadResult(
                config: config,
                platformConfig: PlatformIntegrationConfig(manageDNSResolvers: true),
                appPreferences: AppPreferences(),
                migrated: false,
                warnings: []
            ),
            vpnStatusMonitor: FakeVPNStatusObserver(),
            privilegeClient: recording
        )

        do {
            try await host.startRuntime()
            XCTFail("start should fail on a config the kernel rejects")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            recording.commands(matching: .removeDNS).compactMap(\.first),
            ["revert-test.example"],
            "a failed start must not strand resolver files pointing at listeners that never came up"
        )
    }

    // MARK: - Ownership guards, twins of the `AppState` scenarios

    /// A host over a `FakeMachine`, the way `AppStateHarness` builds the app:
    /// every subprocess and privileged write lands on the model, resolver
    /// files in a scratch directory, and the journal file under the
    /// isolated environment.
    @MainActor
    private final class DaemonHarness {
        let environment: RuntimeEnvironment
        let machine: FakeMachine
        let vpn = FakeVPNStatusObserver()
        private let stateDirectory: URL

        init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) throws {
            let stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pm-daemon-harness-\(UUID().uuidString)", isDirectory: true)
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

        /// A fresh reader over the journal file; the host's own instance
        /// caches what it loaded.
        var journal: PlatformStateJournal { PlatformStateJournal(fileURL: environment.platformStateFile) }

        var wifi: FakeMachine.Service { machine.service("Wi-Fi") }

        func makeHost() -> DaemonRuntimeHost {
            let machine = self.machine
            return DaemonRuntimeHost(
                environment: environment,
                logger: DiscardingLogSink(),
                loadedConfiguration: ProxyConfigPersistence.loadAllMigrating(in: environment),
                vpnStatusMonitor: vpn,
                privilegeClient: machine,
                commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
                homeDirectory: stateDirectory.appendingPathComponent("home", isDirectory: true),
                resolverDirectory: machine.resolverDirectory.path
            )
        }

        /// The switch goes off on disk, the way the app or a hand edit
        /// changes it for the daemon, and the daemon reloads.
        func flip(_ platformConfig: PlatformIntegrationConfig, on host: DaemonRuntimeHost) async throws {
            try PlatformConfigPersistence.save(platformConfig, in: environment)
            await host.reloadConfiguration()
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    private var harness: DaemonHarness!

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    /// Ephemeral ports, one split-DNS entry: the same config the app
    /// scenarios run on.
    private func launch(platform: PlatformIntegrationConfig) throws -> DaemonRuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: platform)
        return harness.makeHost()
    }

    /// The `AppState` scenario of the same name, against its twin. This
    /// used to be a strict expected failure listing what the daemon lacked:
    /// a journal behind its resolver manager, a reconcile pass on a flag
    /// flip, and a stop that clears by ownership. All three came over; the
    /// reload's pass removes the file, and stop has nothing left to do.
    func testStopRemovesAResolverFileTheSwitchNoLongerNamesWhenTheHostWroteIt() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
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
        let host = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
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
        let host = try launch(platform: PlatformIntegrationConfig(manageDNSResolvers: false))
        try harness.machine.strandResolverFile(for: "corp.example", contents: "nameserver 192.168.1.1")
        try await host.startRuntime()
        await host.stopRuntime()

        XCTAssertEqual(harness.machine.resolverFile(for: "corp.example"), "nameserver 192.168.1.1")
    }

    /// The system proxy through the whole stack: the start applies it, a
    /// reload with the switch off clears it while the proxy keeps running,
    /// and the journal is released.
    func testASystemProxySwitchFlippedOffOnReloadClearsItWithoutAStop() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
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
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
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
}
