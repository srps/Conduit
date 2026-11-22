// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The proxy hostnames PAC answers have routed through, most recently used
/// last, for the DNS forwarder to resolve through a tunnel's servers
/// (decision 0051). `PACRoutingEngine` records the routes of every answer it
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

    /// Records the chain's first `limit` `PROXY` hosts, last to first, so
    /// its first choice is the newest and a long chain cannot evict its own
    /// head. Returns how many hosts the limit evicted.
    @discardableResult
    package func record(_ chain: PACChain) -> Int {
        let proxies = chain.routes.compactMap { route -> String? in
            guard case .proxy(let host, _) = route else { return nil }
            return host
        }
        return proxies.prefix(Self.limit).reversed().reduce(0) { $0 + record(host: $1) }
    }

    /// Returns how many hosts the limit evicted: 0 or 1.
    @discardableResult
    package func record(host: String) -> Int {
        let name = ProxyHostNames.normalize(host)
        guard !name.isEmpty else { return 0 }
        return lock.withLock {
            if hosts.last == name { return 0 }
            hosts.removeAll { $0 == name }
            hosts.append(name)
            let excess = max(hosts.count - Self.limit, 0)
            hosts.removeFirst(excess)
            return excess
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
