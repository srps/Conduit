// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
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

    /// The app log may write its own `log` file and nothing else protected. Every other entry still applies to it.
    func testAppLogProtectsEverythingButItsOwnLogFile() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let appLog = protectedDiagnosticResources(for: .appLog, in: environment).map(\.resource)

        XCTAssertEqual(Set(appLog), Set(ProtectedRecordResource.allCases).subtracting([.log, .writerLease]))
        XCTAssertFalse(appLog.contains(.log))

        let guardForAppLog = diagnosticDestinationGuard(for: .appLog, in: environment)
        XCTAssertNoThrow(try guardForAppLog.admit(destination: environment.logFile))
        XCTAssertThrowsError(try guardForAppLog.admit(destination: environment.configFile)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .protectedPath, resource: .config))
        }
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

    // MARK: - An entry created between the climb's two reads

    /// Launch recovery writes `platform-state.json` for the first time with an atomic rename while the
    /// snapshot writer admits its destination. Here the rename lands after `realpath` found nothing and
    /// before `lstat` looks. That reproduces the plausible first-creation interleaving identified in review
    /// of run bwveLh, where it was inferred from the recorded events, not observed. The one fresh
    /// resolution finds the file, so the snapshot destination is admitted.
    func testProtectedFileCreatedBetweenTheTwoReadsResolvesOnTheRetry() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let platformState = environment.platformStateFile.standardizedFileURL.path
        let reads = InterposedReads([
            .init(before: .entry(platformState), occurrence: 1) {
                try Data("{}".utf8).write(to: environment.platformStateFile, options: .atomic)
            },
        ])
        let guardForSnapshot = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .snapshot, in: environment),
            caseSensitivity: { _ in true }, reads: reads.reads)

        XCTAssertNoThrow(try guardForSnapshot.admit(destination: environment.snapshotFile))
        XCTAssertEqual(reads.changeFailures, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: platformState), "the interposed creation did not happen")
        XCTAssertEqual(reads.recorded(at: platformState),
                       [.resolve(platformState), .entry(platformState), .resolve(platformState)])
    }

    /// A destination that appears between the reads as an alias of the config is judged on what it resolves
    /// to: a symlink by its canonical path, a hardlink by its identity. Neither is admitted, and the config
    /// bytes are untouched.
    func testDestinationAppearingAsAnAliasOfAProtectedFileIsRefusedAfterTheRetry() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let config = try Data(contentsOf: environment.configFile)
        let symlink = root.appendingPathComponent("audit-link.ndjson")
        let hardlink = root.appendingPathComponent("audit-hard.ndjson")
        let cases: [(URL, () throws -> Void, RecordFileDestinationRefusal)] = [
            (symlink, { try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: environment.configFile) },
             RecordFileDestinationRefusal(reason: .protectedPath, resource: .config)),
            (hardlink, { try FileManager.default.linkItem(at: environment.configFile, to: hardlink) },
             RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .config)),
        ]

        for (destination, create, refusal) in cases {
            let path = destination.standardizedFileURL.path
            let reads = InterposedReads([.init(before: .entry(path), occurrence: 1, change: create)])
            let guardForAudit = SystemRecordFileDestinationGuard(
                protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
                caseSensitivity: { _ in true }, reads: reads.reads)

            XCTAssertThrowsError(try guardForAudit.admit(destination: destination), path) { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal, refusal, path)
            }
            XCTAssertEqual(reads.changeFailures, [], path)
            XCTAssertEqual(reads.recorded(at: path), [.resolve(path), .entry(path), .resolve(path)], path)
        }
        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
    }

    /// A dangling link fails the fresh resolution too and is refused, whether it is the destination or a
    /// protected path. The climb reads the link three times and never past it, and its target is not created.
    func testDanglingLinkIsRefusedAfterExactlyOneRetry() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let nowhere = root.appendingPathComponent("nowhere.json")
        let link = root.appendingPathComponent("audit.ndjson")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nowhere)
        let linkPath = link.standardizedFileURL.path
        let reads = InterposedReads([])
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in true }, reads: reads.reads)

        XCTAssertThrowsError(try guardForAudit.admit(destination: link)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .inspectionFailed, resource: nil))
        }
        XCTAssertEqual(reads.recorded, [.resolve(linkPath), .entry(linkPath), .resolve(linkPath)])

        try FileManager.default.createSymbolicLink(at: environment.configFile, withDestinationURL: nowhere)
        let protectedLink = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in true })
        XCTAssertThrowsError(try protectedLink.admit(destination: root.appendingPathComponent("other.ndjson"))) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .inspectionFailed, resource: .config))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nowhere.path), "a dangling link's target was created")
    }

    /// An entry that appears and is gone again before the fresh resolution is refused, not climbed past.
    func testEntryGoneBeforeTheRetryIsRefused() throws {
        let environment = RuntimeEnvironment(configDirectory: root)
        let destination = root.appendingPathComponent("audit.ndjson")
        let path = destination.standardizedFileURL.path
        let reads = InterposedReads([
            .init(before: .entry(path), occurrence: 1) { try Data().write(to: destination, options: .atomic) },
            .init(before: .resolve(path), occurrence: 2) { try FileManager.default.removeItem(at: destination) },
        ])
        let guardForAudit = SystemRecordFileDestinationGuard(
            protected: protectedDiagnosticResources(for: .connectionAudit, in: environment),
            caseSensitivity: { _ in true }, reads: reads.reads)

        XCTAssertThrowsError(try guardForAudit.admit(destination: destination)) { error in
            XCTAssertEqual(error as? RecordFileDestinationRefusal,
                           RecordFileDestinationRefusal(reason: .inspectionFailed, resource: nil))
        }
        XCTAssertEqual(reads.changeFailures, [])
        XCTAssertEqual(reads.recorded, [.resolve(path), .entry(path), .resolve(path)])
    }

    /// A failure that is not a missing name refuses at the read that gave it: the first resolution, the entry
    /// read, or the fresh resolution. None of them climbs or reads again.
    func testFailuresOtherThanAMissingNameRefuseWithoutFurtherReads() {
        let destination = root.appendingPathComponent("audit.ndjson")
        let scripts: [(resolve: [Int32], entry: [Int32], calls: [String])] = [
            ([EACCES], [], ["resolve"]),
            ([ENOENT], [EACCES], ["resolve", "entry"]),
            ([ENOTDIR], [ELOOP], ["resolve", "entry"]),
            ([ENOENT, EIO], [0], ["resolve", "entry", "resolve"]),
            ([ENOENT, ENOENT], [0], ["resolve", "entry", "resolve"]),
            ([ENOTDIR, ENOTDIR], [0], ["resolve", "entry", "resolve"]),
        ]

        for script in scripts {
            let reads = ScriptedReads(resolve: script.resolve, entry: script.entry)
            let guardUnderTest = SystemRecordFileDestinationGuard(
                protected: [], caseSensitivity: { _ in true }, reads: reads.reads)

            XCTAssertThrowsError(try guardUnderTest.admit(destination: destination), "\(script)") { error in
                XCTAssertEqual(error as? RecordFileDestinationRefusal,
                               RecordFileDestinationRefusal(reason: .inspectionFailed, resource: nil), "\(script)")
            }
            XCTAssertEqual(reads.calls, script.calls, "\(script)")
        }
    }

    /// The system reads, each recorded in order, with a real filesystem change made just before a chosen
    /// read. The change lands exactly between two of the climb's reads, and the real call still answers.
    private final class InterposedReads: @unchecked Sendable {
        enum Read: Equatable {
            case resolve(String)
            case entry(String)

            var path: String {
                switch self {
                case .resolve(let path), .entry(let path): path
                }
            }
        }

        struct Step {
            let before: Read
            /// 1 for the first read of `before`, 2 for the second.
            let occurrence: Int
            let change: () throws -> Void
        }

        private let lock = NIOLock()
        private let steps: [Step]
        private var log: [Read] = []
        private var failures: [String] = []

        init(_ steps: [Step]) { self.steps = steps }

        var reads: SystemRecordFileDestinationGuard.PathReads {
            let system = SystemRecordFileDestinationGuard.PathReads.system
            return .init(
                resolve: { path in self.record(.resolve(path)); return system.resolve(path) },
                entryFailure: { path in self.record(.entry(path)); return system.entryFailure(path) })
        }

        var recorded: [Read] { lock.withLock { log } }
        var changeFailures: [String] { lock.withLock { failures } }

        func recorded(at path: String) -> [Read] { recorded.filter { $0.path == path } }

        private func record(_ read: Read) {
            lock.withLock {
                log.append(read)
                let occurrence = log.filter { $0 == read }.count
                for step in steps where step.before == read && step.occurrence == occurrence {
                    do { try step.change() } catch { failures.append("\(read): \(error)") }
                }
            }
        }
    }

    /// Reads answered from a script of `errno` values, 0 meaning success, for failures a real file
    /// cannot be made to give on demand. A read past the end of its script answers EIO and is recorded.
    private final class ScriptedReads: @unchecked Sendable {
        private let lock = NIOLock()
        private var resolveCodes: [Int32]
        private var entryCodes: [Int32]
        private var log: [String] = []

        init(resolve: [Int32], entry: [Int32]) {
            resolveCodes = resolve
            entryCodes = entry
        }

        var calls: [String] { lock.withLock { log } }

        var reads: SystemRecordFileDestinationGuard.PathReads {
            typealias Failure = SystemRecordFileDestinationGuard.PathReads.Failure
            return .init(
                resolve: { path in
                    let code = self.next("resolve")
                    return code == 0 ? .success(path) : .failure(Failure(code: code))
                },
                entryFailure: { _ in
                    let code = self.next("entry")
                    return code == 0 ? nil : Failure(code: code)
                })
        }

        private func next(_ read: String) -> Int32 {
            lock.withLock {
                log.append(read)
                if read == "resolve" {
                    return resolveCodes.isEmpty ? EIO : resolveCodes.removeFirst()
                }
                return entryCodes.isEmpty ? EIO : entryCodes.removeFirst()
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
