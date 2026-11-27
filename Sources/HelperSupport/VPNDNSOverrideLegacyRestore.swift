// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation

/// The originals a helper that rewrote the VPN's key saved before it wrote `127.0.0.1`.
package struct VPNDNSOverrideLegacyRecord: Codable, Equatable, Sendable {
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

package enum VPNDNSOverrideLegacyStoredRecord: Equatable, Sendable {
    case none
    case record(VPNDNSOverrideLegacyRecord)
    /// The file is there but could not be read; it is kept and read again.
    case unreadable(String)
    /// Read, but not a record: a link, too large, not JSON or out of shape.
    case malformed(String)
}

package protocol VPNDNSOverrideLegacyRecordFile {
    func load() -> VPNDNSOverrideLegacyStoredRecord
    func delete() throws
    /// Moves a malformed record out of the way, kept for a person to read, so it is never read again.
    func setAside() throws
}

/// The only write to a VPN client's key: putting back what an older helper replaced, once, when a person asks.
package protocol VPNDNSLegacyStore {
    func legacyDNS(service: String) -> VPNDNSRead
    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool
}

package enum VPNDNSOverrideLegacyRestore {
    package enum Outcome: Equatable, Sendable {
        case noRecord
        /// At start: a record is there, and only `--restore-legacy-vpn-dns` acts on it. The key is not read or written.
        case awaitingRecovery(service: String)
        case restored(service: String)
        /// The key no longer holds `127.0.0.1`: the client wrote its own servers, so nothing is written.
        case keyChanged(service: String)
        case keyGone(service: String)
        /// The record stays, for another recovery.
        case keyUnreadable(service: String, reason: String)
        /// The record stays, for another recovery.
        case restoreFailed(service: String)
        /// The record stays.
        case recordUnreadable(String)
        case malformedSetAside(String)
        case setAsideFailed(String)
        case deleteFailed(String)

        package var logLine: String {
            let prefix = "vpn-dns-override legacy"
            switch self {
            case .noRecord: return "\(prefix) no record"
            case .awaitingRecovery(let service):
                return "\(prefix) awaiting_recovery service=\(HelperAudit.safe(service)); the helper does not write the VPN's key. "
                    + "Reconnect the VPN, or run: sudo \(HelperConstants.binaryInstallPath) \(VPNDNSOverrideLegacyRestore.flag)"
            case .restored(let service): return "\(prefix) restored service=\(HelperAudit.safe(service))"
            case .keyChanged(let service): return "\(prefix) key_changed service=\(HelperAudit.safe(service)); left alone"
            case .keyGone(let service): return "\(prefix) key_gone service=\(HelperAudit.safe(service)); left alone"
            case .keyUnreadable(let service, let reason):
                return "\(prefix) key_unreadable service=\(HelperAudit.safe(service)) reason=\"\(HelperAudit.bounded(reason))\"; record kept"
            case .restoreFailed(let service): return "\(prefix) restore_failed service=\(HelperAudit.safe(service)); record kept"
            case .recordUnreadable(let why): return "\(prefix) record_unreadable reason=\"\(HelperAudit.bounded(why))\"; record kept"
            case .malformedSetAside(let why):
                return "\(prefix) record_malformed reason=\"\(HelperAudit.bounded(why))\"; set aside as \(VPNDNSOverrideLegacyFile.setAsideSuffix)"
            case .setAsideFailed(let why): return "\(prefix) record set aside failed: \"\(HelperAudit.bounded(why))\""
            case .deleteFailed(let why): return "\(prefix) record delete failed: \"\(HelperAudit.bounded(why))\""
            }
        }

        package var isFailure: Bool {
            switch self {
            case .noRecord, .restored, .keyChanged, .keyGone, .awaitingRecovery: return false
            default: return true
            }
        }

        /// The record is still where it is read from, so another recovery may finish it.
        package var keepsRecord: Bool {
            switch self {
            case .awaitingRecovery, .keyUnreadable, .restoreFailed, .recordUnreadable, .setAsideFailed, .deleteFailed: return true
            default: return false
            }
        }
    }

    package static let flag = "--restore-legacy-vpn-dns"

    /// What the helper does at start: it reports a record and leaves both it and the VPN's key alone. A malformed record
    /// is set aside, as `run` would.
    @discardableResult
    package static func check(
        file: any VPNDNSOverrideLegacyRecordFile,
        report: (Outcome) -> Void
    ) -> Outcome {
        let outcome: Outcome
        switch file.load() {
        case .none: return .noRecord
        case .record(let record): outcome = .awaitingRecovery(service: record.serviceID)
        case .unreadable(let why): outcome = .recordUnreadable(why)
        case .malformed(let why): outcome = setAside(file, why)
        }
        report(outcome)
        return outcome
    }

    /// `--restore-legacy-vpn-dns`, run once by a person: reads the record and the key afresh. Compare-then-write, not
    /// atomic: the originals go back only over the `127.0.0.1` the older helper wrote, read just before, and nothing is
    /// deleted from the key. A client that writes between the read and the write loses to the restore, so it is never
    /// run unasked; the client rewrites its key on its own next change.
    @discardableResult
    package static func run(
        store: any VPNDNSLegacyStore,
        file: any VPNDNSOverrideLegacyRecordFile,
        report: (Outcome) -> Void
    ) -> Outcome {
        let outcome: Outcome
        switch file.load() {
        case .none:
            return .noRecord
        case .unreadable(let why):
            outcome = .recordUnreadable(why)
        case .malformed(let why):
            outcome = setAside(file, why)
            report(outcome)
            return outcome
        case .record(let record):
            outcome = restore(record, store: store)
        }
        report(outcome)
        if outcome.keepsRecord { return outcome }
        do {
            try file.delete()
        } catch {
            let failure = Outcome.deleteFailed(error.localizedDescription)
            report(failure)
            return failure
        }
        return outcome
    }

    private static func setAside(_ file: any VPNDNSOverrideLegacyRecordFile, _ why: String) -> Outcome {
        do {
            try file.setAside()
            return .malformedSetAside(why)
        } catch {
            return .setAsideFailed("\(why); \(error.localizedDescription)")
        }
    }

    private static func restore(_ record: VPNDNSOverrideLegacyRecord, store: any VPNDNSLegacyStore) -> Outcome {
        var dns: [String: VPNDNSValue]
        switch store.legacyDNS(service: record.serviceID) {
        case .absent: return .keyGone(service: record.serviceID)
        case .unreadable(let reason): return .keyUnreadable(service: record.serviceID, reason: reason)
        case .value(let value): dns = value
        }
        guard dns["ServerAddresses"] == .strings(["127.0.0.1"]) else { return .keyChanged(service: record.serviceID) }
        dns["ServerAddresses"] = .strings(record.originals)
        return store.setDNS(dns, service: record.serviceID)
            ? .restored(service: record.serviceID) : .restoreFailed(service: record.serviceID)
    }
}

/// The older helper's record under `/var/run`, root-owned 0600.
package struct VPNDNSOverrideLegacyFile: VPNDNSOverrideLegacyRecordFile {
    package static let maximumBytes = 16_384
    package static let setAsideSuffix = ".malformed"

    package let path: String

    package init(path: String = HelperConstants.legacyVPNDNSOverrideRecordPath) {
        self.path = path
    }

    package func load() -> VPNDNSOverrideLegacyStoredRecord {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return .none
            case ELOOP: return .malformed("a link, not a file")
            default: return .unreadable("open: \(String(cString: strerror(errno)))")
            }
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .unreadable("read: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > Self.maximumBytes { return .malformed("larger than \(Self.maximumBytes) bytes") }
        }
        return Self.decode(data)
    }

    package static func decode(_ data: Data) -> VPNDNSOverrideLegacyStoredRecord {
        let decoded: VPNDNSOverrideLegacyRecord
        do {
            decoded = try JSONDecoder().decode(VPNDNSOverrideLegacyRecord.self, from: data)
        } catch {
            return .malformed("not a record: \(error.localizedDescription)")
        }
        guard decoded.isValid else { return .malformed("record out of shape") }
        return .record(decoded)
    }

    /// A rename within the record's directory, replacing an earlier one; a link is moved, never followed.
    package func setAside() throws {
        guard rename(path, path + Self.setAsideSuffix) == 0 || errno == ENOENT else {
            throw VPNDNSOverrideLegacyFileError.system("rename \(path)", errno)
        }
    }

    package func delete() throws {
        guard unlink(path) == 0 || errno == ENOENT else {
            throw VPNDNSOverrideLegacyFileError.system("unlink \(path)", errno)
        }
        let directory = (path as NSString).deletingLastPathComponent
        if rmdir(directory) != 0, errno != ENOENT, errno != ENOTEMPTY {
            throw VPNDNSOverrideLegacyFileError.system("rmdir \(directory)", errno)
        }
    }
}

package enum VPNDNSOverrideLegacyFileError: Error, LocalizedError, Equatable {
    case system(String, Int32)

    package var errorDescription: String? {
        switch self {
        case .system(let step, let code): return "\(step): \(String(cString: strerror(code)))"
        }
    }
}
