// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest

/// The helper's accept loop waits for whatever child a command runs, so what
/// a child can make it wait is what every later client waits. `/bin/sh`
/// stands in for `networksetup`; nothing privileged is involved.
final class HelperSubprocessTests: XCTestCase {
    private func run(
        _ script: String,
        milliseconds: Int,
        maxOutputBytes: Int = HelperSubprocess.defaultMaxOutputBytes
    ) throws -> HelperSubprocess.Result {
        try HelperSubprocess.run(
            "/bin/sh",
            ["-c", script],
            deadline: HelperLineIO.deadline(afterMilliseconds: milliseconds),
            maxOutputBytes: maxOutputBytes
        )
    }

    private func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((HelperLineIO.now() - start) / 1_000_000)
    }

    func testExitCodeAndBothStreamsComeBack() throws {
        let result = try run("echo out; echo err >&2; exit 3", milliseconds: 5_000)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.errorOutput, as: UTF8.self), "err\n")
        XCTAssertFalse(result.outputTruncated)
    }

    /// The defect: `waitUntilExit` on a child that never returns held the
    /// helper's one loop for good.
    func testChildThatNeverReturnsIsTerminatedAtTheDeadline() {
        let start = HelperLineIO.now()
        XCTAssertThrowsError(try run("exec sleep 30", milliseconds: 300)) { error in
            XCTAssertEqual(
                error as? HelperSubprocess.Failure,
                .deadlineExceeded(executable: "/bin/sh", reaped: true)
            )
        }
        // `sleep` dies on SIGTERM, so neither kill grace is spent.
        XCTAssertLessThan(elapsedMilliseconds(since: start), 300 + HelperSubprocess.terminationGraceMilliseconds)
    }

    func testChildThatIgnoresSIGTERMIsKilled() {
        let start = HelperLineIO.now()
        // The shell ignores SIGTERM and waits on a `sleep` that was not
        // signalled at all, which also leaves a writer on both pipes after
        // the shell is killed: the drain must give up on it too.
        XCTAssertThrowsError(try run("trap '' TERM; sleep 8", milliseconds: 200)) { error in
            XCTAssertEqual(
                error as? HelperSubprocess.Failure,
                .deadlineExceeded(executable: "/bin/sh", reaped: true)
            )
        }
        let elapsed = elapsedMilliseconds(since: start)
        XCTAssertGreaterThanOrEqual(elapsed, 200 + HelperSubprocess.terminationGraceMilliseconds)
        XCTAssertLessThan(elapsed, 200 + HelperSubprocess.overrunMilliseconds + 1_000)
    }

    /// A child that writes more than a pipe holds blocks until someone reads.
    /// Waiting for the exit first is how that becomes a hang.
    func testOutputPastThePipeBufferDoesNotBlockTheChild() throws {
        let result = try run("head -c 300000 /dev/zero; exit 0", milliseconds: 10_000, maxOutputBytes: 1_024)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.count, 1_024)
        XCTAssertTrue(result.outputTruncated)
    }

    /// The child's exit is not the last word on its pipes: a grandchild
    /// inherits them. The result comes back after the drain grace, flagged.
    func testGrandchildHoldingThePipesDoesNotHoldTheCaller() throws {
        let start = HelperLineIO.now()
        let result = try run("sleep 8 & echo started", milliseconds: 5_000)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "started\n")
        XCTAssertTrue(result.outputTruncated)
        XCTAssertLessThan(elapsedMilliseconds(since: start), 5_000)
    }

    /// A child that closes both streams and keeps running has nothing left to
    /// read; the deadline still ends it.
    func testChildThatClosesItsStreamsIsStillBounded() {
        XCTAssertThrowsError(try run("exec >&- 2>&-; exec sleep 30", milliseconds: 300)) { error in
            XCTAssertEqual(
                error as? HelperSubprocess.Failure,
                .deadlineExceeded(executable: "/bin/sh", reaped: true)
            )
        }
    }

    func testExecutableThatCannotBeLaunchedThrows() {
        XCTAssertThrowsError(
            try HelperSubprocess.run(
                "/nonexistent/networksetup",
                [],
                deadline: HelperLineIO.deadline(afterMilliseconds: 1_000)
            )
        ) { error in
            XCTAssertNil(error as? HelperSubprocess.Failure, "a launch failure is not a deadline")
        }
    }

    /// One budget for a whole command: a second child started after the
    /// deadline gets no time of its own.
    func testDeadlineAlreadyPassedTerminatesAtOnce() {
        let start = HelperLineIO.now()
        XCTAssertThrowsError(
            try HelperSubprocess.run("/bin/sh", ["-c", "exec sleep 30"], deadline: start)
        )
        XCTAssertLessThan(elapsedMilliseconds(since: start), HelperSubprocess.terminationGraceMilliseconds)
    }
}
