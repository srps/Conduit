// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import Conduit
import ProxyKernel

/// Startup ownership (decisions 0017, 0020 and 0028): the root is taken before
/// anything under it is read, migrated, seeded or recovered. Real lease and
/// file system in scratch directories where the question is the disk, and the
/// scripted fakes where it is a layout decision.
final class RuntimeStartupOwnershipTests: XCTestCase {
    private var scratch: [URL] = []

    override func tearDown() {
        removeScratch(scratch)
        scratch = []
        super.tearDown()
    }

    private func makeScratch(createDirectory: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-startup-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        if createDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// The refusal of an acquisition that must not succeed, or nil after failing the test.
    private func refusal(
        _ outcome: Result<StateRootSession, StateRootAcquisitionFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StateRootAcquisitionFailure? {
        switch outcome {
        case .success(let session):
            releaseScratchStateRoot(session, file: file, line: line)
            XCTFail("the root was taken when a refusal was expected", file: file, line: line)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    private func bootstrap(
        _ environment: RuntimeEnvironment,
        leasing: any StateWriterLeasing = OSStateWriterLeasing(),
        fileSystem: any StateRootFileSystem = OSStateRootFileSystem(),
        createRootIfMissing: Bool = false
    ) -> Result<StateRootSession, StateRootAcquisitionFailure> {
        StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: createRootIfMissing,
            fileSystem: fileSystem,
            leasing: leasing,
            onReleaseFailure: { failure in XCTFail("a lease could not be closed: errno \(failure.errno)") }
        )
    }

    // MARK: - Busy and first touch

    /// A held root refuses before the configuration is read, and the bytes stay as they were.
    func testBusyRootRefusesBeforeAnyReadAndLeavesTheConfigurationBytes() throws {
        let directory = try makeScratch()
        let config = directory.appendingPathComponent("config.json")
        try Data("original".utf8).write(to: config)
        let canonical = try OSStateRootFileSystem().canonicalPath(of: directory.path)
        guard case .acquired(let holder) = OSStateWriterLeasing().acquire(
            root: CanonicalStateRoot(canonicalPath: canonical), onReleaseFailure: { _ in XCTFail("a holder close failed") }
        ) else {
            return XCTFail("the holder takes the root first")
        }
        defer { _ = holder.release() }

        let failure = refusal(bootstrap(.isolated(stateDirectory: directory)))
        XCTAssertEqual(failure, .busy)
        XCTAssertEqual(try Data(contentsOf: config), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("platform.json").path),
                       "a busy root gets no authoritative file")
    }

    /// The busy path asks the lease and nothing else: the counting fake sees one refusal.
    func testBusyRefusalIsCountedOnceAndTakesNoOtherAuthority() throws {
        let directory = try makeScratch()
        let fake = FakeStateWriterLeasing()
        let canonical = CanonicalStateRoot(canonicalPath: try OSStateRootFileSystem().canonicalPath(of: directory.path))
        guard case .acquired(let holder) = fake.acquire(root: canonical, onReleaseFailure: { _ in }) else {
            return XCTFail("the fake grants the first holder")
        }
        defer { _ = holder.release() }

        XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: directory), leasing: fake)), .busy)
        XCTAssertEqual(fake.acquireCount, 2)
        XCTAssertEqual(fake.busyCount, 1)
    }

    /// A fresh root reports no prior configuration.
    func testFreshRootReportsNoPriorConfiguration() throws {
        let directory = try makeScratch()
        let session = try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: directory)))
        XCTAssertFalse(session.configFilePredatesLaunch, "a fresh root has no configuration yet")
        releaseScratchStateRoot(session)
    }

    /// The configuration-present fact is read under the lease, before any load can write the file. The shared log
    /// orders the lease against every effect on the configuration, so the claim is checked, not assumed.
    func testConfigPresenceIsReadOnlyAfterTheLeaseIsHeld() throws {
        let directory = try makeScratch()
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let log = StateRootEffectLog()
        let session = try XCTUnwrap(bootstrapSession(
            .isolated(stateDirectory: directory),
            fileSystem: RecordingStateRootFileSystem(OSStateRootFileSystem(), log: log),
            leasing: RecordingStateWriterLeasing(OSStateWriterLeasing(), log: log)
        ))
        XCTAssertTrue(session.configFilePredatesLaunch)
        releaseScratchStateRoot(session)

        let leaseAt = try XCTUnwrap(log.effects.firstIndex { $0.operation == "lease" }, "the lease was attempted")
        let firstConfigAt = try XCTUnwrap(log.effects.firstIndex { $0.path.hasSuffix("/config.json") }, "the configuration was read")
        XCTAssertGreaterThan(firstConfigAt, leaseAt, "the configuration is first touched after the lease is held")
    }

    private func bootstrapSession(
        _ environment: RuntimeEnvironment,
        fileSystem: any StateRootFileSystem = OSStateRootFileSystem(),
        leasing: any StateWriterLeasing = OSStateWriterLeasing(),
        createRootIfMissing: Bool = false
    ) -> StateRootSession? {
        switch bootstrap(environment, leasing: leasing, fileSystem: fileSystem, createRootIfMissing: createRootIfMissing) {
        case .success(let session): return session
        case .failure(let failure):
            XCTFail("the root should be taken, got \(failure)")
            return nil
        }
    }

    // MARK: - Names before any effect (decision 0028)

    /// A fresh nested root with an arbitrary writable name is refused before anything is created, read or locked.
    func testFreshNestedRootWithACustomNameIsRefusedBeforeAnyEffect() throws {
        let top = try makeScratch(createDirectory: false)
        let state = top.appendingPathComponent("one/two/state", isDirectory: true)
        let log = StateRootEffectLog()
        let outcome = bootstrap(
            RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("custom.json")),
            leasing: RecordingStateWriterLeasing(OSStateWriterLeasing(), log: log),
            fileSystem: RecordingStateRootFileSystem(OSStateRootFileSystem(), log: log),
            createRootIfMissing: true
        )

        XCTAssertEqual(refusal(outcome), .refused(.unsupportedFileName(.config)))
        XCTAssertEqual(log.effects, [], "the refusal read, created and locked nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: top.path), "no ancestor of the root was created")
    }

    /// An overlong configuration directory is refused before any effect, through the production bootstrap, with a file
    /// system that would otherwise create every missing prefix. The effect log and the lease count stay empty.
    func testAnOverlongRootIsRefusedBeforeAnyEffect() {
        let root = URL(fileURLWithPath: absolutePath(byteCount: Int(PATH_MAX)), isDirectory: true)
        XCTAssertGreaterThanOrEqual(root.path.utf8.count, Int(PATH_MAX))
        let log = StateRootEffectLog()
        let outcome = bootstrap(
            RuntimeEnvironment(configDirectory: root),
            leasing: RecordingStateWriterLeasing(FakeStateWriterLeasing(), log: log),
            fileSystem: RecordingStateRootFileSystem(FakeStateRootFileSystem(), log: log),
            createRootIfMissing: true
        )

        XCTAssertEqual(refusal(outcome), .refused(.rootUnavailable(errno: ENAMETOOLONG)))
        XCTAssertEqual(log.effects, [], "an overlong root reached no file system or lease effect")
    }

    /// Every writer role refuses an arbitrary name before the file system or the lease sees an effect.
    func testEveryWriterRoleRefusesAnArbitraryNameBeforeAnyEffect() {
        let state = URL(fileURLWithPath: "/state", isDirectory: true)
        let custom = state.appendingPathComponent("custom.json")
        let cases: [(StateRootRole, RuntimeEnvironment)] = [
            (.config, RuntimeEnvironment(configDirectory: state, configFile: custom)),
            (.platformConfig, RuntimeEnvironment(configDirectory: state, platformConfigFile: custom)),
            (.preferences, RuntimeEnvironment(configDirectory: state, preferencesFile: custom)),
            (.journal, RuntimeEnvironment(configDirectory: state, platformStateFile: custom)),
        ]
        for (role, environment) in cases {
            let log = StateRootEffectLog()
            let outcome = bootstrap(
                environment,
                leasing: RecordingStateWriterLeasing(FakeStateWriterLeasing(), log: log),
                fileSystem: RecordingStateRootFileSystem(FakeStateRootFileSystem(), log: log),
                createRootIfMissing: true
            )
            XCTAssertEqual(refusal(outcome), .refused(.unsupportedFileName(role)), "\(role)")
            XCTAssertEqual(log.effects, [], "\(role) touched nothing")
        }
    }

    /// A fold alias of a slot is decided after the lease, by the volume. A folding volume accepts it and a case-sensitive
    /// one refuses it, and in both the lease comes before the case query.
    func testAFoldAliasOfASlotIsDecidedAfterTheLeaseByTheVolume() throws {
        let state = URL(fileURLWithPath: "/state", isDirectory: true)
        let environment = RuntimeEnvironment(configDirectory: state, configFile: state.appendingPathComponent("CONFIG.json"))

        let folding = FakeStateRootFileSystem(caseSensitiveNames: false)
        folding.addDirectory("/state")
        let foldingLog = StateRootEffectLog()
        let accepted = try XCTUnwrap(bootstrapSession(
            environment,
            fileSystem: RecordingStateRootFileSystem(folding, log: foldingLog),
            leasing: RecordingStateWriterLeasing(FakeStateWriterLeasing(), log: foldingLog)
        ))
        XCTAssertEqual(accepted.plan.config.path, "/state/config.json")
        releaseScratchStateRoot(accepted)
        let foldingLease = try XCTUnwrap(foldingLog.effects.firstIndex { $0.operation == "lease" })
        let foldingCase = try XCTUnwrap(foldingLog.effects.firstIndex { $0.operation == "caseQuery" })
        XCTAssertLessThan(foldingLease, foldingCase)

        let sensitive = FakeStateRootFileSystem(caseSensitiveNames: true)
        sensitive.addDirectory("/state")
        let sensitiveLog = StateRootEffectLog()
        XCTAssertEqual(
            refusal(bootstrap(
                environment,
                leasing: RecordingStateWriterLeasing(FakeStateWriterLeasing(), log: sensitiveLog),
                fileSystem: RecordingStateRootFileSystem(sensitive, log: sensitiveLog)
            )),
            .refused(.unsupportedFileName(.config))
        )
        let sensitiveLease = try XCTUnwrap(sensitiveLog.effects.firstIndex { $0.operation == "lease" })
        let sensitiveCase = try XCTUnwrap(sensitiveLog.effects.firstIndex { $0.operation == "caseQuery" })
        XCTAssertLessThan(sensitiveLease, sensitiveCase)
    }

    // MARK: - Directory setup before the lease (decision 0017)

    /// A fresh nested root, as an explicit path or a fresh user's Application Support, gets its missing ancestors. They
    /// and the root are owner-only, and an existing directory keeps its mode.
    func testFreshNestedRootIsCreatedWithItsAncestorsOwnerOnly() throws {
        let existing = try makeScratch()
        XCTAssertEqual(Darwin.chmod(existing.path, 0o755), 0)
        let state = existing.appendingPathComponent("Library/Application Support/Conduit", isDirectory: true)

        let session = try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: state), createRootIfMissing: true))
        releaseScratchStateRoot(session)

        for directory in [existing.appendingPathComponent("Library"),
                          existing.appendingPathComponent("Library/Application Support"),
                          state] {
            XCTAssertEqual(mode(directory.path), 0o700, directory.lastPathComponent)
        }
        XCTAssertEqual(mode(existing.path), 0o755, "an existing directory keeps its mode")
    }

    /// The directories are made outermost first, and every one of them before the lease. The shared log is the order.
    func testDirectoriesAreMadeOutermostFirstAndAllBeforeTheLease() throws {
        let top = try makeScratch(createDirectory: false)
        let state = top.appendingPathComponent("a/b/state", isDirectory: true)
        let log = StateRootEffectLog()
        let session = try XCTUnwrap(bootstrapSession(
            .isolated(stateDirectory: state),
            fileSystem: RecordingStateRootFileSystem(OSStateRootFileSystem(), log: log),
            leasing: RecordingStateWriterLeasing(OSStateWriterLeasing(), log: log),
            createRootIfMissing: true
        ))
        releaseScratchStateRoot(session)

        let made = log.effects.filter { $0.operation == "mkdir" }.map(\.path)
        XCTAssertEqual(made, [
            top.path,
            top.appendingPathComponent("a").path,
            top.appendingPathComponent("a/b").path,
            state.path,
        ])
        let lastMkdir = try XCTUnwrap(log.effects.lastIndex { $0.operation == "mkdir" })
        let leaseAt = try XCTUnwrap(log.effects.firstIndex { $0.operation == "lease" })
        XCTAssertLessThan(lastMkdir, leaseAt)
    }

    /// A file where an ancestor belongs is refused, nothing beneath it is created, and the file keeps its bytes.
    func testANonDirectoryAncestorIsRefusedAndNothingBeneathItIsCreated() throws {
        let directory = try makeScratch()
        let file = directory.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        let state = file.appendingPathComponent("one/state", isDirectory: true)

        XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: state), createRootIfMissing: true)), .refused(.rootNotDirectory))
        XCTAssertEqual(try Data(contentsOf: file), Data("not a directory".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file"])
    }

    /// A dangling link as an ancestor is refused with the errno realpath gives, and nothing is created through it.
    func testADanglingAncestorLinkIsRefusedAndNothingIsCreatedThroughIt() throws {
        let directory = try makeScratch()
        let absent = directory.appendingPathComponent("absent", isDirectory: true)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: absent)
        let before = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let state = link.appendingPathComponent("state", isDirectory: true)

        XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: state), createRootIfMissing: true)), .refused(.rootUnavailable(errno: ENOENT)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path), "nothing was created through the dangling link")
    }

    /// A racing creator makes the root between the check and the mkdir. The recheck accepts the directory.
    func testRacedRootCreationIsAcceptedWhenTheRaceProducedADirectory() throws {
        let directory = try makeScratch(createDirectory: false)
        let fileSystem = RaceOnDirectoryCreation(racer: .directory, at: directory.path)
        let session = try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: directory), fileSystem: fileSystem, createRootIfMissing: true))
        XCTAssertTrue(fileSystem.didRace, "the race happened at the root")
        XCTAssertEqual(session.environment.configDirectory.lastPathComponent, directory.lastPathComponent)
        releaseScratchStateRoot(session)
    }

    /// A racing creator that makes a regular file where the root belongs is refused, not used.
    func testRacedRootCreationIsRefusedWhenTheRaceProducedAFile() throws {
        let directory = try makeScratch(createDirectory: false)
        let fileSystem = RaceOnDirectoryCreation(racer: .regularFile, at: directory.path)
        XCTAssertEqual(
            refusal(bootstrap(.isolated(stateDirectory: directory), fileSystem: fileSystem, createRootIfMissing: true)),
            .refused(.rootNotDirectory)
        )
        XCTAssertTrue(fileSystem.didRace, "the race happened at the root")
    }

    /// A racing creator on an ancestor is accepted when it makes a directory, and the nested root is then created beneath it.
    func testRacedAncestorCreationIsAcceptedWhenTheRaceProducedADirectory() throws {
        let directory = try makeScratch(createDirectory: false)
        let ancestor = directory.appendingPathComponent("one", isDirectory: true)
        let state = ancestor.appendingPathComponent("state", isDirectory: true)
        let fileSystem = RaceOnDirectoryCreation(racer: .directory, at: ancestor.path)
        let session = try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: state), fileSystem: fileSystem, createRootIfMissing: true))
        XCTAssertTrue(fileSystem.didRace, "the race happened at the ancestor")
        releaseScratchStateRoot(session)
        XCTAssertEqual(mode(state.path), 0o700)
    }

    /// A racing creator on an ancestor that makes a regular file is refused, and nothing beneath it is created.
    func testRacedAncestorCreationIsRefusedWhenTheRaceProducedAFile() throws {
        let directory = try makeScratch(createDirectory: false)
        let ancestor = directory.appendingPathComponent("one", isDirectory: true)
        let state = ancestor.appendingPathComponent("state", isDirectory: true)
        let fileSystem = RaceOnDirectoryCreation(racer: .regularFile, at: ancestor.path)

        XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: state), fileSystem: fileSystem, createRootIfMissing: true)), .refused(.rootNotDirectory))
        XCTAssertTrue(fileSystem.didRace, "the race happened at the ancestor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    // MARK: - Fixed slots, dangling (decision 0028)

    /// A dangling link at a fixed slot does not resolve. It is refused as an unresolved path, and the link and its missing
    /// target are left as they were.
    func testADanglingFixedSlotLinkIsRefusedAndItsTargetIsNotCreated() throws {
        let directory = try makeScratch()
        let absent = directory.appendingPathComponent("absent-config.json")
        let config = directory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: absent)
        let before = try FileManager.default.destinationOfSymbolicLink(atPath: config.path)

        XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: directory))), .refused(.pathUnavailable(.config, errno: ENOENT)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    // MARK: - Fixed slots (decision 0028)

    /// On a case-folding volume a case alias of the fixed leaf is the slot, and it resolves to the fixed spelling.
    func testFixedLeafCaseAliasResolvesToTheSlotOnACaseFoldingVolume() throws {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: false)
        fileSystem.addDirectory("/state")
        let environment = RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/state", isDirectory: true),
                                             configFile: URL(fileURLWithPath: "/state/CONFIG.json"))
        let plan = try StateRootLayout.resolve(environment, configAccess: .writerOwned, fileSystem: fileSystem)
        XCTAssertEqual(plan.config.path, "/state/config.json")
    }

    /// A case variant on a case-sensitive volume is a different name, so it is not the slot.
    func testFixedLeafCaseVariantIsRefusedOnACaseSensitiveVolume() {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: true)
        fileSystem.addDirectory("/state")
        let environment = RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/state", isDirectory: true),
                                             configFile: URL(fileURLWithPath: "/state/CONFIG.json"))
        XCTAssertThrowsError(try StateRootLayout.resolve(environment, configAccess: .writerOwned, fileSystem: fileSystem)) { error in
            XCTAssertEqual(error as? StateRootFailure, .unsupportedFileName(.config))
        }
    }

    /// `config.json` may link to a contained target with any name: the link is kept and the target is the authority.
    func testConfigSymbolicLinkToAContainedTargetWithAnyNameIsTheAuthority() throws {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: true)
        fileSystem.addDirectory("/state")
        fileSystem.addSymbolicLink("/state/config.json", to: "/state/custom-target.json")
        fileSystem.addFile("/state/custom-target.json")
        let plan = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/state", isDirectory: true)),
                                               configAccess: .writerOwned, fileSystem: fileSystem)
        XCTAssertEqual(plan.config.path, "/state/custom-target.json")
    }

    /// A configuration link whose target is a reserved runtime name is refused by the resource it names.
    func testConfigSymbolicLinkToAReservedResourceIsRefused() {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: true)
        fileSystem.addDirectory("/state")
        fileSystem.addSymbolicLink("/state/config.json", to: "/state/state-writer.lock")
        fileSystem.addFile("/state/state-writer.lock")
        XCTAssertThrowsError(try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/state", isDirectory: true)),
                                                         configAccess: .writerOwned, fileSystem: fileSystem)) { error in
            XCTAssertEqual(error as? StateRootFailure, .reservedName(.config, .writerLock))
        }
    }

    /// An arbitrary leaf is refused before it is read, and its bytes are left as they were.
    func testCustomConfigNameIsRefusedAndItsBytesArePreserved() throws {
        let directory = try makeScratch()
        let custom = directory.appendingPathComponent("custom.json")
        try Data("custom bytes".utf8).write(to: custom)
        let environment = RuntimeEnvironment(configDirectory: directory, configFile: custom)
        XCTAssertEqual(refusal(bootstrap(environment)), .refused(.unsupportedFileName(.config)))
        XCTAssertEqual(try Data(contentsOf: custom), Data("custom bytes".utf8))
    }

    /// A configuration outside the requested root is refused, and the outside file is not touched.
    func testSplitRootRefusesAnOutsideConfigurationBeforeAnyWrite() throws {
        let state = try makeScratch()
        let outside = try makeScratch()
        let config = outside.appendingPathComponent("config.json")
        try Data("outside".utf8).write(to: config)
        let environment = RuntimeEnvironment(configDirectory: state, configFile: config)
        XCTAssertEqual(refusal(bootstrap(environment)), .refused(.outsideRoot(.config)))
        XCTAssertEqual(try Data(contentsOf: config), Data("outside".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("platform.json").path))
    }

    // MARK: - Root identity and held authority

    /// A root directory replaced at the same path between the two identity checks is refused.
    func testRootReplacedAtTheSamePathDuringTheLayoutIsRefused() throws {
        let fileSystem = FakeStateRootFileSystem(caseSensitiveNames: true)
        fileSystem.addDirectory("/state")
        let replacing = ReplacingRootIdentity(fake: fileSystem, root: "/state")
        XCTAssertEqual(
            refusal(bootstrap(RuntimeEnvironment(configDirectory: URL(fileURLWithPath: "/state", isDirectory: true)),
                              leasing: FakeStateWriterLeasing(), fileSystem: replacing)),
            .refused(.rootChanged)
        )
    }

    /// The authority is the session's, not the owner's: dropping the owner keeps the root held until the session goes.
    func testHeldAuthorityEndsWithItsSessionAndNotBeforeTheOwnerDrops() throws {
        let directory = try makeScratch()
        final class Owner {
            let session: StateRootSession
            init(session: StateRootSession) { self.session = session }
        }
        var owner: Owner? = Owner(session: try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: directory))))
        weak var session: StateRootSession?
        session = owner?.session
        withExtendedLifetime(owner) {
            XCTAssertEqual(refusal(bootstrap(.isolated(stateDirectory: directory))), .busy, "the owner still holds the root")
        }
        owner = nil
        XCTAssertNil(session, "the owner held the session's only reference, so dropping it ended the session")
        let second = try XCTUnwrap(bootstrapSession(.isolated(stateDirectory: directory)), "the root is free once the session is gone")
        releaseScratchStateRoot(second)
    }
}

/// A file system whose creation of one path loses a race: the path is absent at the check, then the racer takes it
/// before the mkdir, so mkdir reports EEXIST. The racer makes a directory or a regular file. Every other path is
/// created for real. `didRace` says whether the named path was ever reached, so a test cannot pass by never racing.
private final class RaceOnDirectoryCreation: StateRootFileSystem, @unchecked Sendable {
    enum Racer { case directory, regularFile }
    private let racer: Racer
    private let racedPath: String
    private let real = OSStateRootFileSystem()
    private let lock = NSLock()
    private var raced = false

    init(racer: Racer, at racedPath: String) {
        self.racer = racer
        self.racedPath = racedPath
    }

    var didRace: Bool { lock.withLock { raced } }

    func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind {
        try real.entryKind(at: path)
    }

    func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity? {
        try real.identity(at: path)
    }

    func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String {
        try real.canonicalPath(of: path)
    }

    func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool? {
        try real.volumeSupportsCaseSensitiveNames(at: directory)
    }

    func createDirectory(at path: String) throws(StateRootFileSystemError) {
        if path != racedPath {
            try real.createDirectory(at: path)
            return
        }
        lock.withLock { raced = true }
        do {
            switch racer {
            case .directory:
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            case .regularFile:
                guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                    XCTFail("the racer could not create its file")
                    throw StateRootFileSystemError(errno: EIO)
                }
            }
        } catch {
            XCTFail("the racer could not take the path: \(error)")
        }
        throw StateRootFileSystemError(errno: EEXIST)
    }
}

/// A scripted file system whose root directory is replaced after its first identity read: the same path,
/// a new object, so its inode changes. The layout's own reads see the replacement from their second call.
private final class ReplacingRootIdentity: StateRootFileSystem, @unchecked Sendable {
    private let fake: FakeStateRootFileSystem
    private let root: String
    private let lock = NSLock()
    private var identityReads = 0

    init(fake: FakeStateRootFileSystem, root: String) {
        self.fake = fake
        self.root = root
    }

    func entryKind(at path: String) throws(StateRootFileSystemError) -> StateRootEntryKind {
        try fake.entryKind(at: path)
    }

    func identity(at path: String) throws(StateRootFileSystemError) -> StateRootFileIdentity? {
        let read = lock.withLock { () -> Int in
            guard path == root else { return 0 }
            identityReads += 1
            return identityReads
        }
        if read == 2 { fake.addDirectory(root) }
        return try fake.identity(at: path)
    }

    func canonicalPath(of path: String) throws(StateRootFileSystemError) -> String {
        try fake.canonicalPath(of: path)
    }

    func volumeSupportsCaseSensitiveNames(at directory: String) throws(StateRootFileSystemError) -> Bool? {
        try fake.volumeSupportsCaseSensitiveNames(at: directory)
    }

    func createDirectory(at path: String) throws(StateRootFileSystemError) {
        try fake.createDirectory(at: path)
    }
}

#if DEBUG
/// The dev composition is paired with its session before it creates or seeds anything (decision 0028). The two
/// scratch roots stand in for the installed app's directory, so no production file is touched.
@MainActor
final class RuntimeStartupDevPairingTests: XCTestCase {
    private var scratch: [URL] = []

    override func tearDown() async throws {
        removeScratch(scratch)
        scratch = []
        try await super.tearDown()
    }

    private func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-startup-dev-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session for one root, with options for another, refuses before any fake home, resolver or seed.
    func testASessionForAnotherRootRefusesBeforeAnyWrite() throws {
        let sessionRoot = try makeScratch()
        let optionsRoot = try makeScratch()
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: sessionRoot))
        defer { releaseScratchStateRoot(session) }

        XCTAssertThrowsError(try DevLaunch.composeAppState(
            DevLaunchOptions(stateDirectory: optionsRoot), stateSession: session, protectedDirectories: []
        ))
        for root in [sessionRoot, optionsRoot] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: DevLaunchOptions.fakeHome(in: root).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path),
                           "no seed is written under \(root.lastPathComponent)")
        }
        XCTAssertFalse(DevLaunch.isActive)
    }

    /// A session whose root is a protected directory is refused by the production check before anything is created.
    func testAProtectedSessionRootRefusesBeforeAnyWrite() throws {
        let protectedRoot = try makeScratch()
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: protectedRoot))
        defer { releaseScratchStateRoot(session) }

        XCTAssertThrowsError(try DevLaunch.composeAppState(
            DevLaunchOptions(stateDirectory: protectedRoot), stateSession: session, protectedDirectories: [protectedRoot]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevLaunchOptions.fakeHome(in: protectedRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protectedRoot.appendingPathComponent("config.json").path))
        XCTAssertFalse(DevLaunch.isActive)
    }

    /// A child alias that leaves the state directory is found by the existing inventory before any seed.
    func testAChildAliasOutsideTheRootIsFoundBeforeAnySeed() throws {
        let root = try makeScratch()
        let outside = try makeScratch()
        let outsideFile = outside.appendingPathComponent("events.ndjson")
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("events.ndjson"), withDestinationURL: outsideFile)
        let session = try acquireScratchStateRoot(.isolated(stateDirectory: root))
        defer { releaseScratchStateRoot(session) }

        XCTAssertThrowsError(try DevLaunch.composeAppState(
            DevLaunchOptions(stateDirectory: root), stateSession: session, protectedDirectories: []
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path),
                       "no seed is written past a child alias")
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside")
    }
}
#endif
