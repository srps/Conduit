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
/// journal's `resolverFile` surface holds one scope per domain this app wrote
/// and a released marker once a teardown ran to completion. A host whose user
/// has turned resolver management *off* reads those to tell our file from one
/// the user maintains by hand for the same domain (#13), which the file's
/// presence alone cannot.
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
        try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"], "internal.example is not ours to remove")
    }

    /// With the switch off, a configured domain we never wrote is the user's:
    /// `clearRecorded` works from the journal alone, unlike `clear`.
    func testClearRecordedLeavesConfiguredDomainsNeverWrittenAlone() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)

        try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"])
        XCTAssertFalse(manager.hasManagedState())

        try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example"], "nothing recorded, nothing removed")
    }

    private func corruptJournal() throws {
        try Data("{ truncated".utf8).write(to: journalDirectory.appendingPathComponent("platform-state.json"))
    }

    private func writeResolverFile(_ domain: String, _ contents: String) throws {
        try contents.write(to: journalDirectory.appendingPathComponent(domain), atomically: true, encoding: .utf8)
    }

    /// An unreadable journal reads as empty, and "nothing recorded" is the
    /// one answer that strands — but removing every configured domain would
    /// delete a file the user keeps under a name we also configure. The file
    /// itself is the evidence: our exact contents are ours, anything else is
    /// somebody else's.
    func testUnreadableJournalRecoversOwnershipFromTheFilesThemselves() throws {
        try corruptJournal()
        try writeResolverFile("corp.example", "nameserver 10.1.1.1\n")
        try writeResolverFile("internal.example", "nameserver 192.168.1.1\nsearch home.arpa\n")
        let manager = makeManager()

        XCTAssertTrue(manager.hasManagedState(), "cannot say what we changed, so assume the worst")
        try manager.clearRecorded(configs: [makeTwoDomainConfig()], surfaceWasManaged: false, logger: nil)

        XCTAssertEqual(removedDomains(), ["corp.example"], "internal.example has contents we never write")
        XCTAssertFalse(manager.hasManagedState(), "the journal was rebuilt and then released")
    }

    /// Nothing of ours on disk must settle the surface, not leave it forever
    /// suspect: every later stop and quit would otherwise re-run the scan.
    func testUnreadableJournalWithNothingOfOursSettlesTheSurface() throws {
        try corruptJournal()
        let manager = makeManager()

        try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil)

        XCTAssertTrue(removedDomains().isEmpty)
        XCTAssertFalse(manager.hasManagedState())
    }

    /// One save can edit the entries and turn the switch off together. With
    /// the journal unreadable, the scan has only the configs to go on, so the
    /// caller passes the previous one too and both sets of files are judged.
    func testUnreadableJournalScanCoversThePreviousConfig() throws {
        try corruptJournal()
        try writeResolverFile("corp.example", "nameserver 10.1.1.1")
        try writeResolverFile("internal.example", "nameserver 10.2.2.2")
        try writeResolverFile("renamed.example", "nameserver 10.3.3.3")
        let manager = makeManager()

        var renamed = makeConfig()
        renamed.dnsEntries = [DomainDNSEntry(domain: "renamed.example", servers: ["10.3.3.3"])]
        try manager.clearRecorded(configs: [makeTwoDomainConfig(), renamed], surfaceWasManaged: false, logger: nil)

        XCTAssertEqual(Set(removedDomains()), ["corp.example", "internal.example", "renamed.example"])
    }

    /// Adopting a file records it, so a removal that then fails is retried by
    /// the next teardown from the journal — even once the config has moved on
    /// and no longer names the domain.
    func testUnreadableJournalAdoptionMakesAFailedRemovalRetryable() throws {
        try corruptJournal()
        try writeResolverFile("corp.example", "nameserver 10.1.1.1")
        let manager = makeManager()
        recording.failingDomains = ["corp.example"]

        XCTAssertThrowsError(try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil))
        XCTAssertTrue(manager.hasManagedState(), "the failed domain stays recorded")

        recording.failingDomains = []
        var movedOn = makeConfig()
        movedOn.dnsEntries = []
        try manager.clearRecorded(configs: [movedOn], surfaceWasManaged: false, logger: nil)

        XCTAssertEqual(removedDomains(), ["corp.example", "corp.example"], "retried from the rebuilt journal")
        XCTAssertFalse(manager.hasManagedState())
    }

    /// An install upgraded from a release without per-domain records has a
    /// readable journal that has never seen this surface, and files that
    /// release wrote. The same is true after a start that found its files
    /// already on disk and did not rewrite them. At the moment the switch is
    /// turned off both are judged by contents, and the surface is settled.
    func testSwitchOffOnAJournalThatNeverSawTheSurfaceRecoversOwnershipFromFiles() throws {
        // A journal an older release left: readable, other surfaces present,
        // nothing about resolver files.
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webEnabled": "0"])
        try writeResolverFile("corp.example", "nameserver 10.1.1.1")
        try writeResolverFile("internal.example", "nameserver 192.168.1.1")
        let manager = makeManager()

        try manager.clearRecorded(configs: [makeTwoDomainConfig()], surfaceWasManaged: true, logger: nil)

        XCTAssertEqual(removedDomains(), ["corp.example"], "the file with foreign contents is not ours")
        XCTAssertFalse(manager.hasManagedState(), "settled as released")
        XCTAssertTrue(journal.hasRecords(for: .systemProxy), "other surfaces untouched")
    }

    /// A fresh install whose user keeps their own resolver file, with the
    /// same `nameserver` line Conduit would write for the same domain, must
    /// keep it through every stop and quit with the switch off. Contents are
    /// not evidence of ours when the switch was never on.
    func testStopWithTheSwitchOffLeavesAnUnseenSurfaceAlone() throws {
        try writeResolverFile("corp.example", "nameserver 10.1.1.1")
        let manager = makeManager()

        XCTAssertFalse(manager.hasManagedState(), "the host would not even call")
        try manager.clearRecorded(configs: [makeConfig()], surfaceWasManaged: false, logger: nil)

        XCTAssertTrue(removedDomains().isEmpty, "the user's identical file survives")
    }

    /// Without a journal there is no ownership to report, and the daemon and
    /// the other tests construct the manager that way.
    func testNoJournalMeansNoManagedState() throws {
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: journalDirectory.path)
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertFalse(manager.hasManagedState())
    }
}
