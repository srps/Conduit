// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// `upstream.tunnel_failed` and `upstream.exchange_failed` say the upstream
/// failed. A request the pool refused locally never reached it (Codex on
/// PR #42): exhaustion reports as `connection.pool_exhausted`, and the
/// limiter already emits `auth.handshake_rejected` for its own refusals.
final class ConnectFailureEventTests: XCTestCase {
    func testLocalPoolRefusalsGetNoUpstreamEvent() {
        let exhausted = HTTPProxyHandler.upstreamFailureReport("upstream.tunnel_failed", level: .error, for: ConnectionPoolError.poolExhausted)
        XCTAssertEqual(exhausted.event, "connection.pool_exhausted")
        XCTAssertEqual(exhausted.level, .error)
        let limited = HTTPProxyHandler.upstreamFailureReport("upstream.exchange_failed", level: .error, for: ConnectionPoolError.authHandshakeLimitExceeded)
        XCTAssertNil(limited.event, "the limiter emits auth.handshake_rejected itself")
        XCTAssertEqual(limited.level, .error)
    }

    /// A transient path change demotes upstream failures to info; a cap hit
    /// during that window is still a cap hit, loud and with its event.
    func testALocalRefusalDoesNotFollowTheTransientDemotion() {
        let exhausted = HTTPProxyHandler.upstreamFailureReport("upstream.tunnel_failed", level: .info, for: ConnectionPoolError.poolExhausted)
        XCTAssertEqual(exhausted.event, "connection.pool_exhausted")
        XCTAssertEqual(exhausted.level, .error)
        let upstream = HTTPProxyHandler.upstreamFailureReport("upstream.tunnel_failed", level: .info, for: ConnectionPoolError.upstreamResponseTimedOut)
        XCTAssertEqual(upstream.event, "upstream.tunnel_failed")
        XCTAssertEqual(upstream.level, .info, "an upstream failure keeps the cause's level")
    }

    func testUpstreamFailuresKeepTheirEvent() {
        XCTAssertEqual(
            HTTPProxyHandler.upstreamFailureReport("upstream.tunnel_failed", level: .error, for: ConnectionPoolError.upstreamResponseTimedOut).event,
            "upstream.tunnel_failed"
        )
        XCTAssertEqual(
            HTTPProxyHandler.upstreamFailureReport("upstream.exchange_failed", level: .error, for: ConnectionPoolError.noUpstreamsConfigured).event,
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
