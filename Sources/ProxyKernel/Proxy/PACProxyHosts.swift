// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The proxy hostnames PAC answers have routed through, most recently used
/// last, for the DNS forwarder to resolve through a tunnel's servers
/// (decision 0051). `PACRoutingEngine` records the routes of every answer it
/// gives, cached or evaluated; read from any thread. The set belongs to one
/// PAC: it is emptied when PAC is turned off, its URL changes or its script
/// is replaced, and an answer started before that is not recorded.
package final class PACProxyHosts: @unchecked Sendable {
    /// Past it, recording a new host evicts the one used longest ago; an
    /// evicted host resolves as a public name again until an answer names it.
    package static let limit = 32

    /// What an answer was started under.
    package struct Stamp: Equatable, Sendable {
        package var epoch: UInt64
        package var pacURL: String
    }

    private let lock = NSLock()
    private var hosts: [String] = []
    private var epoch: UInt64 = 0
    private var learnedFrom: String?

    package init() {}

    /// Lowercased, no trailing dot, in the order last seen.
    package var current: [String] {
        lock.withLock { hosts }
    }

    /// The hosts while `config` still routes by the PAC they were learned from; otherwise none, and the set is emptied.
    package func current(for config: ProxyConfig) -> [String] {
        lock.withLock {
            let routing = config.pacRoutingEnabled && !config.pacURL.isEmpty
            if routing, learnedFrom.map({ ExactText.same($0, config.pacURL) }) ?? true { return hosts }
            clearLocked()
            return []
        }
    }

    package func stamp(pacURL: String) -> Stamp {
        lock.withLock { Stamp(epoch: epoch, pacURL: pacURL) }
    }

    /// Empties the set; an answer stamped before this is not recorded.
    package func clear() {
        lock.withLock { clearLocked() }
    }

    /// Records `chain` only if nothing cleared the set since `stamp` and `config` still routes by the stamped PAC.
    @discardableResult
    package func record(_ chain: PACChain, stamp: Stamp, config: ProxyConfig) -> Int {
        guard config.pacRoutingEnabled, ExactText.same(config.pacURL, stamp.pacURL) else { return 0 }
        return lock.withLock {
            guard epoch == stamp.epoch else { return 0 }
            if let learnedFrom, !ExactText.same(learnedFrom, stamp.pacURL) { hosts = [] }
            learnedFrom = stamp.pacURL
            return Self.names(in: chain).reduce(0) { $0 + recordLocked($1) }
        }
    }

    /// Records the chain's first `limit` distinct `PROXY` hostnames, last to
    /// first, so its first choice is the newest and a long chain cannot evict
    /// its own head. Returns how many hosts the limit evicted.
    @discardableResult
    package func record(_ chain: PACChain) -> Int {
        lock.withLock { Self.names(in: chain).reduce(0) { $0 + recordLocked($1) } }
    }

    /// Returns how many hosts the limit evicted: 0 or 1.
    @discardableResult
    package func record(host: String) -> Int {
        lock.withLock { recordLocked(ProxyHostNames.normalize(host)) }
    }

    private static func names(in chain: PACChain) -> [String] {
        var seen = Set<String>()
        let names = chain.routes.compactMap { route -> String? in
            guard case .proxy(let host, _) = route else { return nil }
            let name = ProxyHostNames.normalize(host)
            return seen.insert(name).inserted ? name : nil
        }
        return names.prefix(Self.limit).reversed()
    }

    private func recordLocked(_ name: String) -> Int {
        guard !name.isEmpty else { return 0 }
        if hosts.last == name { return 0 }
        hosts.removeAll { $0 == name }
        hosts.append(name)
        let excess = max(hosts.count - Self.limit, 0)
        hosts.removeFirst(excess)
        return excess
    }

    private func clearLocked() {
        hosts = []
        learnedFrom = nil
        epoch &+= 1
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

    /// Whether `name` is one of the names, or one followed by more labels, as a stub resolver appends a search domain
    /// to a relative name. The network can set that domain, so any suffix counts.
    package func containsOrSearchExpands(_ name: String) -> Bool {
        let name = Self.normalize(name)
        var dot = name.firstIndex(of: ".")
        while let end = dot {
            if names.contains(String(name[..<end])) { return true }
            dot = name[name.index(after: end)...].firstIndex(of: ".")
        }
        return names.contains(name)
    }

    package var isEmpty: Bool { names.isEmpty }

    static func normalize(_ host: String) -> String {
        var lower = host.lowercased()
        while lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }
}
