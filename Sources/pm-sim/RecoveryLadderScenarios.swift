// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel
import RuntimeEvents

/// #147 through a running orchestrator. The only upstream refuses every
/// connect, so each health check fails as unreachable. The ladder must not
/// re-authenticate against an upstream that never answered, and its
/// exhaustion line must not send the user to re-enter a password.
/// Holds the first caller of `holdOnce` until `release`; later callers pass.
private final class ProbeHold: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    var isHolding: Bool { lock.withLock { waiter != nil } }

    func holdOnce() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                guard !used, !released else { return true }
                used = true
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

enum RecoveryLadderScenarios {
    @RuntimeActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// The typed ladder outcomes the kernel recorded, matched by value: `proxy_recovery.*` is a closed typed namespace.
    private static func recoveryOutcomes(_ log: RuntimeEventLog) -> [ProxyRecoveryEvent] {
        log.events.compactMap { event in
            guard case .proxyRecovery(let outcome)? = event.typed else { return nil }
            return outcome
        }
    }

    @RuntimeActor
    static func unreachableLadder(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        // A port that was just bound and released: connects to it are refused.
        let dead = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 9, requireAuth: false)
        try await dead.start()
        let deadPort = dead.port
        await dead.stop()

        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: deadPort, priority: 0)]
        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        // The reachability probe says yes so the health loop, not direct
        // mode, owns the outage: that is the path that starts the ladder.
        // The first probe after exhaustion is held until released, so a VPN
        // report can supersede it.
        let log = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let heldProbe = ProbeHold()
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let exhausted = log.withLockedValue { $0 }?.events.contains { $0.event == "recovery.exhausted" } ?? false
                if exhausted { await heldProbe.holdOnce() }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        log.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }

        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        let exhausted = try await until(timeout: 15) { !events("recovery.exhausted").isEmpty }
        let skipped = events("recovery.step_skipped")
        let exhaustedDetail = events("recovery.exhausted").first?.detail ?? ""
        let entries = logger.entries()
        let reauthRan = entries.contains { $0.message.contains("Re-authenticate") && !$0.message.hasPrefix("Recovery step skipped") }
        let errorLine = entries.last { $0.level == .error && $0.message.hasPrefix("Automatic recovery exhausted") }?.message ?? ""

        // A VPN report lands while the post-exhaustion probe is out: the
        // cooldown the ladder earned on the old network is dropped (#155).
        let probeHeld = try await until(timeout: 5) { heldProbe.isHolding }
        await orchestrator.handleVPNStateChange(.connected)
        heldProbe.release()
        let cleared = try await until(timeout: 5) { !events("recovery.cooldown_cleared").isEmpty }
        let clearedDetail = events("recovery.cooldown_cleared").first?.detail
        let outcomes = recoveryOutcomes(orchestrator.eventLog)

        return ScenarioResult(name: "recovery-unreachable-ladder", clientCount: 0, clientsOpened: 0,
            clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("an unreachable upstream exhausts the ladder", exhausted && exhaustedDetail.hasPrefix("failure=unreachable ")),
                .init("re-authenticate is skipped with a structured reason", skipped.count == 1
                    && skipped[0].detail?.hasPrefix("step=reauthenticate reason=upstream_unreachable") == true && !reauthRan),
                .init("the exhaustion line says no upstream answered and does not blame the password",
                      errorLine.contains("no upstream proxy answered") && !errorLine.localizedCaseInsensitiveContains("password")),
                .init("the cooldown still follows exhaustion", !events("recovery.cooldown_started").isEmpty),
                .init("a VPN report superseding the post-exhaustion probe clears the cooldown",
                      probeHeld && cleared && clearedDetail == "reason=superseded"),
                .init("the superseded ladder records no typed recovery outcome", outcomes == []),
            ], notes: ["refusing loopback upstream on port \(deadPort); injected reachable probe; no credentials, helper or settings"])
    }

    /// #155: a VPN disconnect lands while an exhausted ladder's probe is
    /// out. The ladder's probe returns first, finds itself superseded and
    /// stands down, reading the cause from before the disconnect; then the
    /// disconnect's probe routes DIRECT. The disconnect's verdict must own
    /// the status: `.running`, not the `.degraded` the ladder left.
    @RuntimeActor
    static func ladderSupersededByDisconnect(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let dead = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 9, requireAuth: false)
        try await dead.start()
        let deadPort = dead.port
        await dead.stop()

        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: deadPort, priority: 0)]
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        // Reachable, so the health loop owns the outage, until the
        // disconnect. The ladder's post-exhaustion probe and the
        // disconnect's probe are each held.
        let log = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let disconnected = NIOLockedValueBox(false)
        let ladderProbe = ProbeHold(), disconnectProbe = ProbeHold()
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let off = disconnected.withLockedValue { $0 }
                if off {
                    await disconnectProbe.holdOnce()
                } else if log.withLockedValue({ $0 })?.events.contains(where: { $0.event == "recovery.exhausted" }) ?? false {
                    await ladderProbe.holdOnce()
                }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: !off) })
            })
        log.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }

        // The startup health check fails; the ladder runs out and probes.
        let ladderHeld = try await until(timeout: 15) { ladderProbe.isHolding }
        let recovering = orchestrator.snapshot.runtimeStatus.state == .recovering
        disconnected.withLockedValue { $0 = true }
        let disconnect = Task { @RuntimeActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        let disconnectHeld = try await until(timeout: 5) { disconnectProbe.isHolding }
        // The ladder's probe returns first and stands down.
        ladderProbe.release()
        let stoodDown = try await until(timeout: 5) { !events("recovery.cooldown_cleared").isEmpty }
        let ladderLeft = orchestrator.snapshot.runtimeStatus.state
        disconnectProbe.release()
        await disconnect.value
        let status = orchestrator.snapshot.runtimeStatus
        let outcomes = recoveryOutcomes(orchestrator.eventLog)

        return ScenarioResult(name: "recovery-superseded-by-disconnect", clientCount: 0, clientsOpened: 0,
            clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the exhausted ladder's probe is out while recovering", ladderHeld && recovering),
                .init("the superseded ladder stands down to degraded before the disconnect decides",
                      disconnectHeld && stoodDown && ladderLeft == .degraded),
                .init("the disconnect routes DIRECT", orchestrator.snapshot.directModeCause == .vpnDisconnected),
                .init("the disconnect's verdict owns the status", status.state == .running && status.activeUpstream == "DIRECT"),
                .init("neither the stood-down ladder nor the disconnect records a typed recovery outcome", outcomes == []),
            ], notes: ["refusing loopback upstream on port \(deadPort); injected probe outcomes, the ladder's and the disconnect's probes held"])
    }
}
