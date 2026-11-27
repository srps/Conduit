// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import HelperSupport
import SystemConfiguration

/// The helper's own store session. Root only. The helper's loop calls it, and the expiry watchdog calls `removeOwnKey`;
/// the session is reached only under `lock`.
final class SCDynamicStoreVPNDNSStore: VPNDNSStore, @unchecked Sendable {
    private static var ownKey: CFString { "State:/Network/Service/\(HelperConstants.vpnDNSOverrideServiceID)/DNS" as CFString }
    private static let notificationPatterns = ["State:/Network/Service/[^/]+/DNS", "State:/Network/Service/[^/]+/IPv4"]
    private static let notificationKeys = ["State:/Network/Global/IPv4"]

    private let queue = DispatchQueue(label: "io.github.srps.Conduit.Helper.vpn-dns-override.store")
    private let changed: @Sendable () -> Void
    private let lock = NSLock()
    private var _store: SCDynamicStore?

    /// `changed` runs on a private queue for every notification, the store's own key's included.
    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        open()
    }

    private func open() {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let options = [kSCDynamicStoreUseSessionKeys: kCFBooleanTrue] as CFDictionary
        guard let created = SCDynamicStoreCreateWithOptions(
            nil, "io.github.srps.Conduit.Helper.vpn-dns-override" as CFString, options,
            { _, _, info in
                guard let info else { return }
                Unmanaged<SCDynamicStoreVPNDNSStore>.fromOpaque(info).takeUnretainedValue().changed()
            },
            &context
        ) else {
            HelperLog.error("vpn-dns-override: SCDynamicStoreCreateWithOptions failed: \(Self.lastError)")
            return
        }
        if !SCDynamicStoreSetNotificationKeys(created, Self.notificationKeys as CFArray, Self.notificationPatterns as CFArray) {
            HelperLog.error("vpn-dns-override: notification keys not set: \(Self.lastError); only the ticks re-read the store")
        }
        if !SCDynamicStoreSetDispatchQueue(created, queue) {
            HelperLog.error("vpn-dns-override: notifications not scheduled: \(Self.lastError); only the ticks re-read the store")
        }
        lock.withLock { _store = created }
    }

    func closeSession() {
        let closing = lock.withLock { () -> SCDynamicStore? in
            defer { _store = nil }
            return _store
        }
        if let closing { SCDynamicStoreSetDispatchQueue(closing, nil) }
        open()
    }

    /// Each call on the session, and the error it leaves for this thread, under the lock.
    private func withStore<T>(orElse fallback: T, _ body: (SCDynamicStore) -> T) -> T {
        lock.withLock { _store.map(body) ?? fallback }
    }

    private func copy(_ key: CFString) -> [String: Any]? {
        withStore(orElse: nil) { SCDynamicStoreCopyValue($0, key) as? [String: Any] }
    }

    func dns(service: String) -> VPNDNSRead {
        withStore(orElse: .unreadable("no session")) { store in
            guard let copied = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DNS" as CFString) else {
                let status = SCError()
                return status == kSCStatusNoKey ? .absent : .unreadable(String(cString: SCErrorString(status)))
            }
            guard let raw = copied as? [String: Any] else { return .unreadable("not a dictionary") }
            return .value(raw.compactMapValues(VPNDNSPropertyList.value))
        }
    }

    func overridesPrimary(service: String) -> Bool {
        (copy("State:/Network/Service/\(service)/IPv4" as CFString)?["OverridePrimary"] as? NSNumber)?.intValue == 1
    }

    func primaryService() -> String? {
        copy("State:/Network/Global/IPv4" as CFString)?["PrimaryService"] as? String
    }

    func ownKeyState() -> VPNDNSOwnKeyState {
        withStore(orElse: .unreadable("no session")) { store in
            if SCDynamicStoreCopyValue(store, Self.ownKey) != nil { return .present }
            let status = SCError()
            return status == kSCStatusNoKey ? .absent : .unreadable(String(cString: SCErrorString(status)))
        }
    }

    func publishOwnKey(_ value: [String: VPNDNSValue]) -> VPNDNSPublishResult {
        let dictionary = value.mapValues(VPNDNSPropertyList.object) as NSDictionary
        return withStore(orElse: .failed) { store in
            if SCDynamicStoreAddTemporaryValue(store, Self.ownKey, dictionary) { return .added }
            let status = SCError()
            if status == kSCStatusKeyExists { return .collision }
            HelperLog.error("vpn-dns-override: SCDynamicStoreAddTemporaryValue failed: \(String(cString: SCErrorString(status)))")
            return .failed
        }
    }

    /// Also called by the expiry watchdog, off the helper's loop.
    func removeOwnKey() -> Bool {
        withStore(orElse: false) { store in
            guard SCDynamicStoreRemoveValue(store, Self.ownKey) else {
                if SCError() == kSCStatusNoKey { return true }
                HelperLog.error("vpn-dns-override: SCDynamicStoreRemoveValue failed: \(Self.lastError)")
                return false
            }
            return true
        }
    }

    fileprivate static var lastError: String {
        String(cString: SCErrorString(SCError()))
    }
}

/// Withdraws the published key at its deadline even while a command holds the helper's loop; the loop then sees the key
/// gone and reports the withdrawal itself.
enum VPNDNSOverrideWatchdog {
    static let intervalMilliseconds: UInt32 = 250

    static func start(expiry: VPNDNSOverrideExpiry, store: SCDynamicStoreVPNDNSStore) {
        let thread = Thread {
            while true {
                usleep(intervalMilliseconds * 1_000)
                let removed = expiry.expire(now: DispatchTime.now().uptimeNanoseconds) { store.removeOwnKey() }
                switch removed {
                case true?:
                    HelperLog.warning("vpn-dns-override expired: no confirmed answer within "
                        + "\(VPNDNSOverridePublisher.unverifiedSecondsToWithdraw) s while the helper was busy; key removed")
                case false?:
                    HelperLog.error("vpn-dns-override expired: the store refused the removal; the loop retries it")
                case nil:
                    break
                }
            }
        }
        thread.name = "vpn-dns-override-expiry"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// The one write a VPN client's key ever gets: the legacy restore at start.
struct SCDynamicStoreLegacyVPNDNSStore: VPNDNSLegacyStore {
    private let store = SCDynamicStoreCreate(nil, "io.github.srps.Conduit.Helper.vpn-dns-override-legacy" as CFString, nil, nil)

    func legacyDNS(service: String) -> VPNDNSRead {
        guard let store else { return .unreadable("store: \(SCDynamicStoreVPNDNSStore.lastError)") }
        guard let copied = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DNS" as CFString) else {
            let status = SCError()
            return status == kSCStatusNoKey ? .absent : .unreadable("copy: \(String(cString: SCErrorString(status)))")
        }
        guard let raw = copied as? [String: Any] else { return .unreadable("not a dictionary") }
        var value: [String: VPNDNSValue] = [:]
        for (field, item) in raw {
            // A field this type cannot write back makes the key unreadable, so nothing is written over it.
            guard let converted = VPNDNSPropertyList.value(item) else { return .unreadable("field \(field) cannot be written back") }
            value[field] = converted
        }
        return .value(value)
    }

    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool {
        guard let store else { return false }
        let dictionary = value.mapValues(VPNDNSPropertyList.object) as NSDictionary
        guard SCDynamicStoreSetValue(store, "State:/Network/Service/\(service)/DNS" as CFString, dictionary) else {
            HelperLog.error("vpn-dns-override legacy: SCDynamicStoreSetValue failed: \(SCDynamicStoreVPNDNSStore.lastError)")
            return false
        }
        return true
    }
}

enum VPNDNSPropertyList {
    static func value(_ item: Any) -> VPNDNSValue? {
        if let string = item as? String { return .string(string) }
        if let number = item as? NSNumber { return scalar(number) }
        if let array = item as? [Any] {
            if array.isEmpty { return .strings([]) }
            if let strings = array as? [String] { return .strings(strings) }
            var numbers: [Int] = []
            for element in array {
                guard let number = element as? NSNumber, case .number(let integer)? = scalar(number) else { return nil }
                numbers.append(integer)
            }
            return .numbers(numbers)
        }
        return nil
    }

    private static func scalar(_ number: NSNumber) -> VPNDNSValue? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        guard !CFNumberIsFloatType(number) else { return nil }
        return .number(number.intValue)
    }

    static func object(_ value: VPNDNSValue) -> Any {
        switch value {
        case .string(let string): return string as NSString
        case .number(let number): return NSNumber(value: number)
        case .bool(let bool): return bool ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        case .strings(let strings): return strings as NSArray
        case .numbers(let numbers): return numbers.map { NSNumber(value: $0) } as NSArray
        }
    }
}
