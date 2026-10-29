// SPDX-License-Identifier: Apache-2.0
import Foundation

// The client side of the process quit (decision 0015): one framed Quit that fences the host first, then at most the two final saves it
// declared, each under the exact baselines its caller submitted, all within one total deadline. It uses the clients' own primitives and
// nothing else: the Quit's own lane and alias partition, the private client's one transfer and frozen-input custody, and the ordinary
// settlement frames and lookups. It never retries, never rereads a draft and never mutates the host by another route.

/// What one step of the client quit came to.
package enum RuntimeQuitStep: Sendable, Equatable {
    /// The caller declared nothing for this step.
    case notDeclared
    /// The operation settled with this outcome. A save's outcome carries its causal receipt; only that receipt may rebase a draft.
    case settled(ControlOperationOutcome)
    /// The host refused the step at admission. Nothing ran.
    case rejected(ControlRejectionCode)
    /// The host has no admission recorded for the request. That proves nothing ran only together with the client's own knowledge.
    case notRecorded(ControlUnknownOutcomeReason)
    /// The client's own failure, as the client reported it: not sent, admission unknown, or a local refusal.
    case clientFailure(RuntimeClientError)
    /// Admitted, and no settlement was read before the deadline or the end of the stream.
    case unsettled(ControlOperationID)
    /// Not attempted: the Quit was not admitted.
    case skipped
}

/// The client quit's result, one step each.
package struct RuntimeClientQuitResult: Sendable, Equatable {
    package var quit: RuntimeQuitStep
    /// The earlier update the caller named, whose frozen input had to be released before a final save could take the slot.
    package var priorUpdate: RuntimeQuitStep
    package var configuration: RuntimeQuitStep
    package var preferences: RuntimeQuitStep
    /// The first failure that ended the reading of settlements early, the subscription's or a lookup's. A step it left unread is `unsettled`.
    package var observationFailure: RuntimeClientError?
}

/// The bounded client quit over one framed client and one private editor client of the same composition.
package enum RuntimeClientQuit {
    /// Quits the host, then flushes the declared final saves within `total`, counted from `now`.
    ///
    /// The Quit goes first and names the request IDs minted here for the declared saves, so only those may spend the host's reserved flush;
    /// the Quit has its own lane, so busy ordinary or private work does not hold it. When `priorUpdate` names an update the caller
    /// submitted, its settlement is read first, from a live stream when the host grants one and by lookup otherwise.
    ///
    /// Every declared save is then attempted, whatever the stream did. Its exchange waits, within the same deadline, for the frozen-input
    /// custody's physical release, which follows the earlier operation's quiescence and its caller's decode, so an update still running
    /// keeps the save out without the quit giving up on it. The configuration save goes before the preferences save, which waits the same
    /// way for the configuration save's release and is attempted whatever that save came to. A save is mapped by its producer inside its
    /// exchange, under the ID minted here and with the remaining budget; it must be all save-only, so the quit never applies or starts
    /// anything and writes no disable. Each producer is handed the prior update's step: a settled receipt there is the only fact it may
    /// rebase a submitted baseline from, so later local edits stay its own. A prior step still unsettled when the first exchange holds the
    /// released custody is looked up once more there, since the host records a settlement in the turn that releases the input; what that
    /// one lookup finds is final, and a producer handed `unsettled` keeps its exact submitted baselines. An invalid runtime draft does not hold back valid
    /// sidecar or preference edits: the caller's producer submits its last clean runtime value under the exact baseline it was submitted
    /// with, and nothing here rereads or retokenizes it. A declared save that is never admitted keeps the host's window open until the
    /// total deadline; the Quit still ends then. This returns once the Quit is read settled, or at the total deadline: with no stream to
    /// report the Quit, it keeps the caller for the rest of the deadline and reads the Quit's outcome once near its end, so a terminating
    /// caller never leaves while the host may still be tearing down. No step is retried.
    ///
    /// The wait effect defaults to continuous-clock sleep; deadline checks always use that clock.
    package static func quit(
        control: any RuntimeClient,
        editor: PrivateEditorClient,
        incarnation: ControlHostIncarnation,
        total: Duration,
        now: ContinuousClock.Instant = .now,
        priorUpdate: ControlRequestID? = nil,
        configuration: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest)? = nil,
        preferences: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivatePreferencesRequest)? = nil,
        sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { instant in
            try await Task.sleep(until: instant, clock: .continuous)
        }
    ) async -> RuntimeClientQuitResult {
        let deadline = RuntimeDeadline.after(total, from: now)
        var result = RuntimeClientQuitResult(
            quit: .skipped, priorUpdate: priorUpdate == nil ? .notDeclared : .skipped,
            configuration: configuration == nil ? .notDeclared : .skipped, preferences: preferences == nil ? .notDeclared : .skipped
        )
        let configurationID = configuration.map { _ in ControlRequestID(rawValue: UUID()) }
        let preferencesID = preferences.map { _ in ControlRequestID(rawValue: UUID()) }
        let quitID = ControlRequestID(rawValue: UUID())
        let quitOperation: ControlOperationID
        do {
            let command = ControlRuntimeCommand.quit(
                total: try remainingBudget(deadline, cappedAt: total),
                flush: try ControlQuitFlush(configuration: configurationID, preferences: preferencesID)
            )
            switch try await control.submit(command, requestID: quitID, expectedIncarnation: incarnation, deadline: deadline) {
            case .accepted(let operation), .joined(let operation):
                quitOperation = operation
            case .rejected(let code):
                result.quit = .rejected(code)
                return result
            }
        } catch {
            result.quit = .clientFailure(clientError(error))
            return result
        }

        // Subscribed after the fence. Each wait looks its operation up once first, so a settlement published before this point is not missed.
        let settlements = SettlementWaiter(control: control, incarnation: incarnation, deadline: deadline, quit: quitOperation, sleep: sleep)
        await settlements.subscribe()
        defer {
            settlements.cancel()
        }

        if let priorUpdate {
            result.priorUpdate = await settlements.settlement(ofRequest: priorUpdate)
        }
        let prior = result.priorUpdate
        if let configuration, let configurationID {
            let budgetCap = total
            result.configuration = await settlements.admitAndSettle(configurationID) {
                try await editor.submit(requestID: configurationID, deadline: deadline, awaitingCapacity: true) {
                    let released = await settlements.released(prior)
                    var request = try configuration(configurationID, released)
                    guard request.modules == PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly) else {
                        throw PrivateConfigurationWireError.invalidValue
                    }
                    request.budget = try remainingBudget(deadline, cappedAt: budgetCap)
                    return request
                }
            }
        }
        if let preferences, let preferencesID {
            let budgetCap = total
            let configurationStep = result.configuration
            result.preferences = await settlements.admitAndSettle(preferencesID) {
                try await editor.submitPreferences(requestID: preferencesID, deadline: deadline, awaitingCapacity: true) {
                    let released = await settlements.released(prior)
                    // The configuration save released the same input, so its own unread settlement is recorded by now too.
                    _ = await settlements.released(configurationStep)
                    var request = try preferences(preferencesID, released)
                    request.budget = try remainingBudget(deadline, cappedAt: budgetCap)
                    return request
                }
            }
        }
        result.priorUpdate = settlements.recorded(prior)
        result.configuration = settlements.recorded(result.configuration)
        result.quit = await settlements.quitSettlement(of: quitOperation, finalReadReserve: finalQuitReadReserve)
        result.observationFailure = settlements.failure
        return result
    }

    /// How long before the total deadline the Quit's one final outcome read starts when no stream can report its settlement, so the read
    /// still has time to answer within the deadline.
    static let finalQuitReadReserve: Duration = .milliseconds(200)

    fileprivate static func clientError(_ error: any Error) -> RuntimeClientError {
        if let error = error as? RuntimeClientError { return error }
        return .localRefusal(.invalidValue)
    }

    /// The wire budget left for one step. None left is the deadline's own expiry, before anything was sent, never an invalid value.
    private static func remainingBudget(_ deadline: RuntimeDeadline, cappedAt cap: Duration) throws -> ControlWireBudget {
        let budget = try deadline.wireBudget(at: .now, cappedAt: cap)
        guard budget.rawValue > 0 else { throw RuntimeClientError.notSent(.deadlineExpired) }
        return budget
    }
}

/// The settlements the quit waits for, read from one live stream when the host grants one. Only the Quit and the operations it has waited
/// for are recorded, at most four outcomes. Every wait looks its operation up once before reading the stream and once after the stream
/// ended or was refused, and never more; an update a later save waited for gets at most one lookup beyond that, after its input's release.
/// One task uses it, in order: the producers that call `released` run inside that task's awaited exchanges.
private final class SettlementWaiter: @unchecked Sendable {
    private let control: any RuntimeClient
    private let incarnation: ControlHostIncarnation
    private let deadline: RuntimeDeadline
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var stream: RuntimeSubscription?
    private var streamEnded = true
    private var watched: Set<ControlOperationID>
    private var finished: [ControlOperationID: ControlOperationOutcome] = [:]
    /// The operations whose one lookup after their input's release was spent: the prior update and the configuration save, at most two.
    private var lookedUpAfterRelease: Set<ControlOperationID> = []
    private(set) var failure: RuntimeClientError?

    init(
        control: any RuntimeClient,
        incarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline,
        quit: ControlOperationID,
        sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void
    ) {
        self.control = control
        self.incarnation = incarnation
        self.deadline = deadline
        self.sleep = sleep
        watched = [quit]
    }

    func subscribe() async {
        do {
            stream = try await control.subscribe(.live, deadline: deadline)
            streamEnded = false
        } catch {
            record(error)
        }
    }

    func cancel() {
        stream?.cancel()
    }

    private func record(_ error: any Error) {
        if failure == nil { failure = RuntimeClientQuit.clientError(error) }
    }

    /// Admits one save, then waits for its settlement.
    func admitAndSettle(_ requestID: ControlRequestID, _ submit: () async throws -> ControlAdmission) async -> RuntimeQuitStep {
        do {
            switch try await submit() {
            case .accepted(let operation), .joined(let operation):
                return await settlement(of: operation)
            case .rejected(let code):
                return .rejected(code)
            }
        } catch {
            return .clientFailure(RuntimeClientQuit.clientError(error))
        }
    }

    /// The settlement of the operation the host recorded for `requestID`.
    func settlement(ofRequest requestID: ControlRequestID) async -> RuntimeQuitStep {
        do {
            switch try await control.lookupAdmission(of: requestID, expectedIncarnation: incarnation, deadline: deadline) {
            case .admission(.accepted(let operation)), .admission(.joined(let operation)):
                return await settlement(of: operation)
            case .admission(.rejected(let code)):
                return .rejected(code)
            case .unknown(let reason):
                return .notRecorded(reason)
            }
        } catch {
            return .clientFailure(RuntimeClientQuit.clientError(error))
        }
    }

    func settlement(of operation: ControlOperationID) async -> RuntimeQuitStep {
        watched.insert(operation)
        if let outcome = finished[operation] { return .settled(outcome) }
        if let outcome = await lookup(operation) { return .settled(outcome) }
        while !streamEnded, let stream {
            do {
                switch try await stream.next(deadline) {
                case .operationFinished(let done):
                    if watched.contains(done.operationID) { finished[done.operationID] = done.outcome }
                    if done.operationID == operation { return .settled(done.outcome) }
                case .end(let end):
                    streamEnded = true
                    record(RuntimeClientError.streamClosed(end.reason))
                case .baseline, .snapshot, .events, .replayCaughtUp:
                    continue
                }
            } catch RuntimeClientError.readAborted(.deadlineExpired) {
                return .unsettled(operation)
            } catch {
                streamEnded = true
                record(error)
            }
        }
        if let outcome = await lookup(operation) { return .settled(outcome) }
        return .unsettled(operation)
    }

    /// The Quit's own settlement, which the caller's process lifetime follows: it stays until the Quit is read settled or the total
    /// deadline ends. Read as any other wait while a stream reports it, so a normal quit returns as soon as it settles. Once no stream can
    /// report it, refused, ended or failed, the host may still be tearing down, so the caller is kept until `finalReadReserve` before the
    /// deadline and the outcome is read once more then. A settled read is the answer. A quit still pending, or a read that failed, stays
    /// `unsettled`, and the caller is kept to the deadline itself, with no further read, so it never leaves while that teardown may run. A
    /// stream wait that itself reached the deadline has nothing left to wait for. Only the caller's own cancellation ends a wait early.
    func quitSettlement(of operation: ControlOperationID, finalReadReserve: Duration) async -> RuntimeQuitStep {
        let step = await settlement(of: operation)
        guard case .unsettled = step, streamEnded else { return step }
        guard await keepCaller(until: deadline.instant.advanced(by: .zero - finalReadReserve)) else { return step }
        if let outcome = await lookup(operation) { return .settled(outcome) }
        _ = await keepCaller(until: deadline.instant)
        return step
    }

    /// Waits until `instant`, at once when it has passed. False when the caller's cancellation ended the wait: it stopped waiting for the
    /// Quit, so the step it reads stays unsettled.
    private func keepCaller(until instant: ContinuousClock.Instant) async -> Bool {
        guard ContinuousClock.now < instant else { return true }
        do {
            try await sleep(instant)
            return true
        } catch {
            return false
        }
    }

    /// An earlier update's step, read from inside a later save's exchange, which holds the frozen input that update released. The host
    /// records an update's settlement in the owner turn that releases its input, so a step the stream left unsettled is looked up once more
    /// here, and what that one lookup finds is final: an outcome the host could not retain stays `unsettled`. Any other step is returned as
    /// it is.
    func released(_ step: RuntimeQuitStep) async -> RuntimeQuitStep {
        guard case .unsettled(let operation) = step else { return step }
        if let outcome = finished[operation] { return .settled(outcome) }
        guard lookedUpAfterRelease.insert(operation).inserted else { return step }
        if let outcome = await lookup(operation) { return .settled(outcome) }
        return step
    }

    /// `step` with any settlement read for it since, with no further lookup.
    func recorded(_ step: RuntimeQuitStep) -> RuntimeQuitStep {
        guard case .unsettled(let operation) = step, let outcome = finished[operation] else { return step }
        return .settled(outcome)
    }

    /// A finished outcome is kept for an operation the quit watches, so a later wait or `recorded` reads it without asking again.
    private func lookup(_ operation: ControlOperationID) async -> ControlOperationOutcome? {
        do {
            guard case .finished(let outcome) = try await control.outcome(of: operation, expectedIncarnation: incarnation, deadline: deadline)
            else { return nil }
            if watched.contains(operation) { finished[operation] = outcome }
            return outcome
        } catch {
            record(error)
            return nil
        }
    }
}
