// SPDX-License-Identifier: Apache-2.0

/// The VPN verdicts `ProxyOrchestrator` has reacted to: the last definite one, and whether the monitor is blind now.
///
/// The monitor reports `.unknown` only while it cannot read the store
/// (decision 0048). That report says nothing about the tunnel, so it is kept
/// as `blind` and leaves `definite`, the last verdict that did say something,
/// in place. Every reaction is classified against `definite`: a flap, outage
/// or connect seen through a blind reading is still that flap, outage or
/// connect. `definite == nil` is the cold start: no definite verdict yet in
/// this runtime.
struct VPNReactionHistory: Equatable, Sendable {
    /// A verdict that says something about the tunnel.
    enum Definite: Equatable, Sendable {
        case connected
        case reasserting
        case disconnected(VPNDisconnectReason)

        init?(_ state: VPNObservedState) {
            switch state {
            case .unknown: return nil
            case .connected: self = .connected
            case .reasserting: self = .reasserting
            case .disconnected(let reason): self = .disconnected(reason)
            }
        }

        var observed: VPNObservedState {
            switch self {
            case .connected: .connected
            case .reasserting: .reasserting
            case .disconnected(let reason): .disconnected(reason: reason)
            }
        }
    }

    /// What a report changed.
    enum Change: Equatable, Sendable {
        /// The monitor lost sight of the store. Nothing it acted on is known to have changed.
        case blinded
        /// The same definite verdict again: after a blind reading (`afterBlind`), on another tunnel (`tunnelReplaced`), or only
        /// with a tunnel name where there was none.
        case confirmed(afterBlind: Bool, tunnelReplaced: Bool)
        /// A different definite verdict; `from` is the one before it, nil on the cold start.
        case transition(from: Definite?)
    }

    private(set) var definite: Definite?
    /// The utun carrying a definite `.connected`, when the observer named one. Kept through a blind reading, so a tunnel that
    /// replaced it during the gap is still seen as a replacement.
    private(set) var tunnel: String?
    private(set) var blind = false

    /// What the monitor last said, for display.
    var observed: VPNObservedState { blind ? .unknown : definite?.observed ?? .unknown }

    /// The tunnel to display: none unless the monitor sees a connected VPN.
    var shownTunnel: String? { observed == .connected ? tunnel : nil }

    /// Records a monitor report; nil when it changes nothing.
    mutating func record(_ state: VPNObservedState, tunnel reported: String?) -> Change? {
        guard let next = Definite(state) else {
            guard observed != .unknown else { return nil }
            blind = true
            return .blinded
        }
        let wasBlind = blind
        let previous = definite
        let previousTunnel = tunnel
        blind = false
        definite = next
        tunnel = next == .connected ? reported : nil
        guard previous == next else { return .transition(from: previous) }
        let replaced = previousTunnel != nil && tunnel != nil && previousTunnel != tunnel
        guard wasBlind || replaced || previousTunnel != tunnel else { return nil }
        return .confirmed(afterBlind: wasBlind, tunnelReplaced: replaced)
    }

    /// A flap the orchestrator ended itself (a wake that found the upstream reachable): the VPN is connected again, on a tunnel
    /// the monitor will name. Only while the monitor can read the store: a blind monitor's next good reading decides the flap.
    mutating func recoverFlap() {
        assert(!blind, "a wake recovers no flap the monitor cannot see")
        definite = .connected
        tunnel = nil
    }
}
