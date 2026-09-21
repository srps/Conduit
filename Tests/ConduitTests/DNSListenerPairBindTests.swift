// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// With `port: 0` the forwarder binds UDP first and puts TCP on the number UDP
/// got. An ephemeral UDP port does not reserve the TCP port of the same
/// number, so another socket may already hold it (#57). The forwarder used to
/// log a warning and serve UDP only, and everything that read
/// `tcpListeningPort` afterwards depended on luck.
///
/// The kernel's choice of ephemeral port cannot be steered, so these tests use
/// the forwarder's `willBindTCP` hook to take the TCP port in the gap, with a
/// real listener and so a real `EADDRINUSE`.
final class DNSListenerPairBindTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    /// Holds listeners on TCP ports the forwarder is about to ask for.
    private final class Squatter: Sendable {
        private let group: EventLoopGroup
        private let held = NIOLockedValueBox<[Channel]>([])
        private let seen = NIOLockedValueBox<[Int]>([])

        init(group: EventLoopGroup) { self.group = group }

        var ports: [Int] { seen.withLockedValue { $0 } }

        func take(_ port: Int) async {
            seen.withLockedValue { $0.append(port) }
            // `SO_REUSEADDR` lets this bind succeed over a connection in
            // `TIME_WAIT` on the same local port, which a test run leaves all
            // over the ephemeral range; without it the squatter fails where
            // the forwarder, which sets the option, would not. Once this
            // socket listens, the option no longer helps the forwarder. If
            // the bind fails anyway, a stranger is already listening there,
            // and the forwarder meets the same `EADDRINUSE` from them.
            let channel = try? await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: port)
                .get()
            if let channel { held.withLockedValue { $0.append(channel) } }
        }

        func releaseAll() async {
            for channel in held.withLockedValue({ let all = $0; $0 = []; return all }) {
                _ = try? await channel.close().get()
            }
        }
    }

    private func makeForwarder(
        events: NIOLockedValueBox<[RuntimeEvent]>,
        willBindTCP: @escaping @Sendable (Int) async -> Void
    ) -> LocalDNSForwarder {
        let config = ProxyConfig.testFixture()
        return LocalDNSForwarder(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            willBindTCP: willBindTCP
        )
    }

    @MainActor
    func testAnEphemeralPortWhoseTCPSideIsTakenIsBoundAgainAsAPair() async throws {
        let squatter = Squatter(group: group)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = makeForwarder(events: events) { port in
            if squatter.ports.isEmpty { await squatter.take(port) }
        }
        addTeardownBlock {
            await forwarder.stop()
            await squatter.releaseAll()
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)

        let taken = try XCTUnwrap(squatter.ports.first)
        let udpPort = try XCTUnwrap(forwarder.listeningPort)
        let tcpPort = try XCTUnwrap(forwarder.tcpListeningPort, "the pair must be bound again, not left UDP-only")
        XCTAssertEqual(udpPort, tcpPort)
        XCTAssertNotEqual(udpPort, taken)

        let seen = events.withLockedValue { $0 }
        XCTAssertEqual(seen.map(\.event), ["dns.listener_port_retry"])
        XCTAssertEqual(seen.first?.kind, .health)
        XCTAssertEqual(
            seen.first?.detail,
            "port=\(taken) attempt=1 of=\(LocalDNSForwarder.ephemeralPairAttempts) reason=tcp_port_in_use"
        )
    }

    /// The UDP socket of an abandoned attempt must be closed, not left bound
    /// and answering beside the pair that replaced it.
    @MainActor
    func testTheAbandonedUDPPortIsReleased() async throws {
        let squatter = Squatter(group: group)
        let forwarder = makeForwarder(events: NIOLockedValueBox([])) { port in
            if squatter.ports.isEmpty { await squatter.take(port) }
        }
        addTeardownBlock {
            await forwarder.stop()
            await squatter.releaseAll()
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)

        let taken = try XCTUnwrap(squatter.ports.first)
        let probe = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: taken).get()
        try await probe.close().get()
    }

    @MainActor
    func testStartFailsLoudlyWhenNoEphemeralPairIsFree() async throws {
        let squatter = Squatter(group: group)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = makeForwarder(events: events) { port in await squatter.take(port) }
        addTeardownBlock {
            await forwarder.stop()
            await squatter.releaseAll()
        }

        let attempts = LocalDNSForwarder.ephemeralPairAttempts
        do {
            try await forwarder.start(host: "127.0.0.1", port: 0)
            XCTFail("start must not settle for UDP only when it was asked for any port")
        } catch let error as DNSForwarderStartError {
            XCTAssertEqual(error, .noEphemeralPortPair(host: "127.0.0.1", attempts: attempts))
        }

        XCTAssertEqual(squatter.ports.count, attempts, "the attempts are bounded")
        XCTAssertNil(forwarder.listeningPort)
        XCTAssertNil(forwarder.tcpListeningPort)

        let seen = events.withLockedValue { $0 }
        XCTAssertEqual(
            seen.map(\.event),
            Array(repeating: "dns.listener_port_retry", count: attempts - 1) + ["dns.tcp_listener_unavailable"]
        )
        let last = try XCTUnwrap(squatter.ports.last)
        XCTAssertEqual(seen.last?.detail, "port=\(last) outcome=start_failed attempts=\(attempts)")

        // Every abandoned UDP socket is closed, the last one included.
        for port in squatter.ports {
            let probe = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            try await probe.close().get()
        }
    }

    /// A configured port keeps what it always did: another port is not what
    /// the user asked for, and a resolver serving UDP beats one that refused
    /// to start. It now says so in an event as well as a warning.
    @MainActor
    func testAConfiguredPortWhoseTCPSideIsTakenStillServesUDP() async throws {
        let squatter = Squatter(group: group)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = makeForwarder(events: events) { port in await squatter.take(port) }
        addTeardownBlock {
            await forwarder.stop()
            await squatter.releaseAll()
        }

        // Borrow a number the kernel considers free on UDP right now.
        let scout = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(scout.localAddress?.port)
        try await scout.close().get()

        try await forwarder.start(host: "127.0.0.1", port: port)

        XCTAssertEqual(squatter.ports, [port], "a configured port is tried once")
        XCTAssertEqual(forwarder.listeningPort, port)
        XCTAssertNil(forwarder.tcpListeningPort)

        let seen = events.withLockedValue { $0 }
        XCTAssertEqual(seen.map(\.event), ["dns.tcp_listener_unavailable"])
        XCTAssertTrue(
            seen.first?.detail?.hasPrefix("port=\(port) outcome=udp_only error=") == true,
            "got: \(seen.first?.detail ?? "nil")"
        )
    }
}
