// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

// Single-threaded by contract: the helper calls it from its one loop, and `FakeMachine` from under a lock.

package enum VPNDNSValue: Equatable, Sendable {
    case string(String)
    case number(Int)
    case bool(Bool)
    case strings([String])
    case numbers([Int])
}

package struct VPNDNSOverrideRecord: Codable, Equatable, Sendable {
    package var serviceID: String
    package var originals: [String]

    package init(serviceID: String, originals: [String]) {
        self.serviceID = serviceID
        self.originals = originals
    }

    package var isValid: Bool {
        VPNDNSOverrideValidation.isServiceID(serviceID)
            && (1...VPNDNSOverrideValidation.maximumServers).contains(originals.count)
            && originals.allSatisfy(VPNDNSOverrideValidation.isTunnelServer)
    }
}

package protocol VPNDNSStore {
    func dns(service: String) -> [String: VPNDNSValue]?
    func ipv4Exists(service: String) -> Bool
    func overridesPrimary(service: String) -> Bool
    func primaryService() -> String?
    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool
    // No remove: mid-flap the IPv4 key is briefly absent, and a VPN client never republishes a deleted DNS key.
}

package enum VPNDNSProbeVerdict: Equatable, Sendable {
    case notRunning
    case answered
    case refused
    case silent
    case failed(String)
}

package protocol VPNDNSForwarderProbe {
    func probe() -> VPNDNSProbeVerdict
    func tcpListening() -> Bool
}

package enum VPNDNSOverrideStoredRecord: Equatable, Sendable {
    case none
    case record(VPNDNSOverrideRecord)
    case undecodable(String)
}

package protocol VPNDNSOverridePersistence {
    func load() -> VPNDNSOverrideStoredRecord
    func save(_ record: VPNDNSOverrideRecord) throws
    func delete() throws
}

package enum VPNDNSOverrideReleaseReason: String, Sendable, CaseIterable {
    case requested
    case ownerExited = "owner_exited"
    case relayStopped = "relay_stopped"
    case targetRefused = "target_refused"
    case targetSilent = "target_silent"
    case helperStopping = "helper_stopping"
    case helperStart = "helper_start"
}

package enum VPNDNSReleaseWrite: String, Sendable {
    case restored
    case keyChanged = "key_changed"
    case keyGone = "key_gone"
    case restoreFailed = "restore_failed"

    package var failed: Bool { self == .restoreFailed }
}

package enum VPNDNSOverrideOutcome: Equatable, Sendable {
    case applied(service: String, servers: Int)
    case refused(service: String, reason: HelperVPNDNSOverrideRefusal)
    case released(service: String, reason: VPNDNSOverrideReleaseReason, write: VPNDNSReleaseWrite)
    case nothingToRelease(reason: VPNDNSOverrideReleaseReason)
    case probeMissed(service: String, verdict: VPNDNSProbeVerdict, consecutive: Int)
    case discardedUndecodableRecord(String)
    case persistenceFailed(operation: String, error: String)
    case serviceGoneDuringApply(service: String, restored: Bool)

    package var logLine: String {
        let prefix = "vpn-dns-override"
        switch self {
        case .applied(let service, let servers):
            return "\(prefix) applied service=\(HelperAudit.safe(service)) servers=\(servers)"
        case .refused(let service, let reason):
            return "\(prefix) refused service=\(HelperAudit.safe(service)) reason=\(reason.rawValue)"
        case .released(let service, let reason, let write) where write.failed:
            return "\(prefix) release service=\(HelperAudit.safe(service)) reason=\(reason.rawValue) write=\(write.rawValue) restore_pending=next_tick"
        case .released(let service, let reason, let write):
            return "\(prefix) released service=\(HelperAudit.safe(service)) reason=\(reason.rawValue) write=\(write.rawValue)"
        case .nothingToRelease(let reason):
            return "\(prefix) release reason=\(reason.rawValue) held=none"
        case .probeMissed(let service, let verdict, let consecutive):
            return "\(prefix) probe service=\(HelperAudit.safe(service)) verdict=\(verdict.word) consecutive=\(consecutive)"
        case .discardedUndecodableRecord(let why):
            return "\(prefix) record undecodable, deleted, key left alone: \"\(HelperAudit.bounded(why))\""
        case .persistenceFailed(let operation, let error):
            return "\(prefix) record \(operation) failed: \"\(HelperAudit.bounded(error))\""
        case .serviceGoneDuringApply(let service, let restored):
            return "\(prefix) service=\(HelperAudit.safe(service)) had no IPv4 key after apply; originals \(restored ? "restored" : "NOT restored")"
        }
    }

    package var isFailure: Bool {
        switch self {
        case .persistenceFailed, .discardedUndecodableRecord: return true
        case .serviceGoneDuringApply(_, let restored): return !restored
        case .released(_, _, let write): return write.failed
        default: return false
        }
    }
}

extension VPNDNSProbeVerdict {
    var word: String {
        switch self {
        case .notRunning: return "not_running"
        case .answered: return "answered"
        case .refused: return "refused"
        case .silent: return "silent"
        case .failed(let why): return "failed(\(HelperAudit.bounded(why)))"
        }
    }
}

package enum VPNDNSOverrideApplyResult: Equatable, Sendable {
    case applied
    case refused(HelperVPNDNSOverrideRefusal)
}

package final class VPNDNSOverrideLedger {
    package static let relayServers = ["127.0.0.1"]
    package static let tickSeconds = 10
    package static let refusedTicksToRelease = 2
    package static let silentTicksToRelease = 3

    private let store: any VPNDNSStore
    private let probe: any VPNDNSForwarderProbe
    private let persistence: any VPNDNSOverridePersistence
    private let report: (VPNDNSOverrideOutcome) -> Void
    private var record: VPNDNSOverrideRecord?
    package private(set) var lastRelease: VPNDNSOverrideReleaseReason?
    /// Set while the record is held only because its restore failed; each tick retries it before any probe.
    package private(set) var restorePending: VPNDNSOverrideReleaseReason?
    private var consecutiveRefused = 0
    private var consecutiveSilent = 0

    package init(
        store: any VPNDNSStore,
        probe: any VPNDNSForwarderProbe,
        persistence: any VPNDNSOverridePersistence,
        report: @escaping (VPNDNSOverrideOutcome) -> Void
    ) {
        self.store = store
        self.probe = probe
        self.persistence = persistence
        self.report = report
    }

    package func status() -> VPNDNSOverrideRecord? { record }

    package func start() {
        switch persistence.load() {
        case .none:
            return
        case .record(let persisted):
            record = persisted
            release(reason: .helperStart)
        case .undecodable(let why):
            deleteFile()
            report(.discardedUndecodableRecord(why))
        }
    }

    /// The record is on disk before the key is written.
    package func apply(service: String, expected: [String]) -> VPNDNSOverrideApplyResult {
        let current: [String: VPNDNSValue]
        switch check(service: service, expected: expected) {
        case .refused(let reason):
            report(.refused(service: service, reason: reason))
            return .refused(reason)
        case .passed(let dns):
            current = dns
        }
        if let held = record, held.serviceID != service || restorePending != nil,
           release(reason: restorePending ?? .requested)?.failed == true {
            report(.refused(service: service, reason: .writeFailed))
            return .refused(.writeFailed)
        }
        let replacement = VPNDNSOverrideRecord(serviceID: service, originals: expected)
        do {
            try persistence.save(replacement)
        } catch {
            report(.persistenceFailed(operation: "save", error: error.localizedDescription))
            report(.refused(service: service, reason: .writeFailed))
            return .refused(.writeFailed)
        }
        var overridden = current
        overridden["ServerAddresses"] = .strings(Self.relayServers)
        guard store.setDNS(overridden, service: service) else {
            forgetRecord()
            report(.refused(service: service, reason: .writeFailed))
            return .refused(.writeFailed)
        }
        // Restore over our own 127.0.0.1 only while it is still ours; never remove the key.
        guard store.ipv4Exists(service: service) else {
            var restored = true
            if store.dns(service: service) == overridden {
                var original = overridden
                original["ServerAddresses"] = .strings(expected)
                restored = store.setDNS(original, service: service)
            }
            forgetRecord()
            report(.serviceGoneDuringApply(service: service, restored: restored))
            report(.refused(service: service, reason: .notFound))
            return .refused(.notFound)
        }
        record = replacement
        resetProbeStreaks()
        report(.applied(service: service, servers: expected.count))
        return .applied
    }

    private enum Check {
        case passed([String: VPNDNSValue])
        case refused(HelperVPNDNSOverrideRefusal)
    }

    private func check(service: String, expected: [String]) -> Check {
        // Before any key is addressed: a malformed ID could name another key.
        guard VPNDNSOverrideValidation.isServiceID(service) else { return .refused(.invalid) }
        guard let dns = store.dns(service: service),
              case .strings(let servers)? = dns["ServerAddresses"], !servers.isEmpty else {
            return .refused(.notFound)
        }
        guard store.overridesPrimary(service: service) else { return .refused(.notFullTunnel) }
        guard store.primaryService() == service else { return .refused(.notPrimary) }
        if let supplemental = dns["SupplementalMatchDomains"], supplemental != .strings([]) {
            return .refused(.notFullTunnel)
        }
        guard servers == expected else { return .refused(.changed) }
        guard (1...VPNDNSOverrideValidation.maximumServers).contains(expected.count),
              expected.allSatisfy(VPNDNSOverrideValidation.isTunnelServer) else {
            return .refused(.invalid)
        }
        guard probe.tcpListening(), probe.probe() == .answered else { return .refused(.relayNotServing) }
        return .passed(dns)
    }

    @discardableResult
    package func release(reason: VPNDNSOverrideReleaseReason) -> VPNDNSReleaseWrite? {
        guard let held = record else {
            report(.nothingToRelease(reason: reason))
            return nil
        }
        let write = restore(held)
        if write.failed {
            restorePending = reason
        } else {
            forgetRecord()
            lastRelease = reason
        }
        report(.released(service: held.serviceID, reason: reason, write: write))
        return write
    }

    private func restore(_ held: VPNDNSOverrideRecord) -> VPNDNSReleaseWrite {
        guard var dns = store.dns(service: held.serviceID) else { return .keyGone }
        guard dns["ServerAddresses"] == .strings(Self.relayServers) else { return .keyChanged }
        dns["ServerAddresses"] = .strings(held.originals)
        return store.setDNS(dns, service: held.serviceID) ? .restored : .restoreFailed
    }

    package func tick() {
        guard let held = record else { return }
        if let pending = restorePending {
            release(reason: pending)
            return
        }
        guard probe.tcpListening() else {
            release(reason: .relayStopped)
            return
        }
        switch probe.probe() {
        case .notRunning:
            release(reason: .relayStopped)
        case .answered:
            resetProbeStreaks()
        case .refused:
            consecutiveSilent = 0
            consecutiveRefused += 1
            if consecutiveRefused >= Self.refusedTicksToRelease {
                release(reason: .targetRefused)
            } else {
                report(.probeMissed(service: held.serviceID, verdict: .refused, consecutive: consecutiveRefused))
            }
        case .silent:
            consecutiveRefused = 0
            consecutiveSilent += 1
            if consecutiveSilent >= Self.silentTicksToRelease {
                release(reason: .targetSilent)
            } else {
                report(.probeMissed(service: held.serviceID, verdict: .silent, consecutive: consecutiveSilent))
            }
        case .failed(let why):
            report(.probeMissed(service: held.serviceID, verdict: .failed(why), consecutive: 0))
        }
    }

    package func relayRestarted(succeeded: Bool) {
        guard record != nil else { return }
        if succeeded {
            resetProbeStreaks()
        } else {
            release(reason: .relayStopped)
        }
    }

    private func resetProbeStreaks() {
        consecutiveRefused = 0
        consecutiveSilent = 0
    }

    private func forgetRecord() {
        record = nil
        restorePending = nil
        resetProbeStreaks()
        deleteFile()
    }

    private func deleteFile() {
        do {
            try persistence.delete()
        } catch {
            report(.persistenceFailed(operation: "delete", error: error.localizedDescription))
        }
    }
}

/// Root-owned 0600 in a 0700 directory under `/var/run`, which is cleared at boot like the key.
package struct VPNDNSOverrideFile: VPNDNSOverridePersistence {
    package static let maximumBytes = 16_384

    package let path: String

    package init(path: String = HelperConstants.vpnDNSOverrideRecordPath) {
        self.path = path
    }

    package func load() -> VPNDNSOverrideStoredRecord {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return .none }
            return .undecodable("open: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .undecodable("read: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > Self.maximumBytes { return .undecodable("larger than \(Self.maximumBytes) bytes") }
        }
        return Self.decode(data)
    }

    package static func decode(_ data: Data) -> VPNDNSOverrideStoredRecord {
        let decoded: VPNDNSOverrideRecord
        do {
            decoded = try JSONDecoder().decode(VPNDNSOverrideRecord.self, from: data)
        } catch {
            return .undecodable("not a record: \(error.localizedDescription)")
        }
        guard decoded.isValid else { return .undecodable("record out of shape") }
        return .record(decoded)
    }

    package static func encode(_ record: VPNDNSOverrideRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    package func save(_ record: VPNDNSOverrideRecord) throws {
        let data = try Self.encode(record)
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw VPNDNSOverrideFileError.system("mkdir \(directory)", errno)
        }
        let temporary = path + ".tmp"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VPNDNSOverrideFileError.system("open \(temporary)", errno) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let writeErrno = errno
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else {
            unlink(temporary)
            throw VPNDNSOverrideFileError.system("write \(temporary)", writeErrno)
        }
        guard rename(temporary, path) == 0 else {
            let renameErrno = errno
            unlink(temporary)
            throw VPNDNSOverrideFileError.system("rename to \(path)", renameErrno)
        }
    }

    package func delete() throws {
        guard unlink(path) == 0 || errno == ENOENT else {
            throw VPNDNSOverrideFileError.system("unlink \(path)", errno)
        }
    }
}

package enum VPNDNSOverrideFileError: Error, LocalizedError, Equatable {
    case system(String, Int32)

    package var errorDescription: String? {
        switch self {
        case .system(let step, let code): return "\(step): \(String(cString: strerror(code)))"
        }
    }
}
