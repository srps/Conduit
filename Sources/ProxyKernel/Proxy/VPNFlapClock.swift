// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The two readings a VPN flap takes (#252). The flap's elapsed duration comes from the monotonic `elapsedNow`, so a wall-clock step
/// during a flap cannot make `ProxyMetrics.vpnFlapTotalDuration` negative. The wall clock only stamps the displayed `lastVpnFlapAt`.
/// `ContinuousClock` keeps counting while the machine sleeps, so a flap that spans a sleep reports the time it really lasted, as the
/// wall-clock difference did. Injected so a test can step the wall clock without changing the machine's.
package struct VPNFlapClock: Sendable {
    package let wallNow: @Sendable () -> Date
    package let elapsedNow: @Sendable () -> ContinuousClock.Instant

    package init(wallNow: @escaping @Sendable () -> Date, elapsedNow: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.wallNow = wallNow
        self.elapsedNow = elapsedNow
    }

    package static let system = VPNFlapClock(wallNow: { Date() }, elapsedNow: { ContinuousClock.now })

    /// Seconds from `start` to now on the monotonic clock.
    package func secondsSince(_ start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = start.duration(to: elapsedNow()).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) * 1e-18
    }
}
