// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import RuntimeEvents

/// The process start the harnesses report. Fixed, so no test reads the clock.
private let testStartedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A host test never ends the process. A terminal stop that reaches this hook is a failure.
private let unexpectedTerminalExit: @MainActor () -> Void = { XCTFail("the runtime host ended the process") }

/// A synthetic satisfied path, the report `FakeNetworkPathObserver` delivers in place of `NWPathMonitor`.
private func satisfiedPath() -> NetworkPathState {
    NetworkPathState(
        status: .satisfied, interfaces: [], gateways: [],
        supportsIPv4: true, supportsIPv6: false, supportsDNS: true,
        isExpensive: false, isConstrained: false
    )
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

        let host = RuntimeHost(
            stateSession: session, logger: DiscardingLogSink(),
            loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: FakeVPNStatusObserver(), networkPathObserver: FakeNetworkPathObserver(), privilegeClient: RecordingPrivilegeClient(),
            credentialStore: secrets, kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        let host = RuntimeHost(
            stateSession: session, logger: DiscardingLogSink(),
            loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: FakeVPNStatusObserver(), networkPathObserver: FakeNetworkPathObserver(), privilegeClient: machine, credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(),
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
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Last good config"
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        try ProxyConfigPersistence.save(config, in: environment)
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let host = RuntimeHost(stateSession: session, logger: DiscardingLogSink(),
                                     loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
                                     startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: FakeVPNStatusObserver(), networkPathObserver: FakeNetworkPathObserver(), privilegeClient: machine,
                                     credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(),
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-daemon-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        defer { releaseScratchStateRoot(session) }
        let environment = session.environment

        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Initial"
        try ProxyConfigPersistence.save(config, in: environment)

        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: environment)
        let host = RuntimeHost(
            stateSession: session,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: FakeVPNStatusObserver(), networkPathObserver: FakeNetworkPathObserver(),
            privilegeClient: RecordingPrivilegeClient(), credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        let loaded = RuntimeConfigurationLoadResult(
            config: GenericDefaults.shared.makeConfig(),
            platformConfig: PlatformIntegrationConfig(),
            appPreferences: AppPreferences(),
            migrated: false,
            warnings: []
        )
        let host = RuntimeHost(
            stateSession: session,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: observer, networkPathObserver: FakeNetworkPathObserver(),
            privilegeClient: RecordingPrivilegeClient(), credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        let loaded = RuntimeConfigurationLoadResult(
            config: GenericDefaults.shared.makeConfig(),
            platformConfig: PlatformIntegrationConfig(),
            appPreferences: AppPreferences(),
            migrated: false,
            warnings: []
        )
        let host = RuntimeHost(
            stateSession: session,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: observer, networkPathObserver: FakeNetworkPathObserver(),
            privilegeClient: RecordingPrivilegeClient(), credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        let loaded = RuntimeConfigurationLoadResult(
            config: GenericDefaults.shared.makeConfig(),
            platformConfig: PlatformIntegrationConfig(),
            appPreferences: AppPreferences(),
            migrated: false,
            warnings: []
        )
        let host = RuntimeHost(
            stateSession: session,
            logger: DiscardingLogSink(),
            loadedConfiguration: loaded,
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: observer, networkPathObserver: FakeNetworkPathObserver(),
            privilegeClient: RecordingPrivilegeClient(), credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        let host = RuntimeHost(
            stateSession: session,
            logger: DiscardingLogSink(),
            loadedConfiguration: RuntimeConfigurationLoadResult(
                config: config,
                platformConfig: PlatformIntegrationConfig(manageDNSResolvers: true),
                appPreferences: AppPreferences(),
                migrated: false,
                warnings: []
            ),
            startedAt: testStartedAt, terminalExit: unexpectedTerminalExit, networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil }, vpnStatusMonitor: FakeVPNStatusObserver(), networkPathObserver: FakeNetworkPathObserver(),
            privilegeClient: recording,
            credentialStore: InMemorySecretStore(), kerberosTicketRecovery: FakeKerberosTicketRecovery(), commandRunner: Self.offMachine, homeDirectory: environment.configDirectory.appendingPathComponent("home")
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
        /// The scratch root's writer authority, taken before any seed write. Released by `tearDown`, after the host's work.
        let stateSession: StateRootSession
        let environment: RuntimeEnvironment
        let machine: FakeMachine
        let vpn = FakeVPNStatusObserver()
        let locationObserver = FakeNetworkLocationObserver()
        let pathObserver = FakeNetworkPathObserver()
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
        /// The one host `makeHost` built, owned until `tearDown` has stopped and flushed it.
        private var ownedHost: RuntimeHost?
        let secrets = InMemorySecretStore()
        /// The helper status the split-DNS check reads; never the installed helper.
        let helper = FakeHelperLifecycle()
        /// Long, so a split-DNS helper check never lands inside a scenario
        /// about something else; the check's own scenario passes a short one.
        var splitDNSHelperCheckInterval: Duration = .seconds(3600)
        private let stateDirectory: URL
        /// The scratch home the host edits shell profiles in.
        var homeDirectory: URL { stateDirectory.appendingPathComponent("home", isDirectory: true) }

        init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) throws {
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
        func makeHost() throws -> RuntimeHost {
            if ownedHost != nil {
                XCTFail("this harness already owns a host; a test builds one host and stops it")
            }
            let host = try buildHost()
            ownedHost = host
            return host
        }

        private func buildHost() throws -> RuntimeHost {
            let machine = self.machine
            let listings = self.listings
            let hold = self.hold
            return RuntimeHost(
                stateSession: stateSession,
                logger: DiscardingLogSink(),
                loadedConfiguration: try ProxyConfigPersistence.loadAllMigrating(in: environment),
                startedAt: testStartedAt, terminalExit: terminalExit,
                networkLocationObserver: locationObserver,
                networkLocationStoreFactory: { [locationStore] _ in locationStore },
                networkLocationLimits: locationLimits, vpnStatusMonitor: vpn, networkPathObserver: pathObserver,
                privilegeClient: HoldingPrivilegeClient(base: machine, hold: hold),
                credentialStore: secrets, kerberosTicketRecovery: FakeKerberosTicketRecovery(),
                commandRunner: { launchPath, arguments in
                    if arguments.first == "-listallnetworkservices" { listings.passThrough() }
                    hold.pass(launchPath, arguments)
                    return try machine.run(launchPath, arguments)
                },
                // As `AppStateHarness`: never the real port 53.
                dnsResponds: FakeDNSProbe().responds(onPort:),
                reapplyRetrySchedule: reapplyRetrySchedule,
                helperStatus: helper,
                splitDNSHelperCheckInterval: splitDNSHelperCheckInterval,
                homeDirectory: stateDirectory.appendingPathComponent("home", isDirectory: true),
                resolverDirectory: machine.resolverDirectory.path
            )
        }

        /// The switch goes off on disk, the way the app or a hand edit
        /// changes it for the daemon, and the daemon reloads.
        func flip(_ platformConfig: PlatformIntegrationConfig, on host: RuntimeHost) async throws {
            try PlatformConfigPersistence.save(platformConfig, in: environment)
            await host.reloadConfiguration()
        }

        /// Stops and flushes the owned host, then ends the root's authority and removes the directory. The flush joins the
        /// host's audit, event and snapshot writers, so no file is written while the directory is removed.
        func tearDown() async {
            // A test that failed mid-hold leaves the hold armed, and the stop would wait on it. Releasing is harmless when
            // nothing waits.
            hold.release()
            listings.release()
            if let host = ownedHost {
                await host.stopRuntime()
                await host.flushEvents()
            }
            ownedHost = nil
            releaseScratchStateRoot(stateSession)
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

    private var harness: DaemonHarness!

    // The async override runs on the main actor, where `harness` lives.
    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// Ephemeral ports, one split-DNS entry: the same config the app
    /// scenarios run on.
    private func launch(platform: PlatformIntegrationConfig, dnsForwarderEnabled: Bool = false) throws -> RuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = dnsForwarderEnabled
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        harness = try DaemonHarness(config: config, platformConfig: platform)
        return try harness.makeHost()
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
        let host = try harness.makeHost()
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
    /// than the executable. The non-terminal stop only submits the stopped state, so the explicit flush at the
    /// process boundary must be what confirms it: the readiness flush happened before the stop.
    func testExitAfterReadySequenceConfirmsTheStoppedStateInTheFile() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let snapshotFile = harness.environment.snapshotFile
        let host = try harness.makeHost()
        await host.awaitLaunchRecovery()

        try await host.startRuntime()
        await host.markReady(mode: "runtime-started")
        await host.flushEvents()
        await host.stopRuntime()
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
        let host = try harness.makeHost()
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
        let host = try launch(platform: PlatformIntegrationConfig())
        await host.awaitLaunchRecovery()

        XCTAssertEqual(host.status().daemon?.startedAt, testStartedAt)
        await host.stopRuntime()
    }

    /// The runtime starts and stops the injected path observer, and a report
    /// it delivers reaches the orchestrator as a path decision.
    func testRuntimeDrivesTheInjectedPathObserver() async throws {
        let host = try launch(platform: PlatformIntegrationConfig())
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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

    /// #98, as in `AppState`: the runtime start reads the saved password
    /// once, and the handshakes after it are answered from that read.
    func testRuntimeStartReadsASavedPasswordOnce() async throws {
        let host = try launch(platform: PlatformIntegrationConfig())
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

    /// Twin of `AppStateHarnessTests.testAJournalFromANewerConduitIsReportedAndKeptAtLaunch`.
    func testAJournalFromANewerConduitIsReportedAndKeptAtLaunch() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        harness = try DaemonHarness(config: config, platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        try newer.write(to: harness.environment.platformStateFile)

        let host = try harness.makeHost()
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
            privilegeClient: machine,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            dnsResponds: FakeDNSProbe().responds(onPort:),
            networkLocationStoreFactory: { _ in nil }
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
            privilegeClient: machine,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            dnsResponds: FakeDNSProbe().responds(onPort:),
            networkLocationStoreFactory: { _ in nil }
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

        let host = try harness.makeHost()
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

        let host = try harness.makeHost()
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
        let events = await RuntimeHost.recoverWithoutConfiguration(
            stateSession: harness.stateSession,
            logger: DiscardingLogSink(),
            privilegeClient: machine,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            dnsResponds: FakeDNSProbe().responds(onPort:),
            networkLocationStoreFactory: { _ in nil }
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

    // MARK: - Start and stop off the main actor (#47)

    /// Twin of `AppStateHarnessTests.testProxyAndDNSStartAndStopWaitOnTheHelperOffTheMainThread`:
    /// every privileged write a start and a stop make, system DNS included,
    /// is asked for from the platform work queue.
    func testStartAndStopWaitOnTheHelperOffTheMainThread() async throws {
        let host = try launch(
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
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
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
        try await start.value
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

    /// Twin of `AppStateHarnessTests.testASettingsChangeWhileTheStartAppliesIsReconciledAfterIt`:
    /// a reload's pass waits for the start's platform work, and the machine
    /// ends as the reloaded config says.
    func testAReloadWhileTheStartAppliesIsReconciledAfterIt() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true))
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
        try await start.value
        try await reload.value

        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.wifi.routesThroughAProxy)
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"], "the environment follows the reloaded switch")
        XCTAssertTrue(harness.journal.knowsSurfaceIsIdle(.launchdEnvironment))
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testABypassEditReachesTheAdvertisedSurfacesInManualMode`.
    func testABypassReloadReachesTheAdvertisedSurfacesInManualMode() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try launch(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
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
        await reload.value

        XCTAssertTrue(harness.machine.launchdEnvironment["NO_PROXY"]?.contains("bypass.example") == true)
        await host.stopRuntime()
    }

    /// Twin of `AppStateHarnessTests.testABypassEditInPACModeLeavesTheSystemProxyAlone`.
    func testABypassReloadInPACModeLeavesTheSystemProxyAlone() async throws {
        let host = try launch(platform: PlatformIntegrationConfig(
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
        let host = try launch(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
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
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true))
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try harness.makeHost()
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
        let host = try launch(platform: PlatformIntegrationConfig(manageSystemProxy: true, manageDNSResolvers: true))
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
