// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []
    /// Domains whose privileged operation fails.
    var failingDomains: Set<String> = []

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        struct Refused: Error {}
        try lock.withLock {
            _commands.append((operation, values))
            if let domain = values.first, failingDomains.contains(domain) {
                throw Refused()
            }
        }
    }
}

/// Resolver files are written by the helper and carry no prior value, so the
/// journal's `resolverFile` surface holds only an applied/released marker. A
/// host whose user has turned resolver management *off* reads that marker to
/// tell our file from one the user maintains by hand for the same domain
/// (#13), which the file's presence alone cannot.
final class DNSManagerOwnershipTests: XCTestCase {

    private var journalDirectory: URL!
    private var journal: PlatformStateJournal!
    private var recording: RecordingPrivilegeClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        journalDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dns-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        journal = PlatformStateJournal(fileURL: journalDirectory.appendingPathComponent("platform-state.json"))
        recording = RecordingPrivilegeClient()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: journalDirectory)
        journalDirectory = nil
        journal = nil
        recording = nil
        super.tearDown()
    }

    private func makeManager() -> DNSManager {
        DNSManager(privilegeClient: recording, resolverDirectory: journalDirectory.path, journal: journal)
    }

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [
            DomainDNSEntry(domain: "corp.example", servers: ["10.1.1.1"], enabled: true)
        ]
        return config
    }

    func testHasManagedStateFollowsApplyAndClear() throws {
        let manager = makeManager()
        XCTAssertFalse(manager.hasManagedState(), "nothing written yet")

        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertTrue(manager.hasManagedState())

        try manager.clear(config: makeConfig(), logger: nil)
        XCTAssertFalse(manager.hasManagedState(), "every file removed, surface released")
    }

    func testEntryAndInterceptWritersBothMarkTheSurface() throws {
        var config = makeConfig()
        config.transparentProxyEnabled = true
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.cursor.sh", enabled: true)]

        let entries = makeManager()
        try entries.applyEntryFiles(config: config, logger: nil)
        XCTAssertTrue(entries.hasManagedState())
        try entries.clear(config: config, logger: nil)

        let intercepts = makeManager()
        try intercepts.applyInterceptFiles(config: config, logger: nil)
        XCTAssertTrue(intercepts.hasManagedState())
    }

    /// A removal that failed leaves a file of ours on disk. Releasing the
    /// marker anyway would stop the next teardown from retrying it.
    func testFailedRemovalKeepsTheSurfaceOwned() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        recording.failingDomains = ["corp.example"]

        XCTAssertThrowsError(try manager.clear(config: makeConfig(), logger: nil))
        XCTAssertTrue(manager.hasManagedState(), "the file is still there and still ours")
    }

    private func removedDomains() -> [String] {
        recording.executedCommands.filter { $0.0 == .removeDNS }.compactMap(\.1.first)
    }

    /// Every teardown derives its domains from the *current* config. A domain
    /// edited out of the config file by hand is still ours on disk, and the
    /// journal is what names it.
    func testClearRemovesRecordedDomainsTheConfigNoLongerNames() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)

        var edited = makeConfig()
        edited.dnsEntries = []
        try manager.clear(config: edited, logger: nil)

        XCTAssertEqual(removedDomains(), ["corp.example"])
        XCTAssertFalse(manager.hasManagedState())
    }

    /// The hosts guard `clear` on `isCleared`, so it has to see a recorded
    /// domain the config no longer names or the guard skips the file.
    func testIsClearedSeesARecordedDomainStillOnDisk() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        try "nameserver 10.1.1.1".write(
            to: journalDirectory.appendingPathComponent("corp.example"),
            atomically: true,
            encoding: .utf8
        )

        var edited = makeConfig()
        edited.dnsEntries = []
        XCTAssertFalse(manager.isCleared(config: edited), "the recorded file is on disk")
    }

    /// A removal that failed keeps its record, so the next teardown retries
    /// it even if the config has moved on — and only then is the surface
    /// released.
    func testFailedRemovalIsRetriedByTheNextClear() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        recording.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.clear(config: makeConfig(), logger: nil))
        XCTAssertTrue(manager.hasManagedState())

        recording.failingDomains = []
        var edited = makeConfig()
        edited.dnsEntries = []
        try manager.clear(config: edited, logger: nil)

        XCTAssertEqual(removedDomains(), ["corp.example", "corp.example"], "retried from the journal alone")
        XCTAssertFalse(manager.hasManagedState())
    }

    private func makeTwoDomainConfig() -> ProxyConfig {
        var config = makeConfig()
        config.dnsEntries.append(DomainDNSEntry(domain: "internal.example", servers: ["10.2.2.2"]))
        return config
    }

    /// The writers fail fast. Claiming the whole batch before the first write
    /// would leave a never-written domain journaled after an early failure,
    /// and the switch-off teardown would then delete a file the user keeps
    /// under that name. A domain is claimed one write at a time.
    func testEarlyWriteFailureClaimsOnlyTheDomainsAttempted() throws {
        let manager = makeManager()
        recording.failingDomains = ["corp.example"]

        XCTAssertThrowsError(try manager.apply(config: makeTwoDomainConfig(), logger: nil, vpnConnected: true))

        XCTAssertEqual(journal.scopes(for: .resolverFile), ["corp.example"], "the second domain was never attempted")
        recording.failingDomains = []
        try manager.clearRecorded(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"], "internal.example is not ours to remove")
    }

    /// With the switch off, a configured domain we never wrote is the user's:
    /// `clearRecorded` works from the journal alone, unlike `clear`.
    func testClearRecordedLeavesConfiguredDomainsNeverWrittenAlone() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)

        try manager.clearRecorded(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"])
        XCTAssertFalse(manager.hasManagedState())

        try manager.clearRecorded(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"], "nothing recorded, nothing removed")
    }

    /// An unreadable journal reads as empty, and "nothing recorded" is the
    /// one answer that strands. The switch-off teardown then falls back to
    /// the configured domains, as the other surfaces do.
    func testUnreadableJournalFallsBackToTheConfiguredDomains() throws {
        try Data("{ truncated".utf8).write(to: journalDirectory.appendingPathComponent("platform-state.json"))
        let manager = makeManager()

        XCTAssertTrue(manager.hasManagedState(), "cannot say what we changed, so assume the worst")
        try manager.clearRecorded(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"])
    }

    /// Without a journal there is no ownership to report, and the daemon and
    /// the other tests construct the manager that way.
    func testNoJournalMeansNoManagedState() throws {
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: journalDirectory.path)
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertFalse(manager.hasManagedState())
    }
}
