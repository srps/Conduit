// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import ProxyKernel

final class HTTPUpgradeRelayTests: XCTestCase {

    // MARK: - Upgrade request detection

    func testIsUpgradeRequestRequiresBothHeaders() {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://ws.example/chat")
        XCTAssertFalse(HTTPHopByHopHeaders.isUpgradeRequest(head))

        head.headers.add(name: "Upgrade", value: "websocket")
        XCTAssertFalse(HTTPHopByHopHeaders.isUpgradeRequest(head), "Upgrade without Connection token is not an upgrade request")

        head.headers.add(name: "Connection", value: "Upgrade")
        XCTAssertTrue(HTTPHopByHopHeaders.isUpgradeRequest(head))
    }

    func testIsUpgradeRequestHandlesMultiTokenConnectionCaseInsensitively() {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://ws.example/chat")
        head.headers.add(name: "Upgrade", value: "websocket")
        head.headers.add(name: "Connection", value: "keep-alive, UPGRADE")
        XCTAssertTrue(HTTPHopByHopHeaders.isUpgradeRequest(head))
    }

    func testIsUpgradeRequestFalseForConnectionWithoutUpgradeToken() {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://ws.example/chat")
        head.headers.add(name: "Upgrade", value: "websocket")
        head.headers.add(name: "Connection", value: "keep-alive")
        XCTAssertFalse(HTTPHopByHopHeaders.isUpgradeRequest(head))
    }

    // MARK: - Upgrade-preserving sanitization

    func testGenericSanitizerStripsUpgradeButUpgradeVariantPreservesIt() {
        var stripped: HTTPHeaders = [
            "Host": "ws.example",
            "Upgrade": "websocket",
            "Connection": "keep-alive, Upgrade",
            "Sec-WebSocket-Key": "x3JJHMbDL1EzLkh9GBhXDw==",
            "Sec-WebSocket-Version": "13",
        ]
        var preserved = stripped

        HTTPHopByHopHeaders.sanitizeForwardedRequestHeaders(&stripped)
        XCTAssertTrue(stripped["Upgrade"].isEmpty, "generic sanitizer must strip Upgrade")

        HTTPHopByHopHeaders.sanitizeForwardedUpgradeRequestHeaders(&preserved)
        XCTAssertEqual(preserved["Upgrade"], ["websocket"])
        XCTAssertEqual(preserved["Connection"], ["upgrade"])
        XCTAssertEqual(preserved["Sec-WebSocket-Key"], ["x3JJHMbDL1EzLkh9GBhXDw=="], "end-to-end headers survive")
    }

    func testUpgradeResponseSanitizerPreservesUpgradeAndConnection() {
        var headers: HTTPHeaders = [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": "HSmrc0sMlYUkAGmm5OPpG2HaGWk=",
        ]
        HTTPHopByHopHeaders.sanitizeForwardedUpgradeResponseHeaders(&headers)
        XCTAssertEqual(headers["Upgrade"], ["websocket"])
        XCTAssertEqual(headers["Connection"], ["upgrade"])
        XCTAssertEqual(headers["Sec-WebSocket-Accept"], ["HSmrc0sMlYUkAGmm5OPpG2HaGWk="])
    }

    // MARK: - Relay splice on 101

    /// A no-op stand-in for `HTTPProxyHandler` on the client pipeline; the
    /// splice removes it by its registered name.
    private final class NoOpServerHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = NIOAny
    }

    private struct UpgradeFixture {
        let loop: EmbeddedEventLoop
        let client: EmbeddedChannel
        let upstream: EmbeddedChannel
    }

    private func makeFixture(
        onTunnelEstablished: @escaping @Sendable () -> Void = {},
        onRefusedResponseComplete: @escaping @Sendable () -> Void = {},
        onFailure: @escaping @Sendable () -> Void = {},
        onTunnelClosed: @escaping @Sendable () -> Void = {}
    ) throws -> UpgradeFixture {
        let loop = EmbeddedEventLoop()
        let client = EmbeddedChannel(loop: loop)
        try client.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
            name: ProxyPipelineNames.serverDecoder)
        try client.pipeline.syncOperations.addHandler(
            HTTPResponseEncoder(), name: ProxyPipelineNames.serverEncoder)
        try client.pipeline.syncOperations.addHandler(
            HTTPExpectContinueHandler(), name: ProxyPipelineNames.serverExpectContinue)
        try client.pipeline.syncOperations.addHandler(
            NoOpServerHandler(), name: ProxyPipelineNames.serverHandler)

        let upstream = EmbeddedChannel(loop: loop)
        try upstream.pipeline.syncOperations.addHandler(
            HTTPRequestEncoder(), name: UpgradePipelineNames.upstreamEncoder)
        try upstream.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
            name: UpgradePipelineNames.upstreamDecoder)
        let relay = HTTPUpgradeResponseRelay(
            clientChannel: client,
            targetDescription: "ws.example:80",
            logger: DiscardingLogSink(),
            failureLevel: .info,
            onTunnelEstablished: onTunnelEstablished,
            onRefusedResponseComplete: onRefusedResponseComplete,
            onFailure: onFailure,
            onTunnelClosed: onTunnelClosed
        )
        try upstream.pipeline.syncOperations.addHandler(relay)

        // The response decoder pairs with the request encoder: it must see
        // the outbound request before it will parse a response, exactly as
        // the production flow writes the upgrade request first.
        var reqHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/chat")
        reqHead.headers.add(name: "Host", value: "ws.example")
        reqHead.headers.add(name: "Upgrade", value: "websocket")
        reqHead.headers.add(name: "Connection", value: "upgrade")
        try upstream.writeOutbound(HTTPClientRequestPart.head(reqHead))
        try upstream.writeOutbound(HTTPClientRequestPart.end(nil))
        while let _: ByteBuffer = try upstream.readOutbound() {}

        return UpgradeFixture(loop: loop, client: client, upstream: upstream)
    }

    private func drainClientOutput(_ client: EmbeddedChannel) throws -> String {
        var collected = ""
        while let out: ByteBuffer = try client.readOutbound() {
            collected += String(buffer: out)
        }
        return collected
    }

    func testRelaySplicesOn101AndForwardsLeftoverBytes() throws {
        nonisolated(unsafe) var established = false
        let fixture = try makeFixture(onTunnelEstablished: { established = true })

        // 101 plus a frame the origin sent in the same flight: the leftover
        // bytes must reach the client raw, after the encoded 101.
        var raw = fixture.upstream.allocator.buffer(capacity: 256)
        raw.writeString(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: HSmrc0sMlYUkAGmm5OPpG2HaGWk=\r\n" +
            "\r\n" +
            "EARLY-FRAME")
        try fixture.upstream.writeInbound(raw)
        fixture.loop.run()

        let clientSaw = try drainClientOutput(fixture.client)
        XCTAssertTrue(clientSaw.contains("101 Switching Protocols"), "client must receive the 101")
        XCTAssertTrue(clientSaw.contains("Upgrade: websocket"), "Upgrade header must survive the relay")
        XCTAssertTrue(clientSaw.hasSuffix("EARLY-FRAME"), "decoder leftovers must be relayed raw after the 101; got: \(clientSaw)")
        XCTAssertTrue(established, "tunnel-established callback must fire")

        // Post-splice: raw bytes flow both directions.
        var clientFrame = fixture.client.allocator.buffer(capacity: 16)
        clientFrame.writeString("CLIENT-FRAME")
        try fixture.client.writeInbound(clientFrame)
        fixture.loop.run()
        let upstreamSaw: ByteBuffer? = try fixture.upstream.readOutbound()
        XCTAssertEqual(upstreamSaw.map { String(buffer: $0) }, "CLIENT-FRAME")

        var originFrame = fixture.upstream.allocator.buffer(capacity: 16)
        originFrame.writeString("ORIGIN-FRAME")
        try fixture.upstream.writeInbound(originFrame)
        fixture.loop.run()
        let clientSaw2 = try drainClientOutput(fixture.client)
        XCTAssertEqual(clientSaw2, "ORIGIN-FRAME")

        try? fixture.client.close().wait()
        try? fixture.upstream.close().wait()
    }

    func testRelayForwardsRefusedUpgradeAndCloses() throws {
        nonisolated(unsafe) var refusalCompleted = false
        nonisolated(unsafe) var failed = false
        let fixture = try makeFixture(
            onRefusedResponseComplete: { refusalCompleted = true },
            onFailure: { failed = true }
        )

        var raw = fixture.upstream.allocator.buffer(capacity: 256)
        raw.writeString(
            "HTTP/1.1 403 Forbidden\r\n" +
            "Content-Length: 6\r\n" +
            "\r\n" +
            "denied")
        try fixture.upstream.writeInbound(raw)
        fixture.loop.run()

        let clientSaw = try drainClientOutput(fixture.client)
        XCTAssertTrue(clientSaw.contains("403 Forbidden"))
        XCTAssertTrue(clientSaw.contains("Connection: close"), "refused upgrade must not return to keep-alive")
        XCTAssertTrue(clientSaw.hasSuffix("denied"))
        XCTAssertTrue(refusalCompleted)
        XCTAssertFalse(failed)
        XCTAssertFalse(fixture.client.isActive, "client connection closes after a refused upgrade")
        XCTAssertFalse(fixture.upstream.isActive)
    }

    func testRelayFailsWhenOriginClosesBeforeResponding() throws {
        nonisolated(unsafe) var failed = false
        let fixture = try makeFixture(onFailure: { failed = true })

        fixture.upstream.pipeline.fireChannelInactive()
        fixture.loop.run()

        XCTAssertTrue(failed, "origin closing mid-handshake must surface as a failure")
        XCTAssertFalse(fixture.client.isActive)
    }
}
