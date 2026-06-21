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
}
