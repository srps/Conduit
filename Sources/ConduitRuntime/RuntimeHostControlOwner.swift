// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel
import RuntimeEvents

/// The presentation revision of the host's control snapshots, and the last snapshot stamped with it. The revision moves only when a
/// projection differs from the last one, so the service's slot never sees two bodies under one revision. It holds one snapshot, replaced
/// in place, and no history. A nil `last` means the current revision has no body yet: nothing was projected, or a settlement reserved it.
struct RuntimeHostPresentation {
    private(set) var revision = 0
    private(set) var last: ControlRuntimeSnapshot?
    /// Whether the latest projection failed, so its diagnostic is recorded once per failure episode. A stamped projection clears it.
    private(set) var failing = false

    /// `revision` is the first revision, 0 for a host; a test seeds it near `Int.max` to reach exhaustion.
    init(revision: Int = 0) {
        precondition(revision >= 0, "a presentation revision is never negative")
        self.revision = revision
    }

    /// `projected` is stamped with the current revision. An equal projection answers the last snapshot; a different one takes the next
    /// revision, and a body for a revision that has none takes that revision. Nil when a changed body needs a revision past the maximum:
    /// the read fails closed rather than reuse a revision for a different body.
    mutating func stamp(_ projected: ControlRuntimeSnapshot) -> ControlRuntimeSnapshot? {
        if let last, last == projected {
            failing = false
            return last
        }
        var stamped = projected
        if last != nil {
            guard revision < Int.max, let next = ControlPresentationRevision(rawValue: revision + 1) else { return nil }
            revision += 1
            stamped.stamp.presentationRevision = next
        }
        last = stamped
        failing = false
        return stamped
    }

    /// Records a failed projection. True only when it begins a failure episode, so the caller records its diagnostic once.
    mutating func projectionFailed() -> Bool {
        defer { failing = true }
        return !failing
    }

    /// A settlement that no projection reflects yet takes the next revision, with no body, so the first projection after it takes that
    /// revision and a subscriber holding an older one knows its view is not current. Repeated reservations before that projection name
    /// the same revision, which reflects them all. False at the maximum, where no newer revision exists.
    mutating func reserveUnprojected() -> Bool {
        guard last != nil else { return true }
        guard revision < Int.max else { return false }
        revision += 1
        last = nil
        return true
    }
}

extension RuntimeConfigurationWorkflow.EditorCapture {
    /// The private observation for this capture, through the one bridge mapping and its resource preflight. It copies every value, so a
    /// caller runs it off the owner, beside the encoding.
    func observation() throws -> PrivateEditorObservation {
        try PrivateConfigurationBridge.makeObservation(
            config: values.runtime, platform: values.platform, preferences: values.preferences,
            terminal: terminal, components: components, modules: modules
        )
    }
}

/// One collection's revision: the kernel value it was taken from, and a counter that moves whenever that value differs. The value is the
/// kernel's own copy-on-write storage, so an unchanged collection compares in constant time and the host keeps no projected rows.
private struct RuntimeCollectionRevisionTracker<Source: Equatable> {
    private var source: Source?
    private var revision = 0
    /// Set once a change needed a revision past the maximum. A revision names one body for its whole life, so none is reused; the
    /// collection then reports no captured revision for the rest of this host's life.
    private var exhausted = false

    mutating func revision(for current: Source) -> ControlCollectionRevision? {
        if let source, source == current {
            return exhausted ? nil : ControlCollectionRevision(rawValue: revision)
        }
        if source != nil {
            if revision == Int.max { exhausted = true }
            if !exhausted { revision += 1 }
        }
        source = current
        return exhausted ? nil : ControlCollectionRevision(rawValue: revision)
    }
}

/// The revisions the host's snapshots pin for its four collections, each taken in the snapshot's own owner turn. A page captures its rows
/// in that turn too (`projectedRows`), so the rows are exactly the revision's.
struct RuntimeHostCollections {
    private var activeConnections = RuntimeCollectionRevisionTracker<ActiveConnectionStore>()
    private var upstreamHealth = RuntimeCollectionRevisionTracker<[UpstreamRuntimeStatus]>()
    private var tunnelBindings = RuntimeCollectionRevisionTracker<[TunnelBindingInfo]>()
    private var tunnelDNSHosts = RuntimeCollectionRevisionTracker<TunnelDNSOverrideStatus>()

    mutating func revisions(of snapshot: ProxyOrchestratorSnapshot) -> ControlCollectionRevisions {
        ControlCollectionRevisions(
            activeConnections: activeConnections.revision(for: snapshot.activeConnections),
            upstreamHealth: upstreamHealth.revision(for: snapshot.upstreamStatuses),
            tunnelBindings: tunnelBindings.revision(for: snapshot.bindings.tunnels),
            tunnelDNSHosts: tunnelDNSHosts.revision(for: snapshot.tunnelDNSOverrideStatus)
        )
    }
}

/// A control operation the host admitted at the service's fence and has not launched. It holds no configuration value.
enum RuntimeControlAdmission {
    case stop(RuntimeAdmittedStop, ControlModule)
    /// A saved Start or Restart, settled with its causal receipt for `request`.
    case start(RuntimeAdmittedStart, request: ControlRequestID)
    case launchAtLogin(Bool, PrivateBaseline, ControlRequestID)
    /// The quit latched at the fence; its work already runs, and its window holds the one total deadline.
    case quit(Task<Void, Never>, RuntimeQuitFlush)
    /// A DNS liveness probe of the port the fence chose.
    case dnsProbe(port: Int)
    /// A preflight request, pending work from its admission (`admitPreflight`); its effect joins a pass at launch (`preflightPass`).
    case preflight
    /// The client changed the saved password; the effect drops the cached credential.
    case credentialsChanged
    /// An explicit reload, pending work from its admission, with the intent generation its fence captured.
    case reload(capturedAt: Int, request: ControlRequestID)
}

/// The latest control Stop of one module: the service operation and the revision its fence took.
struct RuntimeControlStop {
    let operation: ControlOperationID
    let revision: Int
}

/// The host is the service's one command owner (decisions 0014, 0031 and 0035). Its fence is the host's own synchronous admission, the
/// same `admitModuleStop` and `admitModuleStart` its facades compose, made in the service's admission turn before launch recovery or any
/// I/O. The service only dispatches: it never decides what a command does to intent. The effect is the matching `runAdmitted…` half.
extension RuntimeHost: ControlCommandOwner {
    /// The scalar snapshot of this turn: the orchestrator's state, stamped with this host's incarnation, the v1 accepted-view counter
    /// (`configGeneration`) as the config revision and the whole-host lifecycle counter as the lifecycle revision. Each collection names the
    /// revision of the kernel value it was taken from in this turn (`RuntimeHostCollections`), so a page captured in the same turn is
    /// exactly that revision's rows; one whose revisions are exhausted names none. Nil, with its event, when the projection fails.
    func snapshot() -> ControlRuntimeSnapshot? {
        let revisions = workflow.revisions
        guard let lifecycle = ControlLifecycleRevision(rawValue: workflow.generation),
              let configRevision = ControlConfigRevision(rawValue: configGeneration),
              let current = ControlPresentationRevision(rawValue: presentation.revision),
              let proxy = ControlLifecycleRevision(rawValue: revisions.proxy),
              let dns = ControlLifecycleRevision(rawValue: revisions.dns),
              let tunnels = ControlLifecycleRevision(rawValue: revisions.tunnels)
        else {
            preconditionFailure("the host's counters are never negative")
        }
        let stamp = ControlRuntimeStamp(
            incarnation: incarnation, presentationRevision: current, configRevision: configRevision, lifecycleRevision: lifecycle,
            modules: ControlModuleRevisions(proxy: proxy, dns: dns, tunnels: tunnels)
        )
        var kernel = orchestrator.snapshot
        // The host's DNS health observation is a fact of the running forwarder: the kernel's run state stays authoritative, and an error
        // of the kernel's own wins. Projected before the stamp, so its change moves the presentation revision.
        if dnsRelayUnresponsive, kernel.dnsRunState == .running, kernel.dnsError == nil {
            kernel.dnsError = Self.dnsRelayUnresponsiveError
        }
        let projected: ControlRuntimeSnapshot
        do {
            projected = try RuntimeSnapshotControlProjection.snapshot(
                kernel, stamp: stamp, profileName: config.profileName, collectionRevisions: collections.revisions(of: kernel)
            )
        } catch {
            // The projection names no value in its error, and none is kept. The read that asked fails closed.
            return snapshotUnavailable(.projectionFailed)
        }
        guard let stamped = presentation.stamp(projected) else { return snapshotUnavailable(.revisionExhausted) }
        return stamped
    }

    /// The fixed DNS error the health observation projects; the app's own text for the same reading.
    static let dnsRelayUnresponsiveError = "DNS pipeline unresponsive"

    /// The closed failure of a snapshot read, recorded once per failure episode so a persistent failure cannot flood the bounded event log.
    private func snapshotUnavailable(_ reason: RuntimeServiceSnapshotUnavailableReason) -> ControlRuntimeSnapshot? {
        if presentation.projectionFailed() {
            recordLifecycle(RuntimeEvent(payload: .runtimeService(.snapshotUnavailable(reason))), level: .warning)
        }
        return nil
    }

    func projectedRows(for kind: ControlCollectionKind, within budget: ControlRowBudget) -> ControlProjection {
        RuntimeSnapshotControlProjection.projectRows(kind, from: orchestrator.snapshot, within: budget)
    }

    func serviceFault(_ fault: ControlServiceFault) {
        recordLifecycle(RuntimeEvent(payload: .runtimeService(.fault(Self.recordedFault(fault)))), level: .warning)
    }

    func fence(
        _ command: ControlRuntimeCommand,
        request: ControlRequestID,
        operation: ControlOperationID,
        candidate: ControlOperationID?
    ) -> ControlOwnerFenceResult {
        switch command {
        case .stop(let module):
            return fenceStop(module, request: request, operation: operation, candidate: candidate)
        case .start(let module, let expected, let companion):
            return fenceSavedStart(
                module, expected: expected.rawValue, conditionalDNS: companion, restartsProxy: false, request: request, operation: operation
            )
        case .restart(.proxy, let expected, let companion):
            return fenceProxyRestart(expected, conditionalDNS: companion, request: request, operation: operation)
        case .setLaunchAtLogin(let enabled, let baseline):
            guard !workflow.isTerminal else { return .rejected(.hostStopping) }
            pendingAdmissions += 1
            controlAdmissions[operation] = .launchAtLogin(enabled, baseline, request)
            return .admitted
        case .quit(let total, let flush):
            // A quit already latched, by this command or the host's own, admits no second one. A final save under the Quit's own ID could
            // never be told apart from it, so that Quit is refused as conflicting before anything latches.
            guard !workflow.isTerminal, quit == nil else { return .rejected(.hostStopping) }
            guard !flush.names(request) else { return .rejected(.requestConflict) }
            let work = admitQuit(until: ContinuousClock.now.advanced(by: .milliseconds(total.rawValue)), flushing: flush)
            guard let window = quitFlush else { preconditionFailure("a quit with a deadline holds its window") }
            controlAdmissions[operation] = .quit(work, window)
            return .admitted
        case .testDNS:
            // The app's Test DNS, from this host's own state and no editor value: system DNS's port 53 while the host manages it,
            // otherwise the forwarder's bound port, or its configured one when none is bound. It reads; it changes no intent.
            guard !workflow.isTerminal else { return .rejected(.hostStopping) }
            let port = platformConfig.manageSystemDNS ? 53 : (orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort)
            controlAdmissions[operation] = .dnsProbe(port: port)
            return .admitted
        case .refreshPreflight(let helperReplaced):
            // The app's preflight refresh. It reads; it changes no intent. A replacement it names revokes the pass already reading.
            guard !workflow.isTerminal else { return .rejected(.hostStopping) }
            admitPreflight(helperReplaced: helperReplaced)
            controlAdmissions[operation] = .preflight
            return .admitted
        case .credentialsChanged:
            guard !workflow.isTerminal else { return .rejected(.hostStopping) }
            controlAdmissions[operation] = .credentialsChanged
            return .admitted
        case .reload:
            // Captured in this admission turn, so a Start, Stop or update admitted before the effect's read makes it stale (decision 0032).
            guard !workflow.isTerminal else { return .rejected(.hostStopping) }
            pendingAdmissions += 1
            controlAdmissions[operation] = .reload(capturedAt: workflow.generation, request: request)
            return .admitted
        case .restart(.dns, _, _), .restart(.tunnels, _, _), .testUpstream:
            // Not adopted on this owner yet; each is refused whole before anything changes.
            return .rejected(.notImplemented)
        }
    }

    func reservesQuitFlush(_ requestID: ControlRequestID) -> Bool {
        workflow.isTerminal && quitFlush?.reserves(requestID) == true
    }

    func startEffect(_ command: ControlRuntimeCommand, operation: ControlOperationID, report: ControlEffectReport) {
        guard let admission = controlAdmissions.removeValue(forKey: operation) else {
            // The service launches only what this fence admitted, once.
            assertionFailure("a launch names an operation the fence did not admit: \(command.kind.rawValue)")
            report.settled(.failed(.internalFailure))
            report.quiesced()
            return
        }
        switch admission {
        case .stop(let stop, let module):
            Task { [self] in
                let outcome = await runAdmittedStop(stop)
                report.settled(controlOutcome(of: outcome, module: module, dnsWrite: stop.facts.dnsWrite))
                report.quiesced()
                onControlStateChange?()
            }
        case .launchAtLogin(let enabled, let baseline, let request):
            Task { [self] in
                defer { pendingAdmissions -= 1 }
                let outcome = await workflow.commitLaunchAtLogin(enabled, expecting: baseline, requestID: request)
                emitConfigurationEvents(outcome.events)
                report.settled(launchAtLoginOutcome(outcome.write))
                report.quiesced()
                onControlStateChange?()
            }
        case .quit(let work, let window):
            // Settled at the first of the quit's end and its deadline; quiesced only when its work has ended, so the operation keeps its
            // capacity, and the host the root, while a late teardown or write still runs.
            Task { [self] in
                report.settled(await window.settled() ? completed(.quit) : .failed(.cleanupIncomplete))
                onControlStateChange?()
                await work.value
                report.quiesced()
                onControlStateChange?()
            }
        case .dnsProbe(let port):
            Task { [self] in
                let outcome: ControlOperationOutcome
                // A port that cannot be named on the wire, as an unbound forwarder configured on port 0, has nothing to probe.
                if let wirePort = try? ControlPort(port) {
                    logger.log(.notice, "DNS test: probing 127.0.0.1:\(port)...", category: .system)
                    let answered = await dnsLiveness(port: port).value
                    if answered {
                        logger.log(.notice, "DNS test: PASS — received response from relay/forwarder pipeline.", category: .system)
                    } else {
                        logger.log(.warning, "DNS test: FAIL — no response from 127.0.0.1:\(port) within 2s.", category: .system)
                    }
                    outcome = completed(.testDNS, result: .dnsLiveness(ControlDNSLivenessProbe(port: wirePort, answered: answered)))
                } else {
                    logger.log(.warning, "DNS test: no forwarder port to probe.", category: .system)
                    outcome = .failed(.effectFailed)
                }
                report.settled(outcome)
                report.quiesced()
                onControlStateChange?()
            }
        case .start(let start, let request):
            Task { [self] in
                report.settled(await settleAdmittedStart(start, requestID: request, reportsPrior: true))
                report.quiesced()
                onControlStateChange?()
            }
        case .preflight:
            // The pass is joined in this launch turn. Quiesced when it ends: the read may outlast the quit, and the operation keeps its
            // capacity, and its pending count, until then.
            let pass = preflightPass()
            Task { [self] in
                defer { pendingAdmissions -= 1 }
                report.settled(await pass.value)
                report.quiesced()
                onControlStateChange?()
            }
        case .credentialsChanged:
            // The next handshake reads the store afresh; a read already out discards its answer. Nothing is read again here: the client
            // wrote the store, and the app never re-warms after a save or a clear either.
            credentialManager.invalidateCachedCredentials()
            report.settled(completed(.credentialsChanged))
            report.quiesced()
            onControlStateChange?()
        case .reload(let captured, let request):
            Task { [self] in
                defer { pendingAdmissions -= 1 }
                let decision = await performReload(capturedAt: captured, requestID: request)
                report.settled(completed(.reload, result: .reload(Self.reloadResult(decision))))
                report.quiesced()
                onControlStateChange?()
            }
        }
    }

    // MARK: Fences

    /// A session Stop of one module. A repeated Stop joins the pending one while that Stop's fence is still the module's latest admission;
    /// otherwise this Stop fences the module again, and a replaced Stop that never launched is released here, as the service drops it.
    private func fenceStop(
        _ module: ControlModule,
        request: ControlRequestID,
        operation: ControlOperationID,
        candidate: ControlOperationID?
    ) -> ControlOwnerFenceResult {
        if let candidate, let latest = controlStops[module], latest.operation == candidate,
           workflow.revisions[module] == latest.revision {
            return .joinedCandidate
        }
        if let candidate, case .stop(let replaced, _)? = controlAdmissions.removeValue(forKey: candidate) {
            dropAdmittedStop(replaced)
        }
        let admitted = admitModuleStop([module], reason: .session, requestID: request)
        controlAdmissions[operation] = .stop(admitted, module)
        controlStops[module] = RuntimeControlStop(operation: operation, revision: admitted.revision)
        return .admitted
    }

    /// The ordinary menu Restart of the proxy (decision 0036). `ifLifecycleRevision` is the whole-host lifecycle counter the client read in
    /// a snapshot stamp. When it still matches, in this same turn no module's revision has moved, so the proxy's own revision is taken here
    /// as its exact precondition; that is the only derivation made. `conditionalDNS` is the DNS revision the client itself observed: it
    /// asks for the companion and is checked as given, never filled from host state, and a request without it has no companion. A moved
    /// counter or DNS revision refuses the whole request before anything changes (decision 0035).
    private func fenceProxyRestart(
        _ expected: ControlLifecycleRevision,
        conditionalDNS: ControlLifecycleRevision?,
        request: ControlRequestID,
        operation: ControlOperationID
    ) -> ControlOwnerFenceResult {
        guard !workflow.isTerminal else {
            emitConfigurationEvents(workflow.terminalRefusal())
            return .rejected(.hostStopping)
        }
        guard expected.rawValue == workflow.generation else {
            emitConfigurationEvents(workflow.admissionEvents(.stale(.proxy)))
            return .rejected(.staleRevision)
        }
        return fenceSavedStart(
            .proxy, expected: workflow.revisions.proxy, conditionalDNS: conditionalDNS, restartsProxy: true, request: request,
            operation: operation
        )
    }

    /// A saved Start of one module, the app's menu, Overview and shortcut controls (decision 0037), and the Restart's own admission: the
    /// host's one Start path with no editor value, whose preparation captures the saved pair once. `expected` is the module's exact
    /// revision and `conditionalDNS` the DNS revision the client observed for the proxy's companion (decision 0036); each is checked as
    /// given in this one turn, so a moved one refuses the whole request before anything changes (decision 0035).
    private func fenceSavedStart(
        _ module: ControlModule,
        expected: Int,
        conditionalDNS: ControlLifecycleRevision?,
        restartsProxy: Bool,
        request: ControlRequestID,
        operation: ControlOperationID
    ) -> ControlOwnerFenceResult {
        // Decoding and encoding refuse a companion on any module but the proxy, so none reaches here.
        precondition(conditionalDNS == nil || module == .proxy, "only the proxy's Start has a DNS companion")
        var actions = PrivateModuleSlots<RuntimeModuleAction>(proxy: .none, dns: .none, tunnels: .none)
        var revisions = PrivateModuleSlots<Int?>(proxy: nil, dns: nil, tunnels: nil)
        actions[module] = .start
        revisions[module] = expected
        if let conditionalDNS {
            actions[.dns] = .conditionalActivation
            revisions[.dns] = conditionalDNS.rawValue
        }
        let name: LifecycleOperation = switch module {
        case .proxy: .proxyStart
        case .dns: .dnsStart
        case .tunnels: .tunnelsStart
        }
        switch admitModuleStart(actions, expecting: revisions, operation: name, restartsProxy: restartsProxy, requestID: request) {
        case .success(let admitted):
            controlAdmissions[operation] = .start(admitted, request: request)
            return .admitted
        case .failure(.stale):
            return .rejected(.staleRevision)
        case .failure(.terminated):
            return .rejected(.hostStopping)
        case .failure(.intentExhausted), .failure(.stopSaveOwed), .failure(.held), .failure(.notRunning), .failure(.superseded):
            return .rejected(.internalFailure)
        }
    }

    // MARK: Outcomes

    /// A Stop completed when its module is down, by its own teardown or one it joined. A module a newer Start took is not this Stop's.
    /// Its fence was established at admission either way. A session DNS Stop that attempted its disable save completes with that save's
    /// causal runtime write, so the client that holds the baseline it was conditional on can recognize the write as its own Stop's.
    private func controlOutcome(
        of stop: RuntimeModuleStopOutcome,
        module: ControlModule,
        dnsWrite: RuntimeConfigurationWorkflow.DNSStopWrite?
    ) -> ControlOperationOutcome {
        guard stop.stopped.contains(module) || modulesDown().contains(module) else { return .failed(.staleRevision) }
        guard let dnsWrite else { return completed(.stop) }
        do {
            let write = try ControlDNSDisableWrite(prior: dnsWrite.prior, runtime: try Self.componentWrite(dnsWrite.write))
            return completed(.stop, result: .dnsDisable(write))
        } catch {
            preconditionFailure("a disable write is built from the store's own consistent facts")
        }
    }

    /// The admin write's settlement: its platform write with the new baseline when it verified, or the store's closed capacity cause.
    private func launchAtLoginOutcome(_ write: ConfigurationWriteOutcome?) -> ControlOperationOutcome {
        guard let write else { return .failed(.storeBusy) }
        do {
            return completed(.setLaunchAtLogin, result: .platformWrite(try Self.componentWrite(write)))
        } catch {
            preconditionFailure("an admin settlement is built from the store's own consistent facts")
        }
    }

    /// A reload's answer on the wire, one case for one. The shared refusal and hold vocabulary goes through the bridge's own maps.
    static func reloadResult(_ decision: RuntimeReloadDecision) -> ControlReloadResult {
        switch decision {
        case .refused(let refusal):
            .refused(ControlConfigWorkflowRefusal(refusal))
        case .adopted(.superseded):
            .adopted(.superseded)
        case .adopted(.held(let input, let reason)):
            .adopted(.held(ControlConfigWorkflowHeldInput(input), ControlConfigWorkflowHoldReason(reason)))
        case .adopted(.reconcileAttempted(let currentAtEnd)):
            .adopted(.reconcileAttempted(currentAtEnd: currentAtEnd))
        }
    }

    /// The one completion path of every command: its result, cited at the revision that reflects the settlement.
    func completed(_ command: ControlRuntimeCommandKind, result: ControlCommandResult = .settled) -> ControlOperationOutcome {
        // The revision that reflects the settlement is the one this turn's snapshot carries. When none can be projected, the settlement
        // reserves the next one, which the first projection after it takes; the last body, from before the settlement, is never cited.
        // At the maximum no revision can reflect it, so it fails closed.
        if snapshot() == nil, !presentation.reserveUnprojected() {
            return .failed(.internalFailure)
        }
        guard let revision = ControlPresentationRevision(rawValue: presentation.revision) else {
            preconditionFailure("a presentation revision is never negative")
        }
        do {
            return .completed(try ControlCompletion(command: command, presentationRevision: revision, result: result))
        } catch {
            preconditionFailure("a command settles with its own result kind")
        }
    }

    /// The app's Test DNS probe of `port`, run as the host's own DNS health timer runs its probe: through the injected probe on a
    /// global queue, never on `platformWork`, so a probe waiting out its timeout cannot hold a Stop's or a quit's teardown there. One
    /// physical probe runs at a time. A request for the latest probe's port joins it, and one for another port runs after it, so each
    /// answer is for the port its request chose and the probes waiting are bounded by the service's ordinary capacity.
    private func dnsLiveness(port: Int) -> Task<Bool, Never> {
        if let latest = dnsLivenessProbe, latest.port == port { return latest.answer }
        let previous = dnsLivenessProbe?.answer
        let identity = UUID()
        let manager = systemDNSManager
        let answer = Task { [weak self] in
            _ = await previous?.value
            let answered = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: manager.probeLiveness(port: port)) }
            }
            if self?.dnsLivenessProbe?.identity == identity { self?.dnsLivenessProbe = nil }
            return answered
        }
        dnsLivenessProbe = (port, identity, answer)
        return answer
    }

    /// The service's fault as the recorded domain value: one case for one, with no default, so a new site fails to compile here.
    private static func recordedFault(_ fault: ControlServiceFault) -> RuntimeServiceFault {
        switch fault {
        case .submitCommandNotEncodable: .submitCommandNotEncodable
        case .outcomeNotEncodable: .outcomeNotEncodable
        case .projectionNotEncodable: .projectionNotEncodable
        case .projectionCountMismatch: .projectionCountMismatch
        case .snapshotIncarnationMismatch: .snapshotIncarnationMismatch
        case .revisionTotalChanged: .revisionTotalChanged
        case .collectionAccountingMismatch: .collectionAccountingMismatch
        case .quiescenceAccountingMismatch: .quiescenceAccountingMismatch
        case .snapshotNotEncodable: .snapshotNotEncodable
        case .snapshotOverBound: .snapshotOverBound
        case .snapshotRevisionConflict: .snapshotRevisionConflict
        case .snapshotRevisionRegressed: .snapshotRevisionRegressed
        }
    }
}

extension RuntimeHost {
    /// The production in-memory composition over this host, handed out only as the client a caller holds (decisions 0014 and 0033): the
    /// actual service, transport, clock and owner hops, with no concrete service or transport exposed. The caller passes every bound; no
    /// shipping profile is selected. The client keeps the composition alive. One per host.
    package func makeInMemoryControlClient(
        limits: RuntimeServiceLimits,
        clientFrameLimits: ControlFrameLimits,
        wireBudgetCap: Duration
    ) throws -> RuntimeInMemoryClients {
        let composition = RuntimeControlComposition(host: self, limits: limits, timing: .system, scheduling: TaskOwnerScheduling())
        let clients: RuntimeInMemoryClients
        do {
            clients = RuntimeInMemoryClients(
                control: try makeFramedRuntimeClient(transport: composition.transport, limits: clientFrameLimits, wireBudgetCap: wireBudgetCap),
                editor: PrivateEditorClient(transport: composition.transport)
            )
        } catch {
            // No client holds the composition, so the host is left with none: every connection the composition made is undone.
            detachControlObservation()
            throw error
        }
        return clients
    }

    /// Composes the diagnostics log's one sink with the control stream (decision 0014). Every event the host records reaches its file writer
    /// exactly once, as before, and then the service's bounded leaf ingress, from whatever thread recorded it: an event that cannot be
    /// retained there is a loss marker, which a subscriber reads as a resync. The service is held weakly and the host not at all, so the
    /// sink keeps no composition or host alive. An event recorded before this call was written to the file only; the stream begins here.
    func attachControlStream(_ service: RuntimeServiceCore) {
        orchestrator.eventLog.setSink { [eventWriter, weak service] event in
            eventWriter.record(event)
            service?.ingest(ControlRuntimeEvent(event))
        }
    }

    /// Undoes a composition no client came to hold: no state, event or shutdown callback is left, and the file writer records alone again.
    func detachControlObservation() {
        onControlStateChange = nil
        onControlShutdown = nil
        orchestrator.eventLog.setSink { [eventWriter] event in eventWriter.record(event) }
    }
}

/// The two clients of one in-memory composition: the ordinary framed client and the private editor client, over the same service, transport
/// and private custody.
package struct RuntimeInMemoryClients: Sendable {
    package let control: any RuntimeClient
    package let editor: PrivateEditorClient
}

/// The control service composed over one host, and its in-memory transport (decision 0014). The caller supplies every bound and the
/// clock: no production profile is selected, so a test or a scenario passes its own explicit one. One service per host.
@MainActor
struct RuntimeControlComposition {
    let service: RuntimeServiceCore
    let transport: RuntimeInMemoryTransport
    /// The composition's one private custody, shared by every transport it builds (decisions 0021 and 0034).
    let privateCustody: RuntimePrivateCustody

    init(
        host: RuntimeHost,
        limits: RuntimeServiceLimits,
        timing: RuntimeServiceTiming,
        scheduling: any RuntimeOwnerScheduling
    ) {
        precondition(host.onControlStateChange == nil, "one control service per host")
        let service = RuntimeServiceCore(
            owner: host,
            limits: limits,
            timing: timing,
            scheduling: scheduling,
            makeOperationID: { ControlOperationID(rawValue: UUID()) }
        )
        self.service = service
        let custody = RuntimePrivateCustody(limits: limits)
        privateCustody = custody
        transport = RuntimeInMemoryTransport(
            core: service, limits: limits, timing: timing, scheduling: scheduling,
            privateChannel: RuntimePrivateChannel(custody: custody, owner: host)
        )
        // The host's whole observation is bound here, together, for every composition (decision 0014): its safe state, every event it
        // records, beside its file writer, and the quit's end, which ends every stream after what was published. Weak throughout: the
        // service holds the host as its owner, so the host must not keep the service alive.
        host.onControlStateChange = { [weak service] in service?.ownerDidChange() }
        host.onControlShutdown = { [weak service] in service?.hostDidShutDown() }
        host.attachControlStream(service)
        // A host whose quit already ended has no later end to report, so the service starts shut down.
        if host.quitEnded {
            service.hostDidShutDown()
        }
    }
}
