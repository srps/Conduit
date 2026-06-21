// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import XCTest
@testable import ProxyKernel

/// Regression coverage for the Edge `ERR_TUNNEL_CONNECTION_FAILED` flood seen in
/// VPN-off / direct-mode sessions, where `attachDirectTunnel` raced against the
/// client closing the CONNECT socket mid-setup. The old code logged the
/// resulting `ChannelPipelineError.notFound` at `.error`, surfacing the opaque
/// "Direct tunnel setup failed: … ChannelPipelineError error 1." line without
/// any signal that the failure is a normal browser-disconnect race rather than
/// a proxy bug.
///
/// `HTTPProxyHandler.isBenignTunnelSetupRace` is the new classifier that
/// demotes those races to the cause-derived severity. These tests pin its
/// contract so future refactors don't regress the classification.
final class DirectTunnelSetupRaceTests: XCTestCase {

    // MARK: - Pipeline-lookup races (the original Edge failure mode)

    func testPipelineNotFoundIsBenign() {
        // `removeHandler(name:)` fails with `.notFound` when the client-side
        // pipeline has already been torn down — i.e. the browser closed the
        // CONNECT before we finished splicing. Treating this as `.error`
        // scared users into thinking the proxy was broken.
        XCTAssertTrue(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelPipelineError.notFound))
    }

    func testPipelineAlreadyRemovedIsBenign() {
        // Paired case: a concurrent removal (unlikely in practice, but NIO
        // exposes it) should be treated identically — it's still "the pipeline
        // isn't in the shape we expected because somebody else already
        // cleaned it up."
        XCTAssertTrue(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelPipelineError.alreadyRemoved))
    }

    // MARK: - Closed-channel races (writing 200 OK to a gone socket)

    func testIOOnClosedChannelIsBenign() {
        // The inline `write(.head)` happens on a context whose channel can go
        // inactive any time; if it does, the subsequent `writeAndFlush(.end)`
        // fails with `.ioOnClosedChannel`. Same root cause as the pipeline
        // race — client closed first.
        XCTAssertTrue(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelError.ioOnClosedChannel))
    }

    func testAlreadyClosedIsBenign() {
        XCTAssertTrue(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelError.alreadyClosed))
    }

    func testEofIsBenign() {
        // EOF on the client socket during the setup window is the TCP-level
        // version of the same story: remote peer went away.
        XCTAssertTrue(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelError.eof))
    }

    // MARK: - Genuine failures must still surface as errors

    func testChannelConnectTimeoutIsNotBenign() {
        // Connect timeouts are a real upstream problem worth investigating —
        // they indicate the target is unreachable, not that the client gave
        // up. Keep `.error` severity.
        XCTAssertFalse(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelError.connectTimeout(.seconds(10))))
    }

    func testOperationUnsupportedIsNotBenign() {
        // Misuse of the Channel API. Not something that should happen under
        // normal browser disconnect; keep it loud.
        XCTAssertFalse(HTTPProxyHandler.isBenignTunnelSetupRace(ChannelError.operationUnsupported))
    }

    func testArbitraryErrorIsNotBenign() {
        struct SomeRandomError: Error {}
        XCTAssertFalse(HTTPProxyHandler.isBenignTunnelSetupRace(SomeRandomError()))
    }

    func testNSErrorLookingLikeChannelPipelineErrorIsNotBenign() {
        // The original log line read "NIOCore.ChannelPipelineError error 1."
        // because `NSError` bridging prints the enum discriminator. Make sure
        // a raw `NSError` with the same domain+code doesn't sneak through
        // classification — we key on the Swift enum type, not its string form.
        let mimic = NSError(domain: "NIOCore.ChannelPipelineError", code: 1)
        XCTAssertFalse(HTTPProxyHandler.isBenignTunnelSetupRace(mimic))
    }
}
