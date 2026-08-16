// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitDaemon
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

        let recording = RecordingDaemonPrivilegeClient()
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
}

// MARK: - Test Double

private final class RecordingDaemonPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var executed: [(PrivilegedOperation, [String])] = []

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { executed.append((operation, values)) }
    }

    func commands(matching operation: PrivilegedOperation) -> [[String]] {
        lock.withLock { executed }.filter { $0.0 == operation }.map(\.1)
    }
}
