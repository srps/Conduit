// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A loopback UDP DNS server standing in for a split-DNS server. It answers an A query for a name at or under
/// `domain` with `ip`, and every other name with NXDOMAIN, and counts the queries per name.
final class FakeSplitDNSServer: @unchecked Sendable {
    let channel: Channel
    private let asked: NIOLockedValueBox<[String: Int]>

    var port: Int { channel.localAddress?.port ?? 0 }

    func queryCount(_ name: String) -> Int { asked.withLockedValue { $0[name] ?? 0 } }
    var totalQueries: Int { asked.withLockedValue { $0.values.reduce(0, +) } }

    private init(channel: Channel, asked: NIOLockedValueBox<[String: Int]>) {
        self.channel = channel
        self.asked = asked
    }

    static func start(domain: String, ip: String) async throws -> FakeSplitDNSServer {
        let asked = NIOLockedValueBox<[String: Int]>([:])
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(Responder(domain: domain, ip: ip, asked: asked)) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return FakeSplitDNSServer(channel: channel, asked: asked)
    }

    func stop() async {
        try? await channel.close()
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let domain: String
        private let ip: String
        private let asked: NIOLockedValueBox<[String: Int]>

        init(domain: String, ip: String, asked: NIOLockedValueBox<[String: Int]>) {
            self.domain = domain
            self.ip = ip
            self.asked = asked
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            var buffer = envelope.data
            let query = buffer.readBytes(length: buffer.readableBytes) ?? []
            let name = DNSWireFormat.extractDomainName(from: query).lowercased()
            asked.withLockedValue { $0[name, default: 0] += 1 }
            let mine = name == domain || name.hasSuffix(".\(domain)")
            let answer = mine
                ? DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: ip)
                : DNSWireFormat.emptyDNSResponse(originalQuery: query, rcode: 3)
            guard let answer else { return }
            var out = context.channel.allocator.buffer(capacity: answer.count)
            out.writeBytes(answer)
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
        }
    }
}

enum SplitDNSProbe {
    /// The first A record a forwarder on `port` answers for `name`, or nil when it answers none within ten seconds.
    static func resolve(_ name: String, port: Int, txID: UInt16 = 0x5D00) async throws -> String? {
        let group = MultiThreadedEventLoopGroup.singleton
        let collector = UDPReplyCollector()
        let client = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { client.close(promise: nil) }
        let query = DNSWireFormat.buildQuery(domain: name, txID: txID)
        var buffer = client.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buffer)).get()
        for _ in 0..<1000 where collector.replies().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.replies().first.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
    }

    /// A tuning that reaches each split-DNS server at the loopback port `endpoints` names for its address. A server
    /// it does not name goes to port 9 on loopback, where nothing answers.
    static func tuning(_ endpoints: [String: Int]) -> DNSForwarderTuning {
        var tuning = DNSForwarderTuning()
        tuning.internalServerEndpoint = { server in ("127.0.0.1", endpoints[server] ?? 9) }
        return tuning
    }
}
