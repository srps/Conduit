// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class TunnelRelayDiagnosticsTests: XCTestCase {
    func testRelayReportsSideObservedBytesTimingAndTransitionOnce() throws {
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let logger = RecordingLogSink(minLevel: .info)
        let clock = NIOLockedValueBox(UInt64(1_000_000_000))
        let cause = NIOLockedValueBox(DirectModeCause.none)
        let reporter = TunnelFailureReporter(logger: logger, eventSink: { event in
            XCTAssertTrue(logger.entries().isEmpty, "event must precede its log")
            events.withLockedValue { $0.append(event) }
        })
        let diagnostics = TunnelRelayDiagnostics(
            target: "example.test:443", transport: "connect", route: "upstream", upstream: "proxy.test:8080",
            causeProvider: { cause.withLockedValue { $0 } }, reporter: reporter,
            now: { clock.withLockedValue { $0 } }
        )
        let client = EmbeddedChannel()
        let remote = EmbeddedChannel()
        try client.pipeline.addHandler(TunnelRelayHandler(peer: remote, diagnostics: diagnostics, side: .client)).wait()
        try remote.pipeline.addHandler(TunnelRelayHandler(peer: client, diagnostics: diagnostics, side: .remote)).wait()
        try client.writeInbound(ByteBuffer(string: "abc"))
        XCTAssertEqual(try remote.readOutbound(as: ByteBuffer.self)?.readableBytes, 3)
        clock.withLockedValue { $0 = 1_200_000_000 }
        try remote.writeInbound(ByteBuffer(string: "reply"))
        XCTAssertEqual(try client.readOutbound(as: ByteBuffer.self)?.readableBytes, 5)
        cause.withLockedValue { $0 = .vpnDisconnected }
        clock.withLockedValue { $0 = 1_500_000_000 }
        remote.pipeline.fireErrorCaught(IOError(errnoCode: ECONNRESET, reason: "reset"))
        client.pipeline.fireErrorCaught(IOError(errnoCode: ETIMEDOUT, reason: "timeout"))
        let emitted = events.withLockedValue { $0 }
        XCTAssertEqual(emitted.count, 1, "both halves must not report the same tunnel failure twice")
        XCTAssertEqual(emitted.first?.event, "tunnel.relay_failed")
        let detail = try XCTUnwrap(emitted.first?.detail)
        for field in ["side=remote", "client_bytes=3", "remote_bytes=5", "age_ms=500", "idle_ms=300",
                      "upstream=proxy.test:8080", "started_cause=none", "current_cause=vpnDisconnected", "errno=54"] {
            XCTAssertTrue(detail.contains(field), "missing \(field): \(detail)")
        }
        XCTAssertTrue(logger.containsMessage(detail, at: .warning))
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }

    func testFailureStormIsCoalescedAndItsNextEventCarriesSuppressedCount() {
        let at = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let reporter = TunnelFailureReporter(logger: DiscardingLogSink(), eventSink: { event in
            events.withLockedValue { $0.append(event) }
        }, now: { at.withLockedValue { $0 } })
        func fail() {
            let diagnostics = TunnelRelayDiagnostics(
                target: "example.test:443", transport: "transparent", route: "direct", upstream: nil,
                causeProvider: { .vpnDisconnected }, reporter: reporter
            )
            diagnostics.failed(IOError(errnoCode: ECONNRESET, reason: "reset"), on: .client)
        }
        for _ in 0..<100 { fail() }
        XCTAssertEqual(events.withLockedValue { $0.count }, 1)
        at.withLockedValue { $0 += 60 }
        fail()
        XCTAssertEqual(events.withLockedValue { $0.count }, 2)
        XCTAssertTrue(events.withLockedValue { $0.last?.detail?.contains("suppressed=99") == true })
    }

    func testDiagnosticTargetAndErrorAreRedacted() {
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let reporter = TunnelFailureReporter(logger: DiscardingLogSink(), eventSink: { event in
            events.withLockedValue { $0.append(event) }
        })
        let diagnostics = TunnelRelayDiagnostics(
            target: "https://example.test/path?secret=value#fragment", transport: "transparent", route: "direct", upstream: nil,
            causeProvider: { .none }, reporter: reporter
        )
        diagnostics.failed(IOError(errnoCode: ECONNRESET, reason: "Authorization: Bearer TOPSECRET"), on: .remote)
        let detail = events.withLockedValue { $0.first?.detail ?? "" }
        XCTAssertFalse(detail.contains("secret=value"))
        XCTAssertFalse(detail.contains("TOPSECRET"))
        XCTAssertTrue(detail.contains("target=https://example.test/path"))
    }
}
