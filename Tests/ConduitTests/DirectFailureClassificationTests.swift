// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #100 end to end through the HTTP listener: a direct CONNECT whose origin
/// does not resolve completes as an origin failure and is logged once; a
/// CONNECT the upstream refuses completes as an upstream failure.
final class DirectFailureClassificationTests: XCTestCase {
    private let stormHost = "storm.conduit-direct-failure.invalid"

    func testDirectNXDOMAINIsAnOriginFailureAndUpstreamRefusalIsAnUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let closed = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let deadUpstreamPort = closed.localAddress!.port!
        try await closed.close().get()

        var config = ProxyConfig.testFixture()
        config.localPort = 0
        config.socksEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "dead", host: "127.0.0.1", port: deadUpstreamPort, priority: 0)]
        config.noProxyHosts = [stormHost]
        let capturedConfig = config

        let logger = RecordingLogSink(minLevel: .info)
        let outcomes = NIOLockedValueBox<[RequestOutcome]>([])
        let events = RuntimeEventLog(capacity: 256)
        let server = LocalProxyServer(
            logger: logger,
            configProvider: { capturedConfig },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in ClassificationTestAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink()),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { outcome, _ in outcomes.withLockedValue { $0.append(outcome) } },
            eventSink: { events.append($0) }
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try XCTUnwrap(server.listeningPort)

        let storm = 30
        var clients: [Channel] = []
        for _ in 0..<storm {
            clients.append(try await sendConnect(to: "\(stormHost):443", proxyPort: port, group: group))
        }
        try await waitForOutcomes(storm, outcomes)
        XCTAssertEqual(outcomes.withLockedValue { $0 }, Array(repeating: .failed(.origin), count: storm))
        let stormLines = logger.entries().filter { $0.message.hasPrefix("Direct connect to \(stormHost):443 failed") }
        XCTAssertEqual(stormLines.count, 1, "the storm is logged once; the rest wait for the interval's summary")
        XCTAssertEqual(events.events.filter { $0.event == "direct.connect_failed" }.count, 1)

        clients.append(try await sendConnect(to: "example.test:443", proxyPort: port, group: group))
        try await waitForOutcomes(storm + 1, outcomes)
        XCTAssertEqual(outcomes.withLockedValue { $0.last }, .failed(.upstream))

        for client in clients { client.close(promise: nil) }
    }

    private func sendConnect(to target: String, proxyPort: Int, group: EventLoopGroup) async throws -> Channel {
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: proxyPort).get()
        let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer).get()
        return client
    }

    /// Counts completions rather than timing them; the deadline only keeps
    /// a regression from hanging the suite.
    private func waitForOutcomes(_ expected: Int, _ outcomes: NIOLockedValueBox<[RequestOutcome]>) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while outcomes.withLockedValue({ $0.count }) < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(outcomes.withLockedValue { $0.count }, expected, "requests did not all complete")
    }
}

private final class ClassificationTestAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate test-token" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { "Negotiate test-response" }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}
