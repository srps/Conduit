// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Identifies the process currently listening on an address.
///
/// Answering "the port is in use" is not actionable on its own — the user
/// still has to go find the holder before they can decide whether to stop it.
/// The kernel cannot look this up itself (it is Apple-framework-free by
/// design), so hosts inject a platform probe, the same way they inject
/// `PrivilegeClient` and `PacEvaluator`.
///
/// Implementations must be cheap and non-throwing: this runs on a bind
/// failure, where the useful outcome is a better message, never a second
/// failure. Returning `nil` simply means "could not tell" and the caller
/// falls back to naming the address alone.
package protocol ListenerPortHolderProbing: Sendable {
    /// A short human-readable description of whatever holds `host:port`, or
    /// `nil` when nothing does or the holder cannot be identified (it belongs
    /// to another user, or the platform denies the lookup).
    func describeHolder(host: String, port: Int) -> String?
}
