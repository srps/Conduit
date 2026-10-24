// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Scratch state directories and file identities for the state-writer tests.
/// Every test removes its directory after the leases and children it started
/// are released or joined.
enum StateRootScratch {
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static func make(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch {
            XCTFail("scratch cleanup failed for \(url.path): \(error.localizedDescription)")
        }
    }

    static func canonicalRoot(_ directory: URL) throws -> CanonicalStateRoot {
        let plan = try StateRootLayout.resolve(
            RuntimeEnvironment(configDirectory: directory), configAccess: .writerOwned, fileSystem: OSStateRootFileSystem()
        )
        return plan.root
    }

    static func lockPath(_ root: CanonicalStateRoot) -> String {
        root.path + "/" + OSStateWriterLeasing.lockFileName
    }

    static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

final class StateWriterLeaseTests: XCTestCase {
    /// Any close the destructor could not confirm is a test failure.
    private static let failIfReported: @Sendable (StateWriterReleaseFailure) -> Void = { failure in
        XCTFail("destructor could not confirm a close: \(failure)")
    }

    private func lease(_ outcome: StateWriterAcquisition) -> StateWriterLease? {
        switch outcome {
        case .acquired(let lease): return lease
        case .busy:
            XCTFail("expected acquired, got busy")
            return nil
        case .failed(let failure):
            XCTFail("expected acquired, got \(failure)")
            return nil
        }
    }

    /// True only for a busy refusal. An unexpected lease is released here, so
    /// the test does not leave the root held.
    private func isBusy(_ outcome: StateWriterAcquisition) -> Bool {
        switch outcome {
        case .busy: return true
        case .acquired(let unexpected):
            _ = unexpected.release()
            return false
        case .failed: return false
        }
    }

    private func failure(_ outcome: StateWriterAcquisition) -> StateWriterFailure? {
        if case .failed(let failure) = outcome { return failure }
        return nil
    }

    func testSecondAcquisitionIsBusyWhileHeldAndTheRootIsAcquirableAfterRelease() throws {
        let directory = try StateRootScratch.make("busy")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let leasing = OSStateWriterLeasing()

        let first = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertTrue(isBusy(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(first.release(), .released)

        let second = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(second.release(), .released)
    }

    func testReleaseClosesOnceAndARepeatCallTouchesNothing() throws {
        let directory = try StateRootScratch.make("once")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let held = try XCTUnwrap(lease(OSStateWriterLeasing().acquire(root: root, onReleaseFailure: Self.failIfReported)))

        XCTAssertEqual(held.release(), .released)
        XCTAssertEqual(held.release(), .alreadyReleased)
        XCTAssertEqual(held.release(), .alreadyReleased)
    }

    /// The lock file is never unlinked or replaced, so its inode is the same
    /// before and after a release.
    func testLockFileIsNeverUnlinkedAndKeepsItsInode() throws {
        let directory = try StateRootScratch.make("inode")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let leasing = OSStateWriterLeasing()

        let first = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        let inode = try XCTUnwrap(StateRootScratch.identity(StateRootScratch.lockPath(root)))
        XCTAssertEqual(first.release(), .released)

        XCTAssertTrue(FileManager.default.fileExists(atPath: StateRootScratch.lockPath(root)))
        let second = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(StateRootScratch.identity(StateRootScratch.lockPath(root)), inode)
        XCTAssertEqual(second.release(), .released)
    }

    /// The lock is on a stable lock file, not on the data file, so replacing the
    /// data file atomically leaves the root busy.
    func testAtomicDataReplacementWhileHeldKeepsTheRootBusy() throws {
        let directory = try StateRootScratch.make("atomic")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let platform = directory.appendingPathComponent("platform.json")
        try Data("one".utf8).write(to: platform)
        let leasing = OSStateWriterLeasing()

        let held = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        let lockBefore = StateRootScratch.identity(StateRootScratch.lockPath(root))
        let dataBefore = StateRootScratch.identity(platform.path)
        try Data("two".utf8).write(to: platform, options: .atomic)

        XCTAssertNotEqual(StateRootScratch.identity(platform.path), dataBefore)
        XCTAssertEqual(StateRootScratch.identity(StateRootScratch.lockPath(root)), lockBefore)
        XCTAssertTrue(isBusy(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(held.release(), .released)
    }

    /// A lock path that is a symbolic link is refused with ELOOP, and the link's
    /// target is neither opened for locking nor changed.
    func testLockPathSymbolicLinkIsRefusedAndItsTargetIsUntouched() throws {
        let directory = try StateRootScratch.make("symlink")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let target = directory.appendingPathComponent("elsewhere-target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: StateRootScratch.lockPath(root), withDestinationPath: target.path
        )

        let outcome = OSStateWriterLeasing().acquire(root: root, onReleaseFailure: Self.failIfReported)

        XCTAssertEqual(failure(outcome), .lockOpenFailed(errno: ELOOP))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    /// A root removed after it was resolved fails the open. It is not recreated
    /// by the lease, which only ever creates the lock file.
    func testAcquisitionAgainstARootRemovedAfterResolutionFailsWithoutRecreatingIt() throws {
        let directory = try StateRootScratch.make("removed")
        let root = try StateRootScratch.canonicalRoot(directory)
        try FileManager.default.removeItem(at: directory)

        let outcome = OSStateWriterLeasing().acquire(root: root, onReleaseFailure: Self.failIfReported)

        XCTAssertEqual(failure(outcome), .lockOpenFailed(errno: ENOENT))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Dropping a held lease closes it, so the root is free again.
    func testDroppedLeaseClosesItsDescriptor() throws {
        let directory = try StateRootScratch.make("dropped")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let leasing = OSStateWriterLeasing()

        holdAndDrop(leasing, root)

        let next = try XCTUnwrap(lease(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(next.release(), .released)
    }

    private func holdAndDrop(_ leasing: OSStateWriterLeasing, _ root: CanonicalStateRoot) {
        guard case .acquired = leasing.acquire(root: root, onReleaseFailure: Self.failIfReported) else {
            XCTFail("expected acquired")
            return
        }
    }

    func testFakeRefusesWithTypedBusyAndCountsIt() throws {
        let fake = FakeStateWriterLeasing()
        let root = CanonicalStateRoot(canonicalPath: "/state")
        let held = try XCTUnwrap(lease(fake.acquire(root: root, onReleaseFailure: Self.failIfReported)))

        XCTAssertTrue(isBusy(fake.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(fake.acquireCount, 2)
        XCTAssertEqual(fake.busyCount, 1)
        XCTAssertTrue(fake.isHeld(root))
        XCTAssertEqual(held.release(), .released)
        XCTAssertFalse(fake.isHeld(root))
    }

    func testFakeInjectedAcquisitionFailureIsOneTypedRefusal() throws {
        let fake = FakeStateWriterLeasing()
        let root = CanonicalStateRoot(canonicalPath: "/state")
        fake.failNextAcquisition(.lockFailed(errno: ENOLCK))

        XCTAssertEqual(failure(fake.acquire(root: root, onReleaseFailure: Self.failIfReported)), .lockFailed(errno: ENOLCK))
        let next = try XCTUnwrap(lease(fake.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(next.release(), .released)
    }

    /// An explicit release that cannot be confirmed is returned to the caller,
    /// and the destructor does not report it again. A repeat returns the same
    /// unconfirmed outcome. It is not `alreadyReleased`, and close is not retried:
    /// the fake's one scripted failure is consumed, so a retry would return `.released`.
    func testExplicitReleaseFailureIsReturnedAndNotReportedAgain() {
        let fake = FakeStateWriterLeasing()
        let root = CanonicalStateRoot(canonicalPath: "/state")
        let sink = FailureSink()
        fake.failNextRelease(errno: EINTR)

        let outcomes = releaseTwice(fake, root, sink)

        XCTAssertEqual(outcomes.first, .releaseUnknown(errno: EINTR))
        XCTAssertEqual(outcomes.second, .releaseUnknown(errno: EINTR),
                       "a repeat of an unconfirmed close is the same unconfirmed outcome, never alreadyReleased")
        XCTAssertFalse(fake.isHeld(root))
        XCTAssertEqual(sink.recorded, [])
    }

    /// Returns after the lease is gone, so the destructor has already run.
    private func releaseTwice(
        _ fake: FakeStateWriterLeasing,
        _ root: CanonicalStateRoot,
        _ sink: FailureSink
    ) -> (first: StateWriterRelease?, second: StateWriterRelease?) {
        guard case .acquired(let held) = fake.acquire(root: root, onReleaseFailure: sink.record) else {
            XCTFail("expected acquired")
            return (nil, nil)
        }
        return (held.release(), held.release())
    }

    /// A destructor close that cannot be confirmed reaches the typed callback.
    func testDestructorCloseFailureIsReportedThroughTheCallback() {
        let fake = FakeStateWriterLeasing()
        let root = CanonicalStateRoot(canonicalPath: "/state")
        let sink = FailureSink()
        fake.failNextRelease(errno: EIO)

        holdAndDropFake(fake, root, sink)

        XCTAssertEqual(sink.recorded, [StateWriterReleaseFailure(root: root, errno: EIO)])
        XCTAssertFalse(fake.isHeld(root))
    }

    private func holdAndDropFake(_ fake: FakeStateWriterLeasing, _ root: CanonicalStateRoot, _ sink: FailureSink) {
        guard case .acquired = fake.acquire(root: root, onReleaseFailure: sink.record) else {
            XCTFail("expected acquired")
            return
        }
    }
}

/// Collects typed destructor failures from a `@Sendable` callback.
private final class FailureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [StateWriterReleaseFailure] = []

    var recorded: [StateWriterReleaseFailure] { lock.withLock { failures } }

    func record(_ failure: StateWriterReleaseFailure) {
        lock.withLock { failures.append(failure) }
    }
}
