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
    case unreadable(String)
    /// Read, but not a record: a link, too large, not JSON or out of shape.
    case malformed(String)
}

/// What the helper reports at start about an older helper's record. Nothing writes the VPN's key or the record: the
/// VPN client puts its own servers back when it reconnects, and the record under `/var/run` goes at the next boot.
package enum VPNDNSOverrideLegacyCheck {
    package enum Outcome: Equatable, Sendable {
        case noRecord
        case awaitingRecovery(service: String)
        case recordUnreadable(String)
        case malformed(String)

        package var logLine: String {
            let prefix = "vpn-dns-override legacy"
            switch self {
            case .noRecord: return "\(prefix) no record"
            case .awaitingRecovery(let service):
                return "\(prefix) awaiting_recovery service=\(HelperAudit.safe(service)); an older helper may have left "
                    + "127.0.0.1 in the VPN's key, and this helper never writes it. Reconnect the VPN to put its servers back"
            case .recordUnreadable(let why): return "\(prefix) record_unreadable reason=\"\(HelperAudit.bounded(why))\""
            case .malformed(let why): return "\(prefix) record_malformed reason=\"\(HelperAudit.bounded(why))\""
            }
        }
    }

    @discardableResult
    package static func check(file: VPNDNSOverrideLegacyFile, report: (Outcome) -> Void) -> Outcome {
        let outcome: Outcome
        switch file.load() {
        case .none: return .noRecord
        case .record(let record): outcome = .awaitingRecovery(service: record.serviceID)
        case .unreadable(let why): outcome = .recordUnreadable(why)
        case .malformed(let why): outcome = .malformed(why)
        }
        report(outcome)
        return outcome
    }
}

/// The older helper's record under `/var/run`, root-owned 0600. Read only.
package struct VPNDNSOverrideLegacyFile {
    package static let maximumBytes = 16_384

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
}
