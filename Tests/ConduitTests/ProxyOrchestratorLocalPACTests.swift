// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class ProxyOrchestratorLocalPACTests: XCTestCase {

    @MainActor
    func testLocalPACStartsWithActualBoundProxyPort() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.strictMode = true
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in

            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let script = try await Self.fetch(localPACURL)

            XCTAssertEqual(try Self.routes(script, host: "public.example"), [.proxy(host: "127.0.0.1", port: proxyPort)],
                           "browsers must receive the actual bound proxy port, not configured port 0")
        }
    }

    @MainActor
    func testRoutingReloadUpdatesServedPACScript() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.strictMode = true
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.noProxyHosts = ["before.example"]

        try await withStartedOrchestrator(config) { orchestrator in

            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let proxied: [PACRoute] = [.proxy(host: "127.0.0.1", port: proxyPort)]
            var script = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(script, host: "before.example"), [.direct])
            XCTAssertEqual(try Self.routes(script, host: "after.example"), proxied)

            var updated = orchestrator.config
            updated.noProxyHosts = ["after.example"]
            await orchestrator.applyConfigChange(updated)

            script = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(script, host: "before.example"), proxied)
            XCTAssertEqual(try Self.routes(script, host: "after.example"), [.direct])
        }
    }

    @MainActor
    func testVPNRoutingChangesKeepServedBrowserPACStable() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true

        try await withStartedOrchestrator(config) { orchestrator in
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let retained = try await Self.fetch(localPACURL)
            XCTAssertTrue(retained.contains("return \"PROXY 127.0.0.1:\(proxyPort)\";"))
            for cause: DirectModeCause in [.vpnDisconnected, .none, .upstreamsUnreachable, .transientNetworkChange] {
                orchestrator.setDirectModeForTesting(cause)
                let current = try await Self.fetch(localPACURL)
                XCTAssertEqual(current, retained, "a browser that never refetches PAC must remain on Conduit across \(cause)")
            }
        }
    }

    @MainActor
    func testRoutingReloadDisablesLocalPACServer() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            XCTAssertNotNil(orchestrator.snapshot.bindings.localPACURL)

            var updated = orchestrator.config
            updated.localPACEnabled = false
            await orchestrator.applyConfigChange(updated)

            XCTAssertNil(orchestrator.snapshot.bindings.localPACHost)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACURL)
        }
    }

    @MainActor
    func testStrictModeReloadUpdatesServedPACScript() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true

        try await withStartedOrchestrator(config) { orchestrator in
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)

            var script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:\(proxyPort)\";"))
            XCTAssertFalse(script.contains("return \"PROXY 127.0.0.1:\(proxyPort); DIRECT\";"))

            var updated = orchestrator.config
            updated.strictMode = false
            await orchestrator.applyConfigChange(updated)

            script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:\(proxyPort); DIRECT\";"))
            XCTAssertTrue(orchestrator.eventLog.events.contains {
                $0.kind == .config && $0.event == "config.strict_mode_pac_refresh"
            })
        }
    }

    @MainActor
    func testUpstreamAvailabilityHotReloadUpdatesServedPACWithoutRestart() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true
        config.noProxyHosts = []

        try await withStartedOrchestrator(config) { orchestrator in
            let initialBindings = orchestrator.snapshot.bindings
            let localPACURL = try XCTUnwrap(initialBindings.localPACURL)
            let proxyPort = try XCTUnwrap(initialBindings.proxyPort)
            let proxyRoute: [PACRoute] = [.proxy(host: "127.0.0.1", port: proxyPort)]
            let initial = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(initial, host: "public.example"), [.direct])

            var added = orchestrator.config
            added.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
            await orchestrator.applyConfigChange(added)
            let enabled = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(enabled, host: "public.example"), proxyRoute,
                           "adding the first enabled upstream must replace DIRECT-only PAC")

            var disabled = orchestrator.config
            disabled.upstreams[0].enabled = false
            await orchestrator.applyConfigChange(disabled)
            let noEnabled = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(noEnabled, host: "public.example"), [.direct])

            // The app mirrors editor values before applying with its prior
            // reconciled config; retain that boundary rather than diffing self.
            let prior = orchestrator.config
            var reenabled = prior
            reenabled.upstreams[0].enabled = true
            orchestrator.config = reenabled
            await orchestrator.applyConfigChange(reenabled, from: prior)
            let restored = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(restored, host: "public.example"), proxyRoute)

            var removed = orchestrator.config
            removed.upstreams = []
            await orchestrator.applyConfigChange(removed)
            let empty = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(empty, host: "public.example"), [.direct])
            XCTAssertEqual(orchestrator.snapshot.bindings.proxyPort, initialBindings.proxyPort)
            XCTAssertEqual(orchestrator.snapshot.bindings.localPACURL, localPACURL)
            XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "config.proxy_restart" })
        }
    }

    /// A stop admitted while a reload's PAC listener restart is out supersedes the restart at its next epoch check. That is reported as
    /// a supersession, not as a failed PAC update, and the stop leaves no PAC listener behind. The test observes `local_pac.restarting`,
    /// which the restart emits just before its first suspension, and admits the stop then; the stop takes its epoch before it suspends.
    @MainActor
    func testAStopDuringAReloadPACRestartIsReportedAsSupersededNotFailed() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            let boundPort = try XCTUnwrap(orchestrator.snapshot.bindings.localPACPort)
            var moved = orchestrator.config
            // A different fixed port forces the restart branch. The restart is superseded before it binds, so the port is never taken.
            moved.localPACPort = boundPort == 65535 ? boundPort - 1 : boundPort + 1
            let before = orchestrator.eventLog.events.count
            let reload = Task { @MainActor in await orchestrator.applyConfigChange(moved) }
            for _ in 0..<5_000 where !orchestrator.eventLog.events.contains(where: { $0.event == "local_pac.restarting" }) {
                await Task.yield()
            }
            XCTAssertTrue(orchestrator.eventLog.events.contains { $0.event == "local_pac.restarting" }, "the reload's PAC restart is out")

            await orchestrator.stopProxy()
            await reload.value

            let names = orchestrator.eventLog.events.dropFirst(before).map(\.event)
            XCTAssertTrue(names.contains("config.local_pac_refresh_superseded"), "\(names)")
            XCTAssertFalse(names.contains("local_pac.failed"), "a superseded restart is not a failure: \(names)")
            XCTAssertFalse(names.contains("local_pac.started"), "the superseded restart bound nothing: \(names)")
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort, "the stop leaves no PAC listener")
        }
    }

    /// The opposite ordering: the reload arrives after a stop took its epoch and before its teardown published `stopped`, so the
    /// snapshot still reads running. A strict-mode edit reaches the PAC branch with no suspension, so the decision is made inside that
    /// window: both run on the main actor, and the stop cannot end until this test yields. The refresh is deferred to the next start
    /// instead of taking the stop's epoch, waiting behind its teardown and binding the PAC listener after it.
    @MainActor
    func testAReloadDuringAStopDoesNotRebindThePACListenerAfterIt() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true

        try await withStartedOrchestrator(config) { orchestrator in
            // Pin the PAC port to the one already bound, which updates the running listener in place. A rebind after the stop would
            // then answer on this same URL, so a refused fetch proves no listener, whatever the snapshot says.
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            var pinned = orchestrator.config
            pinned.localPACPort = try XCTUnwrap(orchestrator.snapshot.bindings.localPACPort)
            await orchestrator.applyConfigChange(pinned)
            XCTAssertEqual(orchestrator.snapshot.bindings.localPACURL, localPACURL)
            _ = try await Self.fetch(localPACURL)

            var relaxed = orchestrator.config
            relaxed.strictMode = false
            let before = orchestrator.eventLog.events.count
            let stop = await Self.stopHeldInFlight(orchestrator)
            await orchestrator.applyConfigChange(relaxed)
            await stop.value

            let names = orchestrator.eventLog.events.dropFirst(before).map(\.event)
            XCTAssertFalse(names.contains("config.strict_mode_pac_refresh"), "a stop in flight defers the refresh: \(names)")
            XCTAssertFalse(names.contains("local_pac.started"), "nothing binds the PAC listener after the stop: \(names)")
            XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort, "the stop leaves no PAC listener")
            do {
                _ = try await Self.fetch(localPACURL)
                XCTFail("the PAC listener answered after the stop")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cannotConnectToHost, "nothing listens on the stopped PAC port: \(error)")
            }
        }
    }

    /// The same window for a listener edit: a restart admitted during the stop would supersede it and start the proxy again.
    @MainActor
    func testAListenerReloadDuringAStopDoesNotStartTheProxyAgain() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.socksEnabled = false
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            var moved = orchestrator.config
            moved.socksPort = moved.socksPort == 65535 ? 65534 : moved.socksPort + 1
            let before = orchestrator.eventLog.events.count
            let stop = await Self.stopHeldInFlight(orchestrator)
            await orchestrator.applyConfigChange(moved)
            await stop.value

            let names = orchestrator.eventLog.events.dropFirst(before).map(\.event)
            XCTAssertFalse(names.contains("config.proxy_restart"), "a stop in flight defers the restart: \(names)")
            XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped, "the stop is not undone: \(names)")
            XCTAssertNil(orchestrator.snapshot.bindings.proxyPort)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort)
        }
    }

    /// The same window for a health interval edit: the stop already ended the health loop, so the reload restarts nothing and the next
    /// start runs the loop with the new interval.
    @MainActor
    func testAHealthReloadDuringAStopDoesNotRestartTheHealthLoop() async throws {
        var config = ProxyConfig.testFixture()
        // One loopback upstream, which the fixture's probe reports unreachable: on the VPN that is `upstreamsUnreachable`, a cause that
        // runs the health loop. The long interval leaves only the loop's first check.
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.healthCheckIntervalSeconds = 3600
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            await orchestrator.handleVPNStateChange(.connected)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .upstreamsUnreachable, "the health loop runs before the stop")
            XCTAssertTrue(orchestrator.snapshot.directModeCause.runsUpstreamHealthLoop)
            var edited = orchestrator.config
            edited.healthCheckIntervalSeconds += 1
            let before = orchestrator.eventLog.events.count
            let stop = await Self.stopHeldInFlight(orchestrator)
            await orchestrator.applyConfigChange(edited)
            await stop.value

            let names = orchestrator.eventLog.events.dropFirst(before).map(\.event)
            XCTAssertFalse(names.contains("config.health_restart"), "a stop in flight defers the health restart: \(names)")
            XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped)
            XCTAssertEqual(orchestrator.config.healthCheckIntervalSeconds, edited.healthCheckIntervalSeconds)
        }
    }

    /// The restart's own stop is in flight when a user stop is admitted. The restart then must not start over that newer stop; it is
    /// reported as superseded, and the edit is left in the config for the next start. The restart reaches its stop with no suspension,
    /// so the test admits its stop as soon as it sees one in flight.
    @MainActor
    func testAStopDuringAListenerRestartsOwnTeardownIsNotOvertakenByTheRestart() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.socksEnabled = false
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            var moved = orchestrator.config
            moved.socksPort = moved.socksPort == 65535 ? 65534 : moved.socksPort + 1
            let before = orchestrator.eventLog.events.count
            let reload = Task { @MainActor in await orchestrator.applyConfigChange(moved) }
            for _ in 0..<5_000 where !orchestrator.isStopInFlight {
                await Task.yield()
            }
            XCTAssertTrue(orchestrator.isStopInFlight, "the restart's own stop is in flight")
            await orchestrator.stopProxy()
            await reload.value

            let names = orchestrator.eventLog.events.dropFirst(before).map(\.event)
            XCTAssertTrue(names.contains("config.proxy_restart"), "\(names)")
            XCTAssertTrue(names.contains("config.proxy_restart_superseded"), "\(names)")
            XCTAssertFalse(names.contains("config.proxy_restart_failed"), "a superseded restart is not a failure: \(names)")
            XCTAssertFalse(names.contains("proxy.starting"), "nothing starts over the user's stop: \(names)")
            XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped)
            XCTAssertNil(orchestrator.snapshot.bindings.proxyPort)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort)
            XCTAssertEqual(orchestrator.config.socksPort, moved.socksPort, "the next start binds the edit")
        }
    }

    /// An upstream reload probes under its own lifecycle. A stop is admitted and finishes while that probe is out, so the result is
    /// dropped: the stopped runtime's routing and upstream status stay as the stop left them, and the edit waits for the next start.
    @MainActor
    func testAnUpstreamReloadProbeThatOutlivesAStopCommitsNoRouting() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), connectivityProbe: { upstreams in
            // The reload's probe, the first with an upstream to probe: a stop is admitted and finishes while it is out.
            if !upstreams.isEmpty, let orchestrator = box.withLockedValue({ held -> ProxyOrchestrator? in
                defer { held = nil }
                return held
            }) {
                await orchestrator.stopProxy()
            }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
        })
        try await orchestrator.startProxy()
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .noUpstreamsConfigured)
        box.withLockedValue { $0 = orchestrator }

        var added = orchestrator.config
        added.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        await orchestrator.applyConfigChange(added)

        let superseded = orchestrator.eventLog.events.filter { $0.event == "connectivity.probe_superseded" }.map { $0.detail ?? "" }
        XCTAssertEqual(superseded.count, 1, "\(superseded)")
        XCTAssertTrue(superseded.first?.hasPrefix("by=lifecycle") == true, "\(superseded)")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped, "the stop's state stands")
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .noUpstreamsConfigured, "the dropped probe commits no routing")
        XCTAssertTrue(orchestrator.snapshot.upstreamStatuses.isEmpty)
        XCTAssertEqual(orchestrator.config.upstreams, added.upstreams, "the next start probes the edit")
        await orchestrator.stopProxy()
    }

    /// Admits a stop and returns once it has taken its epoch and suspended in its teardown, before it publishes `stopped`. The caller
    /// must not suspend before acting on that window.
    @MainActor
    private static func stopHeldInFlight(_ orchestrator: ProxyOrchestrator) async -> Task<Void, Never> {
        let stop = Task { @MainActor in await orchestrator.stopProxy() }
        for _ in 0..<5_000 where !orchestrator.isStopInFlight {
            await Task.yield()
        }
        XCTAssertTrue(orchestrator.isStopInFlight, "the stop is in flight")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running, "the stop has not published yet")
        return stop
    }

    private static func routes(_ script: String, host: String) throws -> [PACRoute] {
        let evaluator = CFPACEvaluator()
        let compiled = try evaluator.makeEvaluator(pacScript: script)
        let target = try XCTUnwrap(URL(string: "https://\(host)/"))
        return evaluator.routeChain(for: try compiled.resolveProxyChain(for: target)).routes
    }

    private static func fetch(_ urlString: String) async throws -> String {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private func withStartedOrchestrator(
        _ config: ProxyConfig,
        body: (ProxyOrchestrator) async throws -> Void
    ) async throws {
        // These tests exercise served browser policy, not upstream reachability.
        // Avoid real dials to the fixture endpoints; the prober has its own tests.
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), connectivityProbe: { targets in
            UpstreamProbeSummary(results: targets.filter(\.enabled).map {
                ProbeResult(proxy: $0, latencyMS: 0, reachable: false)
            })
        })
        try await orchestrator.startProxy()
        do {
            try await body(orchestrator)
            await orchestrator.stopProxy()
        } catch {
            await orchestrator.stopProxy()
            throw error
        }
    }
}
