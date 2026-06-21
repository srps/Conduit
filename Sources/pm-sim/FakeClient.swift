// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// Metrics a fake client collects across its lifetime.
struct ClientMetrics: Sendable {
    var connectEstablishedAt: Date?
    var firstByteAt: Date?
    var lastByteAt: Date?
    var bytesReceived: Int = 0
    var readCount: Int = 0
    var closedAt: Date?
    var closeReason: String?
}

/// Opens a raw TCP connection to the local proxy, sends a CONNECT request, reads back the
/// 200 Connection Established, then behaves per `clientBehavior`. Captures metrics.
final class FakeClient: @unchecked Sendable {
    let id: Int
    let group: EventLoopGroup
    let localProxyHost: String
    let localProxyPort: Int
    let target: String
    let behavior: ClientBehavior

    private let metricsBox = NIOLockedValueBox(ClientMetrics())
    private let eventLoopBox = NIOLockedValueBox<EventLoop?>(nil)
    private let channelBox = NIOLockedValueBox<Channel?>(nil)

    init(
        id: Int,
        group: EventLoopGroup,
        localProxyHost: String,
        localProxyPort: Int,
        target: String,
        behavior: ClientBehavior
    ) {
        self.id = id
        self.group = group
        self.localProxyHost = localProxyHost
        self.localProxyPort = localProxyPort
        self.target = target
        self.behavior = behavior
    }

    var metrics: ClientMetrics { metricsBox.withLockedValue { $0 } }

    func run() async throws {
        let id = self.id
        let target = self.target
        let behavior = self.behavior
        let metricsBox = self.metricsBox
        let channelBox = self.channelBox

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    FakeClientHandler(
                        id: id,
                        target: target,
                        behavior: behavior,
                        metricsBox: metricsBox
                    )
                )
            }
            .connect(host: localProxyHost, port: localProxyPort)
            .get()
        channelBox.withLockedValue { $0 = channel }
        eventLoopBox.withLockedValue { $0 = channel.eventLoop }
    }

    func waitForClose(timeout: TimeInterval) async {
        guard let channel = channelBox.withLockedValue({ $0 }) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while channel.isActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func close() async {
        if let channel = channelBox.withLockedValue({ $0 }) {
            try? await channel.close().get()
        }
    }
}

/// Traffic pattern a fake client produces.
enum ClientBehavior: Sendable {
    /// Send one small initial write, then stay silent. Only receive from server.
    /// This is the pattern we expect to break under a per-direction idle timer.
    case sendOnceThenListen(requestBytes: Int)

    /// Send a small write every `pingIntervalMs` to keep the client→upstream direction alive.
    case periodicPing(requestBytes: Int, pingIntervalMs: Int, pingBytes: Int)

    /// Slow-draining client: throttle inbound reads so the proxy-to-client direction
    /// builds up backpressure. Simulates the AE5F6815 pattern where fast upstream
    /// saturates a slow client and upstream then closes mid-stream.
    case slowDrain(requestBytes: Int, smallRcvBufBytes: Int)
}

private final class FakeClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase { case awaitingConnectResponse, tunnelOpen }

    private let id: Int
    private let target: String
    private let behavior: ClientBehavior
    private let metricsBox: NIOLockedValueBox<ClientMetrics>

    private var phase: Phase = .awaitingConnectResponse
    private var connectResponseAccum = ByteBufferAllocator().buffer(capacity: 1024)
    private var pingTask: RepeatedTask?

    init(
        id: Int,
        target: String,
        behavior: ClientBehavior,
        metricsBox: NIOLockedValueBox<ClientMetrics>
    ) {
        self.id = id
        self.target = target
        self.behavior = behavior
        self.metricsBox = metricsBox
    }

    func channelActive(context: ChannelHandlerContext) {
        let connect =
            "CONNECT \(target) HTTP/1.1\r\n" +
            "Host: \(target)\r\n" +
            "Proxy-Connection: Keep-Alive\r\n" +
            "\r\n"
        var buf = context.channel.allocator.buffer(capacity: connect.utf8.count)
        buf.writeString(connect)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)

        switch phase {
        case .awaitingConnectResponse:
            connectResponseAccum.writeBuffer(&buf)
            guard let str = connectResponseAccum.getString(
                at: connectResponseAccum.readerIndex,
                length: connectResponseAccum.readableBytes
            ), str.contains("\r\n\r\n") else {
                return
            }

            // Expect "HTTP/1.1 200 ..."
            guard str.hasPrefix("HTTP/1.1 200") else {
                metricsBox.withLockedValue { $0.closeReason = "proxy returned non-200: \(str.prefix(32))" }
                context.close(promise: nil)
                return
            }

            metricsBox.withLockedValue { $0.connectEstablishedAt = Date() }
            phase = .tunnelOpen

            // If the 200 response included any bytes after \r\n\r\n, those are tunnel payload.
            let headerEndRange = str.range(of: "\r\n\r\n")!
            let consumed = str.distance(from: str.startIndex, to: headerEndRange.upperBound)
            connectResponseAccum.moveReaderIndex(forwardBy: consumed)
            if connectResponseAccum.readableBytes > 0 {
                recordBytesReceived(connectResponseAccum.readableBytes)
            }
            connectResponseAccum.clear()

            startBehavior(context: context)

        case .tunnelOpen:
            recordBytesReceived(buf.readableBytes)
        }
    }

    private func recordBytesReceived(_ n: Int) {
        metricsBox.withLockedValue { m in
            if m.firstByteAt == nil { m.firstByteAt = Date() }
            m.lastByteAt = Date()
            m.bytesReceived += n
            m.readCount += 1
        }
    }

    private func startBehavior(context: ChannelHandlerContext) {
        switch behavior {
        case .sendOnceThenListen(let requestBytes):
            emit(context: context, bytes: requestBytes)

        case .periodicPing(let requestBytes, let pingIntervalMs, let pingBytes):
            emit(context: context, bytes: requestBytes)
            let channel = context.channel
            pingTask = context.eventLoop.scheduleRepeatedTask(
                initialDelay: .milliseconds(Int64(pingIntervalMs)),
                delay: .milliseconds(Int64(pingIntervalMs))
            ) { [weak self] _ in
                guard let self else { return }
                self.emit(channel: channel, bytes: pingBytes)
            }

        case .slowDrain(let requestBytes, let smallRcvBufBytes):
            // Shrink the client's socket receive buffer. That forces the kernel to
            // advertise a small TCP receive window, which makes the proxy's outbound
            // socket (to us) fill up fast → proxy hits backpressure → peer.isWritable=false
            // path in TunnelRelayHandler.
            _ = context.channel.setOption(ChannelOptions.socketOption(.so_rcvbuf), value: CInt(smallRcvBufBytes))
            emit(context: context, bytes: requestBytes)
        }
    }

    private func emit(context: ChannelHandlerContext, bytes: Int) {
        emit(channel: context.channel, bytes: bytes)
    }

    private func emit(channel: Channel, bytes: Int) {
        guard bytes > 0, channel.isActive else { return }
        var buf = channel.allocator.buffer(capacity: bytes)
        buf.writeRepeatingByte(UInt8.random(in: 32...126), count: bytes)
        channel.writeAndFlush(buf, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        pingTask?.cancel()
        pingTask = nil
        metricsBox.withLockedValue { m in
            m.closedAt = Date()
            if m.closeReason == nil { m.closeReason = "channel_inactive" }
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        metricsBox.withLockedValue { m in
            m.closeReason = "error: \(error.localizedDescription)"
        }
        context.close(promise: nil)
    }
}
