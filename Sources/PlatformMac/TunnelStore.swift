// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import ProxyKernel
import SystemConfiguration

extension TunnelSnapshot {
    /// Store keys a snapshot is built from, as `SCDynamicStore` patterns. The
    /// service ID is `[^/]+`, never UUID-only.
    package static let keyPatterns = [
        "State:/Network/Interface/utun[0-9]+/IPv4",
        "State:/Network/Interface/utun[0-9]+/IPv6",
        PushedResolverReading.ipv4KeyPattern,
        PushedResolverReading.ipv6KeyPattern,
    ]

    private static let interfacePrefix = "State:/Network/Interface/"
    private static let servicePrefix = "State:/Network/Service/"

    /// Parses the store's `State:/Network/Interface/<utun>/IPv4|IPv6` and
    /// `State:/Network/Service/<id>/IPv4|IPv6` dictionaries, keyed by store
    /// key as `SCDynamicStoreCopyMultiple` returns them. Other keys, and
    /// services on an interface that is not a `utun`, are ignored.
    ///
    /// A value of the wrong type reads as absent, as `VPNStatusMonitor` reads
    /// it: a key that is no dictionary is no key, and an `Addresses` that is
    /// not a list of strings lists none.
    package static func parse(store: [String: Any]) -> TunnelSnapshot {
        struct Entry {
            var hasInterfaceKey = false
            var ipv4Addresses: [String] = []
            var hasRoutableIPv6 = false
            var serviceIDs: [String] = []
            var overridesPrimary = false
        }
        var entries: [String: Entry] = [:]

        for (key, value) in store {
            guard let dictionary = value as? [String: Any], let family = Family(key: key) else { continue }
            if let interface = middle(of: key, after: interfacePrefix, family: family) {
                guard PushedResolverReading.isTunnelInterface(interface) else { continue }
                var entry = entries[interface] ?? Entry()
                entry.hasInterfaceKey = true
                let addresses = dictionary["Addresses"] as? [String] ?? []
                switch family {
                case .ipv4: entry.ipv4Addresses = addresses
                case .ipv6: entry.hasRoutableIPv6 = addresses.contains(where: isRoutableIPv6)
                }
                entries[interface] = entry
            } else if let serviceID = middle(of: key, after: servicePrefix, family: family) {
                guard let interface = dictionary["InterfaceName"] as? String,
                      PushedResolverReading.isTunnelInterface(interface) else { continue }
                var entry = entries[interface] ?? Entry()
                if !entry.serviceIDs.contains(serviceID) { entry.serviceIDs.append(serviceID) }
                if family == .ipv4, (dictionary["OverridePrimary"] as? NSNumber)?.boolValue == true {
                    entry.overridesPrimary = true
                }
                entries[interface] = entry
            }
        }

        return TunnelSnapshot(tunnels: entries.map { interface, entry in
            Tunnel(
                interface: interface,
                hasInterfaceKey: entry.hasInterfaceKey,
                ipv4Addresses: entry.ipv4Addresses,
                hasRoutableIPv6: entry.hasRoutableIPv6,
                serviceID: entry.serviceIDs.min(),
                overridesPrimary: entry.overridesPrimary
            )
        })
    }

    private enum Family: String {
        case ipv4 = "/IPv4"
        case ipv6 = "/IPv6"

        init?(key: String) {
            guard let family = [Family.ipv4, .ipv6].first(where: { key.hasSuffix($0.rawValue) }) else { return nil }
            self = family
        }
    }

    /// The one path segment between `prefix` and the family suffix.
    private static func middle(of key: String, after prefix: String, family: Family) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let segment = key.dropFirst(prefix.count).dropLast(family.rawValue.count)
        return segment.isEmpty || segment.contains("/") ? nil : String(segment)
    }

    /// A unicast IPv6 literal that is not link-local, loopback or
    /// unspecified. A zone index is ignored.
    package static func isRoutableIPv6(_ address: String) -> Bool {
        var parsed = in6_addr()
        let literal = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        guard inet_pton(AF_INET6, literal, &parsed) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &parsed) { Array($0) }
        let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        let isMulticast = bytes[0] == 0xff
        let isLoopbackOrUnspecified = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] <= 1
        return !isLinkLocal && !isMulticast && !isLoopbackOrUnspecified
    }
}

/// A live subscription to store changes. Cancelling it ends the store session
/// it opened; a second cancel does nothing.
package protocol TunnelStoreSubscription: AnyObject, Sendable {
    func cancel()
}

/// The dynamic store as VPN detection uses it: whole readings, and a signal
/// that something changed. The production store is `SystemTunnelStore`;
/// `FakeTunnelStore` in `PlatformFakes.swift` is the injection point.
package protocol TunnelStoreReading: AnyObject, Sendable {
    /// Every tunnel key, read in one pass.
    func read() -> TunnelReading

    /// Calls `onChange` on `queue` after a tunnel key changes. The call says
    /// only that the store moved, so the subscriber reads it again; several
    /// changes may arrive as one call. A call already running when the
    /// subscription is cancelled still finishes.
    func subscribe(
        queue: DispatchQueue, onChange: @escaping @Sendable () -> Void
    ) -> Result<any TunnelStoreSubscription, TunnelReading.Failure>
}

/// `TunnelStoreReading` over `SCDynamicStore`, read-only.
package final class SystemTunnelStore: TunnelStoreReading, @unchecked Sendable {
    private let lock = NSLock()
    /// The session `read()` uses, opened on first use and kept.
    private var readSession: SCDynamicStore?
    private let setNotificationKeys: @Sendable (SCDynamicStore, CFArray) -> Bool
    private let setDispatchQueue: @Sendable (SCDynamicStore, DispatchQueue?) -> Bool

    /// The two subscription calls default to `SCDynamicStoreSetNotificationKeys`
    /// and `SCDynamicStoreSetDispatchQueue`; a test injects failing ones.
    package init(
        setNotificationKeys: @Sendable @escaping (SCDynamicStore, CFArray) -> Bool = {
            SCDynamicStoreSetNotificationKeys($0, nil, $1)
        },
        setDispatchQueue: @Sendable @escaping (SCDynamicStore, DispatchQueue?) -> Bool = {
            SCDynamicStoreSetDispatchQueue($0, $1)
        }
    ) {
        self.setNotificationKeys = setNotificationKeys
        self.setDispatchQueue = setDispatchQueue
    }

    package func read() -> TunnelReading {
        switch readKeys() {
        case .success(let keys): .snapshot(TunnelSnapshot.parse(store: keys))
        case .failure(let failure): .failed(failure)
        }
    }

    /// The dictionaries `read()` parses, keyed by store key.
    private func readKeys() -> Result<[String: Any], TunnelReading.Failure> {
        lock.withLock {
            guard let session = readSession ?? SCDynamicStoreCreate(
                kCFAllocatorDefault, "io.github.srps.Conduit.TunnelStore.read" as CFString, nil, nil
            ) else {
                return .failure(.storeCreate)
            }
            readSession = session
            guard let values = SCDynamicStoreCopyMultiple(
                session, nil, TunnelSnapshot.keyPatterns as CFArray
            ) as? [String: Any] else {
                return .failure(.storeRead)
            }
            return .success(values)
        }
    }

    package func subscribe(
        queue: DispatchQueue, onChange: @escaping @Sendable () -> Void
    ) -> Result<any TunnelStoreSubscription, TunnelReading.Failure> {
        // The store retains and releases the handler through its context, so
        // the handler lives exactly as long as a callback can reach it.
        let handler = ChangeHandler(onChange)
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<ChangeHandler>.fromOpaque($0).retain().toOpaque()) },
            release: { Unmanaged<ChangeHandler>.fromOpaque($0).release() },
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<ChangeHandler>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let session = SCDynamicStoreCreate(
            kCFAllocatorDefault, "io.github.srps.Conduit.TunnelStore.watch" as CFString, callback, &context
        ) else {
            return .failure(.storeCreate)
        }
        guard setNotificationKeys(session, TunnelSnapshot.keyPatterns as CFArray),
              setDispatchQueue(session, queue) else {
            // No queue is attached, and releasing the session drops its keys.
            return .failure(.storeSubscribe)
        }
        return .success(Subscription(session: session, setDispatchQueue: setDispatchQueue))
    }

    private final class ChangeHandler {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private final class Subscription: TunnelStoreSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var session: SCDynamicStore?
        private let setDispatchQueue: @Sendable (SCDynamicStore, DispatchQueue?) -> Bool

        init(session: SCDynamicStore, setDispatchQueue: @escaping @Sendable (SCDynamicStore, DispatchQueue?) -> Bool) {
            self.session = session
            self.setDispatchQueue = setDispatchQueue
        }

        deinit { cancel() }

        func cancel() {
            let detached = lock.withLock { () -> SCDynamicStore? in
                defer { session = nil }
                return session
            }
            // Detaching the queue stops delivery; releasing the session then
            // ends it, whatever the detach returned.
            if let detached { _ = setDispatchQueue(detached, nil) }
        }
    }
}
