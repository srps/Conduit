// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Cross-process claims for the state-writer lease. The Swift adapter holds the
/// lease in the test process. Each child is a `python3 -I` process started with
/// argv only. It calls `flock(2)` directly on the lock file, so these tests show
/// that the kernel lock the adapter takes is visible to, and respected by,
/// another process. They do not run a second Swift adapter in another process.
///
/// Children are started with `posix_spawn`, not `Foundation.Process`: the
/// inheritance tests need the spawn to pass non-close-on-exec descriptors
/// through, and `Process` does not (the control test below measures that).
///
/// Every child is started and joined inside its test. Waits are bounded and
/// synchronized on printed protocol lines, not sleeps.
final class StateWriterLeaseProcessTests: XCTestCase {
    private static let failIfReported: @Sendable (StateWriterReleaseFailure) -> Void = { failure in
        XCTFail("destructor could not confirm a close: \(failure)")
    }

    func testContendingProcessIsBusyWhileTheLeaseIsHeldAndAcquiresAfterRelease() throws {
        let directory = try StateRootScratch.make("contender")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let lockPath = StateRootScratch.lockPath(root)
        let leasing = OSStateWriterLeasing()

        let held = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        let whileHeld = try OwnedLockChild(mode: "probe", lockPath: lockPath)
        XCTAssertEqual(whileHeld.readLine(), "busy")
        XCTAssertEqual(whileHeld.join(), 0)
        XCTAssertEqual(held.release(), .released)

        let afterRelease = try OwnedLockChild(mode: "probe", lockPath: lockPath)
        XCTAssertEqual(afterRelease.readLine(), "acquired")
        XCTAssertEqual(afterRelease.join(), 0)

        let again = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(again.release(), .released)
    }

    /// The holder exits without unlocking. The kernel releases the lock with the
    /// process, so the root is acquirable afterward.
    func testProcessExitReleasesTheLockWithoutAnExplicitUnlock() throws {
        let directory = try StateRootScratch.make("exit")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let lockPath = StateRootScratch.lockPath(root)
        let leasing = OSStateWriterLeasing()

        // The adapter creates the lock file; release it so the holder can take it.
        let seed = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(seed.release(), .released)

        let holder = try OwnedLockChild(mode: "hold", lockPath: lockPath)
        XCTAssertEqual(holder.readLine(), "held")
        XCTAssertTrue(refusedAsBusy(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))

        try holder.closeInput()
        XCTAssertEqual(holder.join(), 0)

        let after = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(after.release(), .released)
    }

    /// Control for the test below: a plain, inheritable descriptor on the lock
    /// file is visible to a spawned child. Without this, "inherited 0" could
    /// mean the spawn never passes descriptors at all.
    func testInheritableDescriptorIsVisibleToASpawnedChild() throws {
        let directory = try StateRootScratch.make("control")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let lockPath = StateRootScratch.lockPath(root)
        let leasing = OSStateWriterLeasing()
        let seed = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(seed.release(), .released)

        let plain = open(lockPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(plain, 0)
        defer { XCTAssertEqual(Darwin.close(plain), 0) }
        let child = try OwnedLockChild(mode: "inherit", lockPath: lockPath)
        XCTAssertEqual(child.readLine(), "inherited 1")
        try child.closeInput()
        XCTAssertEqual(child.join(), 0)
    }

    /// The lease's descriptor is close-on-exec. A child spawned while the lease
    /// is held does not hold the lock, so an explicit release is followed by an
    /// immediate acquisition while that child is still alive. Release is a plain
    /// close, with no LOCK_UN, so this result is not masked by an unlock.
    func testCloseOnExecLeaseDescriptorIsNotVisibleToASpawnedChild() throws {
        let directory = try StateRootScratch.make("cloexec")
        defer { StateRootScratch.remove(directory) }
        let root = try StateRootScratch.canonicalRoot(directory)
        let lockPath = StateRootScratch.lockPath(root)
        let leasing = OSStateWriterLeasing()

        let held = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        let child = try OwnedLockChild(mode: "inherit", lockPath: lockPath)
        XCTAssertEqual(child.readLine(), "inherited 0")

        XCTAssertEqual(held.release(), .released)
        let next = try XCTUnwrap(acquired(leasing.acquire(root: root, onReleaseFailure: Self.failIfReported)))
        XCTAssertEqual(next.release(), .released)

        try child.closeInput()
        XCTAssertEqual(child.join(), 0)
    }

    private func acquired(_ outcome: StateWriterAcquisition) -> StateWriterLease? {
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

    private func refusedAsBusy(_ outcome: StateWriterAcquisition) -> Bool {
        switch outcome {
        case .busy: return true
        case .acquired(let unexpected):
            _ = unexpected.release()
            return false
        case .failed: return false
        }
    }
}

private enum OwnedLockChildError: Error {
    case pipe(errno: Int32)
    case spawn(errno: Int32)
}

/// A `python3 -I` child for one protocol mode, joined by the test that started
/// it. Its output is line-based, and each wait is bounded.
private final class OwnedLockChild {
    /// Modes: `probe` tries the lock once and exits; `hold` keeps the lock until
    /// stdin closes, then exits without unlocking; `inherit` counts the
    /// descriptors that refer to the lock file, then waits for stdin to close.
    private static let script = """
    import fcntl, os, sys
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "probe":
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("acquired", flush=True)
        except BlockingIOError:
            print("busy", flush=True)
    elif mode == "hold":
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("busy", flush=True)
            sys.exit(0)
        print("held", flush=True)
        sys.stdin.read()
        os._exit(0)
    elif mode == "inherit":
        lock = os.stat(path)
        count = 0
        for name in os.listdir("/dev/fd"):
            if not name.isdigit() or int(name) <= 2:
                continue
            try:
                current = os.fstat(int(name))
            except OSError:
                continue
            if (current.st_dev, current.st_ino) == (lock.st_dev, lock.st_ino):
                count += 1
        print("inherited", count, flush=True)
        sys.stdin.read()
    """

    private let pid: pid_t
    private var stdinWrite: Int32
    private var stdoutRead: Int32
    private var buffered = Data()
    private let reaped = ChildExit()

    init(mode: String, lockPath: String) throws {
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw OwnedLockChildError.pipe(errno: errno) }
        guard pipe(&fromChild) == 0 else {
            let code = errno
            _ = Darwin.close(toChild[0])
            _ = Darwin.close(toChild[1])
            throw OwnedLockChildError.pipe(errno: code)
        }
        // Parent ends are close-on-exec, so the child never holds them and sees
        // EOF on stdin when the parent closes its end. The child ends reach the
        // child as stdin and stdout through dup2 actions, which clear the flag.
        for descriptor in toChild + fromChild {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        let devNull = open("/dev/null", O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(devNull, 0)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_adddup2(&actions, devNull, 2)

        let arguments = ["/usr/bin/env", "python3", "-I", "-c", Self.script, mode, lockPath]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for case let pointer? in argv { free(pointer) } }

        var childPid: pid_t = 0
        let result = posix_spawn(&childPid, "/usr/bin/env", &actions, nil, argv, environ)
        _ = Darwin.close(devNull)
        _ = Darwin.close(toChild[0])
        _ = Darwin.close(fromChild[1])
        guard result == 0 else {
            _ = Darwin.close(toChild[1])
            _ = Darwin.close(fromChild[0])
            throw OwnedLockChildError.spawn(errno: result)
        }
        pid = childPid
        stdinWrite = toChild[1]
        stdoutRead = fromChild[0]

        // Reaping happens on a background thread, so a blocked waitpid can never
        // stall the test thread. Join waits on the reaped box, with a bound.
        let reaper = reaped
        let processID = childPid
        DispatchQueue.global().async {
            var status: Int32 = 0
            _ = waitpid(processID, &status, 0)
            reaper.finish(status & 0x7f == 0 ? (status >> 8) & 0xff : -1)
        }
    }

    deinit {
        // A test that fails before joining must not leave a child running.
        if reaped.value == nil { _ = kill(pid, SIGKILL) }
        if stdinWrite >= 0, Darwin.close(stdinWrite) != 0 {
            XCTFail("closing a child's stdin failed: errno \(errno)")
        }
        if stdoutRead >= 0, Darwin.close(stdoutRead) != 0 {
            XCTFail("closing a child's stdout failed: errno \(errno)")
        }
    }

    /// The child's next line, or nil at the deadline or when its output closes.
    func readLine(timeout: TimeInterval = 10) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = String(decoding: buffered[..<newline], as: UTF8.self)
                buffered.removeSubrange(buffered.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, buffered.count < 4096 else { return nil }
            var watched = pollfd(fd: stdoutRead, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, Int32(remaining * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 512)
            let count = read(stdoutRead, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffered.append(contentsOf: chunk[0..<count])
        }
    }

    /// Closes the child's stdin: the signal for `hold` and `inherit` to finish.
    func closeInput() throws {
        guard stdinWrite >= 0 else { return }
        let descriptor = stdinWrite
        stdinWrite = -1
        guard Darwin.close(descriptor) == 0 else {
            throw OwnedLockChildError.pipe(errno: errno)
        }
    }

    /// Waits for exit, bounded. A child still running at the deadline is killed
    /// and reported as nil, so the test fails rather than hangs.
    func join(timeout: TimeInterval = 10) -> Int32? {
        if let code = reaped.value { return code }
        if reaped.wait(timeout: timeout) { return reaped.value }
        _ = kill(pid, SIGKILL)
        _ = reaped.wait(timeout: 5)
        return nil
    }
}

/// The exit status of one child, written by its background reaper.
private final class ChildExit: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var code: Int32?

    var value: Int32? { lock.withLock { code } }

    func finish(_ status: Int32) {
        lock.withLock { code = status }
        done.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }
}
