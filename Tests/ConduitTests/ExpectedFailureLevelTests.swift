// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import XCTest
@testable import ProxyKernel
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// #149: failures that only say a destination is absent, or that a client
/// closed its own tunnel, are not reported like path faults.
final class ExpectedFailureLevelTests: XCTestCase {
    private typealias ResolutionError = AddressFamilyAwareResolver.ResolutionError

    func testAbsentDestinations() {
        let refused = IOError(errnoCode: ECONNREFUSED, reason: "connect")
        XCTAssertTrue(AbsentDestination.matches(refused, host: "127.0.0.1"))
        XCTAssertTrue(AbsentDestination.matches(refused, host: "127.8.9.10"))
        XCTAssertTrue(AbsentDestination.matches(refused, host: "[::1]"))
        XCTAssertTrue(AbsentDestination.matches(refused, host: "localhost"))
        XCTAssertFalse(AbsentDestination.matches(refused, host: "10.0.0.1"), "a refusal elsewhere can be a firewall")
        XCTAssertFalse(AbsentDestination.matches(refused, host: "::2"))

        XCTAssertTrue(AbsentDestination.matches(ResolutionError(host: "gone.example", rc: EAI_NONAME), host: "gone.example"))
        XCTAssertTrue(AbsentDestination.matches(DirectIPv4FallbackError.noIPv4Address(host: "v6.example"), host: "v6.example"))
        XCTAssertFalse(AbsentDestination.matches(ResolutionError(host: "x.example", rc: EAI_AGAIN), host: "x.example"),
                       "a resolver that could not answer is not an absent name")
        XCTAssertFalse(AbsentDestination.matches(DirectIPv4FallbackError.resolutionTimedOut(host: "x.example"), host: "x.example"))

        let timeout = ChannelError.connectTimeout(.seconds(2))
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "probe.INVALID."), "the reserved TLD never exists")
        XCTAssertFalse(AbsentDestination.matches(timeout, host: "127.0.0.1"), "a loopback timeout is not a closed port")
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "169.254.169.254"), "no metadata endpoint off a cloud instance")
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "169.254.170.2"))
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "[fd00:ec2:0::254]"))
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "[::FFFF:A9FE:A9FE]"), "IPv4-mapped metadata address")
        XCTAssertTrue(AbsentDestination.matches(timeout, host: "::ffff:169.254.170.2"))
        XCTAssertFalse(AbsentDestination.matches(timeout, host: "::ffff:169.254.10.10"))
        XCTAssertFalse(AbsentDestination.matches(timeout, host: "169.254.10.10"), "a bridge peer behind a bad route is a path fault")
        XCTAssertFalse(AbsentDestination.matches(timeout, host: "[fe80::1%en0]"))
        XCTAssertFalse(AbsentDestination.matches(timeout, host: "10.0.0.1"), "a routed timeout can be a broken path")
        XCTAssertFalse(AbsentDestination.matches(IOError(errnoCode: ENETUNREACH, reason: "connect"), host: "169.254.169.254"),
                       "an unreachable network is a path fault even toward link-local")
    }

    func testDirectConnectReportLowersAbsentDestinationsAndNeverRaises() {
        let nxdomain = ResolutionError(host: "gone.example", rc: EAI_NONAME)
        let absent = DirectConnectFailure.report(nxdomain, host: "gone.example", default: .error)
        XCTAssertEqual(absent.event, "direct.connect_failed", "structured consumers still see the 502")
        XCTAssertEqual(absent.level, .warning)

        let offVPN = DirectConnectFailure.report(nxdomain, host: "gone.example", default: .info)
        XCTAssertEqual(offVPN.level, .info, "the direct-mode cause already lowered it")

        let timeout = DirectConnectFailure.report(
            ChannelError.connectTimeout(.seconds(2)), host: "example.test", default: .error)
        XCTAssertEqual(timeout.event, "direct.connect_failed")
        XCTAssertEqual(timeout.level, .error)

        let metadata = DirectConnectFailure.report(
            ChannelError.connectTimeout(.seconds(2)), host: "169.254.169.254", default: .error)
        XCTAssertEqual(metadata.event, "direct.connect_failed")
        XCTAssertEqual(metadata.level, .warning)

        let unreachable = DirectConnectFailure.report(
            IOError(errnoCode: ENETUNREACH, reason: "connect"), host: "example.test", default: .error)
        XCTAssertEqual(unreachable.event, "direct.connect_failed")
        XCTAssertEqual(unreachable.level, .error)
    }

    func testAbsentDestinationLogsAWarningAndKeepsItsEvent() {
        let logger = RecordingLogSink(minLevel: .debug)
        let events = RuntimeEventLog(capacity: 16)
        let error = IOError(errnoCode: ECONNREFUSED, reason: "connect")
        let report = DirectConnectFailure.report(error, host: "127.0.0.1", default: .error)
        HTTPProxyHandler.reportConnectFailure(
            report.event, level: report.level, target: "127.0.0.1:11434", error: error,
            message: "Direct connect to 127.0.0.1:11434 failed", logger: logger, eventSink: { events.append($0) }
        )
        XCTAssertEqual(logger.entries().map(\.level), [.warning])
        XCTAssertEqual(events.events.map(\.event), ["direct.connect_failed"])
    }

    func testRelayLevelBySide() {
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .client, errno: ECONNRESET), .info)
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .client, errno: EPIPE), .info)
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .client, errno: ETIMEDOUT), .warning)
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .client, errno: nil), .warning)
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .remote, errno: ECONNRESET), .warning)
        XCTAssertEqual(TunnelRelayDiagnostics.level(side: .remote, errno: ETIMEDOUT), .warning)
    }

    func testClientResetLogsAtInfoAndKeepsItsEvent() {
        let logger = RecordingLogSink(minLevel: .debug)
        let events = RuntimeEventLog(capacity: 16)
        let reporter = TunnelFailureReporter(logger: logger, eventSink: { events.append($0) })
        func relay(_ target: String) -> TunnelRelayDiagnostics {
            TunnelRelayDiagnostics(target: target, transport: "connect", route: "upstream", upstream: "upstream.example:8080",
                                   causeProvider: { .none }, reporter: reporter)
        }
        relay("client.example:443").failed(IOError(errnoCode: ECONNRESET, reason: "read"), on: .client)
        relay("remote.example:443").failed(IOError(errnoCode: ECONNRESET, reason: "read"), on: .remote)

        XCTAssertEqual(logger.entries().map(\.level), [.info, .warning])
        XCTAssertEqual(events.events.map(\.event), ["tunnel.relay_failed", "tunnel.relay_failed"])
    }
}
