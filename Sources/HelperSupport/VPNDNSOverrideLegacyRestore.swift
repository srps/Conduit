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
    case undecodable(String)
}

package protocol VPNDNSOverrideLegacyRecordFile {
    func load() -> VPNDNSOverrideLegacyStoredRecord
    func delete() throws
}

package enum VPNDNSLegacyRead: Equatable, Sendable {
    case absent
    /// The store failed, or the key holds a field that cannot be written back.
    case unreadable(String)
    case value([String: VPNDNSValue])
}

/// The only write to a VPN client's key: putting back what an older helper replaced, once.
package protocol VPNDNSLegacyStore {
    func legacyDNS(service: String) -> VPNDNSLegacyRead
    func setDNS(_ value: [String: VPNDNSValue], service: String) -> Bool
}

package enum VPNDNSOverrideLegacyRestore {
    package enum Outcome: Equatable, Sendable {
        case noRecord
        case restored(service: String)
        /// The key no longer holds `127.0.0.1`: the client wrote its own servers, so nothing is written.
        case keyChanged(service: String)
        case keyGone(service: String)
        /// The record stays, for the next start.
        case keyUnreadable(service: String, reason: String)
        /// The record stays, for the next start.
        case restoreFailed(service: String)
        case undecodable(String)
        case deleteFailed(String)

        package var logLine: String {
            let prefix = "vpn-dns-override legacy"
            switch self {
            case .noRecord: return "\(prefix) no record"
            case .restored(let service): return "\(prefix) restored service=\(HelperAudit.safe(service))"
            case .keyChanged(let service): return "\(prefix) key_changed service=\(HelperAudit.safe(service)); left alone"
            case .keyGone(let service): return "\(prefix) key_gone service=\(HelperAudit.safe(service)); left alone"
            case .keyUnreadable(let service, let reason):
                return "\(prefix) key_unreadable service=\(HelperAudit.safe(service)) reason=\"\(HelperAudit.bounded(reason))\"; record kept"
            case .restoreFailed(let service): return "\(prefix) restore_failed service=\(HelperAudit.safe(service)); record kept"
            case .undecodable(let why): return "\(prefix) record undecodable, deleted: \"\(HelperAudit.bounded(why))\""
            case .deleteFailed(let why): return "\(prefix) record delete failed: \"\(HelperAudit.bounded(why))\""
            }
        }

        package var isFailure: Bool {
            switch self {
            case .keyUnreadable, .restoreFailed, .undecodable, .deleteFailed: return true
            default: return false
            }
        }
    }

    /// Compare-then-write: the originals go back only over the `127.0.0.1` the older helper wrote; nothing is deleted.
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
        case .undecodable(let why):
            outcome = .undecodable(why)
        case .record(let record):
            outcome = restore(record, store: store)
        }
        report(outcome)
        switch outcome {
        case .restoreFailed, .keyUnreadable: return outcome
        default: break
        }
        do {
            try file.delete()
        } catch {
            let failure = Outcome.deleteFailed(error.localizedDescription)
            report(failure)
            return failure
        }
        return outcome
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

    package let path: String

    package init(path: String = HelperConstants.legacyVPNDNSOverrideRecordPath) {
        self.path = path
    }

    package func load() -> VPNDNSOverrideLegacyStoredRecord {
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

    package static func decode(_ data: Data) -> VPNDNSOverrideLegacyStoredRecord {
        let decoded: VPNDNSOverrideLegacyRecord
        do {
            decoded = try JSONDecoder().decode(VPNDNSOverrideLegacyRecord.self, from: data)
        } catch {
            return .undecodable("not a record: \(error.localizedDescription)")
        }
        guard decoded.isValid else { return .undecodable("record out of shape") }
        return .record(decoded)
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
