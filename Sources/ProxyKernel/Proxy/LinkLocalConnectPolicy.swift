// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// Direct connects to link-local literals get a short budget and a short
/// memory of failure.
///
/// Link-local addresses are never routed (RFC 3927 §2.7): a SYN the link did
/// not answer in two seconds will not be answered in ten, and cloud SDKs
/// probe 169.254.169.254 on every credential lookup. Addresses are not
/// refused outright; a Thunderbolt-bridge or self-assigned peer answers fast.
package enum LinkLocalConnectPolicy {
    package static let connectTimeout: TimeAmount = .seconds(2)

    /// `true` for a 169.254.0.0/16 or fe80::/10 literal. Hostnames are not resolved.
    package static func isLinkLocal(host: String) -> Bool {
        var literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = literal.firstIndex(of: "%") {
            literal = String(literal[..<zone])
        }
        if let v4 = IPv4Literal(literal) {
            return v4.value & 0xffff_0000 == 0xa9fe_0000
        }
        if literal.contains(":") {
            let lowered = literal.lowercased()
            guard lowered.count >= 4, lowered.hasPrefix("fe") else { return false }
            let third = lowered[lowered.index(lowered.startIndex, offsetBy: 2)]
            return "89ab".contains(third)
        }
        return false
    }

    private struct IPv4Literal {
        let value: UInt32
        init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var value: UInt32 = 0
            for part in parts {
                guard let octet = UInt8(part) else { return nil }
                value = (value << 8) | UInt32(octet)
            }
            self.value = value
        }
    }
}

/// Bounded memory of direct connects that timed out against link-local
/// targets, keyed by `host:port`, so the next attempt inside `ttl` fails at once.
package final class LinkLocalFailureMemo: @unchecked Sendable {
    package struct RecentFailure: Error, CustomStringConvertible, LocalizedError {
        package let target: String
        package let secondsAgo: Int
        package let retryAfterSeconds: Int
        package var description: String {
            "\(target) is link-local and did not answer \(secondsAgo)s ago; not retried within \(retryAfterSeconds)s"
        }
        package var errorDescription: String? { description }
    }

    package static let shared = LinkLocalFailureMemo(ttl: 60, capacity: 256)

    package let ttl: TimeInterval
    package let capacity: Int
    private let lock = NIOLock()
    private var failures: [String: Date] = [:]

    package init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = capacity
    }

    package func recordFailure(target: String, now: Date = Date()) {
        lock.withLock {
            failures = failures.filter { now.timeIntervalSince($0.value) < ttl }
            if failures.count >= capacity, failures[target] == nil,
               let oldest = failures.min(by: { $0.value < $1.value }) {
                failures.removeValue(forKey: oldest.key)
            }
            failures[target] = now
        }
    }

    /// The failure to hand back instead of dialling, if one is fresh enough.
    package func recentFailure(target: String, now: Date = Date()) -> RecentFailure? {
        lock.withLock {
            guard let failedAt = failures[target] else { return nil }
            let age = now.timeIntervalSince(failedAt)
            guard age < ttl else {
                failures.removeValue(forKey: target)
                return nil
            }
            return RecentFailure(target: target, secondsAgo: Int(age), retryAfterSeconds: Int(ttl))
        }
    }

    package var count: Int { lock.withLock { failures.count } }

    package func reset() {
        lock.withLock { failures.removeAll() }
    }
}
