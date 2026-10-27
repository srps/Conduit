// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// What one admitted request asks of one module (decisions 0035 and 0036). `conditionalActivation` is DNS's companion of a proxy Start:
/// it starts DNS only under DNS's own current intent, and it never enables DNS or clears its fence.
enum RuntimeModuleAction: Equatable, Sendable {
    case none
    case start
    case conditionalActivation
    /// The legacy whole-host facade's DNS Start (decision 0036 keeps that facade's behavior). It is a member like `start` and clears DNS's
    /// fence once authorized, but it stages and grants only DNS's configured intent and is no new DNS configuration intent. It is never on
    /// a wire.
    case configuredStart
}

/// Why modules stop. Only a `session` Stop of DNS persists a disable. A `facade` Stop, the legacy whole-host stop, fences every module and
/// keeps DNS's configured intent. `processQuit` does the same and latches, so nothing starts again in this process.
enum RuntimeStopReason: Equatable, Sendable {
    case session
    case facade
    case processQuit
}

/// One lifecycle request: an action per module, and the revision each actionable slot was observed at. A nil revision is the host's own
/// composition (the process facade), which has no client observation to check.
struct RuntimeLifecycleRequest: Equatable, Sendable {
    var actions: PrivateModuleSlots<RuntimeModuleAction>
    var expectedRevisions: PrivateModuleSlots<Int?>

    init(
        actions: PrivateModuleSlots<RuntimeModuleAction>,
        expectedRevisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) {
        self.actions = actions
        self.expectedRevisions = expectedRevisions
    }
}

/// Why a request was refused in its admission turn. Nothing changed: no intent, no revision and no pending work.
enum RuntimeLifecycleRefusal: Error, Equatable, Sendable {
    /// A terminal stop has latched.
    case terminated
    /// The counter is at its maximum, so no newer admission can be ordered.
    case exhausted
    /// The whole request is stale: this module's revision moved since the caller observed it (decision 0035).
    case stale(ControlModule)
    /// This module's one pending slot holds a disable save that the request's configured Start may not displace. It is retried once the
    /// save settles.
    case busy(ControlModule)
    /// The request asks nothing, or pairs a conditional activation with anything but DNS beside a proxy Start (decision 0036).
    case invalid
}

/// When a ticket's group bound its saved input (decision 0037). A queued group carries no configuration value. Its preparation captures the
/// store's current pair once, when it obtains the store's capacity, and merges DNS's local intent into it then.
enum RuntimeInputBinding: Equatable, Sendable {
    case queued
    /// The `dnsForwarderEnabled` the group's shared write stages, fixed at the capture. A change of the staged value after it, a reload's
    /// newer observation or a newer DNS intent, makes the group stale: its remaining work holds and is never rebound.
    case captured(dnsStaged: Bool)
}

/// What one admission gave its caller: the group's counter value, the actions it requested and the DNS dependency it was admitted on.
/// The companion lives here, with its caller, never in DNS's own slot, so it changes no DNS control. A newer DNS admission, or a change of
/// the staged `dnsForwarderEnabled` after the capture, makes a group that has not been authorized stale (decisions 0035 and 0037).
struct RuntimeLifecycleTicket: Equatable, Sendable {
    let group: Int
    let actions: PrivateModuleSlots<RuntimeModuleAction>
    /// DNS's revision once this admission was made.
    let dnsRevision: Int
    /// The latest DNS Start or session Stop admission once this one was made. Unlike `dnsRevision`, another member ending the group does
    /// not move it, so it orders only DNS's own configured intent against this group's write.
    let dnsIntentRevision: Int
    /// Queued until `RuntimeModuleIntents.capture`; only that sets it.
    fileprivate(set) var binding = RuntimeInputBinding.queued

    var requestsCompanion: Bool { actions.dns == .conditionalActivation }

    /// The staged `dnsForwarderEnabled` of a captured group, or nil while it is queued.
    var dnsStaged: Bool? {
        if case .captured(let staged) = binding { return staged }
        return nil
    }
}

/// An explicit Start that is pending or authorized. `prior` is the module's permission and fence before it, which a held or failed Start
/// restores, so neither leaves a permission that a reload, a repair or a later companion could act on.
struct RuntimeModuleStart: Equatable, Sendable {
    let group: Int
    let priorEnabled: Bool
    let priorFenced: Bool
    /// Admitted as `configuredStart`: it stages and grants DNS's configured intent rather than an enable.
    var configured = false
    /// A DNS Start that took DNS's slot over the disable save a session Stop still owed (decision 0015), directly or from the unverified
    /// Start it replaced. Its admission does not end that obligation: a verified write under the current DNS intent resolves it (a false
    /// one is that disable, the only true one this Start's own enable), and an end without one puts the save back in the slot.
    var displacesOwedSave = false
}

/// The one fixed pending slot of a module. A newer admission on the module replaces it, so the bound is the three modules.
enum RuntimeModulePending: Equatable, Sendable {
    /// A member of group `start.group`'s one shared prepare.
    case start(RuntimeModuleStart)
    /// DNS's Stop disable save, admitted at `revision`.
    case stopSave(revision: Int)
}

/// One module's intent. `enabled` is the session permission: what a companion activation, a repair or a reload may act on. `fenced` is a
/// Stop's fence. Only `authorize` sets the one and clears the other.
struct RuntimeModuleIntent: Equatable, Sendable {
    /// The counter value of the latest admission or settlement that changed this module.
    var revision = 0
    var enabled: Bool
    var fenced = false
    var pending: RuntimeModulePending?
    /// A Start authorized after its verified prepare, until its effect settles.
    var authorized: RuntimeModuleStart?
    /// The group whose authorized Start this module is running under, kept past a successful settle. A companion acts only beside its own
    /// group's proxy Start, so a proxy Stop, a failure or a newer proxy admission ends it (decision 0036).
    var startedGroup: Int?
}

/// The per-module lifecycle intent of one host: one ordered counter, one terminal latch, three fixed module records and DNS's durable
/// forwarder intent. It is a value with no I/O; the configuration workflow owns the one instance.
struct RuntimeModuleIntents: Equatable, Sendable {
    private(set) var counter: Int
    private(set) var terminal = false
    /// Whether the quit's reserved flush window is open (decision 0015): set in the latch's own turn when the quit reserves one, and
    /// cleared once, when the window closes or its deadline passes. A flush's write claim holds only while it is set, so a flush admitted
    /// but not yet at its replacement writes nothing after the window. A write already past its claim completes, and the quit joins it.
    var quitFlushOpen = false
    private(set) var modules: PrivateModuleSlots<RuntimeModuleIntent>
    /// DNS's configured `forwarderEnabled`, separate from its runtime permission: the store's adopted value, a session Stop's disable, or
    /// an explicit DNS Start's verified write. A companion activation reads it; it is never a permission by itself.
    private(set) var dnsConfigured: Bool
    /// The counter value of the latest explicit DNS Start or session DNS Stop: the only admissions that change `dnsConfigured`'s intent.
    /// `nil` after a DNS Stop at the maximum, which takes no newer value: no ticket holds it, and no admission follows it.
    private(set) var dnsIntentRevision: Int? = 0

    /// - Parameter dnsEnabled: the adopted startup value. At launch it is both DNS's configured intent and its session permission.
    init(counter: Int = 0, dnsEnabled: Bool) {
        precondition(counter >= 0, "the counter is never negative")
        self.counter = counter
        self.dnsConfigured = dnsEnabled
        self.modules = PrivateModuleSlots(
            proxy: RuntimeModuleIntent(enabled: false),
            dns: RuntimeModuleIntent(enabled: dnsEnabled),
            tunnels: RuntimeModuleIntent(enabled: false)
        )
    }

    var allFenced: Bool {
        ControlModule.allCases.allSatisfy { modules[$0].fenced }
    }

    /// The `dnsForwarderEnabled` group `group`'s runtime write stages: true when that group's own explicit DNS Start is pending, so its file
    /// holds the enable before its runtime activation; otherwise the durable configured intent, a session Stop's false included. Another
    /// request's pending enable is not yet persisted intent (decisions 0015, 0035 and 0036), so no other group writes it first and no
    /// companion can act on it. A companion, a Stop's save and a facade's `configuredStart` project the configured intent. The permission
    /// and the fence stay as they were until `authorize`.
    /// A nil `group` is a save, which has no Start of its own and stages the durable intent.
    func stagedDNSForwarderEnabled(for group: Int?) -> Bool {
        if let group, case .start(let start) = modules.dns.pending, !start.configured, start.group == group { return true }
        return dnsConfigured
    }

    /// Records a verified runtime write's `dnsForwarderEnabled`, staged by `ticket`'s group. It is a saved fact, kept whatever the Start's
    /// activation does later and whichever member ended the group (decision 0015). Only a newer DNS Start or Stop since the staging wins, so
    /// a late write of an older value cannot overturn a Stop's disable.
    /// A verified write of the very disable a session Stop still owes, staged by a group admitted after that Stop, fulfils the obligation:
    /// the file holds it. The fence stays, and nothing else about DNS changes. A pending DNS Start that displaced the obligation keeps it
    /// until a write under the current intent verifies: only that Start's own group stages true, so a true one is its newer saved fact, and
    /// any other is the disable itself. The same holds once that Start ended before its write verified and gave the save back: its own
    /// late enable, under the intent revision its explicit DNS admission set, is the newer fact. A newer session Stop moved the revision.
    mutating func recordVerifiedDNSWrite(_ enabled: Bool, for ticket: RuntimeLifecycleTicket) {
        let ownEnable = enabled && ticket.actions.dns == .start && ticket.group == ticket.dnsIntentRevision
        recordVerifiedDNSWrite(enabled, intentRevision: ticket.dnsIntentRevision, ownEnable: ownEnable)
    }

    /// The one rule for a verified runtime write's DNS bit, a Start's or a save's, staged under `intentRevision`. A save has no Start of its
    /// own, so it is never `ownEnable`.
    mutating func recordVerifiedDNSWrite(_ enabled: Bool, intentRevision: Int?, ownEnable: Bool) {
        guard let intentRevision, dnsIntentRevision == intentRevision else { return }
        dnsConfigured = enabled
        switch modules.dns.pending {
        case .stopSave(let revision) where (!enabled || ownEnable) && revision == intentRevision:
            modules.dns.pending = nil
        case .start(var start) where start.displacesOwedSave:
            start.displacesOwedSave = false
            modules.dns.pending = .start(start)
        case .stopSave, .start, nil:
            break
        }
    }

    // MARK: - Admission

    /// Admits a request in one turn. Every check runs before any change, so a refusal changes nothing. One counter value orders the whole
    /// request, and it is the group of its Starts and companion.
    mutating func admit(_ request: RuntimeLifecycleRequest) -> Result<RuntimeLifecycleTicket, RuntimeLifecycleRefusal> {
        let actionable = ControlModule.allCases.filter { request.actions[$0] != .none }
        guard !actionable.isEmpty else { return .failure(.invalid) }
        for module in actionable where request.actions[module] == .conditionalActivation {
            guard module == .dns, request.actions.proxy == .start else { return .failure(.invalid) }
        }
        for module in actionable where request.actions[module] == .configuredStart {
            guard module == .dns else { return .failure(.invalid) }
        }
        guard !terminal else { return .failure(.terminated) }
        guard counter < Int.max, let dnsIntent = dnsIntentRevision else { return .failure(.exhausted) }
        for module in actionable {
            if let expected = request.expectedRevisions[module], expected != modules[module].revision {
                return .failure(.stale(module))
            }
            // A configured Start is no DNS intent, so it may not displace the disable save a session Stop still owes from DNS's one slot,
            // held there itself or by an explicit DNS Start that displaced it.
            if request.actions[module] == .configuredStart, modules[module].pending.owesStopSave {
                return .failure(.busy(module))
            }
        }
        counter += 1
        let group = counter
        // Only an explicit Start changes a module's control. The companion is recorded in the ticket, and DNS's slot, save and revision stay.
        for module in actionable where request.actions[module] == .start || request.actions[module] == .configuredStart {
            // A DNS Start carries the disable save the slot still owes, never ends it (decision 0015).
            let displacesOwedSave = module == .dns && modules.dns.pending.owesStopSave
            supersede(module, at: group)
            var intent = modules[module]
            // A Start that replaces an authorized one not yet settled inherits its prior and takes the module from it at once: the
            // unproven permission is withdrawn, and the old Start's late settlement no longer matches, so the chain never confirms it.
            if let replaced = intent.authorized {
                intent.authorized = nil
                intent.enabled = replaced.priorEnabled
                intent.fenced = replaced.priorFenced
            }
            intent.pending = .start(RuntimeModuleStart(
                group: group,
                priorEnabled: intent.enabled,
                priorFenced: intent.fenced,
                configured: request.actions[module] == .configuredStart,
                displacesOwedSave: displacesOwedSave
            ))
            intent.startedGroup = nil
            intent.revision = group
            modules[module] = intent
        }
        let intentRevision = request.actions.dns == .start ? group : dnsIntent
        dnsIntentRevision = intentRevision
        return .success(RuntimeLifecycleTicket(
            group: group,
            actions: request.actions,
            dnsRevision: modules.dns.revision,
            dnsIntentRevision: intentRevision
        ))
    }

    /// Binds a queued ticket's saved input, in the turn its preparation obtained the store's capacity (decision 0037). The store's adopted
    /// `dnsForwarderEnabled` is observed first, as a reload's would be, then DNS's local intent is merged into what the write stages.
    /// Returns the captured ticket, or nil when the group no longer stands; an observation adopted here is kept either way.
    mutating func capture(_ ticket: RuntimeLifecycleTicket, observedDNS: Bool) -> RuntimeLifecycleTicket? {
        precondition(ticket.binding == .queued, "a group captures its saved input once")
        observeDurableDNS(observedDNS)
        guard isPending(ticket) else { return nil }
        var captured = ticket
        captured.binding = .captured(dnsStaged: stagedDNSForwarderEnabled(for: ticket.group))
        return captured
    }

    /// Admits a Stop of `stopped` in one turn: each is fenced and loses its permission at once, before any await. A `session` Stop of DNS
    /// also sets its durable intent false and reserves its save. A `facade` Stop persists no disable and keeps a DNS save an earlier session
    /// Stop reserved, since that obligation predates it; `processQuit` does the same and latches. At the maximum the counter cannot advance,
    /// and the fence holds anyway.
    @discardableResult
    mutating func stop(_ stopped: Set<ControlModule>, reason: RuntimeStopReason) -> Int {
        let advanced = counter < Int.max
        if advanced { counter += 1 }
        let revision = counter
        if reason == .processQuit { terminal = true }
        // Once Quit has latched, every Stop is terminal for persistence: a late session Stop still fences, but it neither reserves a new
        // disable save nor drops one owed from before Quit (decision 0015).
        let persistsDNSStop = reason == .session && !terminal
        for module in ControlModule.allCases where stopped.contains(module) {
            let keepsSave = !persistsDNSStop && module == .dns && modules.dns.pending.isStopSave
            if !keepsSave { supersede(module, at: revision) }
            var intent = modules[module]
            intent.enabled = false
            intent.fenced = true
            intent.authorized = nil
            intent.startedGroup = nil
            intent.revision = revision
            if module == .dns, persistsDNSStop {
                dnsConfigured = false
                dnsIntentRevision = advanced ? revision : nil
                intent.pending = .stopSave(revision: revision)
            }
            modules[module] = intent
        }
        return revision
    }

    /// Clears the module's pending slot for a newer admission at `revision`. A pending Start ends its whole group, and every member it
    /// touches takes the new revision (decision 0035). A save ends alone. A companion has no slot: its ticket goes stale instead.
    private mutating func supersede(_ module: ControlModule, at revision: Int) {
        guard let pending = modules[module].pending else { return }
        switch pending {
        case .start(let start):
            endGroup(start.group, at: revision)
        case .stopSave:
            modules[module].pending = nil
        }
    }

    /// Ends a group's pending members. A DNS member that displaced an owed disable save and ended unauthorized, with no verified write of its
    /// own, gives the save back, keyed to the current DNS intent so a later verified disable under it fulfils the obligation.
    private mutating func endGroup(_ group: Int, at revision: Int?) {
        for module in ControlModule.allCases where modules[module].pending?.group == group {
            var vacated: RuntimeModulePending?
            if case .start(let start) = modules[module].pending, start.displacesOwedSave {
                guard let intentRevision = dnsIntentRevision else {
                    preconditionFailure("a DNS Start is admitted only under a DNS intent revision, and only a Stop at the maximum clears it")
                }
                vacated = .stopSave(revision: intentRevision)
            }
            modules[module].pending = vacated
            if let revision { modules[module].revision = revision }
        }
    }

    // MARK: - Start lifecycle

    /// Whether a ticket's shared prepare still stands: its members are still pending, no terminal stop latched, a captured group still
    /// stages the `dnsForwarderEnabled` it captured, and, for a group with a companion, no newer DNS admission came. A queued group has
    /// bound no value, so no observation before its capture makes it stale.
    func isPending(_ ticket: RuntimeLifecycleTicket) -> Bool {
        !terminal && !members(of: ticket.group).isEmpty
            && (ticket.dnsStaged.map { $0 == stagedDNSForwarderEnabled(for: ticket.group) } ?? true)
            && (!ticket.requestsCompanion || modules.dns.revision == ticket.dnsRevision)
    }

    /// The explicit Start members of a group, in module order.
    func members(of group: Int) -> [ControlModule] {
        ControlModule.allCases.filter {
            if case .start(let start) = modules[$0].pending { return start.group == group }
            return false
        }
    }

    /// Authorizes a ticket whose verified pair the host has already adopted: each member gains its permission and loses its fence. From here
    /// the shared input no longer depends on DNS, so a later DNS Stop denies only the companion. The configured DNS intent is not changed
    /// here; `recordVerifiedDNSWrite` records the saved fact. Returns the members, or an empty list when the ticket no longer stands.
    mutating func authorize(_ ticket: RuntimeLifecycleTicket) -> [ControlModule] {
        guard isPending(ticket) else { return [] }
        let members = members(of: ticket.group)
        for module in members {
            guard case .start(let start) = modules[module].pending else { continue }
            modules[module].pending = nil
            modules[module].authorized = start
            modules[module].startedGroup = ticket.group
            // A facade's configured Start clears the fence like any Start, but grants only the configured intent.
            modules[module].enabled = start.configured ? dnsConfigured : true
            modules[module].fenced = false
        }
        return members
    }

    /// Whether `ticket`'s group is still the latest admission and still holds a member, pending, authorized or started. Any newer Start
    /// or Stop, a Stop at the maximum included, or a failed settle ends it.
    func holdsGroup(_ ticket: RuntimeLifecycleTicket) -> Bool {
        guard !terminal, counter == ticket.group else { return false }
        if isPending(ticket) { return true }
        return ControlModule.allCases.contains {
            modules[$0].authorized?.group == ticket.group || modules[$0].startedGroup == ticket.group
        }
    }

    /// Whether `module` still acts under `ticket`'s group: no terminal stop latched, and the module's own record still names the group, as
    /// a pending member of a prepare that still stands, an authorized Start or a started one. Unlike `holdsGroup`, an admission on another
    /// module does not end it, so an unrelated Start or Stop leaves this module's progress alone (decision 0035). A Stop or a newer Start of
    /// this module, or a failed settle, does.
    func holds(_ module: ControlModule, for ticket: RuntimeLifecycleTicket) -> Bool {
        guard !terminal else { return false }
        let intent = modules[module]
        if case .start(let start) = intent.pending, start.group == ticket.group { return isPending(ticket) }
        return intent.authorized?.group == ticket.group || intent.startedGroup == ticket.group
    }

    /// Ends a held or stale ticket before authorization: its members keep the permission and fence they had. Nothing ran, so the counter
    /// does not advance, and a newer operation in a member's slot is not touched.
    mutating func retire(_ ticket: RuntimeLifecycleTicket) {
        endGroup(ticket.group, at: nil)
    }

    /// Settles one authorized member's effect. A failure restores the module's prior permission and fence, and advances the counter so work
    /// admitted under the start stops. A newer admission already replaced the record when it does not match, and nothing changes.
    mutating func settle(_ module: ControlModule, ticket: RuntimeLifecycleTicket, succeeded: Bool) {
        guard let start = modules[module].authorized, start.group == ticket.group else { return }
        modules[module].authorized = nil
        guard !succeeded else { return }
        modules[module].startedGroup = nil
        modules[module].enabled = start.priorEnabled
        modules[module].fenced = start.priorFenced
        if counter < Int.max {
            counter += 1
        } else {
            modules[module].fenced = true
        }
        modules[module].revision = counter
    }

    // MARK: - Companion and Stop save

    /// Whether a ticket's companion may start DNS now (decision 0036): it was requested, its proxy Start was authorized under this ticket
    /// and has not been stopped or replaced, no DNS admission came since, DNS is configured on, and no Stop fence is in force. It reads the
    /// configured intent, not the runtime permission, so an explicit request can activate DNS a reload found configured; the reload alone
    /// activates nothing.
    func conditionalActivationAllowed(_ ticket: RuntimeLifecycleTicket) -> Bool {
        ticket.requestsCompanion && !terminal && modules.proxy.startedGroup == ticket.group
            && modules.dns.revision == ticket.dnsRevision && dnsConfigured && !modules.dns.fenced
    }

    /// Settles the companion's physical start. The one runtime permission a companion grants: a DNS it started, while still allowed, keeps
    /// the permission the reconciler and repairs need. It never changes the configured intent or the fence, and a failure changes nothing.
    mutating func settleConditional(_ ticket: RuntimeLifecycleTicket, succeeded: Bool) {
        guard succeeded, conditionalActivationAllowed(ticket) else { return }
        modules.dns.enabled = true
    }

    func stopSaveIsCurrent(revision: Int) -> Bool {
        modules.dns.pending == .stopSave(revision: revision)
    }

    /// Ends the Stop's disable save once its write verified. A failed or unverified write leaves it owed.
    mutating func finishStopSave(revision: Int) {
        if stopSaveIsCurrent(revision: revision) { modules.dns.pending = nil }
    }

    // MARK: - Observation

    /// A reload's adopted `forwarderEnabled`. It is a durable fact, not a permission: it becomes the configured intent, can lower DNS's
    /// permission and never raises it, and the fence stays (decisions 0027 and 0032). A pending Start, an authorized one, or a Stop's disable
    /// save still owed keeps DNS's own intent; that save is owed until its write verifies. A facade's pending configured Start is no DNS
    /// intent, so the fact is adopted under it: before its capture it becomes the captured value, and after it the group no longer stands
    /// (decisions 0035 and 0037).
    mutating func observeDurableDNS(_ enabled: Bool) {
        let dns = modules.dns
        let configuredOnly = if case .start(let start) = dns.pending { start.configured } else { false }
        guard dns.pending == nil || configuredOnly, dns.authorized == nil else { return }
        dnsConfigured = enabled
        modules.dns.enabled = dns.enabled && enabled
    }
}

private extension RuntimeModulePending {
    var group: Int? {
        switch self {
        case .start(let start): start.group
        case .stopSave: nil
        }
    }
}

private extension Optional where Wrapped == RuntimeModulePending {
    var isStopSave: Bool {
        if case .stopSave = self { return true }
        return false
    }

    /// Whether the slot still owes a session Stop's disable save: the save itself, or a Start that displaced it unresolved.
    var owesStopSave: Bool {
        switch self {
        case .stopSave: true
        case .start(let start): start.displacesOwedSave
        case nil: false
        }
    }
}
