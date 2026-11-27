// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// `LiveSplitDNSPolicy` between its two observers and the owner (`docs/design-live-vpn-split-dns.md`).
///
/// Readings are not interchangeable: the policy folds each one into the set it holds through a flap, so a reading
/// that is skipped changes the result. Each reading is therefore applied here, on the thread that delivers it and
/// in the order it arrives, and so is each VPN report the owner admits. What waits for the owner is the policy's
/// output, which is whole: the newest one replaces any the owner has not taken, so a burst of readings holds one
/// value however long it is.
package final class LiveSplitDNSDetection: @unchecked Sendable {
    /// The detected set and the input that last changed it.
    package struct DetectedSet: Hashable, Sendable {
        package let rules: [SplitDNSRule]
        package let display: DetectedSplitDNSDisplay
        package let reason: DetectedSplitDNSChangeReason
    }

    /// What the owner has not applied or reported yet.
    package struct Pending: Hashable, Sendable {
        /// The newest set, when an input changed it since the last take. It may equal the set the owner applied
        /// last, when a burst left and came back.
        package let set: DetectedSet?
        /// The rejections in `LiveSplitDNSPolicy.ignored` now that were not in it at the last take.
        package let ignored: Set<PushedResolverRejection>
        /// What the readings since the last take said about the store, in arrival order: the newest failure
        /// that differed from the reading before it, and the newest recovery, at most one of each.
        package let store: [StoreEvent]
    }

    /// A change in whether the observer can read the store (decision 0048).
    package enum StoreEvent: Hashable, Sendable {
        /// A reading failed at this step, on this attempt in a row.
        case failed(PushedResolverReading.Failure, attempt: Int)
        /// A reading succeeded after this many failed attempts.
        case recovered(attempts: Int)

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    private struct State {
        var running = false
        var gate = SplitDNSVPNGate()
        var liveInterfaces: Set<String> = []
        var policy: LiveSplitDNSPolicy
        var lastFailure: StoreEvent?
        var unappliedSet: DetectedSet?
        var reportedIgnored: Set<PushedResolverRejection> = []
        var unreportedStore: [StoreEvent] = []
    }

    private let lock = NSLock()
    private var state: State

    package init(limits: SplitDNSLimits) {
        state = State(policy: LiveSplitDNSPolicy(limits: limits))
    }

    /// Readings count from now on. Call before the observer starts, so its first reading is taken.
    package func start() {
        lock.withLock { state.running = true }
    }

    /// Drops the last reading and the held set, and leaves the empty set for the owner to apply. A store event the
    /// owner has not taken stays for that take, so a failure that arrived just before the stop is still reported. A
    /// reading that arrives after this is dropped: the next start reads the store again. The VPN verdict stays: a
    /// running VPN observer reports only a change and so never repeats it. It goes when that observer stops
    /// (`vpnObserverStopped`).
    package func stop() {
        lock.withLock {
            state.running = false
            state.policy = LiveSplitDNSPolicy(limits: state.policy.limits)
            state.lastFailure = nil
            state.reportedIgnored = []
            state.unappliedSet = DetectedSet(rules: [], display: state.policy.display, reason: .detectionOff)
        }
    }

    /// A reading of the pushed resolvers, from any thread. A reading with a `failure` leaves nothing in use.
    package func receive(_ reading: PushedResolverReading) {
        lock.withLock {
            guard state.running else { return }
            let failure = reading.failure.map { StoreEvent.failed($0, attempt: reading.failedAttempts) }
            if let failure, failure != state.lastFailure {
                queue(failure)
            } else if failure == nil, reading.failedAttempts > 0 {
                queue(.recovered(attempts: reading.failedAttempts))
            }
            state.lastFailure = failure
            update(reading: reading, reason: reading.failure == nil ? .pushed : .detectionFailed)
        }
    }

    /// A VPN report the gate admitted: the gate after it, and the live tunnels the observer named beside it. The
    /// policy gets its last reading back, because a verdict changes which of those resolvers are in use, not what
    /// the store holds.
    package func report(gate: SplitDNSVPNGate, liveInterfaces: Set<String>) {
        lock.withLock {
            state.gate = gate
            state.liveInterfaces = liveInterfaces
            guard state.running else { return }
            let reason: DetectedSplitDNSChangeReason = switch gate.lastVPNState {
            case .connected: .vpnConnected
            case .unknown: .vpnUnknown
            case .disconnected: .vpnDisconnected
            case .reasserting: .flapHeld
            }
            update(reading: state.policy.lastReading, reason: reason)
        }
    }

    /// The VPN observer stopped, so its verdict and live tunnels go back to the cold start's: `.unknown`, which
    /// withholds the set until its next session reports (decision 0048).
    package func vpnObserverStopped() {
        lock.withLock {
            state.gate = SplitDNSVPNGate()
            state.liveInterfaces = []
            guard state.running else { return }
            update(reading: state.policy.lastReading, reason: .vpnObserverStopped)
        }
    }

    package var lastReading: PushedResolverReading {
        lock.withLock { state.policy.lastReading }
    }

    /// Everything not yet taken, or nil when there is nothing. Taking it is the owner's promise to apply it.
    package func take() -> Pending? {
        lock.withLock {
            let ignored = state.policy.ignored.subtracting(state.reportedIgnored)
            let pending = Pending(set: state.unappliedSet, ignored: ignored, store: state.unreportedStore)
            state.reportedIgnored = state.policy.ignored
            state.unappliedSet = nil
            state.unreportedStore = []
            return pending.set == nil && ignored.isEmpty && pending.store.isEmpty ? nil : pending
        }
    }

    /// Keeps the newest event of each kind, in arrival order. Call with the lock held.
    private func queue(_ event: StoreEvent) {
        state.unreportedStore.removeAll { $0.isFailure == event.isFailure }
        state.unreportedStore.append(event)
    }

    /// Call with the lock held.
    private func update(reading: PushedResolverReading, reason: DetectedSplitDNSChangeReason) {
        guard state.policy.update(gate: state.gate, liveInterfaces: state.liveInterfaces, reading: reading) else { return }
        state.unappliedSet = DetectedSet(rules: state.policy.detectedRules, display: state.policy.display, reason: reason)
    }
}
