// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

/// Server-first protocols (SSH banners, SMTP/FTP greetings) through an
/// upstream proxy. The fake upstream writes its `200` and the first greeting
/// in one write, then a second greeting, all before the client says anything;
/// the client must receive both, exactly and in order, then an echo of what
/// it sends. Loss, reordering, or a hang throws, so pm-sim exits nonzero.
enum ServerFirstScenarios {
    enum Entry: String { case httpConnect = "server-first-connect", socks5 = "server-first-socks5" }

    private static let greetings: [[UInt8]] = [
        Array("SSH-2.0-SimServer\r\n".utf8) + [0x00, 0xff, 0x0d, 0x0a],
        Array("220 second greeting\r\n".utf8),
    ]
    private static let clientBytes = Array("CLIENT-AFTER-GREETING".utf8)

    @MainActor
    static func run(_ entry: Entry, verbose: Bool) async throws -> ScenarioResult {
        let start = Date()
        let harness = SimHarness(verbose: verbose)
        do {
            try await harness.start(
                originBehavior: .echo,
                socksEnabled: entry == .socks5,
                upstreamServerFirst: greetings
            )
            let originPort = harness.origin?.port ?? 0
            let handshake: ServerFirstClientHandler.Handshake
            let port: Int
            switch entry {
            case .httpConnect:
                let target = "127.0.0.1:\(originPort)"
                handshake = .httpConnect("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
                port = harness.localProxyPort
            case .socks5:
                guard let socksPort = harness.server?.socksListeningPort else {
                    throw ServerFirstScenarioError.failed("SOCKS5 listener did not start")
                }
                handshake = .socks5(originPort: UInt16(originPort))
                port = socksPort
            }
            let expectedGreeting = greetings.flatMap { $0 }
            let tunnel = try await ServerFirstClient.run(
                group: harness.group, host: harness.localProxyHost, port: port, handshake: handshake,
                greetingLength: expectedGreeting.count, clientBytes: clientBytes
            )
            guard tunnel == expectedGreeting + clientBytes else {
                throw ServerFirstScenarioError.failed(
                    "tunnel bytes were lost, reordered or duplicated: got \(tunnel.count) bytes, "
                        + "expected \(expectedGreeting.count + clientBytes.count)"
                )
            }
            guard harness.upstream?.connectCount == 1 else {
                throw ServerFirstScenarioError.failed("the tunnel did not go through the upstream")
            }
            await harness.stop()
            return ScenarioResult(
                name: entry.rawValue,
                clientCount: 1, clientsOpened: 1, clientsWithFirstByte: 1, clientsClosedEarly: 0,
                totalBytes: tunnel.count, durationSeconds: Date().timeIntervalSince(start), aggregateMBps: 0,
                minBytes: tunnel.count, maxBytes: tunnel.count, medianBytes: tunnel.count,
                earliestClose: nil, latestClose: nil,
                notes: ["PASS: server-first greetings, then the client's echo, arrived exactly in order"]
            )
        } catch {
            await harness.stop()
            throw error
        }
    }
}

private enum ServerFirstScenarioError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Completes the proxy handshake, then collects tunnel bytes: it speaks only
/// after the whole greeting has arrived, so a lost greeting times out.
private final class ServerFirstClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum Handshake {
        case httpConnect(String)
        case socks5(originPort: UInt16)
    }

    private enum Phase { case httpResponse, socksMethod, socksReply, tunnel }

    private let handshake: Handshake
    private let greetingLength: Int
    private let clientBytes: [UInt8]
    private let promise: EventLoopPromise<[UInt8]>
    private var phase: Phase
    private var pending: [UInt8] = []
    private var tunnel: [UInt8] = []
    private var sentClientBytes = false

    init(handshake: Handshake, greetingLength: Int, clientBytes: [UInt8], promise: EventLoopPromise<[UInt8]>) {
        self.handshake = handshake
        self.greetingLength = greetingLength
        self.clientBytes = clientBytes
        self.promise = promise
        switch handshake {
        case .httpConnect: phase = .httpResponse
        case .socks5: phase = .socksMethod
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        switch handshake {
        case .httpConnect(let request): write(Array(request.utf8), context: context)
        case .socks5: write([0x05, 0x01, 0x00], context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        advance(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ServerFirstScenarioError.failed("closed after \(tunnel.count) tunnel bytes"))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    private func advance(context: ChannelHandlerContext) {
        switch phase {
        case .httpResponse:
            let terminator: [UInt8] = [13, 10, 13, 10]
            guard let end = pending.indices.first(where: { pending[$0...].starts(with: terminator) }) else { return }
            guard pending.starts(with: Array("HTTP/1.1 200 ".utf8)) else {
                return fail("CONNECT was refused", context: context)
            }
            pending.removeFirst(end + terminator.count)
            phase = .tunnel
        case .socksMethod:
            guard pending.count >= 2 else { return }
            guard pending[0] == 0x05, pending[1] == 0x00 else { return fail("SOCKS5 method refused", context: context) }
            pending.removeFirst(2)
            if case .socks5(let port) = handshake {
                write([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xff)], context: context)
            }
            phase = .socksReply
        case .socksReply:
            guard pending.count >= 10 else { return }
            guard pending[0] == 0x05, pending[1] == 0x00 else { return fail("SOCKS5 CONNECT refused", context: context) }
            pending.removeFirst(10)
            phase = .tunnel
        case .tunnel:
            tunnel += pending
            pending.removeAll()
            if !sentClientBytes, tunnel.count >= greetingLength {
                sentClientBytes = true
                write(clientBytes, context: context)
            }
            if tunnel.count >= greetingLength + clientBytes.count {
                promise.succeed(tunnel)
                context.close(promise: nil)
            }
            return
        }
        advance(context: context)
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func fail(_ message: String, context: ChannelHandlerContext) {
        promise.fail(ServerFirstScenarioError.failed(message))
        context.close(promise: nil)
    }
}

private enum ServerFirstClient {
    static func run(
        group: EventLoopGroup,
        host: String,
        port: Int,
        handshake: ServerFirstClientHandler.Handshake,
        greetingLength: Int,
        clientBytes: [UInt8]
    ) async throws -> [UInt8] {
        let promise = group.next().makePromise(of: [UInt8].self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(ServerFirstScenarioError.failed("timed out waiting for the server-first greeting"))
        }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ServerFirstClientHandler(
                    handshake: handshake, greetingLength: greetingLength, clientBytes: clientBytes, promise: promise
                ))
            }
            .connect(host: host, port: port)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.always { _ in timeout.cancel() }.get()
    }
}
