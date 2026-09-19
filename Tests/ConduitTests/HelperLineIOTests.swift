// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest

/// The helper serves one connection at a time, so what a peer can make it
/// wait is what every other client waits. Unprivileged socket pairs stand in
/// for the helper's socket; nothing installed is involved.
final class HelperLineIOTests: XCTestCase {
    private var helperEnd: Int32 = -1
    private var peerEnd: Int32 = -1

    override func setUpWithError() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        (helperEnd, peerEnd) = (pair[0], pair[1])
        var one: Int32 = 1
        setsockopt(peerEnd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(helperEnd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    override func tearDown() {
        if helperEnd >= 0 { close(helperEnd) }
        if peerEnd >= 0 { close(peerEnd) }
    }

    /// The defect: a receive timeout restarts with every byte, so a peer that
    /// keeps sending is never timed out. The deadline is on the request.
    func testDripFedRequestIsCutOffAtTheDeadlineDespiteProgress() {
        let stop = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let peer = peerEnd
        let dripper = Thread {
            var byte = UInt8(ascii: "x")
            // Far longer than the deadline; ends when the test says so.
            while stop.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
                if send(peer, &byte, 1, 0) != 1 { break }
            }
            exited.signal()
        }
        dripper.start()
        // The thread must be gone before teardown closes its descriptor: the
        // number is reused by the next test's socket pair, and a last send
        // would land there.
        defer {
            stop.signal()
            XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        }

        let start = HelperLineIO.now()
        let result = HelperLineIO.readLine(
            fd: helperEnd,
            deadline: HelperLineIO.deadline(afterMilliseconds: 300, from: start),
            maxBytes: 1_048_576
        )
        let elapsedMilliseconds = (HelperLineIO.now() - start) / 1_000_000
        XCTAssertEqual(result, .deadlineExceeded)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 300)
        XCTAssertLessThan(elapsedMilliseconds, 3_000, "progress must not extend the deadline")
    }

    func testStalledPeerIsCutOffAtTheDeadline() {
        XCTAssertEqual(write("{\"command\":"), 11)
        let result = HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 100), maxBytes: 1024)
        XCTAssertEqual(result, .deadlineExceeded)
    }

    func testExpiredDeadlineReadsNothing() {
        XCTAssertEqual(write("ping\n"), 5)
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.now(), maxBytes: 1024), .deadlineExceeded)
    }

    func testRequestSplitAcrossWritesIsReassembled() {
        let peer = peerEnd
        let exited = DispatchSemaphore(value: 0)
        let writer = Thread {
            for part in ["{\"comm", "and\":\"pi", "ng\"}\nIGNORED"] {
                _ = part.withCString { send(peer, $0, strlen($0), 0) }
                Thread.sleep(forTimeInterval: 0.02)
            }
            exited.signal()
        }
        writer.start()
        defer { XCTAssertEqual(exited.wait(timeout: .now() + 5), .success) }
        let result = HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 2_000), maxBytes: 1024)
        XCTAssertEqual(result, .line(Data("{\"command\":\"ping\"}".utf8)))
    }

    func testPeerThatDisconnectsEndsTheReadAtOnce() {
        XCTAssertEqual(write("partial"), 7)
        close(peerEnd)
        peerEnd = -1
        let start = HelperLineIO.now()
        let result = HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 5_000), maxBytes: 1024)
        XCTAssertEqual(result, .line(Data("partial".utf8)), "a request without its newline is still the request")
        XCTAssertLessThan((HelperLineIO.now() - start) / 1_000_000, 2_000)
    }

    func testPeerThatDisconnectsWithoutSendingIsEmpty() {
        close(peerEnd)
        peerEnd = -1
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 5_000), maxBytes: 1024), .empty)
    }

    func testRequestOverTheCeilingIsRefusedWithOrWithoutItsNewline() {
        XCTAssertEqual(write(String(repeating: "a", count: 65)), 65)
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 1_000), maxBytes: 64), .tooLarge)
        XCTAssertEqual(write(String(repeating: "b", count: 65) + "\n"), 66)
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 1_000), maxBytes: 64), .tooLarge)
    }

    func testRequestAtTheCeilingIsAccepted() {
        let body = String(repeating: "c", count: 64)
        XCTAssertEqual(write(body + "\n"), 65)
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 1_000), maxBytes: 64), .line(Data(body.utf8)))
    }

    /// The reply side of the same defect: a peer that never reads fills the
    /// socket buffer, and a blocking write would hold the loop indefinitely.
    func testReplyToAPeerThatNeverReadsGivesUpAtTheDeadline() {
        let start = HelperLineIO.now()
        let accepted = HelperLineIO.writeAll(
            fd: helperEnd,
            Data(repeating: 0x41, count: 8 * 1024 * 1024),
            deadline: HelperLineIO.deadline(afterMilliseconds: 200, from: start)
        )
        XCTAssertFalse(accepted)
        XCTAssertLessThan((HelperLineIO.now() - start) / 1_000_000, 3_000)
    }

    func testReplyToAPeerThatLeftFailsWithoutRaising() {
        close(peerEnd)
        peerEnd = -1
        XCTAssertFalse(HelperLineIO.writeAll(fd: helperEnd, Data("{}\n".utf8), deadline: HelperLineIO.deadline(afterMilliseconds: 1_000)))
    }

    func testReplyIsDeliveredWhole() {
        let reply = Data("{\"success\":true}\n".utf8)
        XCTAssertTrue(HelperLineIO.writeAll(fd: helperEnd, reply, deadline: HelperLineIO.deadline(afterMilliseconds: 1_000)))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(peerEnd, &buffer, buffer.count, 0)
        XCTAssertEqual(Data(buffer[..<max(count, 0)]), reply)
    }

    /// What the accept loop depends on: after a peer has used up its whole
    /// allowance, the next client is served within its own.
    func testNextRequestIsServedAfterAStalledOne() {
        XCTAssertEqual(HelperLineIO.readLine(fd: helperEnd, deadline: HelperLineIO.deadline(afterMilliseconds: 100), maxBytes: 1024), .deadlineExceeded)
        var next: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &next), 0)
        defer { close(next[0]); close(next[1]) }
        XCTAssertEqual("ping\n".withCString { send(next[1], $0, 5, 0) }, 5)
        XCTAssertEqual(HelperLineIO.readLine(fd: next[0], deadline: HelperLineIO.deadline(afterMilliseconds: 1_000), maxBytes: 1024), .line(Data("ping".utf8)))
    }

    private func write(_ text: String) -> Int {
        text.withCString { send(peerEnd, $0, strlen($0), 0) }
    }
}
