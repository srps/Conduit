// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

/// `VPNStatusObserving` over the dynamic store, level-triggered
/// (`docs/design-vpn-detection-level-triggered.md`, unit U3).
///
/// Every prompt reads the whole store and reconciles: a store notification,
/// a start, a flap deadline, a retry after a failed reading and the audit
/// read every 60 s while healthy. The verdict is `VPNFlapTimer`'s, from the
/// reading, the clock and the timer's memory, so a missed prompt costs
/// latency, never correctness.
///
/// Each `start` opens a session: a new timer (decision 1), a new subscription
/// and a generation that a store callback or a wake-up from an earlier session
/// is checked against. A session holds one wake-up, at the earliest of the
/// flap deadline, the retry and the audit (decision 0048).
///
/// A failed create, subscribe or read reports `.unknown`, emits
/// `vpn.store_failed` at the attempts the read schedule reports, and is tried
/// again on that schedule; a subscribe retry builds a new session. The first
/// good reading after it emits `vpn.store_recovered`. Keys `parse` dropped as
/// malformed emit `vpn.store_key_malformed` when they first appear.
///
/// Threading: store callbacks and wake-ups run on `monitorQueue`, which owns
/// the session; `onChange` and `onEvent` run there. The names a consumer
/// reads inside `onChange` are set before it is called.
package final class VPNStatusMonitor: VPNStatusObserving, @unchecked Sendable {
    private let monitorQueue: DispatchQueue
    private let store: any TunnelStoreReading
    private let clock: StoreObserverClock
    private let up: VPNUpPredicate
    private let graceSecondsProvider: @Sendable () -> TimeInterval
    private let minVisibleSecondsProvider: @Sendable () -> TimeInterval

    private let onChangeBox = NIOLockedValueBox<(@Sendable (VPNObservedState) -> Void)?>(nil)
    private let onEventBox = NIOLockedValueBox<(@Sendable (RuntimeEvent, LogLevel) -> Void)?>(nil)
    private let lifecycleBox = NIOLockedValueBox<LifecycleState>(.init())
    private let namesBox = NIOLockedValueBox<(connected: String?, live: [String])>((nil, []))
    /// Touched only on `monitorQueue`.
    private var session: Session?

    private struct LifecycleState {
        var started = false
        /// Bumped by every start and stop.
        var generation: UInt64 = 0
        var subscription: (any TunnelStoreSubscription)?
        /// The one pending wake-up, and its number: a wake-up runs only while
        /// it is still the newest.
        var wake: Task<Void, Never>?
        var wakeID: UInt64 = 0
    }

    /// What one start has seen. Lives on `monitorQueue`.
    private struct Session {
        let generation: UInt64
        var timer = VPNFlapTimer()
        var schedule = StoreReadSchedule(audit: StoreReadSchedule.Constants.vpnAudit)
        /// The state last delivered in this session, nil before the first.
        var delivered: VPNObservedState?
        /// The malformed keys the last good reading reported.
        var malformed: Set<String> = []
    }

    /// `graceSecondsProvider` and `minVisibleSecondsProvider` are read on
    /// every reconcile; the timer applies them only to a phase that starts
    /// in it. A test passes its own `queue` to order a store callback
    /// against a restart.
    package init(
        graceSecondsProvider: @escaping @Sendable () -> TimeInterval = { 5 },
        minVisibleSecondsProvider: @escaping @Sendable () -> TimeInterval = { 1 },
        store: any TunnelStoreReading = SystemTunnelStore(),
        clock: StoreObserverClock = .continuous,
        up: VPNUpPredicate = .anyIPv4Tunnel,
        queue: DispatchQueue = DispatchQueue(label: "io.github.srps.Conduit.VPNStatusMonitor")
    ) {
        self.monitorQueue = queue
        self.graceSecondsProvider = graceSecondsProvider
        self.minVisibleSecondsProvider = minVisibleSecondsProvider
        self.store = store
        self.clock = clock
        self.up = up
    }

    deinit {
        let state = lifecycleBox.withLockedValue { $0 }
        state.wake?.cancel()
        if let subscription = state.subscription { reportCancel(subscription.cancel()) }
    }

    package func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

    package func setOnEvent(_ onEvent: @Sendable @escaping (RuntimeEvent, LogLevel) -> Void) {
        onEventBox.withLockedValue { $0 = onEvent }
    }

    package var connectedInterfaceName: String? { namesBox.withLockedValue { $0.connected } }

    package var liveInterfaceNames: [String] { namesBox.withLockedValue { $0.live } }

    package func start() {
        let generation = lifecycleBox.withLockedValue { state -> UInt64? in
            guard !state.started else { return nil }
            state.started = true
            state.generation &+= 1
            return state.generation
        }
        guard let generation else { return }
        monitorQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.session = Session(generation: generation)
            self.attempt(generation)
        }
    }

    package func stop() {
        let teardown = lifecycleBox.withLockedValue { state -> ((any TunnelStoreSubscription)?, Task<Void, Never>?) in
            guard state.started else { return (nil, nil) }
            defer {
                state.started = false
                state.generation &+= 1
                state.subscription = nil
                state.wake = nil
            }
            return (state.subscription, state.wake)
        }
        teardown.1?.cancel()
        if let subscription = teardown.0 { reportCancel(subscription.cancel()) }
    }

    /// The event for a subscription released without a cancel. The monitor
    /// always cancels first, so this runs only if that is broken.
    static func uncancelledReleaseEvent(_ result: Result<Void, TunnelReading.Failure>) -> RuntimeEvent {
        let detail = switch result {
        case .success: "outcome=detached"
        case .failure(let failure): "outcome=\(failure.step.rawValue) code=\(failure.code)"
        }
        return RuntimeEvent(kind: .health, event: "vpn.store_released_uncancelled", detail: detail)
    }

    // MARK: - Internals

    private func isCurrent(_ generation: UInt64) -> Bool {
        lifecycleBox.withLockedValue { $0.started && $0.generation == generation }
    }

    private func emit(_ event: RuntimeEvent, _ level: LogLevel) {
        onEventBox.withLockedValue { $0 }?(event, level)
    }

    /// A failed cancel leaves a queue the store may still call; the
    /// generation check drops those calls.
    private func reportCancel(_ result: Result<Void, TunnelReading.Failure>) {
        guard case .failure(let failure) = result else { return }
        emit(RuntimeEvent(kind: .health, event: "vpn.store_unsubscribe_failed", detail: "code=\(failure.code)"), .warning)
    }

    /// Subscribes if this session has no subscription, then reads. Runs on
    /// `monitorQueue`.
    private func attempt(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        guard lifecycleBox.withLockedValue({ $0.subscription }) == nil else {
            reconcile(store.read(), generation)
            return
        }
        let subscribed = store.subscribe(
            queue: monitorQueue,
            onChange: { [weak self] in self?.storeChanged(generation) },
            onUncancelledRelease: { [onEventBox] in onEventBox.withLockedValue { $0 }?(Self.uncancelledReleaseEvent($0), .error) }
        )
        switch subscribed {
        case .failure(let failure):
            reconcile(.failed(failure), generation)
        case .success(let subscription):
            let installed = lifecycleBox.withLockedValue { state -> Bool in
                guard state.started, state.generation == generation, state.subscription == nil else { return false }
                state.subscription = subscription
                return true
            }
            guard installed else {
                reportCancel(subscription.cancel())
                return
            }
            reconcile(store.read(), generation)
        }
    }

    /// Runs on `monitorQueue`.
    private func storeChanged(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        reconcile(store.read(), generation)
    }

    /// Runs on `monitorQueue`.
    private func reconcile(_ reading: TunnelReading, _ generation: UInt64) {
        guard isCurrent(generation), var session, session.generation == generation else { return }
        let now = clock.now()
        let window = VPNFlapWindow(minVisible: minVisibleSecondsProvider(), grace: graceSecondsProvider())
        let detection = session.timer.reconcile(reading, now: now, window: window, up: up)

        let readDue: TimeInterval?
        switch reading {
        case .failed(let failure):
            let retry = session.schedule.failed(at: now)
            if retry.reports {
                emit(RuntimeEvent(
                    kind: .health, event: "vpn.store_failed",
                    detail: "reason=\(failure.step.rawValue) code=\(failure.code) attempt=\(retry.attempt)"
                ), .warning)
            }
            readDue = retry.due
        case .snapshot(let snapshot):
            let healthy = session.schedule.succeeded(at: now)
            if let attempts = healthy.recoveredAfter {
                emit(RuntimeEvent(kind: .health, event: "vpn.store_recovered", detail: "attempts=\(attempts)"), .notice)
            }
            let malformed = Set(snapshot.malformedKeys)
            for key in malformed.subtracting(session.malformed).sorted() {
                emit(RuntimeEvent(kind: .health, event: "vpn.store_key_malformed", detail: "key=\(key)"), .warning)
            }
            session.malformed = malformed
            readDue = healthy.due
        }

        let deliver = detection.state != session.delivered
        session.delivered = detection.state
        self.session = session
        if let due = [readDue, detection.deadline].compactMap({ $0 }).min() {
            arm(after: max(0, due - now), generation)
        }

        let namesMoved = namesBox.withLockedValue { names -> Bool in
            defer { names = (detection.carrying.first, detection.live) }
            return names.connected != detection.carrying.first || names.live != detection.live
        }
        // An unchanged `.connected` is delivered again when the tunnel
        // carrying it or the live set moved, so the hosts pick up the new
        // names; the orchestrator treats it as a name update, not a
        // transition.
        guard deliver || (namesMoved && detection.state == .connected) else { return }
        onChangeBox.withLockedValue { $0 }?(detection.state)
    }

    /// Replaces the pending wake-up with one `delay` seconds out, allowed to
    /// run 10% late.
    private func arm(after delay: TimeInterval, _ generation: UInt64) {
        let tolerance = StoreReadSchedule.leeway(for: delay)
        lifecycleBox.withLockedValue { state in
            guard state.started, state.generation == generation else { return }
            state.wake?.cancel()
            state.wakeID &+= 1
            let wakeID = state.wakeID
            state.wake = Task { [weak self, clock] in
                do {
                    try await clock.sleep(delay, tolerance)
                } catch {
                    // Cancelled: a stop, a restart or a newer wake-up
                    // replaced this one, and owns what happens next.
                    return
                }
                self?.monitorQueue.async { [weak self] in self?.wake(wakeID, generation) }
            }
        }
    }

    /// Runs on `monitorQueue`.
    private func wake(_ wakeID: UInt64, _ generation: UInt64) {
        guard lifecycleBox.withLockedValue({ $0.wakeID == wakeID }) else { return }
        attempt(generation)
    }
}
