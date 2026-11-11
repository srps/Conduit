// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A host in the one spelling the DoH upstream route compares hosts in: a
/// provider URL's on one side, a SOCKS request's on the other.
///
/// The two are written by different hands. A provider URL may carry a
/// trailing DNS dot, a Unicode name or an IPv4-mapped IPv6 literal, and
/// CFNetwork sends the listener the punycode name or the bare address.
/// Parsed, each of those is one value. An IPv4 address is strict
/// dotted-quad. Anything else that a resolver would still read as an
/// address names no host, and every other host is a name, matched exactly.
enum DoHProviderHost: Hashable, Sendable {
    /// Dotted-quad text. An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is this address.
    case ipv4(String)
    /// The address as `inet_ntop` prints it.
    case ipv6(String)
    /// Lowercase ASCII, punycode for a Unicode name, with no trailing dot.
    case name(String)

    /// Nil for text that names no host.
    init?(_ text: String) {
        var host = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
        if host.hasSuffix(".") { host.removeLast() }
        // A C parser stops at a NUL and would read only what precedes it.
        guard !host.isEmpty, !host.utf8.contains(0) else { return nil }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                self = .ipv4(bytes[12...].map(String.init).joined(separator: "."))
                return
            }
            var printed = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &printed, socklen_t(printed.count)) != nil else { return nil }
            self = .ipv6(String(decoding: printed.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            return
        }
        if let octets = Self.dottedQuad(host) {
            self = .ipv4(octets.map(String.init).joined(separator: "."))
            return
        }
        // What only `inet_aton` reads as an address (`127.1`, `2130706433`, `0x7f.1`, `0177.0.0.1`, `192.0.02.10`, or an address
        // with a space and anything after it) is an address to a resolver and a name to a string compare. It names no host here.
        var v4 = in_addr()
        guard inet_aton(host, &v4) != 1 else { return nil }
        let name: String
        if host.unicodeScalars.allSatisfy(\.isASCII) {
            name = host.lowercased()
        } else {
            var components = URLComponents()
            components.host = host
            guard let encoded = components.encodedHost else { return nil }
            name = encoded.lowercased()
        }
        guard TunnelAuthority.isHostText(name), !name.contains(where: { ":[]".contains($0) }) else { return nil }
        self = .name(name)
    }

    /// Four decimal octets of one to three digits, none above 255 and none
    /// with a leading zero. Darwin's `inet_pton` takes a leading zero, which
    /// `inet_aton` reads as octal.
    private static func dottedQuad(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  part == "0" || !part.hasPrefix("0"), let octet = UInt8(part) else { return nil }
            octets.append(octet)
        }
        return octets
    }

    /// The host as a CONNECT names it: dotted-quad, bracketed IPv6, or the name.
    var authorityHost: String {
        switch self {
        case .ipv4(let address), .name(let address): address
        case .ipv6(let address): "[\(address)]"
        }
    }

    /// Whether the host is this machine wherever it is resolved: loopback,
    /// the unspecified address, or a `localhost` name. An upstream proxy
    /// asked to tunnel to one would dial itself.
    var isThisMachine: Bool {
        switch self {
        case .ipv4(let address):
            // 127.0.0.0/8 is loopback; 0.0.0.0/8 is "this host", and a connect to it lands on loopback.
            return address.hasPrefix("127.") || address.hasPrefix("0.")
        case .ipv6(let address):
            guard address != "::", address != "::1" else { return true }
            // The deprecated IPv4-compatible form (`::127.0.0.1`) is still routed as that IPv4 address.
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return bytes[0..<12].allSatisfy { $0 == 0 } && (bytes[12] == 127 || bytes[12] == 0)
        case .name(let name):
            return name == "localhost" || name.hasSuffix(".localhost")
        }
    }
}
