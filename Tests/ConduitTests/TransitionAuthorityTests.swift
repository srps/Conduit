// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class TransitionAuthorityTests: XCTestCase {
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    private func makeAuthority(capacity: Int = 8) -> TransitionAuthority {
        let events = self.events
        return TransitionAuthority(capacity: { capacity }, retirementLog: ConnectFailureLog(
            logger: DiscardingLogSink(), eventSink: { event in events.withLockedValue { $0.append(event) } }
        ))
    }

    private func details(_ name: String) -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == name }.compactMap(\.detail)
    }
    private func channel(local: String? = nil) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        if let local { channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000) }
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 443)).wait()
        return channel
    }

    /// Stamp and register with no transition in between.
    @discardableResult
    private func open(_ authority: TransitionAuthority, _ channel: Channel, route: TransitionAuthority.Route = .direct) throws -> TransitionTicket {
        try authority.register(channel, route: route, stamp: authority.stamp(), target: "origin.test:443")
    }

    func testReconnectClosesOnlyDirectSocketsOpenedWhileTheVPNWasDown() throws {
        let authority = makeAuthority()
        let onVPN = try channel()
        try open(authority, onVPN)
        authority.beginOutage()
        let offVPN = try channel(), upstream = try channel()
        let ticket = try open(authority, offVPN)
        try open(authority, upstream, route: .upstream)

        XCTAssertEqual(authority.endOutage(), 1)
        XCTAssertFalse(offVPN.isActive)
        XCTAssertTrue(ticket.isRetired)
        XCTAssertTrue(onVPN.isActive)
        XCTAssertTrue(upstream.isActive, "the reconnect leaves upstream sockets alone")
        XCTAssertEqual(authority.count, 2)
    }

    /// The outage follows the VPN state, not the direct-mode cause: a
    /// no-proxy or PAC-DIRECT dial while the probe is pending or on-prem
    /// leaves on the off-VPN path under cause `.none` (#148).
    func testTheReconnectSweepEndsTheOutageOnce() throws {
        let authority = makeAuthority()
        XCTAssertNil(authority.endOutage(), "no outage, no sweep")
        let before = authority.stamp()
        XCTAssertTrue(authority.isCurrent(before), "a failed end is no transition")
        authority.beginOutage()
        XCTAssertTrue(authority.stamp().whileVPNDown)
        XCTAssertNotNil(authority.endOutage())
        XCTAssertFalse(authority.stamp().whileVPNDown)
        XCTAssertNil(authority.endOutage())
    }

    func testAClosedSocketLeavesTheRegistry() throws {
        let authority = makeAuthority()
        authority.beginOutage()
        let socket = try channel()
        try open(authority, socket)
        try socket.close().wait()
        socket.embeddedEventLoop.run()
        XCTAssertEqual(authority.count, 0)
        XCTAssertEqual(authority.endOutage(), 0)
    }

    func testAFullRegistryClosesAndRefusesTheSocket() throws {
        let authority = makeAuthority(capacity: 1)
        let tracked = try channel(), overflow = try channel()
        try open(authority, tracked)
        XCTAssertThrowsError(try open(authority, overflow)) {
            XCTAssertTrue(ConnectionPoolError.isConnectionTrackingFull($0))
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure($0), "never retried, never fed to a breaker")
        }
        XCTAssertFalse(overflow.isActive, "no socket is left untracked")
        XCTAssertTrue(tracked.isActive)
        XCTAssertEqual(details(TransitionAuthority.fullEvent).count, 1)
    }

    func testDisconnectClosesSocketsWhoseLocalAddressLeftWithTheVPN() throws {
        let authority = makeAuthority()
        let overVPN = try channel(local: "10.20.30.40")
        let upstreamOverVPN = try channel(local: "10.20.30.40")
        let overWiFi = try channel(local: "192.168.2.20")
        let unknownLocal = try channel()
        for socket in [overVPN, overWiFi, unknownLocal] { try open(authority, socket) }
        try open(authority, upstreamOverVPN, route: .upstream)

        let result = authority.closeOrphaned(from: ["192.168.2.20", "127.0.0.1"])

        XCTAssertEqual(result, .init(upstream: 1, direct: 1))
        XCTAssertFalse(overVPN.isActive)
        XCTAssertFalse(upstreamOverVPN.isActive)
        XCTAssertTrue(overWiFi.isActive)
        XCTAssertTrue(unknownLocal.isActive, "no known local address is never treated as orphaned")
    }

    func testRoutingDirectClosesEveryUpstreamSocketAndNoDirectOne() throws {
        let authority = makeAuthority()
        let upstream = try channel(), direct = try channel()
        try open(authority, upstream, route: .upstream)
        try open(authority, direct)
        XCTAssertEqual(authority.closeUpstream(), 1)
        XCTAssertFalse(upstream.isActive)
        XCTAssertTrue(direct.isActive)
    }

    // MARK: - Setup that straddles a transition

    /// Every confirmed transition moves the generation, so a socket whose
    /// setup started before one is closed on arrival, whatever its route:
    /// it was routed for a network that is gone.
    func testASocketWhoseSetupStraddledAnyTransitionIsRetired() throws {
        let transitions: [(String, (TransitionAuthority) -> Void)] = [
            ("disconnect", { $0.beginOutage() }),
            ("address sweep", { _ = $0.closeOrphaned(from: []) }),
            ("routing sweep", { _ = $0.closeUpstream() }),
            ("reconnect", { $0.beginOutage(); _ = $0.endOutage() }),
        ]
        for (name, transition) in transitions {
            let authority = makeAuthority()
            let stamp = authority.stamp()
            transition(authority)
            XCTAssertFalse(authority.isCurrent(stamp), name)
            let late = try channel()
            XCTAssertThrowsError(try authority.register(late, route: .upstream, stamp: stamp, target: "origin.test:443"), name) {
                XCTAssertTrue(ConnectionPoolError.isVPNTransitionDuringConnect($0), name)
            }
            XCTAssertFalse(late.isActive, name)
            XCTAssertEqual(authority.count, 0, name)
        }
    }

    /// A stale disconnect report still closes sockets on gone addresses,
    /// but a newer state owns routing: setup begun under it stands.
    func testAStaleReportsAddressSweepRetiresNoSetup() throws {
        let authority = makeAuthority()
        let overVPN = try channel(local: "10.20.30.40")
        try open(authority, overVPN, route: .upstream)
        let stamp = authority.stamp()
        XCTAssertEqual(authority.closeOrphaned(from: ["127.0.0.1"], retiringSetup: false).upstream, 1)
        XCTAssertFalse(overVPN.isActive)
        XCTAssertTrue(authority.isCurrent(stamp))
        XCTAssertNoThrow(try authority.register(try channel(), route: .direct, stamp: stamp, target: "origin.test:443"))
    }

    func testARefusalBeforeTheDialIsReported() throws {
        let authority = makeAuthority()
        let stamp = authority.stamp()
        XCTAssertNil(authority.refusal(stamp, route: .direct, target: "origin.test:443"))
        authority.beginOutage()
        let refusal = authority.refusal(stamp, route: .direct, target: "origin.test:443")
        XCTAssertTrue(refusal.map(ConnectionPoolError.isVPNTransitionDuringConnect) ?? false)
        XCTAssertEqual(details(LateDialRetired.event), [
            "target=origin.test:443 reason=\(LateDialRetired.beforeDial) kind=other",
        ])
    }

    func testARetirementIsReportedWhenItHappens() throws {
        let authority = makeAuthority()
        let stamp = authority.stamp()
        authority.beginOutage()
        XCTAssertThrowsError(try authority.register(try channel(), route: .direct, stamp: stamp, target: "origin.test:443"))
        XCTAssertEqual(details(LateDialRetired.event), [
            "target=origin.test:443 reason=\(LateDialRetired.transition) kind=other",
        ])
    }

    /// A burst of retirements for one target is one event and a summary,
    /// not one event each: the event log is bounded and shared.
    func testABurstOfRetirementsForOneTargetCoalesces() throws {
        let authority = makeAuthority()
        let stamp = authority.stamp()
        authority.beginOutage()
        for _ in 0..<5 {
            XCTAssertThrowsError(try authority.register(try channel(), route: .direct, stamp: stamp, target: "origin.test:443"))
        }
        XCTAssertEqual(details(LateDialRetired.event).count, 1)
    }

    func testCapacityCountsEveryAdmissionBound() {
        var config = ProxyConfig()
        config.inboundConnectionMaxLimit = 100
        config.maxTunnelSessions = 10
        config.maxConnections = 7
        XCTAssertEqual(TransitionAuthority.capacity(for: config), 100 + 100 + 10 + 14)
        config.maxConnections = .max
        XCTAssertEqual(TransitionAuthority.capacity(for: config), .max)
        config.maxConnections = 0
        config.inboundConnectionMaxLimit = 0
        config.maxTunnelSessions = 0
        XCTAssertEqual(TransitionAuthority.capacity(for: config), 1)
    }

    func testLocalAddressesListsLoopback() throws {
        XCTAssertTrue(try LocalAddresses.assigned().contains("127.0.0.1"))
    }
}
