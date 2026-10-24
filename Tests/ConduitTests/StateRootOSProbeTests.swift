// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Probes of the real file system in owned scratch directories. They test the
/// assumptions the state-root design rests on, rather than assuming them:
/// Foundation's atomic write replaces the inode, a flock on a data file does not
/// survive that replacement, lstat does not follow links, realpath resolves an
/// alias to one root, and the owner-only mode is used only for a new root.
final class StateRootOSProbeTests: XCTestCase {
    func testAtomicWriteReplacesTheDataFileInode() throws {
        let directory = try StateRootScratch.make("probe-inode")
        defer { StateRootScratch.remove(directory) }
        let data = directory.appendingPathComponent("platform.json")
        try Data("one".utf8).write(to: data)
        let before = StateRootScratch.identity(data.path)

        try Data("two".utf8).write(to: data, options: .atomic)

        XCTAssertNotNil(before)
        XCTAssertNotEqual(StateRootScratch.identity(data.path), before)
    }

    /// Why the lock is on a stable lock file and not on the data file: a
    /// `flock` on the old data inode is not visible on the path after an atomic
    /// replacement, so a second process would see the root as free.
    func testLockOnADataFileDoesNotSurviveItsAtomicReplacement() throws {
        let directory = try StateRootScratch.make("probe-data-lock")
        defer { StateRootScratch.remove(directory) }
        let data = directory.appendingPathComponent("platform.json")
        try Data("one".utf8).write(to: data)

        let oldInode = open(data.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(oldInode, 0)
        XCTAssertEqual(flock(oldInode, LOCK_EX | LOCK_NB), 0)
        try Data("two".utf8).write(to: data, options: .atomic)

        let newInode = open(data.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(newInode, 0)
        XCTAssertEqual(flock(newInode, LOCK_EX | LOCK_NB), 0, "the path's new inode is unlocked")
        XCTAssertEqual(flock(newInode, LOCK_UN), 0)
        XCTAssertEqual(Darwin.close(newInode), 0)
        XCTAssertEqual(Darwin.close(oldInode), 0)
    }

    /// Foundation's atomic write through a link leaf. Either the link is replaced
    /// by a regular file, or the bytes land in the target. The invariant that
    /// the store depends on is that the path reads the new bytes afterward. The
    /// observed case is printed so the verification note records it.
    func testAtomicWriteThroughASymbolicLinkLeafPublishesTheNewBytes() throws {
        let directory = try StateRootScratch.make("probe-link")
        defer { StateRootScratch.remove(directory) }
        let target = directory.appendingPathComponent("real-prefs.json")
        let link = directory.appendingPathComponent("preferences.json")
        try Data("one".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try Data("two".utf8).write(to: link, options: .atomic)

        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        let linkSurvived = info.st_mode & S_IFMT == S_IFLNK
        print("probe: atomic write through a symbolic link leaf kept the link: \(linkSurvived)")
        XCTAssertEqual(try Data(contentsOf: link), Data("two".utf8))
    }

    func testLStatReportsASymbolicLinkWithoutFollowingIt() throws {
        let directory = try StateRootScratch.make("probe-lstat")
        defer { StateRootScratch.remove(directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(try OSStateRootFileSystem().entryKind(at: link.path), .symbolicLink)
        XCTAssertEqual(try OSStateRootFileSystem().canonicalPath(of: link.path),
                       try OSStateRootFileSystem().canonicalPath(of: target.path))
    }

    func testAliasOfTheRootResolvesToOneCanonicalRoot() throws {
        let directory = try StateRootScratch.make("probe-alias")
        defer { StateRootScratch.remove(directory) }
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        let real = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let viaAlias = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: alias), configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())
        let viaReal = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: real), configAccess: .writerOwned, fileSystem: OSStateRootFileSystem())

        XCTAssertEqual(viaAlias.root, viaReal.root)
        XCTAssertEqual(viaAlias.root.path, try OSStateRootFileSystem().canonicalPath(of: real.path))
    }

    /// A missing root is created owner-only, and an existing root's mode is
    /// left alone, even when the caller allows creation.
    func testOnlyANewRootIsCreatedOwnerOnlyAndAnExistingRootIsNotChanged() throws {
        let directory = try StateRootScratch.make("probe-mode")
        defer { StateRootScratch.remove(directory) }
        let created = directory.appendingPathComponent("created", isDirectory: true)
        let existing = directory.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(existing.path, 0o755), 0)

        _ = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: created), configAccess: .writerOwned,
                                        createRootIfMissing: true, fileSystem: OSStateRootFileSystem())
        _ = try StateRootLayout.resolve(RuntimeEnvironment(configDirectory: existing), configAccess: .writerOwned,
                                        createRootIfMissing: true, fileSystem: OSStateRootFileSystem())

        XCTAssertEqual(mode(created.path), 0o700)
        XCTAssertEqual(mode(existing.path), 0o755)
    }

    func testCanonicalPathOfAMissingPathIsENOENT() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-probe-missing-\(UUID().uuidString)").path

        XCTAssertThrowsError(try OSStateRootFileSystem().canonicalPath(of: missing)) { error in
            XCTAssertEqual(error as? StateRootFileSystemError, StateRootFileSystemError(errno: ENOENT))
        }
    }

    /// The volume query answers as the resource key does, read fresh. A nil answer
    /// is printed, not treated as either kind of volume.
    func testVolumeCaseQueryMatchesTheResourceKeyForAScratchDirectory() throws {
        let directory = try StateRootScratch.make("probe-case")
        defer { StateRootScratch.remove(directory) }

        let answer = try OSStateRootFileSystem().volumeSupportsCaseSensitiveNames(at: directory.path)
        let key = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        print("probe: scratch volume case-sensitive names: \(String(describing: answer))")
        XCTAssertEqual(answer, key)
    }

    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}
