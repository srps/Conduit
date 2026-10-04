// SPDX-License-Identifier: Apache-2.0
import Foundation
import SystemConfiguration
import ConduitShared
import ProxyKernel

package struct NetworkLocationLimits: Sendable {
    package var maximumLocations = 64
    package var maximumServices = 256
    package var maximumRecords = 512
    package init(maximumLocations: Int = 64, maximumServices: Int = 256, maximumRecords: Int = 512) {
        precondition(maximumLocations > 0 && maximumServices > 0 && maximumRecords > 0)
        self.maximumLocations = maximumLocations
        self.maximumServices = maximumServices
        self.maximumRecords = maximumRecords
    }
}

package struct LocationServiceSettings: Equatable, Sendable {
    package var locationID: String
    package var serviceID: String
    package var name: String
    package var enabled: Bool
    package var proxies: [String: NetworkSettingValue]
    package var dns: [String: NetworkSettingValue]
    package var supportsProxies: Bool
    package var supportsDNS: Bool
    package var unreadableProxies: Bool
    package var unreadableDNS: Bool
    package init(locationID: String, serviceID: String, name: String, enabled: Bool,
                 proxies: [String: NetworkSettingValue], dns: [String: NetworkSettingValue],
                 supportsProxies: Bool = true, supportsDNS: Bool = true,
                 unreadableProxies: Bool = false, unreadableDNS: Bool = false) {
        self.locationID = locationID
        self.serviceID = serviceID
        self.name = name
        self.enabled = enabled
        self.proxies = proxies
        self.dns = dns
        self.supportsProxies = supportsProxies
        self.supportsDNS = supportsDNS
        self.unreadableProxies = unreadableProxies
        self.unreadableDNS = unreadableDNS
    }
    package func supports(_ kind: NetworkSettingsKind) -> Bool { kind == .proxies ? supportsProxies : supportsDNS }
    package func isUnreadable(_ kind: NetworkSettingsKind) -> Bool { kind == .proxies ? unreadableProxies : unreadableDNS }
}

package struct NetworkLocationSnapshot: Equatable, Sendable {
    package var activeLocationID: String
    package var services: [LocationServiceSettings]
    package init(activeLocationID: String, services: [LocationServiceSettings]) {
        self.activeLocationID = activeLocationID
        self.services = services
    }
}

package protocol NetworkLocationStoring: Sendable {
    func snapshot() throws -> NetworkLocationSnapshot
    func compareAndWrite(_ request: NetworkSettingsRequest) throws
}

/// Reads every set without selecting it. Mutation is delegated to the helper.
package final class SystemNetworkLocationStore: NetworkLocationStoring, @unchecked Sendable {
    private let write: @Sendable (NetworkSettingsRequest) throws -> Void
    private let limits: NetworkLocationLimits

    package init(limits: NetworkLocationLimits = .init(),
                 write: @escaping @Sendable (NetworkSettingsRequest) throws -> Void) {
        self.limits = limits
        self.write = write
    }

    package convenience init(privilegeClient: any PrivilegeClient, limits: NetworkLocationLimits = .init()) {
        self.init(limits: limits) { request in
            try privilegeClient.execute(.compareNetworkSettings, values: [request.encoded()])
        }
    }

    package func snapshot() throws -> NetworkLocationSnapshot {
        guard let preferences = SCPreferencesCreate(nil, "Conduit locations" as CFString, nil),
              let current = SCNetworkSetCopyCurrent(preferences),
              let activeID = SCNetworkSetGetSetID(current) as String?,
              let sets = SCNetworkSetCopyAll(preferences) as? [SCNetworkSet] else {
            throw NetworkSettingsError.unavailable
        }
        guard sets.count <= limits.maximumLocations else { throw NetworkSettingsError.capacityExceeded }
        var services: [LocationServiceSettings] = []
        for set in sets {
            guard let locationID = SCNetworkSetGetSetID(set) as String?,
                  let members = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
                throw NetworkSettingsError.unavailable
            }
            guard services.count + members.count <= limits.maximumServices else {
                throw NetworkSettingsError.capacityExceeded
            }
            for service in members {
                guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                    throw NetworkSettingsError.unavailable
                }
                // Protocol absence is different from an empty configuration: do not create it.
                let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
                let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
                let proxyFields = proxies.map { Self.readFields(SCNetworkProtocolGetConfiguration($0) as? [String: Any] ?? [:], kind: .proxies) }
                let dnsFields = dns.map { Self.readFields(SCNetworkProtocolGetConfiguration($0) as? [String: Any] ?? [:], kind: .dns) }
                services.append(LocationServiceSettings(
                    locationID: locationID, serviceID: serviceID,
                    name: SCNetworkServiceGetName(service) as String? ?? serviceID,
                    enabled: SCNetworkServiceGetEnabled(service),
                    proxies: proxyFields?.fields ?? [:], dns: dnsFields?.fields ?? [:],
                    supportsProxies: proxies != nil, supportsDNS: dns != nil,
                    unreadableProxies: proxyFields?.unreadable ?? false, unreadableDNS: dnsFields?.unreadable ?? false
                ))
            }
        }
        return NetworkLocationSnapshot(activeLocationID: activeID, services: services)
    }

    package func compareAndWrite(_ request: NetworkSettingsRequest) throws {
        try request.validate()
        try write(request)
    }

    package static func readFields(_ configuration: [String: Any], kind: NetworkSettingsKind) -> (fields: [String: NetworkSettingValue], unreadable: Bool) {
        do {
            let fields = try NetworkSettingsFields.project(configuration, kind: kind)
            // Invalid or credential-bearing fields never enter a snapshot or journal.
            try NetworkSettingsRequest(locationID: UUID().uuidString, serviceID: UUID().uuidString,
                                       kind: kind, expected: fields, replacement: [:], requireActive: false).validate()
            return (fields, false)
        } catch {
            // The identity remains visible, so its recovery record is retained, not treated as deleted.
            return ([:], true)
        }
    }
}
