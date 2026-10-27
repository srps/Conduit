// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel
import RuntimeEvents

// The private editor channel over the shared host (decisions 0018, 0021, 0034, 0035 and 0037). One composition owns one custody: one
// private transfer at a time, reserved before the client maps or encodes, and one admitted frozen input, held from the client's reservation
// until the update's operation has physically quiesced. Every transport the composition builds shares that custody. Ordinary Stop and status
// keep their own lanes, so neither waits on a private body. Encoding and decoding run on the caller's task, off the owner and off
// `PlatformWork`; the owner turn only captures copy-on-write values or admits.

/// The composition's one private custody. Both terms are structural bounds of one, like the three module slots, not profile values.
final class RuntimePrivateCustody: @unchecked Sendable {
    private let lock = NSLock()
    private var transferHeld = false
    private var inputHeld = false

    /// Reserves the transfer, and for an update the frozen-input slot too, or nothing: a busy term refuses before anything is reserved.
    func reserve(_ purpose: PrivateExchangePurpose) -> RuntimePrivateReservation? {
        let reserved = lock.withLock { () -> Bool in
            guard !transferHeld, purpose == .read || !inputHeld else { return false }
            transferHeld = true
            if purpose == .update { inputHeld = true }
            return true
        }
        return reserved ? RuntimePrivateReservation(custody: self, holdsInput: purpose == .update) : nil
    }

    /// What is held now: for tests and measurements, which assert release only after physical cleanup.
    var held: (transfer: Bool, input: Bool) {
        lock.withLock { (transferHeld, inputHeld) }
    }

    fileprivate func releaseTransfer() {
        lock.withLock { transferHeld = false }
    }

    fileprivate func releaseInput() {
        lock.withLock { inputHeld = false }
    }
}

/// One reserved exchange. Its transfer ends with the exchange. An update's frozen-input slot ends with it too, unless an admitted operation
/// took it over, which then releases it at quiescence. Each part is released once.
final class RuntimePrivateReservation: @unchecked Sendable {
    private let custody: RuntimePrivateCustody
    private let lock = NSLock()
    private var transferHeld = true
    private var input: RuntimeFrozenInputSlot?

    fileprivate init(custody: RuntimePrivateCustody, holdsInput: Bool) {
        self.custody = custody
        self.input = holdsInput ? RuntimeFrozenInputSlot(custody: custody) : nil
    }

    /// The frozen-input slot, handed to the operation an update admitted. Nil when this exchange holds none or already handed it over.
    func takeInputSlot() -> RuntimeFrozenInputSlot? {
        lock.withLock {
            defer { input = nil }
            return input
        }
    }

    /// Ends the exchange: after its reply was decoded and its buffers released, in the client's scope.
    func end() {
        let (transfer, slot) = lock.withLock { () -> (Bool, RuntimeFrozenInputSlot?) in
            defer { transferHeld = false; input = nil }
            return (transferHeld, input)
        }
        slot?.release()
        if transfer { custody.releaseTransfer() }
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

/// The deadlines of one private exchange: the caller's own, and the receiver's, which is the arrival plus the request's budget, as for an
/// ordinary request. Sampled in the owner turn that would admit or capture, so work invalidated before it is never newly admitted.
struct RuntimePrivateGate: Sendable {
    /// What the owner turn did: ran, found the receiver's budget lapsed, or found the caller's wait ended.
    enum Turn<Value: Sendable>: Sendable {
        case ran(Value)
        case budgetExpired
        case callerEnded(RuntimeWaitEnd)

        /// The value, nil for a lapsed budget, or the sent failure of a caller that stopped waiting after its frame was handed over.
        func result() throws -> Value? {
            switch self {
            case .ran(let value): return value
            case .budgetExpired: return nil
            case .callerEnded(let end): throw ControlRuntimeTransportFailure.sent(end)
            }
        }
    }

    let caller: RuntimeDeadline
    let arrival: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant

    @MainActor
    func turn<Value: Sendable>(budget: ControlWireBudget, _ body: () -> Value) -> Turn<Value> {
        if Task.isCancelled { return .callerEnded(.cancelled) }
        let instant = now()
        if caller.remaining(at: instant) <= .zero { return .callerEnded(.deadlineExpired) }
        if instant >= arrival.advanced(by: .milliseconds(budget.rawValue)) { return .budgetExpired }
        return .ran(body())
    }
}

/// One owner turn of a private read: the capture, or the closed refusal.
enum RuntimePrivateReadTurn: Sendable {
    case capture(RuntimeConfigurationWorkflow.EditorCapture)
    case refused(ControlRejectionCode)
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
            let arrival = now()
            let gate = RuntimePrivateGate(caller: deadline, arrival: arrival, now: now)
            switch purpose {
            case .read:
                return try await Self.answerRead(frame, owner: channel.owner, gate: gate)
            case .update:
                return try await Self.answerUpdate(frame, owner: channel.owner, core: core, reservation: reservation, gate: gate)
            }
        })
    }

    /// How the caller's wait has ended, if it has: its task was cancelled or its deadline passed. Sampled at each boundary of an exchange.
    private static func ended(_ deadline: RuntimeDeadline, now: () -> ContinuousClock.Instant) -> RuntimeWaitEnd? {
        if Task.isCancelled { return .cancelled }
        return deadline.remaining(at: now()) > .zero ? nil : .deadlineExpired
    }

    /// A read's answer: decoded here, captured in one owner turn, mapped and encoded here again.
    private static func answerRead(_ frame: SecretBytes, owner: RuntimeHost, gate: RuntimePrivateGate) async throws -> SecretBytes {
        let request: PrivateEditorReadRequest
        do {
            request = try PrivateConfigurationDecoder.decodeRead(try PrivateConfigurationFrame.body(of: frame, expecting: .read))
        } catch {
            // The private header carries no request ID, so no correlated answer exists for an undecodable read.
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
        let turn = await MainActor.run { () -> RuntimePrivateGate.Turn<RuntimePrivateReadTurn> in
            gate.turn(budget: request.budget) { owner.privateRead(request) }
        }
        let answer: PrivateEditorAnswer
        switch try turn.result() {
        case nil:
            answer = .refused(.deadlineExpired)
        case .refused(let code)?:
            answer = .refused(code)
        case .capture(let capture)?:
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
        gate: RuntimePrivateGate
    ) async throws -> SecretBytes {
        let request: PrivateConfigurationRequest
        do {
            request = try PrivateConfigurationDecoder.decode(try PrivateConfigurationFrame.body(of: frame, expecting: .update))
        } catch {
            throw ControlRuntimeTransportFailure.sent(.invalidReply)
        }
        let admission: ControlAdmission
        do {
            // The administrative flag is the store's, merged inside the claim, so the value passed here is never written.
            let values = try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: false)
            // Checked in the admission turn itself. A budget that lapsed during the decode and mapping is the typed refusal, with no alias:
            // nothing was admitted. A caller whose own wait ended learns only that its admission is unknown.
            let turn = await MainActor.run { () -> RuntimePrivateGate.Turn<ControlAdmission> in
                gate.turn(budget: request.budget) {
                    core.submitPrivate(requestID: request.requestID, expectedIncarnation: request.incarnation) { operation in
                        owner.fencePrivateUpdate(
                            request, values: (values.config, values.platform), operation: operation,
                            takeInput: { reservation.takeInputSlot() }
                        )
                    }
                }
            }
            admission = try turn.result() ?? .rejected(.deadlineExpired)
        } catch let failure as ControlRuntimeTransportFailure {
            throw failure
        } catch {
            admission = .rejected(.commandTooLarge)
        }
        let hostIncarnation = admission == .rejected(.changedIncarnation) ? core.incarnation : request.incarnation
        return try encodeReply(PrivateEditorReply(requestID: request.requestID, hostIncarnation: hostIncarnation, answer: .admission(admission))) {
            .admission(.rejected(.internalFailure))
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
        /// A save, with the revision each apply-while-running module was admitted at, nil for a save-only module.
        case save(RuntimeConfigurationWorkflow.SaveTicket, RuntimeConfigurationWorkflow.FrozenInput, applying: PrivateModuleSlots<Int?>)
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
            guard case .success(let ticket) = workflow.admitSave(requestID: request.requestID) else {
                emitConfigurationEvents(workflow.terminalRefusal())
                return .rejected(.hostStopping)
            }
            pendingAdmissions += 1
            stoppedEffectsJoin?.finish(.superseded)
            work = .save(ticket, frozen, applying: applying)
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
        case .save(let ticket, let frozen, let applying):
            defer { pendingAdmissions -= 1 }
            await awaitLaunchRecovery()
            let saved = await workflow.saveFrozen(ticket, frozen)
            emitConfigurationEvents(saved.events)
            var applied: Bool?
            if ControlModule.allCases.contains(where: { applying[$0] != nil }) {
                applied = if let verified = saved.commit?.verifiedInput { await applyWhileRunning(verified, at: applying) } else { false }
            }
            return receipt(
                update.requestID, commit: saved.commit, dnsStaged: saved.dnsStaged, modules: [], applied: applied,
                unsaved: saved.superseded ? .staleRevision : .effectFailed
            )
        case .start(let admitted):
            var unsaved = ControlFailureCode.effectFailed
            do {
                _ = try await runAdmittedStart(admitted)
            } catch let refusal as RuntimeStartRefusal {
                if refusal == .superseded || refusal == .terminated { unsaved = .staleRevision }
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
    /// or enables a module; a Stop or newer Start of a named module, or a newer write, holds the rest. Returns whether the pair is applied.
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
        reconciler.reconcile(config: verified.runtime, platformConfig: verified.platform, isCurrent: stands)
        await reconciler.drain()
        guard stands() else { return false }
        if ConfigDiff(old: config, new: verified.runtime).inputChanged || platformConfig != verified.platform {
            adoptHostView(runtime: verified.runtime, platform: verified.platform)
        }
        return true
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
            baseline: outcome.verifiedReceipt.map { receipt in
                let file: ControlConfigWorkflowFile = switch receipt.component {
                case .runtime: .runtime
                case .platform: .platform
                case .preferences: .preferences
                }
                return PrivateBaseline(
                    namespace: PrivateBaselineNamespace(rawValue: receipt.storeIncarnation), component: file, version: receipt.version
                )
            }
        )
    }
}
