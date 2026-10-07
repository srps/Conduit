// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// Request bodies too large to buffer in memory, through a real listener.
///
/// 1. A body that crosses the memory threshold over several reads reaches
///    the upstream whole. Chunks read before the spool existed used to start
///    a spool of their own, and the body lost everything before them.
/// 2. #81: with the spool directory unavailable, the client connection is
///    closed with a structured `request.body_spool_failed` naming the cause.
/// 3. With the directory back, the same request spools and arrives whole.
///
/// Only this process's spool directory is touched (a file is put where it
/// should be); the shared root also serves any Conduit running as this user.
enum RequestBodySpoolScenarios {
    private static let bodySize = 65_536

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "request-body-spool"
        let group = MultiThreadedEventLoopGroup.singleton
        let started = Date()
        var notes: [String] = []

        let upstream = BodyCountingUpstream()
        ScenarioCleanup.register { upstream.stop() }
        try await upstream.start(group: group)

        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.socksEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.maxBufferedBodyBytes = 1_024
        config.maxSpooledBodyBytes = 1_048_576
        config.upstreams = [UpstreamProxy(name: "Counting", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let fixed = config

        let events = RuntimeEventLog(capacity: 64)
        let server = LocalProxyServer(
            logger: ConsoleLogSink(minLevel: verbose ? .debug : .error), configProvider: { fixed },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink(), ttlSeconds: 30, baseTimeoutMS: 500),
            pacRoutingEngine: nil, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }, eventSink: { events.append($0) }
        )
        ScenarioCleanup.register { await server.stop() }
        try await server.start()
        guard let port = server.listeningPort else {
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "proxy did not bind"])
        }

        let body = String(repeating: "x", count: bodySize)
        let target = "origin.example.test"
        let request = "POST http://\(target)/upload HTTP/1.1\r\nHost: \(target)\r\nContent-Length: \(bodySize)\r\nConnection: close\r\n\r\n\(body)"
        func send() async -> String {
            do {
                return try await RawHTTPAuditClient.request(group: group, host: "127.0.0.1", port: port, request: request)
            } catch {
                return "error: \(error)"
            }
        }
        func spoolFailures() -> [RuntimeEvent] { events.events.filter { $0.event == "request.body_spool_failed" } }
        let whole = "got=\(bodySize)"

        // Phase 1. Also runs the process's one-time startup sweep, which
        // would otherwise remove the blocker below as a stale entry.
        let intact = await send()
        notes.append("intact: \(intact.split(separator: "\r\n").last.map(String.init) ?? intact)")

        // Phase 2: a file where this process's spool directory should be.
        let directory = SpooledHTTPRequestBody.processSpoolDirectory
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Nothing spooled since the last request cleaned up: fine.
        }
        let blockerPlaced = fileManager.createFile(atPath: directory.path, contents: Data("blocker".utf8))
        let blocked = await send()
        try await waitUntil { !spoolFailures().isEmpty }
        try fileManager.removeItem(at: directory)
        let failure = spoolFailures().first
        notes.append("blocked: response=\(blocked.prefix(40).debugDescription) event=\(failure?.detail ?? "none")")

        // Phase 3: the directory can be created again.
        let restored = await send()
        notes.append("restored: \(restored.split(separator: "\r\n").last.map(String.init) ?? restored)")

        await server.stop()
        return ScenarioResult(
            name: name, clientCount: 3, clientsOpened: 3, clientsWithFirstByte: 2, clientsClosedEarly: 1,
            totalBytes: 0, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("intact: a spooled body reaches the upstream whole", intact.hasSuffix(whole)),
                .init("blocked: the blocker is in place", blockerPlaced),
                .init("blocked: the client got no response", !blocked.hasPrefix("HTTP/")),
                .init("blocked: one request.body_spool_failed", spoolFailures().count == 1),
                .init("blocked: the event names the target and the unavailable directory",
                      failure?.detail?.contains("target=http://\(target)/upload") == true
                          && failure?.detail?.contains("spool directory") == true),
                .init("restored: the body spools and reaches the upstream whole", restored.hasSuffix(whole)),
                .init("restored: no further spool failure", spoolFailures().count == 1),
            ],
            notes: notes
        )
    }

    /// Polls a condition; the deadline only keeps a regression from hanging pm-sim.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// An upstream that reads a request's `Content-Length` body and answers with
/// how many body bytes arrived (`got=N`), as soon as it has them all.
private final class BodyCountingUpstream: @unchecked Sendable {
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }

    func start(group: EventLoopGroup) async throws {
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(BodyCountingHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() {
        channel?.close(promise: nil)
    }
}

private final class BodyCountingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var received: [UInt8] = []
    private var answered = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readBytes(length: buffer.readableBytes) ?? []
        guard !answered, let headEnd = received.firstRange(of: Array("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let got = received.count - headEnd.upperBound
        guard got >= length else { return }
        answered = true
        let answer = "got=\(got)"
        let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(answer.utf8.count)\r\nConnection: close\r\n\r\n\(answer)"
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: reply)), promise: nil)
    }
}
