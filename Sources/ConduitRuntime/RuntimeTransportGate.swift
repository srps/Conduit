// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// One lane of the in-memory transport. Ordinary commands, reads and each module's stop have separate finite
/// capacity, so a full ordinary lane never consumes a stop's slot, and a stalled owner fills only the lanes
/// that carry its traffic.
enum RuntimeLane: Hashable, Sendable {
    case ordinary
    case read
    case stop(ControlModule)
}

/// The named parts of one lane reservation. A reservation returns its slot only when every part it holds has ended.
/// So a caller that stopped waiting frees nothing while owner work, a timer or a waiter registration is still live.
struct RuntimeTicketParts: OptionSet, Sendable {
    let rawValue: UInt8

    /// An owner hop for this wait is queued or running.
    static let hop = RuntimeTicketParts(rawValue: 1 << 0)
    /// The deadline timer task has not yet ended.
    static let timer = RuntimeTicketParts(rawValue: 1 << 1)
    /// A parked wait's registration may still be held by the service until its cleanup hop has run.
    static let waiterCleanup = RuntimeTicketParts(rawValue: 1 << 2)
}

/// Counts reserved slots per lane. Its lock is a leaf: nothing runs under it.
final class RuntimeLaneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: RuntimeServiceLimits
    private var inUse: [RuntimeLane: Int] = [:]

    init(limits: RuntimeServiceLimits) {
        self.limits = limits
    }

    /// Reserves one slot on a lane, or returns nil when the lane is full. The ticket starts with its timer part.
    func reserve(_ lane: RuntimeLane, onQuiesced: (@Sendable () -> Void)?) -> RuntimeLaneTicket? {
        lock.withLock {
            let used = inUse[lane, default: 0]
            guard used < capacity(of: lane) else { return nil }
            inUse[lane] = used + 1
            return RuntimeLaneTicket(lane: lane, counter: self, onQuiesced: onQuiesced)
        }
    }

    /// The slots in use on a lane right now.
    func inFlight(_ lane: RuntimeLane) -> Int {
        lock.withLock { inUse[lane, default: 0] }
    }

    fileprivate func release(_ lane: RuntimeLane) {
        lock.withLock {
            guard let used = inUse[lane], used > 0 else { return }
            inUse[lane] = used - 1
        }
    }

    private func capacity(of lane: RuntimeLane) -> Int {
        switch lane {
        case .ordinary: limits.ordinaryLaneCapacity
        case .read: limits.readLaneCapacity
        case .stop: limits.stopLaneCapacityPerModule
        }
    }
}

/// One reserved lane slot, with its named parts. The slot returns after the last part ends, and the release callback runs
/// once, outside every lock. Ending a part that is not held changes nothing.
///
/// Hop parts are counted, not held as a set: a round that queues the next round begins the next hop before the current
/// one ends, so two hops can be live at once, and the slot must survive until both have ended.
final class RuntimeLaneTicket: @unchecked Sendable {
    private let lock = NSLock()
    private let lane: RuntimeLane
    private let counter: RuntimeLaneCounter
    private let onQuiesced: (@Sendable () -> Void)?
    /// The timer and waiter-cleanup parts that are still held.
    private var held: RuntimeTicketParts = [.timer]
    /// The owner hops held: one per queued or running round.
    private var hopHolds = 0
    private var released = false

    fileprivate init(lane: RuntimeLane, counter: RuntimeLaneCounter, onQuiesced: (@Sendable () -> Void)?) {
        self.lane = lane
        self.counter = counter
        self.onQuiesced = onQuiesced
    }

    /// Whether every part has ended and the slot has been returned.
    var isReleased: Bool {
        lock.withLock { released }
    }

    /// Adds parts to the reservation. It returns false once the reservation has released, so no caller queues work
    /// it cannot hold.
    func begin(_ parts: RuntimeTicketParts) -> Bool {
        lock.withLock {
            guard !released else { return false }
            if parts.contains(.hop) {
                guard let next = RuntimeCounter.successor(hopHolds) else { return false }
                hopHolds = next
            }
            held.formUnion(parts.subtracting(.hop))
            return true
        }
    }

    /// Ends the parts it holds. The last one releases the slot, and then the release callback runs outside the lock.
    func end(_ parts: RuntimeTicketParts) {
        let releasing = lock.withLock { () -> Bool in
            guard !released else { return false }
            var changed = false
            if parts.contains(.hop), hopHolds > 0 {
                hopHolds -= 1
                changed = true
            }
            let others = parts.subtracting(.hop)
            if !held.intersection(others).isEmpty {
                held.subtract(others)
                changed = true
            }
            guard changed, held.isEmpty, hopHolds == 0 else { return false }
            released = true
            return true
        }
        guard releasing else { return }
        counter.release(lane)
        onQuiesced?()
    }
}

/// What one wait resolves to. A failure says whether a byte may have left the client: `notSent` when the wait ended
/// before the claim, and `sent` when it ended after the claim, where the work may have run.
enum RuntimeWaitOutcome: Sendable {
    case reply(Data)
    /// A subscription opened. A nil subscriber means the open was refused, and `first` is the refusal frame.
    case opened(subscriber: Int?, first: Data)
    case failed(ControlRuntimeTransportFailure)
}

/// The phase of one wait. It is read and changed only under the gate's lock.
enum RuntimeGatePhase: Sendable, Equatable {
    /// Not yet claimed, and not parked. An end here is before any work, so it is `notSent`.
    case open
    /// An owner round holds the work. An end here is possibly sent.
    case claimed
    /// Parked on a stream registration, waiting for a frame. An end here consumed nothing, so it is `notSent`.
    case parked
    /// The first resolution has been made, and later ones change nothing.
    case resolved
}

/// One caller wait: one timer, one continuation, and any number of owner rounds. A stream pull keeps its gate across
/// wakes until a final outcome, so the single pull and its reservation span every round. The first resolution wins.
///
/// Phase classification and first resolution happen in one locked step. The lock is a leaf: continuations resume,
/// timers cancel, cleanup callbacks run and hops queue only after it is released. The only nesting is gate → ticket,
/// and the ticket never calls back into the gate.
final class RuntimeWaitGate: @unchecked Sendable {
    /// One owner round. It runs on the main actor, and it returns the outcome, or nil when it parked the wait.
    typealias Attempt = @MainActor @Sendable (RuntimeWaitGate) -> RuntimeWaitOutcome?
    /// Ends a parked registration. The flag says whether the service already released it: a wake does, and a resolution
    /// does not, so its cleanup must run in an owner hop.
    typealias ParkEnd = @Sendable (_ serviceReleased: Bool) -> Void

    let ticket: RuntimeLaneTicket
    private let lock = NSLock()
    private let deadline: RuntimeDeadline
    private let timing: RuntimeServiceTiming
    private let scheduling: any RuntimeOwnerScheduling
    /// The round's closure. It is kept until resolution, so a parked wait can run it again on a wake, and it is cleared at
    /// resolution, so a resolved wait releases the request it captured while its timer may still be held.
    private var attempt: Attempt?
    private let abandoned: @MainActor @Sendable (RuntimeWaitOutcome) -> Void
    /// The typed refusal to answer with when the wait's deadline is the request's budget and the budget ends before a claim.
    /// It is nil when the caller's own deadline is the bound, and that end is `notSent`. It is kept until resolution, because a
    /// round that parks can return the wait to open on a wake, and it is cleared at resolution like the round's closure.
    private var boundRefusal: Data?
    private var phase = RuntimeGatePhase.open
    private var continuation: CheckedContinuation<RuntimeWaitOutcome, Never>?
    private var resolution: RuntimeWaitOutcome?
    private var timer: Task<Void, Never>?
    private var parkedEnd: ParkEnd?
    /// A wake that arrived while a round still held the wait. The next park takes it at once, so no wake is lost.
    private var wakeRequested = false

    /// `abandoned` receives an outcome that a round produced after the wait had already resolved, so a resource it
    /// registered can be released in the same owner turn.
    init(
        ticket: RuntimeLaneTicket,
        deadline: RuntimeDeadline,
        timing: RuntimeServiceTiming,
        scheduling: any RuntimeOwnerScheduling,
        boundRefusal: Data? = nil,
        attempt: @escaping Attempt,
        abandoned: @escaping @MainActor @Sendable (RuntimeWaitOutcome) -> Void
    ) {
        self.ticket = ticket
        self.deadline = deadline
        self.timing = timing
        self.scheduling = scheduling
        self.boundRefusal = boundRefusal
        self.attempt = attempt
        self.abandoned = abandoned
    }

    /// The phase, for tests and the model.
    var currentPhase: RuntimeGatePhase {
        lock.withLock { phase }
    }

    /// Arms the caller's continuation, starts the wait's one timer, and queues its first round. A resolution that came
    /// first is delivered at once, and the parts that would have run are ended, so nothing is left held.
    func start(_ continuation: CheckedContinuation<RuntimeWaitOutcome, Never>) {
        let early = lock.withLock { () -> RuntimeWaitOutcome? in
            if let resolution { return resolution }
            self.continuation = continuation
            return nil
        }
        if let early {
            // No round was queued, so only the timer part was ever held.
            ticket.end(.timer)
            continuation.resume(returning: early)
            return
        }
        startTimer()
        queueRound()
    }

    /// Claims the wait for one round. It returns false when the wait has already resolved or is held by another round.
    /// It returns the round's attempt, or nil when the wait has resolved or another round holds it.
    private func claim() -> Attempt? {
        lock.withLock {
            guard phase == .open, let attempt else { return nil }
            phase = .claimed
            return attempt
        }
    }

    /// Resolves the wait with a round's answer. It returns true only when this call won, so a caller that commits
    /// a stream frame commits it only on a win.
    @discardableResult
    func finish(_ outcome: RuntimeWaitOutcome) -> Bool {
        resolve { current in current == .resolved ? nil : outcome }
    }

    /// Ends the wait because its deadline passed or its task was cancelled. The phase is read and the failure is chosen
    /// in one locked step, so a claim cannot slip in between.
    func expire(_ end: RuntimeWaitEnd) {
        resolve { current in
            switch current {
            case .resolved: nil
            case .open, .parked: .failed(.notSent(end))
            case .claimed: .failed(.sent(end))
            }
        }
    }

    /// The wait's deadline ended. Before a claim it answers with the bound refusal when the budget was the bound, and it is
    /// `notSent` otherwise. After a claim the work may have run, so it is `sent`, and admitted work is never cancelled here.
    func expireDeadline() {
        resolve { current in
            switch current {
            case .resolved: nil
            case .open, .parked:
                if let boundRefusal { .reply(boundRefusal) } else { .failed(.notSent(.deadlineExpired)) }
            case .claimed: .failed(.sent(.deadlineExpired))
            }
        }
    }

    /// Parks the claimed wait on its registration in the service. `end` runs once that registration is no longer live:
    /// at once when a wake was already recorded or the wait resolved first, otherwise later from a wake or a resolution.
    func park(_ end: @escaping ParkEnd) {
        enum Step { case parked, wokeEarly, resolvedFirst }
        let step = lock.withLock { () -> Step in
            // The caller began the waiter-cleanup part before it installed the registration, so this step never begins a part.
            guard phase == .claimed else { return .resolvedFirst }
            if wakeRequested {
                wakeRequested = false
                phase = .open
                return .wokeEarly
            }
            phase = .parked
            parkedEnd = end
            return .parked
        }
        switch step {
        case .parked:
            return
        case .wokeEarly:
            end(true)
            queueRound()
        case .resolvedFirst:
            end(false)
        }
    }

    /// The service took this wait's registration, in its own owner turn. A parked wait is rearmed: its next round is
    /// queued while its timer keeps running. A wake during a round is recorded for the next park.
    func wake() {
        var registrationEnd: ParkEnd?
        let rearmed = lock.withLock { () -> Bool in
            switch phase {
            case .parked:
                guard ticket.begin(.hop) else { return false }
                phase = .open
                registrationEnd = parkedEnd
                parkedEnd = nil
                return true
            case .claimed:
                wakeRequested = true
                return false
            case .open, .resolved:
                return false
            }
        }
        guard rearmed else { return }
        registrationEnd?(true)
        scheduleRound()
    }

    /// Queues the owner hop for one round. The hop holds the gate weakly. A gate that is already gone ends the hop part itself,
    /// so the reservation never waits on a round that can no longer run.
    private func scheduleRound() {
        let ticket = self.ticket
        scheduling.hop { [weak self] in
            guard let self else {
                ticket.end(.hop)
                return
            }
            self.runRound()
        }
    }

    /// Starts the timer task. Its timer part ends only when the task body has ended, after any expiry it made, so the
    /// reservation covers the timer's own work. A caller may resume on the expiry while that part is still held, and a pull
    /// it starts meanwhile is refused as a typed busy wait. A cancelled timer resolves nothing, and it ends the same way.
    private func startTimer() {
        // The task holds the gate weakly and its ticket strongly: a gate that is gone still ends the timer part, and nothing the
        // task holds is a payload.
        let ticket = self.ticket
        let timing = self.timing
        let instant = deadline.instant
        let timerTask = Task { [weak self] in
            defer { ticket.end(.timer) }
            do {
                try await timing.sleep(instant)
            } catch {
                return
            }
            self?.expireDeadline()
        }
        let superseded = lock.withLock { () -> Bool in
            guard phase != .resolved else { return true }
            timer = timerTask
            return false
        }
        if superseded {
            timerTask.cancel()
        }
    }

    /// Queues one owner round. Its hop part is begun first, so the reservation cannot release while the round waits.
    /// It is internal so the model can start a wait without a continuation.
    func queueRound() {
        guard ticket.begin(.hop) else { return }
        scheduleRound()
    }

    /// One owner round, on the main actor. It checks the deadline at claim time, claims the wait, and runs the attempt.
    /// Its hop part ends last.
    @MainActor
    private func runRound() {
        defer { ticket.end(.hop) }
        guard deadline.remaining(at: timing.now()) > .zero else {
            expireDeadline()
            return
        }
        switch runClaimedAttempt() {
        case .unclaimed:
            return
        case .parked:
            // The attempt parked the wait. A wait left claimed has no answer coming, so it fails as sent.
            if currentPhase == .claimed {
                finish(.failed(.sent(.invalidReply)))
            }
        case .answered(let outcome):
            if !finish(outcome) {
                abandoned(outcome)
            }
        }
    }

    /// What one claimed round produced.
    private enum RoundStep {
        case unclaimed
        case parked
        case answered(RuntimeWaitOutcome)
    }

    /// Claims the wait and runs its attempt. The attempt is a local of this call only, so when the call returns the wait is the
    /// last holder of the round's closure, and resolution is what releases it.
    @MainActor
    private func runClaimedAttempt() -> RoundStep {
        guard let attempt = claim() else { return .unclaimed }
        guard let outcome = attempt(self) else { return .parked }
        return .answered(outcome)
    }

    /// The payloads a resolved wait no longer needs. They are moved out under the lock and released after it.
    private struct SpentPayloads {
        var attempt: Attempt?
        var refusal: Data?
    }

    /// Chooses the outcome from the current phase under the lock, and makes it the first resolution when one is returned.
    /// The spent payloads, the timer, the registration end and the continuation are handled only after the lock is released.
    /// The payloads are released before the timer is cancelled and before the caller resumes, so no destructor runs under
    /// the lock and the caller never resumes while the captured request is still held.
    @discardableResult
    private func resolve(_ choose: (RuntimeGatePhase) -> RuntimeWaitOutcome?) -> Bool {
        var resumeCaller: CheckedContinuation<RuntimeWaitOutcome, Never>?
        var timerToCancel: Task<Void, Never>?
        var registrationEnd: ParkEnd?
        var chosen: RuntimeWaitOutcome?
        var spent = SpentPayloads()
        lock.withLock {
            guard let outcome = choose(phase) else { return }
            phase = .resolved
            resumeCaller = continuation
            continuation = nil
            // Only an early resolution is kept, for `start` to deliver. A delivered answer is never retained here.
            resolution = resumeCaller == nil ? outcome : nil
            // The moved payloads stay alive in `spent` through the unlock below. Nothing under the lock releases them.
            spent = SpentPayloads(attempt: attempt, refusal: boundRefusal)
            attempt = nil
            boundRefusal = nil
            timerToCancel = timer
            timer = nil
            registrationEnd = parkedEnd
            parkedEnd = nil
            chosen = outcome
        }
        // The moved payloads are retained through the unlock, then released explicitly, outside the lock. The round's closure
        // goes first, so its captured request is freed here.
        withExtendedLifetime(spent) {}
        spent = SpentPayloads()
        timerToCancel?.cancel()
        registrationEnd?(false)
        if let chosen, let resumeCaller {
            resumeCaller.resume(returning: chosen)
        }
        return chosen != nil
    }

    /// Whether the gate's lock is free right now. It only tries the lock, so a caller that holds it gets `false` at once and
    /// never waits. A test uses it to check that a payload is released after the lock, and production never calls it.
    var isLockFreeForTesting: Bool {
        guard lock.`try`() else { return false }
        lock.unlock()
        return true
    }
}
