// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

/// WebSocket-style HTTP/1.1 Upgrade relayed by the proxy.
///
/// End-to-end: a raw client sends `GET http://origin/chat` with
/// `Upgrade: websocket` to the local proxy; the proxy must relay the
/// handshake to the origin over a dedicated direct connection, deliver the
/// origin's `101` (including a frame the origin pushed in the same flight),
/// and then become a transparent byte relay in both directions.
enum UpgradeScenarios {
    @MainActor
    static func websocketUpgrade(verbose: Bool) async throws -> ScenarioResult {
        let name = "websocket-upgrade"
        let start = Date()
        let earlyFrame = "EARLY-FRAME"
        let clientFrame = "CLIENT-PING"

        let harness = SimHarness(verbose: verbose)
        try await harness.start(
            originBehavior: .websocketUpgrade(earlyFrame: earlyFrame),
            directMode: true,
            directModeCause: .noUpstreamsConfigured
        )
        defer { Task { @MainActor in await harness.stop() } }

        let originPort = harness.origin?.port ?? 0
        let request =
            "GET http://127.0.0.1:\(originPort)/chat HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(originPort)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: keep-alive, Upgrade\r\n" +
            "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "\r\n"

        let transcript = try await RawUpgradeClient.run(
            group: harness.group,
            host: harness.localProxyHost,
            port: harness.localProxyPort,
            request: request,
            frameToSend: clientFrame,
            expectedFrames: [earlyFrame, clientFrame]
        )

        let got101 = transcript.contains("101 Switching Protocols")
        let upgradeSurvived = transcript.lowercased().contains("upgrade: websocket")
        let gotEarlyFrame = transcript.contains(earlyFrame)
        let gotEcho = transcript.contains(clientFrame)
        let passed = got101 && upgradeSurvived && gotEarlyFrame && gotEcho

        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: transcript.isEmpty ? 0 : 1,
            clientsClosedEarly: passed ? 0 : 1,
            totalBytes: transcript.utf8.count,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: transcript.utf8.count,
            maxBytes: transcript.utf8.count,
            medianBytes: transcript.utf8.count,
            earliestClose: nil,
            latestClose: nil,
            notes: [
                passed ? "ok: 101 relayed, Upgrade preserved, frames flowed both ways"
                       : "BUG: upgrade relay incomplete (101=\(got101) upgradeHeader=\(upgradeSurvived) earlyFrame=\(gotEarlyFrame) echo=\(gotEcho))",
            ]
        )
    }
}

private enum UpgradeScenarioError: Error, LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let message): return message
        }
    }
}

/// Raw TCP client for the upgrade flow: writes the handshake, then after the
/// `101` arrives sends one frame and waits until every expected frame string
/// has been observed in the byte stream (origin early-push + echo).
private final class RawUpgradeClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let frameToSend: String
    private let expectedFrames: [String]
    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var sentFrame = false

    init(request: String, frameToSend: String, expectedFrames: [String], promise: EventLoopPromise<String>) {
        self.request = request
        self.frameToSend = frameToSend
        self.expectedFrames = expectedFrames
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let transcript = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ) else { return }

        if !sentFrame, transcript.contains("\r\n\r\n") {
            if transcript.contains("101") {
                sentFrame = true
                var frame = context.channel.allocator.buffer(capacity: frameToSend.utf8.count)
                frame.writeString(frameToSend)
                context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
            } else {
                // Non-101: the handshake was refused; return what we have.
                promise.succeed(transcript)
                context.close(promise: nil)
                return
            }
        }

        if expectedFrames.allSatisfy(transcript.contains) {
            promise.succeed(transcript)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private enum RawUpgradeClient {
    static func run(
        group: EventLoopGroup,
        host: String,
        port: Int,
        request: String,
        frameToSend: String,
        expectedFrames: [String]
    ) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(UpgradeScenarioError.timeout("websocket-upgrade client timed out"))
        }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    RawUpgradeClientHandler(
                        request: request,
                        frameToSend: frameToSend,
                        expectedFrames: expectedFrames,
                        promise: promise
                    )
                )
            }
            .connect(host: host, port: port)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.always { _ in timeout.cancel() }.get()
    }
}
