// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyControlBridge
import ProxyKernel

/// `protected-snapshot-artifacts`: a configuration whose path is the snapshot destination, or an alias of it,
/// keeps its bytes while the writer refuses the destination. The refusal latches once, and a later submission
/// neither reopens the destination nor encodes again. A normal destination still receives the latest snapshot.
/// One bounded scratch case per alias, all under a temporary directory. No serving instance is touched.
enum ProtectedSnapshotScenarios {
    private enum Alias: String, CaseIterable {
        case direct, symbolicLink = "symbolic-link", hardLink = "hard-link"
    }

    static func run() async throws -> ScenarioResult {
        let began = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let witness = Data(#"{"schemaVersion":2,"witness":"original-intent"}"#.utf8)
        var assertions: [ScenarioAssertion] = []

        for alias in Alias.allCases {
            let directory = root.appendingPathComponent(alias.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = directory.appendingPathComponent("config.json")
            try witness.write(to: config)
            let snapshotURL: URL
            switch alias {
            case .direct:
                snapshotURL = config
            case .symbolicLink:
                snapshotURL = directory.appendingPathComponent("snapshot.json")
                try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: config)
            case .hardLink:
                snapshotURL = directory.appendingPathComponent("snapshot.json")
                try FileManager.default.linkItem(at: config, to: snapshotURL)
            }
            let environment = RuntimeEnvironment(configDirectory: directory, configFile: config,
                                                 snapshotFile: snapshotURL)
            let events = RuntimeEventLog(capacity: 16)
            let cleaned = DispatchSemaphore(value: 0)
            let writer = makeSnapshotArtifactWriter(
                fileURL: environment.snapshotFile,
                logger: DiscardingLogSink(),
                destinationGuard: diagnosticDestinationGuard(for: .snapshot, in: environment),
                eventLog: events,
                onDrainCleanup: { cleaned.signal() }
            )
            writer.submit(snapshot(1))
            let first = await drainJoining(writer, cleaned: cleaned)
            writer.submit(snapshot(2))
            let second = await drainJoining(writer, cleaned: cleaned)
            let refusals = events.events.filter { $0.event == RecordFileDestinationGate.eventName }.count
            let statistics = writer.statistics

            assertions.append(.init("\(alias.rawValue): destination refused on every submission",
                                    first == .refused && second == .refused))
            assertions.append(.init("\(alias.rawValue): configuration bytes preserved",
                                    try Data(contentsOf: config) == witness))
            assertions.append(.init("\(alias.rawValue): refusal latched once, no write, no reopened destination",
                                    refusals == 1 && statistics.refused == 2 && statistics.written == 0))
        }

        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let environment = RuntimeEnvironment(configDirectory: plain, configFile: plain.appendingPathComponent("config.json"))
        let writer = makeSnapshotArtifactWriter(
            fileURL: environment.snapshotFile,
            logger: DiscardingLogSink(),
            destinationGuard: diagnosticDestinationGuard(for: .snapshot, in: environment),
            eventLog: RuntimeEventLog(capacity: 16)
        )
        writer.submit(snapshot(1))
        writer.submit(snapshot(2))
        let outcome = await writer.drain(until: ContinuousClock.now.advanced(by: .seconds(5)))
        let written = try CanonicalJSON.decoder().decode(ProxyOrchestratorSnapshot.self,
                                                         from: Data(contentsOf: environment.snapshotFile))
        assertions.append(.init("normal destination: current, holding the latest generation",
                                outcome == .current && written.dnsQueryCount == 2))

        return ScenarioResult(
            name: "protected-snapshot-artifacts", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: witness.count, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions,
            notes: ["Scratch directory under the temporary directory only; no serving instance, system setting or helper is touched."]
        )
    }

    /// Drains, joining an earlier wait's held reservation through the writer's cleanup seam. Bounded to two joins.
    private static func drainJoining(_ writer: any SnapshotArtifactWriting, cleaned: DispatchSemaphore) async -> SnapshotFlushOutcome {
        var outcome = await writer.drain(until: ContinuousClock.now.advanced(by: .seconds(5)))
        for _ in 0..<2 where outcome == .busy {
            guard joinCleanup(cleaned) == .success else { return outcome }
            outcome = await writer.drain(until: ContinuousClock.now.advanced(by: .seconds(5)))
        }
        return outcome
    }

    /// A synchronous function is the place for the blocking wait: the compiler rejects it inside an async context.
    private static func joinCleanup(_ cleaned: DispatchSemaphore) -> DispatchTimeoutResult {
        cleaned.wait(timeout: .now() + 10)
    }

    private static func snapshot(_ queries: Int) -> ProxyOrchestratorSnapshot {
        var value = ProxyOrchestratorSnapshot()
        value.dnsQueryCount = queries
        return value
    }
}
