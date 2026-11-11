// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The two flap windows, as `HealthSection` configures them.
package struct VPNFlapWindow: Equatable, Sendable {
    /// How long a tunnel may be without its address before the loss shows.
    /// Zero or less disables the debounce.
    package var minVisible: TimeInterval
    /// How long `.reasserting` lasts before the loss is a disconnect.
    package var grace: TimeInterval

    package init(minVisible: TimeInterval = 1, grace: TimeInterval = 5) {
        self.minVisible = minVisible
        self.grace = grace
    }
}

/// What one reconcile concluded. Everything here is derived from the reading,
/// the clock and the timer's memory at that call; none of it is stored.
package struct VPNDetection: Equatable, Sendable {
    package enum Phase: Equatable, Sendable {
        /// A tunnel counts as up.
        case up
        /// None counts, but one lost its address less than `minVisible` ago.
        case debouncing
        /// The loss is visible and the grace window is running.
        case reasserting
        case down(VPNDisconnectReason)
        /// The store could not be read, so nothing is known.
        case blind(TunnelReading.Failure)
    }

    package let phase: Phase
    /// The tunnels behind a `.connected` state, in name order: those that
    /// count, and those still inside their debounce. Empty otherwise.
    package let carrying: [String]
    /// Every tunnel not declared gone, in name order: those that count and
    /// those that lost their address and are still in the store.
    package let live: [String]
    /// When this detection changes with no change to the store. The caller
    /// reconciles again then; a late or missing wake-up costs latency only,
    /// because the next reconcile compares against the clock.
    package let deadline: TimeInterval?

    package var state: VPNObservedState {
        switch phase {
        case .up, .debouncing: .connected
        case .reasserting: .reasserting
        case .down(let reason): .disconnected(reason: reason)
        case .blind: .unknown
        }
    }
}

/// The only memory VPN detection keeps between readings: when each tunnel
/// lost its address, and when the state was last connected. One value lives
/// for one observation session; a new session starts from `init()`.
///
/// `reconcile` takes a whole reading and the current time and returns the
/// verdict. Repeating a call changes nothing, and a missed reading is made
/// good by the next one, whatever prompted it.
package struct VPNFlapTimer: Equatable, Sendable {
    /// Tunnels that stopped counting while observed and are still in the
    /// store, with the time of the reading that first saw the loss. No larger
    /// than the snapshot: an interface the store drops leaves here too.
    private var lostAt: [String: TimeInterval] = [:]
    /// The interfaces that counted in the last reading.
    private var counted: Set<String> = []
    /// The latest instant the state is known to have been `.connected`: a
    /// reading with a tunnel counting, or the end of a debounce. Nil until
    /// the session has seen the VPN up. Grace is measured from here, so it
    /// outlasts the tunnels that set it.
    private var connectedUntil: TimeInterval?

    package init() {}

    /// `now` is a monotonic clock in seconds; only differences matter.
    package mutating func reconcile(
        _ reading: TunnelReading,
        now: TimeInterval,
        window: VPNFlapWindow,
        up: VPNUpPredicate = .anyIPv4Tunnel
    ) -> VPNDetection {
        let snapshot: TunnelSnapshot
        switch reading {
        case .failed(let failure):
            // Memory is left alone: the next reading that succeeds is judged
            // against the clock as if this one had not been attempted.
            return VPNDetection(phase: .blind(failure), carrying: [], live: [], deadline: nil)
        case .snapshot(let read):
            snapshot = read
        }
        let minVisible = max(0, window.minVisible)

        // Up to this reading the state was what the last one left: connected
        // until now if a tunnel counted, else until the last debounce ended.
        if !counted.isEmpty {
            connectedUntil = now
        } else if let lastLoss = lostAt.values.max() {
            connectedUntil = max(connectedUntil ?? -.infinity, min(now, lastLoss + minVisible))
        }

        let countedNow = Set(snapshot.tunnels.filter(up.counts).map(\.interface))
        var lost: [String: TimeInterval] = [:]
        for tunnel in snapshot.tunnels where tunnel.hasInterfaceKey && !countedNow.contains(tunnel.interface) {
            if let since = lostAt[tunnel.interface] {
                lost[tunnel.interface] = since
            } else if counted.contains(tunnel.interface) {
                lost[tunnel.interface] = now
            }
        }
        if !countedNow.isEmpty { connectedUntil = now }
        lostAt = lost
        counted = countedNow

        let debouncing = lost.filter { now < $0.value + minVisible }
        let nextDebounceEnd = debouncing.values.min().map { $0 + minVisible }
        let live = countedNow.union(lost.keys).sorted()

        if !countedNow.isEmpty || !debouncing.isEmpty {
            return VPNDetection(
                phase: countedNow.isEmpty ? .debouncing : .up,
                carrying: countedNow.union(debouncing.keys).sorted(),
                live: live,
                deadline: nextDebounceEnd
            )
        }
        guard let connectedUntil else {
            return VPNDetection(phase: .down(.unknown), carrying: [], live: [], deadline: nil)
        }
        if lost.isEmpty {
            // The VPN was up in this session and no tunnel is waiting to
            // recover: its interfaces were removed outright.
            return VPNDetection(phase: .down(.userInitiated), carrying: [], live: [], deadline: nil)
        }
        let graceEnd = connectedUntil + window.grace
        if now < graceEnd {
            return VPNDetection(phase: .reasserting, carrying: [], live: live, deadline: graceEnd)
        }
        return VPNDetection(phase: .down(.networkLost), carrying: [], live: live, deadline: nil)
    }
}
