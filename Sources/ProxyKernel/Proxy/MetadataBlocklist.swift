// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package enum MetadataBlocklist {
    /// Returns true if the target should be blocked in gateway mode.
    /// Prevents SSRF to cloud metadata endpoints, loopback, and link-local via the proxy.
    package static func isBlocked(host: String, gatewayMode: Bool) -> Bool {
        guard gatewayMode else { return false }
        let h = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingSuffix(".")

        if h == "127.0.0.1" || h == "localhost" || h == "::1" { return true }
        if isBlockedIPv4Literal(h) { return true }
        if isBlockedIPv6Literal(h) { return true }

        if blockedMetadataHostnames.contains(h) { return true }

        return false
    }

    /// Re-checks an already-resolved peer IP literal against the loopback /
    /// link-local / metadata blocklist. Defends against DNS-rebinding: a
    /// hostname that passes the pre-connect `isBlocked(host:)` check but
    /// *resolves* to a blocked address (an attacker-controlled `A`/`AAAA`
    /// record, or a rebinding TTL trick). IP-literal rules only — RFC-1918 is
    /// intentionally allowed, since reaching internal corporate hosts is the
    /// product's purpose.
    ///
    /// Apply this only on the **direct** connect path. Upstream-proxy
    /// connections are operator-configured and may legitimately target
    /// loopback (e.g. a local SASE client's proxy listener).
    package static func isBlockedResolvedAddress(_ ip: String, gatewayMode: Bool) -> Bool {
        isBlocked(host: ip, gatewayMode: gatewayMode)
    }

    /// Thrown on the direct connect path when a resolved peer is blocked, so
    /// the caller can fail the connection exactly like any other connect error.
    package struct BlockedAddressError: Error, LocalizedError {
        package let host: String
        package let resolvedIP: String

        package var errorDescription: String? {
            "\(host) resolved to blocked address \(resolvedIP) (metadata/loopback protection)"
        }
    }

    private static let blockedMetadataHostnames: Set<String> = [
        "metadata.google.internal",
        "metadata.azure.com",
        "metadata.azure-api.net",
    ]

    private static func isBlockedIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)

        if value & 0xff00_0000 == 0x7f00_0000 { return true } // 127.0.0.0/8
        if value & 0xffff_0000 == 0xa9fe_0000 { return true } // 169.254.0.0/16
        if value == 0 { return true }

        return false
    }

    private static func isBlockedIPv6Literal(_ host: String) -> Bool {
        let addressText = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard addressText.contains(":") else { return false }

        var address = in6_addr()
        guard inet_pton(AF_INET6, addressText, &address) == 1 else { return false }

        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16 else { return false }

        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // ::1
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true } // fe80::/10
        if (bytes[0] & 0xfe) == 0xfc { return true } // fc00::/7

        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isBlockedIPv4Bytes(bytes[12...15])
        }

        // Deprecated IPv4-compatible form (`::127.0.0.1`, `::169.254.169.254`).
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isBlockedIPv4Bytes(bytes[12...15])
        }

        return false
    }

    private static func isBlockedIPv4Bytes(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count == 4 else { return false }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if value & 0xff00_0000 == 0x7f00_0000 { return true } // 127.0.0.0/8
        if value & 0xffff_0000 == 0xa9fe_0000 { return true } // 169.254.0.0/16
        if value == 0 { return true }
        return false
    }
}

private extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        hasSuffix(String(suffix)) ? String(dropLast()) : self
    }
}
