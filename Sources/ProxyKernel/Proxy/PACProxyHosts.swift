// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The proxy hostnames PAC answers have routed through, most recently used
/// last, for the DNS forwarder to resolve through a tunnel's servers
/// (decision 0051). `PACRoutingEngine` records a chain on every answer it
/// gives, cached or evaluated; read from any thread.
package final class PACProxyHosts: @unchecked Sendable {
    /// Past it, recording a new host evicts the one used longest ago; an
    /// evicted host resolves as a public name again until an answer names it.
    package static let limit = 32

    private let lock = NSLock()
    private var hosts: [String] = []

    package init() {}

    /// Lowercased, no trailing dot, in the order last seen.
    package var current: [String] {
        lock.withLock { hosts }
    }

    package func record(_ chain: PACChain) {
        for route in chain.routes {
            guard case .proxy(let host, _) = route else { continue }
            record(host: host)
        }
    }

    package func record(host: String) {
        let name = ProxyHostNames.normalize(host)
        guard !name.isEmpty else { return }
        lock.withLock {
            if hosts.last == name { return }
            hosts.removeAll { $0 == name }
            hosts.append(name)
            if hosts.count > Self.limit { hosts.removeFirst(hosts.count - Self.limit) }
        }
    }
}

/// The hostnames Conduit itself dials as upstream proxies: the enabled
/// configured upstreams and the hosts PAC answers named. Matched exactly,
/// ignoring case and a trailing dot.
package struct ProxyHostNames: Hashable, Sendable {
    package static let empty = ProxyHostNames(names: [])

    private let names: Set<String>

    package init(names: some Sequence<String>) {
        self.names = Set(names.map(Self.normalize).filter { !$0.isEmpty })
    }

    package init(config: ProxyConfig, pacHosts: [String]) {
        self.init(names: config.upstreams.filter(\.enabled).map(\.host) + pacHosts)
    }

    package func contains(_ name: String) -> Bool {
        names.contains(Self.normalize(name))
    }

    package var isEmpty: Bool { names.isEmpty }

    static func normalize(_ host: String) -> String {
        var lower = host.lowercased()
        while lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }
}
