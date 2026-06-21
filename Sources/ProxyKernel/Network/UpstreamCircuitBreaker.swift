// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure value-type state machine for the per-upstream circuit breaker. Extracted
/// from `ConnectionPool` so that:
///
///   * The full transition table (`closed → open → halfOpen → {open|closed}`,
///     plus `reset` from any state) lives in one structure that is independently
///     testable without spinning up an event loop or a NIO channel.
///   * Each transition emits a typed `Transition` event the orchestrator's
///     `RuntimeEventLog` can fan out as `upstream.circuit_*` structured events.
///     This is the observability win: "which upstream
///     stopped serving for 30s, and why?" becomes answerable from
///     `pmctl events --follow` instead of guessing from log lines.
///   * Future strategies — per-upstream tuning, manual lock/unlock from the
///     UI, "always probe even if open" override — compose against a single
///     contract instead of poking at the pool's private fields.
///
/// Design invariants (all verified by `UpstreamCircuitBreakerTests`):
///
///   * `state` only changes inside `recordFailure`, `recordSuccess`,
///     `tryHalfOpen`, or `reset`. The breaker has no implicit time-driven
///     transitions; the caller drives the clock by passing `now:` at every
///     mutation. This keeps the structure deterministic for tests and
///     simulator scenarios.
///   * Mutations return `Transition?`. `nil` means "state did not change in a
///     way worth surfacing." The caller (currently `ConnectionPool`) decides
///     whether to log + event-emit. Transitions are the contract; per-call
///     side effects like log lines are the consumer's concern.
///   * Synchronized failure bursts within `windowSeconds` of the first failure
///     do NOT trip the breaker. This is the Phase 5 fix from
///     `docs/design-vpn-flap-resilience.md`: 5 in-flight requests all
///     failing at the same VPN-flap instant is a path signal, not an
///     upstream-rot signal. `windowSeconds = 0` disables the guard for
///     setups that prefer the legacy burst-trip behaviour.
///   * `nextOpenInterval` exposes the open interval that was applied at the
///     most recent trip. The first trip applies `baseOpenInterval`; each
///     subsequent half-open re-trip applies `min(nextOpenInterval * 2,
///     maxOpenInterval)`. `recordSuccess` (closing from half-open) and
///     `reset(_:baseOpenInterval:)` both restore it to base.
///   * `ewmaLatencyMS` is updated by every `recordSuccess` regardless of
///     whether a transition fires — latency information about the upstream
///     is independent of its circuit state. `alpha = 0.3` matches the
///     historical `ConnectionPool.ewmaAlpha` constant so the perceived
///     latency curve is unchanged after the extraction.
///   * Failures recorded while the breaker is already `.open` do nothing
///     (return `nil`). The breaker is already saying "don't use this
///     upstream"; redundant failure signal is noise.
package struct UpstreamCircuitBreaker: Sendable, Equatable {

    // MARK: - Observable state

    package private(set) var state: UpstreamCircuitState = .closed
    package private(set) var consecutiveFailures: Int = 0
    package private(set) var firstFailureAt: Date?
    package private(set) var openUntil: Date?
    package private(set) var lastOpenedAt: Date?
    package private(set) var halfOpenProbeInFlight: Bool = false
    /// The open interval (seconds) applied at the most recent trip. Default = 30,
    /// matching the legacy `ConnectionPool.baseCircuitOpenInterval`. The default
    /// is harmless because before any failure has been recorded the value is
    /// unobservable to consumers — `recordFailure` overwrites it on every trip.
    package private(set) var nextOpenInterval: TimeInterval = 30
    package private(set) var ewmaLatencyMS: Double?

    // MARK: - Internal state

    /// Last-seen `baseOpenInterval` argument from `recordFailure`. Consumed by
    /// `recordSuccess` (which doesn't take a base parameter) to know what
    /// value to restore on a half-open → closed transition. Stays at 30
    /// until the first failure is recorded.
    private var lastBaseOpenInterval: TimeInterval = 30

    private static let ewmaAlpha = 0.3

    // MARK: - Transition events

    package enum Transition: Sendable, Equatable {
        /// State entered `.open`. `consecutiveFailures` is the count that
        /// triggered the trip (snapshotted before the breaker resets it
        /// internally). `openInterval` is the seconds the breaker will stay
        /// open before the next half-open attempt — the structured-event
        /// surface this drives lets `pmctl` render countdowns without
        /// re-reading the snapshot every tick.
        case opened(reason: OpenReason, consecutiveFailures: Int, openInterval: TimeInterval)
        /// State entered `.halfOpen`. `elapsedSeconds` is `now -
        /// lastOpenedAt`, recorded so the event log answers "how long was
        /// it open?" without subtracting timestamps.
        case halfOpened(elapsedSeconds: TimeInterval)
        /// State entered `.closed`. The reason distinguishes a probe-driven
        /// recovery from an explicit reset (e.g. VPN flap recovery), which
        /// matters for "what made the breaker recover?" diagnostics.
        case closed(CloseReason)
    }

    package enum OpenReason: Sendable, Equatable {
        /// `closed → open`: consecutive-failure threshold reached AND the
        /// time-window guard elapsed.
        case thresholdReached
        /// `halfOpen → open`: the single half-open probe failed. Re-opens
        /// immediately and doubles the open interval.
        case probeFailed
    }

    package enum CloseReason: Sendable, Equatable {
        /// `halfOpen → closed`: the single half-open probe succeeded.
        case probeSuccess
        /// Forced close from any state, with the reason that triggered it.
        case reset(ResetReason)
    }

    package enum ResetReason: Sendable, Equatable {
        /// VPN reconnected after a flap; `ProxyOrchestrator` resets every
        /// breaker so the next request through each upstream gets an honest
        /// first attempt instead of being rejected by an open circuit
        /// tripped on the now-stale flap-network path. Mirrors the legacy
        /// `ConnectionPool.resetCircuitsAfterFlap` call site.
        case vpnFlapRecovered
        /// Daemon restarted; no inherited backoff state.
        case daemonRestart
        /// User clicked "reset breaker" in the UI / `pmctl breaker reset`.
        case manualOverride
    }

    package init() {}

    // MARK: - Mutations

    /// Record a successful exchange. Updates EWMA latency unconditionally
    /// and, if the breaker was open or half-open, closes it with
    /// `.probeSuccess`.
    @discardableResult
    package mutating func recordSuccess(latencyMS: Int) -> Transition? {
        if let ewma = ewmaLatencyMS {
            ewmaLatencyMS = (Self.ewmaAlpha * Double(latencyMS)) + ((1 - Self.ewmaAlpha) * ewma)
        } else {
            ewmaLatencyMS = Double(latencyMS)
        }
        consecutiveFailures = 0
        firstFailureAt = nil

        switch state {
        case .closed:
            return nil
        case .open, .halfOpen:
            state = .closed
            openUntil = nil
            lastOpenedAt = nil
            halfOpenProbeInFlight = false
            nextOpenInterval = lastBaseOpenInterval
            return .closed(.probeSuccess)
        }
    }

    /// Record a failed exchange. May trip the breaker depending on current
    /// state, threshold, and window guard.
    ///
    /// - From `.closed`: trips after `threshold` consecutive failures whose
    ///   total time-span across the run is ≥ `windowSeconds`. Synchronized
    ///   bursts within the window are absorbed silently (Phase 5 invariant).
    /// - From `.halfOpen`: trips immediately with `.probeFailed` and doubles
    ///   the open interval.
    /// - From `.open`: no-op (returns `nil`). Failure noise during an open
    ///   window doesn't change the contract.
    @discardableResult
    package mutating func recordFailure(
        now: Date,
        threshold: Int,
        windowSeconds: TimeInterval,
        baseOpenInterval: TimeInterval,
        maxOpenInterval: TimeInterval
    ) -> Transition? {
        lastBaseOpenInterval = baseOpenInterval

        // Short-circuit `.open` BEFORE mutating the failure counter or
        // anchor. The class doc + `.open` case-doc both say this path
        // is a no-op; pre-fix it incremented `consecutiveFailures` and
        // (on the first call) set `firstFailureAt`, leaking visible
        // state for a transition the breaker promised it would ignore.
        // The leak was harmless under the existing call site
        // (`recordFailure` is only called from inside the lock and the
        // counter is reset on the next `.recordSuccess` / `.reset`),
        // but the snapshot-exposed `consecutiveFailures` field would
        // tick up while the breaker was open in any future callsite
        // that called `recordFailure` for `.open` upstreams.
        if state == .open {
            return nil
        }

        consecutiveFailures += 1
        if firstFailureAt == nil {
            firstFailureAt = now
        }

        let openReason: OpenReason
        let appliedInterval: TimeInterval
        let triggeringFailureCount: Int

        switch state {
        case .open:
            // Unreachable — handled above so the early return matches
            // the documented no-op contract. Kept here so the `switch`
            // stays exhaustive without a defaulted case.
            return nil
        case .halfOpen:
            openReason = .probeFailed
            appliedInterval = min(nextOpenInterval * 2, maxOpenInterval)
            triggeringFailureCount = consecutiveFailures
        case .closed:
            guard consecutiveFailures >= threshold else {
                return nil
            }
            let firstFail = firstFailureAt ?? now
            let windowOK = (windowSeconds <= 0) || (now.timeIntervalSince(firstFail) >= windowSeconds)
            guard windowOK else {
                return nil
            }
            openReason = .thresholdReached
            // First trip after a reset: apply baseOpenInterval. Subsequent
            // re-trips happen from .halfOpen (handled above), not from .closed.
            appliedInterval = baseOpenInterval
            triggeringFailureCount = consecutiveFailures
        }

        state = .open
        openUntil = now.addingTimeInterval(appliedInterval)
        lastOpenedAt = now
        halfOpenProbeInFlight = false
        consecutiveFailures = 0
        firstFailureAt = nil
        nextOpenInterval = appliedInterval
        return .opened(reason: openReason, consecutiveFailures: triggeringFailureCount, openInterval: appliedInterval)
    }

    /// Try to transition `.open → .halfOpen`. Succeeds if `openUntil` has
    /// elapsed and no probe is currently in flight. Sets
    /// `halfOpenProbeInFlight = true` so concurrent attempts return `nil`.
    @discardableResult
    package mutating func tryHalfOpen(now: Date) -> Transition? {
        guard state == .open else { return nil }
        guard let openUntil, openUntil <= now else { return nil }
        guard !halfOpenProbeInFlight else { return nil }

        let elapsed = now.timeIntervalSince(lastOpenedAt ?? openUntil)
        state = .halfOpen
        halfOpenProbeInFlight = true
        self.openUntil = nil
        return .halfOpened(elapsedSeconds: elapsed)
    }

    /// Force `.open → .halfOpen` regardless of whether `openUntil` has
    /// elapsed. Used by the connection-pool's "every upstream is open, try
    /// the longest-opened one anyway" fallback so client requests don't
    /// fail-fast when every breaker is mid-backoff. The emitted transition
    /// carries `elapsedSeconds: 0` to signal "this is a forced fallback,
    /// not a normal backoff-elapsed promotion" — observability consumers
    /// can distinguish "the breaker decided to probe" from "the pool had
    /// no other choice".
    ///
    /// Returns `nil` (and leaves state unchanged) if the breaker isn't
    /// `.open` or already has a probe in flight — both cases mean the
    /// half-open slot is already accounted for.
    @discardableResult
    package mutating func forceHalfOpen() -> Transition? {
        guard state == .open else { return nil }
        guard !halfOpenProbeInFlight else { return nil }
        state = .halfOpen
        halfOpenProbeInFlight = true
        openUntil = nil
        return .halfOpened(elapsedSeconds: 0)
    }

    /// Force the breaker closed with the supplied `baseOpenInterval`.
    /// Returns `nil` when the breaker is already in pristine default state
    /// for the supplied base — avoids storming the event log with no-op
    /// resets when, e.g., a VPN observer fires twice for the same recovery.
    /// `ewmaLatencyMS` is preserved because the upstream itself didn't
    /// change, only the path through the kernel did.
    @discardableResult
    package mutating func reset(reason: ResetReason, baseOpenInterval: TimeInterval) -> Transition? {
        let alreadyClean = state == .closed
            && consecutiveFailures == 0
            && firstFailureAt == nil
            && openUntil == nil
            && lastOpenedAt == nil
            && nextOpenInterval == baseOpenInterval
            && !halfOpenProbeInFlight
        lastBaseOpenInterval = baseOpenInterval
        if alreadyClean {
            return nil
        }
        state = .closed
        consecutiveFailures = 0
        firstFailureAt = nil
        openUntil = nil
        lastOpenedAt = nil
        halfOpenProbeInFlight = false
        nextOpenInterval = baseOpenInterval
        return .closed(.reset(reason))
    }
}
