// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

package final class TunnelDNSResponder: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let overrides: NIOLockedValueBox<[String: String]>
    private var channel: Channel?

    package init(group: EventLoopGroup, logger: any LogSink) {
        self.group = group
        self.logger = logger
        self.overrides = NIOLockedValueBox([:])
    }

    package func start(host: String, port: Int) async throws {
        if let existing = channel, existing.isActive {
            _ = try? await existing.close().get()
        }
        let handler = TunnelDNSHandler(overrides: overrides, logger: logger)
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel = bound
        let actualPort = bound.localAddress?.port ?? port
        logger.log(.notice, "Tunnel DNS responder listening on \(host):\(actualPort).", category: .tunnel)
    }

    package func stop() async {
        if let channel {
            _ = try? await channel.close().get()
        }
        channel = nil
        overrides.withLockedValue { $0.removeAll() }
        logger.log(.notice, "Tunnel DNS responder stopped.", category: .tunnel)
    }

    package func updateHostnames(_ mapping: [String: String]) {
        overrides.withLockedValue { $0 = mapping }
    }

    package var activeOverrides: [String: String] {
        overrides.withLockedValue { $0 }
    }
}

private final class TunnelDNSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let overrides: NIOLockedValueBox<[String: String]>
    private let logger: any LogSink

    init(overrides: NIOLockedValueBox<[String: String]>, logger: any LogSink) {
        self.overrides = overrides
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let clientAddress = envelope.remoteAddress
        var queryBuffer = envelope.data
        let queryBytes = queryBuffer.readBytes(length: queryBuffer.readableBytes) ?? []
        guard queryBytes.count >= 12 else { return }

        let domain = DNSWireFormat.extractDomainName(from: queryBytes).lowercased()
        let ip = overrides.withLockedValue { $0[domain] }

        guard let listenIP = ip else {
            if let refused = DNSWireFormat.emptyRefusedResponse(originalQuery: queryBytes) {
                var buf = context.channel.allocator.buffer(capacity: refused.count)
                buf.writeBytes(refused)
                let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            }
            return
        }

        guard let responseBytes = DNSWireFormat.synthesizeDirectResponse(originalQuery: queryBytes, ip: listenIP) else {
            logger.log(.warning, "Tunnel DNS: failed to synthesize response for \(domain).", category: .tunnel)
            if let servfail = DNSWireFormat.emptyDNSResponse(originalQuery: queryBytes, rcode: 2) {
                var buf = context.channel.allocator.buffer(capacity: servfail.count)
                buf.writeBytes(servfail)
                let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            }
            return
        }

        let qtype = DNSWireFormat.extractQueryType(from: queryBytes)
        logger.log(.debug, "Tunnel DNS: \(domain) → \(listenIP) (type \(qtype == 28 ? "AAAA→NODATA" : "A")).", category: .tunnel)

        var buf = context.channel.allocator.buffer(capacity: responseBytes.count)
        buf.writeBytes(responseBytes)
        let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }
}
