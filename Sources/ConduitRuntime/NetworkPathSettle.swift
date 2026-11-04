// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How long `RuntimeHost` waits for a burst of network-path updates to go quiet before it refreshes on the newest path, and the wait
/// itself (#198). Only the refresh (the PAC refetch, the system DNS and proxy reconciles) waits: each material change drops the old
/// path's PAC answers and DoH transports as it arrives, so the window grants nothing and revokes nothing. It bounds how often a churning
/// path refetches the PAC.
///
/// `sleep` is the one seam: production waits on the continuous clock, and a test holds the wait and releases it, so it counts settles
/// instead of timing them. It throws only when the wait is cancelled.
package struct NetworkPathSettle: Sendable {
    /// `NWPathMonitor` reports several updates per wake or roam within a second.
    package static let standardInterval: Duration = .seconds(2)
    package static let standard = NetworkPathSettle(interval: standardInterval)

    package let interval: Duration
    package let sleep: @Sendable (Duration) async throws -> Void

    package init(
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.sleep = sleep
    }
}
