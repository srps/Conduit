// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import ProxyKernel

/// Small real-listener pressure test; never approaches the host's descriptor limit.
enum AdmissionScenarios {
    private struct Failure: Error { let message: String }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }

    @MainActor
    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: message)
    }

    @MainActor
    private final class Fixture {
        let group = MultiThreadedEventLoopGroup.singleton
        let config = NIOLockedValueBox(GenericDefaults.shared.makeConfig())
        let events = RuntimeEventLog(capacity: 32)
        let logger: ConsoleLogSink
        let server: LocalProxyServer
        let origin: FakeOrigin
        private(set) var clients: [Channel] = [] // Fixture has at most fourteen peers.

        init(verbose: Bool) {
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .error)
            let config = self.config
            config.withLockedValue {
                $0.localPort = 0
                $0.socksEnabled = true
                $0.socksPort = 0
                $0.localPACEnabled = false
                $0.inboundConnectionMaxLimit = 4
                $0.inboundConnectionWarnThreshold = 2
            }
            let events = self.events
            server = LocalProxyServer(
                logger: logger, configProvider: { config.withLockedValue { $0 } },
                directModeProvider: { (true, .vpnDisconnected) },
                authenticatorProvider: { _ in MockAuthenticator() },
                directConnectDetector: DirectConnectDetector(group: group, logger: logger, ttlSeconds: 30, baseTimeoutMS: 100),
                pacRoutingEngine: nil, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
                onRequestCompleted: { _, _ in }, eventSink: { events.append($0) },
                socksHandshakeTimeout: .seconds(1)
            )
            origin = FakeOrigin(group: group, behavior: .silent)
            self.logger = logger
        }

        func start() async throws {
            try await server.start()
            try await origin.start()
        }

        private func connect(_ port: Int) async throws -> Channel {
            precondition(clients.count < 14)
            let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
                .connect(host: "127.0.0.1", port: port).get()
            clients.append(channel)
            return channel
        }

        private func write(_ channel: Channel, _ bytes: [UInt8]) async throws {
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await channel.writeAndFlush(buffer).get()
        }

        func run() async throws {
            guard let http = server.listeningPort, let socks = server.socksListeningPort else {
                throw Failure(message: "Missing listeners")
            }
            _ = try await connect(http)
            _ = try await connect(http)
            let idle = try await connect(socks)
            let drip = try await connect(socks)
            try await write(drip, [5, 1, 0, 5])
            try await eventually("Both protocols must consume the shared cap") { server.inboundConnectionCount == 4 }
            let rejectedHTTP = try await connect(http)
            let rejectedSOCKS = try await connect(socks)
            try await eventually("Excess peers were not rejected") { !rejectedHTTP.isActive && !rejectedSOCKS.isActive }
            try require(server.inboundConnectionCount == 4, "Rejected peers consumed permits")
            try await Task.sleep(for: .milliseconds(500))
            try await write(drip, [1])
            try await Task.sleep(for: .milliseconds(700))
            try require(!idle.isActive && !drip.isActive, "Greeting/request deadline was extended by partial progress")
            try await eventually("Timeouts leaked permits") { server.inboundConnectionCount == 2 }
            try require(events.events.filter { $0.event == "connection.socks5_handshake_timeout" }.count == 2,
                        "Missing handshake timeout events")
            let invalid = try await connect(socks)
            try await write(invalid, [4, 1, 0])
            try await eventually("Malformed greeting did not release permit") { !invalid.isActive && server.inboundConnectionCount == 2 }
            let port = UInt16(origin.port)
            let oversized = try await connect(socks)
            let greetingAndRequest: [UInt8] = [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]
            try await write(oversized, greetingAndRequest + Array(repeating: 0x41, count: 1024))
            try await eventually("Oversized negotiation did not release permit") { !oversized.isActive && server.inboundConnectionCount == 2 }
            let early = try await connect(socks)
            try await write(early, [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255), 42])
            try await eventually("Early payload did not release permit") { !early.isActive && server.inboundConnectionCount == 2 }
            try require(origin.connectionCount == 0, "Early payload started routing before rejection")
            let tunnel = try await connect(socks)
            try await write(tunnel, [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)])
            try await eventually("Recovered SOCKS connection did not reach origin") { origin.connectionCount == 1 }
            try await Task.sleep(for: .milliseconds(1200))
            try require(tunnel.isActive, "Handshake deadline closed an established tunnel")
            for limit in [2, 0, -1] {
                config.withLockedValue { $0.inboundConnectionMaxLimit = limit; $0.inboundConnectionWarnThreshold = 1 }
                let reduced = try await connect(http)
                try await eventually("Lowered live budget admitted a new peer") { !reduced.isActive }
                try require(tunnel.isActive, "Lowered budget evicted an existing tunnel")
                try require(server.inboundConnectionCount == 3, "Live limit edit lost an existing reservation")
            }
            config.withLockedValue { $0.inboundConnectionMaxLimit = 2 }
            for channel in clients where channel.isActive { try await channel.close().get() }
            try await eventually("Client closes leaked admission permits") { server.inboundConnectionCount == 0 }
            let recovered = try await connect(http)
            try await eventually("HTTP did not recover capacity") { server.inboundConnectionCount == 1 }
            try await recovered.close().get()
            try await eventually("Final permit leaked") { server.inboundConnectionCount == 0 }
            let rejections = events.events.filter { $0.event == "connection.inbound_limit_rejected" }
            try require(rejections.count == 5, "Missing mixed-protocol rejection events")
        }

        func stop() async {
            for channel in clients where channel.isActive {
                do { try await channel.close().get() }
                catch { logger.log(.warning, "Fixture cleanup failed: \(error)", category: .proxy) }
            }
            await server.stop()
            await origin.stop()
        }
    }

    @MainActor
    static func sharedBudget(verbose: Bool) async throws -> ScenarioResult {
        let start = Date()
        let fixture = Fixture(verbose: verbose)
        do {
            try await fixture.start()
            try await fixture.run()
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
        return ScenarioResult(
            name: "shared-inbound-budget", clientCount: fixture.clients.count, clientsOpened: fixture.clients.count,
            clientsWithFirstByte: 1, clientsClosedEarly: 5, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: combined admission, idle/drip deadlines, malformed greeting release, live limit reduction, tunnel survival and recovery"]
        )
    }
}
