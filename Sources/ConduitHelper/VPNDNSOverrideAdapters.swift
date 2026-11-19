// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared
import SystemConfiguration

/// Root only, and only the helper's one thread uses it.
final class SCDynamicStoreVPNDNSStore: VPNDNSStore {
    private let store: SCDynamicStore?

    init() {
        store = SCDynamicStoreCreate(nil, "io.github.srps.Conduit.Helper.vpn-dns-override" as CFString, nil, nil)
        if store == nil {
            HelperLog.error("vpn-dns-override: SCDynamicStoreCreate failed: \(Self.lastError)")
        }
    }

    private static func dnsKey(_ service: String) -> CFString {
        "State:/Network/Service/\(service)/DNS" as CFString
    }

    private static func ipv4Key(_ service: String) -> CFString {
        "State:/Network/Service/\(service)/IPv4" as CFString
    }

    private func copy(_ key: CFString) -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, key) as? [String: Any]
    }

    func dns(service: String) -> [String: VPNDNSValue]? {
        guard let raw = copy(Self.dnsKey(service)) else { return nil }
        var value: [String: VPNDNSValue] = [:]
        for (field, item) in raw {
            guard let converted = Self.value(item) else {
                // Absent, so nothing is written over a field this type could not write back.
                // The field name is the client's schema, not a value, so it may be logged.
                HelperLog.warning("vpn-dns-override: \(HelperAudit.safe(service)) DNS field \(HelperAudit.safe(field)) has a shape the helper cannot write back; treating the key as absent")
                return nil
            }
            value[field] = converted
        }
        return value
    }

    func ipv4Exists(service: String) -> Bool {
        copy(Self.ipv4Key(service)) != nil
    }

    func overridesPrimary(service: String) -> Bool {
        (copy(Self.ipv4Key(service))?["OverridePrimary"] as? NSNumber)?.intValue == 1
    }

    func primaryService() -> String? {
        copy("State:/Network/Global/IPv4" as CFString)?["PrimaryService"] as? String
    }

    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool {
        guard let store else { return false }
        let dictionary = value.mapValues(Self.propertyListValue) as NSDictionary
        guard SCDynamicStoreSetValue(store, Self.dnsKey(service), dictionary) else {
            HelperLog.error("vpn-dns-override: SCDynamicStoreSetValue \(HelperAudit.safe(service)) DNS failed: \(Self.lastError)")
            return false
        }
        return true
    }

    private static func value(_ item: Any) -> VPNDNSValue? {
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

    private static func propertyListValue(_ value: VPNDNSValue) -> Any {
        switch value {
        case .string(let string): return string as NSString
        case .number(let number): return NSNumber(value: number)
        case .bool(let bool): return bool ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        case .strings(let strings): return strings as NSArray
        case .numbers(let numbers): return numbers.map { NSNumber(value: $0) } as NSArray
        }
    }

    private static var lastError: String {
        String(cString: SCErrorString(SCError()))
    }
}

struct RelayForwarderProbe: VPNDNSForwarderProbe {
    let relay: () -> UDPRelay?
    let tcpRelay: () -> TCPRelay?

    func tcpListening() -> Bool {
        tcpRelay()?.isRunning == true
    }

    func probe() -> VPNDNSProbeVerdict {
        guard let relay = relay() else { return .notRunning }
        do {
            switch try relay.forwarderProbe() {
            case .notRunning: return .notRunning
            case .relaying(_, .answered): return .answered
            case .relaying(_, .refused): return .refused
            case .relaying(_, .silent): return .silent
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
