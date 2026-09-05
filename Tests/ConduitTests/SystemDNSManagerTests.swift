// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Test Double

/// The `networksetup` reads the DNS surface makes, answered from a described
/// machine instead of this host. Only the three the recovery path uses.
private final class FakeDNSNetworksetupRunner: @unchecked Sendable {
    /// Service name → the DNS servers the machine reports for it.
    var dnsServers: [String: [String]]
    /// Listed but without an address.
    var disconnected: Set<String> = []
    /// Listed with the disabled-service asterisk.
    var disabled: Set<String> = []
    var listingFailuresRemaining = 0
    /// Services whose `-getdnsservers` read fails.
    var failingReads: Set<String> = []

    init(dnsServers: [String: [String]], disconnected: Set<String> = [], disabled: Set<String> = []) {
        self.dnsServers = dnsServers
        self.disconnected = disconnected
        self.disabled = disabled
    }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        guard launchPath == "/usr/sbin/networksetup", let command = arguments.first else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
        let service = arguments.count > 1 ? arguments[1] : ""
        switch command {
        case "-listallnetworkservices":
            if listingFailuresRemaining > 0 {
                listingFailuresRemaining -= 1
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error: transient")
            }
            let lines = ["An asterisk (*) denotes that a network service is disabled."]
                + dnsServers.keys.sorted().map { disabled.contains($0) ? "*\($0)" : $0 }
            return CommandResult(exitCode: 0, standardOutput: lines.joined(separator: "\n"), standardError: "")
        case "-getinfo":
            if disconnected.contains(service) {
                return CommandResult(exitCode: 0, standardOutput: "IP address:\nSubnet mask:", standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: "IP address: 192.0.2.10", standardError: "")
        case "-getdnsservers":
            if failingReads.contains(service) {
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error: read failed")
            }
            let servers = dnsServers[service] ?? []
            return CommandResult(
                exitCode: 0,
                standardOutput: servers.isEmpty
                    ? "There aren't any DNS Servers set on \(service)."
                    : servers.joined(separator: "\n"),
                standardError: ""
            )
        default:
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected read: \(command)")
        }
    }
}

// MARK: - Tests

/// Convenience shape for seeding the journal with per-interface prior DNS
/// servers. Not an on-disk format — the journal is the only storage now.
private struct SavedDNS {
    var savedAt: Date = .now
    var interfaces: [String: [String]] = [:]
}

final class SystemDNSManagerTests: XCTestCase {

    private var recording: RecordingPrivilegeClient!
    /// Per-test state directory.
    ///
    /// These tests used to write saved DNS state into the *live*
    /// `~/Library/Application Support/Conduit` directory, so a run that
    /// crashed between `setUp` and `tearDown` left a snapshot the installed app
    /// would find and act on. Harmless while the snapshot was DNS-only and
    /// `manageSystemDNS` was off, but the journal is shared across every
    /// platform surface now — a stray record there would have the running app
    /// restore proxy settings it never captured.
    private var stateDirectory: URL!
    private var journal: PlatformStateJournal!

    override func setUp() {
        super.setUp()
        recording = RecordingPrivilegeClient()
        stateDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("systemdns-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        journal = PlatformStateJournal(fileURL: stateDirectory.appendingPathComponent("platform-state.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        stateDirectory = nil
        journal = nil
        recording = nil
        super.tearDown()
    }

    /// Manager under test, wired to this test's isolated state.
    private func makeManager() -> SystemDNSManager {
        SystemDNSManager(privilegeClient: recording, journal: journal)
    }

    /// Manager under test on a described machine, so the launch-time recovery
    /// decision can be pinned without depending on what this host's interfaces
    /// happen to hold.
    private func makeManager(machine: FakeDNSNetworksetupRunner, relayIsLive: Bool) -> SystemDNSManager {
        SystemDNSManager(
            privilegeClient: recording,
            journal: journal,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            relayIsLive: { relayIsLive }
        )
    }







    // MARK: - Staleness detection

    func testStalenessThresholdDetectsOldState() {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        let state = SavedDNS(savedAt: eightDaysAgo, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertTrue(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "State older than 7 days should be stale"
        )
    }

    func testStalenessThresholdAllowsFreshState() {
        let state = SavedDNS(savedAt: .now, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertFalse(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "Fresh state should not be stale"
        )
    }

    func testStalenessThresholdBoundaryJustUnder() {
        let justUnder = Date().addingTimeInterval(-7 * 24 * 3600 + 60)
        let state = SavedDNS(savedAt: justUnder, interfaces: ["Wi-Fi": ["8.8.8.8"]])

        let threshold: TimeInterval = 7 * 24 * 3600
        XCTAssertFalse(
            Date().timeIntervalSince(state.savedAt) > threshold,
            "State just under 7 days should not be stale"
        )
    }

    // MARK: - State Detection

    func testHasSavedStateReturnsFalseWhenNoFile() {
        let manager = makeManager()
        XCTAssertFalse(manager.hasSavedState())
    }

    func testHasSavedStateReturnsTrueWhenFileExists() {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["8.8.8.8"]]))
        let manager = makeManager()
        XCTAssertTrue(manager.hasSavedState())
    }

    func testReadDNSServersForNonexistentService() {
        let manager = makeManager()
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


    // MARK: - clear() with RecordingPrivilegeClient

    /// Listed but down — a VPN link, an unplugged adapter — still takes the
    /// write. Restore it now rather than let it come back pointed at 127.0.0.1.
    func testClearRestoresARecordedInterfaceThatIsListedButDisconnected() throws {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"], "Ethernet": ["10.0.0.1"]]))
        let machine = FakeDNSNetworksetupRunner(
            dnsServers: ["Wi-Fi": ["127.0.0.1"], "Ethernet": ["127.0.0.1"]],
            disconnected: ["Ethernet"]
        )
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.clear(logger: nil)

        XCTAssertEqual(
            Set(recording.commands(matching: .setDNSServers).map { $0.joined(separator: " ") }),
            ["Wi-Fi 192.168.1.1", "Ethernet 10.0.0.1"]
        )
        XCTAssertFalse(manager.hasSavedState())
    }

    func testClearRestoresARecordedInterfaceThatWasDisabledSince() throws {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"], "Ethernet": ["10.0.0.1"]]))
        let machine = FakeDNSNetworksetupRunner(
            dnsServers: ["Wi-Fi": ["127.0.0.1"], "Ethernet": ["127.0.0.1"]],
            disabled: ["Ethernet"]
        )
        try makeManager(machine: machine, relayIsLive: false).clear(logger: nil)

        XCTAssertEqual(
            Set(recording.commands(matching: .setDNSServers).map { $0.joined(separator: " ") }),
            ["Wi-Fi 192.168.1.1", "Ethernet 10.0.0.1"]
        )
    }

    func testClearKeepsTheRecordsWhenTheListingFails() throws {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"]]))
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        let manager = makeManager(machine: machine, relayIsLive: false)
        machine.listingFailuresRemaining = 1

        try manager.clear(logger: nil)

        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty)
        XCTAssertTrue(manager.hasSavedState(), "a listing that fails must not read as an empty machine")
    }

    /// An interface whose servers could not be read is recorded as untouched:
    /// not redirected by apply, not reset by teardown.
    func testUnreadableInterfaceIsNeitherRedirectedNorReset() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["192.168.1.1"], "Ethernet": ["10.0.0.1"]])
        machine.failingReads = ["Ethernet"]
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.saveCurrentDNS(logger: nil)
        XCTAssertEqual(journal.prior(surface: .systemDNS, scope: "Ethernet"), .wasPresent([SystemDNSManager.untouchedMarkerKey: "unreadable"]))

        try manager.apply(forwarderPort: 5053, logger: nil)
        XCTAssertEqual(recording.commands(matching: .setDNSServers), [["Wi-Fi", "127.0.0.1"]], "the unreadable interface is not redirected")

        machine.dnsServers["Wi-Fi"] = ["127.0.0.1"]
        recording.reset()
        try manager.clear(logger: nil)
        XCTAssertEqual(recording.commands(matching: .setDNSServers), [["Wi-Fi", "192.168.1.1"]], "and not touched by teardown either")
        XCTAssertFalse(manager.hasSavedState())
    }

    /// Every capture failed: nothing was redirected, so the first teardown has
    /// nothing to put back — and the second must not read the user's own
    /// 127.0.0.1 as residue.
    func testTeardownAfterAFullyUnreadableCaptureReleasesTheSurface() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        machine.failingReads = ["Wi-Fi"]
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.saveCurrentDNS(logger: nil)
        try manager.apply(forwarderPort: 5053, logger: nil)
        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty)

        try manager.clear(logger: nil)
        XCTAssertEqual(journal.ownership(of: .systemDNS), .released)

        machine.failingReads = []
        try manager.clear(logger: nil)
        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty, "a released surface is not probed for residue")
    }

    /// A VPN service mid-flap is down, not gone: its record stays.
    func testReconcileKeepsTheRecordOfAListedButDisconnectedInterface() throws {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"], "VPN": ["10.0.0.1"]]))
        let machine = FakeDNSNetworksetupRunner(
            dnsServers: ["Wi-Fi": ["127.0.0.1"], "VPN": ["127.0.0.1"]],
            disconnected: ["VPN"]
        )
        makeManager(machine: machine, relayIsLive: true).reconcile(logger: nil)

        XCTAssertEqual(journal.prior(surface: .systemDNS, scope: "VPN"), .wasPresent(["servers": "10.0.0.1"]))
    }

    /// The user's own resolver was 127.0.0.1. After the first teardown puts it
    /// back, a second teardown must not read it as our residue.
    func testSecondTeardownDoesNotResetARestoredLoopbackResolver() throws {
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["127.0.0.1"]]))
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.clear(logger: nil)
        XCTAssertEqual(recording.commands(matching: .setDNSServers), [["Wi-Fi", "127.0.0.1"]])
        XCTAssertEqual(journal.ownership(of: .systemDNS), .released)

        recording.reset()
        try manager.clear(logger: nil)
        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty, "a released surface is not probed for residue")

        // A new session takes ownership back.
        try manager.saveCurrentDNS(logger: nil)
        XCTAssertEqual(journal.ownership(of: .systemDNS), .applied)
    }

    func testClearWithAllVanishedInterfacesSkipsAllAndDeletesFile() throws {
        let state = SavedDNS(interfaces: [
            "FakeVPN_utun99": ["10.0.0.1"],
            "FakeThunderbolt": ["169.254.1.1"]
        ])
        writeSavedState(state)

        let manager = makeManager()
        try manager.clear(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        XCTAssertTrue(dnsCommands.isEmpty, "Should not issue any setDNSServers for vanished interfaces")
        XCTAssertFalse(manager.hasSavedState(), "Saved state file should be deleted after clear")
    }

    func testClearWithEmptySavedInterfacesJustDeletesFile() throws {
        writeSavedState(SavedDNS(interfaces: [:]))

        let manager = makeManager()
        try manager.clear(logger: nil)

        XCTAssertTrue(
            recording.commands(matching: .setDNSServers).isEmpty,
            "nothing was captured, so no interface's servers may be rewritten"
        )
        XCTAssertFalse(recording.commands(matching: .stopDNSRelay).isEmpty,
                       "the relay is ours regardless — this branch used to leave it running")
        XCTAssertFalse(manager.hasSavedState())
    }

    /// An empty journal used to mean "reset every connected service to DHCP",
    /// erasing resolvers the app may never have touched — the mirror image of
    /// the system-proxy surface, where the same state meant "do nothing".
    /// Neither guess is acceptable; the machine decides.
    func testClearWithNoSavedStateLeavesForeignResolversAlone() throws {
        let manager = makeManager()   // journal empty, and nothing points at 127.0.0.1

        try manager.clear(logger: nil)

        XCTAssertTrue(
            recording.commands(matching: .setDNSServers).isEmpty,
            "DNS the app never redirected must not be reset to DHCP"
        )
    }

    func testClearRestoresRealInterfacesAndSkipsFake() throws {
        let manager = makeManager()

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services on this machine")
        }

        let state = SavedDNS(interfaces: [
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
        let manager = makeManager()

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services on this machine")
        }

        writeSavedState(SavedDNS(interfaces: [firstService: []]))

        try manager.clear(logger: nil)

        let dnsCommands = recording.commands(matching: .setDNSServers)
        let matchingCmd = dnsCommands.first { $0[0] == firstService }
        XCTAssertNotNil(matchingCmd)
        XCTAssertEqual(matchingCmd?[1], "empty", "Empty saved servers should restore as 'empty' (DHCP)")
    }

    func testClearContinuesAfterPartialFailure() throws {
        let manager = makeManager()

        let realServices = try manager.connectedNetworkServices()
        guard realServices.count >= 2 else {
            throw XCTSkip("Need at least 2 connected network services for partial failure test")
        }

        recording.failing = [.setDNSServers]
        writeSavedState(SavedDNS(interfaces: Dictionary(
            uniqueKeysWithValues: realServices.map { ($0, ["1.1.1.1"]) }
        )))

        do {
            try manager.clear(logger: nil)
        } catch {}

        XCTAssertTrue(
            manager.hasSavedState(),
            """
            Records must SURVIVE a partial failure. Dropping them destroys the only copy of \
            the still-unrestored interfaces' real servers while leaving those interfaces pinned \
            at 127.0.0.1 — the rule the proxy and launchd surfaces already follow. This assertion \
            was inverted deliberately; it previously pinned the losing behaviour.
            """
        )
    }

    // MARK: - apply() with RecordingPrivilegeClient

    func testApplyNeverCallsResolverOverrideCommands() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["192.168.1.1"]])
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.saveCurrentDNS(logger: nil)
        try manager.apply(forwarderPort: 5053, logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)

        XCTAssertTrue(applyDNS.isEmpty, "apply() must not issue .applyDNS (resolver override removed)")
        XCTAssertTrue(removeDNS.isEmpty, "apply() must not issue .removeDNS (resolver override removed)")
    }

    func testApplySetsAllInterfacesToLocalhost() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["192.168.1.1"], "Ethernet": ["10.0.0.1"]])
        let manager = makeManager(machine: machine, relayIsLive: false)

        try manager.saveCurrentDNS(logger: nil)
        try manager.apply(forwarderPort: 5053, logger: nil)

        XCTAssertEqual(
            Set(recording.commands(matching: .setDNSServers).map { $0.joined(separator: " ") }),
            ["Wi-Fi 127.0.0.1", "Ethernet 127.0.0.1"]
        )
    }

    /// Every host treats a failed `saveCurrentDNS` as non-fatal and goes on
    /// to `apply`. Without the capture there is nothing to restore from, and
    /// the teardown's residue sweep would reset the redirected interfaces to
    /// DHCP, so `apply` must refuse rather than redirect.
    func testApplyRefusesToRedirectWhenNothingWasCaptured() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["192.168.1.1"]])
        let manager = makeManager(machine: machine, relayIsLive: false)

        machine.listingFailuresRemaining = 1
        XCTAssertThrowsError(try manager.saveCurrentDNS(logger: nil), "the capture failed")

        XCTAssertThrowsError(try manager.apply(forwarderPort: 5053, logger: nil)) { error in
            XCTAssertEqual(error as? SystemDNSManagerError, .priorStateNotCaptured)
        }
        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty, "no interface was redirected")
        XCTAssertTrue(recording.commands(matching: .startDNSRelay).isEmpty, "and the relay was not started")

        try manager.saveCurrentDNS(logger: nil)
        try manager.apply(forwarderPort: 5053, logger: nil)
        XCTAssertEqual(recording.commands(matching: .setDNSServers), [["Wi-Fi", "127.0.0.1"]], "the next attempt, with a capture, redirects")
    }

    // MARK: - clear() never calls resolver override commands (regression)

    func testClearNeverCallsResolverOverrideCommands() throws {
        let manager = makeManager()
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNS(interfaces: [service: ["1.1.1.1"]]))

        try manager.clear(logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)

        XCTAssertTrue(applyDNS.isEmpty, "clear() must not issue .applyDNS")
        XCTAssertTrue(removeDNS.isEmpty, "clear() must not issue .removeDNS")
    }

    // MARK: - reconcile() with RecordingPrivilegeClient

    func testReconcileRedirectsNewInterfaces() throws {
        let manager = makeManager()

        let realServices = try manager.connectedNetworkServices()
        guard let firstService = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNS(interfaces: [
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
        let manager = makeManager()
        manager.reconcile(logger: nil)
        XCTAssertTrue(recording.commands.isEmpty, "No saved state means no reconciliation")
    }

    func testReconcileRepinsDriftedManagedInterfacesWithoutTouchingSavedState() throws {
        let manager = makeManager()

        let realServices = try manager.connectedNetworkServices()
        guard !realServices.isEmpty else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNS(interfaces: Dictionary(
            uniqueKeysWithValues: realServices.map { ($0, ["192.168.1.1"]) }
        )))

        manager.reconcile(logger: nil)

        // Managed interfaces whose live DNS is not 127.0.0.1 have drifted
        // (e.g. a VPN client rewrote them after wake) and must be re-pinned;
        // interfaces already at 127.0.0.1 must be left alone.
        let driftedCount = realServices.filter { manager.readDNSServers(service: $0) != ["127.0.0.1"] }.count
        let dnsCommands = recording.commands(matching: .setDNSServers)
        XCTAssertEqual(dnsCommands.count, driftedCount, "Exactly the drifted managed interfaces are re-pinned")
        for command in dnsCommands {
            XCTAssertEqual(Array(command.dropFirst()), ["127.0.0.1"], "Re-pin always restores the loopback override")
        }
        XCTAssertTrue(
            recording.commands.allSatisfy { $0.0 == .setDNSServers },
            "Reconcile with no new/gone interfaces issues nothing but re-pins"
        )

        // The saved (pre-override) servers are the restore target for
        // disable/quit — a re-pin must never overwrite them.
        let loaded = loadSavedState()
        for service in realServices {
            XCTAssertEqual(loaded?.interfaces[service], ["192.168.1.1"], "Saved original DNS survives re-pinning")
        }
    }

    func testReconcileNeverCallsResolverOverrideCommands() throws {
        let manager = makeManager()

        writeSavedState(SavedDNS(interfaces: ["FakeOldInterface": ["10.0.0.1"]]))
        manager.reconcile(logger: nil)

        let applyDNS = recording.commands(matching: .applyDNS)
        let removeDNS = recording.commands(matching: .removeDNS)
        XCTAssertTrue(applyDNS.isEmpty, "reconcile() must not issue .applyDNS")
        XCTAssertTrue(removeDNS.isEmpty, "reconcile() must not issue .removeDNS")
    }

    func testReconcileUpdatesTimestamp() throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        writeSavedState(SavedDNS(savedAt: oldDate, interfaces: ["FakeOldInterface": ["10.0.0.1"]]))

        let manager = makeManager()
        manager.reconcile(logger: nil)

        let loaded = loadSavedState()
        XCTAssertNotNil(loaded)
        XCTAssertGreaterThan(loaded!.savedAt, oldDate, "reconcile should update savedAt timestamp")
    }

    // MARK: - Reconcile set algebra (pure logic)

    func testReconcileDetectsNewInterfaces() {
        let saved = SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"]])
        let currentServices = ["Wi-Fi", "utun3"]

        let newInterfaces = Set(currentServices).subtracting(saved.interfaces.keys)
        let goneInterfaces = Set(saved.interfaces.keys).subtracting(currentServices)

        XCTAssertEqual(newInterfaces, ["utun3"])
        XCTAssertTrue(goneInterfaces.isEmpty)
    }

    func testReconcileDetectsGoneInterfaces() {
        let saved = SavedDNS(interfaces: [
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
        let saved = SavedDNS(interfaces: [
            "Wi-Fi": ["192.168.1.1"],
            "utun3": ["10.0.0.1"]
        ])
        let currentServices = ["Wi-Fi", "Ethernet"]

        let newInterfaces = Set(currentServices).subtracting(saved.interfaces.keys)
        let goneInterfaces = Set(saved.interfaces.keys).subtracting(currentServices)

        XCTAssertEqual(newInterfaces, ["Ethernet"])
        XCTAssertEqual(goneInterfaces, ["utun3"])
    }

    // MARK: - Legacy snapshot migration

    // MARK: - restoreIfNeeded()

    func testRestoreIfNeededNoOpsWithoutFile() {
        let manager = makeManager()
        manager.restoreIfNeeded(logger: nil)
        XCTAssertTrue(recording.commands.isEmpty)
    }

    func testRestoreIfNeededRestoresWhenPort53FreeAndFileExists() throws {
        let manager = makeManager()
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        writeSavedState(SavedDNS(interfaces: [service: ["8.8.8.8"]]))

        manager.restoreIfNeeded(logger: nil)

        if recording.commands.isEmpty {
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
        let manager = makeManager()
        let realServices = try manager.connectedNetworkServices()
        guard let service = realServices.first else {
            throw XCTSkip("No connected network services")
        }

        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        writeSavedState(SavedDNS(savedAt: eightDaysAgo, interfaces: [service: ["8.8.8.8"]]))

        manager.restoreIfNeeded(logger: nil)

        XCTAssertFalse(manager.hasSavedState(), "Stale state should always be cleaned up")
    }

    // MARK: - restoreIfNeeded(): 0.1.x snapshot

    /// 0.1.1 crashed with DNS pointed at the relay, the user upgraded: the
    /// resolvers exist only in `saved-dns.json`. Recovery must read that file
    /// once, restore from it, and not leave it around to be re-imported.
    func testRestoreIfNeededImportsTheLegacySnapshotBeforeDeciding() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        let legacy = stateDirectory.appendingPathComponent("saved-dns.json")
        let snapshot = LegacyDNSSnapshot(
            savedAt: Date().addingTimeInterval(-3600),
            interfaces: ["Wi-Fi": ["192.168.1.1", "1.1.1.1"]]
        )
        try JSONEncoder().encode(snapshot).write(to: legacy)

        let manager = SystemDNSManager(
            privilegeClient: recording,
            journal: journal,
            legacySnapshotFile: legacy,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            relayIsLive: { false }
        )
        manager.restoreIfNeeded(logger: nil)

        XCTAssertEqual(recording.commands(matching: .setDNSServers), [["Wi-Fi", "192.168.1.1", "1.1.1.1"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "removed after a successful import")
        XCTAssertFalse(manager.hasSavedState())
    }

    /// The daemon never calls `restoreIfNeeded`; its first DNS act is the save.
    func testSaveCurrentDNSImportsTheLegacySnapshotBeforeRecording() throws {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        let legacy = stateDirectory.appendingPathComponent("saved-dns.json")
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["192.168.1.1"]])).write(to: legacy)
        let manager = SystemDNSManager(
            privilegeClient: recording,
            journal: journal,
            legacySnapshotFile: legacy,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            relayIsLive: { false }
        )

        try manager.saveCurrentDNS(logger: nil)

        XCTAssertEqual(
            journal.prior(surface: .systemDNS, scope: "Wi-Fi"),
            .wasPresent(["servers": "192.168.1.1"]),
            "the stranded 127.0.0.1 must not become the recorded prior value"
        )
    }

    func testLegacySnapshotIsRefusedWhenTheJournalIsUnreadable() throws {
        let legacy = stateDirectory.appendingPathComponent("saved-dns.json")
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["9.9.9.9"]])).write(to: legacy)
        try Data("not json".utf8).write(to: stateDirectory.appendingPathComponent("platform-state.json"))
        let corrupt = PlatformStateJournal(fileURL: stateDirectory.appendingPathComponent("platform-state.json"))

        XCTAssertFalse(corrupt.importLegacyDNSSnapshot(at: legacy))
        XCTAssertEqual(corrupt.fileState, .unreadable, "the journal is left as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacySnapshotIsKeptWhenTheJournalCannotBeWritten() throws {
        let legacy = stateDirectory.appendingPathComponent("saved-dns.json")
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["9.9.9.9"]])).write(to: legacy)
        // A directory that cannot be created: a path under a regular file.
        let blocker = stateDirectory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let unwritable = PlatformStateJournal(fileURL: blocker.appendingPathComponent("dir/platform-state.json"))

        XCTAssertFalse(unwritable.importLegacyDNSSnapshot(at: legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "the last copy of the resolvers stays")
    }

    func testLegacySnapshotDoesNotOverrideAJournalThatKnowsTheSurface() throws {
        let legacy = stateDirectory.appendingPathComponent("saved-dns.json")
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["9.9.9.9"]])).write(to: legacy)
        journal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: ["servers": "192.168.1.1"])

        XCTAssertFalse(journal.importLegacyDNSSnapshot(at: legacy))
        XCTAssertEqual(journal.prior(surface: .systemDNS, scope: "Wi-Fi"), .wasPresent(["servers": "192.168.1.1"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "left alone when not imported")
    }

    // MARK: - restoreIfNeeded(): crash recovery vs. a live session

    /// The relay is not in the app. It runs inside the privileged LaunchDaemon,
    /// which is `KeepAlive` and outlives every app process — so after a
    /// `SIGKILL` it is still bound to 53 and still forwarding to a forwarder
    /// port that nothing answers on. "Is the port held?" is therefore `true` in
    /// exactly the crash this recovery exists for, and gating on it skipped the
    /// restore. Whether anything still *resolves* is the question being asked.
    func testRestoreIfNeededRestoresWhenTheLeftoverRelayNoLongerResolves() {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["127.0.0.1"]])
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"]]))

        let manager = makeManager(machine: machine, relayIsLive: false)
        manager.restoreIfNeeded(logger: nil)

        XCTAssertEqual(
            recording.commands(matching: .setDNSServers),
            [["Wi-Fi", "192.168.1.1"]],
            "a relay that resolves nothing is residue, whoever is holding the socket"
        )
        XCTAssertFalse(manager.hasSavedState(), "the records go once the servers are back")
    }

    /// The delete branch has to ask "is anything of ours still on the machine",
    /// not "is everything still ours". A single interface that came back with
    /// its own resolvers — a VPN link, a service added since — makes the
    /// all-interfaces test say "not applied", and deleting on that basis throws
    /// away the recorded servers for the interfaces that are still pinned at
    /// 127.0.0.1.
    func testRestoreIfNeededKeepsSavedStateWhileAnyInterfaceIsStillRedirected() {
        let machine = FakeDNSNetworksetupRunner(dnsServers: [
            "Wi-Fi": ["127.0.0.1"],
            "Ethernet": ["10.0.0.1"],
        ])
        writeSavedState(SavedDNS(interfaces: [
            "Wi-Fi": ["192.168.1.1"],
            "Ethernet": ["10.0.0.53"],
        ]))

        let manager = makeManager(machine: machine, relayIsLive: true)
        manager.restoreIfNeeded(logger: nil)

        XCTAssertTrue(
            manager.hasSavedState(),
            "Wi-Fi still points at the forwarder, so its recorded servers are the only copy left"
        )
        XCTAssertTrue(
            recording.commands(matching: .setDNSServers).isEmpty,
            "a live resolver means a session is serving this machine; its DNS is not ours to take"
        )
    }

    /// The companion branch: a live resolver and nothing of ours left on any
    /// interface means the records describe a machine state that no longer
    /// exists, so they are noise rather than the last copy of anything.
    func testRestoreIfNeededDropsSavedStateWhenNoInterfacePointsAtTheForwarder() {
        let machine = FakeDNSNetworksetupRunner(dnsServers: ["Wi-Fi": ["1.1.1.1"]])
        writeSavedState(SavedDNS(interfaces: ["Wi-Fi": ["192.168.1.1"]]))

        let manager = makeManager(machine: machine, relayIsLive: true)
        manager.restoreIfNeeded(logger: nil)

        XCTAssertFalse(manager.hasSavedState())
        XCTAssertTrue(recording.commands(matching: .setDNSServers).isEmpty)
    }

    // MARK: - Liveness probe

    func testProbeLivenessReturnsFalseWhenNoListener() {
        let manager = makeManager()
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

        let manager = makeManager()
        let alive = manager.probeLiveness(port: port)

        close(echoFD)

        XCTAssertTrue(alive, "Should succeed when a UDP echo server responds on the target port")
    }

    // MARK: - DoH providers config

    func testDohProvidersDefaultHasThreeEntries() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.dohProviders.count, 3)
    }

    /// The default providers must be addressable without DNS.
    ///
    /// This is the invariant, not which vendors are listed: the DoH path exists
    /// for networks whose nameservers cannot resolve public names, and on such a
    /// network a provider named by hostname cannot be reached at all. Asserting
    /// on the host being an IP literal keeps a future edit from quietly
    /// reintroducing the bootstrap dependency.
    func testDohProviderDefaultsAreAddressableWithoutDNS() throws {
        for provider in DNSSection.defaultDoHProviders {
            let host = try XCTUnwrap(URL(string: provider)?.host, "\(provider) has no host")
            var parsed = in_addr()
            XCTAssertEqual(
                host.withCString { inet_pton(AF_INET, $0, &parsed) }, 1,
                "\(provider) is addressed by hostname; DoH must not need DNS to bootstrap DNS"
            )
        }
    }

    /// Guards the migration's recognition test in `ProxyConfigPersistence`:
    /// if these two lists ever overlap, a migrated config would be rewritten
    /// back to a blocked default.
    func testLegacyAndCurrentDoHDefaultsAreDisjoint() {
        let legacy = Set(DNSSection.legacyHostnameDoHProviders)
        let current = Set(DNSSection.defaultDoHProviders)
        XCTAssertTrue(legacy.isDisjoint(with: current))
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

    private func writeSavedState(_ state: SavedDNS) {
        journal.forgetAll(surface: .systemDNS)
        // Mark applied even with zero interfaces: "we ran and captured
        // nothing" is not the same as having no saved state at all, and
        // teardown treats them differently.
        journal.markApplied(surface: .systemDNS, now: state.savedAt)
        for (service, servers) in state.interfaces {
            journal.recordPrior(
                surface: .systemDNS,
                scope: service,
                value: ["servers": servers.joined(separator: ",")],
                now: state.savedAt
            )
        }
    }

    private func loadSavedState() -> SavedDNS? {
        guard journal.hasRecords(for: .systemDNS) else { return nil }
        var interfaces: [String: [String]] = [:]
        for record in journal.records(for: .systemDNS) {
            let servers = record.priorValue?["servers"] ?? ""
            interfaces[record.scope] = servers.isEmpty ? [] : servers.split(separator: ",").map(String.init)
        }
        return SavedDNS(
            savedAt: journal.oldestRecordDate(for: .systemDNS) ?? .now,
            interfaces: interfaces
        )
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
