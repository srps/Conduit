// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import SystemConfiguration

/// Producer of the current pushed-resolver set. Mirrors `VPNStatusObserving`
/// and `NetworkPathObserving`. The production observer is
/// `PushedResolverMonitor`; `FakePushedResolverObserver` in
/// `PlatformFakes.swift` is the injection point.
package protocol PushedResolverObserving: AnyObject, Sendable {
    /// Called with the whole current reading on every change, never a delta,
    /// on any queue; the consumer hops to its own isolation. A reading with
    /// no resolvers is valid; one with a `failure` says the store could not
    /// be created or read.
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
/// Threading follows `VPNStatusMonitor`: the store dispatches on
/// `monitorQueue`, `lastDelivered` is touched only there, and `onChange` runs
/// there.
package final class PushedResolverMonitor: PushedResolverObserving, @unchecked Sendable {
    private let monitorQueue = DispatchQueue(label: "io.github.srps.Conduit.PushedResolverMonitor")
    private let onChangeBox = NIOLockedValueBox<(@Sendable (PushedResolverReading) -> Void)?>(nil)
    private let lifecycleBox = NIOLockedValueBox<LifecycleState>(.init())
    private var lastDelivered: PushedResolverReading?

    private struct LifecycleState {
        var store: SCDynamicStore?
        var started = false
        /// The `Unmanaged` retain handed to the store's callback context,
        /// released in `stop()` once the store is detached.
        var contextOpaque: UnsafeMutableRawPointer?
    }

    private static let notificationPatterns = [
        PushedResolverReading.dnsKeyPattern,
        PushedResolverReading.ipv4KeyPattern,
        PushedResolverReading.ipv6KeyPattern,
        "State:/Network/Global/DNS",
    ]

    package init() {}

    package func setOnChange(_ onChange: @Sendable @escaping (PushedResolverReading) -> Void) {
        onChangeBox.withLockedValue { $0 = onChange }
    }

    package func start() {
        let alreadyStarted = lifecycleBox.withLockedValue { state -> Bool in
            defer { state.started = true }
            return state.started
        }
        guard !alreadyStarted else { return }
        monitorQueue.async { [weak self] in self?.installStore() }
    }

    package func stop() {
        let teardown = lifecycleBox.withLockedValue { state -> (SCDynamicStore?, UnsafeMutableRawPointer?) in
            defer { state = .init() }
            return (state.store, state.contextOpaque)
        }
        monitorQueue.async { [weak self] in self?.lastDelivered = nil }
        guard let store = teardown.0 else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        if let opaque = teardown.1 {
            Unmanaged<PushedResolverMonitor>.fromOpaque(opaque).release()
        }
    }

    /// One read of the live store with no subscription, for diagnostics.
    package static func readOnce() -> PushedResolverReading {
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault, "io.github.srps.Conduit.PushedResolverRead" as CFString, nil, nil
        ) else {
            return PushedResolverReading(failure: .storeCreate)
        }
        return read(store)
    }

    private static func read(_ store: SCDynamicStore) -> PushedResolverReading {
        let patterns = [
            PushedResolverReading.dnsKeyPattern,
            PushedResolverReading.ipv4KeyPattern,
            PushedResolverReading.ipv6KeyPattern,
        ] as CFArray
        guard let values = SCDynamicStoreCopyMultiple(store, nil, patterns) as? [String: Any] else {
            return PushedResolverReading(failure: .storeRead)
        }
        return PushedResolverReading.parse(store: values)
    }

    private func installStore() {
        guard lifecycleBox.withLockedValue({ $0.started }) else { return }
        let retained = Unmanaged.passRetained(self)
        let context = UnsafeMutableRawPointer(retained.toOpaque())
        var scContext = SCDynamicStoreContext(
            version: 0, info: context, retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { store, _, info in
            guard let info else { return }
            Unmanaged<PushedResolverMonitor>.fromOpaque(info).takeUnretainedValue().deliver(PushedResolverMonitor.read(store))
        }
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault, "io.github.srps.Conduit.PushedResolverMonitor" as CFString, callback, &scContext
        ) else {
            retained.release()
            deliver(PushedResolverReading(failure: .storeCreate))
            return
        }
        SCDynamicStoreSetNotificationKeys(store, nil, Self.notificationPatterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, monitorQueue)

        let installed = lifecycleBox.withLockedValue { state -> Bool in
            guard state.started, state.store == nil else { return false }
            state.store = store
            state.contextOpaque = context
            return true
        }
        guard installed else {
            SCDynamicStoreSetDispatchQueue(store, nil)
            retained.release()
            return
        }
        deliver(Self.read(store))
    }

    /// Runs on `monitorQueue`.
    private func deliver(_ reading: PushedResolverReading) {
        guard lifecycleBox.withLockedValue({ $0.started }), reading != lastDelivered else { return }
        lastDelivered = reading
        onChangeBox.withLockedValue { $0 }?(reading)
    }
}
