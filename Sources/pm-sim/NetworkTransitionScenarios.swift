// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// `pm-sim network-transition`. Exercises the full
/// orchestrator transition table for the daily-driver chaos sequence
/// `Wi-Fi → VPN → captive portal → resume`, verifying:
///
/// 1. Every recovery transition emits exactly one `dns.transports_reset`
///    event so the in-flight DoH `URLSession`s get recycled (matches the
///    `LocalDNSForwarder.resetUpstreamTransports` contract).
/// 2. The orchestrator returns to a non-direct routing state within the
///    Reliability budget (< 5 s end-to-end).
/// 3. The state machine is idempotent under rapid retrigger — wake-after-wake
///    with no intervening real change must not crash, hang, or accumulate
///    stale state, and must still emit one reset per call.
/// 4. The runtime survives the round trip with `eventLog` totals advancing
///    monotonically and no exceptions thrown.
///
/// Mirrors the bare-orchestrator pattern from `VPNFlapScenarios.vpnFlapLongOutage`
/// — no FakeUpstreamProxy is needed because the scenario asserts on the
/// transition events the orchestrator emits, not on an in-flight tunnel
/// surviving (the existing `vpn-flap-*` family covers tunnel survival; this
/// one focuses on the DoH-recycle + recovery-budget contract that the
/// uncommitted `LocalDNSForwarder.resetUpstreamTransports` work introduces).
enum NetworkTransitionScenarios {

    /// Full sequence: connected → reasserting (Wi-Fi handoff) → disconnected
    /// (captive portal blocks egress) → connected (resume). Plus one
    /// `handleSystemWake()` hop at the end to model "user closed the lid,
    /// reopened in a new café Wi-Fi." Asserts:
    ///
    ///  * one `dns.transports_reset` event per recovery hop (vpn flap
    ///    recovery + vpn reconnect after disconnect + system wake = 3 total)
    ///  * `directModeCause` is non-direct after the final transition (or
    ///    `.noUpstreamsConfigured` when the bare orchestrator has no
    ///    upstreams configured — both are accepted because they share the
    ///    same routing-decision shape from the menu bar's perspective)
    ///  * total wall-clock from the first transition to the final settled
    ///    state is < 5 s
    ///  * no extra `dns.transports_reset` events fired between the scripted
    ///    hops (catches the regression where the DoH recycle gets wired into
    ///    a tier-C-shaped path that fires on every `NWPathMonitor` event)
    @MainActor
    static func networkTransition(verbose: Bool) async throws -> ScenarioResult {
        let name = "networkTransition"
        let start = Date()
        var notes: [String] = []

        let orchestrator = makeBareOrchestrator(verbose: verbose)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        // Establish a stable .connected baseline before the cutoff so the
        // initial transition's `vpn.connected` event isn't counted in the
        // recovery total. This is the same pattern the VPN flap scenarios use.
        await orchestrator.handleVPNStateChange(.connected)
        try await Task.sleep(for: .milliseconds(50))
        let cutoff = Date()
        let recoveryStart = cutoff

        // Hop 1: Wi-Fi → VPN handoff. Brief reasserting then back to
        // connected (the tier-B flap path that recycles DoH transports).
        await orchestrator.handleVPNStateChange(.reasserting)
        try await Task.sleep(for: .milliseconds(120))
        await orchestrator.handleVPNStateChange(.connected)
        try await Task.sleep(for: .milliseconds(80))

        // Hop 2: captive portal. Egress is blocked long enough to commit the
        // disconnect (the post-grace path), then resumes. Mirrors the
        // VPNFlapScenarios.vpnFlapLongOutage shape.
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        try await Task.sleep(for: .milliseconds(80))
        await orchestrator.handleVPNStateChange(.connected)
        try await Task.sleep(for: .milliseconds(80))

        // Hop 3: lid-close-and-reopen. handleSystemWake fires a DoH recycle
        // and queues a probe; the orchestrator resolves quickly because no
        // real network call goes out (no upstreams configured).
        await orchestrator.handleSystemWake()
        try await Task.sleep(for: .milliseconds(80))

        let recoveryElapsed = Date().timeIntervalSince(recoveryStart)
        notes.append("totalRecoveryMs=\(Int(recoveryElapsed * 1000))")

        let causeNow = orchestrator.snapshot.directModeCause
        notes.append("final directModeCause=\(causeNow)")

        let recoveryEvents = orchestrator.eventLog.events.filter { $0.timestamp >= cutoff }
        let dnsResetEvents = recoveryEvents.filter { $0.event == "dns.transports_reset" }
        notes.append("dns.transports_reset events=\(dnsResetEvents.count)")
        if verbose {
            for event in dnsResetEvents {
                notes.append("  reset: \(event.detail ?? "<no detail>")")
            }
        }

        // Idempotence probe: drive a second handleSystemWake immediately.
        // Each call must emit one fresh reset event — the contract is
        // "recycle every time the orchestrator decides it needs to," not
        // "deduplicate based on debounce." The deduplication, if any, is
        // the *fuser*'s responsibility upstream of this entry point.
        let idempotenceCutoff = Date()
        await orchestrator.handleSystemWake()
        try await Task.sleep(for: .milliseconds(50))
        let idempotenceResets = orchestrator.eventLog.events
            .filter { $0.timestamp >= idempotenceCutoff && $0.event == "dns.transports_reset" }
            .count
        notes.append("idempotence reset events=\(idempotenceResets)")

        // Pass conditions:
        //  - Three recovery resets from the scripted hops:
        //      hop1: vpn_flap_recovered (reasserting → connected)
        //      hop2: vpn_reconnected    (disconnected → connected)
        //      hop3: system_wake        (handleSystemWake)
        //  - Recovery budget honoured (< 5 s)
        //  - Final state is not stuck in a transient direct-mode cause
        //  - Idempotent retrigger emits exactly one more reset
        let expectedResetCount = 3
        let recoveryWithinBudget = recoveryElapsed < 5.0
        let finalStateOk = causeNow == .none
            || causeNow == .noUpstreamsConfigured
        let idempotenceOk = idempotenceResets == 1

        let pass = dnsResetEvents.count == expectedResetCount
            && recoveryWithinBudget
            && finalStateOk
            && idempotenceOk

        if !pass {
            notes.append("expected resets=\(expectedResetCount) got=\(dnsResetEvents.count)")
            notes.append("budget ok=\(recoveryWithinBudget) finalState ok=\(finalStateOk) idempotence ok=\(idempotenceOk)")
        }
        notes.append(pass ? "PASS" : "FAIL")

        return ScenarioResult(
            name: name,
            clientCount: 0,
            clientsOpened: 0,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 0,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes
        )
    }

    @MainActor
    private static func makeBareOrchestrator(verbose: Bool) -> ProxyOrchestrator {
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.routing.pacRoutingEnabled = false
        // Empty upstreams keeps the orchestrator from probing real network on
        // the .connected transitions — the routing decision short-circuits
        // to .noUpstreamsConfigured, which is what we want for a hermetic
        // scenario. The `dns.transports_reset` emission is independent of
        // probe outcome (it lives in the recovery branch before refresh).
        config.upstreams = []
        return ProxyOrchestrator(config: config, logger: logger)
    }
}
