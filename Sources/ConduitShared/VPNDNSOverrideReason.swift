// SPDX-License-Identifier: Apache-2.0

/// Why the helper's key is not published: the `reason` of `vpn-dns-override-status` (decision 0049).
package enum VPNDNSOverrideReason: String, Sendable, CaseIterable {
    case ownerExited = "owner_exited"
    case targetRefused = "target_refused"
    case targetSilent = "target_silent"
    case vpnChanged = "vpn_changed"
    case relayStopped = "relay_stopped"
    case disarmed
    case helperStopping = "helper_stopping"
}
