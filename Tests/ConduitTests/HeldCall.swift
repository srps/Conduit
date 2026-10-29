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
///
/// Nor is one on a thread of the Swift concurrency pool (`isCooperativePool`): holding it takes a pool thread from every task and
/// actor, which hangs the test, and with a one-thread pool deadlocks it. It is taken, recorded (`reachedOnCooperativePool`, and for the
/// hold's whole life `takenOnCooperativePool`) and let through. `HeldCallTests` checks the label rule on the actual contexts.
final class HeldCall: @unchecked Sendable {
    /// What a matching call made on another queue than the armed one does. The main thread is never such a queue: a call there is
    /// always taken and let through.
    enum OtherQueues {
        /// It does not count, as if it had not matched. A host's activation preflight reads the same services from a global queue at
        /// moments a scenario does not control, and must not be the call that gets held.
        case ignored
        /// It is taken as the armed call, with its queue recorded, and let through rather than held. For an effect that has no
        /// legitimate caller on another queue: one that runs on the generic executor, say, fails the test's placement assertion
        /// instead of leaving the test waiting for a call that never comes.
        case recorded
    }

    /// The lock, and the condition a held call and `blockUntilReached` wait on.
    private let condition = NSCondition()
    private var matcher: (@Sendable (_ name: String, _ values: [String]) -> Bool)?
    private var queueSuffix: String?
    private var otherQueues = OtherQueues.ignored
    private var reached = false
    private var onMainThread = false
    private var onCooperativePool = false
    /// Sticky across arms: some arm of this hold took a call on the pool.
    private var everOnCooperativePool = false
    private var onArmedQueue = false
    private var label: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Held calls, as tickets: each one waits in `pass` until `released` reaches its ticket, so each `release()` lets the oldest held
    /// call go, whichever arm took it. A call taken without being held issues none, so it never lets another arm's call go.
    private var issued: UInt64 = 0
    private var released: UInt64 = 0
    /// `release()` came for this arm before its call, with nothing held: the call is let through when it comes. A release with nothing
    /// armed or held leaves nothing behind, so it can never let a later arm's call through.
    private var releasedEarly = false

    /// Whether a thread whose current dispatch queue has this label belongs to the Swift concurrency pool, which runs tasks and the
    /// default executor of every actor but the main one.
    static func isCooperativePool(_ label: String) -> Bool {
        label.hasSuffix(".cooperative")
    }

    /// The label of the calling thread's current dispatch queue.
    static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    /// Holds the next call `matcher` accepts. `name` is the launch path for a
    /// subprocess and the operation's raw value for a privileged write.
    ///
    /// - Parameter queueSuffix: only a call made on a dispatch queue whose
    ///   label ends with this is held. One made on the main thread (the
    ///   inline case this exists to catch) is taken and let through.
    /// - Parameter otherQueues: what a matching call on any other queue does.
    ///
    /// Arming while an earlier arm's call is still held hands the hold on: that call stays held, and the next `release()` lets it go,
    /// so a test can arm for the call the held one leads to before releasing it.
    func arm(
        onQueueLabeled queueSuffix: String? = nil,
        otherQueues: OtherQueues = .ignored,
        _ matcher: @escaping @Sendable (_ name: String, _ values: [String]) -> Bool
    ) {
        condition.withLock {
            self.matcher = matcher
            self.queueSuffix = queueSuffix
            self.otherQueues = otherQueues
            reached = false
            onMainThread = false
            onCooperativePool = false
            onArmedQueue = false
            label = nil
            releasedEarly = false
        }
    }

    /// Whether the held call arrived on the main thread, where it was let
    /// through instead of held.
    var reachedOnMainThread: Bool { condition.withLock { onMainThread } }

    /// Whether the taken call arrived on a thread of the concurrency pool, where it was let through instead of held.
    var reachedOnCooperativePool: Bool { condition.withLock { onCooperativePool } }

    /// Whether any arm of this hold took a call on the concurrency pool. A harness asserts it false at teardown, so a test whose call
    /// was let through on the pool cannot pass as if it had been held.
    var takenOnCooperativePool: Bool { condition.withLock { everOnCooperativePool } }

    /// Whether the call was taken on the queue it was armed for: off the main thread and the concurrency pool, and on the named queue
    /// when one was named.
    var reachedOnArmedQueue: Bool { condition.withLock { onArmedQueue } }

    /// The label of the dispatch queue the taken call was made on, nil until one is taken.
    var reachedQueueLabel: String? { condition.withLock { label } }

    /// Whether a call is held now, waiting for `release()`.
    var isHolding: Bool { condition.withLock { released < issued } }

    /// Called by the fakes on every machine call.
    func pass(_ name: String, _ values: [String]) {
        let isMain = Thread.isMainThread
        let queueLabel = Self.currentQueueLabel()
        let cooperative = !isMain && Self.isCooperativePool(queueLabel)
        let taken: (waiters: [CheckedContinuation<Void, Never>], ticket: UInt64?)? = condition.withLock {
            guard let matcher, matcher(name, values) else { return nil }
            let armedQueue = !isMain && !cooperative && (queueSuffix.map { queueLabel.hasSuffix($0) } ?? true)
            // An arm that names no queue would have held a pool call, so that call is taken and let through instead of ignored.
            if !isMain, !armedQueue, case .ignored = otherQueues, !cooperative || queueSuffix != nil { return nil }
            self.matcher = nil
            reached = true
            onMainThread = isMain
            onCooperativePool = cooperative
            everOnCooperativePool = everOnCooperativePool || cooperative
            onArmedQueue = armedQueue
            label = queueLabel
            var ticket: UInt64?
            if armedQueue, !releasedEarly {
                issued += 1
                ticket = issued
            }
            condition.broadcast()
            defer { waiters = [] }
            return (waiters, ticket)
        }
        guard let taken else { return }
        for waiter in taken.waiters { waiter.resume() }
        guard let ticket = taken.ticket else { return }
        condition.withLock {
            while released < ticket { condition.wait() }
        }
    }

    /// Waits, off the main actor's turn, until the armed call has arrived.
    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let already = condition.withLock { () -> Bool in
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
            if condition.withLock({ reached }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition.withLock { reached }
    }

    /// Blocks the calling thread until the armed call has arrived. For tests
    /// that drive a manager from threads of their own, never from the main
    /// actor while the held work needs it. It waits on this arm's call alone: a call taken under an earlier arm does not count.
    func blockUntilReached() {
        condition.withLock {
            while !reached { condition.wait() }
        }
    }

    /// Lets the oldest held call go on. With nothing held, it lets this arm's call through when it comes; with nothing armed or held,
    /// it does nothing, so it is safe on every exit path.
    func release() {
        condition.withLock {
            if released < issued {
                released += 1
                condition.broadcast()
            } else if matcher != nil {
                releasedEarly = true
            }
        }
    }

    /// Ends the hold for good, for a harness's teardown: disarms, and lets every held call go. A test that failed mid-hold can leave
    /// more than one held after a hand-over, and `release()` frees only the oldest, so a stop waiting on the next would hang.
    func releaseAll() {
        condition.withLock {
            matcher = nil
            releasedEarly = false
            released = issued
            condition.broadcast()
        }
    }
}

/// Parks the main thread, so a test can show work going on while the main actor cannot run. The park is bounded: it ends at
/// `release()` or at its limit, whichever comes first, so a test that fails never hangs XCTest. Call it from off the main actor: the
/// main thread must be free to take the park.
final class MainThreadPark: @unchecked Sendable {
    private let condition = NSCondition()
    private var parked = false
    private var began = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the main thread is parked now.
    var isParked: Bool { condition.withLock { parked } }

    /// Parks the main thread until `release()` or `limit`, and returns once it is parked.
    func park(limit: Duration) async {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let deadline = Date(timeIntervalSinceNow: seconds)
        DispatchQueue.main.async { [self] in
            let waiting = condition.withLock { () -> [CheckedContinuation<Void, Never>] in
                parked = true
                began = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in waiting { waiter.resume() }
            condition.withLock {
                while !released, condition.wait(until: deadline) {}
                parked = false
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = condition.withLock { () -> Bool in
                if began { return true }
                waiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Ends the park. Idempotent, so a test may also call it on every exit.
    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
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
