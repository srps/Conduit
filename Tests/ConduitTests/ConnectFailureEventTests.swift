// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// `upstream.tunnel_failed` and `upstream.exchange_failed` say the upstream
/// failed. A request the pool refused locally never reached it and gets no
/// such event (Codex on PR #42); the limiter already emits
/// `auth.handshake_rejected` for its own refusals.
final class ConnectFailureEventTests: XCTestCase {
    func testLocalPoolRefusalsGetNoUpstreamEvent() {
        XCTAssertNil(HTTPProxyHandler.upstreamFailureEvent("upstream.tunnel_failed", for: ConnectionPoolError.poolExhausted))
        XCTAssertNil(HTTPProxyHandler.upstreamFailureEvent("upstream.exchange_failed", for: ConnectionPoolError.authHandshakeLimitExceeded))
    }

    func testUpstreamFailuresKeepTheirEvent() {
        XCTAssertEqual(
            HTTPProxyHandler.upstreamFailureEvent("upstream.tunnel_failed", for: ConnectionPoolError.upstreamResponseTimedOut),
            "upstream.tunnel_failed"
        )
        XCTAssertEqual(
            HTTPProxyHandler.upstreamFailureEvent("upstream.exchange_failed", for: ConnectionPoolError.noUpstreamsConfigured),
            "upstream.exchange_failed"
        )
    }

    func testAnEventOfNilIsLoggedButNotEmitted() {
        let logger = RecordingLogSink(minLevel: .info)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        HTTPProxyHandler.reportConnectFailure(
            nil, level: .error, target: "example.test:443", error: ConnectionPoolError.poolExhausted,
            message: "CONNECT tunnel failed: pool exhausted", logger: logger,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        XCTAssertTrue(events.withLockedValue { $0.isEmpty })
        XCTAssertTrue(logger.containsMessage("CONNECT tunnel failed: pool exhausted", at: .error))
    }

    func testAnExpectedFailureIsLoggedButNotEmitted() {
        let logger = RecordingLogSink(minLevel: .info)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        HTTPProxyHandler.reportConnectFailure(
            "direct.connect_failed", level: .info, target: "10.0.0.1:443", error: ConnectionPoolError.noUpstreamsConfigured,
            message: "Direct connect to 10.0.0.1:443 failed", logger: logger,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        XCTAssertTrue(events.withLockedValue { $0.isEmpty })
        XCTAssertTrue(logger.containsMessage("Direct connect to 10.0.0.1:443 failed", at: .info))
    }

    func testALoudFailureEmitsBeforeItLogs() {
        let logger = RecordingLogSink(minLevel: .info)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        HTTPProxyHandler.reportConnectFailure(
            "upstream.tunnel_failed", level: .error, target: "example.test:443", error: ConnectionPoolError.upstreamResponseTimedOut,
            message: "CONNECT tunnel failed: timed out", logger: logger,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        let emitted = events.withLockedValue { $0 }
        XCTAssertEqual(emitted.map(\.event), ["upstream.tunnel_failed"])
        XCTAssertEqual(emitted.first?.kind, .connection)
        XCTAssertTrue(emitted.first?.detail?.hasPrefix("target=example.test:443 reason=") ?? false)
        let line = logger.entries().first { $0.message == "CONNECT tunnel failed: timed out" }
        XCTAssertEqual(line?.level, .error)
        if let event = emitted.first, let line { XCTAssertLessThanOrEqual(event.timestamp, line.timestamp) }
    }
}
