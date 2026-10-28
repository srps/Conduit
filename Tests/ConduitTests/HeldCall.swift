// SPDX-License-Identifier: Apache-2.0
import ConduitShared
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

    /// `waitUntilReached`, bounded: false when the armed call has not arrived within `limit`, so a call that never comes fails the
    /// scenario instead of hanging it.
    func waitUntilReached(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if lock.withLock({ reached }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return lock.withLock { reached }
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

/// A helper status source that offers every status read to a `HeldCall` first as `("helper-status", [])`, then reads the one behind it.
final class HoldingHelperStatus: HelperLifecycleManaging, @unchecked Sendable {
    private let base: any HelperLifecycleManaging
    private let hold: HeldCall

    init(base: any HelperLifecycleManaging, hold: HeldCall) {
        self.base = base
        self.hold = hold
    }

    var status: HelperToolPrivilegeClient.Status {
        hold.pass("helper-status", [])
        return base.status
    }

    func installHelper() throws -> HelperPinOutcome { try base.installHelper() }
    func uninstallHelper() throws { try base.uninstallHelper() }
}

/// The operating system's state-file access, offering each configuration read to a `HeldCall` first as `("read", [path])`. A store's
/// physical steps run on `PlatformWork`, never the main thread, so an armed read parks there with the store's slot held.
final class HeldStateFileRead: StateFileAccessing, @unchecked Sendable {
    let hold = HeldCall()
    private let inner = StateFileAccess.operatingSystem()

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        hold.pass("read", [file.path])
        return inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}

/// A private transport over another one that holds one armed exchange at a chosen point: before its frame is sent, so the host has no
/// record of it while its custody is reserved, or after its reply arrived and before the client decodes it, so the host's operation can
/// settle while the transfer is still held. Unarmed, it passes every exchange through.
final class HeldPrivateTransport: PrivateEditorTransport, @unchecked Sendable {
    enum Point {
        case beforeSend
        case afterReply
    }

    private let inner: any PrivateEditorTransport
    private let lock = NSLock()
    private var armed: Point?
    private var reached = false
    private var released = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(inner: any PrivateEditorTransport) {
        self.inner = inner
    }

    func arm(_ point: Point) {
        lock.withLock { armed = point }
    }

    /// Waits until the armed exchange is held.
    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if reached { return true }
                reachedWaiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Lets the held exchange go on. Idempotent, so a test may also call it on every exit.
    func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { releaseWaiter = nil }
            return releaseWaiter
        }
        waiter?.resume()
    }

    func withPrivateExchange<T: Sendable>(
        _ purpose: PrivateExchangePurpose,
        capacityUntil: RuntimeDeadline?,
        _ body: (PrivateExchange) async throws -> T
    ) async throws -> T {
        try await inner.withPrivateExchange(purpose, capacityUntil: capacityUntil) { exchange in
            try await body(PrivateExchange { frame, deadline in
                await self.hold(at: .beforeSend)
                let reply = try await exchange.send(frame, deadline)
                await self.hold(at: .afterReply)
                return reply
            })
        }
    }

    private func hold(at point: Point) async {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
            guard armed == point else { return nil }
            armed = nil
            reached = true
            defer { reachedWaiters = [] }
            return reachedWaiters
        }
        guard let waiters else { return }
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if released { return true }
                releaseWaiter = continuation
                return false
            }
            if go { continuation.resume() }
        }
    }
}

/// One value a task stores and the test reads without awaiting that task, so a test can see whether an answer arrived while the work
/// that would otherwise answer it is still held.
final class LockedSlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? { lock.withLock { stored } }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }
}

/// Values any thread appends, in order, and the test reads.
final class LockedLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
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
