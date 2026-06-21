// SPDX-License-Identifier: Apache-2.0
// Relocated from `ConduitCore/Network/` to `PlatformMac/`.
// `import SystemConfiguration` is forbidden in `ConduitCore` per the
// import fence (see AGENTS.md). The `VPNStatusObserving` protocol it produces
// stays in `ConduitCore/Network/` — kernel consumers branch on the
// protocol without ever seeing the SCDynamicStore concrete.

import Darwin
import ProxyKernel
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import SystemConfiguration

/// Production implementation of `VPNStatusObserving`. Tier B in the design doc
/// (`docs/design-vpn-flap-resilience.md` § "Detection Tiers"): observes
/// `utun*` interface state in `SCDynamicStore`, fuses the raw events into
/// terminal `VPNObservedState` transitions via `VPNStateFuser`, and emits
/// to the registered `onChange` callback.
///
/// Threading: SCDynamicStore callbacks arrive on `monitorQueue` (a dedicated
/// serial queue). The fuser is held as a regular ivar mutated only on
/// `monitorQueue` — the queue's serialization replaces explicit locking.
/// The user's `onChange` closure is invoked on `monitorQueue` — the consumer
/// (typically `AppState`) is expected to hop to its own isolation context.
package final class VPNStatusMonitor: VPNStatusObserving, @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "io.github.srps.Conduit.VPNStatusMonitor")

    private let onChangeBox = NIOLockedValueBox<(@Sendable (VPNObservedState) -> Void)?>(nil)
    private let lifecycleBox = NIOLockedValueBox<LifecycleState>(.init())

    /// Mutated only on `monitorQueue`. Not in the lifecycle box because the
    /// fuser holds non-Sendable state (timer book-keeping) that doesn't belong
    /// in a cross-thread shared container.
    private var fuser = VPNStateFuser()
    /// Pending grace-window timer for the most recent `.reasserting` transition.
    /// Owned by the monitor (not the fuser) so the fuser stays a pure value type.
    private var graceWorkItem: DispatchWorkItem?
    /// Phase 6 (revised): per-interface min-visible timers. Each utun in
    /// `.linkDownDebouncing` has its own timer. If link recovers before the
    /// timer fires, applyObservation cancels it. If the timer fires, it
    /// commits the flap by calling fuser.markMinVisibleExpired().
    private var minVisibleWorkItems: [String: DispatchWorkItem] = [:]

    private struct LifecycleState {
        var store: SCDynamicStore?
        var started = false
        /// Opaque pointer to the `Unmanaged<VPNStatusMonitor>` retain we passed
        /// into `SCDynamicStoreContext.info` in `installStore`. Stored as a raw
        /// pointer (Sendable) rather than the non-Sendable `Unmanaged` itself,
        /// then reconstituted in `stop()` to balance the +1 retain. Cleared
        /// alongside `store` on teardown so a second `stop()` is a no-op.
        var contextOpaque: UnsafeMutableRawPointer?
    }

    /// Grace window before a Link-down utun is declared `.disconnected(.networkLost)`.
    /// Read on every `.reasserting` transition so that Settings-driven config
    /// edits propagate without restarting the monitor — mirrors the
    /// `configProvider` closure pattern used by `ConnectionPool` and
    /// `LocalProxyServer`.
    private let graceSecondsProvider: @Sendable () -> TimeInterval

    /// Phase 6 (revised): minimum Link-inactive duration before a flap becomes
    /// user-visible. Returning `<= 0` disables debounce (every flap immediately
    /// visible — the pre-Phase-6-revision behavior). Read on every link-down
    /// transition so Settings-driven config edits take effect on the next flap.
    private let minVisibleSecondsProvider: @Sendable () -> TimeInterval

    package init(
        graceSecondsProvider: @escaping @Sendable () -> TimeInterval = { 5 },
        minVisibleSecondsProvider: @escaping @Sendable () -> TimeInterval = { 1 }
    ) {
        self.graceSecondsProvider = graceSecondsProvider
        self.minVisibleSecondsProvider = minVisibleSecondsProvider
    }

    package func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

    package func start() {
        let alreadyStarted = lifecycleBox.withLockedValue { state -> Bool in
            if state.started { return true }
            state.started = true
            return false
        }
        if alreadyStarted { return }

        // Build the SCDynamicStore on the monitor queue so the callback context
        // and the queue dispatch land together.
        monitorQueue.async { [weak self] in
            self?.installStore()
        }
    }

    package func stop() {
        let teardown = lifecycleBox.withLockedValue { state -> (store: SCDynamicStore?, opaque: UnsafeMutableRawPointer?) in
            guard state.started else { return (nil, nil) }
            state.started = false
            let s = state.store
            let o = state.contextOpaque
            state.store = nil
            state.contextOpaque = nil
            return (s, o)
        }
        // Cancel pending timers on the monitor queue so the cancellation is
        // serialized with any in-flight fuser work.
        monitorQueue.async { [weak self] in
            self?.graceWorkItem?.cancel()
            self?.graceWorkItem = nil
            for (_, work) in self?.minVisibleWorkItems ?? [:] { work.cancel() }
            self?.minVisibleWorkItems.removeAll()
        }
        guard let store = teardown.store else { return }
        // Detach the store from its dispatch queue. Per Apple docs, passing nil
        // releases the queue association; after this returns no new SCDynamicStore
        // callbacks can fire and any in-flight callback has already completed.
        SCDynamicStoreSetDispatchQueue(store, nil)
        // Balance the +1 retain installStore() took for the C callback context.
        // Safe to release here because the store is detached above — the callback
        // that holds the only consumer of this opaque pointer can no longer fire.
        if let opaque = teardown.opaque {
            Unmanaged<VPNStatusMonitor>.fromOpaque(opaque).release()
        }
    }

    // MARK: - Internals

    private func installStore() {
        // If `stop()` ran between this start() dispatching and the queue picking
        // up our work, bail out — taking a retain now would leak self forever
        // since the matched release in stop() has already run for the empty
        // lifecycle.
        guard lifecycleBox.withLockedValue({ $0.started }) else { return }

        // Capture self via Unmanaged.passRetained for the C callback context.
        // The +1 retain keeps `self` alive for the duration of the
        // SCDynamicStore subscription regardless of Swift-side references; the
        // matching release happens in `stop()` after
        // SCDynamicStoreSetDispatchQueue(store, nil) drains in-flight callbacks.
        let retained = Unmanaged.passRetained(self)
        let context = UnsafeMutableRawPointer(retained.toOpaque())
        var scContext = SCDynamicStoreContext(
            version: 0,
            info: context,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, changedKeysCF, info in
            guard let info else { return }
            let monitor = Unmanaged<VPNStatusMonitor>.fromOpaque(info).takeUnretainedValue()
            let changedKeys = (changedKeysCF as? [String]) ?? []
            monitor.handleStoreChanges(changedKeys)
        }

        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "io.github.srps.Conduit.VPNStatusMonitor" as CFString,
            callback,
            &scContext
        ) else {
            // SCDynamicStoreCreate failed — we never installed a callback that
            // could touch the retained context, so release immediately so the
            // failed-bootstrap path doesn't leak self.
            retained.release()
            return
        }

        // Patterns:
        //   State:/Network/Interface/utun[0-9]+/IPv4  — assigned addresses (the
        //                                               "tunnel reachable" signal)
        //   State:/Network/Interface/utun[0-9]+/IPv6  — interface-alive signal,
        //                                               disambiguates flap vs removal
        //   Setup:/Network/Service/<UUID>             — service add/remove
        //                                               (currently subscribed but
        //                                               unused; kept for future
        //                                               .userInitiated detection)
        //
        // /Link is intentionally absent: macOS does not publish a /Link key
        // for utun virtual interfaces (verified via `scutil` on macOS 26 with
        // a Cisco Secure Client tunnel up). Subscribing to it would deliver
        // zero notifications. See `UtunRawObservation` doc.
        let patterns: [CFString] = [
            "State:/Network/Interface/utun[0-9]+/IPv4" as CFString,
            "State:/Network/Interface/utun[0-9]+/IPv6" as CFString,
            "Setup:/Network/Service/[A-F0-9-]+" as CFString,
        ]
        SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, monitorQueue)

        // Stash both the store and the opaque retain pointer atomically so a
        // racing `stop()` can find them together. If `stop()` already ran while
        // we were assembling the store, undo our work right here so we don't
        // strand a kernel subscription with no matching teardown path.
        let installed = lifecycleBox.withLockedValue { state -> Bool in
            guard state.started else { return false }
            state.store = store
            state.contextOpaque = context
            return true
        }
        if !installed {
            SCDynamicStoreSetDispatchQueue(store, nil)
            retained.release()
            return
        }

        // Prime: take an initial reading of the current utun set so we don't sit
        // in `.unknown` until the first event after a long period of stability.
        primeInitialState(store: store)
    }

    /// Read all current `utun*` keys once at install-time so we have a baseline
    /// state without waiting for the first kernel event.
    private func primeInitialState(store: SCDynamicStore) {
        let ipv4Pattern = "State:/Network/Interface/utun[0-9]+/IPv4" as CFString
        let ipv6Pattern = "State:/Network/Interface/utun[0-9]+/IPv6" as CFString
        let ipv4Keys = (SCDynamicStoreCopyKeyList(store, ipv4Pattern) as? [String]) ?? []
        let ipv6Keys = (SCDynamicStoreCopyKeyList(store, ipv6Pattern) as? [String]) ?? []
        let allKeys = Set(ipv4Keys + ipv6Keys)
        handleStoreChanges(Array(allKeys))
    }

    private func handleStoreChanges(_ changedKeys: [String]) {
        // Called only on monitorQueue (SCDynamicStore dispatches there).
        guard let store = lifecycleBox.withLockedValue({ $0.store }) else { return }

        // Group changed keys by interface name. A single SCDynamicStore notification
        // can include multiple keys (IPv4 + IPv6 for the same utun, for example).
        var perInterface: [String: UtunRawObservation] = [:]
        for key in changedKeys {
            guard let interfaceName = Self.utunNameFromKey(key) else { continue }
            var observation = perInterface[interfaceName] ?? UtunRawObservation()

            let ipv4Key = "State:/Network/Interface/\(interfaceName)/IPv4" as CFString
            let ipv6Key = "State:/Network/Interface/\(interfaceName)/IPv6" as CFString

            // Read fresh values from the store rather than trying to parse the
            // changedKeys callback payload — Apple's API delivers only the keys
            // that changed, not the new values.
            let ipv4Dict = SCDynamicStoreCopyValue(store, ipv4Key) as? [String: Any]
            let ipv6Dict = SCDynamicStoreCopyValue(store, ipv6Key) as? [String: Any]

            observation.ipv4Present = ipv4Dict != nil
            observation.hasIPv4Address = !((ipv4Dict?["Addresses"] as? [String])?.isEmpty ?? true)
            observation.ipv6Present = ipv6Dict != nil

            perInterface[interfaceName] = observation
        }

        guard !perInterface.isEmpty else { return }

        // Filter out utuns that have never had IPv4 — those are Apple service
        // utuns (cloud relay, FaceTime audio bridge, AWDL, etc.) that get
        // assigned IPv6 link-local but never an IPv4 address. They aren't
        // VPN tunnels and shouldn't drive the fused state. Once a utun has
        // been seen with IPv4 (production VPN), the fuser tracks it for the
        // rest of the lifecycle so subsequent IPv4-loss notifications
        // properly trigger the flap path.
        for (name, observation) in perInterface
        where observation.ipv4Present || fuser.knowsAbout(interfaceName: name) {
            // If this interface had a pending min-visible timer and the
            // observation is "fully connected", that means the link recovered
            // before the debounce window expired. Cancel the timer up-front;
            // applyObservation will return .noChange (silent recovery) and we
            // never want a stale min-visible firing after the recovery.
            if observation.isFullyConnected, let pending = minVisibleWorkItems[name] {
                pending.cancel()
                minVisibleWorkItems.removeValue(forKey: name)
            }
            let decision = fuser.applyObservation(interfaceName: name, observation: observation)
            applyFuserDecision(decision)
        }
    }

    /// Translate the fuser's pure decision into queue/timer/callback side effects.
    /// Called only on `monitorQueue`.
    private func applyFuserDecision(_ decision: VPNStateFuser.Decision) {
        let callback = onChangeBox.withLockedValue { $0 }
        switch decision {
        case .noChange:
            return
        case .emit(let state):
            // Cancel any pending grace timer — a non-reasserting state supersedes it.
            graceWorkItem?.cancel()
            graceWorkItem = nil
            callback?(state)
        case .emitAndStartGrace(let state, let then):
            // Fire the .reasserting transition immediately and start a timer that
            // will fire `then` (typically `.disconnected(.networkLost)`) if grace expires.
            // Read graceSeconds fresh from the provider so a Settings change
            // since the last flap takes effect on this transition.
            graceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Bail if stop() has cleared `started` since this work was
                // scheduled. The async cancel block in stop() runs on this
                // same queue but is FIFO-ordered against the asyncAfter
                // delivery — if the timer's deadline arrived between stop()
                // submitting the cancel block and the cancel block actually
                // running, the work item would otherwise emit a state to a
                // consumer that has already torn down. Mirrors the
                // `lifecycleBox.store` guard in `handleStoreChanges`.
                guard self.lifecycleBox.withLockedValue({ $0.started }) else { return }
                // Only fire if we're still in the reasserting state. A recovery
                // would have cancelled this work item before it ran.
                self.fuser.markGraceExpired()
                callback?(then)
            }
            graceWorkItem = work
            monitorQueue.asyncAfter(deadline: .now() + graceSecondsProvider(), execute: work)
            callback?(state)
        case .startMinVisibleTimer(let interfaceName):
            // Phase 6 (revised): min-visible debounce. Don't emit anything yet —
            // the fused state didn't change (utun is still .connected from the
            // orchestrator's POV). Start a per-interface timer; if it fires
            // before another observation supersedes it, commit the flap. Read
            // the duration fresh from the provider on every link-down so a
            // Settings change applies to the next flap.
            let minVisibleSeconds = minVisibleSecondsProvider()
            if minVisibleSeconds <= 0 {
                // Debounce disabled — commit the flap immediately. Mirrors the
                // pre-revision behavior where every link-inactive triggered a
                // .reasserting straight away.
                let nextDecision = fuser.markMinVisibleExpired(interfaceName: interfaceName)
                applyFuserDecision(nextDecision)
                return
            }
            // Cancel any pre-existing timer for this interface (shouldn't normally
            // happen — applyObservation cancels on recovery — but defensive).
            minVisibleWorkItems[interfaceName]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Same lifecycle guard as the grace work item — see comment
                // above. Without this, a min-visible timer firing in the
                // brief window between stop() submitting its cancel block
                // and the queue picking it up would commit a flap (emitting
                // `.reasserting`) for a torn-down monitor.
                guard self.lifecycleBox.withLockedValue({ $0.started }) else { return }
                self.minVisibleWorkItems.removeValue(forKey: interfaceName)
                let nextDecision = self.fuser.markMinVisibleExpired(interfaceName: interfaceName)
                self.applyFuserDecision(nextDecision)
            }
            minVisibleWorkItems[interfaceName] = work
            monitorQueue.asyncAfter(deadline: .now() + minVisibleSeconds, execute: work)
        }
    }

    /// Extract the utun interface name (e.g. "utun0") from a dynamic store key.
    /// Returns nil if the key doesn't match the expected utun pattern.
    static func utunNameFromKey(_ key: String) -> String? {
        // Keys look like "State:/Network/Interface/utun0/Link" or
        // "State:/Network/Interface/utun0/IPv4". Extract the second-to-last segment.
        let parts = key.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let candidate = String(parts[parts.count - 2])
        guard candidate.hasPrefix("utun"),
              candidate.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        return candidate
    }
}

