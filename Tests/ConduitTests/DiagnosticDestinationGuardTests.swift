// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The events writer and the system guard against real files and aliases (#222).
/// `pm-proxy --config <root>/events.ndjson` makes the default events file the config file.
final class DiagnosticDestinationGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-diag-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEventsWriterCollidingWithConfigRefusesWithoutRecursionOrWrites() throws {
        let environment = RuntimeEnvironment.explicit(configFile: root.appendingPathComponent("events.ndjson"))
        XCTAssertEqual(environment.eventsFile, environment.configFile)
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let config = try Data(contentsOf: environment.configFile)

        let log = RuntimeEventLog(capacity: 16)
        let writer = RuntimeEventFileWriter(
            fileURL: environment.eventsFile, logger: DiscardingLogSink(),
            destinationGuard: diagnosticDestinationGuard(for: .runtimeEvents, in: environment),
            eventLog: log
        )
        log.setSink { writer.record($0) }

        log.append(RuntimeEvent(kind: .lifecycle, event: "fixture.before_refusal"))
        XCTAssertTrue(writer.flush(timeout: 5), "A refused events writer must not block its flush")

        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertEqual(writer.statistics.writtenRecords, 0)
        XCTAssertGreaterThanOrEqual(writer.statistics.droppedRecords, 1)
        let refusals = log.events.filter { $0.event == RecordFileDestinationGate.eventName }
        XCTAssertEqual(refusals.map(\.detail), ["sink=events reason=protected_path resource=config"])
    }

    func testEventsRoleMayWriteItsOwnOutputButNotTheConfig() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let guardForEvents = diagnosticDestinationGuard(for: .runtimeEvents, in: environment)

        XCTAssertNoThrow(try guardForEvents.admit(destination: environment.eventsFile))
        XCTAssertThrowsError(try guardForEvents.admit(destination: environment.configFile)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
        }
    }

    /// The closed set: every resource code once, except the opt-in writer lease and, for events, the output itself.
    func testProtectedSetsDifferOnlyByTheEventsOutput() {
        let environment = RuntimeEnvironment(configDirectory: root)
        let audit = protectedDiagnosticResources(for: .connectionAudit, in: environment).map(\.resource)
        let events = protectedDiagnosticResources(for: .runtimeEvents, in: environment).map(\.resource)

        XCTAssertEqual(Set(audit), Set(ProtectedRecordResource.allCases).subtracting([.writerLease]))
        XCTAssertEqual(Set(events), Set(ProtectedRecordResource.allCases).subtracting([.events, .writerLease]))
        XCTAssertEqual(audit.count, Set(audit).count, "a resource code appears once")
    }

    /// Each entry names the file the host or daemon actually writes, not a look-alike.
    func testProtectedFilesUseTheirProductionNames() {
        let environment = RuntimeEnvironment(configDirectory: root)
        let urls = Dictionary(uniqueKeysWithValues:
            protectedDiagnosticResources(for: .connectionAudit, in: environment).map { ($0.resource, $0.url.path) })

        XCTAssertEqual(urls[.ready], root.appendingPathComponent("ready.json").path)
        XCTAssertEqual(urls[.daemonReady], root.appendingPathComponent("daemon-ready.json").path)
        XCTAssertEqual(urls[.control], root.appendingPathComponent("control.sock").path)
    }

    /// The writer lease is one explicit extra entry, present only when a composer passes its URL.
    func testWriterLeaseIsProtectedOnlyWhenItsURLIsPassed() {
        let environment = RuntimeEnvironment(configDirectory: root)
        let lease = root.appendingPathComponent("lease.lock")
        let without = protectedDiagnosticResources(for: .connectionAudit, in: environment)
        let with = protectedDiagnosticResources(for: .connectionAudit, in: environment, writerLeaseFile: lease)

        XCTAssertEqual(with.count, without.count + 1)
        XCTAssertEqual(with.last, ProtectedRecordFile(resource: .writerLease, url: lease))
    }

    /// Every protected path is refused by path alone, and admission creates nothing.
    func testEveryProtectedResourceIsRefusedByPathWithoutCreatingIt() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let guardForAudit = diagnosticDestinationGuard(for: .connectionAudit, in: environment)
        for entry in protectedDiagnosticResources(for: .connectionAudit, in: environment) {
            XCTAssertThrowsError(try guardForAudit.admit(destination: entry.url), "\(entry.resource)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .protectedPath, resource: entry.resource))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.path), "\(entry.resource) was created")
        }
    }

    /// The opened descriptor is judged before any write. A descriptor on the config is refused
    /// even when the path it was opened from looks harmless.
    func testOpenedDescriptorOnProtectedFileIsRefusedBeforeWriting() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let guardForAudit = diagnosticDestinationGuard(for: .connectionAudit, in: environment)
        let harmless = root.appendingPathComponent("audit.ndjson")
        try Data().write(to: harmless)
        let protectedHandle = try FileHandle(forReadingFrom: environment.configFile)
        defer { try? protectedHandle.close() }
        let harmlessHandle = try FileHandle(forReadingFrom: harmless)
        defer { try? harmlessHandle.close() }

        XCTAssertThrowsError(try guardForAudit.admit(openedDescriptor: protectedHandle.fileDescriptor, destination: harmless)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .config))
        }
        XCTAssertNoThrow(try guardForAudit.admit(openedDescriptor: harmlessHandle.fileDescriptor, destination: harmless))
    }

    /// On a case-insensitive volume `CONFIG.JSON` and `config.json` are one file. The guard refuses the
    /// name before a directory or file is created. The probe supplies the volume answer, so this holds on any volume.
    func testCaseEquivalentNameIsRefusedBeforeCreationOnCaseInsensitiveVolume() {
        let environment = RuntimeEnvironment(configDirectory: root)
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in false })
        let alias = root.appendingPathComponent("CONFIG.JSON")

        XCTAssertThrowsError(try guardForAudit.admit(destination: alias)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
    }

    /// On a case-sensitive volume the same spelling is a different file, so it is admitted.
    /// The exact protected path is still refused by path.
    func testCaseEquivalentNameIsAdmittedOnCaseSensitiveVolume() {
        let environment = RuntimeEnvironment(configDirectory: root)
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in true })

        XCTAssertNoThrow(try guardForAudit.admit(destination: root.appendingPathComponent("CONFIG.JSON")))
        XCTAssertThrowsError(try guardForAudit.admit(destination: environment.configFile)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
        }
    }

    /// An unknown volume answer refuses a case-equivalent name, and only that name: it never reaches a
    /// name that is not case-equivalent. A probe that throws refuses the same way.
    func testUnknownOrFailedCaseAnswerRefusesOnlyCaseEquivalentNames() {
        struct ProbeFailure: Error {}
        let environment = RuntimeEnvironment(configDirectory: root)
        let protected = protectedDiagnosticResources(for: .connectionAudit, in: environment)
        let unknown = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in nil })
        let failing = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in throw ProbeFailure() })
        let alias = root.appendingPathComponent("CONFIG.JSON")

        for guardUnderTest in [unknown, failing] {
            XCTAssertThrowsError(try guardUnderTest.admit(destination: alias)) { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .inspectionFailed, resource: .config))
            }
        }
        XCTAssertNoThrow(try unknown.admit(destination: root.appendingPathComponent("audit.ndjson")))
    }

    /// The fixture bypass admits everything, so only an explicit fixture may name it.
    func testUncheckedFixtureBypassAdmitsEverything() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let bypass = UncheckedRecordFileDestination()
        XCTAssertNoThrow(try bypass.admit(destination: environment.configFile))
        XCTAssertNoThrow(try bypass.admit(openedDescriptor: -1, destination: environment.configFile))
    }

    /// Spellings that fold onto a missing protected name are refused before creation on a case-insensitive
    /// volume. The probe answers `false`, so this holds on any volume. Long s, final sigma and micro sign
    /// are the ones `lowercased()` missed. The normalized spelling is NFD against an NFC protected name.
    func testFoldedSpellingsOfMissingProtectedNamesAreRefusedBeforeCreation() {
        for pair in Self.foldedPairs {
            let protected = [ProtectedRecordFile(resource: .config, url: root.appendingPathComponent(pair.protected))]
            let guardForAudit = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in false })
            let alias = root.appendingPathComponent(pair.destination)

            XCTAssertThrowsError(try guardForAudit.admit(destination: alias), "\(pair)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .protectedPath, resource: .config), "\(pair)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path), "\(pair) was created")
        }
    }

    /// The same spellings are distinct files on a case-sensitive volume, so each is admitted.
    func testFoldedSpellingsAreAdmittedOnCaseSensitiveVolume() {
        for pair in Self.foldedPairs where pair.caseOnly {
            let protected = [ProtectedRecordFile(resource: .config, url: root.appendingPathComponent(pair.protected))]
            let guardForAudit = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in true })

            XCTAssertNoThrow(try guardForAudit.admit(destination: root.appendingPathComponent(pair.destination)), "\(pair)")
        }
    }

    /// Diacritics are not folded away: `café` and `cafe` are different names on every volume.
    func testDiacriticsDoNotFoldOntoPlainLetters() {
        let protected = [ProtectedRecordFile(resource: .config, url: root.appendingPathComponent("cafe.json"))]
        let guardForAudit = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in false })

        XCTAssertNoThrow(try guardForAudit.admit(destination: root.appendingPathComponent("caf\u{E9}.json")))
    }

    /// A Swift string comparison is canonical equivalence, so NFC and NFD spellings of one name are one path
    /// to the guard. They are refused on every volume, including a case-sensitive one.
    func testCanonicallyEquivalentSpellingIsRefusedOnCaseSensitiveVolume() {
        let protected = [ProtectedRecordFile(resource: .config, url: root.appendingPathComponent("Caf\u{E9}.json"))]
        let guardForAudit = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in true })

        XCTAssertThrowsError(try guardForAudit.admit(destination: root.appendingPathComponent("Cafe\u{301}.json"))) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
        }
    }

    /// A destination beneath a protected file, or an ancestor of one, is refused before any directory is
    /// created. The config here is nested under a directory that does not exist yet, so that missing
    /// directory is the ancestor a write would turn into a file. Exact relations refuse on every volume.
    func testMissingAncestorOfNestedCustomConfigIsRefusedBeforeCreation() {
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        let config = custom.appendingPathComponent("config.json")
        let environment = RuntimeEnvironment.explicit(configFile: config)
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in true })
        let destinations = [
            custom,                                                    // the config's missing directory
            config.appendingPathComponent("audit.ndjson"),             // beneath the config file
            config.appendingPathComponent("nested").appendingPathComponent("audit.ndjson"),
        ]

        for destination in destinations {
            XCTAssertThrowsError(try guardForAudit.admit(destination: destination), "\(destination.path)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path), "a refused ancestor created a directory")
    }

    /// Siblings that share a name prefix with a protected file, or sit beside it, are other files. No component
    /// of theirs matches a protected component under folding, so the volume is never asked.
    func testSiblingsOfMissingNestedConfigAreAdmittedWithoutAVolumeAnswer() {
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        let environment = RuntimeEnvironment.explicit(configFile: custom.appendingPathComponent("config.json"))
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in
                XCTFail("a sibling with no folded overlap must not reach the volume probe")
                return nil
            })
        let siblings = [
            custom.appendingPathComponent("audit.ndjson"),
            custom.appendingPathComponent("config.json-other").appendingPathComponent("audit.ndjson"),
            root.appendingPathComponent("custom-audit").appendingPathComponent("audit.ndjson"),
        ]

        for destination in siblings {
            XCTAssertNoThrow(try guardForAudit.admit(destination: destination), "\(destination.path)")
        }
    }

    /// A folded spelling of a protected file's ancestor or descendant is refused where the volume may alias it,
    /// and admitted where the volume keeps the names apart. An exact descendant is refused on every volume.
    func testFoldedAncestorAndDescendantSpellingsFollowTheVolumeAnswer() {
        for pair in Self.foldedPairs where pair.caseOnly {
            let protectedFile = root.appendingPathComponent(pair.protected, isDirectory: true)
                .appendingPathComponent("config.json")
            let protected = [ProtectedRecordFile(resource: .config, url: protectedFile)]
            let aliasing = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in false })
            let distinct = SystemRecordFileDestinationGuard(protected: protected, caseSensitivity: { _ in true })
            let ancestor = root.appendingPathComponent(pair.destination, isDirectory: true)
            let descendant = ancestor.appendingPathComponent("config.json").appendingPathComponent("audit.ndjson")

            for destination in [ancestor, descendant] {
                XCTAssertThrowsError(try aliasing.admit(destination: destination), "\(pair) \(destination.path)") { error in
                    XCTAssertEqual(error as? RecordFileDestinationRefusal,
                                   RecordFileDestinationRefusal(reason: .protectedPath, resource: .config), "\(pair)")
                }
                XCTAssertNoThrow(try distinct.admit(destination: destination), "\(pair) \(destination.path)")
            }
            let exactDescendant = protectedFile.appendingPathComponent("audit.ndjson")
            XCTAssertThrowsError(try distinct.admit(destination: exactDescendant), "\(pair)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .protectedPath, resource: .config), "\(pair)")
            }
        }
    }

    private struct FoldedPair: CustomStringConvertible {
        let protected: String
        let destination: String
        /// True when the two names differ only by case or folding, not by canonical form.
        let caseOnly: Bool
        var description: String { "\(protected) vs \(destination)" }
    }

    private static let foldedPairs: [FoldedPair] = [
        FoldedPair(protected: "preferences.json", destination: "preferenceſ.json", caseOnly: true),  // long s U+017F
        FoldedPair(protected: "\u{3A3}.json", destination: "\u{3C2}.json", caseOnly: true),          // sigma vs final sigma
        FoldedPair(protected: "\u{3A3}.json", destination: "\u{3C3}.json", caseOnly: true),          // capital vs small sigma
        FoldedPair(protected: "\u{3BC}.json", destination: "\u{B5}.json", caseOnly: true),           // mu vs micro sign U+00B5
        FoldedPair(protected: "Caf\u{E9}.json", destination: "CAFE\u{301}.json", caseOnly: false),  // NFC vs NFD and case
    ]
}
