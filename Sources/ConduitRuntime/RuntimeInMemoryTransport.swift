// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// A test seam for lost answers. A lost answer still reaches the owner, so the admission is recorded, and only
/// the reply is dropped. A caller must then recover by lookup, never by resending. It is not a product fault model.
final class RuntimeTransportFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var lostReplies = 0

    func loseNextReplies(_ count: Int) {
        lock.withLock { lostReplies += count }
    }

    fileprivate func consumeLostReply() -> Bool {
        lock.withLock {
            guard lostReplies > 0 else { return false }
            lostReplies -= 1
            return true
        }
    }
}

/// The transport's state for one open stream. Its first frame is the baseline, or the refusal when the open was
/// refused. The state is one enum under one leaf lock: it is live, with at most one pull in flight, or released.
/// Release is sticky, and it returns the subscriber exactly once.
final class RuntimeStreamHandle: @unchecked Sendable {
    private enum State {
        case live(subscriber: Int?, firstFrame: Data?, pullInFlight: Bool)
        case released
    }

    let correlation: ControlRequestID
    private let lock = NSLock()
    private var state: State

    init(correlation: ControlRequestID, subscriber: Int?, firstFrame: Data) {
        self.correlation = correlation
        self.state = .live(subscriber: subscriber, firstFrame: firstFrame, pullInFlight: false)
    }

    var subscriberID: Int? {
        lock.withLock {
            guard case .live(let subscriber, _, _) = state else { return nil }
            return subscriber
        }
    }

    var hasFirstFrame: Bool {
        lock.withLock {
            guard case .live(_, let frame, _) = state else { return false }
            return frame != nil
        }
    }

    /// The buffered first frame, consumed exactly once. The caller samples the clock and the cancellation before this call,
    /// so nothing under the lock calls out.
    func takeFirstFrame() -> Data? {
        lock.withLock {
            guard case .live(let subscriber, let frame?, let pull) = state else { return nil }
            state = .live(subscriber: subscriber, firstFrame: nil, pullInFlight: pull)
            return frame
        }
    }

    /// Claims the single pull slot. It is held until the pull's reservation has fully quiesced, not until its caller returns.
    /// A released handle and a handle with a pull in flight are different answers, so each is reported as itself.
    func beginPull() -> RuntimePullStart {
        lock.withLock {
            guard case .live(let subscriber, let frame, let inFlight) = state else { return .released }
            guard !inFlight else { return .busy }
            state = .live(subscriber: subscriber, firstFrame: frame, pullInFlight: true)
            return .started
        }
    }

    /// Frees the pull slot. It runs when the pull's reservation has released.
    func endPull() {
        lock.withLock {
            guard case .live(let subscriber, let frame, true) = state else { return }
            state = .live(subscriber: subscriber, firstFrame: frame, pullInFlight: false)
        }
    }

    /// Terminal and sticky: the first frame and the subscriber are cleared, and the subscriber is returned once.
    func release() -> Int? {
        lock.withLock {
            guard case .live(let subscriber, _, _) = state else { return nil }
            state = .released
            return subscriber
        }
    }
}

/// The receiver's deadline for one budgeted request: the earlier of the caller's absolute deadline and the arrival plus the
/// request's budget. `budgetRefusal` is set only when the budget is the earlier bound, so an end at that bound answers with
/// the typed refusal. When the caller's deadline is earlier, or both are equal, the end is the caller's, and it is `notSent`.
private struct ReceiverDeadline {
    let deadline: RuntimeDeadline
    let budgetRefusal: Data?
}

/// The outcome of installing one parked registration. Each failure names what the service found, so a caller reports a
/// disconnect, a busy slot, or a released reservation as itself.
enum RuntimeRegistrationResult {
    case installed
    case subscriberGone
    case alreadyParked
    case ticketReleased
}

/// The outcome of claiming a stream's single pull slot.
enum RuntimePullStart: Equatable {
    case started
    /// Another pull holds the slot, so this one consumed nothing.
    case busy
    /// The stream was released, so it is disconnected.
    case released
}

/// The in-memory transport. It runs the shared codec both ways. One byte front door decodes each request once, and the
/// lane is classified from the decoded envelope. The receiver's deadline is derived on arrival from the request's budget, and
/// it never widens the caller's. Owner work is queued through `scheduling`, and each caller wait is one gate with one timer and
/// one lane reservation.
struct RuntimeInMemoryTransport: ControlRuntimeTransport {
    let core: RuntimeServiceCore
    let timing: RuntimeServiceTiming
    let scheduling: any RuntimeOwnerScheduling
    let lanes: RuntimeLaneCounter
    let faults: RuntimeTransportFaults
    /// The server's own frame caps. A caller's limits may narrow them, and they never widen them.
    let requestFrameCap: Int
    let replyFrameCap: Int
    /// The composition's private editor channel, shared by every transport it builds; nil where no private owner is composed.
    let privateChannel: RuntimePrivateChannel?

    init(
        core: RuntimeServiceCore,
        limits: RuntimeServiceLimits,
        timing: RuntimeServiceTiming,
        scheduling: any RuntimeOwnerScheduling,
        privateChannel: RuntimePrivateChannel? = nil
    ) {
        self.core = core
        self.timing = timing
        self.scheduling = scheduling
        self.privateChannel = privateChannel
        self.lanes = RuntimeLaneCounter(limits: limits)
        self.faults = RuntimeTransportFaults()
        self.requestFrameCap = limits.maxRequestBytes
        self.replyFrameCap = limits.maxReplyBytes
    }

    /// The limits one frame is read or written under: the server's cap, narrowed by the caller's. A caller's cap that is
    /// larger than the server's changes nothing, so no per-call value widens the service.
    private func effective(_ caller: ControlFrameLimits, cap: Int) throws -> ControlFrameLimits {
        do {
            return try ControlFrameLimits(maxFrameBytes: min(caller.maxFrameBytes, cap))
        } catch {
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
    }

    // MARK: - ControlRuntimeTransport

    func exchange(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> Data {
        // The arrival is read before anything is decoded. The request is decoded under the server's cap, and the reply is
        // encoded under the reply cap.
        let arrival = timing.now()
        let requestLimits = try effective(limits, cap: requestFrameCap)
        let replyLimits = try effective(limits, cap: replyFrameCap)
        let message = try frontDoor(request, limits: requestLimits)
        guard case .request(let envelope) = message.body else {
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
        // A subscribe is opened only by `openStream`. It is refused here, before any lane is reserved or owner hop is queued, so
        // nothing was claimed and the refusal is not sent.
        if case .subscribe = envelope.call {
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
        let lane = laneOf(envelope)
        let bound = try receiverDeadline(
            envelope,
            correlation: message.correlation,
            arrival: arrival,
            caller: deadline,
            limits: replyLimits
        )
        if let refusal = bound.budgetRefusal, bound.deadline.remaining(at: timing.now()) <= .zero {
            // The budget ended before arrival completed. Nothing is reserved, queued or admitted.
            return refusal
        }
        let outcome = await run(lane: lane, deadline: bound.deadline, boundRefusal: bound.budgetRefusal) { _ in
            self.answer(message, limits: replyLimits)
        }
        switch outcome {
        case .reply(let bytes): return bytes
        case .failed(let failure): throw failure
        case .opened: throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
    }

    func openStream(_ request: Data, limits callerLimits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> ControlRuntimeStream {
        let arrival = timing.now()
        let requestLimits = try effective(callerLimits, cap: requestFrameCap)
        let limits = try effective(callerLimits, cap: replyFrameCap)
        let message = try frontDoor(request, limits: requestLimits)
        guard case .request(let envelope) = message.body, case .subscribe(let subscription) = envelope.call else {
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
        let correlation = message.correlation
        let bound = try receiverDeadline(envelope, correlation: correlation, arrival: arrival, caller: deadline, limits: limits)
        if let refusal = bound.budgetRefusal, bound.deadline.remaining(at: timing.now()) <= .zero {
            // A refused open never registers a subscriber, and its refusal is the stream's first frame.
            return makeStream(RuntimeStreamHandle(correlation: correlation, subscriber: nil, firstFrame: refusal), limits: limits)
        }
        let core = self.core
        let outcome = await run(
            lane: .read,
            deadline: bound.deadline,
            boundRefusal: bound.budgetRefusal,
            abandoned: { outcome in
                // An open that resolved too late to be delivered leaves no subscriber behind, in the same owner turn.
                if case .opened(let subscriber?, _) = outcome {
                    core.removeSubscriber(subscriber)
                }
            }
        ) { _ in
            switch core.openSubscription(subscription) {
            case .opened(let subscriber, let baseline):
                return self.openOutcome(.frame(baseline), correlation: correlation, limits: limits, subscriber: subscriber)
            case .refused(let code):
                return self.openOutcome(.response(.failure(code)), correlation: correlation, limits: limits, subscriber: nil)
            }
        }
        switch outcome {
        case .opened(let subscriber, let first):
            let handle = RuntimeStreamHandle(correlation: correlation, subscriber: subscriber, firstFrame: first)
            return makeStream(handle, limits: limits)
        case .reply(let refusal):
            // A budget that ended while the open was queued is answered as a refused open.
            return makeStream(RuntimeStreamHandle(correlation: correlation, subscriber: nil, firstFrame: refusal), limits: limits)
        case .failed(let failure):
            throw failure
        }
    }

    // MARK: - Deadlines

    /// The receiver's deadline for one budgeted request. The budget counts from arrival, so transit is not counted, and the
    /// caller's own deadline still bounds the caller's wait.
    private func receiverDeadline(
        _ envelope: ControlRuntimeRequest,
        correlation: ControlRequestID,
        arrival: ContinuousClock.Instant,
        caller: RuntimeDeadline,
        limits: ControlFrameLimits
    ) throws -> ReceiverDeadline {
        let budgetInstant = arrival.advanced(by: .milliseconds(envelope.budget.rawValue))
        guard budgetInstant < caller.instant else {
            return ReceiverDeadline(deadline: caller, budgetRefusal: nil)
        }
        return ReceiverDeadline(
            deadline: RuntimeDeadline(instant: budgetInstant),
            budgetRefusal: try refusal(for: envelope.call, correlation: correlation, limits: limits)
        )
    }

    /// The typed refusal of a budget that ended before an answer: a submit is a rejected admission, and every other call is a
    /// `deadlineExpired` failure. It is never a malformed reply, so a zero budget is answered as the expiry it is.
    private func refusal(for call: ControlRuntimeCall, correlation: ControlRequestID, limits: ControlFrameLimits) throws -> Data {
        let response: ControlRuntimeResponse
        switch call {
        case .submit: response = .admission(.rejected(.deadlineExpired))
        case .outcome, .requestLookup, .subscribe, .readPage, .readSnapshot: response = .failure(.deadlineExpired)
        }
        do {
            return try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: .response(response)), limits: limits)
        } catch {
            // This runs before any reservation, so nothing was claimed or sent. The failure is an unsent invalid reply, never a raw
            // error that a client would read as a possible send.
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
    }

    // MARK: - Hops

    /// Reserves a lane and runs one wait. Its owner rounds run through the scheduling seam, and the wait resolves with its
    /// first outcome. `onQuiesced` runs when the reservation releases, and it runs at once when no reservation was made.
    private func run(
        lane: RuntimeLane,
        deadline: RuntimeDeadline,
        onQuiesced: (@Sendable () -> Void)? = nil,
        boundRefusal: Data? = nil,
        abandoned: @escaping @MainActor @Sendable (RuntimeWaitOutcome) -> Void = { _ in },
        attempt: @escaping RuntimeWaitGate.Attempt
    ) async -> RuntimeWaitOutcome {
        guard let ticket = lanes.reserve(lane, onQuiesced: onQuiesced) else {
            onQuiesced?()
            return .failed(.notSent(.transportBusy))
        }
        let gate = RuntimeWaitGate(
            ticket: ticket,
            deadline: deadline,
            timing: timing,
            scheduling: scheduling,
            boundRefusal: boundRefusal,
            attempt: attempt,
            abandoned: abandoned
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RuntimeWaitOutcome, Never>) in
                gate.start(continuation)
            }
        } onCancel: {
            gate.expire(.cancelled)
        }
    }

    /// The owner's answer to one exchange. It runs inside the owner's turn, and every admission it makes is
    /// recorded before the reply is encoded.
    @MainActor
    private func answer(_ message: ControlRuntimeMessage, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        guard case .request(let envelope) = message.body else {
            // The claim was made, so the owner turn may have run: the answer is possibly sent, never not sent.
            return .failed(.sent(.invalidReply))
        }
        let correlation = message.correlation
        switch envelope.call {
        case .submit(let submit):
            return replyOutcome(.response(.admission(core.submit(submit))), correlation: correlation, limits: limits)
        case .requestLookup(let query):
            return replyOutcome(.response(.requestLookup(core.requestLookup(query))), correlation: correlation, limits: limits)
        case .outcome(let query):
            return replyOutcome(.response(.lookup(core.operationLookup(query))), correlation: correlation, limits: limits)
        case .readSnapshot:
            switch core.readSnapshot() {
            case .snapshot(let snapshot):
                return snapshotOutcome(snapshot, correlation: correlation, limits: limits)
            case .internalFailure:
                return replyOutcome(.response(.failure(.internalFailure)), correlation: correlation, limits: limits)
            }
        case .readPage(let page):
            return pageOutcome(page, correlation: correlation, limits: limits)
        case .subscribe:
            // A subscribe is answered by `openStream`, never by an exchange. Reaching this inside a claimed round is possibly sent.
            return .failed(.sent(.invalidReply))
        }
    }

    /// A page answer. Each closed source is one closed reply. A failed read is a closed internal failure, not a corrupt transport,
    /// so the client receives a stable wire error. A capture that cannot fit the frame is refused the same way, never truncated.
    @MainActor
    private func pageOutcome(_ page: ControlPageRequest, correlation: ControlRequestID, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        switch core.pageSource(page) {
        case .changedIncarnation:
            return replyOutcome(.response(.failure(.changedIncarnation)), correlation: correlation, limits: limits)
        case .invalidOffset:
            return replyOutcome(.response(.failure(.invalidValue)), correlation: correlation, limits: limits)
        case .unavailable(let reason, let knownTotal):
            return replyOutcome(
                .response(.page(.unavailable(page.collection, reason, knownTotal: knownTotal))),
                correlation: correlation,
                limits: limits
            )
        case .internalFailure:
            return replyOutcome(.response(.failure(.internalFailure)), correlation: correlation, limits: limits)
        case .rows(let revision, let rows, let offset, let status):
            do {
                let message = try pack(rows, offset: offset, revision: revision, status: status, correlation: correlation, limits: limits)
                return finishReply(message, limits: limits)
            } catch ControlRuntimeWireError.frameTooLarge {
                // The rows, or one of them, do not fit this caller's frame. The host's rows are sound, so the caller learns the size.
                return replyOutcome(.response(.failure(.frameTooLarge)), correlation: correlation, limits: limits)
            } catch {
                // Any other refusal of the page is a failed projection, not a corrupt transport, and it says nothing more.
                return replyOutcome(.response(.failure(.internalFailure)), correlation: correlation, limits: limits)
            }
        }
    }

    @MainActor
    private func pack(
        _ rows: ControlProjectedRows,
        offset: Int,
        revision: ControlCollectionRevision,
        status: ControlPageStatus,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        let incarnation = core.incarnation
        switch rows {
        case .activeConnections(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: incarnation, revision: revision,
                status: status, correlation: correlation, limits: limits
            ) { .activeConnections($0) }
        case .upstreamHealth(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: incarnation, revision: revision,
                status: status, correlation: correlation, limits: limits
            ) { .upstreamHealth($0) }
        case .tunnelBindings(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: incarnation, revision: revision,
                status: status, correlation: correlation, limits: limits
            ) { .tunnelBindings($0) }
        case .tunnelDNSHosts(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: incarnation, revision: revision,
                status: status, correlation: correlation, limits: limits
            ) { .tunnelDNSHosts($0) }
        }
    }

    @MainActor
    private func replyOutcome(
        _ body: ControlRuntimeBody,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) -> RuntimeWaitOutcome {
        finishReply(ControlRuntimeMessage(correlation: correlation, body: body), limits: limits)
    }

    /// Encodes one reply. An answer that the caller's frame cannot hold is replaced by one `frameTooLarge` failure. A failure is never
    /// replaced, since its size is its own answer, and a failure that does not fit ends the reply as a disconnect. Any other encoding
    /// invalidity is an invalid reply.
    @MainActor
    private func finishReply(_ message: ControlRuntimeMessage, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        do {
            return answered(try ControlRuntimeCodec.encodeFrame(message, limits: limits))
        } catch ControlRuntimeWireError.frameTooLarge {
            guard !Self.isFailure(message) else { return .failed(.sent(.disconnected)) }
            return oversizedReply(correlation: message.correlation, limits: limits)
        } catch {
            return .failed(.sent(.invalidReply))
        }
    }

    /// The one failure that stands in for an answer the caller's frame cannot hold. It is encoded once, with no further fallback.
    @MainActor
    private func oversizedReply(correlation: ControlRequestID, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        let failure = ControlRuntimeMessage(correlation: correlation, body: .response(.failure(.frameTooLarge)))
        do {
            return answered(try ControlRuntimeCodec.encodeFrame(failure, limits: limits))
        } catch ControlRuntimeWireError.frameTooLarge {
            return .failed(.sent(.disconnected))
        } catch {
            return .failed(.sent(.invalidReply))
        }
    }

    /// The reply for one encoded answer. A lost reply is dropped after encoding, so the answer was real and only its delivery failed.
    @MainActor
    private func answered(_ bytes: Data) -> RuntimeWaitOutcome {
        if faults.consumeLostReply() {
            return .failed(.sent(.disconnected))
        }
        return .reply(bytes)
    }

    private static func isFailure(_ message: ControlRuntimeMessage) -> Bool {
        if case .response(.failure) = message.body { return true }
        return false
    }

    /// A snapshot reply. A snapshot that does not fit the caller's frame is a closed `frameTooLarge` answer, and any other encoding
    /// failure is a closed `internalFailure`. Neither is reported as a disconnect or as an invalid reply.
    @MainActor
    private func snapshotOutcome(_ snapshot: ControlRuntimeSnapshot, correlation: ControlRequestID, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        let message = ControlRuntimeMessage(correlation: correlation, body: .response(.snapshot(snapshot)))
        do {
            return answered(try ControlRuntimeCodec.encodeFrame(message, limits: limits))
        } catch ControlRuntimeWireError.frameTooLarge {
            return replyOutcome(.response(.failure(.frameTooLarge)), correlation: correlation, limits: limits)
        } catch {
            return replyOutcome(.response(.failure(.internalFailure)), correlation: correlation, limits: limits)
        }
    }

    /// The open's first frame, encoded. A failure after a subscriber was registered releases that subscriber. A baseline that does
    /// not fit the caller's frame is refused as a typed `frameTooLarge` first frame, so the subscriber is released and nothing is
    /// reported as an invalid reply.
    @MainActor
    private func openOutcome(
        _ body: ControlRuntimeBody,
        correlation: ControlRequestID,
        limits: ControlFrameLimits,
        subscriber: Int?
    ) -> RuntimeWaitOutcome {
        do {
            let bytes = try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: body), limits: limits)
            return .opened(subscriber: subscriber, first: bytes)
        } catch ControlRuntimeWireError.frameTooLarge {
            if let subscriber {
                core.removeSubscriber(subscriber)
            }
            return refusedOpen(.frameTooLarge, correlation: correlation, limits: limits)
        } catch {
            if let subscriber {
                core.removeSubscriber(subscriber)
            }
            return .failed(.sent(.invalidReply))
        }
    }

    /// The typed end of a stream, as its last reply. The subscription is already released when this runs. An end that does not fit the
    /// caller's frame cannot be sent, so the wait ends as a disconnect, once, with no refusal substituted and no retry. That is the same
    /// classification as a reply that cannot be encoded for its caller, and it is not an invalid reply.
    static func streamEndOutcome(_ reason: ControlStreamEndReason, correlation: ControlRequestID, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        let end = ControlRuntimeMessage(correlation: correlation, body: .frame(.end(ControlStreamEnd(reason: reason))))
        do {
            return .reply(try ControlRuntimeCodec.encodeFrame(end, limits: limits))
        } catch {
            return .failed(.sent(.disconnected))
        }
    }

    /// A refused open's first frame. It registers nothing, so it carries no subscriber.
    @MainActor
    private func refusedOpen(_ code: ControlRuntimeErrorCode, correlation: ControlRequestID, limits: ControlFrameLimits) -> RuntimeWaitOutcome {
        do {
            let refusal = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: correlation, body: .response(.failure(code))),
                limits: limits
            )
            return .opened(subscriber: nil, first: refusal)
        } catch {
            return .failed(.sent(.invalidReply))
        }
    }

    // MARK: - Registrations

    /// Installs one parked registration for a pull. The waiter-cleanup part is begun before the registration exists, so every
    /// installed registration is covered by a part that holds the reservation. A resolution that lands before the park
    /// queues the cleanup, and the part holds until that cleanup has run. `afterRegistration` exists so a test can land a
    /// resolution in exactly that window.
    @MainActor
    func installRegistration(
        _ subscriber: Int,
        token: RuntimeWaiterToken,
        gate: RuntimeWaitGate,
        afterRegistration: () -> Void = {}
    ) -> RuntimeRegistrationResult {
        let ticket = gate.ticket
        guard ticket.begin(.waiterCleanup) else { return .ticketReleased }
        switch core.parkWaiter(subscriber, token: token, wake: { gate.wake() }) {
        case .parked:
            break
        case .subscriberGone:
            // Nothing was registered, so the part ends now.
            ticket.end(.waiterCleanup)
            return .subscriberGone
        case .alreadyParked:
            ticket.end(.waiterCleanup)
            return .alreadyParked
        }
        afterRegistration()
        let core = self.core
        let scheduling = self.scheduling
        gate.park { serviceReleased in
            guard !serviceReleased else {
                // A wake already took the registration, so nothing in the service is left to release.
                ticket.end(.waiterCleanup)
                return
            }
            scheduling.hop {
                core.releaseWaiter(subscriber, token: token)
                ticket.end(.waiterCleanup)
            }
        }
        return .installed
    }

    // MARK: - Streams

    private func makeStream(_ handle: RuntimeStreamHandle, limits: ControlFrameLimits) -> ControlRuntimeStream {
        let transport = self
        return ControlRuntimeStream(
            next: { deadline in try await transport.nextFrame(handle, limits: limits, deadline: deadline) },
            cancel: {
                // Sticky and once: a second cancel finds the handle released, and nothing is queued.
                guard let subscriber = handle.release() else { return }
                let core = transport.core
                transport.scheduling.hop {
                    core.removeSubscriber(subscriber)
                }
            }
        )
    }

    /// One wait for the next frame of a stream. The buffered first frame is taken first, when the caller is still live.
    /// Otherwise the single pull slot is claimed, and one gate carries the pull through its owner rounds until a frame,
    /// an end, or a failure.
    private func nextFrame(_ handle: RuntimeStreamHandle, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> Data {
        if handle.hasFirstFrame {
            // The clock and the cancellation are read before the handle's lock is taken. The take itself is state only.
            if Task.isCancelled { throw RuntimeWaitEnd.cancelled }
            guard deadline.remaining(at: timing.now()) > .zero else { throw RuntimeWaitEnd.deadlineExpired }
            if let first = handle.takeFirstFrame() {
                return first
            }
        }
        guard handle.subscriberID != nil else { throw RuntimeWaitEnd.disconnected }
        switch handle.beginPull() {
        case .started:
            break
        case .busy:
            throw RuntimeWaitEnd.transportBusy
        case .released:
            throw RuntimeWaitEnd.disconnected
        }
        let outcome = await run(lane: .stream, deadline: deadline, onQuiesced: { handle.endPull() }) { gate in
            self.pullOnce(handle, limits: limits, gate: gate)
        }
        switch outcome {
        case .reply(let bytes):
            return bytes
        case .failed(let failure):
            throw endOf(failure)
        case .opened:
            throw RuntimeWaitEnd.invalidReply
        }
    }

    /// One owner round of a pull. The frame is peeked and encoded first, so the cursor moves only when this gate's finish
    /// wins. A pull with nothing ready parks its registration, and it reports nothing, so the caller's wait stays open.
    /// A stream end is terminal: the handle releases and the subscription leaves the service in this same owner turn.
    @MainActor
    private func pullOnce(_ handle: RuntimeStreamHandle, limits: ControlFrameLimits, gate: RuntimeWaitGate) -> RuntimeWaitOutcome? {
        guard let subscriber = handle.subscriberID else {
            return .failed(.sent(.disconnected))
        }
        let correlation = handle.correlation
        let peeked: (pull: RuntimePull, after: RuntimeSubscriberCursor)?
        do {
            peeked = try core.peekFrame(subscriber) { frame in
                fits(frame, correlation: correlation, limits: limits)
            }
        } catch {
            return .failed(.sent(.invalidReply))
        }
        guard let peeked else {
            return .failed(.sent(.disconnected))
        }
        switch peeked.pull {
        case .frame(let frame):
            let bytes: Data
            do {
                bytes = try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: .frame(frame)), limits: limits)
            } catch {
                return .failed(.sent(.invalidReply))
            }
            if gate.finish(.reply(bytes)) {
                core.commitCursor(subscriber, peeked.after)
            }
            return nil
        case .end(let reason):
            if let ended = handle.release() {
                core.removeSubscriber(ended)
            }
            gate.finish(Self.streamEndOutcome(reason, correlation: correlation, limits: limits))
            return nil
        case .idle:
            switch installRegistration(subscriber, token: RuntimeWaiterToken(), gate: gate) {
            case .installed:
                return nil
            case .subscriberGone:
                // The subscription left the service before the wait parked: a disconnect, and nothing was consumed.
                return .failed(.notSent(.disconnected))
            case .alreadyParked:
                // The one wait slot is taken by another wait, so this one is busy and consumed nothing.
                return .failed(.notSent(.transportBusy))
            case .ticketReleased:
                return .failed(.sent(.disconnected))
            }
        }
    }

    @MainActor
    private func fits(_ frame: ControlRuntimeFrame, correlation: ControlRequestID, limits: ControlFrameLimits) -> Bool {
        do {
            _ = try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: .frame(frame)), limits: limits)
            return true
        } catch {
            return false
        }
    }

    private func endOf(_ failure: ControlRuntimeTransportFailure) -> RuntimeWaitEnd {
        switch failure {
        case .notSent(let end), .sent(let end): end
        }
    }

    // MARK: - Front door and lanes

    /// The one byte front door. It decodes the frame once, and the decoded message is what the lane and the owner see.
    private func frontDoor(_ request: Data, limits: ControlFrameLimits) throws -> ControlRuntimeMessage {
        do {
            return try ControlRuntimeCodec.decodeFullFrame(request, limits: limits)
        } catch {
            // The client encoded this frame, so a decode failure is refused before the owner sees it.
            throw ControlRuntimeTransportFailure.notSent(.invalidReply)
        }
    }

    /// Ordinary commands, each module's stop, the quit and reads each have their own lane.
    private func laneOf(_ envelope: ControlRuntimeRequest) -> RuntimeLane {
        switch envelope.call {
        case .submit(let submit):
            switch RuntimePartition.of(submit.command) {
            case .stop(let module): return .stop(module)
            case .quit: return .quit
            case .ordinary: return .ordinary
            }
        case .requestLookup, .outcome, .readPage, .readSnapshot, .subscribe:
            return .read
        }
    }
}
