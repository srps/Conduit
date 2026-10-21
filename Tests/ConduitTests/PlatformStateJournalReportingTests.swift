// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// How the journal reports trouble (#191): every failure is a
/// `RuntimeEvent` first, once per episode, and the log line derives from it.
final class PlatformStateJournalReportingTests: XCTestCase {
    private var directory: URL!
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journal-reporting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may leave the directory read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("platform-state.json") }

    private func makeJournal(at url: URL? = nil) -> PlatformStateJournal {
        let events = self.events
        return PlatformStateJournal(fileURL: url ?? file, eventSink: { event in events.withLockedValue { $0.append(event) } })
    }

    private func reported(_ name: String) -> [String] {
        events.withLockedValue { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }

    private var names: [String] { events.withLockedValue { $0.map(\.event) } }

    private let record = PlatformStateRecord(
        surface: .systemProxy, scope: "Wi-Fi", priorValue: ["webHost": "prior.example.test"],
        recordedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )

    // MARK: - Both date encodings still read

    func testABareArrayWithEpochDatesIsVersionOne() throws {
        try CanonicalJSON.encoder().encode([record]).write(to: file)
        let journal = makeJournal()

        XCTAssertEqual(journal.fileState, .loaded)
        XCTAssertEqual(journal.records(for: .systemProxy), [record])
        XCTAssertEqual(names, [])
    }

    func testABareArrayWithISO8601DatesIsVersionOne() throws {
        try JSONEncoder.prettyISO8601Encoder.encode([record]).write(to: file)
        let journal = makeJournal()

        XCTAssertEqual(journal.fileState, .loaded)
        XCTAssertEqual(journal.records(for: .systemProxy), [record])
        XCTAssertEqual(names, [])
    }

    /// A refusal in the throwing writes, which check before they save, is
    /// what starts the episode when it comes first.
    func testARefusedCaptureStartsTheEpisode() throws {
        try Data("not json".utf8).write(to: file)
        let journal = makeJournal()

        XCTAssertThrowsError(try journal.recordNetworkState(
            surface: .systemProxy, locationID: "L", serviceID: "S", prior: [:], applied: [:], maximumRecords: 8
        ))
        XCTAssertEqual(reported("platform.journal_write_failed"),
                       ["operation=record_network_state surface=systemProxy reason=journal_unreadable"])
    }

    // MARK: - A corrupt file reports every decoder's error

    func testACorruptFileReportsEveryDecodersError() throws {
        let corrupt = Data(#"[{"surface":"systemProxy","scope":"Wi-Fi","recordedAt":"#.utf8)
        try corrupt.write(to: file)
        let journal = makeJournal()

        XCTAssertEqual(journal.fileState, .unreadable)
        let detail = try XCTUnwrap(reported("platform.journal_unreadable").first)
        XCTAssertTrue(detail.hasPrefix("file=platform-state.json reason=undecodable canonical="), detail)
        XCTAssertTrue(detail.contains(" iso8601=data_corrupted"), detail)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    /// Records with a field neither date encoding reads: both errors point
    /// at it, so the report says where the file is damaged.
    func testAnUndecodableRecordIsNamedByPath() throws {
        try Data(#"[{"surface":"systemProxy","scope":"Wi-Fi","recordedAt":{}}]"#.utf8).write(to: file)
        let journal = makeJournal()

        XCTAssertEqual(journal.fileState, .unreadable)
        XCTAssertEqual(reported("platform.journal_unreadable"), [
            "file=platform-state.json reason=undecodable canonical=type_mismatch@0.recordedAt iso8601=type_mismatch@0.recordedAt",
        ])
    }

    // MARK: - Failed writes are one episode

    func testFailedWritesAreOneEpisodeAndALandedWriteEndsIt() throws {
        let locked = directory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let journal = makeJournal(at: locked.appendingPathComponent("platform-state.json"))

        journal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: ["servers": ""])
        journal.markApplied(surface: .systemDNS)
        XCTAssertThrowsError(try journal.forgetNetworkState(surface: .systemProxy, scope: "L/S"))

        let failed = reported("platform.journal_write_failed")
        XCTAssertEqual(failed.count, 1, "a failing disk is one event: \(failed)")
        XCTAssertTrue(failed[0].hasPrefix("operation=record_prior surface=systemDNS reason=io error=NSCocoaErrorDomain:"), failed[0])
        XCTAssertEqual(reported("platform.journal_write_recovered"), [])

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        journal.touch(surface: .systemDNS)
        journal.touch(surface: .systemDNS)

        XCTAssertEqual(reported("platform.journal_write_recovered"), ["failures=3"])
        XCTAssertEqual(PlatformStateJournal(fileURL: locked.appendingPathComponent("platform-state.json")).prior(surface: .systemDNS, scope: "Wi-Fi"),
                       .wasPresent(["servers": ""]), "the held records landed with the write that ended the episode")
        XCTAssertEqual(names, ["platform.journal_write_failed", "platform.journal_write_recovered"])
    }

    /// The event reaches the sink before the log line, and the log line
    /// carries it.
    func testTheLogLineIsDerivedFromTheEvent() throws {
        try Data("not json".utf8).write(to: file)
        let logs = RecordingLogSink()
        let events = self.events
        let journal = PlatformStateJournal(fileURL: file, logger: logs, eventSink: { event in
            XCTAssertTrue(logs.entries().isEmpty, "the event comes first")
            events.withLockedValue { $0.append(event) }
        })

        XCTAssertEqual(journal.fileState, .unreadable)
        let entry = try XCTUnwrap(logs.entries().first)
        XCTAssertEqual(entry.level, .warning)
        XCTAssertTrue(entry.message.contains("platform.journal_unreadable file=platform-state.json reason=undecodable canonical=data_corrupted"), entry.message)
        XCTAssertTrue(entry.message.contains("as records with ISO-8601 dates:"), entry.message)
    }

    // MARK: - Legacy DNS snapshot import

    private var snapshot: URL { directory.appendingPathComponent("saved-dns.json") }

    private func writeSnapshot() throws {
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["192.0.2.53"]])).write(to: snapshot)
    }

    func testAnImportIsReported() throws {
        try writeSnapshot()
        let journal = makeJournal()

        XCTAssertTrue(journal.importLegacyDNSSnapshot(at: snapshot))
        XCTAssertEqual(reported("platform.legacy_dns_imported"), ["interfaces=1"])
        XCTAssertEqual(reported("platform.legacy_dns_import_failed"), [])
    }

    func testNoSnapshotIsNotAFailure() throws {
        XCTAssertFalse(makeJournal().importLegacyDNSSnapshot(at: snapshot))
        XCTAssertEqual(names, [])
    }

    func testAnUndecodableSnapshotIsReportedOnceAndKept() throws {
        try Data("not json".utf8).write(to: snapshot)
        let journal = makeJournal()

        XCTAssertFalse(journal.importLegacyDNSSnapshot(at: snapshot))
        XCTAssertFalse(journal.importLegacyDNSSnapshot(at: snapshot))

        XCTAssertEqual(reported("platform.legacy_dns_import_failed"), ["step=decode_snapshot error=data_corrupted"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testAnUnreadableJournalRefusesTheImportAndSaysSo() throws {
        try writeSnapshot()
        try Data("not json".utf8).write(to: file)
        let journal = makeJournal()

        XCTAssertFalse(journal.importLegacyDNSSnapshot(at: snapshot))
        XCTAssertEqual(reported("platform.legacy_dns_import_failed"), ["step=journal_unreadable"])
        XCTAssertEqual(names, ["platform.journal_unreadable", "platform.legacy_dns_import_failed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testAnImportThatCannotBeWrittenKeepsTheSnapshotAndSaysSo() throws {
        try writeSnapshot()
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let journal = makeJournal(at: blocker.appendingPathComponent("dir/platform-state.json"))

        XCTAssertFalse(journal.importLegacyDNSSnapshot(at: snapshot))
        XCTAssertEqual(reported("platform.legacy_dns_import_failed"), ["step=journal_write"])
        XCTAssertEqual(reported("platform.journal_write_failed").map { $0.components(separatedBy: " error=")[0] },
                       ["operation=import_legacy_dns surface=systemDNS reason=io"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testAnImportedSnapshotThatCannotBeRemovedIsReported() throws {
        let snapshots = directory.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: false)
        let stuck = snapshots.appendingPathComponent("saved-dns.json")
        try JSONEncoder().encode(LegacyDNSSnapshot(savedAt: .now, interfaces: ["Wi-Fi": ["192.0.2.53"]])).write(to: stuck)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: snapshots.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshots.path) }
            catch { XCTFail("could not restore permissions: \(error)") }
        }
        let journal = makeJournal()

        XCTAssertTrue(journal.importLegacyDNSSnapshot(at: stuck))
        XCTAssertEqual(names, ["platform.legacy_dns_imported", "platform.legacy_dns_import_failed"])
        XCTAssertEqual(reported("platform.legacy_dns_import_failed"), ["step=remove_snapshot error=NSCocoaErrorDomain:513"])
    }
}
