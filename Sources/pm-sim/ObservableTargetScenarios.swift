// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import ProxyKernel

/// Observation values must lose URL secrets before any sink serializes them.
enum ObservableTargetScenarios {
    private struct Failure: Error { let message: String }

    @MainActor
    static func redaction() async throws -> ScenarioResult {
        let started = Date()
        let values = [
            "http://example.test/path?sig=s06q#s06f",
            "/path?sig=s06q#s06f", "/path#s06f?sig=s06q",
            "HTTPS://example.test/path#s06f", "http://[invalid/path?sig=s06q",
        ]
        for value in values {
            let observed = SensitiveValueSanitizer.observableTarget(value)
            let info = ActiveConnectionInfo(destination: value, upstream: "DIRECT", method: "GET")
            let event = RuntimeEvent(kind: .routing, event: "routing.test", detail: observed)
            let logs = RecordingLogSink()
            logs.log(.info, "Observed \(observed)", category: .proxy)
            // Exercise the sink backstop independently from call-site filtering.
            logs.log(.error, "Failed URL https://example.test/path?sig=s06q#s06f", category: .proxy)
            let encoder = CanonicalJSON.encoder()
            let timeout = ConnectionPool.upstreamResponseTimedOutEvent(uri: value, upstream: "synthetic:8080")
            let interrupted = ConnectionPool.streamingResponseInterruptedEvent(
                uri: value, upstream: "synthetic:8080", cause: NSError(domain: "synthetic", code: 1))
            let outputs = [timeout.detail ?? "", interrupted.detail ?? "", observed, SensitiveValueSanitizer.auditTarget(value),
                           String(decoding: try encoder.encode(info), as: UTF8.self),
                           String(decoding: try encoder.encode(event), as: UTF8.self)]
                + logs.entries().map(\.message)
            guard outputs.allSatisfy({ !$0.contains("s06q") && !$0.contains("s06f") }),
                  SensitiveValueSanitizer.observableTarget(observed) == observed else {
                throw Failure(message: "An observation retained a URL secret or redaction was not idempotent")
            }
        }
        try await rejectedConnect()
        return ScenarioResult(
            name: "observable-target-redaction", clientCount: 1, clientsOpened: 1, clientsWithFirstByte: 1,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: observed targets, logs, events, audit targets, and encoded connection records redact query/fragment secrets"]
        )
    }

    @MainActor
    private static func rejectedConnect() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let wire = NIOLockedValueBox<String?>(nil)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RejectCONNECT(wire: wire))
            }.bind(host: "127.0.0.1", port: 0).get()
        var config = GenericDefaults.shared.makeConfig()
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0)]
        let fixedConfig = config
        let logs = RecordingLogSink()
        let pool = ConnectionPool(group: group, logger: logs, configProvider: { fixedConfig },
                                  authenticatorProvider: { _ in MockAuthenticator() })
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logs)
        let target = "origin.example.test:443?sig=s06q#s06f"
        do {
            do {
                let connection = try await coordinator.connectUpstreamTunnel(target: target).get()
                try await connection.channel.close().get()
                throw Failure(message: "Rejecting upstream established a tunnel")
            } catch let error as ConnectionPoolError {
                let descriptions = [error.localizedDescription, String(describing: error)] + logs.entries().map(\.message)
                guard descriptions.allSatisfy({ !$0.contains("s06q") && !$0.contains("s06f") }) else {
                    throw Failure(message: "CONNECT error retained a target secret")
                }
            }
            guard wire.withLockedValue({ $0?.hasPrefix("CONNECT \(target) HTTP/1.1") == true }) else {
                throw Failure(message: "Observation redaction changed the CONNECT wire target")
            }
            pool.closeAll(scope: .all)
            try await server.close().get()
        } catch {
            pool.closeAll(scope: .all)
            try await server.close().get()
            throw error
        }
    }

    // Per-connection buffer is confined to its channel event loop.
    private final class RejectCONNECT: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private var bytes = ByteBufferAllocator().buffer(capacity: 1024)
        private let wire: NIOLockedValueBox<String?>
        init(wire: NIOLockedValueBox<String?>) { self.wire = wire }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var incoming = unwrapInboundIn(data)
            guard bytes.readableBytes + incoming.readableBytes <= 8192 else {
                context.close(promise: nil)
                return
            }
            bytes.writeBuffer(&incoming)
            guard let request = bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes),
                  request.contains("\r\n\r\n") else { return }
            wire.withLockedValue { $0 = request }
            var response = context.channel.allocator.buffer(capacity: 64)
            response.writeString("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in channel.close(promise: nil) }
        }
    }

}
