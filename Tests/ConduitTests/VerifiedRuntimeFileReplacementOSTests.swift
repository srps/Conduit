// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// A scratch directory with the real lease on its canonical root. `close` is the only way the directory is removed, and it
/// removes the directory only after the lease release is confirmed. An unconfirmed release keeps the directory on disk, because
/// its lock may still be held, and fails the test. Nothing else in these tests removes a leased root.
private final class LeasedScratch {
    private struct LeaseUnavailable: Error {}

    let directory: URL
    let root: CanonicalStateRoot
    let lease: StateWriterLease

    private init(directory: URL, root: CanonicalStateRoot, lease: StateWriterLease) {
        self.directory = directory
        self.root = root
        self.lease = lease
    }

    /// Creates a fresh directory and takes its lease. A directory whose lease was not taken is kept, because another holder
    /// could own it.
    static func open(_ label: String) throws -> LeasedScratch {
        let directory = try StateRootScratch.make(label)
        // No acquisition was attempted, so this fresh directory is ordinary scratch and is removed on failure.
        let root: CanonicalStateRoot
        do {
            root = try StateRootScratch.canonicalRoot(directory)
        } catch {
            StateRootScratch.remove(directory)
            throw error
        }
        let outcome = OSStateWriterLeasing().acquire(root: root, onReleaseFailure: { failure in
            XCTFail("the destructor could not confirm a close: \(failure)")
        })
        guard case .acquired(let lease) = outcome else {
            XCTFail("the scratch root was not acquired, so its directory is kept: \(outcome)")
            throw LeaseUnavailable()
        }
        return LeasedScratch(directory: directory, root: root, lease: lease)
    }

    /// Releases the lease, then removes the directory only when the release is confirmed.
    func close() {
        switch lease.release() {
        case .released, .alreadyReleased:
            StateRootScratch.remove(directory)
        case .releaseUnknown(let errno):
            XCTFail("the writer lease close was not confirmed (errno \(errno)), so the scratch directory was kept")
        }
    }
}

/// The verified replacement over the real OS adapter, in scratch directories (decisions 0017, 0020 and 0021). Each test takes the
/// real lease on the canonical root and releases it before the scratch directory is removed, so a held lock or root is never
/// deleted. These tests show the adapter's read and write behaviour. They do not reproduce a power loss, an external editor or
/// a fault that lands before the call reports it.
final class VerifiedRuntimeFileReplacementOSTests: XCTestCase {
    private static let staged = Data("staged-config".utf8)
    private static let smallPrior = Data("old".utf8)
    private static let largerPrior = Data(repeating: 0x4C, count: 64)

    private func target(_ root: CanonicalStateRoot, _ name: String = "config.json") -> StateRootFile {
        StateRootFile(role: .config, path: root.path + "/" + name)
    }

    /// The baseline is the file as it is now, observed through the reader the replacement's pre-read uses. A file that cannot be
    /// observed keeps a sentinel that the pre-read never reaches, because the pre-read reports the same failure first.
    private func replace(_ bytes: Data, _ file: StateRootFile, _ lease: StateWriterLease) -> ConfigurationFileReplacementOutcome {
        let access = StateFileAccess.operatingSystem()
        let baseline: ConfigurationFileBaseline
        switch VerifiedConfigurationFileReplacement.observe(file, access: access) {
        case .observed(let input): baseline = ConfigurationFileBaseline(observing: input)
        case .refused, .notObserved: baseline = ConfigurationFileBaseline(observing: .present(Data()))
        }
        return VerifiedConfigurationFileReplacement.replace(bytes, at: file, under: lease, access: access, expecting: baseline)
    }

    private func contents(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func testMissingRuntimeFileIsCreatedAndReadBack() throws {
        let scratch = try LeasedScratch.open("replace-create")
        defer { scratch.close() }
        let file = target(scratch.root)

        XCTAssertEqual(replace(Self.staged, file, scratch.lease), .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try contents(file.path), Self.staged)
    }

    func testAnExistingPriorIsReplacedWhetherLargerOrSmallerThanTheStagedBytes() throws {
        let scratch = try LeasedScratch.open("replace-overwrite")
        defer { scratch.close() }
        let file = target(scratch.root)

        try Self.largerPrior.write(to: URL(fileURLWithPath: file.path))
        XCTAssertEqual(replace(Self.staged, file, scratch.lease), .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try contents(file.path), Self.staged)

        try Self.smallPrior.write(to: URL(fileURLWithPath: file.path))
        XCTAssertEqual(replace(Self.staged, file, scratch.lease), .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try contents(file.path), Self.staged)
    }

    /// The layout resolves a symbolic link to its target, and the write lands on that target. The link itself is kept.
    func testASymbolicLinkConfigIsWrittenAtItsResolvedTargetAndTheLinkIsKept() throws {
        let scratch = try LeasedScratch.open("replace-link")
        defer { scratch.close() }

        let realTarget = scratch.directory.appendingPathComponent("real-config.json")
        try Self.smallPrior.write(to: realTarget)
        let link = scratch.directory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realTarget)

        let plan = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: scratch.directory, configFile: link),
            configAccess: .writerOwned,
            fileSystem: OSStateRootFileSystem()
        )
        XCTAssertEqual(plan.config.path, scratch.root.path + "/real-config.json")
        XCTAssertEqual(replace(Self.staged, plan.config, scratch.lease), .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try contents(realTarget.path), Self.staged)
        XCTAssertEqual(try OSStateRootFileSystem().entryKind(at: link.path), .symbolicLink)
    }

    /// A foreign root and a wrong role are refused before any write. The foreign directory is never leased or written to, so it
    /// is removed here, and it is not the leased root.
    func testAForeignRootAndAWrongRoleAreRefusedBeforeAnyWrite() throws {
        let scratch = try LeasedScratch.open("replace-refuse")
        defer { scratch.close() }

        let elsewhere = try StateRootScratch.make("replace-elsewhere")
        defer { StateRootScratch.remove(elsewhere) }
        let foreignRoot = try StateRootScratch.canonicalRoot(elsewhere)
        let foreign = StateRootFile(role: .config, path: foreignRoot.path + "/config.json")
        XCTAssertEqual(replace(Self.staged, foreign, scratch.lease), .refused(.outsideLeasedRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path))

        let platform = scratch.root.path + "/platform.json"
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: platform))
        // The platform and preferences sidecars are configuration roles now, so the journal is the foreign role.
        let wrongRole = StateRootFile(role: .journal, path: platform)
        XCTAssertEqual(replace(Self.staged, wrongRole, scratch.lease), .refused(.wrongRole(.journal)))
        XCTAssertEqual(try contents(platform), Data("untouched".utf8))
    }

    /// A directory at the config path is not a regular file. The pre-read refuses it, and nothing is written over it.
    func testANonregularPriorIsNotStartedAndStaysAsItWas() throws {
        let scratch = try LeasedScratch.open("replace-nonregular")
        defer { scratch.close() }
        let file = target(scratch.root)
        try FileManager.default.createDirectory(atPath: file.path, withIntermediateDirectories: false)

        XCTAssertEqual(replace(Self.staged, file, scratch.lease), .notStarted(.unreadable(.notRegularFile, closeErrno: nil)))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// A read-only directory refuses the atomic write's temporary file. The 64-byte prior is larger than the 13 staged bytes, so
    /// the read-back is bounded by the prior's length and reads it back in full: the result is not persisted, and the prior is
    /// unchanged. Root bypasses directory permissions, so the test is skipped there rather than made to pass.
    func testAWriteRefusedByAReadOnlyDirectoryIsNotPersistedAndKeepsALargerPrior() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses directory permissions, so the write cannot be refused")
        let scratch = try LeasedScratch.open("replace-readonly")
        // Declared after `scratch`, so the mode is restored before `scratch.close()` runs. A failed restore is reported here, and
        // the removal that follows reports its own failure if the read-only mode blocks it. The lease is released either way.
        defer { scratch.close() }
        defer {
            if chmod(scratch.root.path, 0o700) != 0 {
                let code = errno
                XCTFail("restoring the scratch directory mode failed, errno \(code)")
            }
        }
        let file = target(scratch.root)
        try Self.largerPrior.write(to: URL(fileURLWithPath: file.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.root.path)
        let outcome = replace(Self.staged, file, scratch.lease)
        guard case .verifiedNotPersisted = outcome else {
            XCTFail("expected verifiedNotPersisted, got \(outcome)")
            return
        }
        XCTAssertEqual(try contents(file.path), Self.largerPrior)
    }

    /// The approved budget is written whole, and one byte over it is refused before any I/O.
    func testStagedBytesAtTheBudgetAreWrittenAndOneOverItAreRefused() throws {
        let scratch = try LeasedScratch.open("replace-budget")
        defer { scratch.close() }
        let file = target(scratch.root)
        let limit = ConfigurationFileReader.maximumBytes

        XCTAssertEqual(replace(Data(count: limit + 1), file, scratch.lease), .refused(.stagedTooLarge(limit: limit)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        XCTAssertEqual(replace(Data(count: limit), file, scratch.lease), .verifiedPersisted(writeError: nil))
        XCTAssertEqual(try contents(file.path).count, limit)
    }
}
