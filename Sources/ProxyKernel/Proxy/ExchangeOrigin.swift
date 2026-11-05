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
            hostPort = "\(host.lowercased()):\(components.port ?? (scheme.lowercased() == "https" ? 443 : 80))"
        } else if let host = head.headers.first(name: "Host"), !host.isEmpty {
            self = .authority(host, defaultPort: 80)
        } else {
            hostPort = head.uri.lowercased()
        }
    }

    private init(hostPort: String) { self.hostPort = hostPort }

    package static func connect(_ authority: String) -> ExchangeOrigin { .authority(authority, defaultPort: 443) }

    package static func authority(_ value: String, defaultPort: Int) -> ExchangeOrigin {
        let lowered = value.lowercased()
        if lowered.hasSuffix("]") || !lowered.contains(":") { return ExchangeOrigin(hostPort: "\(lowered):\(defaultPort)") }
        return ExchangeOrigin(hostPort: lowered)
    }
}
