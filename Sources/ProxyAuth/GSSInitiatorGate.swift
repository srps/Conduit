// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Process-wide funnel for GSS initiator calls.
///
/// Every upstream connection gets its own `SystemGSSTokenProvider`, so the
/// per-instance lock in there never stops two handshakes from entering
/// `gss_init_sec_context` at the same time. When neither has a cached
/// service ticket — after a network change, or when the ticket expired —
/// both go to Heimdal's KDC-locate path, and that path runs the
/// `AppSSOLocatePlugin` KDC plugin, which is not safe to run twice at once:
/// `Conduit-2026-08-27-163955.ips` is a SIGTRAP in `CFRelease` inside
/// that plugin with a second thread in `srv_find_realm` alongside it.
///
/// Two things follow from serialising:
/// - Only one handshake at a time asks Heimdal for a ticket; the rest
///   find it in the credential cache when their turn comes.
/// - A KDC that is unreachable would otherwise be waited on once per queued
///   handshake, in series. After such a failure the gate rethrows the same
///   error without touching GSS for `cooldown` seconds — for that target
///   only, so a malformed SPN or a defective challenge from one upstream
///   never blocks the handshake to the next candidate during failover.
///   Credential-absence errors are exempt: they are answered from the
///   cache without a network round trip, and repeating them is what lets a
///   fresh `kinit` take effect immediately.
package final class GSSInitiatorGate: @unchecked Sendable {
    package static let shared = GSSInitiatorGate(cooldown: 5)

    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var coolingDown: [String: (until: Date, failure: Error)] = [:]
    /// Targets are upstream proxy hosts — a handful — but bounded regardless.
    private static let maximumTargets = 32

    package init(cooldown: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown
        self.now = now
    }

    /// Run `body` with exclusive access to the GSS initiator. While a
    /// cooldown is active for `target`, throws the failure that started it
    /// instead. `shouldCoolDown` decides, per error, whether a failure
    /// starts one.
    package func run<T>(
        target: String,
        shouldCoolDown: (Error) -> Bool,
        _ body: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let current = now()
        coolingDown = coolingDown.filter { $0.value.until > current }
        if let entry = coolingDown[target] {
            throw entry.failure
        }

        do {
            return try body()
        } catch {
            if shouldCoolDown(error) {
                if coolingDown.count >= Self.maximumTargets,
                   let oldest = coolingDown.min(by: { $0.value.until < $1.value.until })?.key {
                    coolingDown.removeValue(forKey: oldest)
                }
                // From the time the call *failed*, not entered: a KDC that
                // takes longer than the cooldown to give up would otherwise
                // store an already-expired deadline.
                coolingDown[target] = (now().addingTimeInterval(cooldown), error)
            }
            throw error
        }
    }
}
