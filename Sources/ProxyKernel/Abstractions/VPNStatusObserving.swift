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
    /// isolation context (typically `@MainActor` for orchestrator integration).
    func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void)

    /// Begin observing. Idempotent — calling twice without an intervening
    /// `stop()` is a no-op.
    func start()

    /// Stop observing and release any kernel resources (SCDynamicStore handles,
    /// timers). Idempotent.
    func stop()
}

/// Test/sim injection point. Drives the orchestrator's VPN-state plumbing
/// without involving SCDynamicStore. Use `emit(_:)` to feed synthetic
/// `VPNObservedState` events; the consumer's `onChange` closure fires
/// synchronously on the calling thread.
package final class FakeVPNStatusObserver: VPNStatusObserving, @unchecked Sendable {
    private let onChangeBox = NIOLockedValueBox<(@Sendable (VPNObservedState) -> Void)?>(nil)
    private let startedBox = NIOLockedValueBox<Bool>(false)

    package init() {}

    package func setOnChange(_ onChange: @Sendable @escaping (VPNObservedState) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

    package func start() {
        startedBox.withLockedValue { $0 = true }
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
}
