// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The session seam the configuration store consumes (decisions 0015, 0017, 0021, 0027 and 0031), and the bootstrap boundary it relies on.
/// Each test takes its session through the production bootstrap over a scratch root before it seeds anything, and releases it only after its
/// own work has quiesced. The refusals that the store's raw-plan constructor used to make run here instead, at the bootstrap, where a name or
/// a file outside the root is refused before any write.
final class StateRootSessionConfigurationTests: XCTestCase {
    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    /// The environment of a root whose configuration file is at its fixed name.
    private static func environment(_ directory: URL) -> RuntimeEnvironment {
        RuntimeEnvironment(configDirectory: directory, configFile: directory.appendingPathComponent("config.json"))
    }

    private func baseline(_ bytes: Data?) -> ConfigurationFileBaseline {
        ConfigurationFileBaseline(observing: bytes.map { ConfigurationFileInput.present($0) } ?? .missing)
    }

    private func write(_ bytes: Data, to path: String) throws {
        try bytes.write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// A second bootstrap of the root, made while another holder may own it. A session it would return is released by the test at once, so the
    /// result is either the refusal or nil, and no authority is kept.
    private func secondBootstrap(_ environment: RuntimeEnvironment) -> StateRootAcquisitionFailure? {
        let outcome = StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in XCTFail("the second bootstrap's lease could not be closed: errno \(failure.errno)") }
        )
        switch outcome {
        case .success(let session):
            releaseScratchStateRoot(session)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Makes a store over a session for the root, loads through it once, and returns whether the load was admitted. The store and its session
    /// are locals of this call, so when it returns the last reference to both is gone.
    @RuntimeActor
    private func loadThroughAStore(_ environment: RuntimeEnvironment, access: any StateFileAccessing) async throws -> Bool {
        let session = try acquireScratchStateRoot(environment)
        let store = ConfigurationStore(session: session, access: access, work: PlatformWork(label: "test.session-load"))
        guard case .admitted = await store.load(context: Self.context) else { return false }
        return true
    }

    // MARK: - Bootstrap boundary

    /// A writer-owned name that is not its fixed slot is refused before any effect: no directory is made and no lease is taken. This is the
    /// boundary check that the store's raw-plan name refusal used to cover.
    func testABadWritableNameIsRefusedAtBootstrapBeforeAnyEffect() throws {
        let scratch = try StateRootScratch.make("session-name")
        defer { removeScratch([scratch]) }
        let missingRoot = scratch.appendingPathComponent("not-yet", isDirectory: true)
        let log = StateRootEffectLog()
        let outcome = StateRootBootstrap.acquire(
            RuntimeEnvironment(configDirectory: missingRoot, configFile: missingRoot.appendingPathComponent("custom.json")),
            createRootIfMissing: true,
            fileSystem: RecordingStateRootFileSystem(OSStateRootFileSystem(), log: log),
            leasing: RecordingStateWriterLeasing(OSStateWriterLeasing(), log: log),
            onReleaseFailure: { failure in XCTFail("a refused bootstrap's lease could not be closed: errno \(failure.errno)") }
        )
        guard case .failure(.refused(.unsupportedFileName(.config))) = outcome else {
            return XCTFail("a custom configuration name is refused at bootstrap, got \(outcome)")
        }
        XCTAssertTrue(log.effects.isEmpty, "a refused name starts no file-system effect and takes no lease")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path), "a refused name creates no directory")
    }

    /// A writer-owned file that resolves outside the root is refused after the lease, and the refusal releases that lease. Nothing under the
    /// root is read or written. A later bootstrap of the same root takes it, which shows the lease closed.
    func testAConfigurationFileOutsideTheRootIsRefusedAtBootstrapAndTheLeaseCloses() throws {
        let scratch = try StateRootScratch.make("session-outside")
        defer { removeScratch([scratch]) }
        let root = scratch.appendingPathComponent("state", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let log = StateRootEffectLog()
        let outcome = StateRootBootstrap.acquire(
            RuntimeEnvironment(configDirectory: root, configFile: outside.appendingPathComponent("config.json")),
            createRootIfMissing: true,
            fileSystem: RecordingStateRootFileSystem(OSStateRootFileSystem(), log: log),
            leasing: RecordingStateWriterLeasing(OSStateWriterLeasing(), log: log),
            onReleaseFailure: { failure in XCTFail("the refused lease could not be closed: errno \(failure.errno)") }
        )
        guard case .failure(.refused(.outsideRoot(.config))) = outcome else {
            return XCTFail("an outside configuration file is refused at bootstrap, got \(outcome)")
        }
        XCTAssertEqual(log.effects.filter { $0.operation == "lease" }.count, 1, "the refusal came after the lease was attempted")
        let reacquired = try acquireScratchStateRoot(Self.environment(root))
        releaseScratchStateRoot(reacquired)
    }

    // MARK: - Component map and replacement

    /// Each component maps to its own resolved file, and a conditional replacement of one writes that file alone. The other two configuration
    /// files and the journal keep their bytes.
    func testEachComponentReplacesOnlyItsOwnResolvedFile() throws {
        let scratch = try StateRootScratch.make("session-components")
        defer { removeScratch([scratch]) }
        let session = try acquireScratchStateRoot(Self.environment(scratch))
        defer { releaseScratchStateRoot(session) }
        XCTAssertEqual(session.configurationFile(for: .runtime).role, .config)
        XCTAssertEqual(session.configurationFile(for: .platform).role, .platformConfig)
        XCTAssertEqual(session.configurationFile(for: .preferences).role, .preferences)

        let journal = Data("journal-bytes".utf8)
        try write(journal, to: session.plan.journal.path)
        var current: [ConfigurationComponent: Data] = [
            .runtime: Data("runtime-prior".utf8),
            .platform: Data("platform-prior".utf8),
            .preferences: Data("preferences-prior".utf8),
        ]
        for (component, bytes) in current {
            try write(bytes, to: session.configurationFile(for: component).path)
        }

        let access = StateFileAccess.operatingSystem()
        for component in ConfigurationComponent.allCases {
            let staged = Data("\(component)-staged".utf8)
            let outcome = session.replaceConfigurationFile(
                component, staged: staged, expecting: baseline(current[component]), access: access
            )
            XCTAssertEqual(outcome, .verifiedPersisted(writeError: nil), "\(component) persists its own file")
            current[component] = staged
            for owned in ConfigurationComponent.allCases {
                let bytes = try read(session.configurationFile(for: owned).path)
                XCTAssertEqual(bytes, current[owned], "after \(component), \(owned) holds the bytes it was given")
            }
            let journalBytes = try read(session.plan.journal.path)
            XCTAssertEqual(journalBytes, journal, "after \(component), the journal is unchanged")
        }
    }

    /// A stale baseline is a conflict through the session, before any write. The external bytes stay, and the fake records no write.
    func testAStaleBaselineIsAConflictThroughTheSessionWithNoWrite() throws {
        let scratch = try StateRootScratch.make("session-conflict")
        defer { removeScratch([scratch]) }
        let session = try acquireScratchStateRoot(Self.environment(scratch))
        defer { releaseScratchStateRoot(session) }
        let path = session.configurationFile(for: .runtime).path
        let prior = Data("runtime-prior".utf8)
        let external = Data("runtime-external".utf8)
        let fake = FakeStateFileAccess(files: [path: external])

        let outcome = session.replaceConfigurationFile(.runtime, staged: Data("runtime-staged".utf8), expecting: baseline(prior), access: fake)

        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(fake.storedBytes(at: path), external, "the observed external bytes are kept")
        XCTAssertFalse(fake.observations.contains { if case .write = $0 { true } else { false } }, "no write is made")
    }

    /// A configuration file that is a symbolic link inside the root resolves to its in-root target. The write lands on the target, and the link
    /// is kept.
    func testAnInRootConfigurationAliasIsWrittenThroughAndKept() throws {
        let scratch = try StateRootScratch.make("session-alias")
        defer { removeScratch([scratch]) }
        // The root is the scratch directory. The first session fixes its canonical path before the link exists.
        let first = try acquireScratchStateRoot(Self.environment(scratch))
        let root = first.plan.root.path
        releaseScratchStateRoot(first)

        let targetPath = root + "/runtime-target.json"
        let prior = Data("runtime-prior".utf8)
        try write(prior, to: targetPath)
        let linkPath = root + "/config.json"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)

        let session = try acquireScratchStateRoot(Self.environment(scratch))
        defer { releaseScratchStateRoot(session) }
        XCTAssertEqual(session.configurationFile(for: .runtime).path, targetPath, "the link resolves to its in-root target")
        let staged = Data("runtime-staged".utf8)

        let outcome = session.replaceConfigurationFile(
            .runtime, staged: staged, expecting: baseline(prior), access: StateFileAccess.operatingSystem()
        )

        XCTAssertEqual(outcome, .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try read(targetPath), staged, "the write lands on the in-root target")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath), targetPath, "the link is kept")
    }

    // MARK: - Lifetime

    /// A store keeps its session's lease. A second bootstrap of the root is busy while the store lives, and once the store is dropped the
    /// lease closes and the root can be taken again.
    @RuntimeActor
    func testAStoreKeepsTheRootBusyUntilItIsDroppedThenTheRootIsTakenAgain() async throws {
        let scratch = try StateRootScratch.make("session-store-lifetime")
        defer { removeScratch([scratch]) }
        let environment = Self.environment(scratch)
        var store: ConfigurationStore?
        // Runs before the directory's removal, so a failed assertion still drops the store's lease before the root goes.
        defer { store = nil }
        weak var weakSession: StateRootSession?
        do {
            let session = try acquireScratchStateRoot(environment)
            weakSession = session
            store = ConfigurationStore(session: session, access: FakeStateFileAccess(), work: PlatformWork(label: "test.session-lifetime"))
        }
        XCTAssertNotNil(store)
        XCTAssertNotNil(weakSession, "the store keeps its session alive after the caller's reference ends")
        XCTAssertEqual(secondBootstrap(environment), StateRootAcquisitionFailure.busy, "the root stays busy while the store holds its session")

        store = nil
        XCTAssertNil(weakSession, "dropping the last store drops the session")
        let reacquired = try acquireScratchStateRoot(environment)
        releaseScratchStateRoot(reacquired)
    }

    /// The store owns its session for its whole life, so the session stays held while the call's physical read runs. A second bootstrap made
    /// from inside that read is busy. The probe counts each attempt and keeps no authority. Once the store's call returns and the store is gone,
    /// the root can be taken again.
    @RuntimeActor
    func testASecondBootstrapIsBusyFromInsideAStoreCallsPhysicalReads() async throws {
        let scratch = try StateRootScratch.make("session-in-flight")
        defer { removeScratch([scratch]) }
        let environment = Self.environment(scratch)
        let probe = BootstrapProbe(environment: environment)

        let admitted = try await loadThroughAStore(environment, access: ProbingAccess(inner: FakeStateFileAccess(), probe: probe))

        XCTAssertTrue(admitted, "the load was admitted")
        XCTAssertEqual(probe.attempts, 3, "one probe runs before each of the three configuration reads")
        XCTAssertEqual(probe.busy, probe.attempts, "every bootstrap made inside the store's call was busy")
        XCTAssertEqual(probe.unexpectedSessions, 0, "no probe took a session while the store held it")
        let reacquired = try acquireScratchStateRoot(environment)
        releaseScratchStateRoot(reacquired)
    }
}

/// Makes a second bootstrap of one root each time the store reads a file, from inside the store's physical step. The store owns the session for
/// its whole life, so every attempt must be busy. A session that an attempt takes anyway is released when the attempt ends, and it is counted as unexpected.
private final class BootstrapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let environment: RuntimeEnvironment
    private var attemptCount = 0
    private var busyCount = 0
    private var unexpectedSessionCount = 0

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    var attempts: Int { lock.withLock { attemptCount } }
    var busy: Int { lock.withLock { busyCount } }
    var unexpectedSessions: Int { lock.withLock { unexpectedSessionCount } }

    func attempt() {
        let outcome = StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in XCTFail("a probe's session could not be closed: errno \(failure.errno)") }
        )
        let isBusy: Bool
        switch outcome {
        case .failure(.busy): isBusy = true
        case .success, .failure: isBusy = false
        }
        lock.withLock {
            attemptCount += 1
            if isBusy {
                busyCount += 1
            } else {
                unexpectedSessionCount += 1
            }
        }
    }
}

/// The fake file access, with the probe run before each read. The read runs on the store's `PlatformWork` thread, inside the store's call.
private final class ProbingAccess: StateFileAccessing, @unchecked Sendable {
    let inner: FakeStateFileAccess
    let probe: BootstrapProbe

    init(inner: FakeStateFileAccess, probe: BootstrapProbe) {
        self.inner = inner
        self.probe = probe
    }

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        probe.attempt()
        return inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}
