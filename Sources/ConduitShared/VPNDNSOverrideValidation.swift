// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum VPNDNSOverrideValidation {
    public static let maximumServers = 16

    /// No `/`, so a service ID cannot address another key.
    public static func isServiceID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || "._-".unicodeScalars.contains(scalar)
        }
    }

    /// Loopback or unspecified would point the tunnel's servers back at this Mac.
    public static func isTunnelServer(_ address: String) -> Bool {
        IPAddressSyntax.isLiteral(address) && !isLoopback(address) && !isUnspecified(address)
    }

    public static func isLoopback(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { bytes in
                let ipv6Loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                let mappedLoopback = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
                return ipv6Loopback || mappedLoopback
            }
        }
        return false
    }

    public static func isUnspecified(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return v4.s_addr == 0 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { $0.allSatisfy { $0 == 0 } }
        }
        return false
    }

    /// The servers the relay may fail over to, in order, without repeats.
    public static func failoverServers(_ servers: [String]) -> [String] {
        var kept: [String] = []
        for server in servers where isTunnelServer(server) && !kept.contains(server) {
            kept.append(server)
        }
        return kept
    }
}
