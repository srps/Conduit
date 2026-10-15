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
        maxOutputBytes: Int = HelperSubprocess.defaultMaxOutputBytes,
        terminationGrace: Int = HelperSubprocess.terminationGraceMilliseconds,
        drainGrace: Int = HelperSubprocess.drainGraceMilliseconds
    ) throws -> HelperSubprocess.Result {
        try HelperSubprocess.run(
            "/bin/sh",
            ["-c", script],
            deadline: HelperLineIO.deadline(afterMilliseconds: milliseconds),
            maxOutputBytes: maxOutputBytes,
            terminationGrace: terminationGrace,
            drainGrace: drainGrace
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

    func testChildThatIgnoresSIGTERMIsKilled() throws {
        // The shell ignores SIGTERM and waits on a `sleep` that was not
        // signalled at all, which also leaves a writer on both pipes after
        // the shell is killed: the drain must give up on it too.
        //
        // The kill and drain graces are shortened: the production values are
        // sized for a loaded machine, and what this case checks is that
        // SIGKILL follows the one and the drain gives up after the other.
        //
        // Foundation resets the child's signal dispositions, so no ignored
        // SIGTERM can be handed down to it, and a shell signalled before it
        // has run its `trap` dies on the SIGTERM. So the shell writes a marker
        // once the trap is in place; an attempt without it proves nothing and
        // is repeated with twice the budget.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-trap-\(UUID().uuidString)")
        let grace = 100, drain = 50
        var budget = 100
        while true {
            let start = HelperLineIO.now()
            XCTAssertThrowsError(
                try HelperSubprocess.run(
                    "/bin/sh",
                    ["-c", "trap '' TERM; : > \"$1\"; sleep 12", "sh", marker.path],
                    deadline: HelperLineIO.deadline(afterMilliseconds: budget),
                    terminationGrace: grace,
                    drainGrace: drain
                )
            ) { error in
                XCTAssertEqual(
                    error as? HelperSubprocess.Failure,
                    .deadlineExceeded(executable: "/bin/sh", reaped: true)
                )
            }
            let elapsed = elapsedMilliseconds(since: start)
            if FileManager.default.fileExists(atPath: marker.path) {
                XCTAssertGreaterThanOrEqual(elapsed, budget + grace)
                XCTAssertLessThan(elapsed, budget + 2 * grace + drain + 3_000)
                try FileManager.default.removeItem(at: marker)
                return
            }
            guard budget < 3_200 else { return XCTFail("the shell never got as far as its trap") }
            budget *= 2
        }
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
        // The drain's grace is shortened: what this case checks is that the
        // caller is not held for the grandchild's eight seconds.
        let result = try run("sleep 8 & echo started", milliseconds: 5_000, drainGrace: 50)
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
