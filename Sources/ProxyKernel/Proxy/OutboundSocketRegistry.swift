// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Whether a VPN-transition sweep closed a tracked channel. The pool and
/// handlers keep it beside the channel: an exchange or handshake that then
/// fails failed because of the sweep, not the upstream or the origin.
package final class TransitionTicket: Sendable {
    private let retired = NIOLockedValueBox(false)

    package var isRetired: Bool { retired.withLockedValue { $0 } }

    fileprivate func retire() { retired.withLockedValue { $0 = true } }
}

/// Every outbound socket a routing decision opens (upstream proxy
/// connections, dedicated CONNECT tunnels, DIRECT origin connections; not a
/// configured direct tunnel, which no VPN state routes), in one registry
/// the orchestrator owns. A confirmed VPN transition closes the ones whose
/// path is gone at once, instead of leaving their clients to a 60 s+
/// timeout (#148, #156). It outlives listener restarts and pool replacement.
///
/// A socket is judged by its path, never by when it was routed: the
/// orchestrator only learns of a VPN change after the network changed, so
/// no ordering against its view says whether a socket still works. The path
/// says it directly (`SocketPathChecking`):
///
/// - `register` checks a socket once it connects. One that connected over a
///   path a transition has since removed is closed on arrival
///   (`connection.late_dial_retired`).
/// - `findStranded` checks every tracked socket and `close` closes what it
///   found; the orchestrator runs them on each confirmed transition and
///   again as routes settle, and closes only if no flap began meanwhile.
/// - `closeUpstream` is the one routing rule: a disconnect whose probe found
///   the upstreams gone routes DIRECT, and their sockets cannot answer.
///
/// Sweeps check outside the lock, retire under it, and close outside it.
/// Bounded: `capacity()` entries, read per registration; a socket that
/// finds the registry full is closed and its operation fails locally, so no
/// socket is ever left untracked.
package final class OutboundSocketRegistry: @unchecked Sendable {
    package enum Route: Sendable {
        case upstream
        case direct
    }

    /// One sweep's closures, by route, and the sockets it could not judge.
    package struct Sweep: Equatable, Sendable {
        package var upstream = 0
        package var direct = 0
        package var unknown = 0
    }

    /// The sockets one check found stranded, not yet closed.
    package struct Stranded: Sendable {
        fileprivate let candidates: [(key: ObjectIdentifier, entry: Entry)]
        package let unknown: Int
    }

    fileprivate struct Entry: Sendable {
        let channel: Channel
        let route: Route
        let ticket: TransitionTicket
    }

    /// What a client is told when its setup is retired.
    package static let retiredMessage = "The VPN changed while connecting; retry the request."
    package static let fullMessage = "Too many open connections to track; retry the request."
    package static let fullEvent = "connection.tracking_full"

    private let lock = NIOLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let capacity: @Sendable () -> Int
    private let paths: any SocketPathChecking
    private let retirementLog: ConnectFailureLog

    package init(capacity: @escaping @Sendable () -> Int, paths: any SocketPathChecking, retirementLog: ConnectFailureLog) {
        self.capacity = capacity
        self.paths = paths
        self.retirementLog = retirementLog
    }

    /// A registry for a component built on its own (tests, tools). The
    /// runtime builds one in `ProxyOrchestrator` and hands it to every
    /// listener, pool and tunnel; never build one per pool there.
    package static func standalone(
        capacity: Int = 4_096, paths: any SocketPathChecking = ClosureSocketPaths { _ in .current }
    ) -> OutboundSocketRegistry {
        OutboundSocketRegistry(capacity: { capacity }, paths: paths,
                               retirementLog: ConnectFailureLog(logger: DiscardingLogSink(), eventSink: nil))
    }

    /// The runtime-wide bound: every tracked socket answers an admitted
    /// client connection (the HTTP/SOCKS budget and the transparent proxy's,
    /// each `inboundConnectionMaxLimit`), a tunnel session, or a pool slot
    /// (the listener's pool and the tunnel pool).
    package static func capacity(for config: ProxyConfig) -> Int {
        let (pools, poolOverflow) = config.maxConnections.multipliedReportingOverflow(by: 2)
        let total = [config.inboundConnectionMaxLimit, config.inboundConnectionMaxLimit,
                     config.maxTunnelSessions, poolOverflow ? Int.max : pools]
            .reduce(0) { sum, next in
                let (value, overflow) = sum.addingReportingOverflow(max(0, next))
                return overflow ? Int.max : value
            }
        return max(1, total)
    }

    /// Track `channel`, just connected, until it closes. When its path is
    /// already gone (a transition ran while it connected) or the registry is
    /// full, close it, report it, and throw a local error
    /// (`vpnTransitionDuringConnect`, `connectionTrackingFull`) that is
    /// neither retried nor fed to a breaker. `target` is the sanitized
    /// `host:port` the dial reached.
    @discardableResult
    package func register(
        _ channel: Channel, route: Route, target: String, upstream: String? = nil
    ) throws -> TransitionTicket {
        let key = ObjectIdentifier(channel)
        let ticket = TransitionTicket()
        let outcome: (error: ConnectionPoolError, reason: LateDialRetired?)?
        if let query = Self.query(channel), case .stranded(let label) = paths.verdicts(for: [query]).first {
            outcome = (.vpnTransitionDuringConnect, .pathGone(label))
        } else {
            outcome = lock.withLock {
                guard entries.count < max(1, capacity()) else { return (.connectionTrackingFull, nil) }
                entries[key] = Entry(channel: channel, route: route, ticket: ticket)
                return nil
            }
        }
        guard let outcome else {
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.withLockVoid {
                    if self.entries[key]?.ticket === ticket { self.entries.removeValue(forKey: key) }
                }
            }
            return ticket
        }
        ticket.retire()
        channel.close(mode: .all, promise: nil)
        report(outcome.error, route: route, target: target, upstream: upstream, reason: outcome.reason)
        throw outcome.error
    }

    private static func query(_ channel: Channel) -> SocketPathQuery? {
        guard let local = channel.localAddress, let remote = channel.remoteAddress else { return nil }
        return SocketPathQuery(local: local, remote: remote)
    }

    private func report(_ outcome: ConnectionPoolError, route: Route, target: String, upstream: String?, reason: LateDialRetired?) {
        let kind = route == .upstream ? "Upstream" : "Direct"
        let via = upstream.map { " via \($0)" } ?? ""
        if let reason {
            retirementLog.report(
                LateDialRetired.event, level: .notice, target: target, upstream: upstream, error: reason,
                message: "\(kind) dial for \(target)\(via) retired: \(reason)", eventAtAnyLevel: true
            )
        } else {
            retirementLog.report(
                Self.fullEvent, level: .warning, target: target, upstream: upstream, error: outcome,
                message: "\(kind) connection to \(target)\(via) refused: the transition registry is full (\(capacity()) sockets)",
                eventAtAnyLevel: true
            )
        }
    }

    package var count: Int { lock.withLock { entries.count } }

    /// Close every tracked socket whose path is gone, or with
    /// `addressesOnly` only those whose local address is gone.
    package func closeStranded(addressesOnly: Bool = false) -> Sweep {
        close(findStranded(addressesOnly: addressesOnly))
    }

    /// Every tracked socket whose path is gone, or with `addressesOnly`
    /// whose local address is gone; nothing is closed yet. Checks every
    /// socket against the machine, so callers run it off the owner, the
    /// concurrency pool and the event loops.
    package func findStranded(addressesOnly: Bool = false) -> Stranded {
        let tracked = lock.withLock { entries.map { (key: $0.key, entry: $0.value) } }
        var checked: [(key: ObjectIdentifier, entry: Entry)] = []
        var queries: [SocketPathQuery] = []
        for item in tracked {
            // A socket that closed has no addresses; it is leaving anyway.
            guard let query = Self.query(item.entry.channel) else { continue }
            checked.append(item)
            queries.append(query)
        }
        var unknown = 0
        var stranded: [(key: ObjectIdentifier, entry: Entry)] = []
        for (item, verdict) in zip(checked, paths.verdicts(for: queries)) {
            switch verdict {
            case .current: break
            case .stranded(let label):
                if !addressesOnly || label == SocketPathVerdict.addressGone { stranded.append(item) }
            case .unknown: unknown += 1
            }
        }
        return Stranded(candidates: stranded, unknown: unknown)
    }

    /// Close what `findStranded` found, skipping any socket that closed or
    /// left meanwhile.
    package func close(_ found: Stranded) -> Sweep {
        var result = close(retire(found.candidates))
        result.unknown = found.unknown
        return result
    }

    /// A disconnect that routes DIRECT: every upstream socket, since the
    /// proxies are behind the VPN.
    package func closeUpstream() -> Int {
        let upstream = lock.withLock {
            entries.filter { $0.value.route == .upstream }.map { (key: $0.key, entry: $0.value) }
        }
        return close(retire(upstream)).upstream
    }

    /// Retire the candidates still registered under the same ticket; one
    /// that closed and left meanwhile is skipped.
    private func retire(_ candidates: [(key: ObjectIdentifier, entry: Entry)]) -> [Entry] {
        lock.withLock {
            candidates.compactMap { candidate in
                guard entries[candidate.key]?.ticket === candidate.entry.ticket else { return nil }
                candidate.entry.ticket.retire()
                entries.removeValue(forKey: candidate.key)
                return candidate.entry
            }
        }
    }

    private func close(_ selected: [Entry]) -> Sweep {
        var result = Sweep()
        for entry in selected {
            // One that closed on its own may not have left yet; it needs no close.
            guard entry.channel.isActive else { continue }
            entry.channel.close(mode: .all, promise: nil)
            switch entry.route {
            case .upstream: result.upstream += 1
            case .direct: result.direct += 1
            }
        }
        return result
    }
}

/// The error a late-dial retirement reports through `ConnectFailureLog`, as
/// `connection.late_dial_retired` (#148). Its description is the event's
/// `reason=`.
package struct LateDialRetired: Error, CustomStringConvertible, Sendable {
    package let description: String

    package init(_ description: String) {
        self.description = description
    }

    package static let event = "connection.late_dial_retired"

    /// The socket connected over a path a VPN transition then removed.
    package static func pathGone(_ label: String) -> LateDialRetired {
        LateDialRetired("its path was gone when it connected (\(label))")
    }
}
