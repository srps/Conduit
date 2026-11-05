// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOHTTP1

/// The origin an exchange asked its upstream for, as lowercased `host:port` with the scheme's default port filled
/// in, so one target is always one origin in `UpstreamSilences`.
package struct ExchangeOrigin: Hashable, Sendable, CustomStringConvertible {
    package let hostPort: String

    package var description: String { hostPort }

    package init(_ head: HTTPRequestHead) {
        if head.method == .CONNECT {
            self = .connect(head.uri)
        } else if let components = URLComponents(string: head.uri), let scheme = components.scheme, let host = components.host, !host.isEmpty {
            hostPort = "\(Self.canonicalHost(host)):\(components.port ?? (scheme.lowercased() == "https" ? 443 : 80))"
        } else if let host = head.headers.first(name: "Host"), !host.isEmpty {
            self = .authority(host, defaultPort: 80)
        } else {
            hostPort = head.uri.lowercased()
        }
    }

    private init(hostPort: String) { self.hostPort = hostPort }

    package static func connect(_ authority: String) -> ExchangeOrigin { .authority(authority, defaultPort: 443) }

    /// The port text is reprinted as a number, so `:080` and `:80` are one origin; a port that does not parse stays as typed.
    package static func authority(_ value: String, defaultPort: Int) -> ExchangeOrigin {
        let lowered = value.lowercased()
        guard !lowered.hasSuffix("]"), let colon = lowered.lastIndex(of: ":") else {
            return ExchangeOrigin(hostPort: "\(canonicalHost(lowered)):\(defaultPort)")
        }
        let host = canonicalHost(String(lowered[..<colon])), portText = lowered[lowered.index(after: colon)...]
        return ExchangeOrigin(hostPort: "\(host):\(Int(portText).map(String.init) ?? String(portText))")
    }

    /// A bracketed IPv6 literal in its RFC 5952 text, so `[::1]` and `[0:0:0:0:0:0:0:1]` are one origin.
    private static func canonicalHost(_ host: String) -> String {
        let lowered = host.lowercased()
        guard lowered.hasPrefix("["), lowered.hasSuffix("]") else { return lowered }
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(lowered.dropFirst().dropLast()), &address) == 1 else { return lowered }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return lowered }
        return "[\(String(cString: text))]"
    }
}
