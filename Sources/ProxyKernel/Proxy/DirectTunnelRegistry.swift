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

/// Established direct (origin-dialed) tunnels and whether each was dialed
/// while the VPN was confirmed down, so a VPN reconnect can retire them (#148).
///
/// A full-tunnel VPN that comes back reroutes the origin's traffic through
/// the utun while the socket keeps its physical-interface source address;
/// such a tunnel stalls until a 60 s+ timeout. Closing it at once lets the
/// client reconnect along the reconnected routing (PAC or upstream).
///
/// "Dialed while the VPN was down" is the VPN state, not the direct-mode
/// cause: while the probe is pending, or on-prem with a reachable upstream,
/// the cause is `.none`, yet a no-proxy or PAC-DIRECT dial still leaves on
/// the off-VPN path. The orchestrator marks the outage on a confirmed
/// disconnect and ends it with the reconnect sweep, under the same lock.
///
/// A dial outlives the instant it starts: `beginDial()` captures the outage
/// flag and the sweep epoch together, and `register` retires a tunnel a
/// sweep run during the dial would have closed (`TransitionSweeps`).
///
/// Bounded: at most `capacity()` entries, read per registration from the
/// inbound-connection limit every tracked tunnel already counts against, and
/// the last `TransitionSweeps.capacity` sweeps. A tunnel that finds the
/// registry full is not tracked; the count of those is reported with the
/// next sweep so none goes unaccounted.
package final class DirectTunnelRegistry: @unchecked Sendable {
    /// What registration did with a tunnel.
    package enum Registration: Equatable, Sendable {
        case tracked
        /// The registry was full; the tunnel is left to its own timeout.
        case untracked
        /// A sweep that ran during the dial would have closed it; it is
        /// closed now and counted as `lateClosed` in the next sweep.
        case retired
    }

    /// What a dial captured when it started.
    package struct Dial: Equatable, Sendable {
        package let epoch: UInt64
        package let whileVPNDown: Bool
    }

    /// One sweep's outcome. `lateClosed` counts tunnels retired on
    /// registration since the previous sweep; `untracked` those that found
    /// the registry full.
    package struct Sweep: Equatable, Sendable {
        package var closed: Int
        package var untracked: Int
        package var lateClosed: Int
    }

    private enum Rule {
        case openedWhileVPNDown
        case orphanedFrom(Set<String>)

        func selects(_ dial: Dial, channel: Channel) -> Bool {
            switch self {
            case .openedWhileVPNDown: return dial.whileVPNDown
            case .orphanedFrom(let assigned): return LocalAddresses.isOrphaned(channel, assigned: assigned)
            }
        }
    }

    private struct Entry {
        let channel: Channel
        let dial: Dial
    }

    /// What a client is told when its tunnel is retired on registration.
    package static let retiredMessage = "The VPN changed while connecting; retry the request."

    private let lock = NIOLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var untracked = 0
    private var lateClosed = 0
    private var vpnDown = false
    private var sweeps = TransitionSweeps<Rule>()
    private let capacity: @Sendable () -> Int

    package init(capacity: @escaping @Sendable () -> Int) {
        self.capacity = capacity
    }

    /// Capture before a direct dial starts; pass to `register`.
    package func beginDial() -> Dial {
        lock.withLock { Dial(epoch: sweeps.epoch, whileVPNDown: vpnDown) }
    }

    /// A confirmed disconnect: dials from now on are off the VPN.
    package func markVPNDown() {
        lock.withLockVoid { vpnDown = true }
    }

    /// Track `channel` until it closes, unless a sweep that ran since the
    /// dial began would have closed it: then close it now.
    @discardableResult
    package func register(_ channel: Channel, dial: Dial) -> Registration {
        let key = ObjectIdentifier(channel)
        let registration: Registration = lock.withLock {
            if sweeps.retires(since: dial.epoch, { $0.selects(dial, channel: channel) }) {
                lateClosed += 1
                return .retired
            }
            guard entries.count < max(1, capacity()) else {
                untracked += 1
                return .untracked
            }
            entries[key] = Entry(channel: channel, dial: dial)
            return .tracked
        }
        switch registration {
        case .tracked:
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lock.withLockVoid { _ = self.entries.removeValue(forKey: key) }
            }
        case .retired:
            channel.close(mode: .all, promise: nil)
        case .untracked:
            break
        }
        return registration
    }

    package var count: Int { lock.withLock { entries.count } }

    /// End the outage and close every tracked tunnel dialed during it, as
    /// one step: a dial starting after this is on the VPN, one that started
    /// before is retired when it registers. `nil` when no outage was marked.
    package func closeTunnelsOpenedWhileVPNDown() -> Sweep? {
        sweep(.openedWhileVPNDown, endingOutage: true)
    }

    /// Close every tracked tunnel whose local address is not in `assigned`:
    /// the VPN took it, so the socket is not expected to resume.
    package func closeTunnels(orphanedFrom assigned: Set<String>) -> Sweep {
        sweep(.orphanedFrom(assigned), endingOutage: false) ?? Sweep(closed: 0, untracked: 0, lateClosed: 0)
    }

    private func sweep(_ rule: Rule, endingOutage: Bool) -> Sweep? {
        let swept: (channels: [Channel], untracked: Int, late: Int)? = lock.withLock {
            if endingOutage {
                guard vpnDown else { return nil }
                vpnDown = false
            }
            sweeps.record(rule)
            let matching = entries.filter { rule.selects($0.value.dial, channel: $0.value.channel) }
            for key in matching.keys { entries.removeValue(forKey: key) }
            let counts = (untracked, lateClosed)
            untracked = 0
            lateClosed = 0
            // One that closed on its own may not have left yet; it needs no close.
            return (matching.values.map(\.channel).filter(\.isActive), counts.0, counts.1)
        }
        guard let swept else { return nil }
        for channel in swept.channels { channel.close(mode: .all, promise: nil) }
        return Sweep(closed: swept.channels.count, untracked: swept.untracked, lateClosed: swept.late)
    }
}
