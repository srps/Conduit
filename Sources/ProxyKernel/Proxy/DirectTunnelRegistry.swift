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
/// Bounded: at most `capacity()` entries, read per registration from the
/// inbound-connection limit every tracked tunnel already counts against. A
/// tunnel that finds the registry full is not tracked; the count of those is
/// reported with the next migration so none goes unaccounted.
package final class DirectTunnelRegistry: @unchecked Sendable {
    private struct Entry {
        let channel: Channel
        let startedCause: DirectModeCause
    }

    private let lock = NIOLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var untracked = 0
    private let capacity: @Sendable () -> Int

    package init(capacity: @escaping @Sendable () -> Int) {
        self.capacity = capacity
    }

    /// Track `channel` until it closes. Returns false when the registry is
    /// full and the tunnel is left untracked.
    @discardableResult
    package func register(_ channel: Channel, startedCause: DirectModeCause) -> Bool {
        let key = ObjectIdentifier(channel)
        let admitted: Bool = lock.withLock {
            guard entries.count < max(1, capacity()) else {
                untracked += 1
                return false
            }
            entries[key] = Entry(channel: channel, startedCause: startedCause)
            return true
        }
        guard admitted else { return false }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLockVoid { _ = self.entries.removeValue(forKey: key) }
        }
        return true
    }

    package var count: Int { lock.withLock { entries.count } }

    /// Close every tracked tunnel opened under `cause`. Returns how many were
    /// closed and how many tunnels went untracked since the last call.
    package func closeTunnels(openedUnder cause: DirectModeCause) -> (closed: Int, untracked: Int) {
        closeTunnels { startedCause, _ in startedCause == cause }
    }

    /// Close every tracked tunnel whose local address is not in `assigned`:
    /// the VPN took it, so the socket cannot resume.
    package func closeTunnels(orphanedFrom assigned: Set<String>) -> (closed: Int, untracked: Int) {
        closeTunnels { _, channel in LocalAddresses.isOrphaned(channel, assigned: assigned) }
    }

    /// Close every tracked tunnel `shouldClose` selects. Returns how many
    /// were closed and how many tunnels went untracked since the last call.
    package func closeTunnels(
        where shouldClose: (_ startedCause: DirectModeCause, _ channel: Channel) -> Bool
    ) -> (closed: Int, untracked: Int) {
        let (channels, missed): ([Channel], Int) = lock.withLock {
            let matching = entries.filter { shouldClose($0.value.startedCause, $0.value.channel) }
            for key in matching.keys { entries.removeValue(forKey: key) }
            let missed = untracked
            untracked = 0
            // One that closed on its own may not have left yet; it needs no close.
            return (matching.values.map(\.channel).filter(\.isActive), missed)
        }
        for channel in channels { channel.close(mode: .all, promise: nil) }
        return (channels.count, missed)
    }
}
