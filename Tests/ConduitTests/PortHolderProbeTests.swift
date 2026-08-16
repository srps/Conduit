// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// A port conflict is only actionable if the user learns *what* holds the port.
/// The motivating case is a corporate proxy agent that claims Conduit's
/// listen port on every VPN reconnect: knowing the port is busy leaves the user
/// nowhere, knowing which process and pid holds it lets them decide whether to
/// stop it.
final class PortHolderProbeTests: XCTestCase {

    private func squat(on port: Int) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port)
            .get()
    }

    func testNamesTheProcessHoldingThePort() async throws {
        let listener = try await squat(on: 0)
        let port = try XCTUnwrap(listener.localAddress?.port)
        addTeardownBlock { _ = try? await listener.close().get() }

        let holder = try XCTUnwrap(
            PortHolderProbe().describeHolder(host: "127.0.0.1", port: port),
            "the probe must find a listener owned by this very process"
        )
        XCTAssertTrue(holder.contains("pid \(getpid())"), "should name the holding pid: \(holder)")
    }

    func testReturnsNilWhenNothingHoldsThePort() async throws {
        // Bind and release, so the port is known to have been free-able.
        let scout = try await squat(on: 0)
        let port = try XCTUnwrap(scout.localAddress?.port)
        _ = try? await scout.close().get()

        XCTAssertNil(
            PortHolderProbe().describeHolder(host: "127.0.0.1", port: port),
            "an unheld port has no holder to name"
        )
    }

    /// Only accept sockets count. An *established* connection also has a local
    /// port, and reporting one of those would name an innocent process — or
    /// this one — as the thing to go stop.
    func testIgnoresEstablishedConnections() async throws {
        let listener = try await squat(on: 0)
        let listenPort = try XCTUnwrap(listener.localAddress?.port)
        addTeardownBlock { _ = try? await listener.close().get() }

        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: listenPort)
            .get()
        let clientPort = try XCTUnwrap(client.localAddress?.port)
        addTeardownBlock { _ = try? await client.close().get() }

        XCTAssertNil(
            PortHolderProbe().describeHolder(host: "127.0.0.1", port: clientPort),
            "an established connection's local port is not a listener"
        )
    }

    /// The host is part of the conflict's identity. A machine can hold the same
    /// port on several loopback aliases at once — this app binds both
    /// `127.0.0.1` and `127.44.3.0` — and matching on port alone would name
    /// whichever process the scan reached first, pointing the user at an
    /// innocent process while the real conflict stands. Caught in review on #54.
    func testDoesNotNameAHolderOnADifferentAddress() async throws {
        let listener = try await squat(on: 0)
        let port = try XCTUnwrap(listener.localAddress?.port)
        addTeardownBlock { _ = try? await listener.close().get() }

        // 127.0.0.2 is a distinct loopback address that nothing here binds.
        XCTAssertNil(
            PortHolderProbe().describeHolder(host: "127.0.0.2", port: port),
            "a listener on 127.0.0.1 does not block a bind to 127.0.0.2"
        )
        XCTAssertNotNil(
            PortHolderProbe().describeHolder(host: "127.0.0.1", port: port),
            "the address it actually holds must still be reported"
        )
    }

    /// A wildcard bind occupies the port on every address, so it conflicts with
    /// whatever host the caller asked about.
    func testNamesAWildcardHolderForAnySpecificAddress() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "0.0.0.0", port: 0)
            .get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        addTeardownBlock { _ = try? await listener.close().get() }

        XCTAssertNotNil(
            PortHolderProbe().describeHolder(host: "127.0.0.1", port: port),
            "a 0.0.0.0 listener blocks a bind to any specific local address"
        )
    }

    /// End to end: the conflict a user actually hits carries the holder in the
    /// message, not just the address.
    func testBindConflictErrorNamesTheHolder() async throws {
        let squatter = try await squat(on: 0)
        let port = try XCTUnwrap(squatter.localAddress?.port)
        addTeardownBlock { _ = try? await squatter.close().get() }

        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = port

        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in ProbeNoOpAuthenticator() },
            directConnectDetector: DirectConnectDetector(
                group: MultiThreadedEventLoopGroup.singleton,
                logger: DiscardingLogSink()
            ),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            bindRetryLimit: 1,
            portHolderProbe: PortHolderProbe()
        )

        do {
            try await server.start()
            XCTFail("start should fail against an occupied port")
        } catch let error as ListenerBindError {
            guard case .addressInUse(_, _, _, let holder) = error else {
                return XCTFail("expected an address-in-use classification, got \(error)")
            }
            let named = try XCTUnwrap(holder, "the conflict must name its holder")
            XCTAssertTrue(named.contains("pid \(getpid())"), "holder should name the pid: \(named)")

            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains(named), "the user-facing message must carry the holder: \(message)")
            XCTAssertFalse(message.contains("lsof"), "no need to send the user hunting once we know: \(message)")
        }
    }
}

private final class ProbeNoOpAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "NoOp" }
    func initialToken(for host: String) throws -> String { "NoOp none" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}
