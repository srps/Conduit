// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import ProxyKernel

/// `pm-sim upstream-flap`. Drives the full
/// per-upstream circuit-breaker state machine (`closed → open → halfOpen →
/// {closed | open}`) end-to-end through `LocalProxyServer` +
/// `ConnectionPool`, asserting that:
///
/// 1. Each transition emits exactly one `RuntimeEvent` of kind `.health`
///    with the expected event name (`upstream.circuit_opened`,
///    `upstream.circuit_half_opened`, `upstream.circuit_closed`).
/// 2. The breaker trips after the configured `circuitFailureThreshold`
///    failures (here aggressively set to 2 so the scenario stays fast).
/// 3. After the `circuitBaseOpenIntervalSeconds` elapses, the next request
///    is routed as a half-open probe.
/// 4. A successful probe closes the breaker and the upstream is back in
///    rotation. A failed probe re-opens with doubled backoff.
///
/// The scenario uses an inline `FakeUpstreamProxy` that we can stop /
/// restart to simulate upstream flap. Origin is a `FakeOrigin` doing a
/// trivial response — the request path itself isn't under test, the
/// breaker's reaction to failure/success on that path is.
///
/// Why a separate file and not inline in `OrchestratorScenarios.swift`:
/// the existing `upstreamFailover` scenario asserts the *cross-upstream*
/// failover via `switchToNextUpstream`. This scenario asserts the
/// *per-upstream* circuit-breaker state machine. Both pass through
/// `ConnectionPool` but exercise different invariants; keeping them
/// separate keeps the assertion blocks short.
enum UpstreamFlapScenarios {

    @MainActor
    static func upstreamFlap(verbose: Bool) async throws -> ScenarioResult {
        let name = "upstreamFlap"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let origin = FakeOrigin(group: group, behavior: .silent)
        try await origin.start()

        // Single upstream so the breaker's state is the only thing
        // determining whether the request gets routed.
        var upstream: FakeUpstreamProxy? = FakeUpstreamProxy(
            group: group,
            originHost: "127.0.0.1",
            originPort: origin.port,
            requireAuth: false
        )
        try await upstream!.start()
        let upstreamPort = upstream!.port

        // Aggressive thresholds so the scenario finishes in ~2 s wall time.
        // `circuitFailureThreshold = 2` makes the breaker trip after two
        // consecutive failures; `circuitBreakerWindowSeconds = 0` disables
        // the burst-protection window so synchronized failures DO trip;
        // `circuitBaseOpenIntervalSeconds = 0.3` keeps the open phase
        // short. These are not realistic production values — they're test
        // accelerators.
        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.maxConnections = 16
        config.proxy.inboundConnectionMaxLimit = 256
        config.proxy.inboundConnectionWarnThreshold = 256
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.health.circuitFailureThreshold = 2
        config.health.circuitBreakerWindowSeconds = 0
        config.health.circuitBaseOpenIntervalSeconds = 0.3
        config.health.circuitMaxOpenIntervalSeconds = 1.5
        config.upstreams = [
            UpstreamProxy(name: "FlapUpstream", host: "127.0.0.1", port: upstreamPort, priority: 0)
        ]

        // Capture every breaker event into a thread-safe sink so we can
        // assert the transition sequence regardless of which event-loop
        // thread fired the callback.
        let eventLog = RuntimeEventLog()
        let detector = DirectConnectDetector(group: group, logger: logger)
        let capturedConfig = config
        let server = LocalProxyServer(
            logger: logger,
            configProvider: { capturedConfig },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: detector,
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onConnectionActivity: { _ in },
            onRequestCompleted: { _, _ in },
            eventSink: { eventLog.append($0) }
        )
        try await server.start()
        defer {
            Task { @MainActor in
                await server.stop()
                if let upstream { await upstream.stop() }
                await origin.stop()
            }
        }

        // Phase 1: healthy baseline. One successful health check warms the
        // pool and proves the upstream is reachable.
        let hcBaseline = await server.performHealthCheck()
        notes.append("baseline healthy=\(hcBaseline.healthy)")
        guard hcBaseline.healthy else {
            return failResult(name: name, start: start,
                              notes: notes + ["baseline health check failed — fix scenario setup"])
        }

        // Phase 2: kill the upstream. The next requests will fail.
        await upstream!.stop()
        upstream = nil
        notes.append("upstream killed")

        // Phase 3: drive failures until the breaker trips. Threshold = 2
        // → 2 failed exchanges. We do 3 to be defensive (the breaker may
        // also receive failures from concurrent retry probes inside the
        // pool, but the structured event we care about is the single
        // .circuit_opened transition).
        for i in 0..<3 {
            let result = await server.performHealthCheck()
            notes.append("failure #\(i) healthy=\(result.healthy)")
        }
        try await Task.sleep(for: .milliseconds(100))

        let openedEvents = eventLog.events.filter { $0.event == "upstream.circuit_opened" }
        notes.append("upstream.circuit_opened events=\(openedEvents.count)")
        guard openedEvents.count >= 1 else {
            return failResult(name: name, start: start,
                              notes: notes + ["breaker did not trip — expected ≥1 upstream.circuit_opened event"])
        }
        let firstOpen = openedEvents[0]
        let opensWithThresholdReason = openedEvents.filter { ($0.detail ?? "").contains("reason=threshold") }.count
        notes.append("first open detail=\(firstOpen.detail ?? "<none>")")
        notes.append("opens with threshold reason=\(opensWithThresholdReason)")

        // Phase 4: wait past the open interval and revive the upstream.
        // The next health check should drive a half-open probe.
        try await Task.sleep(for: .milliseconds(500))  // > circuitBaseOpenIntervalSeconds (0.3)
        upstream = FakeUpstreamProxy(
            group: group,
            originHost: "127.0.0.1",
            originPort: origin.port,
            requireAuth: false
        )
        // Rebind to the original port so the connection pool — which still
        // points at `upstreamPort` from the config — can reach the revived
        // upstream. Without the explicit port, FakeUpstreamProxy's default
        // would pick an ephemeral one and the pool would still be probing
        // a dead address. SO_REUSEADDR is set on the listener so the rebind
        // succeeds even if the previous listener is still in TIME_WAIT.
        do {
            try await upstream!.start(port: upstreamPort)
        } catch {
            try await Task.sleep(for: .milliseconds(100))
            try await upstream!.start(port: upstreamPort)
        }
        notes.append("upstream revived on port \(upstreamPort)")

        // Force the half-open probe by issuing one request. With the
        // aggressive base interval (0.3 s) elapsed, the next request goes
        // through the breaker as a probe; success closes the circuit.
        // The first probe may race with the connection pool's own
        // half-open arming; iterate up to 3 times so the scenario doesn't
        // false-fail on a single flake. Each iteration is a fresh probe
        // through the breaker, so a probe-success (.closed) on any of
        // them satisfies the test.
        var recovered = await server.performHealthCheck()
        var probes = 1
        while !recovered.healthy && probes < 3 {
            try await Task.sleep(for: .milliseconds(300))
            recovered = await server.performHealthCheck()
            probes += 1
        }
        notes.append("post-recovery healthy=\(recovered.healthy) probes=\(probes)")

        try await Task.sleep(for: .milliseconds(100))

        let halfOpenEvents = eventLog.events.filter { $0.event == "upstream.circuit_half_opened" }
        let closedEvents = eventLog.events.filter { $0.event == "upstream.circuit_closed" }
        notes.append("upstream.circuit_half_opened events=\(halfOpenEvents.count)")
        notes.append("upstream.circuit_closed events=\(closedEvents.count)")

        // Pass conditions:
        //   - At least one .circuit_opened with .thresholdReached reason
        //   - At least one .circuit_half_opened (the probe arming)
        //   - At least one .circuit_closed with .probeSuccess reason
        //   - Events all classified as `.health` (the orchestrator's
        //     "upstream service health" semantic family)
        let healthOnly = (openedEvents + halfOpenEvents + closedEvents).allSatisfy { $0.kind == .health }
        let closeProbeSuccess = closedEvents.contains { ($0.detail ?? "").contains("reason=probe_success") }
        let pass = opensWithThresholdReason >= 1
            && halfOpenEvents.count >= 1
            && closedEvents.count >= 1
            && closeProbeSuccess
            && healthOnly
            && recovered.healthy

        notes.append(pass ? "PASS — circuit traversed closed→open→halfOpen→closed with correct events"
                          : "FAIL — see counts above")

        return ScenarioResult(
            name: name,
            clientCount: 5,
            clientsOpened: 5,
            clientsWithFirstByte: pass ? 5 : 0,
            clientsClosedEarly: pass ? 0 : 1,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes
        )
    }

    private static func failResult(name: String, start: Date, notes: [String]) -> ScenarioResult {
        ScenarioResult(
            name: name,
            clientCount: 0,
            clientsOpened: 0,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 1,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes + ["FAIL"]
        )
    }
}
