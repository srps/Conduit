// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import ProxyKernel

/// Regression coverage for the `ERR_CONNECTION_CLOSED` (ENOTCONN on first
/// write) failure mode observed on VPN-on dual-stack networks where NIO's
/// `HappyEyeballsConnector` returns a half-open IPv6 channel. The channel
/// reports `isActive: true` but has `remoteAddress: nil` because the kernel
/// never completed the TCP handshake — writes fail with errno 57 and the
/// browser sees a collapsed tunnel.
///
/// The production fix lives in `HTTPProxyHandler.applyHalfOpenFallback` +
/// `HTTPProxyHandler.resolveIPv4`. These tests pin the two contracts they
/// rely on:
///
/// 1. Half-open detection + pass-through branch (`remoteAddress != nil` →
///    return the original channel unchanged; the IPv4 fallback is NOT
///    invoked).
/// 2. Half-open detection + fallback branch (`remoteAddress == nil` → close
///    the bogus channel, resolve `host` via `getaddrinfo(AF_INET)`, and call
///    the injected `ipv4Reconnect` with a first-A-record `SocketAddress`).
/// 3. `resolveIPv4` successfully returns an IPv4 loopback address for
///    `localhost` and fails with `DirectIPv4FallbackError.resolutionFailed`
///    for an obviously-invalid host.
/// 4. `DirectIPv4FallbackError.errorDescription` produces the human-readable
///    strings surfaced to users on bad-gateway responses.
final class DirectIPv4FallbackTests: XCTestCase {

    // MARK: - Error descriptions

    func testErrorDescription_resolutionFailed() {
        let err = DirectIPv4FallbackError.resolutionFailed(host: "example.invalid", rc: -1)
        XCTAssertEqual(
            err.errorDescription,
            "IPv4 fallback resolution failed for example.invalid (getaddrinfo rc=-1)"
        )
    }

    func testErrorDescription_noIPv4Address() {
        let err = DirectIPv4FallbackError.noIPv4Address(host: "ipv6only.invalid")
        XCTAssertEqual(
            err.errorDescription,
            "IPv4 fallback: ipv6only.invalid has no A record"
        )
    }

    func testErrorDescription_resolutionTimedOut() {
        let err = DirectIPv4FallbackError.resolutionTimedOut(host: "slow.example.com")
        XCTAssertEqual(
            err.errorDescription,
            "IPv4 fallback resolution timed out for slow.example.com"
        )
    }

    // MARK: - resolveIPv4

    /// `localhost` is guaranteed to resolve to `127.0.0.1` via the system
    /// resolver on every supported platform (no DNS dependency), so this
    /// test has no flakiness.
    func testResolveIPv4_localhost_returnsLoopbackIPv4() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        let address = try await HTTPProxyHandler
            .resolveIPv4(host: "localhost", port: 8443, on: loop)
            .get()

        XCTAssertEqual(address.ipAddress, "127.0.0.1")
        XCTAssertEqual(address.port, 8443)
        if case .v4 = address {
            // expected
        } else {
            XCTFail("Expected SocketAddress.v4 for localhost, got \(address)")
        }
    }

    /// An obviously-nonexistent hostname must surface a
    /// `DirectIPv4FallbackError.resolutionFailed` (not crash, not hang, not
    /// resolve to something else). `.invalid` is the RFC 2606 / RFC 6761
    /// reserved TLD guaranteed never to resolve.
    func testResolveIPv4_invalidHost_returnsResolutionFailedError() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        do {
            _ = try await HTTPProxyHandler
                .resolveIPv4(host: "this-host-definitely-does-not-exist.invalid", port: 443, on: loop)
                .get()
            XCTFail("Expected resolveIPv4 to fail for .invalid hostname")
        } catch let err as DirectIPv4FallbackError {
            switch err {
            case .resolutionFailed(let host, _):
                XCTAssertEqual(host, "this-host-definitely-does-not-exist.invalid")
            case .noIPv4Address:
                XCTFail("Expected .resolutionFailed for a host getaddrinfo rejects outright, got .noIPv4Address")
            case .resolutionTimedOut:
                XCTFail("Expected .resolutionFailed, got .resolutionTimedOut")
            }
        } catch {
            XCTFail("Expected DirectIPv4FallbackError, got \(error)")
        }
    }

    // MARK: - applyHalfOpenFallback

    /// When the channel returned by happy-eyeballs has a valid
    /// `remoteAddress`, the fallback MUST NOT fire and the original channel
    /// MUST be passed through unchanged. This is the hot path — any overhead
    /// here would cost every direct CONNECT.
    func testApplyHalfOpenFallback_validRemoteAddress_passesThroughWithoutFallback() async throws {
        let group = MultiThreadedEventLoopGroup.singleton

        // Stand up a real loopback listener so we get a genuine client channel
        // with `remoteAddress` set — `EmbeddedChannel` can't provide one.
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()

        let clientChannel = try await ClientBootstrap(group: group)
            .connect(to: server.localAddress!).get()

        XCTAssertNotNil(clientChannel.remoteAddress,
                        "Loopback client channel must have a valid remoteAddress")

        // Use a synchronization-safe witness to detect whether the fallback
        // got invoked. It must NOT have.
        actor FallbackWitness { var invoked = false; func mark() { invoked = true } }
        let witness = FallbackWitness()

        let clientEL = clientChannel.eventLoop
        let result = try await HTTPProxyHandler.applyHalfOpenFallback(
            upstreamChannel: clientChannel,
            host: "127.0.0.1",
            port: 443,
            on: clientEL,
            ipv4Reconnect: { _ in
                Task { await witness.mark() }
                return clientEL.makeFailedFuture(ChannelError.alreadyClosed)
            }
        ).get()

        let fallbackFired = await witness.invoked
        XCTAssertFalse(fallbackFired,
                       "Fallback must NOT fire for channels with non-nil remoteAddress")
        XCTAssertTrue(result === clientChannel,
                      "Pass-through must return the original channel identity")

        _ = try await clientChannel.close().get()
        _ = try await server.close().get()
    }

    /// Half-open models the ENOTCONN bug: `remoteAddress == nil` on a
    /// channel NIO's ClientBootstrap reported as succeeding. `EmbeddedChannel`
    /// is the canonical "no remote" channel we can build in a test without
    /// reaching into NIO's happy-eyeballs internals.
    ///
    /// Expected behaviour:
    /// - The bogus channel is closed (not leaked forward to `attachDirectTunnel`).
    /// - `resolveIPv4` is invoked and the caller's `ipv4Reconnect` closure
    ///   is called with an IPv4 SocketAddress derived from `host`.
    /// - The final future resolves to whatever `ipv4Reconnect` returns.
    func testApplyHalfOpenFallback_nilRemoteAddress_fallsBackToIPv4Reconnect() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        let embeddedLoop = EmbeddedEventLoop()
        let halfOpen = EmbeddedChannel(loop: embeddedLoop)
        // Confirm the precondition we're modelling.
        XCTAssertNil(halfOpen.remoteAddress,
                     "EmbeddedChannel models the half-open bug by having nil remoteAddress")

        // Build a "replacement" channel that `ipv4Reconnect` will hand back.
        // It must be distinct from `halfOpen` so the identity assertion below
        // is meaningful.
        let replacementLoop = EmbeddedEventLoop()
        let replacement = EmbeddedChannel(loop: replacementLoop)

        struct WitnessState {
            var invoked = false
            var address: SocketAddress?
        }
        let witness = NIOLockedValueBox(WitnessState())

        let result = try await HTTPProxyHandler.applyHalfOpenFallback(
            upstreamChannel: halfOpen,
            host: "localhost",  // resolves via getaddrinfo to 127.0.0.1
            port: 443,
            on: loop,
            ipv4Reconnect: { address in
                witness.withLockedValue { $0.invoked = true; $0.address = address }
                return loop.makeSucceededFuture(replacement as Channel)
            }
        ).get()

        let fired = witness.withLockedValue { $0.invoked }
        let receivedAddress = witness.withLockedValue { $0.address }
        XCTAssertTrue(fired, "Fallback MUST fire when the channel has nil remoteAddress")
        XCTAssertEqual(receivedAddress?.ipAddress, "127.0.0.1",
                       "Fallback must reach ipv4Reconnect with a resolved IPv4 SocketAddress")
        XCTAssertEqual(receivedAddress?.port, 443)
        XCTAssertTrue(result === replacement,
                      "Final channel must be the one returned by ipv4Reconnect, not the bogus half-open one")
    }

    /// Pairs with the error-path coverage: if the fallback's getaddrinfo
    /// call fails, that failure must propagate as a `DirectIPv4FallbackError`
    /// — `ipv4Reconnect` MUST NOT be invoked with a bogus address, and the
    /// caller sees a structured error (not a crash or ENOTCONN leaking
    /// through).
    func testApplyHalfOpenFallback_nilRemoteAddress_resolutionFailure_surfacesFallbackError() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        let embeddedLoop = EmbeddedEventLoop()
        let halfOpen = EmbeddedChannel(loop: embeddedLoop)

        actor Witness { var invoked = false; func mark() { invoked = true } }
        let witness = Witness()

        do {
            _ = try await HTTPProxyHandler.applyHalfOpenFallback(
                upstreamChannel: halfOpen,
                host: "this-host-definitely-does-not-exist.invalid",
                port: 443,
                on: loop,
                ipv4Reconnect: { _ in
                    Task { await witness.mark() }
                    return loop.makeFailedFuture(ChannelError.alreadyClosed)
                }
            ).get()
            XCTFail("Expected a DirectIPv4FallbackError from the resolveIPv4 stage")
        } catch let err as DirectIPv4FallbackError {
            switch err {
            case .resolutionFailed(let host, _):
                XCTAssertEqual(host, "this-host-definitely-does-not-exist.invalid")
            case .noIPv4Address:
                XCTFail("Expected .resolutionFailed, got .noIPv4Address")
            case .resolutionTimedOut:
                XCTFail("Expected .resolutionFailed, got .resolutionTimedOut")
            }
        } catch {
            XCTFail("Expected DirectIPv4FallbackError, got \(error)")
        }

        let fired = await witness.invoked
        XCTAssertFalse(fired, "ipv4Reconnect must NOT fire when getaddrinfo itself fails")
    }
}
