// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

/// Shared by both hosts and both network surfaces. Never uses a service name as identity.
package final class LocationSettingsRecovery: @unchecked Sendable {
    private let store: any NetworkLocationStoring
    private let journal: PlatformStateJournal
    private let limits: NetworkLocationLimits
    private let emit: @Sendable (RuntimeEvent) -> Void
    private let operations = NSRecursiveLock()

    package init(store: any NetworkLocationStoring, journal: PlatformStateJournal,
                 limits: NetworkLocationLimits = .init(), emit: @escaping @Sendable (RuntimeEvent) -> Void) {
        self.store = store
        self.journal = journal
        self.limits = limits
        self.emit = emit
    }

    private func report(_ event: String, _ detail: String) {
        emit(RuntimeEvent(kind: .config, event: "platform.location_" + event, detail: detail))
    }

    private func surface(_ kind: NetworkSettingsKind) -> PlatformSurface {
        kind == .proxies ? .systemProxy : .systemDNS
    }

    private func fields(_ service: LocationServiceSettings, _ kind: NetworkSettingsKind) -> [String: NetworkSettingValue] {
        kind == .proxies ? service.proxies : service.dns
    }

    private func pack(_ value: [String: NetworkSettingValue]) throws -> [String: String] {
        ["networkSettings": String(decoding: try CanonicalJSON.encoder().encode(value), as: UTF8.self)]
    }

    private func packApplied(_ value: [String: NetworkSettingValue], previous: [String: NetworkSettingValue]) throws -> [String: String] {
        var result = try pack(value)
        result["previousNetworkSettings"] = try pack(previous)["networkSettings"]
        return result
    }

    private func unpack(_ value: [String: String]?) throws -> [String: NetworkSettingValue] {
        guard let text = value?["networkSettings"] else { throw NetworkSettingsError.invalidRequest }
        return try CanonicalJSON.decoder().decode([String: NetworkSettingValue].self, from: Data(text.utf8))
    }

    /// Read the endpoints actually stored on the machine, including old configured ports.
    /// Probing only today's config misses a live session after a port/config change.
    package func proxyListenerIsLive(config: ProxyConfig, probe: @Sendable (Int) -> Bool) throws -> Bool {
        let snapshot = try store.snapshot()
        for service in snapshot.services {
            let current = service.proxies
            for prefix in ["HTTP", "HTTPS"] {
                guard case .text(let host) = current[prefix + "Proxy"],
                      host == config.effectiveClientHost || Self.isLoopback(host),
                      case .number(let port) = current[prefix + "Port"], (1...65535).contains(port) else { continue }
                if probe(port) { return true }
            }
            if case .text(let text) = current["ProxyAutoConfigURLString"], let url = URL(string: text),
               Self.isLoopback(url.host ?? ""), let port = url.port, (1...65535).contains(port), probe(port) { return true }
        }
        return false
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    package func validateSnapshot() throws { _ = try store.snapshot() }

    package func isCleared(kind: NetworkSettingsKind) -> Bool {
        do {
            let snapshot = try store.snapshot()
            return snapshot.services.filter { $0.locationID == snapshot.activeLocationID }.allSatisfy { member in
                let current = fields(member, kind)
                if kind == .dns { return current["ServerAddresses"] != .list(["127.0.0.1"]) }
                return ["HTTPEnable", "HTTPSEnable", "ProxyAutoConfigEnable"].allSatisfy { current[$0] != .number(1) }
            }
        } catch {
            report("failed", "operation=inspect reason=\(error.localizedDescription)")
            return false
        }
    }

    package func isApplied(kind: NetworkSettingsKind, desired: [String: NetworkSettingValue]) -> Bool {
        do {
            let snapshot = try store.snapshot()
            let active = snapshot.services.filter { $0.locationID == snapshot.activeLocationID && $0.enabled && $0.supports(kind) }
            return !active.isEmpty && active.allSatisfy { service in
                desired.allSatisfy { fields(service, kind)[$0.key] == $0.value }
            }
        } catch {
            report("failed", "operation=inspect reason=\(error.localizedDescription)")
            return false
        }
    }

    package func apply(kind: NetworkSettingsKind, desired: [String: NetworkSettingValue], config: ProxyConfig) throws {
        try operations.withLock {
            // Put back inactive locations first; their endpoints must not outlive this runtime.
            try cleanLegacy(kind: kind, config: config)
            try restore(kind: kind, inactiveOnly: true)
            let snapshot = try store.snapshot()
            let active = snapshot.services.filter { $0.locationID == snapshot.activeLocationID && $0.enabled && $0.supports(kind) }
            guard !active.isEmpty else { throw NetworkSettingsError.unavailable }
            for service in active {
                let current = fields(service, kind)
                let scope = service.locationID + "/" + service.serviceID
                if let record = journal.records(for: surface(kind)).first(where: { $0.scope == scope }),
                   try unpack(record.appliedValue) != current {
                    // Preserve later external values as the next prior state before reapplying.
                    try restoreRecord(record, snapshot: snapshot, kind: kind)
                }
                let fresh = try store.snapshot()
                guard fresh.activeLocationID == snapshot.activeLocationID,
                      let member = fresh.services.first(where: {
                          $0.locationID == service.locationID && $0.serviceID == service.serviceID
                      }) else { throw NetworkSettingsError.changed }
                let expected = fields(member, kind)
                var replacement = expected
                for (key, value) in desired { replacement[key] = value }
                let request = NetworkSettingsRequest(locationID: service.locationID, serviceID: service.serviceID,
                                                     kind: kind, expected: expected, replacement: replacement, requireActive: true)
                try request.validate()
                let prior = removeResidue(expected, kind: kind, config: config)
                do {
                    try journal.recordNetworkState(surface: surface(kind), locationID: service.locationID,
                                                   serviceID: service.serviceID, prior: pack(prior),
                                                   applied: packApplied(replacement, previous: expected), maximumRecords: limits.maximumRecords)
                } catch {
                    report("failed", "operation=capture location=\(service.locationID) reason=\(error.localizedDescription)")
                    throw error
                }
                report("apply", "location=\(service.locationID) service=\(service.serviceID) surface=\(kind.rawValue)")
                do { try store.compareAndWrite(request) }
                catch {
                    report("failed", "operation=apply location=\(service.locationID) reason=\(error.localizedDescription)")
                    throw error
                }
            }
        }
    }

    package func restore(kind: NetworkSettingsKind, inactiveOnly: Bool = false) throws {
        try operations.withLock {
            let snapshot = try store.snapshot()
            var firstError: Error?
            for record in journal.records(for: surface(kind)) where record.locationID != nil {
                if inactiveOnly && record.locationID == snapshot.activeLocationID { continue }
                do { try restoreRecord(record, snapshot: snapshot, kind: kind) }
                catch {
                    report("failed", "operation=restore scope=\(record.scope) reason=\(error.localizedDescription)")
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        }
    }

    private func restoreRecord(_ record: PlatformStateRecord, snapshot: NetworkLocationSnapshot,
                               kind: NetworkSettingsKind) throws {
        guard let member = snapshot.services.first(where: {
            $0.locationID == record.locationID && $0.serviceID == record.serviceID && $0.supports(kind)
        }) else {
            report("deleted", "scope=\(record.scope) surface=\(kind.rawValue)")
            try journal.forgetNetworkState(surface: surface(kind), scope: record.scope)
            return
        }
        let current = fields(member, kind)
        let prior = try unpack(record.priorValue)
        let applied = try unpack(record.appliedValue)
        let previous = try record.appliedValue?["previousNetworkSettings"].map {
            try CanonicalJSON.decoder().decode([String: NetworkSettingValue].self, from: Data($0.utf8))
        }
        var replacement = current
        let groups: [(keys: [String], enable: String?)] = kind == .dns ? [(["ServerAddresses"], nil)] : [
            (["HTTPProxy", "HTTPPort"], "HTTPEnable"), (["HTTPSProxy", "HTTPSPort"], "HTTPSEnable"),
            (["ProxyAutoConfigURLString"], "ProxyAutoConfigEnable"), (["ExceptionsList"], nil)
        ]
        for group in groups {
            let intendedMatches = group.keys.allSatisfy { current[$0] == applied[$0] }
            let previousMatches = previous.map { old in group.keys.allSatisfy { current[$0] == old[$0] } } ?? false
            guard intendedMatches || previousMatches else { continue }
            for key in group.keys { replacement[key] = prior[key] }
            if let enable = group.enable,
               current[enable] == applied[enable] || (previousMatches && current[enable] == previous?[enable]) {
                replacement[enable] = prior[enable]
            }
        }
        report(replacement == current ? "external_preserved" : "restore",
               "scope=\(record.scope) surface=\(kind.rawValue) active=\(member.locationID == snapshot.activeLocationID)")
        // Compare even a no-op so an external change between snapshot and release is detected.
        do {
            try store.compareAndWrite(NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                             kind: kind, expected: current, replacement: replacement, requireActive: false))
        } catch PrivilegeClientError.refused(.noConsoleUser, _) {
            var cleanup = current
            for key in kind.keys where replacement[key] != current[key] { cleanup.removeValue(forKey: key) }
            try journal.recordNetworkState(surface: surface(kind), locationID: member.locationID, serviceID: member.serviceID,
                                           prior: record.priorValue ?? [:], applied: packApplied(cleanup, previous: current),
                                           maximumRecords: limits.maximumRecords)
            report("cleanup_deferred", "scope=\(record.scope) surface=\(kind.rawValue) reason=no_console_user")
            try store.compareAndWrite(NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                             kind: kind, expected: current, replacement: cleanup, requireActive: false))
            throw PrivilegeClientError.refused(.noConsoleUser, "Cleanup completed; prior settings retained for the next login.")
        }
        try journal.forgetNetworkState(surface: surface(kind), scope: record.scope)
    }

    package func recover(kind: NetworkSettingsKind, config: ProxyConfig, listenerIsLive: Bool) -> LaunchRecoveryOutcome {
        operations.withLock {
            do {
                if listenerIsLive {
                    let snapshot = try store.snapshot()
                    let residue = snapshot.services.contains {
                        let current = fields($0, kind)
                        return current != removeResidue(current, kind: kind, config: config)
                    }
                    if journal.hasRecords(for: surface(kind)) || residue { return .declinedLiveListener }
                }
                let hadRecords = journal.hasRecords(for: surface(kind))
                try cleanLegacy(kind: kind, config: config)
                try restore(kind: kind)
                return hadRecords ? .restored(stale: false) : .nothingToDo(.nothingRecorded)
            } catch {
                report("failed", "operation=recover reason=\(error.localizedDescription)")
                return .failed(reason: error.localizedDescription)
            }
        }
    }

    package func clear(kind: NetworkSettingsKind, config: ProxyConfig) throws {
        try operations.withLock {
            try cleanLegacy(kind: kind, config: config)
            try restore(kind: kind)
            if !journal.hasRecords(for: surface(kind)) { journal.markReleased(surface: surface(kind)) }
        }
    }

    private func cleanLegacy(kind: NetworkSettingsKind, config: ProxyConfig) throws {
        let legacy = journal.records(for: surface(kind)).filter { $0.locationID == nil }
        // A released surface contains the user's own settings; never sweep it again.
        guard !legacy.isEmpty || (journal.ownership(of: surface(kind)) == .unknown && !journal.hasRecords(for: surface(kind))) else { return }
        let snapshot = try store.snapshot()
        let scoped = Set(journal.records(for: surface(kind)).filter { $0.locationID != nil }.map(\.scope))
        for member in snapshot.services where member.supports(kind) && !scoped.contains(member.locationID + "/" + member.serviceID) {
            let current = fields(member, kind)
            let replacement = removeResidue(current, kind: kind, config: config)
            guard current != replacement else { continue }
            report("legacy_cleanup", "location=\(member.locationID) service=\(member.serviceID) surface=\(kind.rawValue) prior_location=unknown")
            try store.compareAndWrite(NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                             kind: kind, expected: current, replacement: replacement, requireActive: false))
        }
        for record in legacy {
            report("legacy_retired", "surface=\(kind.rawValue) prior_location=unknown")
            try journal.forgetNetworkState(surface: surface(kind), scope: record.scope)
        }
    }

    private func removeResidue(_ current: [String: NetworkSettingValue], kind: NetworkSettingsKind,
                               config: ProxyConfig) -> [String: NetworkSettingValue] {
        var replacement = current
        if kind == .dns {
            if current["ServerAddresses"] == .list(["127.0.0.1"]) { replacement.removeValue(forKey: "ServerAddresses") }
        } else {
            let ours = SystemProxyManager.LocalListenerFingerprint(config: config)
            for prefix in ["HTTP", "HTTPS"] {
                if case .text(let host) = current[prefix + "Proxy"],
                   case .number(let port) = current[prefix + "Port"],
                   ours.matchesEndpoint(host: host, port: String(port)) {
                    for suffix in ["Proxy", "Port", "Enable"] { replacement.removeValue(forKey: prefix + suffix) }
                }
            }
            if case .text(let url) = current["ProxyAutoConfigURLString"], ours.matchesPACURL(url) {
                replacement.removeValue(forKey: "ProxyAutoConfigURLString")
                replacement.removeValue(forKey: "ProxyAutoConfigEnable")
            }
        }
        return replacement
    }
}
