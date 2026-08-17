// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac

/// `CommandRunner` used to call `waitUntilExit()` and only then read the pipes.
/// A child that writes past the 64 KiB Darwin pipe buffer blocks in `write`
/// waiting for a reader that never arrives, while the parent blocks waiting for
/// a child that can never exit — an unrecoverable hang with no timeout to break
/// it. Latent only because every caller at the time was terse; `curlPACFetcher`
/// runs the same helper against an arbitrary PAC URL, and corporate PAC files
/// with large host lists reach 64 KiB without being remarkable.
///
/// Every case here runs the call off the test thread with a deadline, so a
/// regression fails this test instead of wedging the whole suite.
final class CommandRunnerTests: XCTestCase {

    /// ~205 KB on stdout: comfortably past the pipe buffer, comfortably under
    /// `maxOutputBytes`.
    private static let wideLine = String(repeating: "a", count: 40)

    private func runOffThread(
        timeoutSeconds: TimeInterval = 30,
        _ body: @escaping @Sendable () throws -> Void
    ) {
        let done = expectation(description: "CommandRunner returned")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try body()
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: timeoutSeconds)
    }

    func testOutputLargerThanThePipeBufferDoesNotDeadlock() {
        runOffThread {
            let result = try? CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "yes \(Self.wideLine) | head -n 5000"]
            )
            XCTAssertEqual(result?.exitCode, 0)
            XCTAssertGreaterThan(
                result?.standardOutput.utf8.count ?? 0,
                65_536,
                "the point of the case is that the child wrote past the pipe buffer"
            )
        }
    }

    /// Same hazard on the other stream — a child can fill either pipe.
    func testStandardErrorLargerThanThePipeBufferDoesNotDeadlock() {
        runOffThread {
            let result = try? CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "yes \(Self.wideLine) | head -n 5000 >&2"]
            )
            XCTAssertEqual(result?.exitCode, 0)
            XCTAssertGreaterThan(result?.standardError.utf8.count ?? 0, 65_536)
        }
    }

    func testOutputBeyondTheCapFailsRatherThanTruncating() {
        runOffThread {
            // ~1.23 MB, past `maxOutputBytes`. Truncating here would hand
            // `curlPACFetcher` half a PAC script, which routes traffic wrongly
            // rather than visibly failing.
            XCTAssertThrowsError(
                try CommandRunner.run(
                    launchPath: "/bin/sh",
                    arguments: ["-c", "yes \(Self.wideLine) | head -n 30000"]
                )
            ) { error in
                guard case CommandRunnerError.outputTooLarge = error else {
                    return XCTFail("expected outputTooLarge, got \(error)")
                }
            }
        }
    }

    func testAChildThatOutlivesItsTimeoutIsTerminated() {
        runOffThread {
            let started = Date()
            XCTAssertThrowsError(
                try CommandRunner.run(
                    launchPath: "/bin/sleep",
                    arguments: ["30"],
                    timeout: 0.5
                )
            ) { error in
                guard case CommandRunnerError.timedOut = error else {
                    return XCTFail("expected timedOut, got \(error)")
                }
            }
            XCTAssertLessThan(
                Date().timeIntervalSince(started),
                10,
                "the timeout must fire on its own deadline, not the child's"
            )
        }
    }

    /// A child that ignores `SIGTERM` still has to die, or the timeout is only
    /// a suggestion.
    ///
    /// This case also covers the grandchild problem: `sh` holds `sleep 30` as a
    /// child, and killing `sh` leaves `sleep` holding the inherited pipe. The
    /// call has to come back on its own deadline rather than joining a read
    /// that nothing will end.
    func testAChildThatIgnoresSIGTERMIsKilled() {
        runOffThread {
            XCTAssertThrowsError(
                try CommandRunner.run(
                    launchPath: "/bin/sh",
                    arguments: ["-c", "trap '' TERM; sleep 30"],
                    timeout: 0.5
                )
            ) { error in
                guard case CommandRunnerError.timedOut = error else {
                    return XCTFail("expected timedOut, got \(error)")
                }
            }
        }
    }

    /// The child exits promptly and cleanly; a backgrounded grandchild keeps
    /// the pipe open behind it. Returning the prefix as if it were the whole
    /// output would be a silent truncation, so this is reported.
    func testAnOrphanHoldingThePipeIsReportedRatherThanTruncated() {
        runOffThread(timeoutSeconds: 60) {
            XCTAssertThrowsError(
                try CommandRunner.run(
                    launchPath: "/bin/sh",
                    arguments: ["-c", "echo first; sleep 30 & exit 0"]
                )
            ) { error in
                guard case CommandRunnerError.outputIncomplete = error else {
                    return XCTFail("expected outputIncomplete, got \(error)")
                }
            }
        }
    }

    /// Giving up on a read must release it, not merely stop waiting on it.
    ///
    /// An abandoned *blocking* read keeps its thread, its buffer and its
    /// descriptor alive for as long as the orphan writer lives. Repeat the path
    /// and the drain queue fills with parked workers, at which point no command
    /// can drain at all — the deadlock this whole file exists to prevent,
    /// arrived at from the other side. Descriptor count is the observable
    /// proxy: two per call, and they must all come back.
    func testAbandonedDrainsDoNotAccumulate() {
        runOffThread(timeoutSeconds: 120) {
            // One warm-up first: the first subprocess in a test process opens
            // descriptors that stay open (dyld caches, the Foundation reaper),
            // and counting those as a leak would make this flaky.
            _ = try? CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "echo warm; sleep 20 & exit 0"]
            )

            let baseline = Self.openDescriptorCount()
            for _ in 0..<5 {
                XCTAssertThrowsError(
                    try CommandRunner.run(
                        launchPath: "/bin/sh",
                        arguments: ["-c", "echo held; sleep 20 & exit 0"]
                    )
                )
            }
            let after = Self.openDescriptorCount()

            XCTAssertLessThanOrEqual(
                after - baseline,
                2,
                "five abandoned drains held \(after - baseline) extra descriptors; "
                    + "cancelling has to close them, not just stop waiting"
            )
        }
    }

    private static func openDescriptorCount() -> Int {
        (0..<1024).reduce(into: 0) { count, fd in
            if fcntl(Int32(fd), F_GETFD) != -1 { count += 1 }
        }
    }

    func testExitCodeAndStreamsAreReportedSeparately() {
        runOffThread {
            let result = try? CommandRunner.run(
                launchPath: "/bin/sh",
                arguments: ["-c", "echo out; echo err >&2; exit 3"]
            )
            XCTAssertEqual(result?.exitCode, 3)
            XCTAssertEqual(result?.standardOutput, "out")
            XCTAssertEqual(result?.standardError, "err")
        }
    }
}
