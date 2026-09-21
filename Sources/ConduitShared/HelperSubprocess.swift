// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A child process the helper runs (`networksetup`, `ifconfig`), bounded in
/// time and in output.
///
/// The helper serves one connection at a time, and `HelperLineIO` bounds what
/// a peer may cost it on the socket. The operation in between was not bounded
/// at all: `waitUntilExit` on a `networksetup` that never returns held the
/// accept loop, and with it every later client, including the teardown that
/// restores the user's proxy settings at logout. The deadline here is the
/// same monotonic clock, shared by every child one command runs, so a command
/// of four writes gets one budget rather than four.
///
/// Everything happens on the calling thread. Both pipes are read while the
/// child runs, because a child that fills a pipe nobody reads never exits,
/// and past `maxOutputBytes` the bytes are dropped rather than left unread
/// for the same reason. A child that outlives the deadline gets `SIGTERM`,
/// then `SIGKILL`, and each wait for it to go is bounded too.
package enum HelperSubprocess {
    package struct Result: Equatable, Sendable {
        package var exitCode: Int32
        package var output: Data
        package var errorOutput: Data
        /// More than `maxOutputBytes` arrived on a stream, or a writer still
        /// held a pipe after the child was gone. What is here is a prefix.
        package var outputTruncated: Bool
    }

    package enum Failure: Error, Equatable, LocalizedError {
        /// `reaped` is false for a child that survived `SIGKILL` for the
        /// grace period, which only an uninterruptible wait explains.
        case deadlineExceeded(executable: String, reaped: Bool)

        package var errorDescription: String? {
            switch self {
            case .deadlineExceeded(let executable, true):
                return "\(executable) did not finish before the operation's deadline and was terminated"
            case .deadlineExceeded(let executable, false):
                return "\(executable) did not finish before the operation's deadline and could not be killed"
            }
        }
    }

    /// What one helper command may spend on its children, all of them
    /// together. A `networksetup` write answers in well under a second, and
    /// the longest command runs four.
    package static let operationMilliseconds = 20_000

    /// How long a child gets to honour `SIGTERM`, and then `SIGKILL`.
    package static let terminationGraceMilliseconds = 2_000

    /// How long the pipes get to reach end-of-stream once the child is gone.
    /// A grandchild inherits them, so the child's exit is not the last word.
    package static let drainGraceMilliseconds = 500

    package static let defaultMaxOutputBytes = 65_536

    /// The longest `run` can take past its deadline: both kill waits and the
    /// drain. `HelperTransactionBudget` builds the client's deadline from it.
    package static var overrunMilliseconds: Int {
        2 * terminationGraceMilliseconds + drainGraceMilliseconds
    }

    /// Throws what `Process.run()` throws when the child cannot be launched,
    /// and `Failure.deadlineExceeded` when it was still running at `deadline`
    /// (`HelperLineIO.deadline`).
    package static func run(
        _ executable: String,
        _ arguments: [String],
        deadline: UInt64,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) throws -> Result {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Installed before `run()`: a child that exits at once would beat a
        // handler assigned afterwards.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        var streams = [
            Stream(outputPipe.fileHandleForReading, limit: maxOutputBytes),
            Stream(errorPipe.fileHandleForReading, limit: maxOutputBytes),
        ]
        var hasExited = false
        var timedOut = false
        while !hasExited {
            let current = HelperLineIO.now()
            guard current < deadline else {
                timedOut = true
                break
            }
            let remaining = Int(min((deadline - current + 999_999) / 1_000_000, UInt64(Int32.max)))
            if streams.contains(where: \.isOpen) {
                read(&streams, waitMilliseconds: min(remaining, pollSliceMilliseconds))
                hasExited = exited.wait(timeout: .now()) == .success
            } else {
                // Both streams ended and the child has not: nothing to read,
                // so the exit is the only thing left to wait for.
                hasExited = exited.wait(timeout: .now() + .milliseconds(remaining)) == .success
            }
        }
        if timedOut {
            hasExited = kill(process, waitingOn: exited)
        }

        let drainDeadline = HelperLineIO.deadline(afterMilliseconds: drainGraceMilliseconds)
        while streams.contains(where: \.isOpen), HelperLineIO.now() < drainDeadline {
            read(&streams, waitMilliseconds: pollSliceMilliseconds)
        }
        let abandoned = streams.contains(where: \.isOpen)
        for index in streams.indices { streams[index].close() }

        if timedOut {
            throw Failure.deadlineExceeded(executable: executable, reaped: hasExited)
        }
        return Result(
            // Read only after the exit was seen: `terminationStatus` raises
            // on a process that is still running.
            exitCode: process.terminationStatus,
            output: streams[0].collected,
            errorOutput: streams[1].collected,
            outputTruncated: abandoned || streams.contains(where: \.truncated)
        )
    }

    // MARK: - Reading

    /// How long one `poll` waits before the loop looks at the clock and the
    /// child again.
    private static let pollSliceMilliseconds = 50

    /// One pipe's read end, owned here from launch to `close()`.
    private struct Stream {
        let handle: FileHandle
        let limit: Int
        var collected = Data()
        var truncated = false
        var isOpen = true

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = limit
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            // A descriptor that cannot be made nonblocking is not read at
            // all: a blocking read here is the unbounded wait this type
            // exists to remove.
            if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 {
                truncated = true
                isOpen = false
            }
        }

        mutating func close() {
            isOpen = false
            // A close that fails leaks one descriptor and changes nothing
            // about the result, which is already in `collected`.
            try? handle.close()
        }
    }

    private static func read(_ streams: inout [Stream], waitMilliseconds: Int) {
        let open = streams.indices.filter { streams[$0].isOpen }
        var descriptors = open.map { pollfd(fd: streams[$0].handle.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(waitMilliseconds))
        guard ready > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        for (slot, index) in open.enumerated() where descriptors[slot].revents != 0 {
            let count = Darwin.read(descriptors[slot].fd, &buffer, buffer.count)
            if count > 0 {
                let room = streams[index].limit - streams[index].collected.count
                streams[index].collected.append(contentsOf: buffer[..<min(count, room)])
                if count > room { streams[index].truncated = true }
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                // End of stream, or a read error, which for a pipe leaves
                // nothing further to collect either. The prefix is flagged.
                if count < 0 { streams[index].truncated = true }
                streams[index].isOpen = false
            }
        }
    }

    // MARK: - Termination

    /// `SIGTERM`, then `SIGKILL` for a child that ignores it. True once the
    /// child is gone. `isRunning` narrows the window in which the pid has
    /// been reaped and handed to another process; it cannot close it.
    private static func kill(_ process: Process, waitingOn exited: DispatchSemaphore) -> Bool {
        let grace = DispatchTimeInterval.milliseconds(terminationGraceMilliseconds)
        if process.isRunning {
            process.terminate()
        }
        if exited.wait(timeout: .now() + grace) == .success { return true }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        return exited.wait(timeout: .now() + grace) == .success
    }
}

/// What one helper transaction may take, as both ends count it.
package enum HelperTransactionBudget {
    /// The helper's bound on receiving an admitted peer's request, and on
    /// the peer accepting the reply.
    package static let requestMilliseconds = 5_000
    package static let replyMilliseconds = 5_000

    /// How long a client waits for one transaction, connect to reply: the
    /// helper's own worst case and a little over. The relay start is the one
    /// command that goes on after a child ran out of time, to undo its alias,
    /// so the overrun is counted twice. Past this the helper is not slow, it
    /// is held, and the client reports it unreachable rather than wait on.
    ///
    /// It is one transaction's worth, with no allowance for waiting in the
    /// helper's backlog behind another. `HelperToolPrivilegeClient` sends one
    /// request at a time per process so that its own never wait there.
    package static var clientMilliseconds: Int {
        requestMilliseconds
            + HelperSubprocess.operationMilliseconds
            + 2 * HelperSubprocess.overrunMilliseconds
            + replyMilliseconds
            + 1_000
    }
}
