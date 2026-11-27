// SPDX-License-Identifier: Apache-2.0

/// Why the helper's key is not published: the `reason` of `vpn-dns-override-status` (decision 0049).
package enum VPNDNSOverrideReason: String, Sendable, CaseIterable {
    case ownerExited = "owner_exited"
    case targetRefused = "target_refused"
    case targetSilent = "target_silent"
    /// No confirmed answer within `unverifiedSecondsToWithdraw`, the probe's own socket failing included.
    case targetUnverified = "target_unverified"
    /// The helper could not watch the owner's exit, so it dropped the arm.
    case ownerUnwatched = "owner_unwatched"
    case vpnChanged = "vpn_changed"
    /// The VPN's DNS key could not be read, so whether it still matches is unknown.
    case vpnUnreadable = "vpn_unreadable"
    case relayStopped = "relay_stopped"
    case disarmed
    case helperStopping = "helper_stopping"
}
