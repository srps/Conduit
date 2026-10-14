// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// The machine's assigned IP addresses, to find sockets a VPN disconnect
/// stranded: a socket whose local address is gone cannot resume (#148).
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

/// Established direct (origin-dialed) tunnels and the direct-mode cause they
/// were opened under, so a VPN reconnect can retire the ones dialed only
/// because the VPN was down (#148).
///
/// A full-tunnel VPN that comes back reroutes the origin's traffic through
/// the utun while the socket keeps its physical-interface source address;
/// such a tunnel stalls until a 60 s+ timeout. Closing it at once lets the
/// client reconnect along the reconnected routing (PAC or upstream).
///
/// A dial outlives the instant its cause is read: it captures `epoch` when
/// it starts and passes it to `register`. Every sweep advances the epoch
/// under the same lock, so a tunnel that completes after a sweep it would
/// have matched is retired on registration instead of escaping the sweep.
///
/// Bounded: at most `capacity()` entries, read per registration from the
/// inbound-connection limit every tracked tunnel already counts against, and
/// the last `sweepHistory` sweeps. A tunnel that finds the registry full is
/// not tracked; the count of those is reported with the next sweep so none
/// goes unaccounted. A dial older than every remembered sweep has crossed
/// that many transitions and is retired.
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

    /// One sweep's outcome. `lateClosed` counts tunnels retired on
    /// registration since the previous sweep; `untracked` those that found
    /// the registry full.
    package struct Sweep: Equatable, Sendable {
        package var closed: Int
        package var untracked: Int
        package var lateClosed: Int
    }

    private enum Rule {
        case openedUnder(DirectModeCause)
        case orphanedFrom(Set<String>)

        func selects(startedCause: DirectModeCause, channel: Channel) -> Bool {
            switch self {
            case .openedUnder(let cause): return startedCause == cause
            case .orphanedFrom(let assigned): return LocalAddresses.isOrphaned(channel, assigned: assigned)
            }
        }
    }

    private struct Entry {
        let channel: Channel
        let startedCause: DirectModeCause
    }

    package static let sweepHistory = 8

    /// What a client is told when its tunnel is retired on registration.
    package static let retiredMessage = "The VPN changed while connecting; retry the request."

    private let lock = NIOLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var untracked = 0
    private var lateClosed = 0
    private var currentEpoch: UInt64 = 0
    /// The most recent sweeps, oldest first; each tagged with the epoch it advanced to.
    private var sweeps: [(epoch: UInt64, rule: Rule)] = []
    private let capacity: @Sendable () -> Int

    package init(capacity: @escaping @Sendable () -> Int) {
        self.capacity = capacity
    }

    /// The transition generation a dial captures before it starts.
    package var epoch: UInt64 { lock.withLock { currentEpoch } }

    /// Track `channel` until it closes, unless a sweep that ran since
    /// `epoch` would have closed it: then close it now.
    @discardableResult
    package func register(_ channel: Channel, startedCause: DirectModeCause, epoch: UInt64) -> Registration {
        let key = ObjectIdentifier(channel)
        let registration: Registration = lock.withLock {
            if epoch < currentEpoch {
                let missed = sweeps.filter { $0.epoch > epoch }
                let forgotten = (sweeps.first?.epoch ?? currentEpoch) > epoch + 1
                if forgotten || missed.contains(where: { $0.rule.selects(startedCause: startedCause, channel: channel) }) {
                    lateClosed += 1
                    return .retired
                }
            }
            guard entries.count < max(1, capacity()) else {
                untracked += 1
                return .untracked
            }
            entries[key] = Entry(channel: channel, startedCause: startedCause)
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

    /// Close every tracked tunnel opened under `cause`.
    package func closeTunnels(openedUnder cause: DirectModeCause) -> Sweep {
        sweep(.openedUnder(cause))
    }

    /// Close every tracked tunnel whose local address is not in `assigned`:
    /// the VPN took it, so the socket cannot resume.
    package func closeTunnels(orphanedFrom assigned: Set<String>) -> Sweep {
        sweep(.orphanedFrom(assigned))
    }

    private func sweep(_ rule: Rule) -> Sweep {
        let (channels, missed, late): ([Channel], Int, Int) = lock.withLock {
            currentEpoch += 1
            sweeps.append((currentEpoch, rule))
            if sweeps.count > Self.sweepHistory { sweeps.removeFirst(sweeps.count - Self.sweepHistory) }
            let matching = entries.filter { rule.selects(startedCause: $0.value.startedCause, channel: $0.value.channel) }
            for key in matching.keys { entries.removeValue(forKey: key) }
            let counts = (untracked, lateClosed)
            untracked = 0
            lateClosed = 0
            // One that closed on its own may not have left yet; it needs no close.
            return (matching.values.map(\.channel).filter(\.isActive), counts.0, counts.1)
        }
        for channel in channels { channel.close(mode: .all, promise: nil) }
        return Sweep(closed: channels.count, untracked: missed, lateClosed: late)
    }
}
