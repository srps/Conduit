// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A tiny stand-in for a corporate proxy. Accepts CONNECT, plays the 407→200 auth dance
/// with a fake Negotiate scheme, then opens a TCP connection to the configured origin and
/// relays bytes in both directions for the life of the tunnel.
///
/// Ignores the CONNECT target host entirely; every tunnel is redirected to originHost:originPort.
final class FakeUpstreamProxy: @unchecked Sendable {
    let group: EventLoopGroup
    let originHost: String
    let originPort: Int
    let requireAuth: Bool
    let plainHTTPResponse: String?
    private(set) var channel: Channel?
    /// Accepted child channels. Closing the listener with NIO does NOT close
    /// already-accepted child channels — they keep serving requests off the
    /// pool's idle connections, which is unrealistic compared to a real
    /// upstream proxy going down (where both the listener and existing
    /// connections die). Track them so `stop()` can tear everything down,
    /// which is what scenarios like `upstream-flap` rely on to make the
    /// connection pool actually observe failures after a `stop()`.
    private let childrenLock = NIOLock()
    private var children: [ObjectIdentifier: Channel] = [:]

    /// Number of CONNECT requests this upstream has accepted. Scenarios that
    /// must distinguish "routed through the proxy" from "relayed directly"
    /// assert on this — both paths reach the same origin, so the byte stream
    /// alone cannot tell them apart.
    private let connectCountBox = NIOLockedValueBox(0)
    var connectCount: Int { connectCountBox.withLockedValue { $0 } }

    init(
        group: EventLoopGroup,
        originHost: String,
        originPort: Int,
        requireAuth: Bool = true,
        plainHTTPResponse: String? = nil
    ) {
        self.group = group
        self.originHost = originHost
        self.originPort = originPort
        self.requireAuth = requireAuth
        self.plainHTTPResponse = plainHTTPResponse
    }

    var port: Int { channel?.localAddress?.port ?? 0 }

    /// Bind the listener. `port` defaults to `0` (let the kernel assign an
    /// ephemeral port — read it back via `port` after `start()`). Pass an
    /// explicit value when the scenario needs to rebind to the same port
    /// after a stop, e.g. `pm-sim upstream-flap` revives the upstream and
    /// expects the connection pool to reach it on the original port.
    /// SO_REUSEADDR is set on the listener so a quick rebind succeeds even
    /// when the previous listener is still in TIME_WAIT.
    func start(host: String = "127.0.0.1", port: Int = 0) async throws {
        let originHost = self.originHost
        let originPort = self.originPort
        let requireAuth = self.requireAuth
        let plainHTTPResponse = self.plainHTTPResponse
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                self?.trackChild(channel)
                let connectCountBox = self?.connectCountBox
                return channel.pipeline.addHandler(
                    FakeUpstreamSession(
                        originHost: originHost,
                        originPort: originPort,
                        requireAuth: requireAuth,
                        plainHTTPResponse: plainHTTPResponse,
                        onConnect: { connectCountBox?.withLockedValue { $0 += 1 } }
                    )
                )
            }
        self.channel = try await bootstrap.bind(host: host, port: port).get()
    }

    private func trackChild(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        childrenLock.withLockVoid { children[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.childrenLock.withLockVoid { self?.children.removeValue(forKey: id) }
        }
    }

    func stop() async {
        try? await channel?.close().get()
        let snapshot = childrenLock.withLock { Array(children.values) }
        await withTaskGroup(of: Void.self) { group in
            for child in snapshot {
                group.addTask {
                    try? await child.close().get()
                }
            }
        }
    }
}

private final class FakeUpstreamSession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        case awaitingFirstConnect
        case awaitingAuthedConnect
        case relaying
    }

    private let originHost: String
    private let originPort: Int
    private let requireAuth: Bool
    private let plainHTTPResponse: String?
    private let onConnect: @Sendable () -> Void
    private var phase: Phase
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var originChannel: Channel?

    init(
        originHost: String,
        originPort: Int,
        requireAuth: Bool,
        plainHTTPResponse: String?,
        onConnect: @escaping @Sendable () -> Void = {}
    ) {
        self.originHost = originHost
        self.originPort = originPort
        self.requireAuth = requireAuth
        self.plainHTTPResponse = plainHTTPResponse
        self.onConnect = onConnect
        self.phase = requireAuth ? .awaitingFirstConnect : .awaitingAuthedConnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)

        if phase == .relaying {
            originChannel?.writeAndFlush(buf, promise: nil)
            return
        }

        accumulated.writeBuffer(&buf)
        guard let str = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              str.contains("\r\n\r\n") else {
            return
        }

        let requestLine = str.split(separator: "\r\n").first.map(String.init) ?? ""
        let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
        accumulated.clear()

        switch phase {
        case .awaitingFirstConnect:
            let response =
                "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Negotiate\r\n" +
                "Content-Length: 0\r\n" +
                "\r\n"
            var out = context.channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
            phase = .awaitingAuthedConnect

        case .awaitingAuthedConnect:
            if method.uppercased() == "CONNECT" {
                onConnect()
                openOriginAndPromote(context: context)
            } else {
                // Plain HTTP request (e.g., HEAD health check). Answer 200 OK with empty body.
                let response = plainHTTPResponse ??
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Length: 0\r\n" +
                    "Connection: keep-alive\r\n" +
                    "\r\n"
                var out = context.channel.allocator.buffer(capacity: response.utf8.count)
                out.writeString(response)
                context.writeAndFlush(wrapOutboundOut(out), promise: nil)
                // Stay in `.awaitingAuthedConnect` — SPNEGO/Negotiate authenticates the
                // connection, not each request, so keep-alive reuse on an already-authed
                // socket should NOT re-challenge with 407.
            }

        case .relaying:
            return
        }
    }

    private func openOriginAndPromote(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        ClientBootstrap(group: context.eventLoop.next())
            .connect(host: originHost, port: originPort)
            .whenComplete { [self] result in
                switch result {
                case .success(let originChannel):
                    self.originChannel = originChannel

                    let response =
                        "HTTP/1.1 200 Connection Established\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                    var out = clientChannel.allocator.buffer(capacity: response.utf8.count)
                    out.writeString(response)
                    clientChannel.writeAndFlush(out).whenComplete { [self] _ in
                        self.phase = .relaying
                        let clientToOriginBridge = OriginRelayToClient(peer: clientChannel)
                        originChannel.pipeline.addHandler(clientToOriginBridge).whenFailure { _ in
                            clientChannel.close(promise: nil)
                        }
                    }

                case .failure:
                    let response =
                        "HTTP/1.1 502 Bad Gateway\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                    var out = clientChannel.allocator.buffer(capacity: response.utf8.count)
                    out.writeString(response)
                    clientChannel.writeAndFlush(out).whenComplete { _ in
                        clientChannel.close(promise: nil)
                    }
                }
            }
    }

    func channelInactive(context: ChannelHandlerContext) {
        originChannel?.close(promise: nil)
        originChannel = nil
        context.fireChannelInactive()
    }
}

/// Relays bytes that arrive from the origin back to the proxy's client channel.
private final class OriginRelayToClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        peer.writeAndFlush(buf, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Drain pending writes before closing peer, or the sim truncates bytes that the
        // real code already delivered correctly. Same pattern as TunnelRelayHandler.gracefulClosePeer.
        let peer = self.peer
        if peer.isActive {
            peer.writeAndFlush(peer.allocator.buffer(capacity: 0)).whenComplete { _ in
                peer.close(mode: .all, promise: nil)
            }
        } else {
            peer.close(mode: .all, promise: nil)
        }
        context.fireChannelInactive()
    }
}
