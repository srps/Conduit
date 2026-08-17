// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import ProxyKernel

package struct CommandResult: Sendable {
    package let exitCode: Int32
    package let standardOutput: String
    package let standardError: String
}

package enum CommandRunnerError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)
    case outputTooLarge(command: String, limitBytes: Int)
    case outputIncomplete(command: String, reason: String)

    package var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            return "\(command) did not finish within \(Int(seconds))s and was terminated."
        case .outputTooLarge(let command, let limitBytes):
            return "\(command) produced more than \(limitBytes) bytes of output."
        case .outputIncomplete(let command, let reason):
            return "\(command) produced output that could not be read in full (\(reason)); "
                 + "what was read is a prefix, not the whole stream."
        }
    }
}

package enum CommandRunner {
    /// Default per-stream ceiling on what a child may write before we call the
    /// output runaway. Exceeding it fails the call rather than truncating: a
    /// silently shortened result is one a caller would act on as if complete.
    ///
    /// 1 MiB is enormous for what this default covers. Every caller on it —
    /// `networksetup`, `scutil`, `launchctl`, `ifconfig` — answers in a line or
    /// two, so the number is a runaway guard rather than a working limit.
    ///
    /// It is deliberately a *default* and not the only value. A caller reading a
    /// whole document has a different question to answer, and the honest place to
    /// answer it is that call site: see `AppState.curlPACFetcher`. An earlier
    /// version of this comment justified the number by matching the helper
    /// socket's frame cap, which explained nothing — a protocol frame and a
    /// document are not the same kind of thing.
    package static let defaultMaxOutputBytes = 1_048_576

    /// Wall-clock ceiling for an ordinary child. Everything on this path
    /// (`networksetup`, `scutil`, `launchctl`, `curl --max-time 15`) answers in
    /// well under a second.
    package static let defaultTimeout: TimeInterval = 30

    /// Ceiling for a child that is blocked on a human. `osascript`'s
    /// `with administrator privileges` dialog waits for a password, so the
    /// ordinary bound would cancel the prompt while the user is still typing.
    /// This one exists only so a wedged `osascript` cannot outlive the app.
    package static let privilegedTimeout: TimeInterval = 600

    /// How long a child gets to honour `SIGTERM` before it is killed.
    private static let terminationGrace: TimeInterval = 2

    /// How long the pipes get to reach EOF once the child is gone.
    ///
    /// Not zero, because the child's exit is not the last word on its pipes: a
    /// grandchild inherits them, so `sh -c 'sleep 30 &'` — or `osascript`
    /// running a script that backgrounds something — leaves a writer alive
    /// after the process we waited on has died. Joining unconditionally would
    /// then hang on exactly the path meant to break a hang.
    ///
    /// Note what this means for such a command: it now fails with
    /// `outputIncomplete` after the grace rather than returning the exit code
    /// and the output collected so far. That is deliberate — a prefix presented
    /// as the whole stream is the failure mode this file exists to prevent — but
    /// it makes `&` in anything run through here a behavioural change, not just
    /// a style choice. No current caller backgrounds a writer on our pipes:
    /// `networksetup`, `scutil` and `curl` do not, and `osascript` collects its
    /// inner script's output itself.
    private static let drainJoinGrace: TimeInterval = 5

    private static let drainQueue = DispatchQueue(
        label: "io.github.srps.Conduit.command-runner",
        qos: .utility,
        attributes: .concurrent
    )

    @discardableResult
    package static func run(
        launchPath: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = defaultTimeout,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Installed before `run()`: a child that exits immediately would beat a
        // handler assigned afterwards, and the signal would be lost.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Drain *concurrently with* the wait, never after it. A child that
        // writes more than the pipe buffer (64 KiB on Darwin) blocks in
        // `write` until someone reads; waiting for exit first guarantees
        // nobody ever does, and both sides hang with no timeout to break it.
        let outputDrain = StreamDrain(stdout.fileHandleForReading, limit: maxOutputBytes, on: drainQueue)
        let errorDrain = StreamDrain(stderr.fileHandleForReading, limit: maxOutputBytes, on: drainQueue)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process, waitingOn: exited)
            timedOut = true
        }

        // One deadline shared by both joins, not one each: the streams are read
        // concurrently, so a pipe still held open should cost the grace period
        // once rather than twice.
        //
        // A consequence worth naming: if the first join burns the whole grace,
        // the second starts already expired, so a stderr drain still mid-read is
        // cancelled at once. That is the right outcome rather than a hazard — by
        // then `output.failure` is set and the call throws regardless, so the
        // only thing the extra wait could buy is a prefix nobody will read. A
        // drain that already reached EOF is unaffected: its semaphore is
        // signalled, and `wait` succeeds on an expired deadline in that case.
        let joinDeadline = DispatchTime.now() + drainJoinGrace
        let output = outputDrain.join(deadline: joinDeadline)
        let error = errorDrain.join(deadline: joinDeadline)

        if timedOut {
            throw CommandRunnerError.timedOut(command: launchPath, seconds: timeout)
        }
        guard !output.overflowed, !error.overflowed else {
            throw CommandRunnerError.outputTooLarge(command: launchPath, limitBytes: maxOutputBytes)
        }
        // Reported, not swallowed: the alternative is handing back a prefix of
        // the output as if it were all of it, and every caller here branches on
        // what the command said.
        if let failure = output.failure ?? error.failure {
            throw CommandRunnerError.outputIncomplete(command: launchPath, reason: failure)
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    package static func runPrivilegedShellScript(_ script: String) throws -> CommandResult {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-\(UUID().uuidString).sh")
        try script.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let appleScript = "do shell script \"/bin/sh " + tempFile.path.shellQuoted + "\" with administrator privileges"
        return try run(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: privilegedTimeout
        )
    }

    // MARK: - Draining

    private struct DrainedStream {
        var text: String
        var overflowed: Bool
        /// Nil when the read reached a clean EOF. Set means `text` is a prefix,
        /// and says why it stopped short.
        var failure: String?
    }

    /// One pipe's background read.
    ///
    /// Cancellable, which is the only reason this is not a
    /// `readDataToEndOfFile` on a queue. When a join gives up — a grandchild
    /// holding the pipe behind a child that has already exited — an abandoned
    /// *blocking* read would hold its thread, its buffer and its descriptor for
    /// as long as that writer lives. Repeat that path and the drain queue fills
    /// with parked workers, after which nothing can drain at all and the
    /// deadlock this file exists to prevent returns by another door. So the
    /// read polls in slices and can be told to stop, and cancelling closes the
    /// descriptor *from the thread that owns it* rather than from underneath a
    /// blocked reader — closing it under one invites that number being reissued
    /// by the next `open`, pointing the abandoned read at an unrelated file.
    ///
    /// Past its limit the read keeps going and stops accumulating.
    /// Stopping early would leave the child blocked in `write`, which is the
    /// original bug moved into teardown; a child that never stops writing is
    /// bounded by the caller's timeout instead.
    private final class StreamDrain: @unchecked Sendable {
        /// How long a `poll` waits before the loop looks at `cancelled` again.
        /// The upper bound on how long a cancel takes to be honoured.
        private static let pollSliceMilliseconds: Int32 = 100

        /// How long a cancel gets to be honoured. Comfortably more than one poll
        /// slice, so it only expires when the read block never started at all.
        private static let cancelGrace: TimeInterval = 2

        private let handle: FileHandle
        private let limit: Int
        private let lock = NSLock()
        private var collected = Data()
        private var overflowed = false
        private var failure: String?
        private var cancelled = false
        /// Set only by the read loop, when `read` returns 0. The one piece of
        /// evidence that the stream really ended rather than being given up on.
        private var reachedEOF = false
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle, limit: Int, on queue: DispatchQueue) {
            self.handle = handle
            self.limit = limit
            queue.async { [self] in
                readUntilDone()
                finished.signal()
            }
        }

        /// Waits for EOF, then reports. If the deadline passes first the read is
        /// cancelled and this returns only once it has actually stopped, so no
        /// descriptor or worker outlives the call.
        func join(deadline: DispatchTime) -> DrainedStream {
            if finished.wait(timeout: deadline) == .timedOut {
                lock.withLock { cancelled = true }
                // Bounded, where a bare `wait()` would not be. The loop notices
                // `cancelled` within one poll slice *once its block is running*,
                // and nothing here can guarantee the block was ever scheduled —
                // it sits on a queue backed by a shared pool. An unbounded wait
                // would hang in that case, which is the failure this whole file
                // exists to remove. Giving up costs one leaked drain instead; a
                // rare leak beats a certain hang, and #69 tracks moving the
                // drains off the shared pool so neither outcome is possible.
                _ = finished.wait(timeout: .now() + Self.cancelGrace)
            }
            return lock.withLock {
                // Judged from what the loop actually did, and only once it has
                // stopped. Recording the failure at the moment the deadline fires
                // would call a stream truncated when the read in fact finished in
                // the instant between the two — and would turn any later increase
                // in poll-slice latency, or a large pipe that needs longer than
                // the grace to flush after the child exits, into a hard failure
                // on a complete read.
                if failure == nil, !reachedEOF {
                    failure = "a writer still held the pipe open after the child exited"
                }
                return DrainedStream(
                    text: String(decoding: collected, as: UTF8.self),
                    overflowed: overflowed,
                    failure: failure
                )
            }
        }

        private func readUntilDone() {
            // Closed on every exit, not only the cancel path. `Pipe` going out of
            // scope in `run` would close it anyway, but an implicit lifetime is
            // the opposite of what this class argues for — and closing here is
            // safe on all paths because the loop is the only thing that touches
            // the handle once it owns it.
            defer { try? handle.close() }

            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                lock.withLock { failure = "could not set the output pipe non-blocking" }
                return
            }

            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !lock.withLock({ cancelled }) {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    record(errno: errno, while: "polling")
                    return
                }
                // Nothing yet: fall back to the top so a cancel is noticed.
                if ready == 0 { continue }

                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count == 0 {
                    // EOF: every writer has closed.
                    lock.withLock { reachedEOF = true }
                    return
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    record(errno: errno, while: "reading")
                    return
                }
                append(buffer, count: count)
            }
        }

        private func append(_ buffer: [UInt8], count: Int) {
            lock.withLock {
                guard collected.count + count <= limit else {
                    overflowed = true
                    return
                }
                collected.append(contentsOf: buffer[0..<count])
            }
        }

        /// A read that fails is not a read that ended. Reporting it as EOF would
        /// hand back a prefix as though it were the whole stream, which is the
        /// silent truncation the rest of this file exists to prevent.
        /// `strerror_r` rather than `strerror`: both drains share one concurrent
        /// queue, so this is reachable from two threads at once, and POSIX does
        /// not require `strerror` to be thread-safe. Darwin returns constants for
        /// known codes but falls back to a shared static buffer for unknown ones.
        private func record(errno code: Int32, while verb: String) {
            var buffer = [CChar](repeating: 0, count: 256)
            let message = strerror_r(code, &buffer, buffer.count) == 0
                ? String(cString: buffer)
                : "errno \(code)"
            lock.withLock { failure = "\(verb) the output pipe failed: \(message)" }
        }
    }

    /// `SIGTERM`, then `SIGKILL` for a child that ignores it.
    ///
    /// Both signals are guarded by `isRunning`, which narrows — it cannot close
    /// — the window in which Foundation has already reaped the child and the pid
    /// has been handed to someone else. The guard was originally on the
    /// escalation only; the window is smaller on the first signal but it is the
    /// same window, and there is no reason to treat them differently.
    private static func kill(_ process: Process, waitingOn exited: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        guard exited.wait(timeout: .now() + terminationGrace) == .timedOut else { return }
        // A child that has survived `SIGTERM` for the grace period is far
        // likelier to still be here than to have exited in that instant.
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        // Bounded even here. `SIGKILL` is not refusable, but a child wedged in
        // an uninterruptible wait can outlive it, and no signal we have left
        // would help — better to return and report than to inherit the hang.
        _ = exited.wait(timeout: .now() + terminationGrace)
    }
}

extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
