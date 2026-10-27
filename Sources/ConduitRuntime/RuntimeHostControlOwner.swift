// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel

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
    case restart(RuntimeAdmittedStart)
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
    /// (`configGeneration`) as the config revision and the whole-host lifecycle counter as the lifecycle revision. Collections report no
    /// captured revision, so their counts are exact and their rows unavailable as `not_captured`. Nil, with its event, when the projection
    /// fails.
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
        let kernel = orchestrator.snapshot
        let projected: ControlRuntimeSnapshot
        do {
            projected = try RuntimeSnapshotControlProjection.snapshot(
                kernel, stamp: stamp, profileName: config.profileName, collectionRevisions: collections.revisions(of: kernel)
            )
        } catch {
            // The projection names no value in its error, and none is kept. The read that asked fails closed.
            return snapshotUnavailable("projection_failed")
        }
        guard let stamped = presentation.stamp(projected) else { return snapshotUnavailable("revision_exhausted") }
        return stamped
    }

    /// The closed failure of a snapshot read, recorded once per failure episode so a persistent failure cannot flood the bounded event log.
    private func snapshotUnavailable(_ reason: StaticString) -> ControlRuntimeSnapshot? {
        if presentation.projectionFailed() {
            recordLifecycle(RuntimeEvent(kind: .health, event: "runtime_service.snapshot_unavailable", detail: "reason=\(reason)"),
                            level: .warning)
        }
        return nil
    }

    func projectedRows(for kind: ControlCollectionKind, within budget: ControlRowBudget) -> ControlProjection {
        RuntimeSnapshotControlProjection.projectRows(kind, from: orchestrator.snapshot, within: budget)
    }

    func serviceFault(_ fault: ControlServiceFault) {
        recordLifecycle(RuntimeEvent(kind: .health, event: "runtime_service.fault", detail: "fault=\(Self.faultName(fault))"),
                        level: .warning)
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
        case .restart(.proxy, let expected, let companion):
            return fenceProxyRestart(expected, conditionalDNS: companion, request: request, operation: operation)
        case .restart(.dns, _, _), .restart(.tunnels, _, _), .testDNS, .testUpstream, .refreshPreflight:
            // Not adopted on this owner yet; each is refused whole before anything changes.
            return .rejected(.notImplemented)
        }
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
            Task { @MainActor [self] in
                let outcome = await runAdmittedStop(stop)
                report.settled(controlOutcome(of: outcome, module: module))
                report.quiesced()
                onControlStateChange?()
            }
        case .restart(let start):
            Task { @MainActor [self] in
                let outcome: ControlOperationOutcome
                do {
                    outcome = controlOutcome(of: try await runAdmittedStart(start))
                } catch let refusal as RuntimeStartRefusal {
                    outcome = .failed(Self.failure(of: refusal))
                } catch {
                    // The proxy listener's own start failure surfaces as the member's typed `failed` settlement before it is thrown.
                    outcome = .failed(.effectFailed)
                }
                report.settled(outcome)
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
        // Decoding refused a companion on any other module, so only the proxy reaches here with one.
        let proxyRevision = workflow.revisions.proxy
        switch admitModuleStart(
            PrivateModuleSlots(proxy: .start, dns: conditionalDNS == nil ? .none : .conditionalActivation, tunnels: .none),
            expecting: PrivateModuleSlots(proxy: proxyRevision, dns: conditionalDNS?.rawValue, tunnels: nil),
            operation: .proxyStart,
            restartsProxy: true,
            requestID: request
        ) {
        case .success(let admitted):
            controlAdmissions[operation] = .restart(admitted)
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
    /// Its fence was established at admission either way, and a DNS disable save's own result is its typed `config.workflow` event.
    private func controlOutcome(of stop: RuntimeModuleStopOutcome, module: ControlModule) -> ControlOperationOutcome {
        guard stop.stopped.contains(module) || modulesDown().contains(module) else { return .failed(.staleRevision) }
        return completed(.stop)
    }

    /// A Restart's proxy member result. Its typed `lifecycle.module_settled` carries the same value.
    private func controlOutcome(of start: RuntimeModuleStartOutcome) -> ControlOperationOutcome {
        switch start.modules.proxy {
        case .started?: completed(.restart)
        case .failed?: .failed(.effectFailed)
        case .superseded?: .failed(.staleRevision)
        case .notConfigured?, nil: .failed(.internalFailure)
        }
    }

    private func completed(_ command: ControlRuntimeCommandKind) -> ControlOperationOutcome {
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
            return .completed(try ControlCompletion(command: command, presentationRevision: revision, result: .settled))
        } catch {
            preconditionFailure("a lifecycle command settles with no payload")
        }
    }

    private static func failure(of refusal: RuntimeStartRefusal) -> ControlFailureCode {
        switch refusal {
        case .superseded, .terminated, .stale: .staleRevision
        case .held, .notRunning: .effectFailed
        case .intentExhausted, .stopSaveOwed: .internalFailure
        }
    }

    private static func faultName(_ fault: ControlServiceFault) -> String {
        switch fault {
        case .submitCommandNotEncodable: "submit_command_not_encodable"
        case .outcomeNotEncodable: "outcome_not_encodable"
        case .projectionNotEncodable: "projection_not_encodable"
        case .projectionCountMismatch: "projection_count_mismatch"
        case .snapshotIncarnationMismatch: "snapshot_incarnation_mismatch"
        case .revisionTotalChanged: "revision_total_changed"
        case .collectionAccountingMismatch: "collection_accounting_mismatch"
        case .quiescenceAccountingMismatch: "quiescence_accounting_mismatch"
        case .snapshotNotEncodable: "snapshot_not_encodable"
        case .snapshotOverBound: "snapshot_over_bound"
        case .snapshotRevisionConflict: "snapshot_revision_conflict"
        case .snapshotRevisionRegressed: "snapshot_revision_regressed"
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
    ) throws -> any RuntimeClient {
        let composition = RuntimeControlComposition(host: self, limits: limits, timing: .system, scheduling: TaskOwnerScheduling())
        do {
            return try makeFramedRuntimeClient(transport: composition.transport, limits: clientFrameLimits, wireBudgetCap: wireBudgetCap)
        } catch {
            // No client holds the composition, so the host is left with none.
            onControlStateChange = nil
            throw error
        }
    }
}

/// The control service composed over one host, and its in-memory transport (decision 0014). The caller supplies every bound and the
/// clock: no production profile is selected, so a test or a scenario passes its own explicit one. One service per host.
@MainActor
struct RuntimeControlComposition {
    let service: RuntimeServiceCore
    let transport: RuntimeInMemoryTransport

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
        transport = RuntimeInMemoryTransport(core: service, limits: limits, timing: timing, scheduling: scheduling)
        // Weak: the service holds the host as its owner, so the host must not keep the service alive.
        host.onControlStateChange = { [weak service] in service?.ownerDidChange() }
    }
}
