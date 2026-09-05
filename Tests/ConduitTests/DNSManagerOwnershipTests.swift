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

    /// Without a journal there is no ownership to report, and the daemon and
    /// the other tests construct the manager that way.
    func testNoJournalMeansNoManagedState() throws {
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: journalDirectory.path)
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertFalse(manager.hasManagedState())
    }
}
