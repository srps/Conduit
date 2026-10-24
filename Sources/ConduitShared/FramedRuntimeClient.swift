// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The first framed `RuntimeClient`. It runs the v2 codec over a `ControlRuntimeTransport` and maps
/// each outcome to what the caller may claim. It is an adapter contract. It proves framing and error
/// mapping over a byte transport. It proves nothing about host fences, admission order or retention.
///
/// Waiting belongs to the transport. This client starts no timer and claims no socket deadline
/// enforcement. It checks the caller's deadline once before a send, then passes the same absolute
/// deadline down, so one budget covers a whole call and no nested phase starts a fresh one.
///
/// Limits are explicit. `limits` bounds every request this client sends and every reply or stream
/// frame it accepts. A request carries the caller's remaining time, capped at `wireBudgetCap`.
///
/// A mutation is sent once. A submit whose send may have happened and whose answer is lost is
/// `admissionUnknown`, and the client never resends it.
package struct FramedRuntimeClient: RuntimeClient {
    private let transport: any ControlRuntimeTransport
    private let limits: ControlFrameLimits
    private let wireBudgetCap: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let makeCorrelation: @Sendable () -> ControlRequestID

    /// Refuses a budget cap that is not positive. `limits` is validated when it is built.
    package init(
        transport: any ControlRuntimeTransport,
        limits: ControlFrameLimits,
        wireBudgetCap: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        makeCorrelation: @escaping @Sendable () -> ControlRequestID = { ControlRequestID(rawValue: UUID()) }
    ) throws {
        guard wireBudgetCap > .zero else { throw ControlRuntimeWireError.invalidValue }
        self.transport = transport
        self.limits = limits
        self.wireBudgetCap = wireBudgetCap
        self.now = now
        self.makeCorrelation = makeCorrelation
    }

    // MARK: - Commands and lookups

    /// A submit's correlation is its request ID, so a reply names the request it answers. It is never
    /// resent. A send that may have happened and whose answer is lost is `admissionUnknown`.
    package func submit(
        _ command: ControlRuntimeCommand,
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlAdmission {
        let budget = try requestBudget(for: deadline)
        let request = ControlRuntimeRequest.submit(ControlOperationRequest(
            requestID: requestID,
            expectedIncarnation: expectedIncarnation,
            command: command,
            budget: budget
        ))
        do {
            let response = try await exchange(request, correlation: requestID, expecting: .admission, deadline: deadline)
            guard case .admission(let admission) = response else { throw ExchangeFailure.invalidReply }
            return admission
        } catch let failure as ExchangeFailure {
            throw admissionError(failure, requestID: requestID)
        }
    }

    package func lookupAdmission(
        of requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlRequestLookup {
        let budget = try requestBudget(for: deadline)
        let request = ControlRuntimeRequest.requestLookup(ControlRequestQuery(
            expectedIncarnation: expectedIncarnation,
            requestID: requestID,
            budget: budget
        ))
        do {
            let response = try await exchange(request, correlation: makeCorrelation(), expecting: .requestLookup, deadline: deadline)
            guard case .requestLookup(let lookup) = response else { throw ExchangeFailure.invalidReply }
            return lookup
        } catch let failure as ExchangeFailure {
            throw readError(failure)
        }
    }

    package func outcome(
        of operation: ControlOperationID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlOperationLookup {
        let budget = try requestBudget(for: deadline)
        let request = ControlRuntimeRequest.outcome(ControlOperationQuery(
            expectedIncarnation: expectedIncarnation,
            operationID: operation,
            budget: budget
        ))
        do {
            let response = try await exchange(request, correlation: makeCorrelation(), expecting: .lookup, deadline: deadline)
            guard case .lookup(let lookup) = response else { throw ExchangeFailure.invalidReply }
            return lookup
        } catch let failure as ExchangeFailure {
            throw readError(failure)
        }
    }

    // MARK: - Reads and subscriptions

    package func readPage(_ request: ControlPageRequest, deadline: RuntimeDeadline) async throws -> ControlPageReply {
        do {
            let response = try await exchange(.readPage(request), correlation: makeCorrelation(), expecting: .page, deadline: deadline)
            guard case .page(let reply) = response else { throw ExchangeFailure.invalidReply }
            return reply
        } catch let failure as ExchangeFailure {
            throw readError(failure)
        }
    }

    package func readSnapshot(deadline: RuntimeDeadline) async throws -> ControlRuntimeSnapshot {
        do {
            let response = try await exchange(.readSnapshot, correlation: makeCorrelation(), expecting: .snapshot, deadline: deadline)
            guard case .snapshot(let snapshot) = response else { throw ExchangeFailure.invalidReply }
            return snapshot
        } catch let failure as ExchangeFailure {
            throw readError(failure)
        }
    }

    /// Opens one stream. The subscription mints its own correlation, and every frame must answer it.
    package func subscribe(_ request: ControlSubscriptionRequest, deadline: RuntimeDeadline) async throws -> RuntimeSubscription {
        let correlation = makeCorrelation()
        let frame = try encodeRequest(.subscribe(request), correlation: correlation)
        if let end = notLiveEnd(deadline) {
            throw RuntimeClientError.notSent(end)
        }
        let stream: ControlRuntimeStream
        do {
            stream = try await transport.openStream(frame, limits: limits, deadline: deadline)
        } catch {
            throw readError(sendFailure(error))
        }
        let subscription = FramedSubscription(stream: stream, limits: limits, correlation: correlation)
        return RuntimeSubscription(
            next: { waitDeadline in try await subscription.next(waitDeadline) },
            cancel: { subscription.cancel() }
        )
    }

    // MARK: - One exchange

    /// Sends one request and validates its reply. Every failure leaves here as an `ExchangeFailure`
    /// or as a `RuntimeClientError` from local encoding. The caller decides what the failure may claim.
    private func exchange(
        _ request: ControlRuntimeRequest,
        correlation: ControlRequestID,
        expecting kind: ControlRuntimeResponseKind,
        deadline: RuntimeDeadline
    ) async throws -> ControlRuntimeResponse {
        let frame = try encodeRequest(request, correlation: correlation)
        if let end = notLiveEnd(deadline) {
            throw ExchangeFailure.notSent(end)
        }
        let reply: Data
        do {
            reply = try await transport.exchange(frame, limits: limits, deadline: deadline)
        } catch {
            throw sendFailure(error)
        }
        let message: ControlRuntimeMessage
        do {
            message = try receiveReply(reply, correlation: correlation, limits: limits)
        } catch {
            throw ExchangeFailure.invalidReply
        }
        switch message.body {
        case .response(.failure(let code)):
            throw ExchangeFailure.hostFailure(code)
        case .response(let response) where response.kind == kind:
            return response
        default:
            throw ExchangeFailure.invalidReply
        }
    }

    /// The one place a request becomes bytes. A refusal here is local, and nothing is sent.
    private func encodeRequest(_ request: ControlRuntimeRequest, correlation: ControlRequestID) throws -> Data {
        do {
            return try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: correlation, body: .request(request)),
                limits: limits
            )
        } catch {
            throw RuntimeClientError.localRefusal(wireCode(error))
        }
    }

    /// The budget a request carries: the caller's remaining time, capped. It is read once per call.
    private func requestBudget(for deadline: RuntimeDeadline) throws -> ControlWireBudget {
        do {
            return try deadline.wireBudget(at: now(), cappedAt: wireBudgetCap)
        } catch {
            throw RuntimeClientError.localRefusal(wireCode(error))
        }
    }

    /// Why a call must not be sent: its task was cancelled, or its deadline has passed. Either way
    /// no byte leaves the client.
    private func notLiveEnd(_ deadline: RuntimeDeadline) -> RuntimeWaitEnd? {
        if Task.isCancelled { return .cancelled }
        if deadline.remaining(at: now()) <= .zero { return .deadlineExpired }
        return nil
    }

    private func wireCode(_ error: any Error) -> ControlRuntimeErrorCode {
        (error as? ControlRuntimeWireError)?.code ?? .invalidValue
    }
}

// MARK: - Failure mapping

/// How one exchange failed, before the caller maps it to what it may claim.
private enum ExchangeFailure: Error {
    /// No byte left the client.
    case notSent(RuntimeWaitEnd)
    /// Bytes may have left the client, or a wait ended after the send.
    case sent(RuntimeWaitEnd)
    /// A reply arrived, but it is malformed, incomplete, oversize, multi-frame, mis-correlated or
    /// of the wrong kind.
    case invalidReply
    /// The host answered with a failure for this request's correlation.
    case hostFailure(ControlRuntimeErrorCode)
}

/// A typed transport failure keeps its meaning. Any other error counts as a possible send, since
/// bytes may already have left the client. A cancellation is reported as one.
private func sendFailure(_ error: any Error) -> ExchangeFailure {
    if let failure = error as? ControlRuntimeTransportFailure {
        switch failure {
        case .notSent(let end): return .notSent(end)
        case .sent(let end): return .sent(end)
        }
    }
    return .sent(error is CancellationError ? .cancelled : .disconnected)
}

/// A submit may be admitted, so every failure after a possible send is `admissionUnknown` with its
/// request ID. Only a host failure with the request's correlation is an answer, and it is `wire`.
private func admissionError(_ failure: ExchangeFailure, requestID: ControlRequestID) -> RuntimeClientError {
    switch failure {
    case .notSent(let end): .notSent(end)
    case .sent(let end): .admissionUnknown(requestID, end)
    case .invalidReply: .admissionUnknown(requestID, .invalidReply)
    case .hostFailure(let code): .wire(code)
    }
}

/// A read has no admission to protect. It is idempotent, so a failed wait is `readAborted`, and a
/// malformed reply is `unexpectedReply`.
private func readError(_ failure: ExchangeFailure) -> RuntimeClientError {
    switch failure {
    case .notSent(let end): .notSent(end)
    case .sent(let end): .readAborted(end)
    case .invalidReply: .unexpectedReply
    case .hostFailure(let code): .wire(code)
    }
}

/// Validates one complete reply or stream frame before anything parses it: size against the
/// limit first, then one frame with exactly one trailing line feed, then the correlation.
private func receiveReply(
    _ bytes: Data,
    correlation: ControlRequestID,
    limits: ControlFrameLimits
) throws -> ControlRuntimeMessage {
    let message = try ControlRuntimeCodec.decodeFullFrame(bytes, limits: limits)
    guard message.correlation == correlation else { throw ControlRuntimeWireError.malformedMessage }
    return message
}

// MARK: - Subscription handle

/// The state of one open subscription. Single-pull: one `next` is in flight at a time, and a second
/// one is refused locally. The lock is a leaf. It guards plain state, and it is never held across an
/// await or a call into the transport. The transport's `cancel` runs at most once, outside the lock.
/// Dropping the last handle releases the stream exactly as an explicit cancel does.
///
/// Scope: frames are handed over in transport order. The baseline's incarnation is retained, and a
/// later snapshot from another incarnation ends the stream even when its correlation matches. Event
/// cursor order, replay continuity and gap handling are not validated here. They belong to the engine
/// and its model, which remain separate work.
private final class FramedSubscription: @unchecked Sendable {
    private enum Phase {
        case awaitingBaseline
        case live
        /// Terminal. Every later `next` throws this error, and the stream has been released.
        case closed(RuntimeClientError)
    }

    private let stream: ControlRuntimeStream
    private let limits: ControlFrameLimits
    private let correlation: ControlRequestID
    private let lock = NSLock()
    private var phase = Phase.awaitingBaseline
    /// The incarnation the baseline named. Set once, and never changed while the stream is open.
    private var incarnation: ControlHostIncarnation?
    private var reading = false
    private var released = false

    init(stream: ControlRuntimeStream, limits: ControlFrameLimits, correlation: ControlRequestID) {
        self.stream = stream
        self.limits = limits
        self.correlation = correlation
    }

    deinit {
        finish(.readAborted(.cancelled))
    }

    /// Waits for the next frame. The first frame must be the baseline, or a typed end or failure.
    /// A deadline or a cancel ends the wait and consumes no frame. Any frame that breaks the protocol
    /// ends the stream.
    func next(_ deadline: RuntimeDeadline) async throws -> ControlRuntimeFrame {
        let awaitingBaseline = try beginRead()
        defer { endRead() }

        let bytes: Data
        do {
            bytes = try await stream.next(deadline)
        } catch {
            // A terminal error set during the wait, such as an explicit cancel, is the first terminal
            // and wins over whatever ended the wait afterwards.
            if let terminal = closedError() { throw terminal }
            throw waitFailure(error)
        }

        let message: ControlRuntimeMessage
        do {
            message = try receiveReply(bytes, correlation: correlation, limits: limits)
        } catch {
            throw finish(.unexpectedReply)
        }

        switch message.body {
        case .response(.failure(let code)):
            throw finish(.wire(code))
        case .frame(.end(let end)):
            throw finish(.streamClosed(end.reason))
        case .frame(let frame):
            if case .baseline = frame {
                guard awaitingBaseline else { throw finish(.unexpectedReply) }
            } else if awaitingBaseline {
                throw finish(.unexpectedReply)
            }
            // A snapshot must belong to the incarnation the baseline named. Another incarnation ends the
            // stream, even though its correlation matches.
            if case .snapshot(let snapshot) = frame, !isBaselineIncarnation(snapshot.stamp.incarnation) {
                throw finish(.unexpectedReply)
            }
            return try accept(frame)
        default:
            throw finish(.unexpectedReply)
        }
    }

    /// Releases the stream. Idempotent, and it never stops the host.
    func cancel() {
        finish(.readAborted(.cancelled))
    }

    /// Claims the single read slot. A concurrent read and a closed subscription are refused here,
    /// without touching the transport. Returns whether the baseline is still owed.
    private func beginRead() throws -> Bool {
        try lock.withLock { () throws -> Bool in
            if reading { throw RuntimeClientError.readInProgress }
            if case .closed(let error) = phase { throw error }
            reading = true
            if case .awaitingBaseline = phase { return true }
            return false
        }
    }

    private func endRead() {
        lock.withLock { reading = false }
    }

    /// Hands one validated frame to the caller. A frame that lands after the subscription closed during
    /// the wait is dropped and never delivered. The first baseline moves the subscription to live and
    /// retains its incarnation.
    private func accept(_ frame: ControlRuntimeFrame) throws -> ControlRuntimeFrame {
        try lock.withLock { () throws -> ControlRuntimeFrame in
            if case .closed(let error) = phase { throw error }
            if case .baseline(let baseline) = frame {
                phase = .live
                incarnation = baseline.incarnation
            }
            return frame
        }
    }

    private func isBaselineIncarnation(_ value: ControlHostIncarnation) -> Bool {
        lock.withLock { incarnation == value }
    }

    /// The terminal error, when the subscription has already closed.
    private func closedError() -> RuntimeClientError? {
        lock.withLock { () -> RuntimeClientError? in
            if case .closed(let error) = phase { return error }
            return nil
        }
    }

    /// Maps a failed wait. A deadline, a cancel or a cancelled task is an allowed wait failure: the stream
    /// stays valid and no frame was consumed. Any other error is terminal, and it releases the stream.
    private func waitFailure(_ error: any Error) -> RuntimeClientError {
        switch error {
        case let end as RuntimeWaitEnd where end == .deadlineExpired || end == .cancelled:
            return .readAborted(end)
        case is CancellationError:
            return .readAborted(.cancelled)
        default:
            return finish(.readAborted((error as? RuntimeWaitEnd) ?? .disconnected))
        }
    }

    /// Moves to the terminal phase once and releases the stream once. The first terminal error wins and
    /// is returned for the caller to throw. Later calls change nothing.
    @discardableResult
    private func finish(_ terminal: RuntimeClientError) -> RuntimeClientError {
        let outcome = lock.withLock { () -> (error: RuntimeClientError, release: Bool) in
            if case .closed(let error) = phase { return (error, false) }
            phase = .closed(terminal)
            let release = !released
            released = true
            return (terminal, release)
        }
        if outcome.release {
            stream.cancel()
        }
        return outcome.error
    }
}
