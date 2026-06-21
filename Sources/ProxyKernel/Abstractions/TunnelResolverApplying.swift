// SPDX-License-Identifier: Apache-2.0
// Kernel-side seam for writing `/etc/resolver/*` files used by the tunnel DNS
// override feature. The concrete impl — `TunnelResolverManager`, which talks
// to the privileged helper to write the files — lives in `PlatformMac`.
// `TunnelForwarder` (kernel-side) stores `any TunnelResolverApplying` so it
// can orchestrate the resolver without importing `PlatformMac`.
//
// Three methods mirror `TunnelResolverManager`'s public surface one-for-one —
// no behavioural abstraction, just the import-fence boundary.

import Foundation

/// Abstraction over the `/etc/resolver/*` file writer. Production code in
/// `PlatformMac.TunnelResolverManager` calls the privileged helper; tests can
/// swap in a mock that records calls without touching the filesystem.
package protocol TunnelResolverApplying: Sendable {
    /// Remove stale `/etc/resolver/*` files whose hostname is not in
    /// `activeHostnames`. Called at the start of an override cycle to clean
    /// up after a crashed previous run.
    func cleanupStale(activeHostnames: Set<String>)

    /// Write one `/etc/resolver/<host>` file per `hostname`, all pointing at
    /// `listenIP` (`127.0.0.1` in production). Returns which hostnames
    /// succeeded vs. failed so the caller can surface a partial-success status
    /// in the UI.
    func applyAll(hostnames: [String], listenIP: String) -> (succeeded: [String], failed: [String])

    /// Remove `/etc/resolver/<host>` files for each hostname. Used on tunnel
    /// shutdown and on hostname-set changes.
    func removeAll(hostnames: [String])
}
