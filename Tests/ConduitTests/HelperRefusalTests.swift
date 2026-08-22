// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

/// The helper used to answer an unauthorized peer with EOF, which the client
/// read as "helper unreachable" and turned into an admin password prompt. A
/// denial must never become a prompt; these pin the path end to end with a
/// stand-in helper on a temporary socket.
final class HelperRefusalTests: XCTestCase {

    // MARK: - Wire

    func testARefusalRoundTripsAndAnOlderFrameHasNone() throws {
        let frame = HelperResponse.refused(.noConsoleUser, "no console user yet")
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertEqual(decoded.refusal, .noConsoleUser)
        XCTAssertFalse(decoded.success)

        let older = Data(#"{"protocolVersion":4,"success":false,"errorMessage":"x"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperResponse.self, from: older).refusal)
    }

    func testAnUnknownRefusalReasonIsStillAFailedFrameNotADecodeError() throws {
        let future = Data(#"{"protocolVersion":4,"success":false,"refusal":"somethingNew"}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: future)
        XCTAssertNil(decoded.refusal)
        XCTAssertFalse(decoded.success)
    }

    // MARK: - Classification

    func testARefusalIsNotUnreachability() {
        XCTAssertFalse(PrivilegeClientError.refused(.unauthorized, "").isHelperUnreachable)
        XCTAssertFalse(PrivilegeClientError.refused(.noConsoleUser, "").isHelperUnreachable)
        XCTAssertTrue(PrivilegeClientError.communicationFailed("Empty response").isHelperUnreachable,
                      "EOF is still unreachability — that is the case a helper that predates the field produces")
    }

    // MARK: - Client against a stand-in helper

    func testAnUnauthorizedRefusalThrowsRefusedAndNeverReachesTheFallback() throws {
        let helper = try FakeHelper(replies: [.refused(.unauthorized, "peer is not the console user")])
        defer { helper.stop() }
        let fallbackRan = NIOLockedBox(false)
        let events = NIOLockedBox<[String]>([])
        let client = HelperToolPrivilegeClient(
            eventSink: { event in events.with { $0.append(event.event) } },
            socketPath: helper.path,
            fallback: AppleScriptPrivilegeClient(runner: { _ in
                fallbackRan.with { $0 = true }
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            })
        )
        XCTAssertThrowsError(try client.execute(.startDNSRelay, values: ["5053"])) { error in
            guard case .refused(.unauthorized, _)? = error as? PrivilegeClientError else {
                return XCTFail("expected .refused(.unauthorized), got \(error)")
            }
        }
        XCTAssertFalse(fallbackRan.value, "a denial became an admin prompt")
        XCTAssertEqual(events.value, ["auth.privilege_helper_refused"])
        XCTAssertEqual(helper.requestsSeen, 1)
    }

    /// `noConsoleUser` is state for the UI and the reconcile paths, not
    /// something to sleep on: every `execute` caller is on the MainActor. One
    /// request, an immediate `.refused`, no prompt, and the time it took is
    /// the round trip — a retry loop here would show as seconds.
    func testNoConsoleUserReturnsAtOnceWithoutPromptingOrWaiting() throws {
        let helper = try FakeHelper(replies: Array(repeating: .refused(.noConsoleUser, "no console user yet"), count: 10))
        defer { helper.stop() }
        let client = HelperToolPrivilegeClient(
            socketPath: helper.path,
            fallback: AppleScriptPrivilegeClient(runner: { _ in XCTFail("fallback ran"); throw CancellationError() })
        )
        let started = Date()
        XCTAssertThrowsError(try client.execute(.ping, values: [])) { error in
            guard case .refused(.noConsoleUser, _)? = error as? PrivilegeClientError else {
                return XCTFail("expected .refused(.noConsoleUser), got \(error)")
            }
        }
        XCTAssertEqual(helper.requestsSeen, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the client slept on a refusal")
    }

    /// Either refusal is a single reply; `unauthorized` in particular is a
    /// verdict and never re-asked.
    func testUnauthorizedIsNotRetried() throws {
        let helper = try FakeHelper(replies: Array(repeating: .refused(.unauthorized, "x"), count: 5))
        defer { helper.stop() }
        let client = HelperToolPrivilegeClient(
            socketPath: helper.path,
            fallback: AppleScriptPrivilegeClient(runner: { _ in XCTFail("fallback ran"); throw CancellationError() })
        )
        XCTAssertThrowsError(try client.execute(.ping, values: []))
        XCTAssertEqual(helper.requestsSeen, 1)
    }

    /// The EOF a pre-field helper still produces keeps its old meaning, so
    /// the fallback is still reachable for a helper that is genuinely gone.
    func testEOFStillDegradesToTheFallback() throws {
        let helper = try FakeHelper(replies: [nil])
        defer { helper.stop() }
        let fallbackRan = NIOLockedBox(false)
        let client = HelperToolPrivilegeClient(
            socketPath: helper.path,
            fallback: AppleScriptPrivilegeClient(runner: { _ in
                fallbackRan.with { $0 = true }
                return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            })
        )
        XCTAssertNoThrow(try client.execute(.ping, values: []))
        XCTAssertTrue(fallbackRan.value)
    }
}

// MARK: - Stand-in helper

/// Accepts on a temporary Unix socket and answers each connection with the
/// next scripted reply (`nil` = close without writing, the pre-field EOF).
private final class FakeHelper: @unchecked Sendable {
    let path: String
    private let serverFD: Int32
    private let replies: [HelperResponse?]
    private let lock = NSLock()
    private var seen = 0
    private var running = true

    var requestsSeen: Int { lock.withLock { seen } }

    init(replies: [HelperResponse?]) throws {
        // sun_path is 104 bytes; /tmp keeps it short.
        path = "/tmp/pm-fake-helper-\(UUID().uuidString.prefix(8)).sock"
        self.replies = replies
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                _ = strlcpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, maxLen)
            }
        }
        let fd = serverFD
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 5) == 0 else { throw CancellationError() }
        let worker = Thread { [self] in self.serve() }
        worker.start()
    }

    private func serve() {
        while lock.withLock({ running }) {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { return }
            var byte: UInt8 = 0
            while Darwin.read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
            let index = lock.withLock { () -> Int in defer { seen += 1 }; return seen }
            if index < replies.count, let reply = replies[index],
               var data = try? JSONEncoder().encode(reply) {
                data.append(UInt8(ascii: "\n"))
                data.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress!, $0.count) }
            }
            close(client)
        }
    }

    func stop() {
        lock.withLock { running = false }
        close(serverFD)
        unlink(path)
    }
}

private final class NIOLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func with(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}
