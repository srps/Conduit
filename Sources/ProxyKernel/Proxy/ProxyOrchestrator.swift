// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix

package struct ProxyOrchestratorBindings: Sendable, Codable, Equatable {
    package var proxyHost: String?
    package var proxyPort: Int?
    package var socksHost: String?
    package var socksPort: Int?
    package var localPACHost: String?
    package var localPACPort: Int?
    package var dnsHost: String?
    package var dnsPort: Int?
    package var tunnels: [TunnelBindingInfo]

    package init(
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        localPACHost: String? = nil,
        localPACPort: Int? = nil,
        dnsHost: String? = nil,
        dnsPort: Int? = nil,
        tunnels: [TunnelBindingInfo] = []
    ) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.localPACHost = localPACHost
        self.localPACPort = localPACPort
        self.dnsHost = dnsHost
        self.dnsPort = dnsPort
        self.tunnels = tunnels
    }

    package var localPACURL: String? {
        guard let localPACHost, let localPACPort else { return nil }
        return "http://\(localPACHost):\(localPACPort)\(LocalPACServer.pacPath)"
    }

    private enum CodingKeys: String, CodingKey {
        case proxyHost
        case proxyPort
        case socksHost
        case socksPort
        case localPACHost
        case localPACPort
        case dnsHost
        case dnsPort
        case tunnels
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost)
        self.proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort)
        self.socksHost = try c.decodeIfPresent(String.self, forKey: .socksHost)
        self.socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort)
        self.localPACHost = try c.decodeIfPresent(String.self, forKey: .localPACHost)
        self.localPACPort = try c.decodeIfPresent(Int.self, forKey: .localPACPort)
        self.dnsHost = try c.decodeIfPresent(String.self, forKey: .dnsHost)
        self.dnsPort = try c.decodeIfPresent(Int.self, forKey: .dnsPort)
        self.tunnels = try c.decodeIfPresent([TunnelBindingInfo].self, forKey: .tunnels) ?? []
    }
}

package struct ProxyOrchestratorSnapshot: Sendable, Equatable, Codable {
    package var runtimeStatus: ProxyRuntimeStatus
    /// Active connections, indexed by ID. Was `[ActiveConnectionInfo]` pre-
    /// PR; the type swap eliminated the O(N) `firstIndex(where:)` scan
    /// that fired per-close and per-activity-update on the MainActor.
    /// Wire format unchanged — `ActiveConnectionStore` Codables as a bare
    /// array. See `ActiveConnectionStore`'s file-level comment for the
    /// ordering caveat (swap-remove reorders contents).
    package var activeConnections: ActiveConnectionStore
    package var upstreamStatuses: [UpstreamRuntimeStatus]
    /// Why the proxy is in a direct/degraded connectivity state (or `.none`
    /// when upstream routing is healthy). Single source of truth for direct
    /// mode health and routing predicates. Drives log severity, error-rate
    /// alarm gating, reprobe cadence, and the user-visible health summary
    /// string. See `docs/design-vpn-flap-resilience.md`.
    package var directModeCause: DirectModeCause
    /// What the VPN-state observer (Tier B utun + Tier C path-monitor fallback)
    /// believes about the VPN. Phase 3 added this field; Phase 4 wires it into
    /// the orchestrator transition table. For now it's stored verbatim — the
    /// orchestrator does not yet branch on it.
    package var vpnState: VPNObservedState
    package var proxyError: String?
    package var dnsError: String?
    package var dnsRunState: ModuleRunState
    package var dnsQueryCount: Int
    package var dnsDoHFallbackCount: Int
    package var dnsCacheHitCount: Int
    package var tunnelsRunState: ModuleRunState
    package var tunnelsError: String?
    package var tunnelActiveCount: Int
    package var tunnelSessionCount: Int
    package var tunnelDNSOverrideStatus: TunnelDNSOverrideStatus
    package var bindings: ProxyOrchestratorBindings

    /// What the authenticator actually produced on the most recent handshake.
    /// Nil until the first request completes auth. Drives the UI's auth chip
    /// so "Kerberos" only appears when Kerberos really fired; a silent
    /// fallback to NTLM surfaces as `.ntlmFallback`. See `RuntimeAuthOutcome`.
    package var lastAuthOutcome: RuntimeAuthOutcome?
    /// Timestamp of the most recent auth outcome; used by the UI to age-out
    /// the chip state if auth goes quiet for a long time.
    package var lastAuthOutcomeAt: Date?
    /// Compact reason code for the last `ntlmFallback` outcome
    /// (e.g. `bad_mech`, `no_credential`, `credentials_expired`). Nil when
    /// the last outcome wasn't a fallback. Exposed so the UI and logs can
    /// distinguish "TGT missing" from "TGT expired" without round-tripping
    /// through the event stream.
    package var lastAuthFallbackReason: String?

    package init(
        runtimeStatus: ProxyRuntimeStatus = .initial,
        activeConnections: ActiveConnectionStore = ActiveConnectionStore(),
        upstreamStatuses: [UpstreamRuntimeStatus] = [],
        directModeCause: DirectModeCause = .none,
        vpnState: VPNObservedState = .unknown,
        proxyError: String? = nil,
        dnsError: String? = nil,
        dnsRunState: ModuleRunState = .stopped,
        dnsQueryCount: Int = 0,
        dnsDoHFallbackCount: Int = 0,
        dnsCacheHitCount: Int = 0,
        tunnelsRunState: ModuleRunState = .stopped,
        tunnelsError: String? = nil,
        tunnelActiveCount: Int = 0,
        tunnelSessionCount: Int = 0,
        tunnelDNSOverrideStatus: TunnelDNSOverrideStatus = .notNeeded,
        bindings: ProxyOrchestratorBindings = .init(),
        lastAuthOutcome: RuntimeAuthOutcome? = nil,
        lastAuthOutcomeAt: Date? = nil,
        lastAuthFallbackReason: String? = nil
    ) {
        self.runtimeStatus = runtimeStatus
        self.activeConnections = activeConnections
        self.upstreamStatuses = upstreamStatuses
        self.directModeCause = directModeCause
        self.vpnState = vpnState
        self.proxyError = proxyError
        self.dnsError = dnsError
        self.dnsRunState = dnsRunState
        self.dnsQueryCount = dnsQueryCount
        self.dnsDoHFallbackCount = dnsDoHFallbackCount
        self.dnsCacheHitCount = dnsCacheHitCount
        self.tunnelsRunState = tunnelsRunState
        self.tunnelsError = tunnelsError
        self.tunnelActiveCount = tunnelActiveCount
        self.tunnelSessionCount = tunnelSessionCount
        self.tunnelDNSOverrideStatus = tunnelDNSOverrideStatus
        self.bindings = bindings
        self.lastAuthOutcome = lastAuthOutcome
        self.lastAuthOutcomeAt = lastAuthOutcomeAt
        self.lastAuthFallbackReason = lastAuthFallbackReason
    }
}

package enum ProxyOrchestratorEvent: Sendable {
    case proxyRecovered(activeUpstream: String?)
    case proxyRecoveryFailed(summary: String, authenticationLikely: Bool)
}

private final class ProxyConfigBox: @unchecked Sendable {
    private let box: NIOLockedValueBox<ProxyConfig>

    init(_ config: ProxyConfig) {
        self.box = NIOLockedValueBox(config)
    }

    var current: ProxyConfig {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

/// Reference-type holder for the authenticator factory. Exists to avoid
/// `NIOLockedValueBox<@Sendable (String) throws -> ProxyAuthenticator>`,
/// whose `(inout T) throws -> R` body contract reabstracts closure-typed
/// values through @in_guaranteed/@guaranteed thunks on every invocation —
/// the box writes the re-thunked closure back to storage on body return,
/// and subsequent calls compound the thunk layers. That footgun caused a
/// ~4-frame-per-call stack-frame leak that eventually toppled the crash
/// reported on 2026-04-22 after ~550 CONNECT handshakes.
///
/// This holder reads the factory into a local via a plain class-field
/// load (no inout), releases the lock, then invokes. No inout copy-out,
/// no reabstraction cycle, no accumulation. Regression test:
/// `AuthProviderStackDepthTests.testLateBoundProviderFrameCountIsBounded`.
private final class AuthProviderHolder: @unchecked Sendable {
    private let lock = NIOLock()
    private var provider: @Sendable (String) throws -> ProxyAuthenticator

    init(initial: @escaping @Sendable (String) throws -> ProxyAuthenticator) {
        self.provider = initial
    }

    func set(_ newProvider: @escaping @Sendable (String) throws -> ProxyAuthenticator) {
        lock.lock()
        defer { lock.unlock() }
        self.provider = newProvider
    }

    func invoke(_ host: String) throws -> ProxyAuthenticator {
        lock.lock()
        let snapshot = self.provider
        lock.unlock()
        return try snapshot(host)
    }
}

@MainActor
package final class ProxyOrchestrator {
    package var onSnapshotChange: ((ProxyOrchestratorSnapshot) -> Void)? {
        // Fire the initial snapshot synchronously when the consumer wires
        // up the callback — that's the AppState bootstrap that builds the
        // first UI render. Goes through the immediate path so any pending
        // coalesced flush is cancelled (otherwise we'd double-emit).
        didSet { emitSnapshotImmediate() }
    }
    package var onEvent: ((ProxyOrchestratorEvent) -> Void)?
    package var onConfigChange: ((ProxyConfig) -> Void)?

    package let logStore: any LogSink
    package let eventLog = RuntimeEventLog()
    /// Connection audit log sink. Defaults to
    /// `DiscardingConnectionAuditSink` (silent) so the orchestrator can
    /// be constructed without one in headless / test contexts. The
    /// SwiftUI app and `pm-proxy` (when audit is enabled in config) wire
    /// in `FileConnectionAuditSink` pointed at `$state-dir/audit.ndjson`.
    /// One record per `onConnectionClosed` callback (see the
    /// `localProxyServer` lazy initializer below).
    package let auditSink: any ConnectionAuditSink
    package private(set) var snapshot = ProxyOrchestratorSnapshot()

    /// Read-only snapshot accessor for the live config, callable from any
    /// thread / any actor isolation. Allocated once at `init`; callers
    /// (`AppState`, `pm-proxy`) capture it at startup and forward to the
    /// `credentialBasedAuthenticatorProvider` factory closure that runs on
    /// NIO event loops.
    ///
    /// Previously `AppState` and `pm-proxy` each maintained
    /// their own `NIOLockedValueBox<ProxyConfig>` mirror to satisfy the
    /// auth factory's `@Sendable () -> ProxyConfig` requirement. With this
    /// stored property, the orchestrator becomes the single source of
    /// truth and the mirrors collapse.
    ///
    /// **Invariant**: the `config` setter must update `configBox` *before*
    /// running side-effects so the closure never returns a snapshot older
    /// than the in-flight reload. This ordering is load-bearing for the
    /// auth factory; do not reorder.
    package let configSnapshotProvider: @Sendable () -> ProxyConfig

    private func mutateSnapshot(_ body: (inout ProxyOrchestratorSnapshot) -> Void) {
        body(&snapshot)
        emitSnapshotImmediate()
    }

    // MARK: - Snapshot emission throttle (PR 5 of perf cleanup)
    //
    // Two-tier emission:
    //
    //   - State-transition callsites (start/stop, vpn changes, errors,
    //     direct-mode flips, auth outcome, the `mutateSnapshot` helper)
    //     call `emitSnapshotImmediate()`. The UI sees these instantly.
    //
    //   - Counter-tier callsites (per-connection open/close, per-request
    //     completion, DNS metric tick, tunnel session count) call
    //     `emitSnapshotCoalesced()`. Multiple coalesced calls within
    //     `snapshotCoalesceInterval` collapse to one emission at the end
    //     of the window.
    //
    // Why: the per-request callbacks fire synchronously on every wire-level
    // event. At 50 req/s burst that meant 150 MainActor `onSnapshotChange`
    // fan-outs per second through the `RuntimePresentationAdapter`. The
    // adapter then re-coalesces *publishes* at 1 Hz, so the immediate
    // fan-out gave the UI nothing actionable — the immediate-tier fields
    // (state, vpn, errors, bindings, auth outcome) only change on rare
    // events anyway, and counter-tier fields are coalesced again at the
    // adapter boundary. Throttling the orchestrator emission caps the
    // upstream work at 10 Hz without changing what the UI shows.
    //
    // 100ms is fast enough that no human notices the lag on counter
    // increments (the adapter then re-coalesces at 1 Hz before publishing).
    // Slow enough that a 100 req/s burst translates to ≤ 10 emissions/s
    // instead of 300+.
    //
    // State-transition emissions cancel any pending coalesced flush — the
    // immediate emission already carried the snapshot, so re-emitting the
    // same snapshot 99ms later would be redundant.
    //
    // See `SnapshotCoalescingTests` for the locked-down behaviour.

    /// Maximum coalesce window for counter-tier emissions. 100ms.
    private static let snapshotCoalesceInterval: DispatchTimeInterval = .milliseconds(100)

    /// `true` when a counter-tier callsite has mutated the snapshot but
    /// the throttled flush hasn't fired yet. Cleared by every emission
    /// path (`flushPendingSnapshot()` or the cancellation in
    /// `emitSnapshotImmediate()`).
    private var snapshotCoalescePending = false

    /// Active timer awaiting the next coalesced flush. Owned here so
    /// `emitSnapshotImmediate()` can cancel a pending flush, and so
    /// teardown paths (`stopProxy`, `performTerminationCleanup`) can
    /// release it.
    private var snapshotCoalesceTimer: DispatchSourceTimer?

    /// State-transition emit. Bypasses the throttle, cancels any pending
    /// coalesced flush, and fires `onSnapshotChange` synchronously.
    /// Use from `mutateSnapshot`, lifecycle paths, vpn transitions, etc.
    private func emitSnapshotImmediate() {
        if snapshotCoalescePending || snapshotCoalesceTimer != nil {
            snapshotCoalescePending = false
            snapshotCoalesceTimer?.cancel()
            snapshotCoalesceTimer = nil
        }
        onSnapshotChange?(snapshot)
    }

    /// Counter-tier emit. Marks snapshot dirty and schedules a flush at
    /// most once per `snapshotCoalesceInterval`. Subsequent calls within
    /// the window are absorbed (no extra timer, no extra emission).
    private func emitSnapshotCoalesced() {
        snapshotCoalescePending = true
        guard snapshotCoalesceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.snapshotCoalesceInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingSnapshot()
            }
        }
        timer.resume()
        snapshotCoalesceTimer = timer
    }

    /// Timer handler. Drops the timer reference, then emits if a coalesced
    /// flush is still pending (a state-transition emit might have already
    /// flushed and cancelled in the gap between schedule and fire — in
    /// which case `snapshotCoalescePending` is false and we no-op).
    private func flushPendingSnapshot() {
        snapshotCoalesceTimer = nil
        guard snapshotCoalescePending else { return }
        snapshotCoalescePending = false
        onSnapshotChange?(snapshot)
    }

    /// Teardown helper. Cancels any pending coalesced flush WITHOUT emitting.
    /// Called from `performTerminationCleanup` to drop pending main-queue
    /// work before process exit. The timer captures `[weak self]` so a
    /// fired-then-deallocated path is also safe, but explicit cancellation
    /// keeps the queue clean.
    private func stopSnapshotCoalesceTimer() {
        snapshotCoalesceTimer?.cancel()
        snapshotCoalesceTimer = nil
        snapshotCoalescePending = false
    }

    /// Test seam — drives the same `emitSnapshotCoalesced` path the
    /// per-connection / per-request callbacks use. Production callers
    /// reach this through `onConnectionOpened` etc.; `SnapshotCoalescingTests`
    /// drives it directly so the throttle is testable without standing up
    /// real client connections.
    package func triggerCoalescedSnapshotEmitForTesting() {
        emitSnapshotCoalesced()
    }

    /// Test seam — runs `body` against the snapshot and emits via the
    /// immediate path (the same one `mutateSnapshot` uses internally).
    /// Lets `SnapshotCoalescingTests` verify the immediate-cancels-pending
    /// contract without leaking the private `mutateSnapshot` helper.
    package func mutateSnapshotForTesting(_ body: (inout ProxyOrchestratorSnapshot) -> Void) {
        mutateSnapshot(body)
    }

    /// Test seam — exercises direct-mode side effects (including served local
    /// PAC updates) without depending on live upstream reachability.
    package func setDirectModeForTesting(_ cause: DirectModeCause) {
        setDirectMode(cause)
    }

    private func emitEvent(_ kind: RuntimeEventKind, _ event: String, detail: String? = nil) {
        eventLog.append(RuntimeEvent(kind: kind, event: event, detail: detail))
    }

    /// Build and emit one `ConnectionAuditRecord` for the closing
    /// connection. Called from `localProxyServer.onConnectionClosed`
    /// BEFORE the entry is removed from `snapshot.activeConnections`,
    /// so the lookup finds the destination/upstream/bytes that the
    /// HTTP/CONNECT handlers wrote up through the activity callback.
    ///
    /// The auth method is sourced from `ActiveConnectionInfo.authMethod`,
    /// which the upstream exchange / CONNECT / SOCKS paths update when
    /// their per-connection upstream auth handshake succeeds. Do NOT use
    /// `snapshot.lastAuthOutcome` here: that field is global
    /// orchestrator state for UI chips and can represent a different
    /// connection's later handshake.
    ///
    /// `outcome: .success` is used unconditionally: a connection that
    /// reached `onConnectionClosed` was opened (the upstream callback
    /// fired) and produced bytes. Connection-attempt failures that
    /// don't open the upstream side never reach this code path; their
    /// audit visibility lives in `RuntimeEvent` (`upstream.circuit_*`,
    /// `auth.*` etc.) instead.
    ///
    /// Exposed as `package` (rather than `private`) so test code in the
    /// kernel target can drive the audit funnel without standing up the
    /// full pipeline; the production call site is still confined to the
    /// `localProxyServer.onConnectionClosed` callback below.
    ///
    /// Tests can pass an explicit `info:` to short-circuit the snapshot
    /// lookup. Production callers always pass `nil` and rely on the
    /// snapshot — the lookup must succeed because the production
    /// callback runs BEFORE the connection is removed from the
    /// snapshot.
    @MainActor
    package func recordConnectionCloseForAudit(id: UUID, info: ActiveConnectionInfo? = nil) {
        guard let info = info ?? snapshot.activeConnections.ordered.first(where: { $0.id == id }) else {
            return
        }
        let scheme: ConnectionAuditRecord.Scheme
        if info.method.uppercased() == "SOCKS5" {
            scheme = .socks5
        } else if info.method.uppercased() == "CONNECT" || info.tunnel {
            scheme = .connect
        } else if info.destination.hasSuffix(":443") {
            scheme = .https
        } else {
            scheme = .http
        }
        let durationMS = Int(info.lastActivityAt.timeIntervalSince(info.startedAt) * 1_000)
        let record = ConnectionAuditRecord(
            id: info.id,
            timestamp: info.startedAt,
            clientAddress: nil,  // Per-connection client address is not on ActiveConnectionInfo today; revisit.
            scheme: scheme,
            target: SensitiveValueSanitizer.auditTarget(info.destination),
            pacDecision: nil,    // Per-connection PAC routing isn't recorded in the snapshot today.
            chosenUpstream: info.upstream.isEmpty ? nil : info.upstream,
            authMethod: info.authMethod,
            bytesSent: info.bytesSent,
            bytesReceived: info.bytesReceived,
            durationMS: max(0, durationMS),
            outcome: .success
        )
        auditSink.record(record)
    }

    private func localPACScriptConfig() -> ProxyConfig {
        var scriptConfig = config
        let actualProxyHost = localProxyServer.listeningHost ?? scriptConfig.localHost
        scriptConfig.localHost = Self.loopbackReachableProxyHost(actualProxyHost)
        if let actualProxyPort = localProxyServer.listeningPort {
            scriptConfig.localPort = actualProxyPort
        }
        return scriptConfig
    }

    private func localPACScript(directRoutingAllowed: Bool) -> String {
        PACScriptEmitter.script(for: localPACScriptConfig(), directRoutingAllowed: directRoutingAllowed)
    }

    private static func loopbackReachableProxyHost(_ host: String) -> String {
        switch host {
        case "0.0.0.0", "::", "[::]":
            return "127.0.0.1"
        default:
            return host
        }
    }

    private func reconcileLocalPACServer(reason: String) async throws {
        let currentConfig = config
        guard currentConfig.localPACEnabled else {
            if localPACServer.isRunning {
                emitEvent(.routing, "local_pac.stopping", detail: "reason=\(reason)")
                await localPACServer.stop()
                emitEvent(.routing, "local_pac.stopped", detail: "reason=\(reason)")
                mutateSnapshot {
                    $0.bindings.localPACHost = nil
                    $0.bindings.localPACPort = nil
                }
            }
            return
        }

        let script = localPACScript(directRoutingAllowed: snapshot.directModeCause.advertisesDirectOnlyPAC)
        if localPACServer.isRunning, localPACServer.listeningPort == currentConfig.localPACPort || currentConfig.localPACPort == 0 {
            localPACServer.updateScript(script)
            emitEvent(.routing, "local_pac.updated", detail: "reason=\(reason)")
        } else {
            if localPACServer.isRunning {
                emitEvent(.routing, "local_pac.restarting", detail: "reason=\(reason)")
                await localPACServer.stop()
            } else {
                emitEvent(.routing, "local_pac.starting", detail: "reason=\(reason)")
            }
            do {
                try await localPACServer.start(
                    host: Self.localPACListenHost,
                    port: currentConfig.localPACPort,
                    script: script
                )
                emitEvent(.routing, "local_pac.started", detail: "reason=\(reason)")
            } catch {
                emitEvent(.routing, "local_pac.failed", detail: error.localizedDescription)
                throw error
            }
        }

        mutateSnapshot {
            $0.bindings.localPACHost = self.localPACServer.listeningHost
            $0.bindings.localPACPort = self.localPACServer.listeningPort
        }
    }

    private func refreshLocalPACForDirectModeChange(_ cause: DirectModeCause) {
        guard config.localPACEnabled, localPACServer.isRunning else { return }
        emitEvent(.routing, "local_pac.updated", detail: "reason=direct_mode_change cause=\(cause.rawValue)")
        localPACServer.updateScript(localPACScript(directRoutingAllowed: cause.advertisesDirectOnlyPAC))
    }

    /// Reporter for runtime auth outcomes. Called from the NIO-spawned
    /// auth `Task` (off the main actor) via the `outcomeHandler` closure
    /// threaded through `credentialBasedAuthenticatorProvider`. Emits the
    /// `.auth` event first (per AGENTS.md "events-first" invariant),
    /// derives the human-readable log line from the same decision, and
    /// schedules a MainActor hop to mutate the snapshot so the UI chip
    /// reflects runtime reality rather than configured intent.
    ///
    /// `nonisolated` because the call site is an NIO Task; we do the hop
    /// internally rather than forcing every caller to wrap in `Task { @MainActor in }`.
    package nonisolated func reportAuthOutcome(
        _ outcome: RuntimeAuthOutcome,
        host: String,
        reason: String? = nil
    ) {
        let event: String
        let detail: String
        switch outcome {
        case .kerberos:
            event = "auth.kerberos_succeeded"
            detail = "host=\(host)"
        case .ntlmFallback:
            event = "auth.kerberos_fallback_ntlm"
            detail = reason.map { "host=\(host) reason=\($0)" } ?? "host=\(host)"
        case .ntlmDirect:
            event = "auth.ntlm_configured"
            detail = "host=\(host)"
        }
        eventLog.append(RuntimeEvent(kind: .auth, event: event, detail: detail))

        // Log line is derived from the event. Fallback always logs; the
        // other outcomes log once per transition so the auth tab doesn't
        // fill with per-request noise.
        // `.notice` across all transitions so the Logs view (buffered
        // threshold defaults to `.notice`) picks them up. Transition-
        // gating on `prior` keeps the `.kerberos` / `.ntlmDirect` cases
        // to one line per state change; `.ntlmFallback` always logs
        // because every fallback is user-relevant (explains the
        // Keychain prompt and the orange chip state).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prior = self.snapshot.lastAuthOutcome
            switch outcome {
            case .ntlmFallback:
                let reasonSuffix = reason.map { " (\($0))" } ?? ""
                self.logStore.log(
                    .notice,
                    "Kerberos unavailable for \(host)\(reasonSuffix); falling back to NTLMv2.",
                    category: .auth
                )
            case .kerberos where prior != .kerberos:
                self.logStore.log(.notice, "Using Kerberos for \(host).", category: .auth)
            case .ntlmDirect where prior != .ntlmDirect:
                self.logStore.log(.notice, "Using NTLMv2 (configured) for \(host).", category: .auth)
            default:
                break
            }
            self.mutateSnapshot { snap in
                snap.lastAuthOutcome = outcome
                snap.lastAuthOutcomeAt = Date()
                snap.lastAuthFallbackReason = (outcome == .ntlmFallback) ? reason : nil
            }
        }
    }

    package var config: ProxyConfig {
        get { configBox.current }
        set { configBox.current = newValue }
    }

    /// Whether the proxy listener is in a state that can meaningfully service
    /// reconfiguration side-effects (restart, connectivity re-probe, health-loop restart).
    /// Re-evaluated from `snapshot.runtimeStatus.state` on every read so that callers
    /// spanning `stopProxy()` / `startProxy()` cannot observe a stale snapshot — the
    /// earlier pattern of capturing this value once at the top of `applyConfigChange`
    /// allowed the upstream-refresh branch to run against a `.failed` / `.stopped`
    /// proxy when an intervening restart threw.
    private var isProxyActive: Bool {
        switch snapshot.runtimeStatus.state {
        case .running, .degraded, .recovering:
            return true
        case .stopped, .starting, .failed:
            return false
        }
    }

    /// Apply a new config with targeted subsystem reconfiguration.
    /// Only restarts subsystems whose config sections actually changed.
    ///
    /// Every taken decision branch emits a structured `RuntimeEvent` *before* the human-readable
    /// log line, per the AGENTS.md "events first, logs derived" contract — the event stream is
    /// the contract with the UI, `pmctl`, and `pm-sim`; log lines are for tailing humans.
    package func applyConfigChange(_ newConfig: ProxyConfig) async {
        let oldConfig = config
        let diff = ConfigDiff(old: oldConfig, new: newConfig)
        guard diff.hasChanges else {
            guard oldConfig != newConfig else { return }
            emitEvent(.config, "config.metadata_changed")
            config = newConfig
            onConfigChange?(config)
            return
        }

        config = newConfig

        if diff.loggingChanged {
            emitEvent(.config, "config.logging_changed")
            logStore.log(.notice, "Config reload: logging updated.", category: .general)
        }

        if diff.healthChanged && isProxyActive {
            emitEvent(.config, "config.health_restart")
            healthChecker.stop()
            startHealthLoop()
            logStore.log(.notice, "Config reload: health check interval updated.", category: .general)
        }

        if diff.routingChanged {
            emitEvent(.config, "config.routing_changed")
            await refreshPACRouting(force: true)
            if isProxyActive {
                do {
                    try await reconcileLocalPACServer(reason: "routing_reload")
                } catch {
                    logStore.log(
                        .warning,
                        "Config reload: local PAC server update failed — \(error.localizedDescription).",
                        category: .pac
                    )
                }
            }
            logStore.log(.notice, "Config reload: routing rules applied (no restart).", category: .general)
        }

        if diff.dnsChanged && snapshot.dnsRunState == .running {
            emitEvent(.config, "config.dns_restart")
            logStore.log(.notice, "Config reload: DNS config changed, restarting DNS forwarder.", category: .network)
            await stopTransparentProxy()
            await dnsForwarder.stop()
            mutateSnapshot {
                $0.dnsRunState = .stopped
                $0.dnsQueryCount = 0
                $0.dnsDoHFallbackCount = 0
                $0.dnsCacheHitCount = 0
                $0.bindings.dnsHost = nil
                $0.bindings.dnsPort = nil
            }
            await startDNS()
        }

        if diff.tunnelsChanged && (snapshot.tunnelsRunState == .running || snapshot.tunnelsRunState == .warning) {
            emitEvent(.config, "config.tunnels_reconcile")
            logStore.log(.notice, "Config reload: tunnel definitions changed, reconciling.", category: .tunnel)
            await reconcileTunnels()
        }

        // Auth section: invalidate pooled credentials so the next request rebuilds the
        // SPNEGO/NTLM handshake against the new mode/username/domain. Without this the
        // pool would cheerfully reuse already-authed connections that were established
        // under the old auth config until they aged out, silently masking the change.
        if diff.authChanged {
            let modeChanged = oldConfig.auth.mode != newConfig.auth.mode
            let detail = modeChanged
                ? "mode \(oldConfig.auth.mode.rawValue) → \(newConfig.auth.mode.rawValue)"
                : "credentials updated"
            emitEvent(.auth, "config.auth_changed", detail: detail)
            // Clear runtime auth outcome so the UI chip stops asserting the
            // previous mode's result against the new configuration. Without
            // this, switching from `systemNegotiated` (last outcome=
            // `.kerberos`) to `ntlmv2` would leave the chip reading
            // "Kerberos" until the first new-config handshake fires —
            // contradicting `MainView.authBadge`'s "runtime over configured"
            // contract. Done unconditionally (regardless of `isProxyActive`)
            // because the snapshot is the source of truth even between
            // proxy run cycles. Mirrors the `stopProxy()` reset of these
            // same fields below for the same reason.
            mutateSnapshot {
                $0.lastAuthOutcome = nil
                $0.lastAuthOutcomeAt = nil
                $0.lastAuthFallbackReason = nil
            }
            if isProxyActive {
                // `reauthenticate()` is `throws` to satisfy `RecoverableProxyService` (the
                // auto-recovery escalation contract) even though the current pool-flush body
                // never throws. Surface a structured event + warning if it ever does, rather
                // than swallowing it with `try?` — per the AGENTS.md "no silent failures" rule.
                do {
                    try await localProxyServer.reauthenticate()
                    tunnelConnectionPool.resetAuthentication()
                    emitEvent(.auth, "config.tunnel_auth_reauth", detail: detail)
                    logStore.log(.notice, "Config reload: auth updated (\(detail)); pooled proxy/tunnel connections will re-authenticate on next request.", category: .auth)
                } catch {
                    emitEvent(.auth, "config.auth_reauth_failed", detail: error.localizedDescription)
                    logStore.log(
                        .warning,
                        "Config reload: pool re-authentication failed — \(error.localizedDescription). Pooled connections may continue to use the old auth mode until they age out.",
                        category: .auth
                    )
                }
            } else {
                logStore.log(.notice, "Config reload: auth updated (\(detail)); proxy not active, change will apply on next start.", category: .auth)
            }
        }

        if diff.proxyChanged && isProxyActive {
            let needsRestart = oldConfig.proxy.host != newConfig.proxy.host
                || oldConfig.proxy.port != newConfig.proxy.port
                || oldConfig.proxy.gatewayMode != newConfig.proxy.gatewayMode
                || oldConfig.proxy.socksEnabled != newConfig.proxy.socksEnabled
                || oldConfig.proxy.socksPort != newConfig.proxy.socksPort

            if needsRestart {
                emitEvent(.config, "config.proxy_restart")
                logStore.log(.notice, "Config reload: proxy listener config changed, restarting proxy (preserving in-flight tunnels).", category: .proxy)
                // Preserve dedicated CONNECT tunnels across the listener swap. The
                // user changed listener config (host/port/SOCKS), not their intent
                // to keep current HTTPS streams alive — those tunnels are byte-relays
                // tied to channels held by client/upstream pipelines, independent of
                // the new listener identity. See docs/design-vpn-flap-resilience.md.
                await stopProxy(scope: .allButDedicated)
                do {
                    try await startProxy()
                } catch {
                    // startProxy() already logs the underlying error and marks the snapshot as
                    // .failed with proxyError, but the restart context is lost at that call site.
                    // Emit a dedicated event + warning so the reload path surfaces the failure
                    // both to event subscribers and to anyone tailing logs during a SIGHUP /
                    // config reload.
                    emitEvent(.config, "config.proxy_restart_failed", detail: error.localizedDescription)
                    logStore.log(
                        .warning,
                        "Config reload: proxy restart failed — \(error.localizedDescription). Listener is now stopped; check proxyError in status.",
                        category: .proxy
                    )
                }
            } else {
                emitEvent(.config, "config.proxy_limits_updated")
                logStore.log(.notice, "Config reload: proxy limits updated (no restart).", category: .proxy)
                if oldConfig.proxy.strictMode != newConfig.proxy.strictMode,
                   newConfig.localPACEnabled,
                   isProxyActive {
                    emitEvent(.config, "config.strict_mode_pac_refresh")
                    do {
                        try await reconcileLocalPACServer(reason: "strict_mode_reload")
                    } catch {
                        logStore.log(
                            .warning,
                            "Config reload: local PAC strict-mode update failed — \(error.localizedDescription).",
                            category: .pac
                        )
                    }
                }
            }
        }

        // Re-checked via `isProxyActive` rather than a captured flag: a failed restart
        // above will have put the proxy in `.failed` / `.stopped`, in which case probing
        // upstreams and overwriting `upstreamStatuses` is wasted work that also races the
        // just-cleared snapshot from `stopProxy()`.
        if diff.upstreamsChanged && isProxyActive {
            emitEvent(.config, "config.upstreams_refresh")
            _ = await refreshConnectivityMode()
            refreshUpstreamStatuses()
            logStore.log(.notice, "Config reload: upstream list updated.", category: .proxy)
        } else if diff.upstreamsChanged {
            emitEvent(.config, "config.upstreams_deferred", detail: "state=\(snapshot.runtimeStatus.state.rawValue)")
            logStore.log(
                .notice,
                "Config reload: upstream list changed, but proxy is not active (state=\(snapshot.runtimeStatus.state.rawValue)) — deferring connectivity refresh until next start.",
                category: .proxy
            )
        }

        onConfigChange?(config)
    }

    package func testUpstream(named name: String) async -> ProbeResult? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            emitEvent(.health, "upstream.test.invalid", detail: "reason=empty_name")
            return nil
        }
        guard var upstream = config.upstreams.first(where: {
            $0.name == trimmedName || $0.endpoint == trimmedName
        }) else {
            emitEvent(.health, "upstream.test.not_found", detail: "name=\(trimmedName)")
            return nil
        }
        upstream.enabled = true
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: logStore)
        guard let result = await prober.probeAll([upstream]).first else {
            emitEvent(.health, "upstream.test.probe_empty", detail: "name=\(upstream.name)")
            return nil
        }
        emitEvent(
            .health,
            "upstream.test",
            detail: "name=\(result.proxy.name) reachable=\(result.reachable) latencyMS=\(result.latencyMS)"
        )
        return result
    }

    private let configBox: ProxyConfigBox
    /// Factory for upstream-proxy authenticators. Injected by callers that link
    /// the `ProxyAuth` target (which owns the concrete NTLM / Negotiate impls);
    /// the kernel no longer references those types directly.
    ///
    /// When the caller does not provide one (most tests, `pm-sim`), we install
    /// a closure that throws `ProxyAuthenticatorNotConfiguredError` on first
    /// use — tests that never trip a 407 are unaffected.
    ///
    /// The factory lives at the caller rather than inside the orchestrator.
    /// Backing storage for the authenticator factory closure. Held in a
    /// small reference-typed holder (class + `NIOLock`) so writes via
    /// `setAuthenticatorProvider` are visible to every closure that
    /// captured the holder — mirrors the `configBox` pattern three
    /// declarations above. Callers do not read this property directly;
    /// they go through `lateBoundAuthenticatorProvider` below (or,
    /// equivalently, through the lazy-var-captured closures that
    /// consume it).
    ///
    /// **Why not `NIOLockedValueBox<@Sendable (String) -> ...>`?** The
    /// box's `(inout T) -> R` contract reabstracts the stored closure
    /// through `@in_guaranteed`/`@guaranteed` thunks on every body
    /// invocation and writes the re-thunked value back into the box.
    /// Each `lateBoundAuthenticatorProvider(host)` call therefore
    /// layered another `~4` stack frames onto the next call's stored
    /// factory — 500 CONNECT handshakes → 2000-frame stack overflow,
    /// observed as the `thunk for @escaping @Sendable (String) ->
    /// ProxyAuthenticator` recursion in the 2026-04-22 crash report.
    /// `AuthProviderHolder` below reads the factory into a local
    /// via simple class-field load (no inout), so there is no write-
    /// back and no thunk accumulation. See
    /// `AuthProviderStackDepthTests.testLateBoundProviderFrameCountIsBounded`
    /// for the regression guard.
    private let authenticatorHolder: AuthProviderHolder

    /// Late-bound authenticator accessor. Captured by the three lazy
    /// sub-objects (`localProxyServer`, `tunnelConnectionPool`,
    /// `tunnelCoordinator`); each invocation dereferences
    /// `authenticatorBox`, so `setAuthenticatorProvider` takes effect
    /// immediately — even after `startProxy()` / `startTunnels()` have
    /// triggered the lazy-var initialization. Resolves the pre-review
    /// footgun where a by-value capture pinned the init-time provider
    /// and later setter calls became silent no-ops.
    ///
    /// Exposed at `package` visibility so tests can verify the
    /// late-binding semantics without wiring a full 407 handshake.
    package let lateBoundAuthenticatorProvider: @Sendable (String) throws -> ProxyAuthenticator

    /// Replace the authenticator factory closure. Safe to call at any
    /// time — before or after `startProxy()` / `startTunnels()`. The
    /// three lazy sub-objects captured a box-dereferencing closure on
    /// first access; writes through this setter are observed by every
    /// subsequent invocation of those captors (one `os_unfair_lock`
    /// acquire per auth handshake, dwarfed by the handshake itself).
    package func setAuthenticatorProvider(_ provider: @escaping @Sendable (String) throws -> ProxyAuthenticator) {
        authenticatorHolder.set(provider)
    }
    private static let localPACListenHost = "127.0.0.1"
    private let privilegeClient: PrivilegeClient?
    private let healthChecker = HealthChecker()
    /// The orchestrator no longer constructs a concrete PAC
    /// resolver (which would live in `ProxyPAC`, forbidden here by the
    /// import fence). Callers that want PAC routing inject a
    /// `PacEvaluator`; otherwise `pacRoutingEngine` stays `nil` and the
    /// proxy runs with PAC disabled — consumers downstream
    /// (`HTTPProxyHandler`, `SOCKS5Server`, `LocalProxyServer`) already
    /// accept `pacRoutingEngine: PACRoutingEngine?`, so the nil branch
    /// is not new.
    private let pacEvaluator: (any PacEvaluator)?
    /// Tuple form `(isDirect, cause)` so the read-side closure consumed by
    /// HTTPProxyHandler / SOCKS5Server can branch on cause without a separate
    /// state lookup. Invariant: `isDirect == cause.isDirect`. Mutated only
    /// via `setDirectMode(_:)`.
    private let directModeBox = NIOLockedValueBox<(isDirect: Bool, cause: DirectModeCause)>((false, .none))
    /// Mirror of `snapshot.vpnState == .connected` for the DNS forwarder's
    /// `@Sendable` DoH transport preference (NIO handlers cannot read MainActor
    /// snapshot). Updated in `handleVPNStateChange`.
    private let vpnConnectedForDNSBox = NIOLockedValueBox(false)

    /// Phase 4: Timestamp of the most recent `.connected → .reasserting`
    /// transition. Used to compute flap duration for the `vpn.flap.recovered`
    /// event detail. Cleared when we leave the reasserting state (either by
    /// recovery or by the grace window expiring into `.disconnected`).
    ///
    /// Phase 6 (revised): rapid-flap coalescing moved to the fuser
    /// (`vpnFlapMinVisibleSeconds` debounce). The orchestrator no longer
    /// tracks `lastFlapRecoveredAt` / `reassertingSuppressed` — sub-window
    /// flaps simply don't reach this layer.
    private var flapStartedAt: Date?
    private var directModeReprobeTimer: DispatchSourceTimer?
    private var recentFailureTimestamps: [Date] = []
    private var errorRateReprobeScheduled = false

    private lazy var directConnectDetector: DirectConnectDetector = {
        DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: logStore,
            ttlSeconds: TimeInterval(configBox.current.directConnectTTLMinutes * 60),
            baseTimeoutMS: Int64(configBox.current.connectionCheckTimeoutMS)
        )
    }()

    private lazy var pacRoutingEngine: PACRoutingEngine? = {
        guard let pacEvaluator else { return nil }
        return PACRoutingEngine(
            configProvider: { [configBox] in configBox.current },
            resolver: pacEvaluator,
            logger: logStore
        )
    }()

    private lazy var dnsForwarder = LocalDNSForwarder(
        group: MultiThreadedEventLoopGroup.singleton,
        logger: logStore,
        configProvider: { [configBox] in configBox.current },
        preferProxyPathForDoH: { [vpnConnectedForDNSBox] in
            vpnConnectedForDNSBox.withLockedValue { $0 }
        },
        onMetrics: { [weak self] queries, dohFallbacks, cacheHits in
            Task { @MainActor in
                guard let s = self else { return }
                s.snapshot.dnsQueryCount = queries
                s.snapshot.dnsDoHFallbackCount = dohFallbacks
                s.snapshot.dnsCacheHitCount = cacheHits
                s.emitSnapshotCoalesced()
            }
        }
    )

    private lazy var localProxyServer = LocalProxyServer(
        logger: logStore,
        configProvider: { [configBox] in configBox.current },
        directModeProvider: { [directModeBox] in
            directModeBox.withLockedValue { ($0.isDirect, $0.cause) }
        },
        authenticatorProvider: lateBoundAuthenticatorProvider,
        directConnectDetector: directConnectDetector,
        pacRoutingEngine: pacRoutingEngine,
        onConnectionOpened: { [weak self] info in
            Task { @MainActor in
                guard let s = self else { return }
                s.snapshot.activeConnections.insert(info)
                s.snapshot.runtimeStatus.metrics.openConnections = s.snapshot.activeConnections.count
                s.emitSnapshotCoalesced()
            }
        },
        onConnectionClosed: { [weak self] id in
            Task { @MainActor in
                guard let s = self else { return }
                // Emit audit record BEFORE removal so the lookup against
                // `snapshot.activeConnections` finds the closing connection's
                // bytes/upstream/destination metadata. The sink itself is
                // safe to call regardless of state — discarding sink ignores
                // the call when audit is off.
                s.recordConnectionCloseForAudit(id: id)
                s.snapshot.activeConnections.remove(id: id)
                s.snapshot.runtimeStatus.metrics.openConnections = s.snapshot.activeConnections.count
                s.emitSnapshotCoalesced()
            }
        },
        onConnectionActivity: { [weak self] activity in
            Task { @MainActor in
                guard let s = self else { return }
                s.snapshot.activeConnections.update(id: activity.connectionID) { info in
                    info.applyActivity(activity)
                }
            }
        },
        onRequestCompleted: { [weak self] success, _ in
            Task { @MainActor in
                guard let s = self else { return }
                s.snapshot.runtimeStatus.metrics.requestsHandled += 1
                if !success {
                    s.snapshot.runtimeStatus.metrics.failedRequests += 1
                    s.snapshot.runtimeStatus.metrics.lastFailure = .now
                    s.refreshUpstreamStatuses()
                }
                s.emitSnapshotCoalesced()
                if !success {
                    s.trackFailureForErrorRate()
                }
            }
        },
        eventSink: { [eventLog] event in eventLog.append(event) }
    )

    private lazy var localPACServer = LocalPACServer(logger: logStore)

    private lazy var autoRecovery = AutoRecovery(service: localProxyServer, logger: logStore)

    private let tunnelAuthHandshakeLimiter = AuthHandshakeLimiter()

    private lazy var tunnelConnectionPool = ConnectionPool(
        group: MultiThreadedEventLoopGroup.singleton,
        logger: logStore,
        configProvider: { [configBox] in configBox.current },
        authenticatorProvider: lateBoundAuthenticatorProvider,
        authHandshakeLimiter: tunnelAuthHandshakeLimiter,
        eventSink: { [eventLog] event in eventLog.append(event) }
    )

    private lazy var tunnelCoordinator = CONNECTCoordinator(
        pool: tunnelConnectionPool,
        authenticatorProvider: lateBoundAuthenticatorProvider,
        logger: logStore,
        authHandshakeLimiter: tunnelAuthHandshakeLimiter,
        authLimitProvider: { [configBox] in
            let config = configBox.current
            return AuthHandshakeLimiter.Limits(
                total: config.pendingAuthHandshakeGlobalLimit,
                perSource: config.pendingAuthHandshakesPerSource
            )
        },
        eventSink: { [eventLog] event in eventLog.append(event) }
    )

    private let tunnelHealthProber = TunnelHealthProber()

    private lazy var tunnelForwarder = TunnelForwarder(
        group: MultiThreadedEventLoopGroup.singleton,
        connectCoordinator: tunnelCoordinator,
        connectionPool: tunnelConnectionPool,
        logger: logStore,
        resolverManager: resolverManager
    )

    private lazy var transparentProxy = TransparentTCPProxy(
        group: MultiThreadedEventLoopGroup.singleton,
        connectCoordinator: tunnelCoordinator,
        connectionPool: tunnelConnectionPool,
        logger: logStore,
        gatewayModeProvider: { [configBox] in configBox.current.gatewayMode }
    )

    private let resolverManager: (any TunnelResolverApplying)?

    package init(
        config: ProxyConfig,
        logger: any LogSink = DiscardingLogSink(),
        privilegeClient: PrivilegeClient? = nil,
        authenticatorProvider: (@Sendable (String) throws -> ProxyAuthenticator)? = nil,
        pacEvaluator: (any PacEvaluator)? = nil,
        auditSink: any ConnectionAuditSink = DiscardingConnectionAuditSink(),
        resolverManager: (any TunnelResolverApplying)? = nil
    ) {
        self.resolverManager = resolverManager
        self.auditSink = auditSink
        let configBox = ProxyConfigBox(config)
        self.configBox = configBox
        // Capture the box once at init for the snapshot-provider closure.
        // `[configBox]` keeps the closure self-contained; reading its
        // `current` property is one lock acquire and one struct copy.
        self.configSnapshotProvider = { [configBox] in configBox.current }
        self.logStore = logger
        self.privilegeClient = privilegeClient
        // See `authenticatorHolder` doc: a reference-type holder (class +
        // `NIOLock`) reads the factory into a local `let` for invocation,
        // which avoids `NIOLockedValueBox`'s inout copy-in/copy-out
        // reabstraction cycle — the root cause of the closure-stack leak
        // that produced the 2026-04-22 stack overflow.
        let holder = AuthProviderHolder(
            initial: authenticatorProvider ?? { _ in
                throw ProxyAuthenticatorNotConfiguredError()
            }
        )
        self.authenticatorHolder = holder
        self.lateBoundAuthenticatorProvider = { [holder] host in
            try holder.invoke(host)
        }
        // Nil means PAC routing is disabled on this orchestrator instance —
        // `pacRoutingEngine` will stay nil and downstream consumers see the
        // same "no PAC" branch they already handle today for users who left
        // `ProxyConfig.pacRoutingEnabled = false`.
        self.pacEvaluator = pacEvaluator
        self.snapshot = ProxyOrchestratorSnapshot()
        self.tunnelForwarder.sessionTracker.onChange = { [weak self] count in
            Task { @MainActor in
                guard let s = self else { return }
                s.snapshot.tunnelSessionCount = count
                s.emitSnapshotCoalesced()
            }
        }
    }

    package func startProxy() async throws {
        guard snapshot.runtimeStatus.state != .starting, snapshot.runtimeStatus.state != .running else { return }
        emitEvent(.lifecycle, "proxy.starting")

        mutateSnapshot {
            $0.runtimeStatus.state = .starting
            $0.proxyError = nil
        }

        do {
            let summary = await refreshConnectivityMode()
            await refreshPACRouting(force: true)

            try await localProxyServer.start()
            try await reconcileLocalPACServer(reason: "proxy_start")

            let directCause = snapshot.directModeCause
            mutateSnapshot {
                $0.bindings.proxyHost = self.localProxyServer.listeningHost
                $0.bindings.proxyPort = self.localProxyServer.listeningPort
                $0.bindings.socksHost = self.localProxyServer.socksListeningHost
                $0.bindings.socksPort = self.localProxyServer.socksListeningPort
                $0.bindings.localPACHost = self.localPACServer.listeningHost
                $0.bindings.localPACPort = self.localPACServer.listeningPort
                $0.upstreamStatuses = self.localProxyServer.upstreamStatuses()
                $0.runtimeStatus.metrics.inboundConnections = self.localProxyServer.inboundConnectionCount
                $0.runtimeStatus.state = .running
                $0.runtimeStatus.metrics.uptimeStartedAt = .now
                $0.runtimeStatus.activeUpstream = directCause.routesClientTrafficDirectly
                    ? "DIRECT"
                    : (summary.bestReachableUpstream?.endpoint ?? self.localProxyServer.activeUpstream())
                if directCause.isDirect {
                    $0.runtimeStatus.lastHealthSummary = directCause.healthSummary
                }
            }

            reconcileConnectivityMonitors(for: directCause)
        } catch {
            await localPACServer.stop()
            await localProxyServer.stop(scope: .all)
            mutateSnapshot {
                $0.runtimeStatus.state = .failed
                $0.proxyError = error.localizedDescription
                $0.bindings.proxyHost = nil
                $0.bindings.proxyPort = nil
                $0.bindings.socksHost = nil
                $0.bindings.socksPort = nil
                $0.bindings.localPACHost = nil
                $0.bindings.localPACPort = nil
            }
            logStore.log(.error, "Failed to start proxy: \(error.localizedDescription)", category: .proxy)
            throw error
        }
    }

    /// Stop the proxy listener.
    ///
    /// Default `scope: .all` matches the prior behavior — used for terminal teardown
    /// (process termination, user toggle-off, manual stop). Pass `.allButDedicated`
    /// from config-driven restart paths so in-flight HTTPS streams established through
    /// the old listener can outlive the listener swap. See `docs/design-vpn-flap-resilience.md`.
    package func stopProxy(scope: CloseScope = .all) async {
        emitEvent(.lifecycle, "proxy.stopping")
        healthChecker.stop()
        stopDirectModeReprobeTimer()
        await localPACServer.stop()
        await localProxyServer.stop(scope: scope)
        // Phase 4 telemetry: clear the per-flap-recovery state machine so the
        // next start-cycle doesn't compute a duration against a flap that
        // started before the listener went down.
        flapStartedAt = nil
        mutateSnapshot {
            // `ActiveConnectionStore` rebuilds its index map from the
            // filtered array — the rebuild is rare (only on stop/scope-flush
            // paths), and the alternative (in-place `removeAll(where:)` on
            // the store) would tangle the policy filter into the storage
            // type rather than keeping it as the testable static helper.
            let preserved = Self.preservedActiveConnections(from: $0.activeConnections.ordered, scope: scope)
            $0.activeConnections = ActiveConnectionStore(preserved)
            $0.upstreamStatuses.removeAll()
            $0.runtimeStatus.metrics.openConnections = $0.activeConnections.count
            $0.runtimeStatus.metrics.inboundConnections = 0
            // Phase 7: cumulative flap telemetry resets on stop. The design doc
            // (Phase 7 "Telemetry strip") and MainView's `showsFlapTelemetryStrip`
            // comment both promise that the strip is hidden when the proxy is
            // stopped because the counters have been reset — without this reset
            // the strip would reappear on the next start showing carry-over from
            // a previous start-cycle, lying about activity in the new cycle.
            $0.runtimeStatus.metrics.vpnFlapCount = 0
            $0.runtimeStatus.metrics.vpnFlapTotalDuration = 0
            $0.runtimeStatus.metrics.lastVpnFlapAt = nil
            $0.runtimeStatus.metrics.streamsPreservedAcrossFlaps = 0
            // Same rationale as the VPN-flap reset above: the runtime auth
            // outcome (consumed by `MainView.authBadge`) describes "what
            // the last handshake actually did". On stop there is no last
            // handshake any more, and on the next start the UI must not
            // carry forward the previous cycle's outcome until a fresh
            // handshake fires. Without this reset, a stop→start cycle
            // would briefly display e.g. "Kerberos → NTLM" from the prior
            // session, violating AGENTS.md's "always derive observability
            // from `ProxyOrchestratorSnapshot`" rule.
            $0.lastAuthOutcome = nil
            $0.lastAuthOutcomeAt = nil
            $0.lastAuthFallbackReason = nil
            $0.runtimeStatus.state = .stopped
            $0.runtimeStatus.activeUpstream = nil
            $0.runtimeStatus.lastHealthSummary = "Stopped"
            $0.proxyError = nil
            $0.bindings.proxyHost = nil
            $0.bindings.proxyPort = nil
            $0.bindings.socksHost = nil
            $0.bindings.socksPort = nil
            $0.bindings.localPACHost = nil
            $0.bindings.localPACPort = nil
        }
    }

    /// Pure filter exposed for unit testing: decide which `activeConnections`
    /// entries survive a `stopProxy(scope:)` call. Mirrors the static helper
    /// pattern on `ConnectionPool.connectionIDsToClose(from:scope:)` so the
    /// policy can be locked down without standing up a live orchestrator.
    ///
    /// Policy:
    /// - `.all` / `.idleOnly`: clear the UI snapshot entirely. `.all` is
    ///   terminal teardown (everything closes); `.idleOnly` isn't currently
    ///   used by `stopProxy` but, if it ever is, preserving in-flight entries
    ///   would require a different API surface than `ActiveConnectionInfo`
    ///   carries today — so we keep the conservative "clear" behavior.
    /// - `.allButDedicated`: retain entries with `tunnel == true`. Those
    ///   correspond to long-lived CONNECT/SOCKS tunnels whose accepted child
    ///   channels survive the server-channel close (per SwiftNIO's
    ///   `ServerSocketChannel` lifecycle contract: closing the server stops
    ///   accepting new connections but does not force accepted child channels
    ///   closed) and whose upstream connections are preserved by the pool's
    ///   matching `CloseScope.allButDedicated` filter. Non-tunnel entries
    ///   (in-flight HTTP exchanges) are backed by pool connections that DO
    ///   get closed here; their `onConnectionClosed` callbacks fire promptly
    ///   on the channel-inactive path and remove them by `id` against this
    ///   same snapshot array — so dropping them synchronously here is the
    ///   honest representation.
    ///
    /// Callbacks for preserved entries that close later remain correct: the
    /// orchestrator's `onConnectionClosed` closure does an O(1) lookup via
    /// `ActiveConnectionStore.remove(id:)` against the same persistent
    /// `snapshot.activeConnections` store and either removes on match
    /// (normal case) or no-ops on miss (tolerant to the `.all` terminal
    /// path). The snapshot store identity is stable across stop/start
    /// because `localProxyServer` is a `lazy var` and the `[weak self]`
    /// capture resolves back to this same orchestrator instance.
    package static func preservedActiveConnections(
        from connections: [ActiveConnectionInfo],
        scope: CloseScope
    ) -> [ActiveConnectionInfo] {
        switch scope {
        case .allButDedicated:
            return connections.filter { $0.tunnel }
        case .all, .idleOnly:
            return []
        }
    }

    package func startDNS() async {
        guard snapshot.dnsRunState != .starting else { return }

        mutateSnapshot {
            $0.dnsRunState = .starting
            $0.dnsError = nil
        }
        let currentConfig = config

        do {
            try await dnsForwarder.start(host: currentConfig.localHost, port: currentConfig.dnsForwarderPort)
            mutateSnapshot {
                $0.dnsRunState = .running
                $0.bindings.dnsHost = self.dnsForwarder.listeningHost
                $0.bindings.dnsPort = self.dnsForwarder.listeningPort
            }

            if currentConfig.transparentProxyEnabled, !currentConfig.enabledInterceptRules.isEmpty {
                await startTransparentProxy(config: currentConfig)
            }
        } catch {
            let message = error.displayDescription
            logStore.log(.warning, "Could not start DNS forwarder on \(currentConfig.localHost):\(currentConfig.dnsForwarderPort): \(message)", category: .network)
            mutateSnapshot {
                $0.dnsRunState = .failed
                $0.bindings.dnsHost = nil
                $0.bindings.dnsPort = nil
                $0.dnsError = message
            }
        }
    }

    package func stopDNS() async {
        await stopTransparentProxy()
        await dnsForwarder.stop()
        mutateSnapshot {
            $0.dnsRunState = .stopped
            $0.dnsQueryCount = 0
            $0.dnsDoHFallbackCount = 0
            $0.dnsCacheHitCount = 0
            $0.dnsError = nil
            $0.bindings.dnsHost = nil
            $0.bindings.dnsPort = nil
        }
    }

    package func startTunnels() async {
        let currentConfig = config
        let activeTunnels = currentConfig.tunnelDefinitions.filter(\.enabled)
        guard !activeTunnels.isEmpty else {
            mutateSnapshot {
                $0.tunnelsError = "No tunnel definitions are enabled."
                $0.tunnelsRunState = .failed
                $0.tunnelActiveCount = 0
                $0.tunnelSessionCount = 0
                $0.tunnelDNSOverrideStatus = .notNeeded
                $0.bindings.tunnels = []
            }
            return
        }

        let reservedPorts = Self.reservedTunnelPorts(in: currentConfig)
        let validationErrors = Self.validateTunnelDefinitions(activeTunnels, reservedPorts: reservedPorts)
        if !validationErrors.isEmpty {
            for message in validationErrors {
                logStore.log(.error, message, category: .tunnel)
            }
            mutateSnapshot {
                $0.tunnelsError = validationErrors.joined(separator: " ")
                $0.tunnelsRunState = .failed
                $0.tunnelActiveCount = 0
                $0.tunnelSessionCount = 0
                $0.tunnelDNSOverrideStatus = .notNeeded
                $0.bindings.tunnels = []
            }
            return
        }

        mutateSnapshot {
            $0.tunnelsRunState = .starting
            $0.tunnelsError = nil
        }

        if currentConfig.gatewayMode && currentConfig.localHost != currentConfig.effectiveTunnelListenHost {
            logStore.log(
                .notice,
                "Gateway mode is active — proxy listens on \(currentConfig.effectiveListenHost) but tunnel listeners remain on \(currentConfig.effectiveTunnelListenHost).",
                category: .tunnel
            )
        }

        tunnelForwarder.updateLimits(
            maxGlobal: currentConfig.maxTunnelSessions,
            maxPerTunnel: currentConfig.maxSessionsPerTunnel
        )

        let result = await tunnelForwarder.start(
            tunnels: activeTunnels,
            listenHost: currentConfig.effectiveTunnelListenHost
        )

        if result.started == 0 {
            await tunnelForwarder.stop()
            tunnelConnectionPool.closeAll()
            mutateSnapshot {
                $0.tunnelsRunState = .failed
                $0.tunnelsError = "All tunnel listeners failed to bind."
                $0.tunnelActiveCount = 0
                $0.tunnelSessionCount = 0
                $0.tunnelDNSOverrideStatus = .notNeeded
                $0.bindings.tunnels = []
            }
        } else {
            mutateSnapshot {
                $0.tunnelDNSOverrideStatus = result.dnsOverrideStatus
                $0.bindings.tunnels = result.bindings
                $0.tunnelSessionCount = self.tunnelForwarder.sessionTracker.totalActiveSessions
                $0.tunnelsRunState = .running
                $0.tunnelActiveCount = result.started
                if result.failed > 0 {
                    $0.tunnelsError = "\(result.failed) tunnel(s) failed to bind — check logs."
                }
            }
        }

        logStore.log(.notice, "Protocol tunnels started: \(result.started) active, \(result.failed) failed.", category: .tunnel)

        if result.started > 0 {
            startTunnelHealthProbing()
        }
    }

    private func startTunnelHealthProbing() {
        // Capture probe targets keyed by the binding's stable id (sourced from
        // `TunnelDefinition.id`). Matching health results back to bindings by id is unambiguous
        // even when two tunnels share an effective label (possible with duplicate user-defined
        // labels or identical auto-generated `port→host:port` labels).
        let probeTargets = snapshot.bindings.tunnels.map { b in
            (id: b.id, host: b.localHost, port: b.localPort)
        }

        tunnelHealthProber.start(
            interval: 30,
            tunnels: { probeTargets },
            onResult: { [weak self] results in
                Task { @MainActor in
                    guard let s = self else { return }

                    // Collect the per-binding health deltas first, then commit them atomically
                    // inside a single `mutateSnapshot` that also derives the run-state
                    // transition from the post-update state. This guarantees exactly one
                    // `onSnapshotChange` fires per probe cycle: the earlier code mutated
                    // bindings in-place outside `mutateSnapshot`, then called `mutateSnapshot`
                    // (one emission) AND `onSnapshotChange` again (a second, redundant
                    // emission). That double-fire inflated the NDJSON status stream and any
                    // observer that counts emissions.
                    var pending: [(index: Int, healthy: Bool)] = []
                    for i in s.snapshot.bindings.tunnels.indices {
                        let bindingID = s.snapshot.bindings.tunnels[i].id
                        if let healthy = results[bindingID],
                           s.snapshot.bindings.tunnels[i].healthy != healthy {
                            pending.append((i, healthy))
                        }
                    }
                    guard !pending.isEmpty else { return }

                    s.mutateSnapshot { snap in
                        for update in pending {
                            snap.bindings.tunnels[update.index].healthy = update.healthy
                        }
                        let anyDegraded = snap.bindings.tunnels.contains { !$0.healthy }
                        if anyDegraded && snap.tunnelsRunState == .running {
                            snap.tunnelsRunState = .warning
                        } else if !anyDegraded && snap.tunnelsRunState == .warning {
                            snap.tunnelsRunState = .running
                        }
                    }
                }
            }
        )
    }

    package func reconcileTunnels() async {
        let currentConfig = config

        // Mirror the boundary-validation that `startTunnels()` runs (empty remote host,
        // out-of-range port, reserved-port collision, duplicate local port). Without this,
        // an invalid hot-reload edit reached `tunnelForwarder.reconcile()` and surfaced as
        // a per-binding bind failure (or worse, silently shadowed another module's port).
        //
        // Unlike `startTunnels()` we do NOT zero the snapshot or flip `tunnelsRunState` to
        // `.failed` on rejection — the currently-bound listeners are still serving traffic
        // and would diverge from the snapshot. Instead, abort the reconcile, surface the
        // validation errors via `tunnelsError` + a structured event, and leave the
        // already-running bindings in place so an unrelated typo in the config can't tear
        // down healthy tunnels.
        let activeDefinitions = currentConfig.tunnelDefinitions.filter(\.enabled)
        let reservedPorts = Self.reservedTunnelPorts(in: currentConfig)
        let validationErrors = Self.validateTunnelDefinitions(activeDefinitions, reservedPorts: reservedPorts)
        if !validationErrors.isEmpty {
            for message in validationErrors {
                logStore.log(.error, message, category: .tunnel)
            }
            emitEvent(
                .config,
                "config.tunnels_reconcile_rejected",
                detail: "\(validationErrors.count) validation error(s); existing bindings preserved"
            )
            mutateSnapshot {
                $0.tunnelsError = "Tunnel reload rejected: " + validationErrors.joined(separator: " ")
            }
            return
        }

        tunnelForwarder.updateLimits(
            maxGlobal: currentConfig.maxTunnelSessions,
            maxPerTunnel: currentConfig.maxSessionsPerTunnel
        )
        let result = await tunnelForwarder.reconcile(
            newDefinitions: currentConfig.tunnelDefinitions,
            listenHost: currentConfig.effectiveTunnelListenHost
        )
        mutateSnapshot {
            $0.tunnelDNSOverrideStatus = result.dnsOverrideStatus
            // Merge per-binding health from the previous snapshot so a reconcile doesn't
            // silently flip every binding back to `healthy: true` (the default on the rebuilt
            // `TunnelBindingInfo`) until the next probe cycle — otherwise a hot-reload opens
            // a false-OK window up to one probe interval wide.
            let previousHealthy = Dictionary(
                uniqueKeysWithValues: $0.bindings.tunnels.map { ($0.id, $0.healthy) }
            )
            $0.bindings.tunnels = result.bindings.map { binding in
                var merged = binding
                merged.healthy = previousHealthy[binding.id] ?? true
                return merged
            }
            $0.tunnelSessionCount = self.tunnelForwarder.sessionTracker.totalActiveSessions
            $0.tunnelActiveCount = result.started
            // Derive run state from the preserved-healthy set so `.warning` survives a reload
            // instead of being unconditionally overwritten with `.running`.
            if result.started == 0 {
                $0.tunnelsRunState = .stopped
            } else if $0.bindings.tunnels.contains(where: { !$0.healthy }) {
                $0.tunnelsRunState = .warning
            } else {
                $0.tunnelsRunState = .running
            }
            $0.tunnelsError = result.failed > 0 ? "\(result.failed) tunnel(s) failed — check logs." : nil
        }
        logStore.log(.notice, "Tunnel reconciliation: \(result.started) active, \(result.failed) failed.", category: .tunnel)

        // Re-snapshot the prober targets against the reconciled binding set.
        // `startTunnelHealthProbing` captures `bindings` at call time, so without this
        // the prober would keep probing the pre-reconciliation target list and miss
        // any tunnels that were added, removed, or re-bound.
        tunnelHealthProber.stop()
        if result.started > 0 {
            startTunnelHealthProbing()
        }
    }

    package func stopTunnels() async {
        tunnelHealthProber.stop()
        await tunnelForwarder.stop()
        tunnelConnectionPool.closeAll()
        mutateSnapshot {
            $0.tunnelsRunState = .stopped
            $0.tunnelActiveCount = 0
            $0.tunnelSessionCount = 0
            $0.tunnelsError = nil
            $0.tunnelDNSOverrideStatus = .notNeeded
            $0.bindings.tunnels = []
        }
        logStore.log(.notice, "Protocol tunnels stopped.", category: .tunnel)
    }

    package func refreshPACRouting(force: Bool = false) async {
        guard let pacRoutingEngine else { return }
        do {
            try await pacRoutingEngine.refresh(force: force)
        } catch {
            logStore.log(.warning, "Could not refresh PAC routing (non-fatal): \(error.localizedDescription)", category: .pac)
        }
    }

    package func handleSystemWake() async {
        logStore.log(.notice, "System woke from sleep — refreshing PAC and re-probing upstreams.", category: .network)
        directConnectDetector.clearCache()
        // Recycle the DNS forwarder's DoH `URLSession`s before anything else
        // touches the network. Their TCP connection pool and host-resolution
        // cache survive system sleep, and on a VPN-while-asleep wake they get
        // pinned to the now-defunct utun route — every subsequent DoH lookup
        // hits `timeoutIntervalForRequest` and the user sees
        // ERR_NAME_NOT_RESOLVED for every internet hostname. macOS does
        // eventually invalidate them on a real VPN reconnect, but plain wake
        // doesn't always trigger that path; this makes recovery deterministic
        // regardless of how the OS feels about emitting a network-change
        // notification on this particular wake.
        resetDNSTransportsForRecovery(source: "system_wake")
        // Wake is the one Tier-C-shaped event where we DO want a probe in
        // addition to the PAC refresh: sleep can hide network changes that
        // wouldn't fire NWPathMonitor or our SCDynamicStore observer (e.g.
        // the upstream rotated DNS while we were asleep). Tier B will catch
        // any utun changes independently; this probe covers the upstream side.
        await refreshPACRouting(force: true)
        let summary = await refreshConnectivityMode()
        guard isProxyActive else { return }
        let cause = snapshot.directModeCause
        if cause.isDirect {
            if cause == .transientNetworkChange, summary.hasReachableUpstream {
                recoverStaleReassertingAfterWake(summary: summary)
                return
            }
            mutateSnapshot {
                $0.runtimeStatus.lastHealthSummary = cause.healthSummary
                if cause.routesClientTrafficDirectly {
                    $0.runtimeStatus.activeUpstream = "DIRECT"
                } else {
                    $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                }
            }
            reconcileConnectivityMonitors(for: cause)
        } else {
            resumeNormalRoutingIfReachable(summary: summary)
        }
    }

    /// Recycle the DNS forwarder's DoH transports and emit a structured event.
    /// Single funnel for both wake- and VPN-recovery-driven session resets so
    /// the event surface is uniform and the call sites stay one-liners. Safe
    /// to call when the forwarder is stopped (the forwarder itself no-ops in
    /// that case). The event uses `.health` kind because the DoH transports
    /// are upstream services whose reachability is being restored — same
    /// semantic family as the upstream-proxy probes that drive direct-mode
    /// transitions. Detail string is kept compact (`source=<reason>`) so log
    /// pipelines and `pmctl` can group on it without parsing prose.
    private func resetDNSTransportsForRecovery(source: String) {
        dnsForwarder.resetUpstreamTransports(reason: source)
        emitEvent(.health, "dns.transports_reset", detail: "source=\(source)")
    }

    private func recoverStaleReassertingAfterWake(summary: UpstreamProbeSummary) {
        let activeTunnels = snapshot.activeConnections.ordered.filter { $0.tunnel }.count
        let recoveredAt = Date()
        let durationSeconds = flapStartedAt.map { recoveredAt.timeIntervalSince($0) } ?? 0
        let durationMS = Int(durationSeconds * 1_000)

        mutateSnapshot { $0.vpnState = .connected }
        flapStartedAt = nil
        localProxyServer.resetCircuitsAfterFlap()
        setDirectMode(deriveDirectModeCause(probeSummary: summary))
        resumeNormalRoutingIfReachable(summary: summary)
        mutateSnapshot {
            $0.runtimeStatus.metrics.vpnFlapCount += 1
            $0.runtimeStatus.metrics.vpnFlapTotalDuration += durationSeconds
            $0.runtimeStatus.metrics.lastVpnFlapAt = recoveredAt
            $0.runtimeStatus.metrics.streamsPreservedAcrossFlaps += activeTunnels
        }
        emitEvent(.vpn, "vpn.flap.recovered",
                  detail: "duration=\(durationMS)ms streamsPreserved=\(activeTunnels) source=system_wake")
        logStore.log(.notice,
                     "VPN flap recovered after system wake — upstream reachable; \(activeTunnels) active tunnel(s) preserved.",
                     category: .network)
    }

    /// Phase 4 transition table for `VPNObservedState`. Implements the design-doc
    /// invariants:
    ///
    /// * `.reasserting` → silent grace state. Stop health checker, set cause
    ///   `.transientNetworkChange`. **Do not** close any pool channel. **Do
    ///   not** reprobe upstreams. Active streams ride out the flap via TCP
    ///   keepalive — see AGENTS.md NEVER rule.
    /// * `.reasserting → .connected` → flap recovered. Reset breakers,
    ///   reprobe once, resume health checks. Emit `vpn.flap.recovered` with
    ///   duration + active-tunnel count preserved.
    /// * `* → .disconnected(.userInitiated)` → user clicked Disconnect.
    ///   Set cause `.vpnDisconnected` immediately, slow reprobe cadence (60 s).
    /// * `* → .disconnected(.networkLost)` → grace expired. Same as above but
    ///   logged at `.warning`.
    /// * `* → .disconnected(.unknown)` → tier-C-only fallback. Treat as
    ///   `.networkLost` for now.
    /// * `.disconnected → .connected` → VPN came back from a real outage.
    ///   Reset breakers, full reprobe, exit direct mode if any upstream reachable.
    package func handleVPNStateChange(_ state: VPNObservedState) async {
        let previous = snapshot.vpnState
        guard previous != state else { return }

        vpnConnectedForDNSBox.withLockedValue { $0 = state == .connected }
        mutateSnapshot { $0.vpnState = state }

        // Reactions are skipped while the proxy listener is stopped — there's
        // nothing to react WITH. The UI snapshot still mirrors the state above.
        guard isProxyActive else { return }

        switch state {

        case .reasserting:
            // Phase 6 (revised): if we reach .reasserting at all, the underlying
            // utun has been inactive for >= vpnFlapMinVisibleSeconds — sub-window
            // blips never get here (the fuser absorbs them silently). So no
            // coalesce/suppression logic at this layer.

            // Silent grace window. Active streams stay alive — that's the whole
            // point. The kernel preserves TCP across the underlying network
            // change; our control plane just needs to not panic.
            flapStartedAt = Date()
            healthChecker.stop()
            stopDirectModeReprobeTimer()
            // Direct-mode transition without a probe. The cause derivation below
            // will return .transientNetworkChange because snapshot.vpnState was
            // already set above.
            setDirectMode(deriveDirectModeCause(probeSummary: nil))
            mutateSnapshot {
                $0.runtimeStatus.lastHealthSummary = DirectModeCause.transientNetworkChange.healthSummary
            }
            // Note: NO startDirectModeReprobeTimer here. We're not in a
            // "find an upstream" loop — we're waiting for the underlying
            // network to recover. Either the VPN observer fires .connected
            // (recovery handled below) or the grace expires into .networkLost.
            emitEvent(.vpn, "vpn.flap.start")
            logStore.log(.notice, "VPN flap detected — preserving active streams, holding routing decisions.", category: .network)

        case .connected:
            // Recovery path. Two flavors based on what state we came from:
            //   .reasserting → .connected: flap recovered. Hot path; reset
            //                              breakers, reprobe once for sanity.
            //   .disconnected → .connected: real outage ended. Same actions
            //                              but log differently.
            //   .unknown → .connected: cold start (observer just primed);
            //                          run a normal probe + state update.
            let activeTunnels = snapshot.activeConnections.ordered.filter { $0.tunnel }.count
            switch previous {
            case .reasserting:
                // Phase 6 (revised): every .reasserting -> .connected we see
                // here is a real (super-min-visible) flap recovery; the fuser
                // already absorbed sub-window blips. No suppression needed.
                let recoveredAt = Date()
                let durationSeconds = flapStartedAt.map { recoveredAt.timeIntervalSince($0) } ?? 0
                let durationMS = Int(durationSeconds * 1_000)
                flapStartedAt = nil
                localProxyServer.resetCircuitsAfterFlap()
                // Recycle the DNS forwarder's DoH sessions: a real flap
                // re-routes the underlying utun, and any in-flight DoH TCP
                // connections were pinned to the old route. Without this,
                // the next post-flap DoH lookup either hangs to timeout or
                // resolves stale; corporate-DNS resolution (per-query UDP
                // sockets) is fine on its own. Mirrors the system-wake reset.
                resetDNSTransportsForRecovery(source: "vpn_flap_recovered")
                let summary = await refreshConnectivityMode()
                setDirectMode(deriveDirectModeCause(probeSummary: summary))
                resumeNormalRoutingIfReachable(summary: summary)
                // Phase 7: telemetry update. Only super-min-visible flaps reach
                // this branch (the fuser absorbs sub-window blips), so every
                // increment here corresponds to a user-visible flap event —
                // matching the strip's "Flaps N" / "Preserved N" semantics.
                mutateSnapshot {
                    $0.runtimeStatus.metrics.vpnFlapCount += 1
                    $0.runtimeStatus.metrics.vpnFlapTotalDuration += durationSeconds
                    $0.runtimeStatus.metrics.lastVpnFlapAt = recoveredAt
                    $0.runtimeStatus.metrics.streamsPreservedAcrossFlaps += activeTunnels
                }
                emitEvent(.vpn, "vpn.flap.recovered",
                          detail: "duration=\(durationMS)ms streamsPreserved=\(activeTunnels)")
                logStore.log(.notice,
                             "VPN flap recovered after \(durationMS) ms — \(activeTunnels) active tunnel(s) preserved.",
                             category: .network)
            case .disconnected:
                localProxyServer.resetCircuitsAfterFlap()
                // Real-outage recovery: the VPN was fully down and is now
                // back. Same DoH-transport recycle as the flap path —
                // belt-and-suspenders against macOS not always invalidating
                // URLSession's connection pool on the reconnect.
                resetDNSTransportsForRecovery(source: "vpn_reconnected")
                let summary = await refreshConnectivityMode()
                setDirectMode(deriveDirectModeCause(probeSummary: summary))
                resumeNormalRoutingIfReachable(summary: summary)
                emitEvent(.vpn, "vpn.connected")
                logStore.log(.notice, "VPN reconnected — re-probing upstreams.", category: .network)
            case .unknown, .connected:
                // Cold start or VPN observer priming to .connected. Recycle DoH
                // transports when the forwarder is running so a connect-while-app-
                // is-up (or post-start VPN attach) does not reuse stale utun-pinned
                // URLSession pools.
                if snapshot.dnsRunState == .running {
                    resetDNSTransportsForRecovery(source: "vpn_connected")
                }
                let summary = await refreshConnectivityMode()
                setDirectMode(deriveDirectModeCause(probeSummary: summary))
                resumeNormalRoutingIfReachable(summary: summary)
                emitEvent(.vpn, "vpn.connected")
            }

        case .disconnected(let reason):
            // Definitive VPN disconnect, but not necessarily "off corporate
            // network": on-prem users have no VPN utun while the upstream proxy
            // is still reachable. Run the lightweight proxy-semantic probe
            // (CONNECT without credentials) before deciding whether to force
            // DIRECT.
            flapStartedAt = nil
            healthChecker.stop()
            let summary = await refreshConnectivityMode()
            let cause = snapshot.directModeCause
            mutateSnapshot {
                if cause.routesClientTrafficDirectly {
                    $0.runtimeStatus.lastHealthSummary = cause.healthSummary
                    $0.runtimeStatus.activeUpstream = "DIRECT"
                } else {
                    $0.runtimeStatus.lastHealthSummary = summary.bestReachableUpstream.map {
                        "Healthy via \($0.endpoint)"
                    } ?? $0.runtimeStatus.lastHealthSummary
                    $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                    $0.runtimeStatus.state = .running
                }
            }
            reconcileConnectivityMonitors(for: cause)
            switch reason {
            case .userInitiated:
                emitEvent(.vpn, "vpn.disconnected.user")
                if cause.routesClientTrafficDirectly {
                    logStore.log(.notice, "VPN disconnected (user-initiated) — direct mode active.", category: .network)
                } else {
                    logStore.log(.notice, "VPN disconnected (user-initiated) — upstream proxy still reachable; proxy routing remains active.", category: .network)
                }
            case .networkLost:
                emitEvent(.vpn, "vpn.disconnected.lost")
                if cause.routesClientTrafficDirectly {
                    logStore.log(.warning, "VPN disconnected (network lost) — direct mode active.", category: .network)
                } else {
                    logStore.log(.notice, "VPN disconnected (network lost) — upstream proxy still reachable; proxy routing remains active.", category: .network)
                }
            case .unknown:
                emitEvent(.vpn, "vpn.disconnected.lost", detail: "tier-C fallback")
                if cause.routesClientTrafficDirectly {
                    logStore.log(.warning, "VPN unreachable (no Tier B signal) — direct mode active.", category: .network)
                } else {
                    logStore.log(.notice, "VPN unreachable (no Tier B signal) — upstream proxy still reachable; proxy routing remains active.", category: .network)
                }
            }

        case .unknown:
            // Cold-state regression. Don't take action — wait for the next
            // definitive transition. (This mostly happens at startup before
            // the observer primes.)
            break
        }
    }

    /// Helper for VPN-recovery transitions: if the post-recovery probe found
    /// any reachable upstream, transition the runtime status back to .running
    /// and resume the health-check loop.
    private func resumeNormalRoutingIfReachable(summary: UpstreamProbeSummary) {
        guard summary.hasReachableUpstream else { return }
        stopDirectModeReprobeTimer()
        mutateSnapshot {
            $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
            if $0.runtimeStatus.state != .running {
                $0.runtimeStatus.state = .running
            }
        }
        startHealthLoop()
    }

    /// Tier C network-change reaction: refresh PAC, log the new path. Does NOT
    /// re-probe upstreams or flip direct mode — those are Tier B's
    /// (`handleVPNStateChange`) responsibility now. Splitting general network
    /// events from VPN events eliminates the historical per-`NWPathMonitor`-event
    /// upstream-reprobe storm (Wi-Fi roams, IPv6 RAs, captive-portal checks all
    /// triggered redundant 3-second probe cycles). See `docs/design-vpn-flap-resilience.md`.
    package func handleNetworkChange(description: String) async {
        logStore.log(.info, "Network changed: \(description)", category: .network)
        if snapshot.dnsRunState == .running {
            resetDNSTransportsForRecovery(source: "network_change")
        }
        await refreshPACRouting(force: true)
    }

    package func performTerminationCleanup() {
        healthChecker.stop()
        stopDirectModeReprobeTimer()
        stopSnapshotCoalesceTimer()
        tunnelHealthProber.stop()
        stopTCPRelay()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transparentProxy.stop()
            await self.dnsForwarder.stop()
            await self.tunnelForwarder.stop()
            self.tunnelConnectionPool.closeAll()
            await self.localProxyServer.stop()
            self.mutateSnapshot {
                $0.activeConnections.removeAll()
                $0.upstreamStatuses.removeAll()
                $0.runtimeStatus.state = .stopped
                $0.runtimeStatus.activeUpstream = nil
                $0.runtimeStatus.lastHealthSummary = "Stopped"
                $0.runtimeStatus.metrics.openConnections = 0
                $0.runtimeStatus.metrics.inboundConnections = 0
                $0.dnsRunState = .stopped
                $0.dnsQueryCount = 0
                $0.dnsDoHFallbackCount = 0
                $0.dnsCacheHitCount = 0
                $0.tunnelsRunState = .stopped
                $0.tunnelActiveCount = 0
                $0.tunnelSessionCount = 0
                $0.tunnelsError = nil
                $0.tunnelDNSOverrideStatus = .notNeeded
                $0.bindings = .init()
            }
        }
    }

    private func startHealthLoop() {
        guard snapshot.directModeCause.runsUpstreamHealthLoop else { return }
        healthChecker.start(interval: config.healthCheckIntervalSeconds) { [weak self] in
            guard let self else {
                return HealthCheckResult(healthy: false, summary: "ProxyOrchestrator deallocated", activeUpstream: nil, responseTimeMS: 0)
            }
            return await self.localProxyServer.performHealthCheck()
        } onResult: { [weak self] result in
            Task { @MainActor in
                self?.applyHealthCheckResult(result)
            }
        }
    }

    private func applyHealthCheckResult(_ result: HealthCheckResult) {
        guard snapshot.directModeCause.runsUpstreamHealthLoop else {
            let cause = snapshot.directModeCause
            mutateSnapshot {
                $0.runtimeStatus.state = .running
                $0.runtimeStatus.lastHealthSummary = cause.healthSummary
                if cause.routesClientTrafficDirectly {
                    $0.runtimeStatus.activeUpstream = "DIRECT"
                }
            }
            return
        }

        if result.healthy {
            mutateSnapshot {
                $0.runtimeStatus.lastHealthSummary = "\(result.summary) (\(result.responseTimeMS) ms)"
                $0.runtimeStatus.activeUpstream = result.activeUpstream ?? $0.runtimeStatus.activeUpstream
                if $0.runtimeStatus.state == .degraded || $0.runtimeStatus.state == .recovering {
                    $0.runtimeStatus.metrics.successfulRecoveries += 1
                }
                $0.runtimeStatus.state = .running
            }
            refreshUpstreamStatuses()
            return
        }

        mutateSnapshot {
            $0.runtimeStatus.lastHealthSummary = "\(result.summary) (\(result.responseTimeMS) ms)"
            $0.runtimeStatus.activeUpstream = result.activeUpstream ?? $0.runtimeStatus.activeUpstream
            $0.runtimeStatus.state = .degraded
        }
        refreshUpstreamStatuses()

        Task { @MainActor in
            self.mutateSnapshot { $0.runtimeStatus.state = .recovering }
            let recovered = await self.autoRecovery.recover()
            if recovered {
                self.mutateSnapshot {
                    $0.runtimeStatus.state = .running
                    $0.proxyError = nil
                }
                self.onEvent?(.proxyRecovered(activeUpstream: self.snapshot.runtimeStatus.activeUpstream))
            } else {
                let connSummary = await self.refreshConnectivityMode()
                if self.snapshot.directModeCause.isDirect {
                    let cause = self.snapshot.directModeCause
                    self.mutateSnapshot {
                        $0.runtimeStatus.state = cause.routesClientTrafficDirectly ? .running : .degraded
                        $0.runtimeStatus.lastHealthSummary = cause.healthSummary
                        if cause.routesClientTrafficDirectly {
                            $0.runtimeStatus.activeUpstream = "DIRECT"
                        } else {
                            $0.runtimeStatus.activeUpstream = connSummary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                        }
                    }
                    self.reconcileConnectivityMonitors(for: cause)
                    return
                } else if connSummary.hasReachableUpstream {
                    self.mutateSnapshot {
                        $0.runtimeStatus.activeUpstream = connSummary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                        $0.runtimeStatus.state = .running
                    }
                    self.startHealthLoop()
                    return
                }
                let summary = self.snapshot.runtimeStatus.lastHealthSummary
                let authenticationLikely = summary.localizedCaseInsensitiveContains("authentication")
                    || summary.localizedCaseInsensitiveContains("rejected")
                self.mutateSnapshot {
                    $0.runtimeStatus.state = .failed
                    if authenticationLikely {
                        $0.proxyError = "Authentication rejected — your password may have changed. Re-enter it in Settings."
                    }
                }
                self.onEvent?(.proxyRecoveryFailed(summary: summary, authenticationLikely: authenticationLikely))
            }
            self.refreshUpstreamStatuses()
        }
    }

    private func reconcileConnectivityMonitors(for cause: DirectModeCause) {
        if cause.runsUpstreamHealthLoop {
            startHealthLoop()
        } else {
            healthChecker.stop()
        }

        if cause.usesDirectReprobeTimer {
            startDirectModeReprobeTimer()
        } else {
            stopDirectModeReprobeTimer()
        }
    }

    private func refreshConnectivityMode() async -> UpstreamProbeSummary {
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: logStore)
        let summary = await prober.summarize(config.upstreams)
        setDirectMode(deriveDirectModeCause(probeSummary: summary))
        refreshUpstreamStatuses()
        return summary
    }

    /// Derive the effective `DirectModeCause` from the union of VPN state and
    /// upstream-probe results. VPN-driven causes win when present:
    ///
    ///   VPN state               | Effective cause
    ///   ------------------------|---------------------------------------------
    ///   .reasserting            | .transientNetworkChange (silent grace window)
    ///   .disconnected(_)        | keep proxy routing if proxy-semantic probe succeeds;
    ///                           | otherwise .vpnDisconnected
    ///   .connected              | derive from proxy-semantic probe + config
    ///   .unknown                | keep proxy routing if proxy-semantic probe succeeds;
    ///                           | otherwise assume off-VPN/direct startup
    ///
    /// This avoids needing two parallel cause-priority systems. Call sites
    /// (`refreshConnectivityMode`, post-recovery reprobes in
    /// `handleVPNStateChange`) feed in their probe summary; callers that do not
    /// have one yet pass `nil` and get the conservative direct-mode answer.
    private func deriveDirectModeCause(probeSummary: UpstreamProbeSummary?) -> DirectModeCause {
        switch snapshot.vpnState {
        case .reasserting:
            return .transientNetworkChange
        case .disconnected:
            if let summary = probeSummary, summary.hasReachableUpstream { return .none }
            return .vpnDisconnected
        case .connected:
            if config.enabledUpstreams.isEmpty { return .noUpstreamsConfigured }
            if let summary = probeSummary, !summary.hasReachableUpstream { return .upstreamsUnreachable }
            return .none
        case .unknown:
            if config.enabledUpstreams.isEmpty { return .noUpstreamsConfigured }
            if let summary = probeSummary, !summary.hasReachableUpstream { return .vpnDisconnected }
            return .none
        }
    }

    /// Reprobe interval for *unexpected* direct mode (`.upstreamsUnreachable`).
    /// Fast cadence because something is genuinely wrong and we want to detect
    /// recovery quickly.
    private static let directReprobeIntervalUnexpected: TimeInterval = 15

    /// Reprobe interval for *expected* direct mode (VPN off, no upstreams
    /// configured). Slow cadence because we're not waiting for "find a working
    /// upstream" — we're waiting for the user to plug VPN back in, which the
    /// `VPNStatusMonitor` will detect via SCDynamicStore and route through
    /// `handleVPNStateChange` long before this timer fires. This is just a
    /// belt-and-suspenders catchall.
    private static let directReprobeIntervalExpected: TimeInterval = 60

    /// Pick the reprobe interval based on the current direct-mode cause.
    /// `cause.isExpected` covers VPN-off, no-upstreams, and the transient
    /// flap window; the unexpected case is `.upstreamsUnreachable` only.
    package static func directReprobeInterval(for cause: DirectModeCause) -> TimeInterval {
        cause.isExpected ? Self.directReprobeIntervalExpected : Self.directReprobeIntervalUnexpected
    }

    private func startDirectModeReprobeTimer() {
        stopDirectModeReprobeTimer()
        let interval = Self.directReprobeInterval(for: snapshot.directModeCause)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.snapshot.directModeCause.usesDirectReprobeTimer,
                  self.snapshot.runtimeStatus.state != .stopped else {
                self?.stopDirectModeReprobeTimer()
                return
            }
            Task { @MainActor in
                self.logStore.log(.debug, "Direct-mode re-probe: checking upstreams…", category: .network)
                let summary = await self.refreshConnectivityMode()
                if !self.snapshot.directModeCause.isDirect, summary.hasReachableUpstream {
                    self.logStore.log(.notice, "Upstreams reachable again — exiting direct mode.", category: .network)
                    self.stopDirectModeReprobeTimer()
                    self.mutateSnapshot {
                        $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                        $0.runtimeStatus.state = .running
                    }
                    self.startHealthLoop()
                }
            }
        }
        directModeReprobeTimer = timer
        timer.resume()
    }

    private func stopDirectModeReprobeTimer() {
        directModeReprobeTimer?.cancel()
        directModeReprobeTimer = nil
    }

    private static let errorRateWindow: TimeInterval = 5
    private static let errorRateThreshold = 20

    private func trackFailureForErrorRate() {
        let now = Date()
        recentFailureTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-Self.errorRateWindow)
        recentFailureTimestamps.removeAll { $0 < cutoff }

        // Phase 2: skip the alarm entirely when we're in direct mode for an
        // *expected* reason (VPN off, no upstreams configured, transient flap).
        // In those states, request failures against corp-internal hosts are
        // expected and do not signal an upstream-pool problem. Only the
        // .upstreamsUnreachable cause and .none state warrant escalation.
        // The counter still tracks (useful for telemetry) but no warning fires
        // and no extra reprobe is triggered.
        let cause = snapshot.directModeCause
        let suppressForExpectedDirect = cause.isExpected
        guard recentFailureTimestamps.count >= Self.errorRateThreshold,
              !errorRateReprobeScheduled,
              !suppressForExpectedDirect,
              snapshot.runtimeStatus.state != .stopped,
              snapshot.runtimeStatus.state != .starting else { return }

        errorRateReprobeScheduled = true
        logStore.log(.warning, "High error rate (\(recentFailureTimestamps.count) failures in \(Int(Self.errorRateWindow))s) — triggering upstream re-probe.", category: .network)

        Task { @MainActor in
            defer { self.errorRateReprobeScheduled = false }
            let summary = await self.refreshConnectivityMode()
            if self.snapshot.directModeCause.isDirect {
                let cause = self.snapshot.directModeCause
                self.mutateSnapshot {
                    $0.runtimeStatus.lastHealthSummary = cause.healthSummary
                    if cause.routesClientTrafficDirectly {
                        $0.runtimeStatus.activeUpstream = "DIRECT"
                    } else {
                        $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                    }
                }
                self.reconcileConnectivityMonitors(for: cause)
            } else if summary.hasReachableUpstream {
                self.stopDirectModeReprobeTimer()
                self.mutateSnapshot {
                    $0.runtimeStatus.activeUpstream = summary.bestReachableUpstream?.endpoint ?? $0.runtimeStatus.activeUpstream
                    if $0.runtimeStatus.state == .degraded || $0.runtimeStatus.state == .failed {
                        $0.runtimeStatus.state = .running
                    }
                }
                self.startHealthLoop()
            }
        }
    }

    /// Set direct-mode state. Updates the shared box (read by HTTPProxyHandler /
    /// SOCKS5Server on every request) and the snapshot (read by UI + NDJSON
    /// consumers) with the new cause. The "is in direct mode" boolean is derived
    /// from the cause via `cause.isDirect` everywhere it's needed; there is no
    /// duplicate stored field.
    private func setDirectMode(_ cause: DirectModeCause) {
        let prior = directModeBox.withLockedValue { state in
            let prior = state.cause
            state = (cause.isDirect, cause)
            return prior
        }
        if prior != cause {
            refreshLocalPACForDirectModeChange(cause)
            logDirectModeEntry(from: prior, to: cause)
        }
        mutateSnapshot { $0.directModeCause = cause }
    }

    private func logDirectModeEntry(from prior: DirectModeCause, to cause: DirectModeCause) {
        guard !prior.isDirect, cause.isDirect, cause != .transientNetworkChange else { return }
        guard snapshot.runtimeStatus.state != .starting else { return }
        emitEvent(.routing, "direct_mode.entered", detail: "cause=\(cause.rawValue) prior=\(prior.rawValue)")
        logStore.log(.notice, "Entering direct mode (cause: \(cause.rawValue)).", category: .network)
    }

    private func refreshUpstreamStatuses() {
        mutateSnapshot {
            $0.upstreamStatuses = self.localProxyServer.upstreamStatuses()
        }
    }

    // MARK: - Transparent TCP Proxy

    private func startTransparentProxy(config: ProxyConfig) async {
        let ip = config.transparentProxyIP
        let port = config.transparentProxyPort

        // Relay FIRST: the helper's relay start is also what creates the lo0
        // alias for the intercept IP, and binding the transparent-proxy
        // listener to that IP fails with EADDRNOTAVAIL until the alias
        // exists. The historical bind-then-relay order could never start
        // from a clean system — it only worked when an alias survived from a
        // previous run. The relay briefly forwards into a not-yet-listening
        // target port (connections get RST for a few ms); that beats the
        // permanent failure the other way around. Port 0 means "bind
        // ephemeral": point the relay at a provisional target so the alias
        // still gets created, then re-point it once the real port is known.
        let relayTarget = port != 0 ? port : 10443
        let relayStarted = startTCPRelay(listenPort: 443, targetPort: relayTarget, host: ip)

        do {
            try await transparentProxy.start(host: ip, port: port)
        } catch {
            logStore.log(
                .warning,
                "Transparent proxy failed to start on \(ip):\(port): \(error.displayDescription)",
                category: .proxy
            )
            if relayStarted {
                stopTCPRelay()
            }
            return
        }

        if let boundPort = transparentProxy.listeningPort, boundPort != relayTarget {
            startTCPRelay(listenPort: 443, targetPort: boundPort, host: ip)
        }
    }

    private func stopTransparentProxy() async {
        stopTCPRelay()
        await transparentProxy.stop()
    }

    /// Returns true when the helper accepted the relay start (which also
    /// aliases the intercept IP onto lo0 — see `startTransparentProxy`).
    @discardableResult
    private func startTCPRelay(listenPort: Int, targetPort: Int, host: String) -> Bool {
        // The kernel no longer downcasts to the concrete
        // `HelperToolPrivilegeClient` — that class lives in `PlatformMac`
        // and the import fence forbids referencing it here. Instead
        // we call the protocol's `execute` and let the impl decide: the real
        // helper socket handles the relay commands; `AppleScriptPrivilegeClient`
        // throws `PrivilegeClientError.executionFailed("Relay commands require
        // the privileged helper")`, which we downgrade to an info log.
        guard let privilegeClient else {
            logStore.log(
                .info,
                "TCP relay unavailable: no privileged helper configured.",
                category: .proxy
            )
            return false
        }
        do {
            try privilegeClient.execute(
                .startTCPRelay,
                values: [String(listenPort), String(targetPort), host]
            )
            logStore.log(
                .notice,
                "TCP relay started: \(host):\(listenPort) → :\(targetPort) via helper.",
                category: .proxy
            )
            return true
        } catch {
            logStore.log(
                .info,
                "TCP relay unavailable on \(host):\(listenPort): \(error.displayDescription)",
                category: .proxy
            )
            return false
        }
    }

    private func stopTCPRelay() {
        // Same pattern as `startTCPRelay`: call the protocol method and ignore
        // failures (stop is best-effort; the AppleScript fallback can't run
        // the command, and a missing helper is fine).
        try? privilegeClient?.execute(.stopTCPRelay, values: [])
        logStore.log(.notice, "TCP relay stopped.", category: .proxy)
    }

    /// Set of ports already claimed by other modules (proxy listener, SOCKS, DNS forwarder,
    /// resolver helper, transparent proxy). Tunnel local ports must not collide with these
    /// or we'll fight other listeners for the bind. Centralised so `startTunnels()` and
    /// `reconcileTunnels()` can't drift apart on which ports count as reserved.
    private static func reservedTunnelPorts(in config: ProxyConfig) -> Set<Int> {
        var reserved: Set<Int> = [config.localPort]
        if config.socksEnabled { reserved.insert(config.socksPort) }
        if config.dnsForwarderEnabled { reserved.insert(config.dnsForwarderPort) }
        reserved.insert(TunnelResolverPort.port)
        if config.transparentProxyEnabled { reserved.insert(config.transparentProxyPort) }
        return reserved
    }

    private static func validateTunnelDefinitions(_ tunnels: [TunnelDefinition], reservedPorts: Set<Int>) -> [String] {
        var errors: [String] = []
        var seenLocalPorts: Set<Int> = []
        for tunnel in tunnels {
            let label = tunnel.effectiveLabel
            if tunnel.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Tunnel \(label): remote host is empty.")
            }
            if tunnel.remotePort <= 0 || tunnel.remotePort > 65535 {
                errors.append("Tunnel \(label): remote port \(tunnel.remotePort) is invalid.")
            }
            if tunnel.localPort < 0 || tunnel.localPort > 65535 {
                errors.append("Tunnel \(label): local port \(tunnel.localPort) is invalid.")
            }
            if tunnel.localPort != 0 && reservedPorts.contains(tunnel.localPort) {
                errors.append("Tunnel \(label): local port \(tunnel.localPort) conflicts with another module (proxy, SOCKS, or DNS).")
            }
            if tunnel.localPort != 0 && seenLocalPorts.contains(tunnel.localPort) {
                errors.append("Tunnel \(label): duplicate local port \(tunnel.localPort).")
            }
            if tunnel.localPort != 0 {
                seenLocalPorts.insert(tunnel.localPort)
            }
        }
        return errors
    }

}

/// Thrown by the orchestrator's default `authenticatorProvider` when the caller
/// did not inject a concrete factory but an upstream proxy demanded auth.
///
/// Kernel-side intentionally: a caller that links `ProxyAuth` provides a real
/// factory at init; a caller that does not (tests, `pm-sim`) gets this error
/// only if a request actually trips a 407.
package struct ProxyAuthenticatorNotConfiguredError: Error, LocalizedError {
    package init() {}
    package var errorDescription: String? {
        "Upstream proxy requires authentication but no authenticator factory was configured on the orchestrator. Inject `authenticatorProvider:` (linking `ProxyAuth`) on `ProxyOrchestrator.init(...)`."
    }
}
