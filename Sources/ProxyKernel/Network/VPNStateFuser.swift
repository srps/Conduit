// SPDX-License-Identifier: Apache-2.0
// Pure value-type state machine for interpreting per-utun raw observations
// into `VPNObservedState` transitions. Extracted from `VPNStatusMonitor.swift`
// so the fuser + its observation / decision types stay kernel-side
// while the SCDynamicStore-backed production monitor moves to `PlatformMac`.
// `VPNStateFuser` is already tested directly via `VPNStateFuserTests`; the
// production monitor in `PlatformMac/VPNStatusMonitor.swift` calls it via
// `import ConduitCore`.
//
// See `docs/design-vpn-flap-resilience.md` for the phase-6 debounce / grace
// state-machine design.

import Foundation

/// Raw per-interface observation built from the SCDynamicStore values for a
/// single `utun*` interface. Fed into `VPNStateFuser.applyObservation`.
///
/// **macOS reality (verified empirically on macOS 26 / Tahoe with Cisco Secure
/// Client):** `utun*` interfaces do **not** publish a
/// `State:/Network/Interface/utun*/Link` key. Only physical interfaces (`en*`,
/// `awdl*`, `anpi*`, `bridge0`) carry `/Link`. The original Phase 3 design
/// relied on link state to gate "VPN tunnel is up" decisions, which left
/// every utun-based VPN permanently mis-detected (state stuck at `.unknown`,
/// UI showing "Not detected"). For utun, the reliable signals are the
/// IPv4 address assignment (VPN-pushed corp IP, typically RFC1918) and
/// IPv6 presence (interface alive at all). See `docs/design-vpn-flap-resilience.md`.
package struct UtunRawObservation: Sendable, Equatable {
    /// `IPv4` key existed in the store. The presence of this key is the
    /// "VPN tunnel reachable" signal for utun. When the VPN drops, the
    /// IPv4 key is removed (or its `Addresses` array empties) before the
    /// interface itself is torn down.
    package var ipv4Present: Bool = false
    /// `IPv4.Addresses` array was non-empty. Belt-and-suspenders against a
    /// utun that has the key but no addresses (rare, observed during VPN
    /// reconnect mid-handshake).
    package var hasIPv4Address: Bool = false
    /// `IPv6` key existed in the store. Used only to disambiguate
    /// "interface still alive but lost its IPv4 (flap)" from "interface
    /// deleted entirely (user clicked Disconnect)" — both manifest as
    /// `!ipv4Present`, but only the latter also has `!ipv6Present`.
    package var ipv6Present: Bool = false

    package init(ipv4Present: Bool = false,
                 hasIPv4Address: Bool = false,
                 ipv6Present: Bool = false) {
        self.ipv4Present = ipv4Present
        self.hasIPv4Address = hasIPv4Address
        self.ipv6Present = ipv6Present
    }

    /// "Counts as connected" — IPv4 assigned. For utun this is the only
    /// signal we get; physical-interface link state doesn't apply to virtual
    /// tunnels (see type doc above).
    package var isFullyConnected: Bool {
        ipv4Present && hasIPv4Address
    }

    /// "Definitively gone" — interface removed entirely from the store
    /// (no IPv4, no IPv6). A utun with `!ipv4Present && ipv6Present` is
    /// treated as "alive but mid-flap" rather than removed, which preserves
    /// the debounce → grace state machine for transient IPv4 losses.
    /// Trade-off: a user-initiated disconnect that leaves the IPv6
    /// link-local addr in place looks like a `.networkLost` flap that
    /// failed to recover, not `.userInitiated`. The distinction is largely
    /// cosmetic (UI label) — both end at `.disconnected` and trigger the
    /// same direct-mode behavior.
    package var isInterfaceRemoved: Bool {
        !ipv4Present && !ipv6Present
    }
}

/// Per-interface state machine fragment held inside `VPNStateFuser`.
private struct UtunInterfaceState: Equatable {
    enum Phase: Equatable {
        case neverSeen
        case connected
        /// Phase 6 (revised): Link is inactive but we haven't yet committed
        /// to declaring this a flap event. The caller's min-visible timer
        /// is running. If the link recovers before the timer fires, we
        /// transition silently back to `.connected` with no event emission.
        /// If the timer fires while we're still in this phase, we transition
        /// to `.linkDownAwaitingRecovery` and emit `.reasserting`.
        case linkDownDebouncing
        case linkDownAwaitingRecovery
        case removed
    }
    var phase: Phase = .neverSeen
    var lastObservation: UtunRawObservation = .init()
}

/// Pure value-type state machine. Translates per-utun raw observations into
/// `VPNObservedState` transitions. Has no side effects of its own — the caller
/// (production: `VPNStatusMonitor`; tests: direct unit tests) interprets the
/// returned `Decision` to drive timers, callbacks, etc.
///
/// Multi-utun policy: if any utun is currently `.connected` → `.connected`.
/// Otherwise the most-recent transition from any utun drives the emitted state.
/// Per-utun internal tracking lets us add per-interface emission later without
/// a schema break (see "Open Items" in the design doc).
///
/// Mutation: `applyObservation` and `markGraceExpired` mutate. Caller must
/// serialize calls (production `VPNStatusMonitor` does this via `monitorQueue`).
package struct VPNStateFuser {
    /// What the caller should do as a result of `applyObservation` or
    /// `markMinVisibleExpired`.
    package enum Decision: Equatable {
        /// State unchanged from last emission — caller should do nothing.
        case noChange
        /// Fused state transitioned. Caller should invoke its `onChange` callback
        /// with the new state and cancel any pending grace timer.
        case emit(VPNObservedState)
        /// Fused state transitioned to `.reasserting`. Caller should:
        ///   1. Invoke `onChange` with the first associated value (`VPNObservedState`)
        ///   2. Start a grace timer that fires the second associated value
        ///      (typically `.disconnected(.networkLost)`) if grace expires
        case emitAndStartGrace(VPNObservedState, then: VPNObservedState)
        /// Phase 6 (revised): a previously-connected utun's Link went inactive.
        /// Caller should start a min-visible timer for this interface; if the
        /// timer fires while still debouncing, caller invokes
        /// `markMinVisibleExpired(interfaceName:)` to commit the flap. If the
        /// link recovers (next observation) before the timer fires, caller
        /// cancels the timer — `applyObservation` will return `.noChange` and
        /// no event ever fires for the sub-window blip.
        case startMinVisibleTimer(interfaceName: String)
    }

    private var interfaces: [String: UtunInterfaceState] = [:]
    private var lastEmitted: VPNObservedState = .unknown
    /// `true` after `markGraceExpired` is called and before any subsequent
    /// observation. Used to decide whether to emit a fresh `.reasserting` →
    /// `.networkLost` decision when the same interface bounces again.
    private var graceExpired: Bool = false

    package init() {}

    /// Process a raw observation for a single utun. Returns the next action
    /// the caller should take.
    ///
    /// Phase transitions:
    ///   * link present + active + IPv4 → `.connected`
    ///       (if previous was `.linkDownDebouncing`: silent recovery, no event)
    ///   * link present + inactive (was `.connected`) → `.linkDownDebouncing`
    ///       (caller starts min-visible timer; if it fires, fuser transitions
    ///        to `.linkDownAwaitingRecovery` and emits `.reasserting`)
    ///   * link present + inactive (was `.linkDownDebouncing` or other) → no phase change
    ///   * link absent (interface removed) → `.removed`
    ///       (no debounce, no grace — user-initiated disconnect is unambiguous)
    package mutating func applyObservation(
        interfaceName: String,
        observation: UtunRawObservation
    ) -> Decision {
        var iface = interfaces[interfaceName] ?? UtunInterfaceState()
        let previousPhase = iface.phase
        iface.lastObservation = observation

        var startMinVisibleTimer = false

        if observation.isInterfaceRemoved {
            iface.phase = .removed
        } else if observation.isFullyConnected {
            // Recovery. If we were debouncing, this is a silent sub-window
            // blip — phase returns to .connected with no event emission.
            iface.phase = .connected
        } else {
            // Link present but not fully connected.
            switch previousPhase {
            case .connected:
                // First-sight-after-connected: enter debouncing, ask caller to
                // start the min-visible timer. Don't update fused state yet —
                // the utun is still "connected enough" for the caller until
                // the timer commits the flap.
                iface.phase = .linkDownDebouncing
                startMinVisibleTimer = true
            case .linkDownDebouncing, .linkDownAwaitingRecovery, .removed, .neverSeen:
                // Stay where we are. (Repeated link-inactive observations during
                // debounce shouldn't re-arm the timer; they're the same event.)
                break
            }
        }

        interfaces[interfaceName] = iface

        // Any new observation clears the grace-expired latch — the underlying
        // state may be moving again, so the next reasserting transition deserves
        // a fresh grace window.
        graceExpired = false

        if startMinVisibleTimer {
            // The phase advanced to .linkDownDebouncing but the FUSED state
            // (what the orchestrator sees) doesn't change yet — we're still
            // .connected from its POV. Return the timer-start decision so the
            // caller arms the min-visible window.
            return .startMinVisibleTimer(interfaceName: interfaceName)
        }

        let newFusedState = fuseCurrentState()
        return decideEmission(newFusedState)
    }

    /// Called by the monitor when the min-visible timer fires. If the
    /// interface is still in `.linkDownDebouncing` (i.e., link did not
    /// recover within the window), commit the flap by transitioning to
    /// `.linkDownAwaitingRecovery` and emitting `.reasserting`. If the
    /// interface has since recovered, no-op.
    package mutating func markMinVisibleExpired(interfaceName: String) -> Decision {
        guard var iface = interfaces[interfaceName],
              iface.phase == .linkDownDebouncing else {
            return .noChange
        }
        iface.phase = .linkDownAwaitingRecovery
        interfaces[interfaceName] = iface
        return decideEmission(fuseCurrentState())
    }

    /// Whether the fuser has ever observed this interface. Used by the
    /// monitor to decide whether to admit a fresh observation: utuns that
    /// have never been seen with IPv4 are Apple service utuns (cloud relay,
    /// FaceTime audio bridge) and should not pollute the fused state, but
    /// once an interface enters the fuser (because it had IPv4 at least
    /// once), all subsequent observations for it must be processed so the
    /// flap / removal state machine can complete.
    package func knowsAbout(interfaceName: String) -> Bool {
        interfaces[interfaceName] != nil
    }

    /// Called by the monitor when the grace-window timer fires. Marks the
    /// internal latch so subsequent observations don't re-emit a stale
    /// `.reasserting` for the same interface bounce.
    package mutating func markGraceExpired() {
        graceExpired = true
        // Note: lastEmitted is NOT updated here — the monitor is responsible for
        // emitting the post-grace `.disconnected(.networkLost)` and that emission
        // is what should update the caller-side cache. The fuser learns about
        // grace expiry only so the next applyObservation() doesn't re-emit
        // `.reasserting` if the same interface phase persists.
    }

    // MARK: - Internals

    /// Reduce per-interface phases to a single fused `VPNObservedState`.
    private func fuseCurrentState() -> VPNObservedState {
        guard !interfaces.isEmpty else { return .unknown }

        // Priority order, highest to lowest:
        //   1. Any utun connected OR debouncing (sub-window blip in progress) → .connected
        //      (debouncing is "Link inactive but we haven't committed to a flap yet";
        //       from the orchestrator's POV, this utun is still serving traffic)
        //   2. Any utun reasserting (post-debounce, pre-grace) → .reasserting
        //   3. All utuns we know about have been explicitly removed → .userInitiated
        //   4. Mix of removed + never-connected → .networkLost
        //   5. Only never-connected utuns → .unknown

        if interfaces.values.contains(where: {
            $0.phase == .connected || $0.phase == .linkDownDebouncing
        }) {
            return .connected
        }

        if interfaces.values.contains(where: { $0.phase == .linkDownAwaitingRecovery }) {
            return .reasserting
        }

        let hasRemoved = interfaces.values.contains { $0.phase == .removed }
        let allRemoved = interfaces.values.allSatisfy { $0.phase == .removed }
        if allRemoved {
            return .disconnected(reason: .userInitiated)
        }
        if hasRemoved {
            return .disconnected(reason: .networkLost)
        }

        // All remaining utuns are .neverSeen — we observed an interface that's
        // not connected and not been-connected-then-gone. Insufficient evidence
        // for a disconnect verdict.
        return .unknown
    }

    private mutating func decideEmission(_ newState: VPNObservedState) -> Decision {
        guard newState != lastEmitted else { return .noChange }
        lastEmitted = newState

        if newState.isReasserting {
            return .emitAndStartGrace(newState, then: .disconnected(reason: .networkLost))
        }
        return .emit(newState)
    }
}
