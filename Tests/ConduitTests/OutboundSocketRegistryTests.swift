// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import ProxyKernel

final class OutboundSocketRegistryTests: XCTestCase {
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    /// The path verdict per local address; anything not listed is current.
    private let paths = NIOLockedValueBox<[String: SocketPathVerdict]>([:])

    private func makeRegistry(capacity: Int = 8) -> OutboundSocketRegistry {
        let events = self.events, paths = self.paths
        return OutboundSocketRegistry(
            capacity: { capacity },
            paths: ClosureSocketPaths { query in
                paths.withLockedValue { $0[query.local.ipAddress ?? ""] } ?? .current
            },
            retirementLog: ConnectFailureLog(
                logger: DiscardingLogSink(), eventSink: { event in events.withLockedValue { $0.append(event) } }
            )
        )
    }

    private func details(_ name: String) -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == name }.compactMap(\.detail)
    }

    private func channel(local: String = "192.168.2.20") throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000)
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 443)).wait()
        return channel
    }

    private func strand(_ local: String, _ label: String = "address_gone") {
        paths.withLockedValue { $0[local] = .stranded(label) }
    }

    @discardableResult
    private func open(_ registry: OutboundSocketRegistry, _ channel: Channel, route: OutboundSocketRegistry.Route = .direct) throws -> TransitionTicket {
        try registry.register(channel, route: route, target: "origin.test:443")
    }

    func testASweepClosesOnlySocketsWhosePathIsGone() throws {
        let registry = makeRegistry()
        let overVPN = try channel(local: "10.20.30.40")
        let upstreamOverVPN = try channel(local: "10.20.30.40")
        let overWiFi = try channel(local: "192.168.2.20")
        let unjudged = try channel(local: "192.168.2.21")
        let ticket = try open(registry, overVPN)
        try open(registry, upstreamOverVPN, route: .upstream)
        try open(registry, overWiFi)
        try open(registry, unjudged)
        strand("10.20.30.40")
        paths.withLockedValue { $0["192.168.2.21"] = .unknown("interfaces_unavailable") }

        XCTAssertEqual(registry.closeStranded(), .init(upstream: 1, direct: 1, unknown: 1))
        XCTAssertFalse(overVPN.isActive)
        XCTAssertTrue(ticket.isRetired)
        XCTAssertFalse(upstreamOverVPN.isActive)
        XCTAssertTrue(overWiFi.isActive)
        XCTAssertTrue(unjudged.isActive, "a socket the check cannot judge is left to its timeouts")
        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.closeStranded(), .init(unknown: 1), "a second pass finds nothing new")
    }

    /// A socket that connected over a path a transition then removed is
    /// closed when it registers, whenever its setup started.
    func testASocketWhosePathIsGoneWhenItRegistersIsRetired() throws {
        let registry = makeRegistry()
        strand("10.20.30.40", "interface_changed")
        let late = try channel(local: "10.20.30.40")
        XCTAssertThrowsError(try open(registry, late, route: .upstream)) {
            XCTAssertTrue(ConnectionPoolError.isVPNTransitionDuringConnect($0))
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure($0), "never retried, never fed to a breaker")
        }
        XCTAssertFalse(late.isActive)
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(details(LateDialRetired.event), [
            "target=origin.test:443 reason=\(LateDialRetired.pathGone("interface_changed")) kind=other",
        ])
    }

    /// A burst of retirements for one target is one event and a summary,
    /// not one event each: the event log is bounded and shared.
    func testABurstOfRetirementsForOneTargetCoalesces() throws {
        let registry = makeRegistry()
        strand("10.20.30.40")
        for _ in 0..<5 {
            XCTAssertThrowsError(try open(registry, try channel(local: "10.20.30.40")))
        }
        XCTAssertEqual(details(LateDialRetired.event).count, 1)
    }

    func testAClosedSocketLeavesTheRegistry() throws {
        let registry = makeRegistry()
        let socket = try channel()
        try open(registry, socket)
        try socket.close().wait()
        socket.embeddedEventLoop.run()
        XCTAssertEqual(registry.count, 0)
        strand("192.168.2.20")
        XCTAssertEqual(registry.closeStranded(), .init())
    }

    func testAFullRegistryClosesAndRefusesTheSocket() throws {
        let registry = makeRegistry(capacity: 1)
        let tracked = try channel(), overflow = try channel()
        try open(registry, tracked)
        XCTAssertThrowsError(try open(registry, overflow)) {
            XCTAssertTrue(ConnectionPoolError.isConnectionTrackingFull($0))
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure($0), "never retried, never fed to a breaker")
        }
        XCTAssertFalse(overflow.isActive, "no socket is left untracked")
        XCTAssertTrue(tracked.isActive)
        XCTAssertEqual(details(OutboundSocketRegistry.fullEvent).count, 1)
    }

    func testRoutingDirectClosesEveryUpstreamSocketAndNoDirectOne() throws {
        let registry = makeRegistry()
        let upstream = try channel(), direct = try channel()
        try open(registry, upstream, route: .upstream)
        try open(registry, direct)
        XCTAssertEqual(registry.closeUpstream(), 1)
        XCTAssertFalse(upstream.isActive)
        XCTAssertTrue(direct.isActive)
    }

    /// A socket with no addresses (not connected yet, or gone) is never
    /// judged.
    func testASocketWithoutAddressesIsNeverJudged() throws {
        let registry = makeRegistry()
        let unconnected = EmbeddedChannel()
        try open(registry, unconnected)
        paths.withLockedValue { $0[""] = .stranded("address_gone") }
        XCTAssertEqual(registry.closeStranded(), .init())
        XCTAssertEqual(registry.count, 1)
    }

    func testCapacityCountsEveryAdmissionBound() {
        var config = ProxyConfig()
        config.inboundConnectionMaxLimit = 100
        config.maxTunnelSessions = 10
        config.maxConnections = 7
        XCTAssertEqual(OutboundSocketRegistry.capacity(for: config), 100 + 100 + 10 + 14)
        config.maxConnections = .max
        XCTAssertEqual(OutboundSocketRegistry.capacity(for: config), .max)
        config.maxConnections = 0
        config.inboundConnectionMaxLimit = 0
        config.maxTunnelSessions = 0
        XCTAssertEqual(OutboundSocketRegistry.capacity(for: config), 1)
    }

    // MARK: - The machine's paths

    func testALoopbackSocketIsCurrent() throws {
        let query = SocketPathQuery(local: try SocketAddress(ipAddress: "127.0.0.1", port: 50_000),
                                    remote: try SocketAddress(ipAddress: "127.0.0.1", port: 443))
        XCTAssertEqual(SystemSocketPaths().verdicts(for: [query]), [.current])
    }

    func testAnUnassignedLocalAddressIsGone() throws {
        let query = SocketPathQuery(local: try SocketAddress(ipAddress: "192.0.2.77", port: 50_000),
                                    remote: try SocketAddress(ipAddress: "127.0.0.1", port: 443))
        XCTAssertEqual(SystemSocketPaths().verdicts(for: [query]), [.stranded("address_gone")])
    }

    /// A real connected socket is judged current on its own path.
    func testAConnectedLoopbackSocketIsCurrent() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let client = try await ClientBootstrap(group: group).connect(to: server.localAddress!).get()
        let query = SocketPathQuery(local: try XCTUnwrap(client.localAddress), remote: try XCTUnwrap(client.remoteAddress))
        XCTAssertEqual(SystemSocketPaths().verdicts(for: [query, query]), [.current, .current])
        try await client.close()
        try await server.close()
    }
}
