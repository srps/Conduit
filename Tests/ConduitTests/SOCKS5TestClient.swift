// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest

/// A SOCKS5 client a test steps through by hand: greeting, CONNECT request,
/// then whatever the tunnel carries.
final class SOCKS5TestClient: Sendable {
    let channel: Channel
    private let received: NIOLockedValueBox<[UInt8]>

    private init(channel: Channel, received: NIOLockedValueBox<[UInt8]>) {
        self.channel = channel
        self.received = received
    }

    static func connect(to port: Int, group: EventLoopGroup) async throws -> SOCKS5TestClient {
        let received = NIOLockedValueBox<[UInt8]>([])
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(Collector(bytes: received)) }
            .connect(host: "127.0.0.1", port: port).get()
        return SOCKS5TestClient(channel: channel, received: received)
    }

    /// One CONNECT on a fresh connection; returns the reply code.
    static func reply(connecting host: String, port: Int, through proxyPort: Int, group: EventLoopGroup) async throws -> UInt8? {
        let client = try await connect(to: proxyPort, group: group)
        try await client.greet()
        let reply = try await client.request(host: host, port: port)
        client.channel.close(promise: nil)
        return reply
    }

    /// Offers "no authentication" and waits for the listener to select it.
    func greet() async throws {
        try await send([0x05, 0x01, 0x00])
        try await waitForBytes(2)
        XCTAssertEqual(bytes(from: 0, count: 2), [0x05, 0x00])
    }

    func sendRequest(host: String, port: Int) async throws {
        var request: [UInt8] = [0x05, 0x01, 0x00]
        if let address = try? SocketAddress(ipAddress: host, port: port), case .v4(let v4) = address {
            request.append(0x01)
            withUnsafeBytes(of: v4.address.sin_addr) { request.append(contentsOf: $0) }
        } else if let address = try? SocketAddress(ipAddress: host, port: port), case .v6(let v6) = address {
            request.append(0x04)
            withUnsafeBytes(of: v6.address.sin6_addr) { request.append(contentsOf: $0) }
        } else {
            request.append(contentsOf: [0x03, UInt8(host.utf8.count)])
            request.append(contentsOf: Array(host.utf8))
        }
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
        try await send(request)
    }

    /// Sends a CONNECT request and returns the reply code, nil when the
    /// listener closed without one.
    func request(host: String, port: Int) async throws -> UInt8? {
        try await sendRequest(host: host, port: port)
        try await waitForBytes(4)
        return bytes(from: 3, count: 1).first
    }

    func send(_ bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Everything received so far, the two-byte method selection and the
    /// ten-byte reply included.
    var receivedBytes: [UInt8] { received.withLockedValue { $0 } }

    /// Returns once `count` bytes have arrived or the listener closed.
    func waitForBytes(_ count: Int) async throws {
        for _ in 0..<800 where received.withLockedValue({ $0.count }) < count && channel.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilClosed() async throws {
        for _ in 0..<800 where channel.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func bytes(from offset: Int, count: Int) -> [UInt8] {
        received.withLockedValue { $0.count >= offset + count ? Array($0[offset..<(offset + count)]) : [] }
    }

    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let bytes: NIOLockedValueBox<[UInt8]>
        init(bytes: NIOLockedValueBox<[UInt8]>) { self.bytes = bytes }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let read = buffer.readBytes(length: buffer.readableBytes) ?? []
            bytes.withLockedValue { if $0.count < 4096 { $0.append(contentsOf: read) } }
        }
    }
}
