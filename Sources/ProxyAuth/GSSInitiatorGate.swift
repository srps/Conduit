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
///   error without touching GSS for `cooldown` seconds. Credential-absence
///   errors are exempt: they are answered from the cache without a network
///   round trip, and repeating them is what lets a fresh `kinit` take effect
///   immediately.
package final class GSSInitiatorGate: @unchecked Sendable {
    package static let shared = GSSInitiatorGate(cooldown: 5)

    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var coolingDownUntil: Date?
    private var lastFailure: Error?

    package init(cooldown: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown
        self.now = now
    }

    /// Run `body` with exclusive access to the GSS initiator. While a
    /// cooldown is active, throws the failure that started it instead.
    /// `shouldCoolDown` decides, per error, whether a failure starts one.
    package func run<T>(
        shouldCoolDown: (Error) -> Bool,
        _ body: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        if let coolingDownUntil, let lastFailure, now() < coolingDownUntil {
            throw lastFailure
        }
        coolingDownUntil = nil
        lastFailure = nil

        do {
            return try body()
        } catch {
            if shouldCoolDown(error) {
                coolingDownUntil = now().addingTimeInterval(cooldown)
                lastFailure = error
            }
            throw error
        }
    }
}
