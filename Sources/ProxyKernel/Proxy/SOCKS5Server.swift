// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

final class SOCKS5Server: @unchecked Sendable {
    private let group: EventLoopGroup
    private let connectCoordinator: CONNECTCoordinator
    private let logger: any LogSink
    /// `(isDirect, cause)`. SOCKS5 doesn't log per-direct-failure today (it
    /// silently sends reply 0x05), so the `cause` is currently unused — but the
    /// signature stays consistent with HTTPProxyHandler so future telemetry
    /// (Phase 7) can surface SOCKS5-direct-failure counts by cause.
    private let directModeProvider: () -> (Bool, DirectModeCause)
    private let pacRoutingEngine: PACRoutingEngine?
    private let configProvider: () -> ProxyConfig
    private let gatewayMode: Bool
    private let onConnectionOpened: @Sendable (ActiveConnectionInfo) -> Void
    private let onConnectionClosed: @Sendable (UUID) -> Void
    private let onConnectionActivity: @Sendable (ConnectionActivity) -> Void
    private var serverChannel: Channel?

    var listeningHost: String? {
        serverChannel?.localAddress?.ipAddress
    }

    var listeningPort: Int? {
        serverChannel?.localAddress?.port
    }

    init(
        group: EventLoopGroup,
        connectCoordinator: CONNECTCoordinator,
        logger: any LogSink,
        directModeProvider: @escaping () -> (Bool, DirectModeCause),
        pacRoutingEngine: PACRoutingEngine?,
        configProvider: @escaping () -> ProxyConfig,
        gatewayMode: Bool,
        onConnectionOpened: @Sendable @escaping (ActiveConnectionInfo) -> Void = { _ in },
        onConnectionClosed: @Sendable @escaping (UUID) -> Void = { _ in },
        onConnectionActivity: @Sendable @escaping (ConnectionActivity) -> Void = { _ in }
    ) {
        self.group = group
        self.connectCoordinator = connectCoordinator
        self.logger = logger
        self.directModeProvider = directModeProvider
        self.pacRoutingEngine = pacRoutingEngine
        self.configProvider = configProvider
        self.gatewayMode = gatewayMode
        self.onConnectionOpened = onConnectionOpened
        self.onConnectionClosed = onConnectionClosed
        self.onConnectionActivity = onConnectionActivity
    }

    func start(host: String, port: Int) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                var future = channel.eventLoop.makeSucceededVoidFuture()
                if self.gatewayMode {
                    nonisolated(unsafe) let configProvider = self.configProvider
                    let filter = ClientIPFilter(
                        allowedIPsProvider: { Set(configProvider().allowedClients) },
                        logger: self.logger
                    )
                    future = future.flatMap { channel.pipeline.addHandler(filter) }
                }
                return future.flatMap {
                    channel.pipeline.addHandler(
                        SOCKS5Handler(
                            connectCoordinator: self.connectCoordinator,
                            logger: self.logger,
                            group: self.group,
                            directModeProvider: self.directModeProvider,
                            pacRoutingEngine: self.pacRoutingEngine,
                            configProvider: self.configProvider,
                            gatewayMode: self.gatewayMode,
                            onConnectionOpened: self.onConnectionOpened,
                            onConnectionClosed: self.onConnectionClosed,
                            onConnectionActivity: self.onConnectionActivity
                        )
                    )
                }
            }
        serverChannel = try await bootstrap.bind(host: host, port: port).get()
        let actualHost = serverChannel?.localAddress?.ipAddress ?? host
        let actualPort = serverChannel?.localAddress?.port ?? port
        logger.log(.notice, "SOCKS5 proxy listening on \(actualHost):\(actualPort).", category: .proxy)
    }

    func stop() async {
        if let serverChannel {
            _ = try? await serverChannel.close().get()
        }
        serverChannel = nil
    }
}

private final class SOCKS5Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connectCoordinator: CONNECTCoordinator
    private let logger: any LogSink
    private let group: EventLoopGroup
    private let directModeProvider: () -> (Bool, DirectModeCause)
    private let pacRoutingEngine: PACRoutingEngine?
    private let configProvider: () -> ProxyConfig
    private let gatewayMode: Bool
    private let onConnectionOpened: @Sendable (ActiveConnectionInfo) -> Void
    private let onConnectionClosed: @Sendable (UUID) -> Void
    private let onConnectionActivity: @Sendable (ConnectionActivity) -> Void
    private enum State { case greeting, request, routing, relaying }
    private var state: State = .greeting
    private var connectionID: UUID?
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(
        connectCoordinator: CONNECTCoordinator,
        logger: any LogSink,
        group: EventLoopGroup,
        directModeProvider: @escaping () -> (Bool, DirectModeCause),
        pacRoutingEngine: PACRoutingEngine?,
        configProvider: @escaping () -> ProxyConfig,
        gatewayMode: Bool,
        onConnectionOpened: @Sendable @escaping (ActiveConnectionInfo) -> Void,
        onConnectionClosed: @Sendable @escaping (UUID) -> Void,
        onConnectionActivity: @Sendable @escaping (ConnectionActivity) -> Void
    ) {
        self.connectCoordinator = connectCoordinator
        self.logger = logger
        self.group = group
        self.directModeProvider = directModeProvider
        self.pacRoutingEngine = pacRoutingEngine
        self.configProvider = configProvider
        self.gatewayMode = gatewayMode
        self.onConnectionOpened = onConnectionOpened
        self.onConnectionClosed = onConnectionClosed
        self.onConnectionActivity = onConnectionActivity
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if state == .relaying {
            context.fireChannelRead(data)
            return
        }
        if state == .routing {
            logger.log(.warning, "SOCKS5: client sent data before routing completed; closing to avoid buffering unbounded early payload.", category: .proxy)
            context.close(promise: nil)
            return
        }

        accumulated.writeBuffer(&buf)
        while true {
            switch state {
            case .greeting:
                guard handleGreeting(context: context, buf: &accumulated) else { return }
            case .request:
                guard handleRequest(context: context, buf: &accumulated) else { return }
            case .routing:
                return
            case .relaying:
                return
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let id = connectionID {
            onConnectionClosed(id)
            connectionID = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(.warning, "SOCKS5 error: \(error.localizedDescription)", category: .proxy)
        context.close(promise: nil)
    }

    @discardableResult
    private func handleGreeting(context: ChannelHandlerContext, buf: inout ByteBuffer) -> Bool {
        guard buf.readableBytes >= 2 else { return false }
        let base = buf.readerIndex
        guard let version: UInt8 = buf.getInteger(at: base),
              version == 5,
              let nmethods: UInt8 = buf.getInteger(at: base + 1) else {
            context.close(promise: nil)
            return false
        }
        let totalLength = 2 + Int(nmethods)
        guard buf.readableBytes >= totalLength else {
            return false
        }
        buf.moveReaderIndex(forwardBy: 2)
        let methods = buf.readBytes(length: Int(nmethods)) ?? []

        var response = context.channel.allocator.buffer(capacity: 2)
        response.writeInteger(UInt8(5))
        guard methods.contains(0x00) else {
            response.writeInteger(UInt8(0xFF))
            context.writeAndFlush(NIOAny(response), promise: nil)
            context.close(promise: nil)
            return false
        }
        response.writeInteger(UInt8(0x00))
        context.writeAndFlush(NIOAny(response), promise: nil)
        state = .request
        return true
    }

    @discardableResult
    private func handleRequest(context: ChannelHandlerContext, buf: inout ByteBuffer) -> Bool {
        guard buf.readableBytes >= 4 else { return false }
        let base = buf.readerIndex
        guard let version: UInt8 = buf.getInteger(at: base), version == 5,
              let cmd: UInt8 = buf.getInteger(at: base + 1), cmd == 1,
              let rsv: UInt8 = buf.getInteger(at: base + 2),
              let atyp: UInt8 = buf.getInteger(at: base + 3) else {
            sendReply(context: context, rep: 0x07)
            return false
        }
        guard rsv == 0 else {
            sendReply(context: context, rep: 0x01)
            return false
        }

        let totalLength: Int
        switch atyp {
        case 1:
            totalLength = 4 + 4 + 2
        case 3:
            guard buf.readableBytes >= 5, let len: UInt8 = buf.getInteger(at: base + 4) else { return false }
            totalLength = 4 + 1 + Int(len) + 2
        case 4:
            totalLength = 4 + 16 + 2
        default:
            sendReply(context: context, rep: 0x08)
            return false
        }
        guard buf.readableBytes >= totalLength else { return false }
        buf.moveReaderIndex(forwardBy: 4)

        let host: String
        switch atyp {
        case 1:
            let bytes = buf.readBytes(length: 4)!
            host = bytes.map { String($0) }.joined(separator: ".")
        case 3:
            let len: UInt8 = buf.readInteger()!
            host = buf.readString(length: Int(len))!
        case 4:
            let bytes = buf.readBytes(length: 16)!
            let parts = stride(from: 0, to: 16, by: 2).map { i in
                String(format: "%x", UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            }
            host = parts.joined(separator: ":")
        default:
            sendReply(context: context, rep: 0x08)
            return false
        }

        guard buf.readableBytes >= 2, let port: UInt16 = buf.readInteger() else {
            sendReply(context: context, rep: 0x01)
            return false
        }

        if MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) {
            logger.log(.warning, "SOCKS5: blocked connection to \(host):\(port) (metadata/loopback protection).", category: .proxy)
            sendReply(context: context, rep: 0x02)
            return false
        }

        let (isDirectMode, directCause) = directModeProvider()
        let directModeBypass = isDirectMode && directCause.routesClientTrafficDirectly
        let currentConfig = configProvider()
        // Only unconditional direct states bypass PAC/upstreams. VPN-connected
        // degraded states keep PAC policy active for split-DNS safety.
        if HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: directModeBypass, forceProxy: false),
           let pacRoutingEngine {
            let pacHost = host.contains(":") ? "[\(host)]" : host
            guard buf.readableBytes == 0 else {
                logger.log(.warning, "SOCKS5: client pipelined payload before CONNECT success; closing to avoid buffering unbounded early payload.", category: .proxy)
                context.close(promise: nil)
                return false
            }
            state = .routing
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            nonisolated(unsafe) let ctx = context
            pacRoutingEngine.routeChainFuture(for: "https://\(pacHost):\(port)/", host: host, on: ctx.eventLoop)
                .whenComplete { result in
                    guard ctx.channel.isActive else { return }
                    let routes = (try? result.get()) ?? []
                    self.finishRequestRouting(
                        host: host,
                        port: port,
                        context: ctx,
                        currentConfig: currentConfig,
                        directModeBypass: directModeBypass,
                        directCause: directCause,
                        pacRoutes: routes
                    )
                }
            return false
        }

        finishRequestRouting(
            host: host,
            port: port,
            context: context,
            currentConfig: currentConfig,
            directModeBypass: directModeBypass,
            directCause: directCause,
            pacRoutes: []
        )
        return false
    }

    private func finishRequestRouting(
        host: String,
        port: UInt16,
        context: ChannelHandlerContext,
        currentConfig: ProxyConfig,
        directModeBypass: Bool,
        directCause: DirectModeCause,
        pacRoutes: [PACRoute]
    ) {
        // Reached from future callbacks (PAC routing, connect attempts) — the
        // handler's state machine is loop-confined by convention, so verify
        // it in debug builds (STYLE: assert invariants).
        context.eventLoop.assertInEventLoop()
        let pacBypass = pacRoutes.first == .direct
        let pacProxyChain = HTTPProxyHandler.pacProxyChain(from: pacRoutes, config: currentConfig)
        // Read pattern lists fresh per request so config-reload changes to
        // `noProxyHosts` / `forceProxyHosts` apply without restarting the SOCKS listener
        // (mirrors the HTTP proxy handler — see HTTPProxyHandler.channelRead).
        let bypass = NoProxyMatcher.shouldBypass(
            host: host,
            patterns: currentConfig.noProxyHosts,
            forceProxy: currentConfig.forceProxyHosts
        )
            || directModeBypass
            || pacBypass

        let info = ActiveConnectionInfo(
            destination: "\(host):\(port)",
            upstream: bypass ? "DIRECT" : "SOCKS5",
            method: "SOCKS5",
            tunnel: true
        )
        connectionID = info.id
        onConnectionOpened(info)

        if bypass {
            logger.log(.info, "SOCKS5 DIRECT to \(host):\(port)", category: .proxy)
            connectDirect(host: host, port: port, context: context)
        } else {
            logger.log(.info, "SOCKS5 CONNECT via upstream to \(host):\(port)", category: .proxy)
            connectViaUpstream(
                host: host,
                port: port,
                context: context,
                proxyChain: pacProxyChain,
                failureLogLevel: HTTPProxyHandler.upstreamFailureLogLevel(for: directCause)
            )
        }
    }

    private func connectDirect(host: String, port: UInt16, context: ChannelHandlerContext) {
        nonisolated(unsafe) let ctx = context
        let clientEL = ctx.eventLoop
        let group = self.group
        let logger = self.logger
        let gatewayMode = self.gatewayMode

        let makeBootstrap: @Sendable () -> ClientBootstrap = {
            ClientBootstrap(group: group).connectTimeout(.seconds(10))
        }

        makeBootstrap()
            .connect(host: host, port: Int(port))
            .hop(to: clientEL)
            .flatMap { upstreamChannel -> EventLoopFuture<Channel> in
                // Mirror the HTTP handler's direct path: NIO's happy-eyeballs
                // connector can hand back a half-open channel (remoteAddress nil)
                // that later fails; fall back to an explicit first-A-record IPv4
                // connect. Shared, unit-tested logic — see HalfOpenChannelFallback.
                if upstreamChannel.remoteAddress == nil {
                    logger.log(.warning, "SOCKS5: half-open channel detected for \(host):\(port) (remoteAddress nil); falling back to explicit IPv4 connect", category: .proxy)
                }
                return HalfOpenChannelFallback.apply(
                    upstreamChannel: upstreamChannel,
                    host: host,
                    port: Int(port),
                    on: clientEL,
                    ipv4Reconnect: { address in
                        logger.log(.info, "SOCKS5: half-open fallback reconnecting to \(host):\(port) via IPv4 \(address)", category: .proxy)
                        return makeBootstrap().connect(to: address).hop(to: clientEL)
                    }
                )
            }
            .flatMapThrowing { channel -> Channel in
                // DNS-rebinding guard: re-check the *resolved* peer against the
                // metadata/loopback blocklist (the pre-connect host check can't
                // see a hostname that resolves to a blocked literal).
                if gatewayMode,
                   let ip = channel.remoteAddress?.ipAddress,
                   MetadataBlocklist.isBlockedResolvedAddress(ip, gatewayMode: gatewayMode) {
                    logger.log(.warning, "SOCKS5: blocked direct connection to \(host):\(port): resolved to \(ip) (metadata/loopback protection).", category: .proxy)
                    channel.close(promise: nil)
                    throw MetadataBlocklist.BlockedAddressError(host: host, resolvedIP: ip)
                }
                return channel
            }
            .whenComplete { result in
                switch result {
                case .success(let upstream):
                    self.attachRelay(context: ctx, upstream: upstream)
                case .failure(let error):
                    // A blocked rebinding peer is a policy denial (0x02, not
                    // allowed by ruleset); every other connect failure is a
                    // general SOCKS5 failure (0x05).
                    let rep: UInt8 = error is MetadataBlocklist.BlockedAddressError ? 0x02 : 0x05
                    self.sendReply(context: ctx, rep: rep)
                }
            }
    }

    private func connectViaUpstream(
        host: String,
        port: UInt16,
        context: ChannelHandlerContext,
        proxyChain: [UpstreamProxy],
        failureLogLevel: LogLevel
    ) {
        nonisolated(unsafe) let ctx = context
        let clientEL = ctx.eventLoop
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let authSource = context.remoteAddress?.ipAddress
        connectCoordinator.connectUpstreamTunnel(target: target, authSource: authSource, proxyChain: proxyChain)
            .hop(to: clientEL)
            .whenComplete { result in
                switch result {
                case .success(let (upstream, endpoint, authMethod)):
                    self.logger.log(.notice, "SOCKS5 tunnel via \(endpoint) for \(host):\(port)", category: .proxy)
                    if let id = self.connectionID, let authMethod {
                        self.onConnectionActivity(ConnectionActivity(connectionID: id, authMethod: authMethod))
                    }
                    self.attachRelay(context: ctx, upstream: upstream)
                case .failure(let error):
                    self.logger.log(failureLogLevel, "SOCKS5 upstream tunnel failed: \(error.localizedDescription)", category: .proxy)
                    self.sendReply(context: ctx, rep: 0x05)
                }
            }
    }

    private func attachRelay(context: ChannelHandlerContext, upstream: Channel) {
        // Reached from connect-completion callbacks; mutates `state`.
        context.eventLoop.assertInEventLoop()
        sendReply(context: context, rep: 0x00)
        state = .relaying
        let clientChannel = context.channel
        let connID = connectionID
        let activityCallback = onConnectionActivity
        let clientRelay = SOCKSTunnelRelay(peer: upstream, connectionID: connID, onActivity: activityCallback, direction: .received)
        let upstreamRelay = SOCKSTunnelRelay(peer: clientChannel, connectionID: connID, onActivity: activityCallback, direction: .sent)
        context.pipeline.addHandler(clientRelay).flatMap {
            upstream.pipeline.addHandler(upstreamRelay)
        }.whenComplete { result in
            switch result {
            case .success:
                clientChannel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            case .failure(let error):
                self.logger.log(.error, "SOCKS5 tunnel setup failed: \(error.localizedDescription)", category: .proxy)
                clientChannel.close(mode: .all, promise: nil)
                upstream.close(mode: .all, promise: nil)
            }
        }
    }

    private func sendReply(context: ChannelHandlerContext, rep: UInt8) {
        var buf = context.channel.allocator.buffer(capacity: 10)
        buf.writeInteger(UInt8(5))
        buf.writeInteger(rep)
        buf.writeInteger(UInt8(0))
        buf.writeInteger(UInt8(1))
        buf.writeRepeatingByte(0, count: 4)
        buf.writeInteger(UInt16(0))
        context.writeAndFlush(NIOAny(buf), promise: nil)
        if rep != 0x00 {
            context.close(promise: nil)
        }
    }
}

private final class SOCKSTunnelRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    enum Direction { case sent, received }

    let peer: Channel
    private let connectionID: UUID?
    private let onActivity: @Sendable (ConnectionActivity) -> Void
    private let direction: Direction

    init(
        peer: Channel,
        connectionID: UUID?,
        onActivity: @Sendable @escaping (ConnectionActivity) -> Void,
        direction: Direction
    ) {
        self.peer = peer
        self.connectionID = connectionID
        self.onActivity = onActivity
        self.direction = direction
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        let byteCount = buf.readableBytes

        if let id = connectionID, byteCount > 0 {
            let activity: ConnectionActivity
            switch direction {
            case .sent:
                activity = ConnectionActivity(connectionID: id, bytesSent: byteCount)
            case .received:
                activity = ConnectionActivity(connectionID: id, bytesReceived: byteCount)
            }
            onActivity(activity)
        }

        peer.writeAndFlush(buf, promise: nil)
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            peer.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}
