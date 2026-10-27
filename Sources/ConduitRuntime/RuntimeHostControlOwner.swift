// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel

/// The presentation revision of the host's control snapshots, and the last snapshot stamped with it. The revision moves only when a
/// projection differs from the last one, so the service's slot never sees two bodies under one revision. It holds one snapshot, replaced
/// in place, and no history.
struct RuntimeHostPresentation {
    private(set) var revision = 0
    private(set) var last: ControlRuntimeSnapshot?

    /// `projected` is stamped with the current revision. An equal projection answers the last snapshot; a different one takes the next
    /// revision. At the maximum no newer revision exists, so the projection keeps the current one and the service refuses it as a
    /// revision conflict, a closed fault, rather than this host reusing an older revision.
    mutating func stamp(_ projected: ControlRuntimeSnapshot) -> ControlRuntimeSnapshot {
        if let last, last == projected { return last }
        var stamped = projected
        if last != nil, revision < Int.max, let next = ControlPresentationRevision(rawValue: revision + 1) {
            revision += 1
            stamped.stamp.presentationRevision = next
        }
        last = stamped
        return stamped
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
        guard let lifecycle = ControlLifecycleRevision(rawValue: workflow.generation),
              let configRevision = ControlConfigRevision(rawValue: configGeneration),
              let current = ControlPresentationRevision(rawValue: presentation.revision)
        else {
            preconditionFailure("the host's counters are never negative")
        }
        let stamp = ControlRuntimeStamp(
            incarnation: incarnation, presentationRevision: current, configRevision: configRevision, lifecycleRevision: lifecycle
        )
        do {
            let projected = try RuntimeSnapshotControlProjection.snapshot(
                orchestrator.snapshot, stamp: stamp, profileName: config.profileName, collectionRevisions: ControlCollectionRevisions()
            )
            return presentation.stamp(projected)
        } catch {
            // The projection names no value in its error, and none is kept. The read that asked fails closed.
            recordLifecycle(RuntimeEvent(kind: .health, event: "runtime_service.snapshot_unavailable", detail: "reason=projection_failed"),
                            level: .warning)
            return nil
        }
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
        case .restart(.proxy, let expected):
            return fenceProxyRestart(expected, request: request, operation: operation)
        case .restart(.dns, _), .restart(.tunnels, _), .testDNS, .testUpstream, .refreshPreflight:
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

    /// The ordinary menu Restart of the proxy (decision 0036), with no companion: the request names no DNS revision, so none is derived.
    /// `ifLifecycleRevision` is the whole-host lifecycle counter the client read in a snapshot stamp. When it still matches, in this same
    /// turn no module's revision has moved, so the proxy's own revision is taken here as its exact precondition; that is the only
    /// derivation made. A moved counter refuses the whole request before anything changes (decision 0035).
    private func fenceProxyRestart(
        _ expected: ControlLifecycleRevision,
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
        let proxyRevision = workflow.revisions.proxy
        switch admitModuleStart(
            PrivateModuleSlots(proxy: .start, dns: .none, tunnels: .none),
            expecting: PrivateModuleSlots(proxy: proxyRevision, dns: nil, tunnels: nil),
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
        // The revision that reflects the settlement is the one this turn's snapshot carries.
        _ = snapshot()
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
