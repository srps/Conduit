// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// The machine's assigned IP addresses, to find sockets a VPN disconnect
/// stranded: a socket whose local address is gone is not expected to resume (#148).
package enum LocalAddresses {
    package static func assigned() throws -> Set<String> {
        Set(try System.enumerateDevices().compactMap { $0.address?.ipAddress })
    }

    /// A channel with no known local address is never orphaned.
    package static func isOrphaned(_ channel: Channel, assigned: Set<String>) -> Bool {
        guard let local = channel.localAddress?.ipAddress else { return false }
        return !assigned.contains(local)
    }
}

/// What an operation captured about routing when it started, before any
/// asynchronous step (body, PAC, DNS, connect, auth) (#156).
package struct RoutingStamp: Equatable, Sendable {
    /// The authority's generation; any confirmed VPN transition moves it.
    package let generation: UInt64
    /// Whether the VPN was confirmed down: a DIRECT socket dialed then
    /// leaves on the off-VPN path, whatever the direct-mode cause says.
    package let whileVPNDown: Bool
}

/// Whether a VPN-transition sweep closed a tracked channel. The pool and
/// handlers keep it beside the channel: an exchange or handshake that then
/// fails failed because of the sweep, not the upstream.
package final class TransitionTicket: Sendable {
    private let retired = NIOLockedValueBox(false)

    package var isRetired: Bool { retired.withLockedValue { $0 } }

    fileprivate func retire() { retired.withLockedValue { $0 = true } }
}

/// Every outbound socket a routing decision opens (upstream proxy
/// connections, dedicated CONNECT tunnels, DIRECT origin connections; not a
/// configured direct tunnel, which no VPN state routes), in one registry
/// the orchestrator owns, so a confirmed VPN transition closes the ones it
/// stranded at once instead of leaving their clients to a 60 s+ timeout
/// (#148, #156). It outlives listener restarts and pool replacement.
///
/// An operation captures a `RoutingStamp` before its first asynchronous
/// step and passes it to `register` once its socket connects. Every
/// confirmed transition advances the generation, so a socket whose setup
/// straddled one is closed on arrival (`connection.late_dial_retired`): it
/// was routed for a network that is gone. A registered socket is then
/// judged only by the sweeps' predicates:
///
/// - `closeOrphaned`: its local address is no longer assigned.
/// - `closeUpstream`: the disconnect routes DIRECT; every upstream socket.
/// - `endOutage`: the reconnect; DIRECT sockets dialed while the VPN was
///   confirmed down. A PAC-DIRECT socket opened while connected stays.
///
/// Sweeps mark and remove under the lock and close outside it. Bounded:
/// `capacity()` entries, read per registration; a socket that finds the
/// registry full is closed and its operation fails locally, so no socket is
/// ever left untracked.
package final class TransitionAuthority: @unchecked Sendable {
    package enum Route: Sendable {
        case upstream
        case direct
    }

    /// One sweep's closures, by route.
    package struct Sweep: Equatable, Sendable {
        package var upstream = 0
        package var direct = 0
    }

    private struct Entry {
        let channel: Channel
        let route: Route
        let dialedWhileDown: Bool
        let ticket: TransitionTicket
    }

    /// What a client is told when its setup is retired.
    package static let retiredMessage = "The VPN changed while connecting; retry the request."
    package static let fullMessage = "Too many open connections to track; retry the request."
    package static let fullEvent = "connection.tracking_full"

    private let lock = NIOLock()
    private var generation: UInt64 = 0
    private var vpnDown = false
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let capacity: @Sendable () -> Int
    private let retirementLog: ConnectFailureLog

    package init(capacity: @escaping @Sendable () -> Int, retirementLog: ConnectFailureLog) {
        self.capacity = capacity
        self.retirementLog = retirementLog
    }

    /// An authority for a component built on its own (tests, tools). The
    /// runtime builds one in `ProxyOrchestrator` and hands it to every
    /// listener, pool and tunnel; never build one per pool there.
    package static func standalone(capacity: Int = 4_096) -> TransitionAuthority {
        TransitionAuthority(capacity: { capacity },
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

    /// Capture before the operation's first asynchronous step.
    package func stamp() -> RoutingStamp {
        lock.withLock { RoutingStamp(generation: generation, whileVPNDown: vpnDown) }
    }

    /// Whether no confirmed transition ran since `stamp`.
    package func isCurrent(_ stamp: RoutingStamp) -> Bool {
        lock.withLock { stamp.generation == generation }
    }

    /// Checked right before an operation opens or reuses a socket: when a
    /// confirmed transition ran since `stamp`, its routing is stale, so it
    /// opens nothing. Reports `connection.late_dial_retired` and returns
    /// the local error to fail with; `nil` when the stamp is current.
    package func refusal(_ stamp: RoutingStamp, route: Route, target: String, upstream: String? = nil) -> Error? {
        guard !isCurrent(stamp) else { return nil }
        report(.vpnTransitionDuringConnect, route: route, target: target, upstream: upstream, reason: LateDialRetired.beforeDial)
        return ConnectionPoolError.vpnTransitionDuringConnect
    }

    /// Track `channel` until it closes, unless a confirmed transition ran
    /// since `stamp` or the registry is full: then close it, report it, and
    /// throw a local error (`vpnTransitionDuringConnect`,
    /// `connectionTrackingFull`) that is neither retried nor fed to a
    /// breaker. `target` is the sanitized `host:port` the dial reached.
    @discardableResult
    package func register(
        _ channel: Channel, route: Route, stamp: RoutingStamp, target: String, upstream: String? = nil
    ) throws -> TransitionTicket {
        let key = ObjectIdentifier(channel)
        let ticket = TransitionTicket()
        let outcome: ConnectionPoolError? = lock.withLock {
            guard stamp.generation == generation else { return .vpnTransitionDuringConnect }
            guard entries.count < max(1, capacity()) else { return .connectionTrackingFull }
            entries[key] = Entry(channel: channel, route: route, dialedWhileDown: stamp.whileVPNDown, ticket: ticket)
            return nil
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
        report(outcome, route: route, target: target, upstream: upstream, reason: LateDialRetired.transition)
        throw outcome
    }

    private func report(_ outcome: ConnectionPoolError, route: Route, target: String, upstream: String?, reason: LateDialRetired) {
        let kind = route == .upstream ? "Upstream" : "Direct"
        let via = upstream.map { " via \($0)" } ?? ""
        if outcome == .vpnTransitionDuringConnect {
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

    /// A confirmed disconnect: from now on DIRECT dials leave off the VPN,
    /// and setup that started before it is retired on arrival.
    package func beginOutage() {
        lock.withLockVoid {
            generation &+= 1
            vpnDown = true
        }
    }

    /// Close every tracked socket whose local address is not in `assigned`:
    /// the VPN took it, so the socket is not expected to resume. A stale
    /// disconnect report passes `retiringSetup: false`: a newer state
    /// already owns routing, and setup begun under it must stand.
    package func closeOrphaned(from assigned: Set<String>, retiringSetup: Bool = true) -> Sweep {
        sweep(endingOutage: false, advancing: retiringSetup) { LocalAddresses.isOrphaned($0.channel, assigned: assigned) } ?? Sweep()
    }

    /// A disconnect that routes DIRECT: every upstream socket, since the
    /// proxies are behind the VPN.
    package func closeUpstream() -> Int {
        sweep(endingOutage: false) { $0.route == .upstream }?.upstream ?? 0
    }

    /// End the outage and close every DIRECT socket dialed during it, as
    /// one step. `nil` when no outage was marked.
    package func endOutage() -> Int? {
        sweep(endingOutage: true) { $0.route == .direct && $0.dialedWhileDown }?.direct
    }

    private func sweep(endingOutage: Bool, advancing: Bool = true, _ selects: (Entry) -> Bool) -> Sweep? {
        let selected: [Entry]? = lock.withLock {
            if endingOutage {
                guard vpnDown else { return nil }
                vpnDown = false
            }
            if advancing { generation &+= 1 }
            let matching = entries.filter { selects($0.value) }
            for (key, entry) in matching {
                entry.ticket.retire()
                entries.removeValue(forKey: key)
            }
            return Array(matching.values)
        }
        guard let selected else { return nil }
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
    package static let transition = LateDialRetired("a confirmed VPN transition ran while it was set up")
    package static let beforeDial = LateDialRetired("a confirmed VPN transition ran before it dialed")
}
