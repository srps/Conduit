// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class RuntimeEventTests: XCTestCase {

    func testEventLogBoundedCapacity() {
        let log = RuntimeEventLog(capacity: 3)
        log.append(RuntimeEvent(kind: .lifecycle, event: "a"))
        log.append(RuntimeEvent(kind: .lifecycle, event: "b"))
        log.append(RuntimeEvent(kind: .lifecycle, event: "c"))
        log.append(RuntimeEvent(kind: .lifecycle, event: "d"))

        XCTAssertEqual(log.events.count, 3, "Log should be bounded to capacity")
        XCTAssertEqual(log.events.map(\.event), ["b", "c", "d"], "Oldest event evicted")
    }

    func testEventLogEmptyInitially() {
        let log = RuntimeEventLog(capacity: 10)
        XCTAssertEqual(log.events.count, 0)
    }

    func testEventLogPreservesOrder() {
        let log = RuntimeEventLog(capacity: 5)
        for i in 0..<5 {
            log.append(RuntimeEvent(kind: .lifecycle, event: "event-\(i)"))
        }
        XCTAssertEqual(log.events.map(\.event), (0..<5).map { "event-\($0)" })
    }

    func testEventLogSinkReceivesAppendedEvents() {
        let log = RuntimeEventLog(capacity: 5)
        let observed = NIOLockedValueBox<[String]>([])
        log.setSink { event in
            observed.withLockedValue { $0.append(event.event) }
        }

        log.append(RuntimeEvent(kind: .lifecycle, event: "a"))
        log.append(RuntimeEvent(kind: .routing, event: "b"))

        XCTAssertEqual(observed.withLockedValue { $0 }, ["a", "b"])
        XCTAssertEqual(log.events.map(\.event), ["a", "b"])
    }

    func testRuntimeEventFileWriterWritesCappedNDJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-event-writer-\(UUID().uuidString)", isDirectory: true)
        let file = tempDir.appendingPathComponent("events.ndjson")
        let writer = RuntimeEventFileWriter(fileURL: file, maxBytes: 180, logger: DiscardingLogSink())

        for i in 0..<8 {
            writer.record(RuntimeEvent(kind: .lifecycle, event: "event-\(i)"))
        }
        writer.flush()

        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, 180)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            // RuntimeEventFileWriter encodes via `CanonicalJSON.encoder()`
            // which uses `.secondsSince1970` for `Date`. Pair with the
            // matching decoder so the timestamp round-trip is correct
            // (vs the silent 31-year reference-date shift you'd see with
            // a plain `JSONDecoder`).
            let decoded = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line.utf8))
            XCTAssertTrue(decoded.event.hasPrefix("event-"))
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEventCodableRoundTrip() throws {
        let event = RuntimeEvent(kind: .routing, event: "route.decision", detail: "DIRECT for 10.0.0.1")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RuntimeEvent.self, from: data)
        XCTAssertEqual(decoded.kind, .routing)
        XCTAssertEqual(decoded.event, "route.decision")
        XCTAssertEqual(decoded.detail, "DIRECT for 10.0.0.1")
    }

    func testEventKindValues() {
        let kinds: [RuntimeEventKind] = [.lifecycle, .routing, .auth, .connection, .health, .config]
        XCTAssertEqual(kinds.count, 6)
    }

    @MainActor
    func testOrchestratorEmitsLifecycleEvents() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        try await orchestrator.startProxy()
        await orchestrator.stopProxy()

        let events = orchestrator.eventLog.events
        let lifecycleEvents = events.filter { $0.kind == .lifecycle }
        XCTAssertTrue(lifecycleEvents.contains { $0.event == "proxy.starting" })
        XCTAssertTrue(lifecycleEvents.contains { $0.event == "proxy.stopping" })
    }

    @MainActor
    func testApplyConfigChangeEmitsConfigEventsPerBranch() async throws {
        // Locks the AGENTS.md "events first" contract for `applyConfigChange`: every taken
        // decision branch (logging / health / routing / tunnels / proxy-limits / upstreams)
        // must emit a structured event so the UI, pmctl, and pm-sim can react without
        // grepping log lines. Auth gets its own dedicated test below.
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db.example.com", remotePort: 5432, proxied: false, label: "DB")
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()

        var newConfig = orchestrator.config
        newConfig.logging.verbose = !newConfig.logging.verbose
        newConfig.health.checkInterval = newConfig.health.checkInterval + 30
        newConfig.routing.noProxyHosts.append("*.newdomain.example")
        newConfig.tunnels.definitions.append(
            TunnelDefinition(localPort: 0, remoteHost: "db2.example.com", remotePort: 3306, proxied: false, label: "DB2")
        )
        newConfig.proxy.maxConnections = newConfig.proxy.maxConnections + 100
        newConfig.upstreams = [UpstreamProxy(name: "T", host: "192.0.2.1", port: 8080, priority: 0)]
        await orchestrator.applyConfigChange(newConfig)

        let names = Set(orchestrator.eventLog.events.map(\.event))
        XCTAssertTrue(names.contains("config.logging_changed"))
        XCTAssertTrue(names.contains("config.health_restart"))
        XCTAssertTrue(names.contains("config.routing_changed"))
        XCTAssertTrue(names.contains("config.tunnels_reconcile"))
        XCTAssertTrue(names.contains("config.proxy_limits_updated"))
        XCTAssertTrue(names.contains("config.upstreams_refresh"))
        // All config-branch events MUST land under the .config kind so subscribers can
        // filter for "config reload" without having to enumerate event names.
        let configEvents = orchestrator.eventLog.events.filter { $0.kind == .config }
        XCTAssertGreaterThanOrEqual(configEvents.count, 6)

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    @MainActor
    func testApplyConfigChangePersistsMetadataOnlyChanges() async throws {
        let config = GenericDefaults.shared.makeConfig()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        var newConfig = config
        newConfig.profileName = "Reloaded Profile"
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.config.profileName, "Reloaded Profile")
        XCTAssertTrue(orchestrator.eventLog.events.contains { $0.event == "config.metadata_changed" })
    }

    @MainActor
    func testAuthChangeEmitsTunnelReauthEventWhenRunning() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()

        var newConfig = orchestrator.config
        newConfig.auth.domain = "NEWDOMAIN"
        await orchestrator.applyConfigChange(newConfig)

        let authEvents = orchestrator.eventLog.events.filter { $0.kind == .auth }
        XCTAssertTrue(authEvents.contains { $0.event == "config.tunnel_auth_reauth" })

        await orchestrator.stopProxy()
    }

    @MainActor
    func testApplyConfigChangeEmitsAuthEventOnAuthChange() async throws {
        // The auth-changed branch was a gap — every other ConfigDiff section had a handler
        // and emitted observable state, but auth edits were silently dropped at the
        // orchestrator boundary. Lock the new behaviour here.
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.auth.mode = .systemNegotiated
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()

        var newConfig = orchestrator.config
        newConfig.auth.mode = .ntlmv2
        await orchestrator.applyConfigChange(newConfig)

        let authEvents = orchestrator.eventLog.events.filter { $0.kind == .auth }
        XCTAssertTrue(
            authEvents.contains { $0.event == "config.auth_changed" },
            "Auth mode flip must emit a `config.auth_changed` event under kind=.auth"
        )
        // Detail must capture the mode transition so subscribers can react without
        // re-reading config — matches the lifecycle/health pattern of self-describing events.
        let modeEvent = authEvents.first { $0.event == "config.auth_changed" }
        XCTAssertEqual(modeEvent?.detail, "mode systemNegotiated → ntlmv2")

        await orchestrator.stopProxy()
    }
}
