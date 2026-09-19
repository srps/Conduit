// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

struct ScenarioResult: Sendable {
    var name: String
    var clientCount: Int
    var clientsOpened: Int
    var clientsWithFirstByte: Int
    var clientsClosedEarly: Int
    var totalBytes: Int
    var durationSeconds: Double
    var aggregateMBps: Double
    var minBytes: Int
    var maxBytes: Int
    var medianBytes: Int
    var earliestClose: Double?
    var latestClose: Double?
    var assertions: [ScenarioAssertion]
    var notes: [String]

    var passed: Bool { !assertions.isEmpty && assertions.allSatisfy(\.passed) }
}

enum Scenarios {
    // MARK: - Baseline: single bursty stream

    @MainActor
    static func baselineBurst(verbose: Bool) async throws -> ScenarioResult {
        let name = "baselineBurst"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .burstStream(intervalMs: 50, chunkSize: 16_384, durationMs: 15_000)
        )

        let start = Date()
        let client = FakeClient(
            id: 0,
            group: harness.group,
            localProxyHost: harness.localProxyHost,
            localProxyPort: harness.localProxyPort,
            target: "burst.example:443",
            behavior: .sendOnceThenListen(requestBytes: 256)
        )
        try await client.run()
        await client.waitForClose(timeout: 20)
        let elapsed = Date().timeIntervalSince(start)
        let m = client.metrics
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: m.connectEstablishedAt != nil ? 1 : 0,
            clientsWithFirstByte: m.firstByteAt != nil ? 1 : 0,
            clientsClosedEarly: (m.bytesReceived < 100_000 ? 1 : 0),
            totalBytes: m.bytesReceived,
            durationSeconds: elapsed,
            aggregateMBps: Double(m.bytesReceived) / 1_048_576.0 / elapsed,
            minBytes: m.bytesReceived,
            maxBytes: m.bytesReceived,
            medianBytes: m.bytesReceived,
            earliestClose: m.closedAt?.timeIntervalSince(start),
            latestClose: m.closedAt?.timeIntervalSince(start),
            assertions: [
                .init("tunnel established", m.connectEstablishedAt != nil),
                .init("bursty stream made progress", m.bytesReceived >= 100_000),
                .init("stream closed within deadline", m.closedAt != nil),
            ],
            notes: ["serverStreamedFor=15s", "interval=50ms", "chunk=16KB"]
        )
    }

    // MARK: - Multi-concurrent bursty streams (high throughput, concurrency)

    @MainActor
    static func multiConcurrent(clientCount: Int, durationSeconds: Int, verbose: Bool) async throws -> ScenarioResult {
        let name = "multiConcurrent(n=\(clientCount))"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .burstStream(
                intervalMs: 25,
                chunkSize: 8192,
                durationMs: durationSeconds * 1000
            ),
            maxConnections: max(clientCount * 4, 64)
        )

        let start = Date()
        var clients: [FakeClient] = []
        for i in 0..<clientCount {
            let client = FakeClient(
                id: i,
                group: harness.group,
                localProxyHost: harness.localProxyHost,
                localProxyPort: harness.localProxyPort,
                target: "multi\(i).example:443",
                behavior: .sendOnceThenListen(requestBytes: 256)
            )
            clients.append(client)
        }

        try await withThrowingTaskGroup(of: Void.self) { g in
            for c in clients {
                g.addTask { try await c.run() }
            }
            try await g.waitForAll()
        }

        await withTaskGroup(of: Void.self) { g in
            for c in clients {
                g.addTask { await c.waitForClose(timeout: TimeInterval(durationSeconds + 10)) }
            }
            await g.waitForAll()
        }

        let elapsed = Date().timeIntervalSince(start)
        let metrics = clients.map { $0.metrics }
        let byteCounts = metrics.map { $0.bytesReceived }.sorted()
        let total = byteCounts.reduce(0, +)
        let median = byteCounts.isEmpty ? 0 : byteCounts[byteCounts.count / 2]
        let closedTimes = metrics.compactMap { $0.closedAt?.timeIntervalSince(start) }
        let opened = metrics.filter { $0.connectEstablishedAt != nil }.count
        let firstByteCount = metrics.filter { $0.firstByteAt != nil }.count
        let earlyClose = metrics.filter { $0.bytesReceived < 1024 }.count

        return ScenarioResult(
            name: name,
            clientCount: clientCount,
            clientsOpened: opened,
            clientsWithFirstByte: firstByteCount,
            clientsClosedEarly: earlyClose,
            totalBytes: total,
            durationSeconds: elapsed,
            aggregateMBps: Double(total) / 1_048_576.0 / elapsed,
            minBytes: byteCounts.first ?? 0,
            maxBytes: byteCounts.last ?? 0,
            medianBytes: median,
            earliestClose: closedTimes.min(),
            latestClose: closedTimes.max(),
            assertions: [
                .init("all tunnels established", opened == clientCount),
                .init("all streams made progress", firstByteCount == clientCount && earlyClose == 0),
                .init("all streams closed within deadline", closedTimes.count == clientCount),
            ],
            notes: [
                "serverStreamedFor=\(durationSeconds)s",
                "interval=25ms",
                "chunk=8KB",
                "concurrent=\(clientCount)"
            ]
        )
    }

    // MARK: - Connection flood: deliberate inbound pressure

    @MainActor
    static func connectionFlood(verbose: Bool) async throws -> ScenarioResult {
        let name = "connectionFlood(inbound-limit)"
        let inboundLimit = 8
        let clientCount = 40
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silent,
            maxConnections: 64,
            inboundConnectionLimit: inboundLimit,
            inboundConnectionWarnThreshold: inboundLimit / 2
        )

        let start = Date()
        let clients = (0..<clientCount).map { i in
            FakeClient(
                id: i,
                group: harness.group,
                localProxyHost: harness.localProxyHost,
                localProxyPort: harness.localProxyPort,
                target: "flood-\(i).example:443",
                behavior: .sendOnceThenListen(requestBytes: 16)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { try await client.run() }
            }
            try await group.waitForAll()
        }

        try await Task.sleep(for: .milliseconds(500))
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.waitForClose(timeout: 0.2) }
            }
        }

        let openedDuringFlood = clients.filter { $0.metrics.connectEstablishedAt != nil }.count
        let rejectedDuringFlood = clients.filter { $0.metrics.connectEstablishedAt == nil || $0.metrics.closedAt != nil }.count

        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.close() }
            }
        }
        try await Task.sleep(for: .milliseconds(200))

        let probe = FakeClient(
            id: clientCount,
            group: harness.group,
            localProxyHost: harness.localProxyHost,
            localProxyPort: harness.localProxyPort,
            target: "post-flood.example:443",
            behavior: .sendOnceThenListen(requestBytes: 16)
        )
        try await probe.run()
        try await Task.sleep(for: .milliseconds(200))
        let probeSucceeded = probe.metrics.connectEstablishedAt != nil
        await probe.close()

        guard rejectedDuringFlood > 0, probeSucceeded else {
            throw NSError(
                domain: "pm-sim.connectionFlood",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "expected flood rejection and post-drain success, rejected=\(rejectedDuringFlood), probeSucceeded=\(probeSucceeded)"
                ]
            )
        }

        let elapsed = Date().timeIntervalSince(start)
        return ScenarioResult(
            name: name,
            clientCount: clientCount + 1,
            clientsOpened: openedDuringFlood + (probeSucceeded ? 1 : 0),
            clientsWithFirstByte: 0,
            clientsClosedEarly: rejectedDuringFlood,
            totalBytes: 0,
            durationSeconds: elapsed,
            aggregateMBps: 0,
            minBytes: 0,
            maxBytes: 0,
            medianBytes: 0,
            earliestClose: nil,
            latestClose: nil,
            assertions: [
                .init("flood rejected excess clients", rejectedDuringFlood > 0),
                .init("post-drain connection succeeded", probeSucceeded),
            ],
            notes: [
                "inboundLimit=\(inboundLimit)",
                "floodClients=\(clientCount)",
                "openedDuringFlood=\(openedDuringFlood)",
                "rejectedDuringFlood=\(rejectedDuringFlood)",
                "postDrainProbe=\(probeSucceeded ? "PASS" : "FAIL")"
            ]
        )
    }

    // MARK: - Auth storm: pending handshake bound

    @MainActor
    static func authStorm(verbose: Bool) async throws -> ScenarioResult {
        let name = "authStorm(pending-handshake-bound)"
        let clientCount = 24
        let perSourceLimit = 2
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silent,
            maxConnections: 64,
            pendingAuthHandshakeGlobalLimit: 8,
            pendingAuthHandshakesPerSource: perSourceLimit,
            authenticatorProvider: { _ in SlowMockAuthenticator(delayMs: 700) }
        )

        let start = Date()
        let clients = (0..<clientCount).map { i in
            FakeClient(
                id: i,
                group: harness.group,
                localProxyHost: harness.localProxyHost,
                localProxyPort: harness.localProxyPort,
                target: "auth-storm-\(i).example:443",
                behavior: .sendOnceThenListen(requestBytes: 16)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { try await client.run() }
            }
            try await group.waitForAll()
        }

        try await Task.sleep(for: .milliseconds(500))
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.waitForClose(timeout: 0.2) }
            }
        }

        let rejected = clients.filter { $0.metrics.connectEstablishedAt == nil && $0.metrics.closedAt != nil }.count
        let opened = clients.filter { $0.metrics.connectEstablishedAt != nil }.count

        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.close() }
            }
        }

        guard rejected > 0 else {
            throw NSError(
                domain: "pm-sim.authStorm",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected pending-auth limiter to reject some clients"]
            )
        }

        return ScenarioResult(
            name: name,
            clientCount: clientCount,
            clientsOpened: opened,
            clientsWithFirstByte: 0,
            clientsClosedEarly: rejected,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0,
            maxBytes: 0,
            medianBytes: 0,
            earliestClose: nil,
            latestClose: nil,
            assertions: [.init("pending-auth limiter rejected excess clients", rejected > 0)],
            notes: [
                "perSourceLimit=\(perSourceLimit)",
                "clients=\(clientCount)",
                "opened=\(opened)",
                "rejected=\(rejected)"
            ]
        )
    }

    // MARK: - Silent-then-burst: confirms tunnel survives long quiet periods

    @MainActor
    static func silentThenBurst(silentForMs: Int, burstBytes: Int, verbose: Bool) async throws -> ScenarioResult {
        let name = "silentThenBurst(silent=\(silentForMs)ms)"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silentThenBurst(silentForMs: silentForMs, burstBytes: burstBytes)
        )

        let start = Date()
        let client = FakeClient(
            id: 0,
            group: harness.group,
            localProxyHost: harness.localProxyHost,
            localProxyPort: harness.localProxyPort,
            target: "quiet.example:443",
            behavior: .sendOnceThenListen(requestBytes: 256)
        )
        try await client.run()
        await client.waitForClose(timeout: TimeInterval(silentForMs) / 1000 + 10)

        let elapsed = Date().timeIntervalSince(start)
        let m = client.metrics
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: m.connectEstablishedAt != nil ? 1 : 0,
            clientsWithFirstByte: m.firstByteAt != nil ? 1 : 0,
            clientsClosedEarly: m.bytesReceived < burstBytes ? 1 : 0,
            totalBytes: m.bytesReceived,
            durationSeconds: elapsed,
            aggregateMBps: Double(m.bytesReceived) / 1_048_576.0 / elapsed,
            minBytes: m.bytesReceived,
            maxBytes: m.bytesReceived,
            medianBytes: m.bytesReceived,
            earliestClose: m.closedAt?.timeIntervalSince(start),
            latestClose: m.closedAt?.timeIntervalSince(start),
            assertions: [
                .init("tunnel established", m.connectEstablishedAt != nil),
                .init("entire burst delivered exactly once", m.bytesReceived == burstBytes),
                .init("stream closed within deadline", m.closedAt != nil),
            ],
            notes: [
                "silentForMs=\(silentForMs)",
                "expectedBurstBytes=\(burstBytes)",
                "closeReason=\(m.closeReason ?? "-")"
            ]
        )
    }

    // MARK: - AE5F6815 reproducer: fast origin flood + slow client + mid-stream close

    @MainActor
    static func floodSlowDrain(verbose: Bool) async throws -> ScenarioResult {
        let name = "floodSlowDrain(AE5F6815 repro)"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        let floodBytes = 2_000_000
        try await harness.start(
            originBehavior: .floodThenClose(floodBytes: floodBytes)
        )

        let start = Date()
        let client = FakeClient(
            id: 0,
            group: harness.group,
            localProxyHost: harness.localProxyHost,
            localProxyPort: harness.localProxyPort,
            target: "flood.example:443",
            behavior: .slowDrain(requestBytes: 256, smallRcvBufBytes: 4096)
        )
        try await client.run()
        await client.waitForClose(timeout: 30)
        let elapsed = Date().timeIntervalSince(start)
        let m = client.metrics
        // Did client receive everything despite origin force-closing mid-burst?
        let complete = m.bytesReceived >= floodBytes
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: m.connectEstablishedAt != nil ? 1 : 0,
            clientsWithFirstByte: m.firstByteAt != nil ? 1 : 0,
            clientsClosedEarly: complete ? 0 : 1,
            totalBytes: m.bytesReceived,
            durationSeconds: elapsed,
            aggregateMBps: Double(m.bytesReceived) / 1_048_576.0 / elapsed,
            minBytes: m.bytesReceived,
            maxBytes: m.bytesReceived,
            medianBytes: m.bytesReceived,
            earliestClose: m.closedAt?.timeIntervalSince(start),
            latestClose: m.closedAt?.timeIntervalSince(start),
            assertions: [
                .init("entire flood delivered exactly once", m.bytesReceived == floodBytes),
                .init("stream closed within deadline", m.closedAt != nil),
            ],
            notes: [
                "originSent=\(floodBytes)",
                "clientRcvBuf=4096",
                "clientReceived=\(m.bytesReceived)",
                complete ? "COMPLETE" : "TRUNCATED (lost \(floodBytes - m.bytesReceived) bytes)",
                "closeReason=\(m.closeReason ?? "-")"
            ]
        )
    }

    // MARK: - High throughput single stream

    @MainActor
    static func highThroughput(durationSeconds: Int, verbose: Bool) async throws -> ScenarioResult {
        let name = "highThroughput(single)"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .burstStream(
                intervalMs: 1,
                chunkSize: 64_000,
                durationMs: durationSeconds * 1000
            )
        )

        let start = Date()
        let client = FakeClient(
            id: 0,
            group: harness.group,
            localProxyHost: harness.localProxyHost,
            localProxyPort: harness.localProxyPort,
            target: "fast.example:443",
            behavior: .sendOnceThenListen(requestBytes: 256)
        )
        try await client.run()
        await client.waitForClose(timeout: TimeInterval(durationSeconds + 10))
        let elapsed = Date().timeIntervalSince(start)
        let m = client.metrics
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: m.connectEstablishedAt != nil ? 1 : 0,
            clientsWithFirstByte: m.firstByteAt != nil ? 1 : 0,
            clientsClosedEarly: 0,
            totalBytes: m.bytesReceived,
            durationSeconds: elapsed,
            aggregateMBps: Double(m.bytesReceived) / 1_048_576.0 / elapsed,
            minBytes: m.bytesReceived,
            maxBytes: m.bytesReceived,
            medianBytes: m.bytesReceived,
            earliestClose: m.closedAt?.timeIntervalSince(start),
            latestClose: m.closedAt?.timeIntervalSince(start),
            assertions: [
                .init("tunnel established", m.connectEstablishedAt != nil),
                .init("stream made progress", m.bytesReceived >= 64_000),
                .init("stream closed within deadline", m.closedAt != nil),
            ],
            notes: [
                "serverStreamedFor=\(durationSeconds)s",
                "interval=1ms",
                "chunk=64KB"
            ]
        )
    }
}
