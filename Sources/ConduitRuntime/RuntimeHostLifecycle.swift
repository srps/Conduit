// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel
import RuntimeEvents

// MARK: - Module lifecycle results

/// What one explicit member of a module Start came to (decisions 0035 and 0036): the same closed value its `lifecycle.module_settled`
/// record carries, so the returned result and the event cannot drift.
package typealias RuntimeModuleStartResult = LifecycleModuleStartResult

/// The separate closed result of a proxy Start's conditional DNS companion (decision 0036), the value its own `lifecycle.module_settled`
/// record carries.
package typealias RuntimeConditionalDNSResult = LifecycleConditionalDNSResult

/// What a module Start that ran came to: each member's result, and the companion's when one was asked for. A Start refused at
/// admission, held at preparation or ended before any member completed throws `RuntimeStartRefusal` instead.
package struct RuntimeModuleStartOutcome: Equatable, Sendable {
    /// Each explicit member's result; nil for a module the request did not start.
    package var modules: PrivateModuleSlots<RuntimeModuleStartResult?>
    /// The companion's result, nil when the request asked for none.
    package var conditionalDNS: RuntimeConditionalDNSResult?
}

/// What a session DNS Stop's disable save came to (decision 0015).
package enum RuntimeDNSStopSave: Equatable, Sendable {
    /// The disable verified, and the obligation ended.
    case saved
    /// The store's slot was taken, the write did not verify, or a pending explicit DNS Start carries the obligation, so the disable stays
    /// owed. Nothing retries it.
    case owed
    /// Nothing is owed any more: a newer DNS Start replaced the obligation, or another save already verified it.
    case notOwed
}

/// What a module Stop did. Its fence was established at admission whatever this reports.
package struct RuntimeModuleStopOutcome: Equatable, Sendable {
    /// The modules whose teardown this Stop, or the identical Stop it joined, ran to its end. A module a newer Start or Stop took over is
    /// that owner's and is not listed.
    package var stopped: Set<ControlModule>
    /// The disable save of a session Stop of DNS, else nil.
    package var dnsSave: RuntimeDNSStopSave?
}

/// One Start admitted in its synchronous turn and not yet run (`RuntimeHost.admitModuleStart`). It carries no configuration value: its
/// preparation captures the saved pair later (decision 0037).
struct RuntimeAdmittedStart: Sendable {
    let ticket: RuntimeConfigurationWorkflow.StartTicket
    let actions: PrivateModuleSlots<RuntimeModuleAction>
    let operation: LifecycleOperation
    let restartsProxy: Bool
    /// An editor request's frozen candidate, committed in place of the saved capture through the same preparation.
    var frozen: RuntimeConfigurationWorkflow.FrozenInput?
    /// Where the preparation leaves its commit facts, for the request's receipt.
    let facts = RuntimeCommitFacts()
}

/// The facts one Start produced for its request's receipt: its commit result and the DNS bit it staged, empty until a commit ran, and each
/// member's result as its lane effect recorded it (the same value its `lifecycle.module_settled` carries), empty until it took lanes.
@MainActor
final class RuntimeCommitFacts: Sendable {
    var commit: RuntimePlatformCommitResult?
    var dnsStaged: Bool?
    var members: PrivateModuleSlots<RuntimeModuleStartResult?>?

    nonisolated init() {}
}

/// One Stop fenced in its synchronous turn and not yet run (`RuntimeHost.admitModuleStop`).
struct RuntimeAdmittedStop: Sendable {
    let modules: Set<ControlModule>
    let reason: RuntimeStopReason
    /// The counter value the Stop's fence took. Its teardown acts only on a module still at it.
    let revision: Int
    let requestID: ControlRequestID?
}

// MARK: - Lane effect

/// One lifecycle operation holding the lanes of its scope, one token per module (decision 0031). Every surface block checks the token of
/// the module it touches, so a newer operation on one module stops this one's work on that module only. For a Start, `prepared` is the
/// authorizing prepared Start: the workflow group in it is the control authority, and an identical Start that joins takes it over with
/// `adopt` while the effect has not settled its members.
@MainActor
final class RuntimeLifecycleEffect {
    /// What an operation asks beyond its scope. Two operations coalesce only when this, their scope and their operation are equal, and a
    /// Start only when it also captured the same verified pair.
    enum Request: Equatable {
        case start(PrivateModuleSlots<RuntimeModuleAction>, restartsProxy: Bool)
        /// A proxy Start's DNS companion, which never coalesces.
        case conditional
        case stop(RuntimeStopReason)
    }

    let operation: LifecycleOperation
    let request: Request
    let scope: Set<ControlModule>
    let tokens: PrivateModuleSlots<LifecycleLane.Token?>
    /// The modules this effect started from down, or took from an operation still in flight. A held or failed Start tears down only these,
    /// never a module that was already running (decision 0035).
    var owned: Set<ControlModule>
    /// The modules whose lane was busy when this effect took it: an operation in flight was overtaken, and what it left unfinished is this
    /// effect's. Fixed at acquisition, unlike `owned`, which also names modules that were simply down.
    let inherited: Set<ControlModule>
    private(set) var prepared: RuntimeConfigurationWorkflow.PreparedStart?
    /// The explicit members still going on under their group.
    var active: Set<ControlModule>
    var results = PrivateModuleSlots<RuntimeModuleStartResult?>(proxy: nil, dns: nil, tunnels: nil)
    var conditionalDNS: RuntimeConditionalDNSResult?
    /// The modules a Stop's teardown ran to its end, for a joiner.
    var stopped: Set<ControlModule> = []
    /// Set once the members settled, so a later identical Start is not adopted into an effect that can settle it no more.
    var completed = false
    /// Set once it lost its authority, so no identical Start is adopted into a teardown.
    var withdrawn = false
    /// One `lifecycle.superseded` per effect.
    var supersessionRecorded = false

    init(
        operation: LifecycleOperation,
        request: Request,
        scope: Set<ControlModule>,
        tokens: PrivateModuleSlots<LifecycleLane.Token?>,
        owned: Set<ControlModule>,
        inherited: Set<ControlModule>,
        prepared: RuntimeConfigurationWorkflow.PreparedStart?
    ) {
        self.operation = operation
        self.request = request
        self.scope = scope
        self.tokens = tokens
        self.owned = owned
        self.inherited = inherited
        self.prepared = prepared
        if case .start(let actions, _) = request {
            active = Set(ControlModule.allCases.filter { actions[$0] == .start || actions[$0] == .configuredStart })
        } else {
            active = []
        }
    }

    /// The first module of the scope, whose lane a joiner waits on: the effect ends every lane in one turn.
    var lead: ControlModule {
        guard let lead = ControlModule.allCases.first(where: scope.contains) else { preconditionFailure("an effect has a scope") }
        return lead
    }

    func token(_ module: ControlModule) -> LifecycleLane.Token {
        guard let token = tokens[module] else { preconditionFailure("an effect acts only on the lanes it holds") }
        return token
    }

    var ticket: RuntimeConfigurationWorkflow.StartTicket {
        guard let prepared else { preconditionFailure("only a Start effect has a ticket") }
        return prepared.ticket
    }

    var actions: PrivateModuleSlots<RuntimeModuleAction> {
        if case .start(let actions, _) = request { return actions }
        return PrivateModuleSlots(proxy: .none, dns: .none, tunnels: .none)
    }

    var restartsProxy: Bool {
        if case .start(_, let restarts) = request { return restarts }
        return false
    }

    var outcome: RuntimeModuleStartOutcome {
        RuntimeModuleStartOutcome(modules: results, conditionalDNS: conditionalDNS)
    }

    /// A joining Start's authorized group takes this effect over when it captured the same pair, before the effect settled any member or
    /// withdrew. A member already settled under the earlier group, a failed one above all, could never settle the joiner's grant for it, so
    /// such a joiner runs its own lanes instead.
    func adopt(_ joining: RuntimeConfigurationWorkflow.PreparedStart) -> Bool {
        guard !completed, !withdrawn, ControlModule.allCases.allSatisfy({ results[$0] == nil }),
              let current = prepared, joining.input.isSamePair(as: current.input) else { return false }
        prepared = joining
        return true
    }
}

// MARK: - Shared lifecycle

extension RuntimeHost {
    static let allModules = Set(ControlModule.allCases)

    /// The modules not running now: no proxy listener, no DNS forwarder, no tunnel bound.
    func modulesDown() -> Set<ControlModule> {
        let state = runtimeState()
        var down: Set<ControlModule> = []
        if !state.proxyIsUp { down.insert(.proxy) }
        if !state.dnsIsUp { down.insert(.dns) }
        if orchestrator.snapshot.bindings.tunnels.isEmpty { down.insert(.tunnels) }
        return down
    }

    enum LaneAdmission {
        case run(RuntimeLifecycleEffect)
        /// An identical effect holds every lane of the scope; `join` it.
        case join(RuntimeLifecycleEffect)
    }

    /// Takes the lanes of `scope` in one turn, or names the identical effect that holds them all. Never suspends. Any admission makes a
    /// pending settle stale.
    func beginLanes(
        _ scope: Set<ControlModule>,
        kind: LifecycleLane.Kind,
        operation: LifecycleOperation,
        request: RuntimeLifecycleEffect.Request,
        prepared: RuntimeConfigurationWorkflow.PreparedStart?,
        coalescing: Bool
    ) -> LaneAdmission {
        let ordered = ControlModule.allCases.filter(scope.contains)
        guard let lead = ordered.first else { preconditionFailure("an operation takes at least one lane") }
        stoppedEffectsJoin?.finish(.superseded)
        if coalescing, let running = laneEffects[lead], running.scope == scope, running.operation == operation,
           running.request == request, ordered.allSatisfy({ laneEffects[$0] === running }),
           prepared.map({ running.adopt($0) }) ?? !running.withdrawn {
            return .join(running)
        }
        // A module whose lane is busy is in motion, so a Start that takes its lane owns it (decision 0035).
        let busy = Set(ordered.filter { !lanes[$0].isIdle })
        let down = modulesDown()
        var tokens = PrivateModuleSlots<LifecycleLane.Token?>(proxy: nil, dns: nil, tunnels: nil)
        for module in ordered {
            guard case .run(let token) = lanes[module].begin(kind, coalescing: false) else {
                preconditionFailure("an uncoalesced begin always runs")
            }
            tokens[module] = token
        }
        let effect = RuntimeLifecycleEffect(
            operation: operation, request: request, scope: scope, tokens: tokens,
            owned: scope.filter { busy.contains($0) || down.contains($0) }, inherited: busy, prepared: prepared
        )
        for module in ordered { laneEffects[module] = effect }
        return .run(effect)
    }

    /// Waits for the identical effect `beginLanes` named, right after it, with no suspension between. It ends all its lanes in one turn.
    func join(_ running: RuntimeLifecycleEffect, operation: LifecycleOperation) async {
        recordLifecycle(lanes[running.lead].coalescedEvent(operation: operation, joining: running.token(running.lead).generation))
        await lanes[running.lead].join(running.token(running.lead).generation)
    }

    /// Ends every lane the effect holds, in one turn.
    func endLanes(_ effect: RuntimeLifecycleEffect) {
        for module in ControlModule.allCases where effect.scope.contains(module) {
            lanes[module].end(effect.token(module))
            if laneEffects[module] === effect { laneEffects[module] = nil }
        }
    }

    /// Whether the effect still holds `module`'s lane. Once it does not, a newer Start or Stop of the module owns it, and the effect says so
    /// with one `lifecycle.superseded` (twin of `AppState.isCurrent`).
    func holdsLane(_ effect: RuntimeLifecycleEffect, _ module: ControlModule) -> Bool {
        let token = effect.token(module)
        guard token.isSuperseded else { return true }
        if !effect.supersessionRecorded {
            effect.supersessionRecorded = true
            recordLifecycle(lanes[module].supersededEvent(operation: effect.operation, token: token))
        }
        return false
    }

    /// Settles one explicit member, once, and records its `lifecycle.module_settled` before any log line about it; the log is derived from
    /// the event, at warning for a failure. A joiner settles nothing itself: the effect it joined records each member once, under the group
    /// that adopted it.
    private func settle(_ start: RuntimeLifecycleEffect, _ module: ControlModule, _ result: RuntimeModuleStartResult) {
        precondition(start.results[module] == nil, "a member settles once")
        start.results[module] = result
        recordSettlement(.explicit(LifecycleModule(module), result), of: start)
    }

    /// Records a settlement under the Start's current group. Only a failure is a warning.
    private func recordSettlement(_ settlement: LifecycleModuleSettlement, of start: RuntimeLifecycleEffect) {
        let level: LogLevel = switch settlement {
        case .explicit(_, .failed), .conditionalDNS(.failed): .warning
        case .explicit, .conditionalDNS: .notice
        }
        recordLifecycle(
            RuntimeEvent(payload: .lifecycle(.moduleSettled(LifecycleModuleSettled(settlement: settlement, group: start.ticket.generation)))),
            level: level
        )
    }

    /// The runtime's observers follow the modules that are up: started by any Start that brought one up, stopped once none is left.
    func startObservers() {
        startLocationObserver()
        networkPathObserver.start()
        vpnStatusMonitor.start()
    }

    // MARK: Start

    /// The one Start path every entry composes (decisions 0035, 0036 and 0037). The request is admitted whole in one turn, with every
    /// revision it names checked before anything changes, before launch recovery is awaited, so a Stop during recovery is never queued
    /// behind it. Its preparation captures the saved pair once inside the store's capacity and verifies it; the pair is pushed through the
    /// one reconciler and authorizes the members only once adopted. Then the members' lanes are taken, or the identical effect holding them
    /// is joined when it captured the same pair. Throws a typed refusal for a Start refused, held or ended before any member completed.
    func runStart(
        _ actions: PrivateModuleSlots<RuntimeModuleAction>,
        expecting revisions: PrivateModuleSlots<Int?>,
        operation: LifecycleOperation,
        restartsProxy: Bool
    ) async throws -> RuntimeModuleStartOutcome {
        let admitted = try admitModuleStart(actions, expecting: revisions, operation: operation, restartsProxy: restartsProxy).get()
        return try await runAdmittedStart(admitted)
    }

    /// The synchronous half of `runStart`: the whole request is admitted, or refused with its typed event, in this one turn, before
    /// anything suspends. A refusal changes nothing. An admission is pending work from here until `runAdmittedStart` returns, so a settle
    /// sees it, and the caller must run it. `requestID` is the client request it follows, nil for the host's own facade.
    func admitModuleStart(
        _ actions: PrivateModuleSlots<RuntimeModuleAction>,
        expecting revisions: PrivateModuleSlots<Int?>,
        operation: LifecycleOperation,
        restartsProxy: Bool,
        requestID: ControlRequestID? = nil
    ) -> Result<RuntimeAdmittedStart, RuntimeStartRefusal> {
        guard !workflow.isTerminal else {
            emitConfigurationEvents(workflow.terminalRefusal())
            return .failure(.terminated)
        }
        switch workflow.admitStart(actions, expecting: revisions, requestID: requestID) {
        case .success(let ticket):
            pendingAdmissions += 1
            // Any admission makes a pending settle stale, whether or not it has reached a lane yet.
            stoppedEffectsJoin?.finish(.superseded)
            return .success(RuntimeAdmittedStart(ticket: ticket, actions: actions, operation: operation, restartsProxy: restartsProxy))
        case .failure(let refusal):
            emitConfigurationEvents(workflow.admissionEvents(refusal))
            return .failure(refusal)
        }
    }

    /// The asynchronous half of `runStart`, for one admission `admitModuleStart` made. It runs once per admission.
    func runAdmittedStart(_ admitted: RuntimeAdmittedStart) async throws -> RuntimeModuleStartOutcome {
        defer { pendingAdmissions -= 1 }
        let ticket = admitted.ticket
        let actions = admitted.actions
        let operation = admitted.operation
        let restartsProxy = admitted.restartsProxy
        await awaitLaunchRecovery()
        let preparation = await workflow.prepareStart(ticket, frozen: admitted.frozen)
        admitted.facts.commit = preparation.commit
        admitted.facts.dnsStaged = preparation.dnsStaged
        emitConfigurationEvents(preparation.events)
        let prepared: RuntimeConfigurationWorkflow.PreparedStart
        switch preparation.preparation {
        case .superseded:
            workflow.retire(ticket)
            throw RuntimeStartRefusal.superseded
        case .held:
            workflow.retire(ticket)
            throw RuntimeStartRefusal.held
        case .ready(let ready):
            prepared = ready
        }
        // A `true` answer authorized the admission, with no suspension since its last check.
        guard await pushVerifiedInput(prepared) else {
            // The cause is read before the retire, which empties the group it inspects.
            let events = workflow.supersession(of: prepared.ticket)
            workflow.retire(prepared.ticket)
            emitConfigurationEvents(events)
            throw RuntimeStartRefusal.superseded
        }
        logNonBlockingConfigProblems()
        let members = Set(ControlModule.allCases.filter { actions[$0] == .start || actions[$0] == .configuredStart })
        switch beginLanes(members, kind: .start, operation: operation, request: .start(actions, restartsProxy: restartsProxy),
                          prepared: prepared, coalescing: true) {
        case .join(let running):
            // This call's admission ended the running Start's group, and its own authorized group adopted the effect in the same turn, so
            // the effect settles this group with what it does.
            await join(running, operation: operation)
            admitted.facts.members = running.results
            guard running.completed else { throw RuntimeStartRefusal.notRunning }
            return running.outcome
        case .run(let start):
            // On every exit, after any finalization: the members' recorded settlements, not a value derived from the error.
            defer {
                admitted.facts.members = start.results
                endLanes(start)
            }
            do {
                return try await runStartEffect(start)
            } catch {
                await holdRemaining(start)
                throw error
            }
        }
    }

    /// The one finalization of a Start that cannot complete whole, every throw exit included (decision 0035). First its members not yet
    /// settled record their `superseded` settlement and end as failed under its own ticket, before anything suspends, which restores each
    /// one's prior permission and fence: no grant is left for a module it did not finish, and a reload pass admitted under it stops. A
    /// member a newer Start or Stop already took, or one that settled alone, has no record under this ticket and is untouched, and
    /// completed saves stay facts. Then the modules it owns are torn down under its own tokens: a lane a newer owner took is skipped, and a
    /// module that was already running when it took the lanes is never touched.
    private func holdRemaining(_ start: RuntimeLifecycleEffect) async {
        guard !start.completed else { return }
        start.withdrawn = true
        for module in ControlModule.allCases where start.active.contains(module) && start.results[module] == nil {
            settle(start, module, .superseded)
        }
        start.active = []
        workflow.endFailedStart(start.ticket)
        await tearDown(start.owned, under: start, terminal: false)
    }

    /// The members' physical start, in the order it always ran: the proxy listener and its surfaces (`applyProxySurfaces`), then the DNS
    /// module (`startDNSModule`), then tunnels, each step on `platformWork` off the main actor (#47). Every suspension is followed by
    /// `continueStart`, and every manager step checks its module's token under the manager's lock (`LifecycleLane`). The members settle
    /// together once all completed; then a requested companion runs on its own DNS lane with its own closed result.
    private func runStartEffect(_ start: RuntimeLifecycleEffect) async throws -> RuntimeModuleStartOutcome {
        if start.scope.contains(.proxy) {
            if start.restartsProxy, runtimeState().proxyIsUp {
                // A restart stops the running listener and its surfaces first, under its own proxy token. The proxy it brings back up is
                // then this Start's, to clear if it holds.
                start.owned.insert(.proxy)
                await tearDown([.proxy], under: start, terminal: false)
                try continueStart(start)
            }
            do {
                try await startProxyListener()
                credentialWarmup = credentialManager.warmCacheInBackground(
                    eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }
                )
            } catch {
                // A start that a stop or a newer start superseded has nothing to revert: that owner cleaned up, and reverting here would
                // undo its work.
                guard holdsLane(start, .proxy) else { throw RuntimeStartRefusal.superseded }
                // The typed failure comes first. The error text stays on the log line below and never enters the event.
                settle(start, .proxy, .failed)
                // Restore owned surfaces after bind failure: a dead PAC/proxy endpoint or resolver can break networking after this process
                // exits.
                logger.log(
                    .warning,
                    "Runtime start failed (\(error.displayDescription)) — reverting system proxy, environment and DNS resolver settings so they cannot point at listeners that are not running.",
                    category: .system
                )
                // `holdRemaining` ends the failed intent before anything suspends, so a reload pass admitted under it does nothing. No
                // Stop is recorded: nothing fences a newer Start. The revert runs under this start's own tokens and waits only for effects
                // already running, never for a queued pass, which waits for these lanes. A proxy that failed to bind is down whatever it
                // was before, so its surfaces are this Start's to clear.
                start.owned.insert(.proxy)
                throw error
            }
            // A stop issued while the listeners came up has already queued its clears; applying now would put the surfaces back after them.
            try continueStart(start)
            // The runtime input is the one the push just reported held. The platform flags are this start's verified intent.
            try await applyProxySurfaces(start, config: heldRuntimeConfig, platform: platformConfig)
            runtimeStarted = true
        }
        let config = heldRuntimeConfig
        let platform = platformConfig
        // A member whose verified pair names nothing to start settles as its Start grants and reports that it started nothing.
        var unconfigured: Set<ControlModule> = []
        // A member running on an idle lane when this Start took it settles without a second physical start: the push already applied the
        // verified pair to it. One it owns, taken from a Stop or Start in flight, runs the physical start: a Stop may have restored its
        // surfaces, and the kernel orders the bind after a Stop's close or joins the start in flight for its real completion.
        if start.active.contains(.dns) {
            if !config.dnsForwarderEnabled {
                await leaveDNSUnconfigured(start, into: &unconfigured)
            } else if !start.owned.contains(.dns), orchestrator.snapshot.dnsRunState == .running {
                // Running from the pushed pair already.
            } else if await startDNSModule(start, config: config, platform: platform, stands: {
                workflow.holds(.dns, for: start.ticket) && start.prepared.map { workflow.holdsInput($0) } == true
            }) == .failed, holdsLane(start, .dns) {
                // A DNS member whose forwarder did not come up fails alone, with its prior permission and fence back; the others go on.
                workflow.endFailedStart(start.ticket, modules: [.dns])
                start.active.remove(.dns)
                settle(start, .dns, .failed)
            }
            // A member that failed alone has settled; only members still going on are checked.
            if !start.active.isEmpty { try continueStart(start) }
        }
        if start.active.contains(.tunnels) {
            let tunnelsState = orchestrator.snapshot.tunnelsRunState
            if !config.tunnelDefinitions.contains(where: \.enabled) {
                unconfigured.insert(.tunnels)
            } else if !start.owned.contains(.tunnels), tunnelsState == .running || tunnelsState == .warning {
                // Running from the pushed pair already.
            } else {
                await orchestrator.startTunnels()
                // The kernel reports a start whose every bind failed, or that it refused, as `failed`; a partial bind still runs as
                // `warning`. A failed member restores its prior permission and fence, and what it may have bound is closed.
                if orchestrator.snapshot.tunnelsRunState == .failed, holdsLane(start, .tunnels) {
                    workflow.endFailedStart(start.ticket, modules: [.tunnels])
                    start.active.remove(.tunnels)
                    settle(start, .tunnels, .failed)
                    if start.owned.contains(.tunnels) {
                        await tearDown([.tunnels], under: start, terminal: false)
                    }
                }
                if !start.active.isEmpty { try continueStart(start) }
            }
        }

        startObservers()
        workflow.finishStart(start.ticket, modules: start.active, succeeded: true)
        for module in ControlModule.allCases where start.active.contains(module) {
            settle(start, module, unconfigured.contains(module) ? .notConfigured : .started)
        }
        start.completed = true
        logger.log(.notice, "Daemon runtime started.", category: .general)
        // Submitted, not awaited: a diagnostic write never holds a lifecycle lane. Readiness and the terminal exit are the boundaries that
        // confirm it (`flushEvents`).
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        if start.actions.dns == .conditionalActivation {
            start.conditionalDNS = await runConditionalDNS(for: start)
        }
        return start.outcome
    }

    /// DNS whose verified pair names no forwarder settles `not_configured`, and this Start starts nothing. When it took DNS's lane from a
    /// Stop or Start in flight, it finishes that overtaken operation's teardown under its own DNS token: a reload that turned the forwarder
    /// off stops nothing by itself, and the run state is no proof that nothing is bound. DNS that was idle, running or down, is left as it
    /// was: a down module gets no clear, whose unknown-journal residue reset could touch a resolver the user set.
    private func leaveDNSUnconfigured(_ start: RuntimeLifecycleEffect, into unconfigured: inout Set<ControlModule>) async {
        unconfigured.insert(.dns)
        guard start.inherited.contains(.dns) else { return }
        await tearDown([.dns], under: start, terminal: false)
    }

    /// The kernel's proxy start, which returns once the start it ran or joined has completed. A proxy that is then not serving is no
    /// start: it throws, so the caller's failure path settles the member failed and clears the surfaces it owns rather than applying them
    /// to a listener that is not there.
    private func startProxyListener() async throws {
        try await orchestrator.startProxy()
        guard runtimeState().proxyIsUp else { throw RuntimeStartRefusal.notRunning }
    }

    /// Whether an authorized Start's remaining effects may run after a suspension; it throws when they may not, and `runStart`'s one
    /// finalization then holds the whole remaining operation (decision 0035). A combined Start is held whole once any of its own explicit
    /// members is superseded: a Stop or a newer Start took the member's lane, or ended its authority without the lane (a newer Start held
    /// before the lane included). Letting the unaffected members progress was the alternative 0035 did not select. A newer observation or
    /// write that replaced the prepared pair holds it too (decision 0037). An admission on a module outside the Start's scope is not its
    /// member and does not hold it; a DNS Stop beside a proxy Start denies only the companion (decision 0036). An identical joiner that
    /// adopted this effect is the group checked here. Nothing is retried.
    func continueStart(_ start: RuntimeLifecycleEffect) throws {
        let members = ControlModule.allCases.filter(start.active.contains)
        // `holdsLane` reports a taken lane with the effect's one `lifecycle.superseded`.
        guard members.allSatisfy({ holdsLane(start, $0) }) else { throw RuntimeStartRefusal.superseded }
        if let ended = members.first(where: { !workflow.holds($0, for: start.ticket) }) {
            emitConfigurationEvents(workflow.supersession(of: start.ticket, module: ended))
            throw RuntimeStartRefusal.superseded
        }
        guard let prepared = start.prepared, workflow.holdsInput(prepared) else {
            emitConfigurationEvents([.held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .inputReplaced))])
            throw RuntimeStartRefusal.superseded
        }
    }

    enum DNSModuleStart {
        case running
        /// The forwarder did not come up; the module's machine surfaces are restored.
        case failed
        /// A newer Start or Stop of DNS took its lane, and owns the module now.
        case superseded
        /// It still holds its lane, but its authority or its verified input no longer stands, so it stopped before its next machine
        /// effect. What it already did is its caller's to tear down, under its own lane.
        case withdrawn
    }

    /// The DNS module's physical start under `effect`'s DNS token, the explicit member's and the companion's alike: the capture of the
    /// prior DNS servers, the forwarder, then the system DNS pointed at it and the intercept files, once the forwarder and the transparent
    /// proxy they point clients at are both listening, then the health timer. A forwarder that does not come up gives the interfaces back
    /// what was captured, as `AppState.startDNS` does, withdraws the intercept files and starts no health timer.
    ///
    /// `stands` is the caller's authority over its verified pair: the group's DNS member and its strict input for an explicit Start, the
    /// companion's conditional permission and its parent's strict input for a companion (decisions 0036 and 0037). It is checked, with the
    /// lane, before the first machine effect and after every suspension, so a newer observation or write of the pair is never acted on.
    func startDNSModule(
        _ effect: RuntimeLifecycleEffect,
        config: ProxyConfig,
        platform: PlatformIntegrationConfig,
        stands: () -> Bool
    ) async -> DNSModuleStart {
        let token = effect.token(.dns)
        let resolvers = dnsManager
        let systemDNS = systemDNSManager
        let logger = self.logger
        func current() -> DNSModuleStart? {
            guard holdsLane(effect, .dns) else { return .superseded }
            return stands() ? nil : .withdrawn
        }
        if let stop = current() { return stop }
        if platform.manageSystemDNS {
            await platformWork.run {
                systemDNS.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try systemDNS.saveCurrentDNS(logger: logger)
                    } catch {
                        logger.log(.warning, "Could not save current DNS state (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if let stop = current() { return stop }
        }
        await orchestrator.startDNS()
        if let stop = current() { return stop }
        let forwarderRunning = orchestrator.snapshot.dnsRunState == .running
        let interceptReady = orchestrator.snapshot.bindings.dnsInterceptReady
        let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
        await platformWork.run {
            if platform.manageSystemDNS {
                systemDNS.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        if forwarderRunning {
                            try systemDNS.apply(forwarderPort: forwarderPort, logger: logger)
                        } else {
                            try systemDNS.clear(logger: logger)
                        }
                    } catch {
                        logger.log(.warning, "Could not \(forwarderRunning ? "set" : "restore") system DNS (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            // `applyProxySurfaces` wrote the split-DNS entry files only; the intercept files follow the forwarder here.
            guard platform.manageDNSResolvers else { return }
            resolvers.serialized {
                guard !token.isSuperseded else { return }
                do {
                    try resolvers.refreshInterceptFiles(
                        config: config,
                        interceptReady: interceptReady,
                        forwarderRunning: forwarderRunning,
                        logger: logger
                    )
                } catch {
                    logger.log(.warning, "Could not apply intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
                }
            }
        }
        if let stop = current() { return stop }
        guard forwarderRunning else { return .failed }
        if platform.manageSystemDNS {
            // Whether or not `apply` succeeded — see `AppState.startDNS`.
            startDNSHealthTimer(forwarderPort: forwarderPort)
        }
        return .running
    }

    /// The companion's run and its own `lifecycle.module_settled`, separate from the members' and under the same group. Every result,
    /// a failure included, is recorded once here, before any log line about it.
    private func runConditionalDNS(for start: RuntimeLifecycleEffect) async -> RuntimeConditionalDNSResult {
        let result = await activateConditionalDNS(for: start)
        recordSettlement(.conditionalDNS(result), of: start)
        return result
    }

    /// A proxy Start's conditional DNS companion (decision 0036), once its members settled. It starts DNS only while DNS's configured
    /// intent is on and unfenced, nothing newer supersedes it, and DNS is neither running nor starting; otherwise it is a typed no-op. It
    /// takes the DNS lane only to act, so it never overtakes a DNS operation in flight, and it never writes intent or clears a fence. A
    /// failed forwarder keeps DNS's intent and fence, restores its surfaces and leaves the proxy up.
    ///
    /// It acts on its parent's prepared pair, the same value, under that pair's strict freshness (decision 0037): a newer observation or
    /// write that replaced it holds the companion, with the typed `input_replaced`, before its next machine effect; it is never rebound. A
    /// companion that lost its parent's permission or input while it ran tears down what it started under its own DNS lane. One whose lane a
    /// newer DNS operation took leaves the module and its cleanup to that owner. The completed proxy is a fact and stays up either way.
    private func activateConditionalDNS(for start: RuntimeLifecycleEffect) async -> RuntimeConditionalDNSResult {
        guard let prepared = start.prepared else { preconditionFailure("a companion rides a Start") }
        let ticket = prepared.ticket
        guard workflow.conditionalActivationAllowed(ticket) else {
            let intent = workflow.dnsIntent
            if intent.fenced { return .fenced }
            return intent.configured ? .superseded : .notConfigured
        }
        func inputReplaced() -> RuntimeConditionalDNSResult {
            emitConfigurationEvents([.held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .inputReplaced))])
            return .superseded
        }
        guard workflow.holdsInput(prepared) else { return inputReplaced() }
        let state = orchestrator.snapshot.dnsRunState
        guard lanes.dns.isIdle, state != .running, state != .starting else { return .alreadyActive }
        guard case .run(let companion) = beginLanes([.dns], kind: .start, operation: .dnsStart, request: .conditional,
                                                     prepared: nil, coalescing: false) else {
            preconditionFailure("a companion never coalesces")
        }
        defer { endLanes(companion) }
        let started = await startDNSModule(companion, config: heldRuntimeConfig, platform: platformConfig, stands: {
            workflow.conditionalActivationAllowed(ticket) && workflow.holdsInput(prepared)
        })
        // A newer DNS operation owns the module and its cleanup.
        guard started != .superseded, holdsLane(companion, .dns) else { return .superseded }
        // Its own lane still: what it started without standing authority is its own to tear down.
        guard workflow.conditionalActivationAllowed(ticket), workflow.holdsInput(prepared) else {
            let replaced = !workflow.holdsInput(prepared)
            await tearDown([.dns], under: companion, terminal: false)
            return replaced ? inputReplaced() : .superseded
        }
        workflow.settleConditional(ticket, succeeded: started == .running)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        // A failure's system DNS is restored and the proxy stays up; its caller records the typed result before any log line.
        return started == .running ? .started : .failed
    }

    // MARK: Teardown

    /// The one physical teardown of `modules`, in DNS, tunnels, proxy order, under `effect`'s tokens, whichever Stop or Start runs it.
    /// DNS restores the system DNS, stops its health timer and forwarder, and, while the proxy stays up, withdraws the intercept files that
    /// pointed at it. Tunnels stop their listeners. The proxy stops its listener and clears the system proxy, environment and resolver
    /// files. The runtime's observers stop only when no module stays up. It waits only for effects already in flight (`quiesceEffects`),
    /// never for a queued reconcile pass: that pass waits for the lanes these tokens hold. A module whose token a newer owner superseded
    /// stops at its next step, unless `terminal` says it must finish; the other modules go on. Returns the modules it ran to their end.
    @discardableResult
    func tearDown(_ modules: Set<ControlModule>, under effect: RuntimeLifecycleEffect, terminal: Bool) async -> Set<ControlModule> {
        guard !modules.isEmpty else { return [] }
        await reconciler.quiesceEffects()
        func goesOn(_ module: ControlModule) -> Bool { terminal || holdsLane(effect, module) }
        // A newer start or stop may have begun during that wait. It owns its modules' observers and state now.
        var remaining = modules.filter { goesOn($0) }
        guard !remaining.isEmpty else { return [] }
        if remaining.union(modulesDown()) == Self.allModules {
            vpnStatusMonitor.stop()
            networkLocationObserver.stop()
            networkPathObserver.stop()
        }
        if remaining.contains(.proxy) { runtimeStarted = false }

        // Cleanup clears what the machine holds: the runtime input it was pushed, and the flags the reconciler completed. A flag that never
        // landed is covered by the journal.
        let config = heldRuntimeConfig
        let platform = completedPlatformBaseline
        let logger = self.logger
        if remaining.contains(.dns) {
            let token = effect.token(.dns)
            let systemDNS = systemDNSManager
            let resolvers = dnsManager
            stopDNSHealthTimer()
            await platformWork.run {
                systemDNS.serialized {
                    guard terminal || !token.isSuperseded else { return }
                    guard platform.manageSystemDNS || systemDNS.hasSavedState() else { return }
                    do {
                        try systemDNS.clear(logger: logger)
                    } catch {
                        logger.log(.warning, "Could not restore system DNS: \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if goesOn(.dns) { await orchestrator.stopDNS() }
            // The proxy's own clear below removes every resolver file; a proxy that stays up keeps its entry files.
            if goesOn(.dns), !remaining.contains(.proxy), platform.manageDNSResolvers {
                let interceptReady = orchestrator.snapshot.bindings.dnsInterceptReady
                let forwarderRunning = orchestrator.snapshot.dnsRunState == .running
                await platformWork.run {
                    resolvers.serialized {
                        guard terminal || !token.isSuperseded else { return }
                        do {
                            try resolvers.refreshInterceptFiles(
                                config: config,
                                interceptReady: interceptReady,
                                forwarderRunning: forwarderRunning,
                                logger: logger
                            )
                        } catch {
                            logger.log(.warning, "Could not withdraw intercept resolver files: \(error.localizedDescription)", category: .system)
                        }
                    }
                }
            }
            if !goesOn(.dns) { remaining.remove(.dns) }
        }
        if remaining.contains(.tunnels) {
            if goesOn(.tunnels) { await orchestrator.stopTunnels() }
            if !goesOn(.tunnels) { remaining.remove(.tunnels) }
        }
        if remaining.contains(.proxy), !(await tearDownProxy(under: effect, config: config, platform: platform, terminal: terminal)) {
            remaining.remove(.proxy)
        }
        if !remaining.isEmpty { logStopped(remaining) }
        return remaining
    }

    /// The proxy module's part of `tearDown`. Returns whether it ran to its end.
    private func tearDownProxy(
        under effect: RuntimeLifecycleEffect,
        config: ProxyConfig,
        platform: PlatformIntegrationConfig,
        terminal: Bool
    ) async -> Bool {
        guard terminal || holdsLane(effect, .proxy) else { return false }
        await orchestrator.stopProxy()
        guard terminal || holdsLane(effect, .proxy) else { return false }
        let token = effect.token(.proxy)
        let systemProxy = systemConduit
        let environment = environmentManager
        let resolvers = dnsManager
        let logger = self.logger

        // Each surface is cleared when its flag is on *or* when the journal
        // says the surface is ours, as in `AppState.stopProxy`. The flag alone
        // skipped the clear whenever the switch had gone off since the
        // surface was applied; the reload reconciles that flip now, so what
        // is left for the guard is the residue: a clear the machine refused,
        // a crash between the flip and the reload, a config file edited by
        // hand (#13). The ownership reads happen inside the block, after
        // whatever was queued ahead of it has landed.
        let stopGeneration = splitDNSRepair.generation
        let entryFiles = await platformWork.run { () -> SplitDNSEntryFileRepair.Outcome? in
            systemProxy.serialized {
                guard terminal || !token.isSuperseded else { return }
                guard platform.manageSystemProxy || systemProxy.hasManagedState() else { return }
                do {
                    try systemProxy.clear(logger: logger)
                } catch {
                    logger.log(.warning, "Could not clear system proxy settings: \(error.localizedDescription)", category: .system)
                }
            }
            environment.serialized {
                guard terminal || !token.isSuperseded else { return }
                guard platform.manageEnvironmentVariables || environment.hasManagedState() else { return }
                do {
                    try environment.clear(logger: logger)
                } catch {
                    logger.log(.warning, "Could not clear environment variables: \(error.localizedDescription)", category: .system)
                }
            }
            return resolvers.serialized { () -> SplitDNSEntryFileRepair.Outcome? in
                guard terminal || !token.isSuperseded else { return nil }
                if platform.manageDNSResolvers {
                    do {
                        try resolvers.clear(config: config, logger: logger)
                    } catch {
                        logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
                        // Only an entry file left on disk is the repair's; an
                        // intercept file the clear could not remove is not.
                        if resolvers.entryFilesPresent(config: config) || resolvers.unconfiguredRecordedFilesPresent(config: config) {
                            return .failed(.remove, error)
                        }
                    }
                    return .succeeded(.remove)
                } else if resolvers.hasManagedState() {
                    // Switch off: only what the journal names as ours, never a file
                    // for a configured domain we did not write.
                    do {
                        try resolvers.clearRecorded(configs: [config], logger: logger)
                    } catch {
                        logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
                    }
                }
                return nil
            }
        }
        recordSplitDNS(entryFiles, source: .stop, startedAt: stopGeneration)
        return terminal || holdsLane(effect, .proxy)
    }

    /// The stopped state is submitted. A terminal stop flushes after this, in `shutdown`.
    private func logStopped(_ modules: Set<ControlModule>) {
        if modulesDown() == Self.allModules {
            logger.log(.notice, "Daemon runtime stopped.", category: .general)
        } else {
            let names = ControlModule.allCases.filter(modules.contains).map(\.rawValue).joined(separator: ",")
            logger.log(.notice, "Daemon runtime modules stopped: \(names).", category: .general)
        }
        writeSnapshotFile(snapshot: orchestrator.snapshot)
    }

    // MARK: Stop and quit

    /// The one Stop path. Admission fences every module in one turn, before launch recovery or any save is awaited (decision 0015); a
    /// session Stop of DNS also owes its disable. A module a newer Start or Stop was admitted on meanwhile is that admission's, so this Stop
    /// leaves it; the others' lanes are taken, or the identical Stop holding them is joined, and only those modules are torn down. Modules
    /// outside the scope keep running. A session DNS Stop's physical restore runs whatever the store's slot is doing, and its disable is then
    /// saved through the runtime-only lifecycle commit; the obligation ends only once the write verifies.
    func runStop(_ modules: Set<ControlModule>, reason: RuntimeStopReason) async -> RuntimeModuleStopOutcome {
        await runAdmittedStop(admitModuleStop(modules, reason: reason))
    }

    /// The synchronous half of `runStop`: every module of the scope is fenced in this one turn, whatever the store or launch recovery is
    /// doing. The admission is pending work until `runAdmittedStop` returns, or until `dropAdmittedStop` releases one that never ran.
    /// `requestID` is the client request it follows, nil for the host's own compositions.
    func admitModuleStop(
        _ modules: Set<ControlModule>,
        reason: RuntimeStopReason,
        requestID: ControlRequestID? = nil
    ) -> RuntimeAdmittedStop {
        precondition(reason != .processQuit, "the process quit is `shutdown`")
        pendingAdmissions += 1
        let revision = workflow.admitStop(modules, reason: reason)
        stoppedEffectsJoin?.finish(.superseded)
        return RuntimeAdmittedStop(modules: modules, reason: reason, revision: revision, requestID: requestID)
    }

    /// Releases a Stop admission that will never run, because a newer Stop of the same module replaced it before it launched. Its fence
    /// stays: the newer Stop holds the module and owes whatever it saves.
    func dropAdmittedStop(_ admitted: RuntimeAdmittedStop) {
        _ = admitted
        pendingAdmissions -= 1
    }

    /// The asynchronous half of `runStop`, for one admission `admitModuleStop` made. It runs once per admission.
    func runAdmittedStop(_ admitted: RuntimeAdmittedStop) async -> RuntimeModuleStopOutcome {
        defer { pendingAdmissions -= 1 }
        let modules = admitted.modules
        let reason = admitted.reason
        let revision = admitted.revision
        await awaitLaunchRecovery()
        // Read before a lane is taken, so no suspension separates it from the check.
        let revisions = workflow.revisions
        let scope = modules.filter { revisions[$0] == revision }
        var stopped: Set<ControlModule> = []
        if !scope.isEmpty {
            let operation = Self.stopOperation(scope)
            switch beginLanes(scope, kind: .stop, operation: operation, request: .stop(reason), prepared: nil, coalescing: true) {
            case .join(let running):
                await join(running, operation: operation)
                stopped = running.stopped
            case .run(let stop):
                stop.stopped = await tearDown(scope, under: stop, terminal: false)
                stopped = stop.stopped
                endLanes(stop)
            }
        }
        guard reason == .session, modules.contains(.dns) else {
            return RuntimeModuleStopOutcome(stopped: stopped, dnsSave: nil)
        }
        let save = await workflow.saveOwedDNSStop(requestID: admitted.requestID)
        emitConfigurationEvents(save.events)
        let result: RuntimeDNSStopSave = switch save.save {
        case .saved: .saved
        case .owed: .owed
        case .notOwed: .notOwed
        }
        return RuntimeModuleStopOutcome(stopped: stopped, dnsSave: result)
    }

    /// The lifecycle operation a Stop of `scope` names in its events.
    static func stopOperation(_ scope: Set<ControlModule>) -> LifecycleOperation {
        guard scope.count == 1, let module = scope.first else { return .runtimeStop }
        switch module {
        case .proxy: return .proxyStop
        case .dns: return .dnsStop
        case .tunnels: return .tunnelsStop
        }
    }

    /// The process quit, and the one terminal teardown. It latches at admission, before anything awaits, so no Start runs again in this
    /// process; it persists no DNS disable (the saved launch intent stays) and keeps a disable save an earlier session Stop still owes. It
    /// supersedes every module's operation in flight rather than joining it, always finishes its own cleanup, then joins every lane, so
    /// each operation it superseded has ended, and every store operation already begun, before it confirms the diagnostic flush. Only then
    /// may the caller release the root's authority. It returns and never exits; a caller that ends the process calls `terminalExit` after
    /// it, as `stopRuntime(exitAfterStop: true)` does. A second call joins the first.
    ///
    /// It joins launch recovery first, and this is where the daemon parts from the app: `AppState.performTerminationCleanup` does not join
    /// because `applicationWillTerminate` is synchronous. `SIGTERM` reaches this through a `Task`, so the join leaves the main actor free,
    /// and the stop's clears never overlap recovery's.
    package func shutdown() async {
        if let quit {
            await quit.value
            return
        }
        pendingAdmissions += 1
        workflow.admitStop(terminal: true)
        stoppedEffectsJoin?.finish(.superseded)
        let quit = Task { @MainActor [self] in
            defer { pendingAdmissions -= 1 }
            await awaitLaunchRecovery()
            guard case .run(let stop) = beginLanes(Self.allModules, kind: .stop, operation: .runtimeStop,
                                                   request: .stop(.processQuit), prepared: nil, coalescing: false) else {
                preconditionFailure("the quit never coalesces")
            }
            stop.stopped = await tearDown(Self.allModules, under: stop, terminal: true)
            endLanes(stop)
            await waitUntilIdle(Self.allModules)
            await workflow.waitUntilIdle()
            await flushEvents()
        }
        self.quit = quit
        await quit.value
    }

    // MARK: Whole-host facade

    /// The legacy whole-runtime facade Start: one admitted group of proxy and tunnels Starts and DNS's configured Start, over the same
    /// owner, preparation and effect path as a module Start. A DNS forwarder that fails beside a started proxy settles DNS alone, as before.
    package func startRuntime() async throws {
        _ = try await runStart(
            PrivateModuleSlots(proxy: .start, dns: .configuredStart, tunnels: .start),
            expecting: PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil),
            operation: .runtimeStart,
            restartsProxy: false
        )
    }

    /// The legacy whole-runtime facade Stop over the one Stop path: it fences every module and persists no DNS disable. A Stop while an
    /// identical one is out joins it rather than queueing another teardown. A Stop on the way to `exit` is the process quit (`shutdown`).
    package func stopRuntime(exitAfterStop: Bool = false) async {
        if exitAfterStop {
            await shutdown()
            terminalExit()
            return
        }
        _ = await runStop(Self.allModules, reason: .facade)
    }

    // MARK: Module facade (decision 0033)

    /// Each module's lifecycle revision now, which a caller names to have its request refused whole if any moved (decision 0035).
    package var moduleRevisions: PrivateModuleSlots<Int> { workflow.revisions }

    /// An explicit proxy Start from the saved input, with DNS's conditional companion when `conditionalDNS` is set (decision 0036).
    package func startProxy(
        conditionalDNS: Bool,
        expecting revisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) async throws -> RuntimeModuleStartOutcome {
        try await runStart(
            PrivateModuleSlots(proxy: .start, dns: conditionalDNS ? .conditionalActivation : .none, tunnels: .none),
            expecting: revisions, operation: .proxyStart, restartsProxy: false
        )
    }

    /// The ordinary menu Restart: a proxy Start from the saved input, never from unsaved editor values, that stops a running listener
    /// first, with DNS's conditional companion. Both use the same primitive as `startProxy`.
    package func restartProxy(
        expecting revisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) async throws -> RuntimeModuleStartOutcome {
        try await runStart(
            PrivateModuleSlots(proxy: .start, dns: .conditionalActivation, tunnels: .none),
            expecting: revisions, operation: .proxyStart, restartsProxy: true
        )
    }

    /// An explicit DNS Start: it stages the enable in the shared write and clears DNS's fence only once its verified pair is adopted.
    package func startDNS(
        expecting revisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) async throws -> RuntimeModuleStartOutcome {
        try await runStart(PrivateModuleSlots(proxy: .none, dns: .start, tunnels: .none),
                           expecting: revisions, operation: .dnsStart, restartsProxy: false)
    }

    /// An explicit tunnels Start from the saved input.
    package func startTunnels(
        expecting revisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) async throws -> RuntimeModuleStartOutcome {
        try await runStart(PrivateModuleSlots(proxy: .none, dns: .none, tunnels: .start),
                           expecting: revisions, operation: .tunnelsStart, restartsProxy: false)
    }

    /// A session Stop of the proxy. DNS and tunnels keep running.
    package func stopProxy() async -> RuntimeModuleStopOutcome {
        await runStop([.proxy], reason: .session)
    }

    /// A session Stop of DNS: fenced at once, physically restored, then its disable saved.
    package func stopDNS() async -> RuntimeModuleStopOutcome {
        await runStop([.dns], reason: .session)
    }

    /// A session Stop of tunnels. The proxy and DNS keep running.
    package func stopTunnels() async -> RuntimeModuleStopOutcome {
        await runStop([.tunnels], reason: .session)
    }
}

extension LifecycleModule {
    /// The event's spelling of a host module lane.
    init(_ module: ControlModule) {
        switch module {
        case .proxy: self = .proxy
        case .dns: self = .dns
        case .tunnels: self = .tunnels
        }
    }
}
