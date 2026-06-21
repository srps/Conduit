// SPDX-License-Identifier: Apache-2.0
import Foundation

package final class AuthHandshakeLimiter: @unchecked Sendable {
    package struct Limits: Sendable, Equatable {
        package var total: Int
        package var perSource: Int

        package init(total: Int, perSource: Int) {
            self.total = max(1, total)
            self.perSource = max(1, perSource)
        }
    }

    package enum Rejection: Error, Sendable, Equatable {
        case totalLimit(total: Int, limit: Int)
        case perSourceLimit(source: String, total: Int, limit: Int)
    }

    private let lock = NSLock()
    private var totalPending = 0
    private var pendingBySource: [String: Int] = [:]

    package init() {}

    package func acquire(source: String?, limits: Limits) -> Result<AuthHandshakePermit, Rejection> {
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedSource.flatMap { $0.isEmpty ? nil : $0 }

        lock.lock()
        defer { lock.unlock() }

        if totalPending >= limits.total {
            return .failure(.totalLimit(total: totalPending, limit: limits.total))
        }

        if let key {
            let sourcePending = pendingBySource[key, default: 0]
            if sourcePending >= limits.perSource {
                return .failure(.perSourceLimit(source: key, total: sourcePending, limit: limits.perSource))
            }
            pendingBySource[key] = sourcePending + 1
        }

        totalPending += 1
        return .success(AuthHandshakePermit(limiter: self, source: key))
    }

    fileprivate func release(source: String?) {
        lock.lock()
        defer { lock.unlock() }

        totalPending = max(0, totalPending - 1)
        guard let source else { return }

        let next = max(0, pendingBySource[source, default: 0] - 1)
        if next == 0 {
            pendingBySource.removeValue(forKey: source)
        } else {
            pendingBySource[source] = next
        }
    }

    package var pendingCount: Int {
        lock.withLock { totalPending }
    }

    package func pendingCount(for source: String) -> Int {
        lock.withLock { pendingBySource[source, default: 0] }
    }
}

package final class AuthHandshakePermit: @unchecked Sendable {
    private let lock = NSLock()
    private weak var limiter: AuthHandshakeLimiter?
    private let source: String?
    private var released = false

    fileprivate init(limiter: AuthHandshakeLimiter, source: String?) {
        self.limiter = limiter
        self.source = source
    }

    deinit {
        release()
    }

    package func release() {
        let target: AuthHandshakeLimiter? = lock.withLock {
            guard !released else { return nil }
            released = true
            return limiter
        }
        target?.release(source: source)
    }
}
