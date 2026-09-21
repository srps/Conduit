// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

/// The client's side of #47: one deadline over connect, request and reply.
/// Every step used to block without one, on whatever thread asked. Listeners
/// on temporary Unix sockets stand in for a helper that is held.
final class HelperClientDeadlineTests: XCTestCase {
    private let budget = 300

    private func client(
        _ listener: HeldHelper,
        events: EventBox? = nil,
        fallbackRan: FlagBox? = nil
    ) -> HelperToolPrivilegeClient {
        let sink: @Sendable (RuntimeEvent) -> Void = { events?.append($0) }
        return HelperToolPrivilegeClient(
            eventSink: sink,
            socketPath: listener.path,
            fallback: AppleScriptPrivilegeClient(runner: { _ in
                fallbackRan?.set()
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }),
            transactionMilliseconds: budget
        )
    }

    private func assertBounded(_ start: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        let elapsed = Int((HelperLineIO.now() - start) / 1_000_000)
        XCTAssertGreaterThanOrEqual(elapsed, budget - 50, file: file, line: line)
        XCTAssertLessThan(elapsed, budget + 2_000, file: file, line: line)
    }

    /// A helper that took the request and is stuck in its command.
    func testHelperThatNeverRepliesIsGivenUpOnAtTheDeadline() throws {
        let helper = try HeldHelper(.readsAndHolds)
        defer { helper.stop() }
        let start = HelperLineIO.now()
        XCTAssertFalse(client(helper).ping())
        assertBounded(start)
    }

    /// Progress must not extend the wait: a reply that arrives a byte at a
    /// time is cut off where a whole one would have been.
    func testDripFedReplyIsCutOffDespiteProgress() throws {
        let helper = try HeldHelper(.dripsReply)
        defer { helper.stop() }
        let start = HelperLineIO.now()
        XCTAssertFalse(client(helper).ping())
        assertBounded(start)
    }

    /// A helper held by another peer accepts nobody, and its backlog fills.
    func testHelperThatAcceptsNobodyDoesNotHoldTheCaller() throws {
        let helper = try HeldHelper(.neverAccepts)
        defer { helper.stop() }
        let waiting = try helper.fillBacklog()
        defer { waiting.forEach { close($0) } }
        let start = HelperLineIO.now()
        XCTAssertFalse(client(helper).ping())
        XCTAssertLessThan(Int((HelperLineIO.now() - start) / 1_000_000), budget + 2_000)
    }

    /// A held helper is an unreachable one: the command goes to the
    /// fallback, and the event stream says why a prompt appeared.
    func testTimedOutCommandDegradesToTheFallbackWithAnEvent() throws {
        let helper = try HeldHelper(.readsAndHolds)
        defer { helper.stop() }
        let events = EventBox()
        let fallbackRan = FlagBox()
        XCTAssertNoThrow(
            try client(helper, events: events, fallbackRan: fallbackRan).execute(.disableAutoproxy, values: ["Wi-Fi"])
        )
        XCTAssertTrue(fallbackRan.isSet)
        let degraded = events.all.filter { $0.event == "auth.privilege_helper_degraded" }
        XCTAssertEqual(degraded.count, 1)
        XCTAssertTrue(degraded.first?.detail?.contains("Timed out") ?? false, "\(String(describing: degraded.first?.detail))")
    }

    /// The legitimate request after a stuck one: the client's descriptor is
    /// closed at the deadline, so nothing of the first outlives it.
    func testNextTransactionProceedsAfterATimedOutOne() throws {
        let helper = try HeldHelper(.holdsFirstThenAnswers)
        defer { helper.stop() }
        let client = client(helper)
        XCTAssertFalse(client.ping())
        XCTAssertTrue(client.ping())
    }

    /// The helper serves one connection at a time. Two requests from this
    /// process sent together would leave the second in the backlog with its
    /// deadline running, to run out having done nothing wrong and fall back
    /// while its request was still queued. Counted at the helper rather than
    /// timed: it never sees a second connection of ours while it has one.
    func testRequestsFromOneProcessReachTheHelperOneAtATime() throws {
        let helper = try HeldHelper(.answersAfter(milliseconds: 100))
        defer { helper.stop() }
        let client = HelperToolPrivilegeClient(socketPath: helper.path, transactionMilliseconds: 20_000)
        let answered = FlagCounter()
        let finished = DispatchGroup()
        for _ in 0..<4 {
            finished.enter()
            Thread {
                if client.ping() { answered.increment() }
                finished.leave()
            }.start()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(answered.count, 4)
        XCTAssertEqual(helper.mostConnectionsAtOnce, 1)
    }

    /// Some callers are still on the main actor, and behind a held helper
    /// every turn ahead of them is a whole budget. The wait for a turn has
    /// the same budget, so a caller is held for two at most, and one that
    /// never got its turn says so rather than "timed out waiting for the
    /// reply": it sent nothing.
    func testTheWaitForATurnIsBounded() throws {
        let helper = try HeldHelper(.readsAndHolds)
        defer { helper.stop() }
        let events = EventBox()
        let client = client(helper, events: events, fallbackRan: FlagBox())
        let finished = DispatchGroup()
        let start = HelperLineIO.now()
        for _ in 0..<4 {
            finished.enter()
            Thread {
                try? client.execute(.disableAutoproxy, values: ["Wi-Fi"])
                finished.leave()
            }.start()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        let elapsed = Int((HelperLineIO.now() - start) / 1_000_000)

        let reasons = events.all.filter { $0.event == "auth.privilege_helper_degraded" }.compactMap(\.detail)
        XCTAssertEqual(reasons.count, 4)
        XCTAssertTrue(reasons.contains { $0.contains("waiting for a turn") }, "\(reasons)")
        // Four held turns back to back would be four budgets.
        XCTAssertLessThan(elapsed, 2 * budget + 2_000)
    }
}

// MARK: - Stand-in helper that is held

private final class HeldHelper: @unchecked Sendable {
    enum Behaviour {
        case neverAccepts
        case readsAndHolds
        case dripsReply
        case holdsFirstThenAnswers
        case answersAfter(milliseconds: Int)
    }

    let path: String
    private let serverFD: Int32
    private let behaviour: Behaviour
    private let lock = NSLock()
    private var held: [Int32] = []
    private var stopped = false
    private var open = 0
    private var mostOpen = 0
    private let workerDone = DispatchSemaphore(value: 0)

    init(_ behaviour: Behaviour) throws {
        // sun_path is 104 bytes; /tmp keeps it short.
        path = "/tmp/pm-held-helper-\(UUID().uuidString.prefix(8)).sock"
        self.behaviour = behaviour
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0, HelperLineIOTestSupport.bind(serverFD, to: path), listen(serverFD, 1) == 0 else {
            throw CancellationError()
        }
        switch behaviour {
        case .neverAccepts:
            workerDone.signal()
        case .answersAfter(let milliseconds):
            Thread { [self] in
                acceptAndCount(answeringAfter: milliseconds)
                workerDone.signal()
            }.start()
        default:
            Thread { [self] in
                serve()
                workerDone.signal()
            }.start()
        }
    }

    /// The most connections this helper had at once, accepted and not yet
    /// answered. Only `.answersAfter` counts.
    var mostConnectionsAtOnce: Int { lock.withLock { mostOpen } }

    /// Accepts at once and answers on a thread per connection, one at a time
    /// like the real helper, so a second connection made while the first is
    /// being served is seen and counted rather than left in the backlog.
    private func acceptAndCount(answeringAfter milliseconds: Int) {
        let serving = NSLock()
        let answers = DispatchGroup()
        while true {
            let peer = accept(serverFD, nil, nil)
            guard peer >= 0 else { break }
            lock.withLock {
                open += 1
                mostOpen = max(mostOpen, open)
            }
            answers.enter()
            Thread { [self] in
                serving.withLock {
                    var byte: UInt8 = 0
                    while Darwin.read(peer, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
                    usleep(useconds_t(milliseconds) * 1_000)
                    lock.withLock { open -= 1 }
                    answer(peer)
                }
                answers.leave()
            }.start()
        }
        answers.wait()
    }

    /// Connections that sit in the backlog until `stop()`. Nonblocking, so
    /// the one that finds it full returns instead of waiting.
    func fillBacklog() throws -> [Int32] {
        var waiting: [Int32] = []
        for _ in 0..<8 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CancellationError() }
            waiting.append(fd)
            let deadline = HelperLineIO.deadline(afterMilliseconds: 50)
            if HelperLineIO.connect(fd: fd, path: path, deadline: deadline) != nil { break }
        }
        return waiting
    }

    private func serve() {
        var served = 0
        while true {
            let peer = accept(serverFD, nil, nil)
            guard peer >= 0 else { return }
            var one: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var byte: UInt8 = 0
            while Darwin.read(peer, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
            served += 1
            switch behaviour {
            case .neverAccepts, .readsAndHolds:
                hold(peer)
            case .holdsFirstThenAnswers:
                if served == 1 {
                    hold(peer)
                } else {
                    answer(peer)
                }
            case .answersAfter:
                // Served by `acceptAndCount`.
                close(peer)
            case .dripsReply:
                var filler = UInt8(ascii: " ")
                while !lock.withLock({ stopped }), Darwin.write(peer, &filler, 1) == 1 {
                    usleep(20_000)
                }
                close(peer)
            }
        }
    }

    private func answer(_ peer: Int32) {
        var reply = (try? JSONEncoder().encode(HelperResponse.ok())) ?? Data()
        reply.append(UInt8(ascii: "\n"))
        reply.withUnsafeBytes { _ = Darwin.write(peer, $0.baseAddress!, $0.count) }
        close(peer)
    }

    private func hold(_ fd: Int32) {
        lock.withLock { held.append(fd) }
    }

    /// The worker is gone before its descriptors are closed: the numbers are
    /// reused by the next test's sockets.
    func stop() {
        lock.withLock { stopped = true }
        shutdown(serverFD, SHUT_RDWR)
        close(serverFD)
        _ = workerDone.wait(timeout: .now() + 5)
        lock.withLock { held }.forEach { close($0) }
        unlink(path)
    }
}

private enum HelperLineIOTestSupport {
    static func bind(_ fd: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                _ = strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    var all: [RuntimeEvent] { lock.withLock { events } }
    func append(_ event: RuntimeEvent) { lock.withLock { events.append(event) } }
}

private final class FlagCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
