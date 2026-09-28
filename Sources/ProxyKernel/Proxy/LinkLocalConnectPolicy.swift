// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Direct connects to link-local literals get a short budget and a short
/// memory of failure.
///
/// Link-local addresses are never routed (RFC 3927 §2.7): a SYN the link did
/// not answer in two seconds will not be answered in ten, and cloud SDKs
/// probe 169.254.169.254 on every credential lookup. Addresses are not
/// refused outright; a Thunderbolt-bridge or self-assigned peer answers fast.
package enum LinkLocalConnectPolicy {
    package static let connectTimeout: TimeAmount = .seconds(2)

    /// `true` when a connect gave up on a timeout, whether NIO reports it as
    /// a bare `ChannelError.connectTimeout` or, from `connect(host:port:)`,
    /// wrapped in `NIOConnectionError` per attempted address.
    package static func isConnectTimeout(_ error: Error) -> Bool {
        if case ChannelError.connectTimeout = error { return true }
        guard let connection = error as? NIOConnectionError, !connection.connectionErrors.isEmpty else { return false }
        return connection.connectionErrors.allSatisfy { attempt in
            if case ChannelError.connectTimeout = attempt.error { return true }
            return false
        }
    }

    /// Wraps a direct dial in the policy: a fresh remembered failure fails at
    /// once (with `direct.link_local_refused`, once per remembered failure),
    /// a link-local literal gets `connectTimeout` instead of `defaultTimeout`,
    /// and a timeout anywhere in `connect` (Happy Eyeballs or the IPv4
    /// fallback) is remembered. A dial to a link-local target that another
    /// dial is still waiting on joins it rather than opening a second
    /// attempt: nothing is remembered until the first times out, and cloud
    /// SDKs send their metadata probes in pairs a second apart (#100). If the
    /// first dial times out, its joiners fail with it; if it succeeds or fails
    /// some other way, every joiner dials at once on its own, without queueing
    /// behind another admission (Codex on #106).
    /// Shared by the HTTP and SOCKS direct paths so they cannot diverge.
    package static func dial(
        host: String,
        port: Int,
        on eventLoop: EventLoop,
        defaultTimeout: TimeAmount = .seconds(10),
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        _ connect: @escaping @Sendable (TimeAmount) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        guard isLinkLocal(host: host) else {
            return connect(defaultTimeout)
        }
        let target = "\(host):\(port)"
        let memo = LinkLocalFailureMemo.shared
        switch memo.admit(target: target, on: eventLoop) {
        case .refuse(let recent, let firstRefusal):
            if firstRefusal {
                eventSink?(RuntimeEvent(kind: .connection, event: "direct.link_local_refused",
                                        detail: "target=\(target) secondsAgo=\(recent.secondsAgo)"))
            }
            return eventLoop.makeFailedFuture(recent)
        case .join(let leader):
            return leader.hop(to: eventLoop).flatMap { outcome in
                switch outcome {
                case .timedOut(let failure):
                    return eventLoop.makeFailedFuture(failure)
                case .finished:
                    return dialAndRemember(target: target, memo: memo, connect)
                }
            }
        case .lead(let done):
            let attempt = dialAndRemember(target: target, memo: memo, connect)
            attempt.whenComplete { result in
                memo.finishDial(target: target)
                if case .failure(let error) = result, isConnectTimeout(error) {
                    done.succeed(.timedOut(RecentFailure(target: target, secondsAgo: 0,
                                                         retryAfterSeconds: Int(memo.ttl))))
                } else {
                    done.succeed(.finished)
                }
            }
            return attempt
        }
    }

    private typealias RecentFailure = LinkLocalFailureMemo.RecentFailure

    /// One link-local connect; a timeout is remembered for the next attempt.
    private static func dialAndRemember(
        target: String,
        memo: LinkLocalFailureMemo,
        _ connect: (TimeAmount) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        connect(connectTimeout).flatMapErrorThrowing { error in
            if isConnectTimeout(error) {
                memo.recordFailure(target: target)
            }
            throw error
        }
    }

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
            // First hextet, parsed: `fe8::1` is 0fe8, not fe80.
            let firstHextet = literal.prefix { $0 != ":" }
            guard (1...4).contains(firstHextet.count), let value = UInt16(firstHextet, radix: 16) else { return false }
            return value & 0xffc0 == 0xfe80
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
/// targets, keyed by `host:port`, so the next attempt inside `ttl` fails at
/// once, plus the dials still in flight so a concurrent attempt can join one.
/// Both maps hold at most `capacity` targets.
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

    /// How the dial a joiner waited on ended.
    package enum LeaderOutcome: Sendable {
        /// It timed out; the joiner fails the same way at once.
        case timedOut(RecentFailure)
        /// It connected or failed another way; the joiner dials on its own.
        case finished
    }

    /// What `dial` does with an attempt.
    package enum Admission {
        /// Fail at once. `firstRefusal` is true for the first refusal of this
        /// remembered failure, the only one that emits an event.
        case refuse(RecentFailure, firstRefusal: Bool)
        /// Wait for the dial in flight and follow its outcome.
        case join(EventLoopFuture<LeaderOutcome>)
        /// Dial; call `finishDial`, then succeed `done`, when it completes.
        case lead(done: EventLoopPromise<LeaderOutcome>)
    }

    package static let shared = LinkLocalFailureMemo(ttl: 60, capacity: 256)

    package let ttl: TimeInterval
    package let capacity: Int
    private let lock = NIOLock()
    private var failures: [String: (failedAt: Date, refused: Bool)] = [:]
    private var inFlight: [String: EventLoopFuture<LeaderOutcome>] = [:]

    package init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = capacity
    }

    package func recordFailure(target: String, now: Date = Date()) {
        lock.withLock {
            failures = failures.filter { now.timeIntervalSince($0.value.failedAt) < ttl }
            if failures.count >= capacity, failures[target] == nil,
               let oldest = failures.min(by: { $0.value.failedAt < $1.value.failedAt }) {
                failures.removeValue(forKey: oldest.key)
            }
            failures[target] = (now, false)
        }
    }

    /// The failure to hand back instead of dialling, if one is fresh enough.
    package func recentFailure(target: String, now: Date = Date()) -> RecentFailure? {
        lock.withLock { freshFailure(target: target, now: now) }
    }

    /// One decision per attempt, under one lock: refuse on a fresh failure,
    /// join a dial in flight, or lead a new one. With the in-flight map full
    /// the attempt leads without registering, as it did before joins existed.
    package func admit(target: String, on eventLoop: EventLoop, now: Date = Date()) -> Admission {
        lock.withLock {
            if let recent = freshFailure(target: target, now: now) {
                let first = failures[target]?.refused == false
                failures[target]?.refused = true
                return .refuse(recent, firstRefusal: first)
            }
            if let pending = inFlight[target] {
                return .join(pending)
            }
            let done = eventLoop.makePromise(of: LeaderOutcome.self)
            if inFlight.count < capacity {
                inFlight[target] = done.futureResult
            }
            return .lead(done: done)
        }
    }

    package func finishDial(target: String) {
        lock.withLock { _ = inFlight.removeValue(forKey: target) }
    }

    package var count: Int { lock.withLock { failures.count } }

    package func reset() {
        lock.withLock {
            failures.removeAll()
            inFlight.removeAll()
        }
    }

    /// Called with the lock held.
    private func freshFailure(target: String, now: Date) -> RecentFailure? {
        guard let failedAt = failures[target]?.failedAt else { return nil }
        let age = now.timeIntervalSince(failedAt)
        guard age < ttl else {
            failures.removeValue(forKey: target)
            return nil
        }
        return RecentFailure(target: target, secondsAgo: Int(age), retryAfterSeconds: Int(ttl))
    }
}
