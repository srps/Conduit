// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitDaemon
@testable import PlatformMac
@testable import ProxyKernel

@MainActor
final class DaemonRuntimeHostTests: XCTestCase {

    /// The daemon's credentials come from the injected store, not the login
    /// Keychain. Without the seam a host over a fake machine read and wrote
    /// the installed app's Keychain entries, the gap #24's review closed in
    /// `AppState`.
    func testCredentialsComeFromTheInjectedStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-credential-store-\(UUID().uuidString)")
        let environment = RuntimeEnvironment.isolated(stateDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
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

        let host = DaemonRuntimeHost(
            environment: environment, logger: DiscardingLogSink(),
            loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
            configFilePredatesLaunch: true,
            vpnStatusMonitor: FakeVPNStatusObserver(), privilegeClient: RecordingPrivilegeClient(),
            credentialStore: secrets
        )
        // Recovery writes the journal under `directory`; let it land before
        // the `defer` removes it.
        await host.awaitLaunchRecovery()

        let authenticator = try host.orchestrator.lateBoundAuthenticatorProvider(upstream)
        XCTAssertEqual(authenticator.scheme, "NTLM")
    }

    func testMalformedSidecarsRejectReloadWithoutReplacingAnyConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-sidecar-reload-\(UUID().uuidString)")
        let environment = RuntimeEnvironment.isolated(stateDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Last good runtime"
        let platform = PlatformIntegrationConfig(manageSystemProxy: true)
        var preferences = AppPreferences()
        preferences.showMenuBarIcon = false
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(platform, in: environment)
        try AppPreferencesPersistence.save(preferences, in: environment)
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let host = DaemonRuntimeHost(
            environment: environment, logger: DiscardingLogSink(),
            loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
            configFilePredatesLaunch: true,
            vpnStatusMonitor: FakeVPNStatusObserver(), privilegeClient: machine, credentialStore: InMemorySecretStore(),
            commandRunner: { path, arguments in try machine.run(path, arguments) },
            homeDirectory: directory.appendingPathComponent("home"), resolverDirectory: machine.resolverDirectory.path
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
            XCTAssertEqual(host.appPreferences, preferences)
            XCTAssertEqual(host.configGeneration, 0)
            XCTAssertEqual(try Data(contentsOf: path), corrupt)
            XCTAssertEqual(host.orchestrator.eventLog.events.last?.event, "config.reload_rejected")
            try original.write(to: path)
        }
        await host.reloadConfiguration()
        XCTAssertEqual(host.config, candidate)
        XCTAssertEqual(host.configGeneration, 1)
    }

    func testRejectedReloadPreservesTheLastConfigurationAndGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-rejected-reload-\(UUID().uuidString)")
        let environment = RuntimeEnvironment.isolated(stateDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Last good config"
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        try ProxyConfigPersistence.save(config, in: environment)
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let host = DaemonRuntimeHost(environment: environment, logger: DiscardingLogSink(),
                                     loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
                                     configFilePredatesLaunch: true,
                                     vpnStatusMonitor: FakeVPNStatusObserver(), privilegeClient: machine,
                                     credentialStore: InMemorySecretStore(),
                                     commandRunner: { path, arguments in try machine.run(path, arguments) },
                                     homeDirectory: directory.appendingPathComponent("home"), resolverDirectory: machine.resolverDirectory.path)
        let originalPlatform = try Data(contentsOf: environment.platformConfigFile)
        let originalPreferences = try Data(contentsOf: environment.preferencesFile)
        for content in ["{", "{\"localHost\":\"192.0.2.1\",\"manageSystemProxy\":true,\"showMenuBarIcon\":false}"] {
            try Data(content.utf8).write(to: environment.configFile)
            await host.reloadConfiguration()
            XCTAssertEqual(host.config, config)
            XCTAssertEqual(host.configGeneration, 0)
            XCTAssertEqual(host.orchestrator.eventLog.events.last?.event, "config.reload_rejected")
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
        let environment = RuntimeEnvironment.isolated(
            stateDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: environment.configDirectory) }

        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Initial"
        try ProxyConfigPersistence.save(config, in: environment)

        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: environment)
        let host = DaemonRuntimeHost(
            environment: environment,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            configFilePredatesLaunch: true,
            vpnStatusMonitor: FakeVPNStatusObserver(),
            credentialStore: InMemorySecretStore()
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
            configFilePredatesLaunch: false,
            vpnStatusMonitor: observer,
            credentialStore: InMemorySecretStore()
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

    /// The interface name belongs to the delivery it came with. The host
    /// hops to the main actor between the observer's callback and the
    /// orchestrator, so a name read after the hop would be whatever the
    /// monitor had moved on to.
    func testVPNInterfaceNameIsTheOneDeliveredWithTheState() async throws {
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
            configFilePredatesLaunch: false,
            vpnStatusMonitor: observer,
            credentialStore: InMemorySecretStore()
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
            configFilePredatesLaunch: false,
            vpnStatusMonitor: FakeVPNStatusObserver(),
            privilegeClient: recording,
            credentialStore: InMemorySecretStore()
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
        /// Holds the machine's `networksetup` listings when armed, so a
        /// scenario can keep one system DNS reconcile out while more arrive.
        let listings = HeldListings()
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

        func makeHost() throws -> DaemonRuntimeHost {
            let machine = self.machine
            let listings = self.listings
            return DaemonRuntimeHost(
                environment: environment,
                logger: DiscardingLogSink(),
                loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
                // The harness writes the config file before the host exists,
                // the way an established install has one.
                configFilePredatesLaunch: true,
                vpnStatusMonitor: vpn,
                privilegeClient: machine,
                credentialStore: InMemorySecretStore(),
                commandRunner: { launchPath, arguments in
                    if arguments.first == "-listallnetworkservices" { listings.passThrough() }
                    return try machine.run(launchPath, arguments)
                },
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

    private var harness: DaemonHarness!

    // The async override runs on the main actor, where `harness` lives.
    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Ephemeral ports, one split-DNS entry: the same config the app
    /// scenarios run on.
    private func launch(platform: PlatformIntegrationConfig, dnsForwarderEnabled: Bool = false) throws -> DaemonRuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = dnsForwarderEnabled
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: platform)
        return try harness.makeHost()
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

        let host = try harness.makeHost()
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

    /// Readiness never precedes recovery. `daemon.ready` and
    /// `daemon-ready.json` tell a consumer startup is over; published while
    /// recovery was still out, they announced a machine that could still be
    /// pointed at a crashed run's dead proxy port.
    func testReadinessIsPublishedOnlyAfterLaunchRecovery() async throws {
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

        let host = try harness.makeHost()
        await host.markReady(mode: "runtime-host")

        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "restored by the time readiness is published")
        let names = host.orchestrator.eventLog.events.map(\.event)
        let ready = try XCTUnwrap(names.firstIndex(of: "daemon.ready"))
        let restored = try XCTUnwrap(names.firstIndex(of: "platform.launch_recovery_restored"))
        XCTAssertLessThan(restored, ready, "recovery's events come first: \(names)")
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
        let events = await DaemonRuntimeHost.recoverWithoutConfiguration(
            environment: harness.environment,
            logger: DiscardingLogSink(),
            privilegeClient: machine,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) }
        )

        XCTAssertEqual(harness.wifi.webProxy.host, "prior.example.test", "journal recovery proceeds despite the broken file")
        XCTAssertEqual(harness.wifi.bypassDomains, ["*.local"])
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.systemProxy))
        let expected = ["surface=systemDNS reason=nothing_recorded", "surface=systemProxy stale=false", "surface=resolverFile reason=config_unavailable"]
        XCTAssertEqual(events.filter { $0.event.hasPrefix("platform.launch_recovery_") }.map(\.detail), expected)
        let written = try String(contentsOf: harness.environment.eventsFile, encoding: .utf8)
        XCTAssertTrue(written.contains("platform.launch_recovery_restored"), "the events reach events.ndjson: \(written)")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), Data("{".utf8), "the broken file is left for the user")
    }

    /// Twin of `AppStateHarnessTests.testAFailedLivenessProbeRestartsTheRelayOffTheMainThread`.
    func testAFailedLivenessProbeRestartsTheRelayOffTheMainThread() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        try await host.startRuntime()
        let privilege = harness.machine.privilege
        XCTAssertTrue(harness.machine.dnsRelayRunning, "system DNS came up through the relay")
        let startsBefore = privilege.commands(matching: .startDNSRelay).count
        let onMainBefore = privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count

        host.handleDNSHealthResult(alive: false, forwarderPort: 5353)
        host.handleDNSHealthResult(alive: false, forwarderPort: 5353)
        await host.deliveries.drain()

        XCTAssertEqual(privilege.commands(matching: .startDNSRelay).count, startsBefore + 1, "one restart for the two ticks")
        XCTAssertEqual(privilege.mainThreadOperations.filter { $0 == .startDNSRelay }.count, onMainBefore)
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testARelayRestartThatFindsSystemDNSReleasedStartsNothing`.
    func testARelayRestartThatFindsSystemDNSReleasedStartsNothing() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
        try await host.startRuntime()
        await host.stopRuntime()
        let privilege = harness.machine.privilege
        let startsBefore = privilege.commands(matching: .startDNSRelay).count

        host.handleDNSHealthResult(alive: false, forwarderPort: 5353)
        await host.deliveries.drain()

        XCTAssertEqual(privilege.commands(matching: .startDNSRelay).count, startsBefore)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
    }

    /// Every VPN and path notification is its own delivery, and each used to
    /// put a reconcile on the platform work queue. While a helper is held
    /// they would pile up there and drain later as so many stale passes.
    func testSystemDNSReconcilesCoalesceWhileOneIsOut() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemDNS: true), dnsForwarderEnabled: true)
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
}
