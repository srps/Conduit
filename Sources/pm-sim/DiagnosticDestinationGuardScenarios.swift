// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// #222: a diagnostic destination that aliases a protected resource is refused before
/// anything is written, the protected bytes survive, one fixed event names the refusal,
/// and the runtime keeps serving and stops cleanly. The writers, guard and orchestrator
/// are the production types. The only fixture is a loopback listener on an ephemeral port,
/// and everything lives under a scratch directory.
@MainActor
enum DiagnosticDestinationGuardScenarios {
    private struct Failure: Error { let message: String }

    static func run() async throws -> ScenarioResult {
        let began = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-dest-guard-\(UUID().uuidString)", isDirectory: true)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-dest-guard-external-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let environment = RuntimeEnvironment(configDirectory: root)
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        let config = try Data(contentsOf: environment.configFile)
        var runtimeConfig = try ProxyConfigPersistence.load(in: environment)
        runtimeConfig.proxy.host = "127.0.0.1"
        runtimeConfig.proxy.port = 0

        // One log for every writer and the orchestrator, as the production compositions wire it.
        let log = RuntimeEventLog(capacity: 256)
        let eventsWriter = RuntimeEventFileWriter(
            fileURL: environment.eventsFile, logger: DiscardingLogSink(),
            destinationGuard: guardFor(.runtimeEvents, in: environment),
            eventLog: log)
        log.setSink { eventsWriter.record($0) }

        // 1. An audit path pointing at the live config, through a running orchestrator.
        let auditAtConfig = audit(at: environment.configFile, environment: environment, log: log)
        let orchestrator = ProxyOrchestrator(config: runtimeConfig, logger: DiscardingLogSink(),
                                             auditSink: auditAtConfig, eventLog: log)
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        let listening = orchestrator.snapshot.bindings.proxyPort != nil && orchestrator.snapshot.proxyError == nil
        auditAtConfig.record(fixtureRecord())
        guard auditAtConfig.flush() else { throw Failure(message: "Refused audit writer did not flush") }
        let configSurvivedDirect = try Data(contentsOf: environment.configFile) == config
        let directCounts = counts(auditAtConfig)

        // 2. Symlink and hardlink aliases of the config, each in a fresh sink.
        let symlink = root.appendingPathComponent("audit-link.ndjson")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: environment.configFile)
        let symlinkSink = audit(at: symlink, environment: environment, log: log)
        symlinkSink.record(fixtureRecord())
        guard symlinkSink.flush() else { throw Failure(message: "Symlink audit writer did not flush") }
        let hardlink = root.appendingPathComponent("audit-hard.ndjson")
        try FileManager.default.linkItem(at: environment.configFile, to: hardlink)
        let hardlinkSink = audit(at: hardlink, environment: environment, log: log)
        hardlinkSink.record(fixtureRecord())
        guard hardlinkSink.flush() else { throw Failure(message: "Hardlink audit writer did not flush") }
        let aliasesRefused = symlinkSink.statistics.writtenRecords == 0 && hardlinkSink.statistics.writtenRecords == 0

        // 3. Valid default and external audit paths still write.
        let defaultSink = audit(at: root.appendingPathComponent("audit.ndjson"), environment: environment, log: log)
        defaultSink.record(fixtureRecord())
        let externalSink = audit(at: external.appendingPathComponent("compliance.ndjson"),
                                 environment: environment, log: log)
        externalSink.record(fixtureRecord())
        guard defaultSink.flush(), externalSink.flush() else { throw Failure(message: "Valid audit writers did not flush") }
        let validWritten = defaultSink.statistics.writtenRecords == 1 && externalSink.statistics.writtenRecords == 1

        // 4. The runtime keeps running, then stops, and the refusal reached the events file.
        let runtimeRunning = orchestrator.snapshot.bindings.proxyPort != nil
        await orchestrator.stopProxy()
        let stopped = orchestrator.snapshot.bindings.proxyPort == nil
        guard eventsWriter.flush(timeout: 5) else { throw Failure(message: "Events writer did not flush") }
        let eventLines = try String(contentsOf: environment.eventsFile, encoding: .utf8)
            .split(separator: "\n").filter { $0.contains(RecordFileDestinationGate.eventName) }
        // Each latched sink emits exactly one refusal: direct path, symlink alias, then hardlink alias.
        let refusalDetails = log.events.filter { $0.event == RecordFileDestinationGate.eventName }.compactMap(\.detail)
        let oneSafeRefusal = refusalDetails == [
            "sink=audit reason=protected_path resource=config",
            "sink=audit reason=protected_path resource=config",
            "sink=audit reason=protected_identity resource=config",
        ] && eventLines.count == refusalDetails.count

        // 5. Events collision: `pm-proxy --config <root>/events.ndjson` makes the events file the config.
        let collisionEnvironment = RuntimeEnvironment.explicit(
            configFile: root.appendingPathComponent("collision/events.ndjson"))
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: collisionEnvironment)
        let collisionConfig = try Data(contentsOf: collisionEnvironment.configFile)
        let collisionLog = RuntimeEventLog(capacity: 16)
        let collisionWriter = RuntimeEventFileWriter(
            fileURL: collisionEnvironment.eventsFile, logger: DiscardingLogSink(),
            destinationGuard: guardFor(.runtimeEvents, in: collisionEnvironment),
            eventLog: collisionLog)
        collisionLog.setSink { collisionWriter.record($0) }
        collisionLog.append(RuntimeEvent(kind: .lifecycle, event: "proxy.starting"))
        let collisionFlushed = collisionWriter.flush(timeout: 5)
        let collisionSurvived = try Data(contentsOf: collisionEnvironment.configFile) == collisionConfig
            && collisionWriter.statistics.writtenRecords == 0

        let checks: [(String, Bool)] = [
            ("runtime serves before the refused audit path is used", listening),
            ("config bytes survive an audit path aliasing the config", configSurvivedDirect),
            ("refused audit writes count as failed, never written", directCounts == (written: 0, failed: 1)),
            ("symlink and hardlink aliases of the config are refused", aliasesRefused),
            ("valid default and external audit paths still write", validWritten),
            ("runtime keeps running after the refusals", runtimeRunning),
            ("stop completes and releases the proxy port", stopped),
            ("one refusal event names only fixed codes, in the log and the events file", oneSafeRefusal),
            ("events collision leaves the config intact and flushes", collisionFlushed && collisionSurvived),
        ]
        guard checks.allSatisfy({ $0.1 }) else {
            let failed = checks.filter { !$0.1 }.map(\.0).joined(separator: "; ")
            throw Failure(message: "Diagnostic destination guard failed: \(failed)")
        }
        return ScenarioResult(
            name: "diagnostic-destination-guard", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: config.count, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks.map { .init($0.0, $0.1) },
            notes: ["PASS: protected config bytes unchanged (\(config.count) bytes) across direct, symlink and hardlink audit aliases",
                    "PASS: refusal counted as failed/dropped, never written; events file carries the fixed refusal event",
                    "PASS: runtime served on an ephemeral loopback port and stopped; events collision left config intact"])
    }

    private static func audit(at url: URL, environment: RuntimeEnvironment, log: RuntimeEventLog) -> FileConnectionAuditSink {
        FileConnectionAuditSink(
            fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink(),
            destinationGuard: guardFor(.connectionAudit, in: environment),
            eventLog: log)
    }

    /// pm-sim has no `ProxyControlBridge` edge on this branch, so it mirrors that target's
    /// `protectedDiagnosticResources` mapping. Keep the two in step; the bridge is the source.
    private static func guardFor(_ sink: RecordFileDiagnosticSink, in environment: RuntimeEnvironment) -> any RecordFileDestinationGuarding {
        let all: [ProtectedRecordFile] = [
            ProtectedRecordFile(resource: .config, url: environment.configFile),
            ProtectedRecordFile(resource: .platformState, url: environment.platformStateFile),
            ProtectedRecordFile(resource: .platformConfig, url: environment.platformConfigFile),
            ProtectedRecordFile(resource: .preferences, url: environment.preferencesFile),
            ProtectedRecordFile(resource: .snapshot, url: environment.snapshotFile),
            ProtectedRecordFile(resource: .legacySavedDNS, url: environment.legacySavedDNSFile),
            ProtectedRecordFile(resource: .events, url: environment.eventsFile),
            ProtectedRecordFile(resource: .ready, url: environment.configDirectory.appendingPathComponent("ready.json")),
            ProtectedRecordFile(resource: .daemonReady,
                                url: environment.configDirectory.appendingPathComponent("daemon-ready.json")),
            ProtectedRecordFile(resource: .control,
                                url: environment.configDirectory.appendingPathComponent(ControlSocket.fileName)),
            ProtectedRecordFile(resource: .updateState, url: environment.updateStateFile),
            ProtectedRecordFile(resource: .log, url: environment.logFile),
        ]
        let protected = sink == .runtimeEvents ? all.filter { $0.resource != .events } : all
        return systemRecordFileDestinationGuard(protected: protected)
    }

    private static func counts(_ sink: FileConnectionAuditSink) -> (written: UInt64, failed: UInt64) {
        (sink.statistics.writtenRecords, sink.statistics.failedRecords)
    }

    private static func fixtureRecord() -> ConnectionAuditRecord {
        ConnectionAuditRecord(id: UUID(), timestamp: Date(), clientAddress: "127.0.0.1",
            scheme: .https, target: "fixture.test:443", pacDecision: nil, chosenUpstream: "DIRECT",
            authMethod: nil, bytesSent: 1, bytesReceived: 1, durationMS: 1, outcome: .success)
    }
}
