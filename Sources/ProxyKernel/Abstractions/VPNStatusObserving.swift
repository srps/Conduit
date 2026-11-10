// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Producer interface for `VPNObservedState` events. Production implementation
/// is `VPNStatusMonitor`; `FakeVPNStatusObserver` is the test/sim injection
/// point. AGENTS.md "always route side effects behind a protocol" — this is
/// what lets `pm-sim` exercise the orchestrator transition table without
/// touching the kernel's SCDynamicStore.
package protocol VPNStatusObserving: AnyObject, Sendable {
    /// Set by the consumer (`AppState`) before `start()`. Implementations may
    /// invoke this on any queue; consumers are expected to hop to the right
    /// isolation context (`@RuntimeActor` for orchestrator integration).
    func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void)

    /// Begin observing. Idempotent — calling twice without an intervening
    /// `stop()` is a no-op.
    func start()

    /// Stop observing and release any kernel resources (SCDynamicStore handles,
    /// timers). Idempotent.
    func stop()

    /// The utun carrying the observer's current `.connected` verdict, or nil
    /// when the state is anything else or the observer cannot name one.
    /// Consumers read it inside their `onChange` handler, where it describes
    /// the state just delivered. Observers with no interface to name (the
    /// fake, a path-monitor fallback) take the default.
    var connectedInterfaceName: String? { get }

    /// Every utun the observer has not declared gone, flapping ones included,
    /// in name order. Read inside `onChange`, like `connectedInterfaceName`.
    var liveInterfaceNames: [String] { get }
}

extension VPNStatusObserving {
    package var connectedInterfaceName: String? { nil }
    package var liveInterfaceNames: [String] { [] }
}

/// Test/sim injection point. Drives the orchestrator's VPN-state plumbing
/// without involving SCDynamicStore. Use `emit(_:)` to feed synthetic
/// `VPNObservedState` events; the consumer's `onChange` closure fires
/// synchronously on the calling thread.
package final class FakeVPNStatusObserver: VPNStatusObserving, @unchecked Sendable {
    private let onChangeBox = NIOLockedValueBox<(@Sendable (VPNObservedState) -> Void)?>(nil)
    private let startedBox = NIOLockedValueBox<Bool>(false)
    private let interfaceBox = NIOLockedValueBox<String?>(nil)
    private let liveInterfacesBox = NIOLockedValueBox<[String]>([])
    private let primedBox = NIOLockedValueBox<VPNObservedState?>(nil)

    package init() {}

    /// Settable so a test can name the tunnel behind a `.connected` it is
    /// about to emit, and change it right after to stand in for a later
    /// transition's refresh.
    package var connectedInterfaceName: String? {
        get { interfaceBox.withLockedValue { $0 } }
        set { interfaceBox.withLockedValue { $0 = newValue } }
    }

    /// Settable so a test can name the live tunnels behind the state it is
    /// about to emit.
    package var liveInterfaceNames: [String] {
        get { liveInterfacesBox.withLockedValue { $0 } }
        set { liveInterfacesBox.withLockedValue { $0 = newValue } }
    }

    package func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

    /// The state `start()` reports, the way the production monitor reads the
    /// current tunnels when it starts. `nil`, the default, reports nothing.
    package var primedState: VPNObservedState? {
        get { primedBox.withLockedValue { $0 } }
        set { primedBox.withLockedValue { $0 = newValue } }
    }

    /// Delivers `primedState`, if any, on each stopped-to-started transition,
    /// on the calling thread. A repeated `start()` delivers nothing.
    package func start() {
        let wasStarted = startedBox.withLockedValue { started -> Bool in
            defer { started = true }
            return started
        }
        guard !wasStarted, let primed = primedState else { return }
        onChangeBox.withLockedValue { $0 }?(primed)
    }

    package func stop() {
        startedBox.withLockedValue { $0 = false }
    }

    /// Drive a synthetic state event. Only delivered if `start()` was called and
    /// `stop()` has not been called since — mirrors the production observer's
    /// gating so tests catch lifecycle bugs early. The closure runs on the
    /// calling thread.
    package func emit(_ state: VPNObservedState) {
        guard startedBox.withLockedValue({ $0 }) else { return }
        let callback = onChangeBox.withLockedValue { $0 }
        callback?(state)
    }
    /// Captures a callback already in flight when observation later stops.
    package func pendingDelivery(_ state: VPNObservedState) -> (@Sendable () -> Void)? {
        guard startedBox.withLockedValue({ $0 }),
              let callback = onChangeBox.withLockedValue({ $0 }) else { return nil }
        return { callback(state) }
    }

}
