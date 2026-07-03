// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

package final class TransparentTCPProxy: @unchecked Sendable {
    private let group: EventLoopGroup
    private let connectCoordinator: CONNECTCoordinator
    private let connectionPool: ConnectionPool
    private let logger: any LogSink
    private let gatewayModeProvider: @Sendable () -> Bool
    private var listener: Channel?

    package private(set) var listeningPort: Int?

    package init(
        group: EventLoopGroup,
        connectCoordinator: CONNECTCoordinator,
        connectionPool: ConnectionPool,
        logger: any LogSink,
        gatewayModeProvider: @escaping @Sendable () -> Bool = { false }
    ) {
        self.group = group
        self.connectCoordinator = connectCoordinator
        self.connectionPool = connectionPool
        self.logger = logger
        self.gatewayModeProvider = gatewayModeProvider
    }

    package func start(host: String, port: Int) async throws {
        let coordinator = connectCoordinator
        let pool = connectionPool
        let log = logger
        let gatewayModeProvider = gatewayModeProvider
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpNoDelay, value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    SNIInterceptHandler(
                        connectCoordinator: coordinator,
                        connectionPool: pool,
                        logger: log,
                        gatewayModeProvider: gatewayModeProvider
                    )
                )
            }
        let ch = try await bootstrap.bind(host: host, port: port).get()
        listener = ch
        let actualPort = ch.localAddress?.port ?? port
        listeningPort = actualPort
        logger.log(
            .notice,
            "Transparent TCP proxy listening on \(host):\(actualPort).",
            category: .proxy
        )
    }

    package func stop() async {
        if let ch = listener {
            _ = try? await ch.close().get()
        }
        listener = nil
        listeningPort = nil
        logger.log(.notice, "Transparent TCP proxy stopped.", category: .proxy)
    }
}

// MARK: - SNI Extraction + Tunnel Establishment

private final class SNIInterceptHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private static let maxPeekBytes = 65_536
    private static let handshakeTimeoutSeconds: Int64 = 10

    private let connectCoordinator: CONNECTCoordinator
    private let connectionPool: ConnectionPool
    private let logger: any LogSink
    private let gatewayModeProvider: @Sendable () -> Bool
    private var accumulated = ByteBuffer()
    private var resolved = false
    private var clientGone = false

    init(
        connectCoordinator: CONNECTCoordinator,
        connectionPool: ConnectionPool,
        logger: any LogSink,
        gatewayModeProvider: @escaping @Sendable () -> Bool
    ) {
        self.connectCoordinator = connectCoordinator
        self.connectionPool = connectionPool
        self.logger = logger
        self.gatewayModeProvider = gatewayModeProvider
    }

    func handlerAdded(context: ChannelHandlerContext) {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.scheduleTask(in: .seconds(Self.handshakeTimeoutSeconds)) { [weak self] in
            guard let self, !self.resolved else { return }
            self.logger.log(.warning, "Transparent proxy: SNI extraction timed out.", category: .proxy)
            ctx.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !resolved else {
            context.fireChannelRead(data)
            return
        }

        var buf = unwrapInboundIn(data)
        accumulated.writeBuffer(&buf)

        if accumulated.readableBytes > Self.maxPeekBytes {
            logger.log(.warning, "Transparent proxy: exceeded peek buffer without valid ClientHello, closing.", category: .proxy)
            context.close(promise: nil)
            return
        }

        guard let sniHost = SNIParser.extractSNI(from: accumulated) else {
            return
        }

        if MetadataBlocklist.isBlocked(host: sniHost, gatewayMode: gatewayModeProvider()) {
            logger.log(.warning, "Transparent proxy: blocked SNI \(sniHost) (metadata/loopback protection).", category: .proxy)
            context.close(promise: nil)
            return
        }

        resolved = true
        let bufferedData = accumulated
        accumulated = ByteBuffer()
        let target = "\(sniHost):443"

        logger.log(.info, "Transparent proxy: SNI=\(sniHost), tunneling to \(target).", category: .proxy)

        nonisolated(unsafe) let ctx = context
        connectCoordinator.connectUpstreamTunnel(target: target)
            .hop(to: ctx.eventLoop)
            .whenComplete { [self] result in
                switch result {
                case .success(let (upstreamChannel, endpoint, _)):
                    if self.clientGone {
                        self.connectionPool.removeDedicatedTunnelByChannel(upstreamChannel)
                        upstreamChannel.close(mode: .all, promise: nil)
                        return
                    }
                    self.logger.log(.notice, "Transparent proxy: tunnel established for \(sniHost) via \(endpoint).", category: .proxy)
                    self.attachRelay(
                        context: ctx,
                        upstreamChannel: upstreamChannel,
                        initialData: bufferedData
                    )

                case .failure(let error):
                    self.logger.log(
                        .error,
                        "Transparent proxy: CONNECT to \(target) failed — \(error.localizedDescription)",
                        category: .proxy
                    )
                    ctx.close(promise: nil)
                }
            }
    }

    func channelInactive(context: ChannelHandlerContext) {
        clientGone = true
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        clientGone = true
        logger.log(.warning, "Transparent proxy: client error — \(error.localizedDescription)", category: .proxy)
        context.close(promise: nil)
    }

    private func attachRelay(
        context: ChannelHandlerContext,
        upstreamChannel: Channel,
        initialData: ByteBuffer
    ) {
        let clientChannel = context.channel

        let upstreamRelay = TransparentPeerRelay(
            peer: clientChannel,
            connectionPool: connectionPool,
            onClose: { [connectionPool] in
                connectionPool.removeDedicatedTunnelByChannel(upstreamChannel)
            }
        )
        let clientRelay = TransparentPeerRelay(peer: upstreamChannel, connectionPool: nil, onClose: nil)

        context.pipeline.removeHandler(self).whenComplete { _ in
            clientChannel.pipeline.addHandler(clientRelay).whenComplete { _ in
                upstreamChannel.pipeline.addHandler(upstreamRelay).whenComplete { _ in
                    if initialData.readableBytes > 0 {
                        upstreamChannel.writeAndFlush(initialData, promise: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Bidirectional Relay

private final class TransparentPeerRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    private let connectionPool: ConnectionPool?
    private let onClose: (@Sendable () -> Void)?

    init(peer: Channel, connectionPool: ConnectionPool?, onClose: (@Sendable () -> Void)?) {
        self.peer = peer
        self.connectionPool = connectionPool
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
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
        onClose?()
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose?()
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}

// MARK: - TLS ClientHello SNI Parser

package enum SNIParser {
    package static func extractSNI(from buffer: ByteBuffer) -> String? {
        guard buffer.readableBytes >= 5 else { return nil }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes)!
        return extractSNI(from: bytes)
    }

    package static func extractSNI(from bytes: [UInt8]) -> String? {
        guard bytes.count >= 5 else { return nil }

        guard bytes[0] == 0x16 else { return nil }
        guard bytes[1] == 0x03, bytes[2] >= 0x01, bytes[2] <= 0x04 else { return nil }

        let recordLength = (Int(bytes[3]) << 8) | Int(bytes[4])
        let recordEnd = min(5 + recordLength, bytes.count)
        guard recordEnd >= 43 else { return nil }

        var offset = 5

        guard bytes[offset] == 0x01 else { return nil }
        offset += 1

        let handshakeLength = (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
        offset += 3
        let handshakeEnd = min(offset + handshakeLength, recordEnd)

        offset += 2
        offset += 32

        guard offset < handshakeEnd else { return nil }
        let sessionIDLen = Int(bytes[offset])
        offset += 1 + sessionIDLen
        guard offset + 2 <= handshakeEnd else { return nil }

        let cipherSuitesLen = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2 + cipherSuitesLen
        guard offset < handshakeEnd else { return nil }

        let compressionLen = Int(bytes[offset])
        offset += 1 + compressionLen
        guard offset + 2 <= handshakeEnd else { return nil }

        let extensionsLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2
        let extensionsEnd = min(offset + extensionsLength, handshakeEnd)

        while offset + 4 <= extensionsEnd {
            let extType = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let extLength = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard offset + extLength <= extensionsEnd else { return nil }

            if extType == 0x0000 {
                return parseServerNameList(bytes, at: offset, length: extLength)
            }

            offset += extLength
        }

        return nil
    }

    private static func parseServerNameList(_ bytes: [UInt8], at start: Int, length: Int) -> String? {
        guard length >= 2 else { return nil }
        var offset = start
        let listEnd = start + length

        let listLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2
        let listBound = min(offset + listLength, listEnd)

        while offset + 3 <= listBound {
            let nameType = bytes[offset]
            offset += 1
            let nameLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard offset + nameLength <= listBound else { return nil }

            if nameType == 0x00, nameLength > 0, nameLength <= 253 {
                let nameBytes = Array(bytes[offset..<offset + nameLength])
                guard let hostname = String(bytes: nameBytes, encoding: .utf8) else { return nil }
                let lower = hostname.lowercased()
                guard isValidHostname(lower) else { return nil }
                return lower
            }

            offset += nameLength
        }

        return nil
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for char in label {
                guard char.isASCII, (char.isLetter || char.isNumber || char == "-") else {
                    return false
                }
            }
        }
        return true
    }
}
