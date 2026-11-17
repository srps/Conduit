// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel
import SystemConfiguration

/// Producer of the current pushed-resolver set. Mirrors `VPNStatusObserving`
/// and `NetworkPathObserving`. The production observer is
/// `PushedResolverMonitor`; `FakePushedResolverObserver` in
/// `PlatformFakes.swift` is the injection point.
package protocol PushedResolverObserving: AnyObject, Sendable {
    /// Called with the whole current reading on every change, never a delta,
    /// on any queue; the consumer hops to its own isolation. A reading with
    /// no resolvers is valid; one with a `failure` says the store could not
    /// be created, subscribed to or read, and its `failedAttempts` how many
    /// times in a row.
    func setOnChange(_ onChange: @Sendable @escaping (PushedResolverReading) -> Void)

    /// Reads the store once and reports it, then observes. Idempotent.
    func start()

    /// Stops observing and releases the store. Idempotent.
    func stop()
}

/// `PushedResolverObserving` over `SCDynamicStore`, read-only. Watches the
/// per-service DNS, IPv4 and IPv6 keys and the global DNS key, and on each
/// notification takes one `SCDynamicStoreCopyMultiple` of the service keys and
/// parses it with `PushedResolverReading.parse(store:)`. A reading equal to
/// the last one delivered is not delivered again.
///
/// A failed create, subscribe or read is tried again on `StoreReadSchedule`
/// (decision 0048, #304): after 1, 2, 4, 8 and 16 s, then every 30 s, until a
/// reading succeeds. A create or subscribe retry builds a new store session.
/// A failed reading is delivered at the attempts the schedule reports, so the
/// first failure drops the detected set at once and a store that stays broken
/// costs a few readings an hour. The first good reading after a failure
/// carries the count of the attempts it ended. There is no audit read: a
/// healthy session reads only when the store notifies.
///
/// Threading follows `VPNStatusMonitor`: the store dispatches on
/// `monitorQueue`, the schedule and `lastDelivered` are touched only there,
/// and `onChange` runs there. Each `start` opens a generation; a store
/// callback or a wake-up from an earlier one does nothing.
package final class PushedResolverMonitor: PushedResolverObserving, @unchecked Sendable {
    /// The store calls that can fail. A test replaces one to fail it.
    package struct Calls: Sendable {
        package var create: @Sendable (CFString, SCDynamicStoreCallBack?, inout SCDynamicStoreContext) -> SCDynamicStore? = {
            SCDynamicStoreCreate(kCFAllocatorDefault, $0, $1, &$2)
        }
        package var copyMultiple: @Sendable (SCDynamicStore, CFArray) -> CFDictionary? = {
            SCDynamicStoreCopyMultiple($0, nil, $1)
        }
        package var setNotificationKeys: @Sendable (SCDynamicStore, CFArray) -> Bool = {
            SCDynamicStoreSetNotificationKeys($0, nil, $1)
        }
        package var setDispatchQueue: @Sendable (SCDynamicStore, DispatchQueue?) -> Bool = {
            SCDynamicStoreSetDispatchQueue($0, $1)
        }

        package init() {}
    }

    private let monitorQueue = DispatchQueue(label: "io.github.srps.Conduit.PushedResolverMonitor")
    private let onChangeBox = NIOLockedValueBox<(@Sendable (PushedResolverReading) -> Void)?>(nil)
    private let lifecycleBox = NIOLockedValueBox<LifecycleState>(.init())
    private let calls: Calls
    private let clock: StoreObserverClock
    /// Touched only on `monitorQueue`; reset by each generation's first attempt.
    private var schedule = StoreReadSchedule(audit: nil)
    private var lastDelivered: PushedResolverReading?

    private struct LifecycleState {
        var started = false
        /// Bumped by every start and stop.
        var generation: UInt64 = 0
        /// This generation's subscribed session, once one is installed.
        var store: SCDynamicStore?
        /// The one pending wake-up, and its number: a wake-up runs only while
        /// it is still the newest.
        var wake: Task<Void, Never>?
        var wakeID: UInt64 = 0
    }

    private static let notificationPatterns = [
        PushedResolverReading.dnsKeyPattern,
        PushedResolverReading.ipv4KeyPattern,
        PushedResolverReading.ipv6KeyPattern,
        "State:/Network/Global/DNS",
    ]

    private static let readPatterns = [
        PushedResolverReading.dnsKeyPattern,
        PushedResolverReading.ipv4KeyPattern,
        PushedResolverReading.ipv6KeyPattern,
    ]

    package init(calls: Calls = Calls(), clock: StoreObserverClock = .continuous) {
        self.calls = calls
        self.clock = clock
    }

    deinit {
        let state = lifecycleBox.withLockedValue { $0 }
        state.wake?.cancel()
        if let store = state.store { _ = calls.setDispatchQueue(store, nil) }
    }

    package func setOnChange(_ onChange: @Sendable @escaping (PushedResolverReading) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

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
            self.schedule = StoreReadSchedule(audit: nil)
            self.lastDelivered = nil
            self.attempt(generation)
        }
    }

    package func stop() {
        let teardown = lifecycleBox.withLockedValue { state -> (SCDynamicStore?, Task<Void, Never>?) in
            guard state.started else { return (nil, nil) }
            defer {
                state.started = false
                state.generation &+= 1
                state.store = nil
                state.wake = nil
            }
            return (state.store, state.wake)
        }
        teardown.1?.cancel()
        guard let store = teardown.0 else { return }
        _ = calls.setDispatchQueue(store, nil)
    }

    /// One read of the live store with no subscription, for diagnostics.
    package static func readOnce() -> PushedResolverReading {
        let calls = Calls()
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let store = calls.create("io.github.srps.Conduit.PushedResolverRead" as CFString, nil, &context) else {
            return PushedResolverReading(failure: .storeCreate)
        }
        return read(store, calls: calls)
    }

    private static func read(_ store: SCDynamicStore, calls: Calls) -> PushedResolverReading {
        guard let values = calls.copyMultiple(store, readPatterns as CFArray) as? [String: Any] else {
            return PushedResolverReading(failure: .storeRead)
        }
        return PushedResolverReading.parse(store: values)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lifecycleBox.withLockedValue { $0.started && $0.generation == generation }
    }

    /// One scheduled attempt: installs a session if this generation has none,
    /// then reads. Runs on `monitorQueue`.
    private func attempt(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        if let store = lifecycleBox.withLockedValue({ $0.store }) {
            read(store, generation)
            return
        }
        switch install(generation) {
        case .installed(let store): read(store, generation)
        case .failed(let failure): failed(failure, generation)
        case .superseded: return
        }
    }

    private enum Install {
        case installed(SCDynamicStore)
        case failed(PushedResolverReading.Failure)
        /// A stop or a restart came first; nothing was kept.
        case superseded
    }

    /// Builds a new subscribed session for `generation`. Runs on `monitorQueue`.
    private func install(_ generation: UInt64) -> Install {
        // The store retains and releases the session through its context, so
        // the session lives exactly as long as a callback can reach it.
        let session = Session(monitor: self, generation: generation)
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(session).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<Session>.fromOpaque($0).retain().toOpaque()) },
            release: { Unmanaged<Session>.fromOpaque($0).release() },
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { store, _, info in
            guard let info else { return }
            Unmanaged<Session>.fromOpaque(info).takeUnretainedValue().storeChanged(store)
        }
        guard let store = calls.create("io.github.srps.Conduit.PushedResolverMonitor" as CFString, callback, &context) else {
            return .failed(.storeCreate)
        }
        guard calls.setNotificationKeys(store, Self.notificationPatterns as CFArray),
              calls.setDispatchQueue(store, monitorQueue) else {
            // No queue was attached, and releasing the store drops its keys.
            // The next attempt builds a new session.
            return .failed(.storeSubscribe)
        }
        let installed = lifecycleBox.withLockedValue { state -> Bool in
            guard state.started, state.generation == generation, state.store == nil else { return false }
            state.store = store
            return true
        }
        guard installed else {
            _ = calls.setDispatchQueue(store, nil)
            return .superseded
        }
        return .installed(store)
    }

    /// Runs on `monitorQueue`.
    private func read(_ store: SCDynamicStore, _ generation: UInt64) {
        guard isCurrent(generation) else { return }
        var reading = Self.read(store, calls: calls)
        if let failure = reading.failure {
            failed(failure, generation)
            return
        }
        let healthy = schedule.succeeded(at: clock.now())
        disarm(generation)
        reading.failedAttempts = healthy.recoveredAfter ?? 0
        deliver(reading, generation)
    }

    /// Runs on `monitorQueue`.
    private func failed(_ failure: PushedResolverReading.Failure, _ generation: UInt64) {
        let now = clock.now()
        let retry = schedule.failed(at: now)
        if retry.reports {
            deliver(PushedResolverReading(failure: failure, failedAttempts: retry.attempt), generation)
        }
        arm(after: retry.due - now, generation)
    }

    /// Replaces the pending wake-up with one `delay` seconds out.
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
                    // Cancelled: a stop, a restart, a good reading or a newer
                    // wake-up replaced this one, and owns what happens next.
                    return
                }
                guard let self else { return }
                self.monitorQueue.async { [weak self] in self?.wake(wakeID, generation) }
            }
        }
    }

    private func disarm(_ generation: UInt64) {
        let pending = lifecycleBox.withLockedValue { state -> Task<Void, Never>? in
            guard state.generation == generation else { return nil }
            defer {
                state.wake = nil
                state.wakeID &+= 1
            }
            return state.wake
        }
        pending?.cancel()
    }

    /// Runs on `monitorQueue`.
    private func wake(_ wakeID: UInt64, _ generation: UInt64) {
        guard lifecycleBox.withLockedValue({ $0.wakeID == wakeID }) else { return }
        attempt(generation)
    }

    /// Runs on `monitorQueue`.
    private func deliver(_ reading: PushedResolverReading, _ generation: UInt64) {
        guard isCurrent(generation), reading != lastDelivered else { return }
        lastDelivered = reading
        onChangeBox.withLockedValue { $0 }?(reading)
    }

    /// What a store session's callback reaches: the monitor, held weakly so
    /// the store does not keep it alive, and the generation that built it.
    private final class Session {
        weak var monitor: PushedResolverMonitor?
        let generation: UInt64

        init(monitor: PushedResolverMonitor, generation: UInt64) {
            self.monitor = monitor
            self.generation = generation
        }

        /// Runs on `monitorQueue`.
        func storeChanged(_ store: SCDynamicStore) {
            monitor?.read(store, generation)
        }
    }
}
