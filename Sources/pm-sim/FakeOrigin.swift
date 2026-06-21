// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

/// Behavior the fake origin exposes inside the CONNECT tunnel.
/// The origin speaks raw bytes (not TLS) since the upstream proxy just relays after 200 OK.
enum OriginBehavior: Sendable {
    /// Emit `chunkSize` bytes every `intervalMs` for `durationMs`. Ignores inbound bytes.
    case burstStream(intervalMs: Int, chunkSize: Int, durationMs: Int)

    /// Stay silent for `silentForMs`, then emit one `burstBytes`-sized payload and close.
    case silentThenBurst(silentForMs: Int, burstBytes: Int)

    /// Echo all inbound bytes.
    case echo

    /// Do nothing, stay open.
    case silent

    /// Immediately blast `floodBytes` of bytes, then TCP-close. This mimics the AE5F6815
    /// pattern: a fast upstream that finishes sending then hangs up while the proxy is
    /// still backpressured trying to deliver to the client.
    case floodThenClose(floodBytes: Int)

    /// Speak just enough HTTP/1.1 to accept a WebSocket-style Upgrade:
    /// accumulate the request until the blank line, answer `101 Switching
    /// Protocols` (+ `earlyFrame` flushed in the same write, mimicking an
    /// origin that pushes a frame before the client's first message), then
    /// echo every subsequent raw byte.
    case websocketUpgrade(earlyFrame: String)
}

final class FakeOrigin: @unchecked Sendable {
    let group: EventLoopGroup
    let behavior: OriginBehavior
    private(set) var channel: Channel?

    init(group: EventLoopGroup, behavior: OriginBehavior) {
        self.group = group
        self.behavior = behavior
    }

    var port: Int { channel?.localAddress?.port ?? 0 }

    func start(host: String = "127.0.0.1") async throws {
        let behavior = self.behavior
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(OriginSessionHandler(behavior: behavior))
            }
        self.channel = try await bootstrap.bind(host: host, port: 0).get()
    }

    func stop() async {
        try? await channel?.close().get()
    }
}

private final class OriginSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let behavior: OriginBehavior
    private var burstTimer: RepeatedTask?
    private var upgradeRequestBuffer = ByteBufferAllocator().buffer(capacity: 512)
    private var upgraded = false

    init(behavior: OriginBehavior) {
        self.behavior = behavior
    }

    func channelActive(context: ChannelHandlerContext) {
        switch behavior {
        case .burstStream(let intervalMs, let chunkSize, let durationMs):
            startBurst(context: context, intervalMs: intervalMs, chunkSize: chunkSize, durationMs: durationMs)
        case .silentThenBurst(let silentForMs, let burstBytes):
            let channel = context.channel
            context.eventLoop.scheduleTask(in: .milliseconds(Int64(silentForMs))) { [weak self] in
                self?.emitBurst(channel: channel, bytes: burstBytes)
            }
        case .echo, .silent, .websocketUpgrade:
            break
        case .floodThenClose(let floodBytes):
            emitBurst(channel: context.channel, bytes: floodBytes)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        switch behavior {
        case .echo:
            context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
        case .websocketUpgrade(let earlyFrame):
            if upgraded {
                context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
                return
            }
            upgradeRequestBuffer.writeBuffer(&buf)
            guard let request = upgradeRequestBuffer.getString(
                at: upgradeRequestBuffer.readerIndex,
                length: upgradeRequestBuffer.readableBytes
            ), request.contains("\r\n\r\n") else { return }
            upgraded = true
            let status = request.lowercased().contains("upgrade: websocket")
                ? "HTTP/1.1 101 Switching Protocols\r\n" +
                  "Upgrade: websocket\r\n" +
                  "Connection: Upgrade\r\n" +
                  "\r\n" + earlyFrame
                : "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            var out = context.channel.allocator.buffer(capacity: status.utf8.count)
            out.writeString(status)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        burstTimer?.cancel()
        burstTimer = nil
        context.fireChannelInactive()
    }

    private func startBurst(context: ChannelHandlerContext, intervalMs: Int, chunkSize: Int, durationMs: Int) {
        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(durationMs) / 1000)
        let channel = context.channel
        let alloc = channel.allocator
        burstTimer = context.eventLoop.scheduleRepeatedTask(
            initialDelay: .milliseconds(Int64(intervalMs)),
            delay: .milliseconds(Int64(intervalMs))
        ) { task in
            if Date() >= deadline {
                task.cancel()
                channel.close(promise: nil)
                return
            }
            var buf = alloc.buffer(capacity: chunkSize)
            buf.writeRepeatingByte(UInt8.random(in: 32...126), count: chunkSize)
            channel.writeAndFlush(buf, promise: nil)
        }
    }

    private func emitBurst(channel: Channel, bytes: Int) {
        var buf = channel.allocator.buffer(capacity: bytes)
        buf.writeRepeatingByte(UInt8.random(in: 32...126), count: bytes)
        channel.writeAndFlush(buf).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
