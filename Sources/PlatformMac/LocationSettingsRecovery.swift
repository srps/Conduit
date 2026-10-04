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

    package func failureEvent(operation: String, error: Error) -> RuntimeEvent {
        let event = RuntimeEvent(kind: .config, event: "platform.location_failed", detail: "operation=\(operation) reason=\(error.localizedDescription)")
        emit(event)
        return event
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
        for service in snapshot.services where service.enabled && service.locationID == snapshot.activeLocationID {
            let current = service.proxies
            for prefix in ["HTTP", "HTTPS"] {
                guard current[prefix + "Enable"] == .number(1), case .text(let host) = current[prefix + "Proxy"],
                      host == config.effectiveClientHost || Self.isLoopback(host),
                      case .number(let port) = current[prefix + "Port"], (1...65535).contains(port) else { continue }
                if probe(port) { return true }
            }
            if current["ProxyAutoConfigEnable"] == .number(1),
               case .text(let text) = current["ProxyAutoConfigURLString"], let url = URL(string: text),
               Self.isLoopback(url.host ?? ""), let port = url.port, (1...65535).contains(port), probe(port) { return true }
        }
        return false
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    package func validateSnapshot() throws { _ = try store.snapshot() }

    package func isCleared(kind: NetworkSettingsKind) -> Bool {
        guard journal.fileState != .unreadable, !journal.hasRecords(for: surface(kind)) else { return false }
        do {
            let snapshot = try store.snapshot()
            return snapshot.services.filter { $0.locationID == snapshot.activeLocationID }.allSatisfy { member in
                guard !member.isUnreadable(kind) else { return false }
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
                !service.isUnreadable(kind) && desired.allSatisfy { fields(service, kind)[$0.key] == $0.value }
            }
        } catch {
            report("failed", "operation=inspect reason=\(error.localizedDescription)")
            return false
        }
    }

    package func apply(kind: NetworkSettingsKind, desired: [String: NetworkSettingValue], config: ProxyConfig) throws {
        try operations.withLock {
            let locationID = try store.snapshot().activeLocationID
            for attempt in 1...limits.maximumApplyAttempts {
                do {
                    try applyAttempt(kind: kind, desired: desired, config: config)
                    return
                } catch {
                    let retryable: Bool
                    switch error {
                    case NetworkSettingsError.changed, PrivilegeClientError.executionFailed: retryable = true
                    default: retryable = false
                    }
                    guard retryable, attempt < limits.maximumApplyAttempts,
                          try store.snapshot().activeLocationID == locationID else { throw error }
                    // Ordinary helper execution errors include CAS conflicts;
                    // never infer their type from human-readable error text.
                    report("retry", "surface=\(kind.rawValue) location=\(locationID) attempt=\(attempt + 1) maximum=\(limits.maximumApplyAttempts)")
                }
            }
        }
    }

    private func applyAttempt(kind: NetworkSettingsKind, desired: [String: NetworkSettingValue], config: ProxyConfig) throws {
        try operations.withLock {
            if kind == .proxies && desired["ProxyAutoConfigEnable"] == .number(1) {
                guard case .text(let url) = desired["ProxyAutoConfigURLString"], !url.isEmpty else {
                    report("failed", "operation=apply surface=proxies reason=missing_pac_url")
                    throw NetworkSettingsError.invalidRequest
                }
            }
            // Put back inactive locations first; their endpoints must not outlive this runtime.
            try cleanLegacyAndRestore(kind: kind, config: config, inactiveOnly: true)
            let snapshot = try store.snapshot()
            let active = snapshot.services.filter { $0.locationID == snapshot.activeLocationID && $0.enabled && $0.supports(kind) }
            guard !active.isEmpty else {
                report("failed", "operation=apply surface=\(kind.rawValue) reason=no_enabled_services")
                throw NetworkSettingsError.unavailable
            }
            guard !active.contains(where: { $0.isUnreadable(kind) }) else {
                report("failed", "operation=apply surface=\(kind.rawValue) reason=unsupported_settings")
                throw NetworkSettingsError.invalidRequest
            }
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
                do { try request.validate() }
                catch {
                    report("failed", "operation=validate location=\(service.locationID) reason=\(error.localizedDescription)")
                    throw error
                }
                // Without a legacy or scoped record, loopback settings belong to the user.
                let prior = expected
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
                do {
                    // The CAS succeeded: an external edit back to the old
                    // generation is no longer an uncertain write outcome.
                    try journal.recordNetworkState(surface: surface(kind), locationID: service.locationID,
                                                   serviceID: service.serviceID, prior: pack(prior),
                                                   applied: pack(replacement), maximumRecords: limits.maximumRecords)
                } catch {
                    report("failed", "operation=finalize location=\(service.locationID) reason=\(error.localizedDescription)")
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
        guard !member.isUnreadable(kind) else { throw NetworkSettingsError.invalidRequest }
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
            let candidate = NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                  kind: kind, expected: current, replacement: replacement, requireActive: false)
            for key in candidate.cleanupKeys where replacement[key] != current[key] { cleanup.removeValue(forKey: key) }
            for (endpoint, enable) in [("HTTPProxy", "HTTPEnable"), ("HTTPSProxy", "HTTPSEnable"), ("ProxyAutoConfigURLString", "ProxyAutoConfigEnable")]
                where current[endpoint] != nil && cleanup[endpoint] == nil {
                cleanup.removeValue(forKey: enable)
            }
            let cleanupRequest = NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                       kind: kind, expected: current, replacement: cleanup, requireActive: false)
            guard cleanupRequest.isCleanup else { throw PrivilegeClientError.refused(.noConsoleUser, "Prior settings retained for the next login.") }
            try journal.recordNetworkState(surface: surface(kind), locationID: member.locationID, serviceID: member.serviceID,
                                           prior: record.priorValue ?? [:], applied: packApplied(cleanup, previous: current),
                                           maximumRecords: limits.maximumRecords)
            report("cleanup_deferred", "scope=\(record.scope) surface=\(kind.rawValue) reason=no_console_user")
            try store.compareAndWrite(cleanupRequest)
            try journal.recordNetworkState(surface: surface(kind), locationID: member.locationID, serviceID: member.serviceID,
                                           prior: record.priorValue ?? [:], applied: pack(cleanup), maximumRecords: limits.maximumRecords)
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
                try cleanLegacyAndRestore(kind: kind, config: config)
                return hadRecords ? .restored(stale: false) : .nothingToDo(.nothingRecorded)
            } catch {
                report("failed", "operation=recover reason=\(error.localizedDescription)")
                return .failed(reason: error.localizedDescription)
            }
        }
    }

    package func clear(kind: NetworkSettingsKind, config: ProxyConfig) throws {
        try operations.withLock {
            try cleanLegacyAndRestore(kind: kind, config: config)
            if !journal.hasRecords(for: surface(kind)) { journal.markReleased(surface: surface(kind)) }
        }
    }

    /// Ambiguous legacy settings cannot prevent restoration of known scoped identities.
    private func cleanLegacyAndRestore(kind: NetworkSettingsKind, config: ProxyConfig, inactiveOnly: Bool = false) throws {
        var firstError: Error?
        do { try cleanLegacy(kind: kind, config: config) }
        catch { firstError = error }
        do { try restore(kind: kind, inactiveOnly: inactiveOnly) }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    private func cleanLegacy(kind: NetworkSettingsKind, config: ProxyConfig) throws {
        let legacy = journal.records(for: surface(kind)).filter { $0.locationID == nil }
        let journalUnreadable = journal.fileState == .unreadable
        // A released surface contains the user's own settings; never sweep it again.
        guard !legacy.isEmpty || journalUnreadable else { return }
        let snapshot = try store.snapshot()
        let scoped = Set(journal.records(for: surface(kind)).filter { $0.locationID != nil }.map(\.scope))
        var unreadable = false
        for member in snapshot.services where member.supports(kind) && !scoped.contains(member.locationID + "/" + member.serviceID) {
            if member.isUnreadable(kind) {
                report("failed", "operation=legacy_cleanup location=\(member.locationID) surface=\(kind.rawValue) reason=unsupported_settings")
                unreadable = true
                continue
            }
            let current = fields(member, kind)
            let replacement = removeResidue(current, kind: kind, config: config)
            if kind == .proxies && !legacy.isEmpty && containsUnattributedEndpoint(replacement, legacy: legacy) {
                report("failed", "operation=legacy_cleanup location=\(member.locationID) surface=proxies reason=unattributed_proxy_endpoint")
                unreadable = true
            }
            guard current != replacement else { continue }
            report("legacy_cleanup", "location=\(member.locationID) service=\(member.serviceID) surface=\(kind.rawValue) prior_location=unknown")
            try store.compareAndWrite(NetworkSettingsRequest(locationID: member.locationID, serviceID: member.serviceID,
                                                             kind: kind, expected: current, replacement: replacement, requireActive: false))
        }
        guard !unreadable else { throw NetworkSettingsError.invalidRequest }
        // Retain corrupt evidence and never overwrite it with a released marker.
        if journalUnreadable {
            report("failed", "operation=legacy_cleanup surface=\(kind.rawValue) reason=unreadable_journal prior_location=unknown")
            throw NetworkSettingsError.unreadableJournal
        }
        for record in legacy {
            report("legacy_retired", "surface=\(kind.rawValue) prior_location=unknown")
            try journal.forgetNetworkState(surface: surface(kind), scope: record.scope)
        }
    }

    private func containsUnattributedEndpoint(_ fields: [String: NetworkSettingValue], legacy: [PlatformStateRecord]) -> Bool {
        for prefix in ["HTTP", "HTTPS"] {
            guard case .text(let host) = fields[prefix + "Proxy"], !host.isEmpty else { continue }
            if Self.isLoopback(host) { return true }
            guard case .number(let port) = fields[prefix + "Port"] else { return true }
            let enabled = fields[prefix + "Enable"] == .number(1)
            let knownPrior = legacy.contains { record in
                let prior = ProxyServiceState(journalValues: record.priorValue ?? [:])
                return prefix == "HTTP"
                    ? prior.webHost == host && prior.webPort == String(port) && prior.webEnabled == enabled
                    : prior.secureHost == host && prior.securePort == String(port) && prior.secureEnabled == enabled
            }
            if !knownPrior { return true }
        }
        if case .text(let text) = fields["ProxyAutoConfigURLString"], !text.isEmpty {
            if let url = URL(string: text), Self.isLoopback(url.host ?? "") { return true }
            let enabled = fields["ProxyAutoConfigEnable"] == .number(1)
            return !legacy.contains { record in
                let prior = ProxyServiceState(journalValues: record.priorValue ?? [:])
                return prior.autoURL == text && prior.autoEnabled == enabled
            }
        }
        return false
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
