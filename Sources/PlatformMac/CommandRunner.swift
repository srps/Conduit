// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

package struct CommandResult: Sendable {
    package let exitCode: Int32
    package let standardOutput: String
    package let standardError: String
}

package enum CommandRunnerError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)
    case outputTooLarge(command: String, limitBytes: Int)
    case outputIncomplete(command: String)

    package var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            return "\(command) did not finish within \(Int(seconds))s and was terminated."
        case .outputTooLarge(let command, let limitBytes):
            return "\(command) produced more than \(limitBytes) bytes of output."
        case .outputIncomplete(let command):
            return "\(command) exited but something still holds its output pipe open; "
                 + "the output read back may be incomplete."
        }
    }
}

package enum CommandRunner {
    /// Per-stream ceiling on what a child may write before we call the output
    /// runaway. Matches the frame cap the helper socket already enforces on
    /// both ends (`HelperDaemon`, `HelperToolPrivilegeClient`), so every
    /// boundary in the app where untrusted bytes arrive agrees on one number.
    ///
    /// Exceeding it fails the call rather than truncating. The only caller that
    /// reads a whole document is `curlPACFetcher`, and a silently truncated PAC
    /// script is a routing change, not a cosmetic one.
    package static let maxOutputBytes = 1_048_576

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
        timeout: TimeInterval = defaultTimeout
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
        let joinOutput = drain(stdout.fileHandleForReading)
        let joinError = drain(stderr.fileHandleForReading)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process, waitingOn: exited)
            timedOut = true
        }

        // One deadline shared by both joins, not one each: the streams are read
        // concurrently, so a pipe still held open should cost the grace period
        // once rather than twice.
        let joinDeadline = DispatchTime.now() + drainJoinGrace
        let output = joinOutput(joinDeadline)
        let error = joinError(joinDeadline)

        if timedOut {
            throw CommandRunnerError.timedOut(command: launchPath, seconds: timeout)
        }
        guard !output.overflowed, !error.overflowed else {
            throw CommandRunnerError.outputTooLarge(command: launchPath, limitBytes: maxOutputBytes)
        }
        // Reported, not swallowed: the alternative is handing back a prefix of
        // the output as if it were all of it, and every caller here branches on
        // what the command said.
        guard output.complete, error.complete else {
            throw CommandRunnerError.outputIncomplete(command: launchPath)
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
        /// Whether the read reached EOF. False means the join gave up while a
        /// writer was still holding the pipe, so `text` is a prefix.
        var complete: Bool
    }

    /// Starts reading `handle` on a background queue and returns the join.
    ///
    /// Past `maxOutputBytes` the read keeps going and stops accumulating:
    /// abandoning it would re-create the very deadlock this exists to prevent,
    /// only moved into teardown. A child that never stops writing is bounded by
    /// the caller's timeout instead — the two limits compose.
    ///
    /// A join that gives up abandons the read rather than closing the handle
    /// under it. Closing a descriptor while another thread is blocked reading
    /// it invites that number being handed straight back out by the next
    /// `open`, and the abandoned read would then be pointed at an unrelated
    /// file. The thread costs nothing and ends by itself when the last writer
    /// closes; the handle stays alive because this closure retains it.
    private static func drain(_ handle: FileHandle) -> (DispatchTime) -> DrainedStream {
        let collected = NIOLockedValueBox(Data())
        let overflowed = NIOLockedValueBox(false)
        let finished = DispatchSemaphore(value: 0)

        drainQueue.async {
            while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                collected.withLockedValue { buffer in
                    guard buffer.count + chunk.count <= maxOutputBytes else {
                        overflowed.withLockedValue { $0 = true }
                        return
                    }
                    buffer.append(chunk)
                }
            }
            finished.signal()
        }

        return { deadline in
            let complete = finished.wait(timeout: deadline) == .success
            return DrainedStream(
                text: String(decoding: collected.withLockedValue { $0 }, as: UTF8.self),
                overflowed: overflowed.withLockedValue { $0 },
                complete: complete
            )
        }
    }

    /// `SIGTERM`, then `SIGKILL` for a child that ignores it.
    private static func kill(_ process: Process, waitingOn exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + terminationGrace) == .timedOut else { return }
        // `isRunning` narrows — it cannot close — the window in which Foundation
        // has already reaped the child and the pid has been handed to someone
        // else. A child that has survived `SIGTERM` for the grace period is far
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
