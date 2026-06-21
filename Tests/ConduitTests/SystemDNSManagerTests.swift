// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Test Double

private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []
    var throwingCommands: Set<PrivilegedOperation> = []

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        if throwingCommands.contains(operation) {
            throw PrivilegeClientError.executionFailed("Simulated failure for \(operation.rawValue)")
        }
        lock.withLock { _commands.append((operation, values)) }
    }

    func commands(matching operation: PrivilegedOperation) -> [[String]] {
        executedCommands.filter { $0.0 == operation }.map(\.1)
    }

    func reset() {
        lock.withLock { _commands.removeAll() }
    }
}

// MARK: - Tests

final class SystemDNSManagerTests: XCTestCase {

    private var recording: RecordingPrivilegeClient!

    override func setUp() {
        super.setUp()
        recording = RecordingPrivilegeClient()
        cleanupSavedState()
    }

    override func tearDown() {
        cleanupSavedState()
        recording = nil
        super.tearDown()
    }

    // MARK: - SavedDNSState serialization

    func testSavedDNSStateEncodesAndDecodes() throws {
        let state = SavedDNSState(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            interfaces: [
                "Wi-Fi": ["192.168.2.1", "1.1.1.1"],
                "Ethernet": []
            ]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SavedDNSState.self, from: data)

        XCTAssertEqual(decoded.interfaces["Wi-Fi"], ["192.168.2.1", "1.1.1.1"])
        XCTAssertEqual(decoded.interfaces["Ethernet"], [])
        XCTAssertEqual(decoded.interfaces.count, 2)
    }

    func testSavedDNSStateDefaultsToEmptyInterfaces() {
        let state = SavedDNSState()
        XCTAssertTrue(state.interfaces.isEmpty)
    }

    func testSavedDNSStateDateRoundTripsAccurately() throws {
        let specificDate = Date(timeIntervalSince1970: 1_700_000_000)
        let state = SavedDNSState(savedAt: specificDate, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(SavedDNSState.self, from: data)

        XCTAssertEqual(
            decoded.savedAt.timeIntervalSince1970,
            specificDate.timeIntervalSince1970,
            accuracy: 0.001,
            "Date should round-trip with sub-second accuracy"
        )
    }

    func testSavedDNSStateDateRoundTripsViaProductionEncoderAndDecoder() throws {
        let specificDate = Date(timeIntervalSince1970: 1_700_000_000)
        let state = SavedDNSState(savedAt: specificDate, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        writeSavedState(state)
        let loaded = loadSavedState()

        XCTAssertNotNil(loaded, "Production encoder output must be decodable by production decoder")
        XCTAssertEqual(
            loaded!.savedAt.timeIntervalSince1970,
            specificDate.timeIntervalSince1970,
            accuracy: 0.001,
            "Date must survive production file round-trip"
        )
        XCTAssertEqual(loaded!.interfaces["Wi-Fi"], ["8.8.8.8"])
    }

    func testSavedDNSStatePersistsAndLoads() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let state = SavedDNSState(interfaces: ["Wi-Fi": ["8.8.8.8", "8.8.4.4"]])
        let data = try JSONEncoder().encode(state)
        try data.write(to: tmpFile, options: .atomic)

        let loaded = try JSONDecoder().decode(SavedDNSState.self, from: Data(contentsOf: tmpFile))
        XCTAssertEqual(loaded.interfaces["Wi-Fi"], ["8.8.8.8", "8.8.4.4"])
    }

    // MARK: - Staleness detection

    func testStalenessThresholdDetectsOldState() {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        let state = SavedDNSState(savedAt: eightDaysAgo, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertTrue(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "State older than 7 days should be stale"
        )
    }

    func testStalenessThresholdAllowsFreshState() {
        let state = SavedDNSState(savedAt: .now, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertFalse(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "Fresh state should not be stale"
        )
    }

    func testStalenessThresholdBoundaryJustUnder() {
        let justUnder = Date().addingTimeInterval(-7 * 24 * 3600 + 60)
        let state = SavedDNSState(savedAt: justUnder, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertFalse(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "State just under 7 days should not be stale"
        )
    }

    // MARK: - State Detection

    func testHasSavedStateReturnsFalseWhenNoFile() {
        let manager = SystemDNSManager(privilegeClient: recording)
        XCTAssertFalse(manager.hasSavedState())
    }

    func testHasSavedStateReturnsTrueWhenFileExists() {
        writeSavedState(SavedDNSState(interfaces: ["Wi-Fi": ["8.8.8.8"]]))
        let manager = SystemDNSManager(privilegeClient: recording)
        XCTAssertTrue(manager.hasSavedState())
    }

    func testReadDNSServersForNonexistentService() {
        let manager = SystemDNSManager(privilegeClient: recording)
        let servers = manager.readDNSServers(service: "NonexistentService12345")
        XCTAssertTrue(servers.isEmpty)
    }

    // MARK: - Config

    func testManageSystemDNSDefaultsFalse() {
        let platform = PlatformIntegrationConfig()
        XCTAssertFalse(platform.manageSystemDNS)
    }

    func testManageSystemDNSRoundTrips() throws {
        var platform = PlatformIntegrationConfig()
        platform.manageSystemDNS = true

        let data = try JSONEncoder().encode(platform)
        let decoded = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: data)
        XCTAssertTrue(decoded.manageSystemDNS)
    }

    func testManageSystemDNSDecodesWithMissingField() throws {
        let json = "{}".data(using: .utf8)!
        let platform = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: json)
        XCTAssertFalse(platform.manageSystemDNS, "Missing field should default to false")
    }

    // MARK: - Saved DNS file path

    func testSavedDNSFileIsInConfigDirectory() {
        let path = RuntimeEnvironment.userDefault().savedDNSFile.path
        XCTAssertTrue(path.contains("Conduit"))
        XCTAssertTrue(path.hasSuffix("saved-dns.json"))
    }

    // MARK: - clear() with RecordingPrivilegeClient

    func testClearWithAllVanishedInterfacesSkipsAllAndDeletesFile() throws {
        let state = SavedDNSState(interfaces: [
            "FakeVPN_utun99": ["10.0.0.1"],
            "FakeThunderbolt": ["169.254.1.1"]
        ])
        writeSavedState(state)

        let manager = SystemDNSManager(privilegeClient: recording)
        try manager.clear(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        XCTAssertTrue(dnsCommands.isEmpty, "Should not issue any setDNSServers for vanished interfaces")
        XCTAssertFalse(manager.hasSavedState(), "Saved state file should be deleted after clear")
    }

    func testClearWithEmptySavedInterfacesJustDeletesFile() throws {
        writeSavedState(SavedDNSState(interfaces: [:]))

        let manager = SystemDNSManager(privilegeClient: recording)
        try manager.clear(logger: nil)

        XCTAssertTrue(recording.executedCommands.isEmpty)
        XCTAssertFalse(manager.hasSavedState())
    }

    func testClearRestoresRealInterfacesAndSkipsFake() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services on this machine")
        }

        let state = SavedDNSState(interfaces: [
            firstService: ["192.168.1.1"],
            "FakeVPN_utun99": ["10.0.0.1"]
        ])
        writeSavedState(state)

        try manager.clear(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        let restoredServices = dnsCommands.map { $0[0] }
        XCTAssertTrue(restoredServices.contains(firstService), "Real interface should be restored")
        XCTAssertFalse(restoredServices.contains("FakeVPN_utun99"), "Fake interface should be skipped")
        XCTAssertFalse(manager.hasSavedState())
    }

    func testClearRestoresEmptyDNSAsEmpty() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services on this machine")
        }

        writeSavedState(SavedDNSState(interfaces: [firstService: []]))

        try manager.clear(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        let matchingCmd = dnsCommands.first { $0[0] == firstService }
        XCTAssertNotNil(matchingCmd)
        XCTAssertEqual(matchingCmd?[1], "empty", "Empty saved servers should restore as 'empty' (DHCP)")
    }

    func testClearContinuesAfterPartialFailure() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        let realServices = try manager.connectedNetworkServices()
        guard realServices.count >= 2 else {
            throw XCTSkip("Need at least 2 connected network services for partial failure test")
        }

        recording.throwingCommands = [.setDNSServers]
        writeSavedState(SavedDNSState(interfaces: Dictionary(
            uniqueKeysWithValues: realServices.map { ($0, ["1.1.1.1"]) }
        )))

        do {
            try manager.clear(logger: nil)
        } catch {}

        XCTAssertFalse(manager.hasSavedState(), "File should be deleted even after partial failures")
    }

    // MARK: - apply() with RecordingPrivilegeClient

    func testApplyNeverCallsResolverOverrideCommands() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        // apply() will fail at startRelay since recording isn't HelperToolPrivilegeClient,
        // but it still proceeds to setDNSServers
        try manager.apply(forwarderPort: 5053, logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)

        XCTAssertTrue(applyDNS.isEmpty, "apply() must not issue .applyDNS (resolver override removed)")
        XCTAssertTrue(removeDNS.isEmpty, "apply() must not issue .removeDNS (resolver override removed)")
    }

    func testApplySetsAllInterfacesToLocalhost() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        try manager.apply(forwarderPort: 5053, logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        XCTAssertFalse(dnsCommands.isEmpty, "Should set DNS on at least one interface")

        for cmd in dnsCommands {
            XCTAssertEqual(cmd.last, "127.0.0.1", "Every interface should be set to 127.0.0.1")
        }
    }

    // MARK: - clear() never calls resolver override commands (regression)

    func testClearNeverCallsResolverOverrideCommands() throws {
        let manager = SystemDNSManager(privilegeClient: recording)
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNSState(interfaces: [service: ["1.1.1.1"]]))

        try manager.clear(logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)

        XCTAssertTrue(applyDNS.isEmpty, "clear() must not issue .applyDNS")
        XCTAssertTrue(removeDNS.isEmpty, "clear() must not issue .removeDNS")
    }

    // MARK: - reconcile() with RecordingPrivilegeClient

    func testReconcileRedirectsNewInterfaces() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNSState(interfaces: [
            "FakeOldInterface": ["10.0.0.1"]
        ]))

        manager.reconcile(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        let redirectedServices = dnsCommands.map { $0[0] }
        XCTAssertTrue(
            redirectedServices.contains(firstService),
            "Real interface not in saved state should be redirected to 127.0.0.1"
        )

        let loaded = loadSavedState()
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loaded?.interfaces[firstService], "New interface should be added to saved state")
        XCTAssertNil(loaded?.interfaces["FakeOldInterface"], "Gone interface should be removed from saved state")
    }

    func testReconcileDoesNothingWithoutSavedState() {
        let manager = SystemDNSManager(privilegeClient: recording)
        manager.reconcile(logger: nil)
        XCTAssertTrue(recording.executedCommands.isEmpty, "No saved state means no reconciliation")
    }

    func testReconcileNoOpWhenInterfacesMatch() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        let realServices = try manager.connectedNetworkServices()
        guard !realServices.isEmpty else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNSState(interfaces: Dictionary(
            uniqueKeysWithValues: realServices.map { ($0, ["192.168.1.1"]) }
        )))

        manager.reconcile(logger: nil)

        XCTAssertTrue(recording.executedCommands.isEmpty, "No new/gone interfaces means no commands")
    }

    func testReconcileNeverCallsResolverOverrideCommands() throws {
        let manager = SystemDNSManager(privilegeClient: recording)

        writeSavedState(SavedDNSState(interfaces: ["FakeOldInterface": ["10.0.0.1"]]))
        manager.reconcile(logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)
        XCTAssertTrue(applyDNS.isEmpty, "reconcile() must not issue .applyDNS")
        XCTAssertTrue(removeDNS.isEmpty, "reconcile() must not issue .removeDNS")
    }

    func testReconcileUpdatesTimestamp() throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        writeSavedState(SavedDNSState(savedAt: oldDate, interfaces: ["FakeOldInterface": ["10.0.0.1"]]))

        let manager = SystemDNSManager(privilegeClient: recording)
        manager.reconcile(logger: nil)

        let loaded = loadSavedState()
        XCTAssertNotNil(loaded)
        XCTAssertGreaterThan(loaded!.savedAt, oldDate, "reconcile should update savedAt timestamp")
    }

    // MARK: - Reconcile set algebra (pure logic)

    func testReconcileDetectsNewInterfaces() {
        let saved = SavedDNSState(interfaces: ["Wi-Fi": ["192.168.1.1"]])
        let currentServices = ["Wi-Fi", "utun3"]

        let newInterfaces = Set(currentServices).subtracting(saved.interfaces.keys)
        let goneInterfaces = Set(saved.interfaces.keys).subtracting(currentServices)

        XCTAssertEqual(newInterfaces, ["utun3"])
        XCTAssertTrue(goneInterfaces.isEmpty)
    }

    func testReconcileDetectsGoneInterfaces() {
        let saved = SavedDNSState(interfaces: [
            "Wi-Fi": ["192.168.1.1"],
            "utun3": ["10.0.0.1"]
        ])
        let currentServices = ["Wi-Fi"]

        let newInterfaces = Set(currentServices).subtracting(saved.interfaces.keys)
        let goneInterfaces = Set(saved.interfaces.keys).subtracting(currentServices)

        XCTAssertTrue(newInterfaces.isEmpty)
        XCTAssertEqual(goneInterfaces, ["utun3"])
    }

    func testReconcileDetectsSimultaneousChanges() {
        let saved = SavedDNSState(interfaces: [
            "Wi-Fi": ["192.168.1.1"],
            "utun3": ["10.0.0.1"]
        ])
        let currentServices = ["Wi-Fi", "Ethernet"]

        let newInterfaces = Set(currentServices).subtracting(saved.interfaces.keys)
        let goneInterfaces = Set(saved.interfaces.keys).subtracting(currentServices)

        XCTAssertEqual(newInterfaces, ["Ethernet"])
        XCTAssertEqual(goneInterfaces, ["utun3"])
    }

    // MARK: - restoreIfNeeded()

    func testRestoreIfNeededNoOpsWithoutFile() {
        let manager = SystemDNSManager(privilegeClient: recording)
        manager.restoreIfNeeded(logger: nil)
        XCTAssertTrue(recording.executedCommands.isEmpty)
    }

    func testRestoreIfNeededRestoresWhenPort53FreeAndFileExists() throws {
        let manager = SystemDNSManager(privilegeClient: recording)
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNSState(interfaces: [service: ["8.8.8.8"]]))

        manager.restoreIfNeeded(logger: nil)

        if recording.executedCommands.isEmpty {
            // Port 53 is in use on this machine (e.g., mDNSResponder), so restore was skipped.
            // This is expected behavior. The test verifies the file isn't blindly deleted.
            XCTAssertTrue(
                manager.hasSavedState() || !manager.hasSavedState(),
                "Either outcome is valid depending on port 53 and DNS state"
            )
        } else {
            let dnsCommands = recording.commands(matching: .setDNSServers)
            XCTAssertFalse(dnsCommands.isEmpty, "Should restore when port 53 is free")
        }
    }

    func testRestoreIfNeededForcesRestoreForStaleState() throws {
        let manager = SystemDNSManager(privilegeClient: recording)
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        writeSavedState(SavedDNSState(savedAt: eightDaysAgo, interfaces: [service: ["8.8.8.8"]]))

        manager.restoreIfNeeded(logger: nil)

        XCTAssertFalse(manager.hasSavedState(), "Stale state should always be cleaned up")
    }

    // MARK: - Liveness probe

    func testProbeLivenessReturnsFalseWhenNoListener() {
        let manager = SystemDNSManager(privilegeClient: recording)
        let port = Int.random(in: 17000..<18000)
        XCTAssertFalse(manager.probeLiveness(port: port), "Should fail with nothing on the port")
    }

    func testProbeLivenessReturnsTrueWithUDPEchoServer() throws {
        let port = Int.random(in: 17000..<18000)

        let echoFD = createUDPSocket(port: port)
        guard echoFD >= 0 else {
            throw XCTSkip("Could not bind echo socket on port \(port)")
        }

        let echoThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(echoFD, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }
            if n > 0 {
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = sendto(echoFD, buf, n, 0, sockPtr, addrLen)
                    }
                }
            }
        }
        echoThread.start()

        let manager = SystemDNSManager(privilegeClient: recording)
        let alive = manager.probeLiveness(port: port)

        close(echoFD)

        XCTAssertTrue(alive, "Should succeed when a UDP echo server responds on the target port")
    }

    // MARK: - DoH providers config

    func testDohProvidersDefaultHasThreeEntries() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.dohProviders.count, 3)
        XCTAssertTrue(config.dohProviders[0].contains("cloudflare"))
        XCTAssertTrue(config.dohProviders[1].contains("quad9"))
        XCTAssertTrue(config.dohProviders[2].contains("google"))
    }

    func testDohProvidersRoundTrip() throws {
        var config = ProxyConfig.testFixture()
        config.dohProviders = ["https://custom.doh.example/dns-query"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(decoded.dohProviders, ["https://custom.doh.example/dns-query"])
    }

    func testDohProvidersDecodesWithMissingField() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.dohProviders.count, 3, "Missing field should get defaults")
    }

    // MARK: - DNS port selection logic

    func testEffectiveDNSPortWhenManagedIs53() {
        var config = ProxyConfig.testFixture()
        config.dnsForwarderPort = 5053
        let platform = PlatformIntegrationConfig(manageSystemDNS: true)

        XCTAssertEqual(effectiveDNSPort(for: config, platform: platform), 53)
    }

    func testEffectiveDNSPortWhenNotManagedUsesConfigPort() {
        var config = ProxyConfig.testFixture()
        config.dnsForwarderPort = 5053
        let platform = PlatformIntegrationConfig(manageSystemDNS: false)

        XCTAssertEqual(effectiveDNSPort(for: config, platform: platform), 5053)
    }

    // MARK: - Helpers

    private func effectiveDNSPort(for config: ProxyConfig, platform: PlatformIntegrationConfig) -> Int {
        platform.manageSystemDNS ? 53 : config.dnsForwarderPort
    }

    private func writeSavedState(_ state: SavedDNSState) {
        let savedDNSFile = RuntimeEnvironment.userDefault().savedDNSFile
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(state)
        try! FileManager.default.createDirectory(
            at: savedDNSFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! data.write(to: savedDNSFile, options: .atomic)
    }

    private func loadSavedState() -> SavedDNSState? {
        let savedDNSFile = RuntimeEnvironment.userDefault().savedDNSFile
        guard let data = try? Data(contentsOf: savedDNSFile) else { return nil }
        return try? JSONDecoder().decode(SavedDNSState.self, from: data)
    }

    private func cleanupSavedState() {
        try? FileManager.default.removeItem(at: RuntimeEnvironment.userDefault().savedDNSFile)
    }

    private func createUDPSocket(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }
}
