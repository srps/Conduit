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
    /// Not attempted: the Quit was not admitted, or an earlier update still held the one frozen-input slot.
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
    /// submitted, its settlement is awaited first: the host releases an update's frozen input before it publishes the settlement. A
    /// settlement is not physical quiescence, though: the earlier caller may still be decoding its reply under the one transfer, and an
    /// update the host never recorded may still be on its way. So each final save waits, within the same deadline, for the custody's
    /// physical release rather than taking a momentary busy as its answer. The configuration save goes before the preferences save, which
    /// waits for its settlement. A save is mapped by its producer inside its exchange, under the ID minted here and with the remaining
    /// budget; it must be all save-only, so the quit never applies or starts anything and writes no disable. Each producer is handed the
    /// prior update's step: a settled receipt there is the only fact it may rebase a submitted baseline from, so later local edits stay
    /// its own. An invalid runtime draft does not hold back valid sidecar or preference edits: the caller's producer submits its last clean
    /// runtime value under the exact baseline it was submitted with, and nothing here rereads or retokenizes it. A declared save that is
    /// never admitted keeps the host's window open until the total deadline; the Quit still ends then.
    package static func quit(
        control: any RuntimeClient,
        editor: PrivateEditorClient,
        incarnation: ControlHostIncarnation,
        total: Duration,
        now: ContinuousClock.Instant = .now,
        priorUpdate: ControlRequestID? = nil,
        configuration: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest)? = nil,
        preferences: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivatePreferencesRequest)? = nil
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
                total: try deadline.wireBudget(at: .now, cappedAt: total),
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
        let settlements = SettlementWaiter(control: control, incarnation: incarnation, deadline: deadline, quit: quitOperation)
        await settlements.subscribe()
        defer {
            settlements.cancel()
        }

        if let priorUpdate {
            result.priorUpdate = await settlements.settlement(ofRequest: priorUpdate)
        }
        // A prior update still unsettled may still hold the frozen input, so no final save is sent.
        let prior = result.priorUpdate
        let inputFree = if case .unsettled = prior { false } else { true }
        if inputFree, let configuration, let configurationID {
            let budgetCap = total
            result.configuration = await settlements.admitAndSettle(configurationID) {
                try await editor.submit(requestID: configurationID, deadline: deadline, awaitingCapacity: true) {
                    var request = try configuration(configurationID, prior)
                    guard request.modules == PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly) else {
                        throw PrivateConfigurationWireError.invalidValue
                    }
                    request.budget = try deadline.wireBudget(at: .now, cappedAt: budgetCap)
                    return request
                }
            }
        }
        let configurationReleased = if case .unsettled = result.configuration { false } else { true }
        if inputFree, configurationReleased, let preferences, let preferencesID {
            let budgetCap = total
            result.preferences = await settlements.admitAndSettle(preferencesID) {
                try await editor.submitPreferences(requestID: preferencesID, deadline: deadline, awaitingCapacity: true) {
                    var request = try preferences(preferencesID, prior)
                    request.budget = try deadline.wireBudget(at: .now, cappedAt: budgetCap)
                    return request
                }
            }
        }
        result.quit = await settlements.settlement(of: quitOperation)
        result.observationFailure = settlements.failure
        return result
    }

    fileprivate static func clientError(_ error: any Error) -> RuntimeClientError {
        if let error = error as? RuntimeClientError { return error }
        return .localRefusal(.invalidValue)
    }
}

/// The settlements the quit waits for, read from one live stream. Only the Quit and the operations it has waited for are recorded, at most
/// four outcomes. Every wait looks its operation up once before reading the stream and once after the stream ended, and never more. One
/// task uses it, in order.
private final class SettlementWaiter: @unchecked Sendable {
    private let control: any RuntimeClient
    private let incarnation: ControlHostIncarnation
    private let deadline: RuntimeDeadline
    private var stream: RuntimeSubscription?
    private var streamEnded = true
    private var watched: Set<ControlOperationID>
    private var finished: [ControlOperationID: ControlOperationOutcome] = [:]
    private(set) var failure: RuntimeClientError?

    init(control: any RuntimeClient, incarnation: ControlHostIncarnation, deadline: RuntimeDeadline, quit: ControlOperationID) {
        self.control = control
        self.incarnation = incarnation
        self.deadline = deadline
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

    private func lookup(_ operation: ControlOperationID) async -> ControlOperationOutcome? {
        do {
            guard case .finished(let outcome) = try await control.outcome(of: operation, expectedIncarnation: incarnation, deadline: deadline)
            else { return nil }
            return outcome
        } catch {
            record(error)
            return nil
        }
    }
}
