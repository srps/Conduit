// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// Holds the first machine call it is armed for until `release()`, so a test
/// can put a second operation in the middle of a first one and say, by
/// counting rather than by timing, which of them landed last.
///
/// A call that matches on the main thread is never held: that is a host
/// running the work inline, and holding it would hang the test instead of
/// failing it. It is recorded instead (`reachedOnMainThread`), and anyone
/// waiting for the hold is let go so the test's assertions can run.
final class HeldCall: @unchecked Sendable {
    private let lock = NSLock()
    private var matcher: (@Sendable (_ name: String, _ values: [String]) -> Bool)?
    private var queueSuffix: String?
    private var reached = false
    private var onMainThread = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let reachedSignal = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    /// Holds the next call `matcher` accepts. `name` is the launch path for a
    /// subprocess and the operation's raw value for a privileged write.
    ///
    /// - Parameter queueSuffix: only a call made on a dispatch queue whose
    ///   label ends with this counts, or one made on the main thread (the
    ///   inline case this exists to catch). A host's activation preflight
    ///   reads the same services from a global queue at moments a scenario
    ///   does not control, and must not be the call that gets held.
    func arm(
        onQueueLabeled queueSuffix: String? = nil,
        _ matcher: @escaping @Sendable (_ name: String, _ values: [String]) -> Bool
    ) {
        lock.withLock {
            self.matcher = matcher
            self.queueSuffix = queueSuffix
            reached = false
            onMainThread = false
        }
    }

    /// Whether the held call arrived on the main thread, where it was let
    /// through instead of held.
    var reachedOnMainThread: Bool { lock.withLock { onMainThread } }

    /// Called by the fakes on every machine call.
    func pass(_ name: String, _ values: [String]) {
        let isMain = Thread.isMainThread
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        let resumed: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard let matcher, matcher(name, values) else { return nil }
            if let queueSuffix, !isMain, !queueLabel.hasSuffix(queueSuffix) { return nil }
            self.matcher = nil
            reached = true
            onMainThread = isMain
            defer { waiters = [] }
            return waiters
        }
        guard let resumed else { return }
        for waiter in resumed { waiter.resume() }
        reachedSignal.signal()
        if !isMain { gate.wait() }
    }

    /// Waits, off the main actor's turn, until the armed call has arrived.
    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock { () -> Bool in
                if reached { return true }
                waiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Blocks the calling thread until the armed call has arrived. For tests
    /// that drive a manager from threads of their own, never from the main
    /// actor while the held work needs it.
    func blockUntilReached() {
        reachedSignal.wait()
    }

    /// Lets the held call go on.
    func release() {
        gate.signal()
    }
}

/// A privilege client that offers every step to a `HeldCall` before
/// handing the batch to the machine behind it.
final class HoldingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let base: any PrivilegeClient
    private let hold: HeldCall

    init(base: any PrivilegeClient, hold: HeldCall) {
        self.base = base
        self.hold = hold
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    func execute(batch: [PrivilegedBatchStep]) throws {
        for step in batch {
            hold.pass(step.operation.rawValue, step.values)
        }
        try base.execute(batch: batch)
    }
}

/// A count one thread writes and another reads after joining it.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = -1

    var value: Int { lock.withLock { stored } }

    func set(_ value: Int) {
        lock.withLock { stored = value }
    }
}
