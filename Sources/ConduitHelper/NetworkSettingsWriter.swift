// SPDX-License-Identifier: Apache-2.0
import Foundation
import SystemConfiguration
import ConduitShared

/// The only privileged location writer. Never selects a location or invokes service-name commands.
enum NetworkSettingsWriter {
    static func run(_ request: NetworkSettingsRequest) throws {
        try request.validate()
        guard let preferences = SCPreferencesCreate(nil, "Conduit scoped network settings" as CFString, nil),
              SCPreferencesLock(preferences, false) else { throw NetworkSettingsError.unavailable }
        defer {
            if !SCPreferencesUnlock(preferences) { HelperLog.warning("Could not unlock network preferences") }
        }
        SCPreferencesSynchronize(preferences)
        guard let set = SCNetworkSetCopy(preferences, request.locationID as CFString),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService],
              let service = services.first(where: { SCNetworkServiceGetServiceID($0) as String? == request.serviceID }) else {
            throw NetworkSettingsError.changed
        }
        if request.requireActive {
            guard let active = SCNetworkSetCopyCurrent(preferences),
                  SCNetworkSetGetSetID(active) as String? == request.locationID else { throw NetworkSettingsError.changed }
        }
        let type = request.kind == .proxies ? kSCNetworkProtocolTypeProxies : kSCNetworkProtocolTypeDNS
        guard let proto = SCNetworkServiceCopyProtocol(service, type) else { throw NetworkSettingsError.changed }
        let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
        let replacement = try NetworkSettingsFields.merging(request, into: current)
        guard SCNetworkProtocolSetConfiguration(proto, replacement as CFDictionary),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw NetworkSettingsError.unavailable
        }
    }
}
