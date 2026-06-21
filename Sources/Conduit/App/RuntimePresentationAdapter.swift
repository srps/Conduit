// SPDX-License-Identifier: Apache-2.0
import Combine
import Foundation
import ProxyKernel

@MainActor
final class RuntimePresentationAdapter: ObservableObject {

    // MARK: - Immediate (operator-critical) state

    @Published private(set) var runtimeStatus: ProxyRuntimeStatus = .initial
    @Published private(set) var dnsRunState: ModuleRunState = .stopped
    @Published private(set) var tunnelsRunState: ModuleRunState = .stopped
    /// Whether the proxy is in direct mode. Derived from `directModeCause` so
    /// there is no second source of truth — `directModeCause` is the only
    /// `@Published` field; views observe state changes via the cause and call
    /// `directMode` when they only care about the boolean.
    var directMode: Bool { directModeCause.isDirect }
    @Published private(set) var directModeCause: DirectModeCause = .none
    /// What the VPN observer believes. Drives the VPN row in `MainView`. Phase 4
    /// will additionally drive `directModeCause` transitions on this field's
    /// changes — for now Phase 3 just mirrors it for UI display.
    @Published private(set) var vpnState: VPNObservedState = .unknown
    @Published private(set) var proxyError: String?
    @Published private(set) var dnsError: String?
    @Published private(set) var tunnelsError: String?
    @Published private(set) var bindings: ProxyOrchestratorBindings = .init()

    /// Runtime auth outcome the UI chip mirrors. Nil until the first
    /// handshake completes. `nil` → chip falls back to `config.authMode`;
    /// non-nil → chip reports what actually happened on the wire, so a
    /// Kerberos→NTLM fallback surfaces instead of being silently masked
    /// by "the config says Kerberos".
    @Published private(set) var lastAuthOutcome: RuntimeAuthOutcome?
    @Published private(set) var lastAuthOutcomeAt: Date?
    /// Reason code for the last `ntlmFallback` outcome (e.g. `bad_mech`).
    /// Non-nil iff `lastAuthOutcome == .ntlmFallback`; used in the chip
    /// tooltip so "why did it fall back" is one hover away.
    @Published private(set) var lastAuthFallbackReason: String?

    // MARK: - Coalesced (counter/diagnostic) state

    @Published private(set) var requestsHandled: Int = 0
    @Published private(set) var failedRequests: Int = 0
    @Published private(set) var successfulRecoveries: Int = 0
    @Published private(set) var uptimeStartedAt: Date?
    /// Snapshot of active connections, mirrored from the orchestrator's
    /// `ActiveConnectionStore`. Stored as the bare ordered array so SwiftUI
    /// `ForEach`/`.count`/`.isEmpty`/`.filter` consumers work without going
    /// through the store's `.ordered` accessor on every read.
    @Published private(set) var activeConnections: [ActiveConnectionInfo] = []
    @Published private(set) var upstreamStatuses: [UpstreamRuntimeStatus] = []
    @Published private(set) var dnsQueryCount: Int = 0
    @Published private(set) var dnsDoHFallbackCount: Int = 0
    @Published private(set) var dnsCacheHitCount: Int = 0
    @Published private(set) var tunnelActiveCount: Int = 0
    @Published private(set) var tunnelSessionCount: Int = 0
    @Published private(set) var tunnelDNSOverrideStatus: TunnelDNSOverrideStatus = .notNeeded

    // MARK: - Phase 7: VPN flap telemetry strip
    //
    // Mirrors the new fields on `ProxyMetrics`. Coalesced (counter-grade) — the
    // strip updates lazily; the immediate `directModeCause` / `vpnState`
    // path above already covers the user-facing transitions.
    @Published private(set) var vpnFlapCount: Int = 0
    @Published private(set) var vpnFlapTotalDuration: TimeInterval = 0
    @Published private(set) var lastVpnFlapAt: Date?
    @Published private(set) var streamsPreservedAcrossFlaps: Int = 0

    // MARK: - Resettable counter baselines
    //
    // The orchestrator's request/error counters are cumulative for the
    // daemon's lifetime — a daily-driver session accumulates them
    // indefinitely and the UI has no way to say "errors since I last
    // looked". Reset is purely presentational: we remember the raw values
    // at reset time and publish the delta. If the raw counter ever goes
    // backwards (orchestrator restart), the baseline self-clears.
    private var rawRequestsHandled = 0
    private var rawFailedRequests = 0
    private var requestsHandledBaseline = 0
    private var failedRequestsBaseline = 0

    /// Zero the displayed Requests/Errors counters from this moment on.
    func resetActivityCounters() {
        requestsHandledBaseline = rawRequestsHandled
        failedRequestsBaseline = rawFailedRequests
        if requestsHandled != 0 { requestsHandled = 0 }
        if failedRequests != 0 { failedRequests = 0 }
    }

    private var pendingCoalescedSnapshot: ProxyOrchestratorSnapshot?
    /// Coalesce scheduling uses `DispatchQueue.main.asyncAfter` rather than
    /// `Timer.scheduledTimer` because the latter only fires when the main
    /// run loop is pumping in default mode — which it isn't during an
    /// `await Task.sleep` on `@MainActor` (Task.sleep parks via libdispatch,
    /// not the run loop). Dispatch-based scheduling integrates with the
    /// MainActor queue directly and fires reliably regardless of how the
    /// suspending caller is waiting.
    private var coalesceWork: DispatchWorkItem?
    private let coalesceInterval: TimeInterval

    init(coalesceInterval: TimeInterval = 1.0) {
        self.coalesceInterval = coalesceInterval
    }

    func apply(snapshot: ProxyOrchestratorSnapshot) {
        applyImmediate(snapshot)
        scheduleCoalescedUpdate(snapshot)
    }

    func stop() {
        coalesceWork?.cancel()
        coalesceWork = nil
        pendingCoalescedSnapshot = nil
    }

    // MARK: - Platform overrides

    func applyDNSHealthOverride(runState: ModuleRunState?, error: String?) {
        if let runState { dnsRunState = runState }
        dnsError = error
    }

    // MARK: - Internals

    private func applyImmediate(_ snapshot: ProxyOrchestratorSnapshot) {
        if runtimeStatus.state != snapshot.runtimeStatus.state
            || runtimeStatus.activeUpstream != snapshot.runtimeStatus.activeUpstream
            || runtimeStatus.lastHealthSummary != snapshot.runtimeStatus.lastHealthSummary {
            runtimeStatus = snapshot.runtimeStatus
        }
        if vpnState != snapshot.vpnState { vpnState = snapshot.vpnState }
        if dnsRunState != snapshot.dnsRunState { dnsRunState = snapshot.dnsRunState }
        if tunnelsRunState != snapshot.tunnelsRunState { tunnelsRunState = snapshot.tunnelsRunState }
        if directModeCause != snapshot.directModeCause { directModeCause = snapshot.directModeCause }
        if proxyError != snapshot.proxyError { proxyError = snapshot.proxyError }
        if dnsError != snapshot.dnsError { dnsError = snapshot.dnsError }
        if tunnelsError != snapshot.tunnelsError { tunnelsError = snapshot.tunnelsError }
        if bindings != snapshot.bindings { bindings = snapshot.bindings }
        if lastAuthOutcome != snapshot.lastAuthOutcome { lastAuthOutcome = snapshot.lastAuthOutcome }
        if lastAuthOutcomeAt != snapshot.lastAuthOutcomeAt { lastAuthOutcomeAt = snapshot.lastAuthOutcomeAt }
        if lastAuthFallbackReason != snapshot.lastAuthFallbackReason { lastAuthFallbackReason = snapshot.lastAuthFallbackReason }
    }

    private func scheduleCoalescedUpdate(_ snapshot: ProxyOrchestratorSnapshot) {
        pendingCoalescedSnapshot = snapshot
        guard coalesceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.flushCoalesced()
            }
        }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: work)
    }

    private func flushCoalesced() {
        coalesceWork = nil
        guard let snapshot = pendingCoalescedSnapshot else { return }
        pendingCoalescedSnapshot = nil

        let metrics = snapshot.runtimeStatus.metrics
        rawRequestsHandled = metrics.requestsHandled
        rawFailedRequests = metrics.failedRequests
        if metrics.requestsHandled < requestsHandledBaseline { requestsHandledBaseline = 0 }
        if metrics.failedRequests < failedRequestsBaseline { failedRequestsBaseline = 0 }
        let adjustedRequests = max(0, metrics.requestsHandled - requestsHandledBaseline)
        let adjustedFailures = max(0, metrics.failedRequests - failedRequestsBaseline)
        if requestsHandled != adjustedRequests { requestsHandled = adjustedRequests }
        if failedRequests != adjustedFailures { failedRequests = adjustedFailures }
        if successfulRecoveries != metrics.successfulRecoveries { successfulRecoveries = metrics.successfulRecoveries }
        if uptimeStartedAt != metrics.uptimeStartedAt { uptimeStartedAt = metrics.uptimeStartedAt }
        if vpnFlapCount != metrics.vpnFlapCount { vpnFlapCount = metrics.vpnFlapCount }
        if vpnFlapTotalDuration != metrics.vpnFlapTotalDuration { vpnFlapTotalDuration = metrics.vpnFlapTotalDuration }
        if lastVpnFlapAt != metrics.lastVpnFlapAt { lastVpnFlapAt = metrics.lastVpnFlapAt }
        if streamsPreservedAcrossFlaps != metrics.streamsPreservedAcrossFlaps { streamsPreservedAcrossFlaps = metrics.streamsPreservedAcrossFlaps }
        if activeConnections != snapshot.activeConnections.ordered { activeConnections = snapshot.activeConnections.ordered }
        if upstreamStatuses != snapshot.upstreamStatuses { upstreamStatuses = snapshot.upstreamStatuses }
        if dnsQueryCount != snapshot.dnsQueryCount { dnsQueryCount = snapshot.dnsQueryCount }
        if dnsDoHFallbackCount != snapshot.dnsDoHFallbackCount { dnsDoHFallbackCount = snapshot.dnsDoHFallbackCount }
        if dnsCacheHitCount != snapshot.dnsCacheHitCount { dnsCacheHitCount = snapshot.dnsCacheHitCount }
        if tunnelActiveCount != snapshot.tunnelActiveCount { tunnelActiveCount = snapshot.tunnelActiveCount }
        if tunnelSessionCount != snapshot.tunnelSessionCount { tunnelSessionCount = snapshot.tunnelSessionCount }
        if tunnelDNSOverrideStatus != snapshot.tunnelDNSOverrideStatus { tunnelDNSOverrideStatus = snapshot.tunnelDNSOverrideStatus }
    }
}
