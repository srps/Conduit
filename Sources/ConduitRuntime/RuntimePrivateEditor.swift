// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import ProxyControlBridge
import ProxyKernel
import RuntimeEvents

// The private editor channel over the shared host (decisions 0018, 0021, 0034, 0035 and 0037). One composition owns one custody: one
// private transfer at a time, reserved before the client maps or encodes, and one admitted frozen input, held from the client's reservation
// until the update's operation has physically quiesced. Every transport the composition builds shares that custody. Ordinary Stop and status
// keep their own lanes, so neither waits on a private body. Encoding and decoding run on the caller's task, off the owner and off
// `PlatformWork`; the owner turn only captures copy-on-write values or admits.

/// The composition's one private custody. Both terms are structural bounds of one, like the three module slots, not profile values. The
/// transfer is one slot of the custody's own lane counter, so its reservation is a lane ticket with the ordinary parts: the client's scope,
/// and the wait's timer and owner hops.
final class RuntimePrivateCustody: @unchecked Sendable {
    private let lock = NSLock()
    private let transfers: RuntimeLaneCounter
    private var inputHeld = false

    init(limits: RuntimeServiceLimits) {
        transfers = RuntimeLaneCounter(limits: limits)
    }

    /// Reserves the transfer, and for an update the frozen-input slot too, or nothing: a busy term refuses before anything is reserved.
    func reserve(_ purpose: PrivateExchangePurpose) -> RuntimePrivateReservation? {
        let input = RuntimePrivateInputHold()
        let reserved = lock.withLock { () -> RuntimeLaneTicket? in
            guard !purpose.holdsInput || !inputHeld else { return nil }
            // An input the round never took is released only when the ticket has quiesced: no queued or running round can still admit.
            guard let ticket = transfers.reserve(.privateTransfer, onQuiesced: { input.releaseUntaken() }) else { return nil }
            if purpose.holdsInput {
                inputHeld = true
                input.hold(RuntimeFrozenInputSlot(custody: self))
            }
            return ticket
        }
        guard let ticket = reserved else { return nil }
        _ = ticket.begin(.clientScope)
        return RuntimePrivateReservation(ticket: ticket, input: input)
    }

    /// What is held now: for tests and measurements, which assert release only after physical cleanup.
    var held: (transfer: Bool, input: Bool) {
        let transfer = transfers.inFlight(.privateTransfer) > 0
        return (transfer, lock.withLock { inputHeld })
    }

    fileprivate func releaseInput() {
        lock.withLock { inputHeld = false }
    }
}

/// An exchange's frozen-input slot until its round hands it to the admitted operation, or the exchange's ticket quiesces without that.
final class RuntimePrivateInputHold: @unchecked Sendable {
    private let lock = NSLock()
    private var slot: RuntimeFrozenInputSlot?

    fileprivate func hold(_ slot: RuntimeFrozenInputSlot) {
        lock.withLock { self.slot = slot }
    }

    fileprivate func take() -> RuntimeFrozenInputSlot? {
        lock.withLock {
            defer { slot = nil }
            return slot
        }
    }

    fileprivate func releaseUntaken() {
        take()?.release()
    }
}

/// One reserved exchange: its transfer ticket and its input. The client's scope is one ticket part, ended with the exchange; the one
/// send's wait adds its timer and hop parts. The ticket, and with it the transfer, returns only when every part has physically ended.
final class RuntimePrivateReservation: @unchecked Sendable {
    let ticket: RuntimeLaneTicket
    private let input: RuntimePrivateInputHold
    private let lock = NSLock()
    private var waited = false

    fileprivate init(ticket: RuntimeLaneTicket, input: RuntimePrivateInputHold) {
        self.ticket = ticket
        self.input = input
    }

    /// The frozen-input slot, handed to the operation an update admitted, in the claimed round. Nil when this exchange holds none.
    func takeInputSlot() -> RuntimeFrozenInputSlot? {
        input.take()
    }

    /// Hands the ticket's timer part to the exchange's one wait. False for a second send, which the exchange refuses unsent.
    fileprivate func beginWait() -> Bool {
        lock.withLock {
            defer { waited = true }
            return !waited
        }
    }

    /// Ends the exchange's client scope: after its reply was decoded and its buffers released. An exchange that never waited also ends the
    /// timer part its ticket started with.
    func end() {
        let waitedOnce = lock.withLock {
            defer { waited = true }
            return waited
        }
        ticket.end(waitedOnce ? .clientScope : [.clientScope, .timer])
    }
}

/// The one admitted frozen input's custody, from the client's reservation until its operation quiesces. Released once.
final class RuntimeFrozenInputSlot: @unchecked Sendable {
    private let custody: RuntimePrivateCustody
    private let lock = NSLock()
    private var held = true

    fileprivate init(custody: RuntimePrivateCustody) {
        self.custody = custody
    }

    func release() {
        let release = lock.withLock { () -> Bool in
            defer { held = false }
            return held
        }
        if release { custody.releaseInput() }
    }
}

/// One owner turn of a private read: the capture, or the closed refusal.
enum RuntimePrivateReadTurn: Sendable {
    case capture(RuntimeConfigurationWorkflow.EditorCapture)
    case refused(ControlRejectionCode)
}

/// What one private round answered, before any reply byte exists: a read's turn, or an update's admission. The round runs through the
/// transport's ordinary gate (`RuntimeInMemoryTransport.wait`), so the caller's deadline or cancellation detaches it as for any request.
enum RuntimePrivateTurn: Sendable {
    case read(RuntimePrivateReadTurn)
    case admission(ControlAdmission)
}

/// One private exchange's single owner round, through the transport's gate: the caller's deadline, or the request's budget from the
/// arrival when that ends first, bounds the wait, and the caller's cancellation detaches it. Before a claim the end is unsent, or the typed
/// budget refusal; after one it is sent, and the claimed round still runs and may admit. The round's turn holds only copy-on-write values
/// or an admission: decoding, mapping and encoding stay on the caller's task.
struct RuntimePrivateRound: Sendable {
    let transport: RuntimeInMemoryTransport
    let reservation: RuntimePrivateReservation
    let caller: RuntimeDeadline
    let arrival: ContinuousClock.Instant

    func turn(
        budget: ControlWireBudget,
        refusal: RuntimePrivateTurn,
        _ body: @escaping @MainActor @Sendable () -> RuntimePrivateTurn
    ) async throws -> RuntimePrivateTurn {
        guard reservation.beginWait() else { throw ControlRuntimeTransportFailure.notSent(.invalidReply) }
        let budgetEnds = arrival.advanced(by: .milliseconds(budget.rawValue))
        let bounded = budgetEnds < caller.instant
        let answered = NIOLockedValueBox(false)
        let outcome = await transport.wait(
            on: reservation.ticket,
            deadline: bounded ? RuntimeDeadline(instant: budgetEnds) : caller,
            boundRefusal: bounded ? .privateTurn(refusal) : nil
        ) { _ in
            answered.withLockedValue { $0 = true }
            return .privateTurn(body())
        }
        switch outcome {
        case .privateTurn(let turn):
            // A round that answered is ending its hop and has cancelled its timer: the slot is free once the client scope ends, so the
            // client's next exchange is not refused busy by this one. A refusal made before any claim waits for nothing.
            if answered.withLockedValue({ $0 }) { await reservation.ticket.settled(leaving: .clientScope) }
            return turn
        case .failed(let failure):
            throw failure
        case .reply, .opened:
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
    }
}

/// The composition's private channel: its one custody and the host that answers it. Every transport of the composition shares it.
struct RuntimePrivateChannel: Sendable {
    let custody: RuntimePrivateCustody
    let owner: RuntimeHost
}

extension RuntimeInMemoryTransport: PrivateEditorTransport {
    func withPrivateExchange<T: Sendable>(
        _ purpose: PrivateExchangePurpose,
        _ body: (PrivateExchange) async throws -> T
    ) async throws -> T {
        guard let channel = privateChannel else { throw ControlRuntimeTransportFailure.notSent(.disconnected) }
        guard let reservation = channel.custody.reserve(purpose) else { throw ControlRuntimeTransportFailure.notSent(.transportBusy) }
        defer { reservation.end() }
        let core = self.core
        let now = timing.now
        return try await body(PrivateExchange { frame, deadline in
            // Before the frame is handed over, a known end means nothing was sent.
            if let end = Self.ended(deadline, now: now) { throw ControlRuntimeTransportFailure.notSent(end) }
            let round = RuntimePrivateRound(transport: self, reservation: reservation, caller: deadline, arrival: now())
            switch purpose {
            case .read:
                return try await Self.answerRead(frame, owner: channel.owner, round: round)
            case .update:
                return try await Self.answerUpdate(frame, owner: channel.owner, core: core, reservation: reservation, round: round)
            case .preferences:
                return try await Self.answerPreferences(frame, owner: channel.owner, core: core, reservation: reservation, round: round)
            }
        })
    }

    /// How the caller's wait has ended, if it has: its task was cancelled or its deadline passed. Sampled at each boundary of an exchange.
    private static func ended(_ deadline: RuntimeDeadline, now: () -> ContinuousClock.Instant) -> RuntimeWaitEnd? {
        if Task.isCancelled { return .cancelled }
        return deadline.remaining(at: now()) > .zero ? nil : .deadlineExpired
    }

    /// A read's answer: decoded here, captured in one owner turn, mapped and encoded here again.
    private static func answerRead(_ frame: SecretBytes, owner: RuntimeHost, round: RuntimePrivateRound) async throws -> SecretBytes {
        let request: PrivateEditorReadRequest
        do {
            request = try PrivateConfigurationDecoder.decodeRead(try PrivateConfigurationFrame.body(of: frame, expecting: .read))
        } catch {
            // The private header carries no request ID, so no correlated answer exists for an undecodable read.
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
        let turn = try await round.turn(budget: request.budget, refusal: .read(.refused(.deadlineExpired))) {
            .read(owner.privateRead(request))
        }
        let answer: PrivateEditorAnswer
        switch turn {
        case .admission:
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        case .read(.refused(let code)):
            answer = .refused(code)
        case .read(.capture(let capture)):
            do {
                answer = .observation(try capture.observation())
            } catch {
                // The mapping's resource preflight refused the values; no value or error text is kept.
                answer = .refused(.internalFailure)
            }
        }
        // A changed incarnation names the host that answered; every other answer is the requested incarnation's.
        let answering = answer == .refused(.changedIncarnation) ? owner.incarnation : request.incarnation
        return try encodeReply(PrivateEditorReply(requestID: request.requestID, hostIncarnation: answering, answer: answer)) {
            .refused(.internalFailure)
        }
    }

    /// An update's answer: decoded and mapped here, admitted in one owner turn through the service, its admission encoded here.
    private static func answerUpdate(
        _ frame: SecretBytes,
        owner: RuntimeHost,
        core: RuntimeServiceCore,
        reservation: RuntimePrivateReservation,
        round: RuntimePrivateRound
    ) async throws -> SecretBytes {
        let request: PrivateConfigurationRequest
        do {
            request = try PrivateConfigurationDecoder.decode(try PrivateConfigurationFrame.body(of: frame, expecting: .update))
        } catch {
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
        return try await answerAdmission(
            requestID: request.requestID, incarnation: request.incarnation, budget: request.budget, core: core, round: round
        ) {
            // The administrative flag is the store's, merged inside the claim, so the value passed here is never written.
            let values = try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: false)
            return { operation in
                owner.fencePrivateUpdate(
                    request, values: (values.config, values.platform), operation: operation, takeInput: { reservation.takeInputSlot() }
                )
            }
        }
    }

    /// An update's admission, either kind: the mapping on the caller's task, then one round through the gate that admits through the
    /// service, then the admission encoded here. A budget that ends before the claim is the typed refusal, with no alias: nothing was
    /// admitted. A caller whose own wait ended after the claim learns only that its admission is unknown; the claimed round still runs.
    private static func answerAdmission(
        requestID: ControlRequestID,
        incarnation: ControlHostIncarnation,
        budget: ControlWireBudget,
        core: RuntimeServiceCore,
        round: RuntimePrivateRound,
        map: () throws -> @MainActor @Sendable (ControlOperationID) -> ControlOwnerFenceResult
    ) async throws -> SecretBytes {
        let admission: ControlAdmission
        do {
            let fence = try map()
            let turn = try await round.turn(budget: budget, refusal: .admission(.rejected(.deadlineExpired))) {
                .admission(core.submitPrivate(requestID: requestID, expectedIncarnation: incarnation, fence: fence))
            }
            guard case .admission(let admitted) = turn else { throw ControlRuntimeTransportFailure.sent(.invalidReply) }
            admission = admitted
        } catch let failure as ControlRuntimeTransportFailure {
            throw failure
        } catch {
            admission = .rejected(.commandTooLarge)
        }
        let hostIncarnation = admission == .rejected(.changedIncarnation) ? core.incarnation : incarnation
        return try encodeReply(PrivateEditorReply(requestID: requestID, hostIncarnation: hostIncarnation, answer: .admission(admission))) {
            .admission(.rejected(.internalFailure))
        }
    }

    /// A preferences update's answer: decoded and mapped here, admitted in one owner turn through the service like any update, its
    /// admission encoded here.
    private static func answerPreferences(
        _ frame: SecretBytes,
        owner: RuntimeHost,
        core: RuntimeServiceCore,
        reservation: RuntimePrivateReservation,
        round: RuntimePrivateRound
    ) async throws -> SecretBytes {
        let request: PrivatePreferencesRequest
        do {
            request = try PrivateConfigurationDecoder.decodePreferences(try PrivateConfigurationFrame.body(of: frame, expecting: .preferences))
        } catch {
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
        return try await answerAdmission(
            requestID: request.requestID, incarnation: request.incarnation, budget: request.budget, core: core, round: round
        ) {
            let preferences = try PrivateConfigurationBridge.makePreferences(from: request)
            return { operation in
                owner.fencePrivatePreferences(request, preferences: preferences, operation: operation, takeInput: { reservation.takeInputSlot() })
            }
        }
    }

    /// The reply frame, or a closed refusal in its place when the answer cannot be encoded within the reply cap. A refusal that cannot be
    /// encoded either is a sent failure with no answer.
    private static func encodeReply(_ reply: PrivateEditorReply, fallback: () -> PrivateEditorAnswer) throws -> SecretBytes {
        do {
            return try PrivateConfigurationEncoder.encode(reply)
        } catch {
            do {
                return try PrivateConfigurationEncoder.encode(
                    PrivateEditorReply(requestID: reply.requestID, hostIncarnation: reply.hostIncarnation, answer: fallback())
                )
            } catch {
                throw ControlRuntimeTransportFailure.sent(.invalidReply)
            }
        }
    }
}

/// A single-use hand-off of one admitted update into its effect.
@MainActor
final class RuntimePrivateWorkBox {
    private var update: RuntimePrivateUpdate?

    init(_ update: RuntimePrivateUpdate) {
        self.update = update
    }

    func take() -> RuntimePrivateUpdate {
        guard let taken = update else { preconditionFailure("an update's work is taken once") }
        update = nil
        return taken
    }
}

/// One admitted private update the host holds until it launches: its frozen work and its frozen-input slot.
struct RuntimePrivateUpdate {
    enum Work {
        case start(RuntimeAdmittedStart)
        /// A save; its ticket names the revision of each module it applies to.
        case save(RuntimeConfigurationWorkflow.SaveTicket, RuntimeConfigurationWorkflow.FrozenInput)
        /// A preferences save under the exact preferences baseline its request named.
        case preferences(RuntimeConfigurationWorkflow.SaveTicket, AppPreferences, PrivateBaseline)
    }

    let requestID: ControlRequestID
    let work: Work
    let slot: RuntimeFrozenInputSlot
}

/// The host side of the private channel. Each call is one owner turn with no I/O.
extension RuntimeHost {
    func privateRead(_ request: PrivateEditorReadRequest) -> RuntimePrivateReadTurn {
        guard request.incarnation == incarnation else { return .refused(.changedIncarnation) }
        return .capture(workflow.editorCapture())
    }

    /// The whole request in one turn (decision 0035): every actionable revision is checked before anything changes, and a refusal changes
    /// nothing. Start slots form one group through the host's one Start path, with the frozen candidate in place of the saved capture. A
    /// request with no Start changes no lifecycle intent: it saves, and applies to each apply-while-running module still running at the
    /// revision it named. A Start beside an apply-while-running slot is not adopted yet, so it is refused whole.
    func fencePrivateUpdate(
        _ request: PrivateConfigurationRequest,
        values: (runtime: ProxyConfig, platform: PlatformIntegrationConfig),
        operation: ControlOperationID,
        takeInput: () -> RuntimeFrozenInputSlot?
    ) -> ControlOwnerFenceResult {
        var actions = PrivateModuleSlots<RuntimeModuleAction>(proxy: .none, dns: .none, tunnels: .none)
        var expected = PrivateModuleSlots<Int?>(proxy: nil, dns: nil, tunnels: nil)
        var applying = PrivateModuleSlots<Int?>(proxy: nil, dns: nil, tunnels: nil)
        for module in ControlModule.allCases {
            switch request.modules[module] {
            case .saveOnly:
                break
            case .applyWhileRunning(let revision):
                applying[module] = revision.rawValue
            case .start(let revision):
                actions[module] = .start
                expected[module] = revision.rawValue
            }
        }
        let applies = ControlModule.allCases.filter { applying[$0] != nil }
        if !applies.isEmpty {
            guard ControlModule.allCases.allSatisfy({ actions[$0] == .none }) else { return .rejected(.notImplemented) }
            let current = workflow.revisions
            if let stale = applies.first(where: { applying[$0] != current[$0] }) {
                emitConfigurationEvents(workflow.admissionEvents(.stale(stale)))
                return .rejected(.staleRevision)
            }
        }
        let frozen = workflow.frozenInput(
            runtime: values.runtime, platform: values.platform,
            runtimeBaseline: request.runtimeBaseline, platformBaseline: request.platformBaseline
        )
        let members = ControlModule.allCases.filter { actions[$0] == .start }
        let work: RuntimePrivateUpdate.Work
        if members.isEmpty {
            // After the quit latched, only its reserved flush is admitted: all save-only, nothing to start or apply.
            if workflow.isTerminal, !applies.isEmpty {
                emitConfigurationEvents(workflow.terminalRefusal())
                return .rejected(.hostStopping)
            }
            guard let ticket = admitSave(request.requestID, applying: applying, flush: .configuration) else { return .rejected(.hostStopping) }
            work = .save(ticket, frozen)
        } else {
            let operationName: LifecycleOperation = members.count == 1
                ? (members[0] == .proxy ? .proxyStart : members[0] == .dns ? .dnsStart : .tunnelsStart)
                : .runtimeStart
            switch admitModuleStart(actions, expecting: expected, operation: operationName, restartsProxy: false, requestID: request.requestID) {
            case .success(var admitted):
                admitted.frozen = frozen
                work = .start(admitted)
            case .failure(.stale): return .rejected(.staleRevision)
            case .failure(.terminated): return .rejected(.hostStopping)
            case .failure: return .rejected(.internalFailure)
            }
        }
        guard let slot = takeInput() else { preconditionFailure("an update's exchange holds the frozen-input slot") }
        privateUpdates[operation] = RuntimePrivateUpdate(requestID: request.requestID, work: work, slot: slot)
        return .admitted
    }

    /// A preferences update in one turn: an all-save-only admission with no module, so it starts, applies and fences nothing. After the quit
    /// latched, only its reserved preferences flush is admitted.
    func fencePrivatePreferences(
        _ request: PrivatePreferencesRequest,
        preferences: AppPreferences,
        operation: ControlOperationID,
        takeInput: () -> RuntimeFrozenInputSlot?
    ) -> ControlOwnerFenceResult {
        guard let ticket = admitSave(request.requestID, applying: PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil), flush: .preferences)
        else { return .rejected(.hostStopping) }
        guard let slot = takeInput() else { preconditionFailure("an update's exchange holds the frozen-input slot") }
        privateUpdates[operation] = RuntimePrivateUpdate(
            requestID: request.requestID, work: .preferences(ticket, preferences, request.preferencesBaseline), slot: slot
        )
        return .admitted
    }

    /// The one all-save-only admission of both update kinds. Before the quit it is admitted as is; after it, only as the window's `flush`
    /// part, once. A refusal comes with its typed event and changes nothing. An admitted save is pending work until its run ends.
    private func admitSave(
        _ requestID: ControlRequestID,
        applying: PrivateModuleSlots<Int?>,
        flush: RuntimeQuitFlush.Part
    ) -> RuntimeConfigurationWorkflow.SaveTicket? {
        let reserved = workflow.isTerminal && quitFlush?.admit(flush, requestID: requestID) == true
        guard case .success(let ticket) = workflow.admitSave(requestID: requestID, applying: applying, quitFlush: reserved) else {
            emitConfigurationEvents(workflow.terminalRefusal())
            return nil
        }
        pendingAdmissions += 1
        stoppedEffectsJoin?.finish(.superseded)
        return ticket
    }

    func startPrivateEffect(operation: ControlOperationID, report: ControlEffectReport) {
        guard let update = privateUpdates.removeValue(forKey: operation) else {
            assertionFailure("a private launch names an operation the fence did not admit")
            report.settled(.failed(.internalFailure))
            report.quiesced()
            return
        }
        // The work moves into the effect once: the closure keeps only the box, and taking the work out leaves the frozen values with the
        // call alone, so they are gone when it returns.
        let work = RuntimePrivateWorkBox(update)
        let slot = update.slot
        Task { @MainActor [self] in
            let outcome = await runPrivateUpdate(work.take())
            // The work, a Start's teardown included, has ended and its frozen values with it, so custody ends before the settlement is
            // published: a client that submits again on seeing it finds the slot free.
            slot.release()
            report.settled(outcome)
            report.quiesced()
            onControlStateChange?()
        }
    }

    /// The update's work and its causal receipt. A request whose store commit never ran has no receipt: it fails with its closed cause.
    private func runPrivateUpdate(_ update: RuntimePrivateUpdate) async -> ControlOperationOutcome {
        switch update.work {
        case .save(let ticket, let frozen):
            defer { pendingAdmissions -= 1 }
            let applying = ticket.applying
            await awaitLaunchRecovery()
            let saved = await workflow.saveFrozen(ticket, frozen)
            emitConfigurationEvents(saved.events)
            if ticket.quitFlush { quitFlush?.finish(.configuration) }
            var applied: Bool?
            if ControlModule.allCases.contains(where: { applying[$0] != nil }) {
                applied = if let verified = saved.commit?.verifiedInput { await applyWhileRunning(verified, at: applying) } else { false }
            }
            return receipt(
                update.requestID, commit: saved.commit, dnsStaged: saved.dnsStaged, modules: [], applied: applied,
                unsaved: saved.storeBusy ? .storeBusy : saved.superseded ? .staleRevision : .effectFailed
            )
        case .preferences(let ticket, let preferences, let baseline):
            defer { pendingAdmissions -= 1 }
            await awaitLaunchRecovery()
            let saved = await workflow.savePreferences(ticket, preferences, expecting: baseline)
            emitConfigurationEvents(saved.events)
            if ticket.quitFlush { quitFlush?.finish(.preferences) }
            guard let write = saved.write else { return .failed(.storeBusy) }
            do {
                return .preferencesSettled(try ControlPreferencesReceipt(
                    requestID: update.requestID, incarnation: incarnation, preferences: try Self.componentWrite(write)
                ))
            } catch {
                preconditionFailure("a receipt is built from the store's own consistent facts")
            }
        case .start(let admitted):
            var unsaved = ControlFailureCode.effectFailed
            do {
                _ = try await runAdmittedStart(admitted)
            } catch let refusal as RuntimeStartRefusal {
                if admitted.facts.storeBusy {
                    unsaved = .storeBusy
                } else if refusal == .superseded || refusal == .terminated {
                    unsaved = .staleRevision
                }
            } catch {
                // The member's own failure is recorded in its settlement below; the error text is not kept.
            }
            // Each member's result is the one its lane effect recorded, the value of its `lifecycle.module_settled`. A member that never
            // settled, because the Start ended before it took lanes, did not finish.
            let results = ControlModule.allCases.filter { admitted.actions[$0] == .start }.map { module in
                ControlModuleReceipt(
                    module: module,
                    result: admitted.facts.members?[module].map { ControlLifecycleModuleResult($0) } ?? .superseded
                )
            }
            return receipt(
                update.requestID, commit: admitted.facts.commit, dnsStaged: admitted.facts.dnsStaged, modules: results, applied: nil,
                unsaved: unsaved
            )
        }
    }

    /// Applies a save's verified pair through the one reconciler, only while every module it names still runs at the revision it was admitted
    /// at, no terminal stop latched and the store still holds the pair (decisions 0025 and 0037). It never authorizes a Start, clears a fence
    /// or enables a module; a Stop or newer Start of a named module, or a newer write, holds the rest. As a reload does, the accepted view is
    /// adopted before the push, so it never falls behind what the runtime takes. Returns whether the runtime's applied input is now this
    /// whole pair: the reconciler's baseline, which moves only to what a push reports held. That is not a claim that a listener came up; a
    /// failed one shows in the snapshot and the lifecycle state. False does not say the runtime half was not taken: a module that went down
    /// before the flag actions leaves the runtime input held and the pair unreconciled.
    private func applyWhileRunning(_ verified: VerifiedRuntimePlatformInput, at revisions: PrivateModuleSlots<Int?>) async -> Bool {
        let stands: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, !self.workflow.isTerminal, self.workflow.stillHolds(verified) else { return false }
            let current = self.workflow.revisions
            let down = self.modulesDown()
            return ControlModule.allCases.allSatisfy { module in
                revisions[module].map { current[module] == $0 && !down.contains(module) } ?? true
            }
        }
        guard stands() else { return false }
        if ConfigDiff(old: config, new: verified.runtime).inputChanged || platformConfig != verified.platform {
            adoptHostView(runtime: verified.runtime, platform: verified.platform)
        }
        reconciler.reconcile(config: verified.runtime, platformConfig: verified.platform, isCurrent: stands)
        await reconciler.drain()
        return !reconciler.lags(config: verified.runtime, platformConfig: verified.platform)
    }

    private func receipt(
        _ requestID: ControlRequestID,
        commit: RuntimePlatformCommitResult?,
        dnsStaged: Bool?,
        modules: [ControlModuleReceipt],
        applied: Bool?,
        unsaved: ControlFailureCode
    ) -> ControlOperationOutcome {
        guard let commit else { return .failed(unsaved) }
        do {
            let runtime = try Self.componentWrite(commit.runtime)
            return .configurationSettled(try ControlConfigurationReceipt(
                requestID: requestID,
                incarnation: incarnation,
                runtime: runtime,
                platform: try Self.componentWrite(commit.platform),
                committedDNSForwarderEnabled: runtime.write.isVerified ? dnsStaged : nil,
                modules: modules,
                applied: applied
            ))
        } catch {
            preconditionFailure("a receipt is built from the store's own consistent facts")
        }
    }

    /// One file's safe result: its closed write, and the exact new baseline only when it verified.
    private static func componentWrite(_ outcome: ConfigurationWriteOutcome) throws -> ControlComponentWrite {
        try ControlComponentWrite(
            write: ControlConfigWorkflowWrite(RuntimeConfigurationWorkflow.write(outcome)),
            baseline: outcome.verifiedReceipt.map { RuntimeConfigurationWorkflow.privateBaseline($0) }
        )
    }
}
