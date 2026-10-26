// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// What one admitted request asks of one module (decisions 0035 and 0036). `conditionalActivation` is DNS's companion of a proxy Start:
/// it starts DNS only under DNS's own current intent, and it never enables DNS or clears its fence.
enum RuntimeModuleAction: Equatable, Sendable {
    case none
    case start
    case conditionalActivation
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
    /// The request asks nothing, or pairs a conditional activation with anything but DNS beside a proxy Start (decision 0036).
    case invalid
}

/// What one admission gave its caller: the group's counter value, the actions it requested and the DNS dependency it was admitted on.
/// The companion lives here, with its caller, never in DNS's own slot, so it changes no DNS control. A newer DNS admission, or a change of
/// the staged `dnsForwarderEnabled`, makes a group that has not been authorized stale (decision 0035).
struct RuntimeLifecycleTicket: Equatable, Sendable {
    let group: Int
    let actions: PrivateModuleSlots<RuntimeModuleAction>
    /// DNS's revision once this admission was made.
    let dnsRevision: Int
    /// The `dnsForwarderEnabled` the group's shared write stages, as of its admission.
    let dnsStaged: Bool

    var requestsCompanion: Bool { actions.dns == .conditionalActivation }
}

/// An explicit Start that is pending or authorized. `prior` is the module's permission and fence before it, which a held or failed Start
/// restores, so neither leaves a permission that a reload, a repair or a later companion could act on.
struct RuntimeModuleStart: Equatable, Sendable {
    let group: Int
    let priorEnabled: Bool
    let priorFenced: Bool
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
    private(set) var modules: PrivateModuleSlots<RuntimeModuleIntent>
    /// DNS's configured `forwarderEnabled`, separate from its runtime permission: the store's adopted value, a session Stop's disable, or
    /// an explicit DNS Start's verified write. A companion activation reads it; it is never a permission by itself.
    private(set) var dnsConfigured: Bool

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

    /// The `dnsForwarderEnabled` every runtime write stages: true for a pending explicit DNS Start, so its file holds the enable before its
    /// runtime activation; otherwise the configured intent. A companion projects the configured intent and enables nothing, and a Stop's save
    /// projects the false its admission set. The permission and the fence stay as they were until `authorize`.
    var stagedDNSForwarderEnabled: Bool {
        if case .start = modules.dns.pending { return true }
        return dnsConfigured
    }

    /// Records a verified runtime write's `dnsForwarderEnabled`, staged while DNS's revision was `revision`. It is a saved fact, kept whatever
    /// the Start's activation does later (decision 0015). A newer DNS admission since the staging wins, so a late write of an older value
    /// cannot overturn a Stop's disable.
    mutating func recordVerifiedDNSWrite(_ enabled: Bool, for ticket: RuntimeLifecycleTicket) {
        guard modules.dns.revision == ticket.dnsRevision else { return }
        dnsConfigured = enabled
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
        guard !terminal else { return .failure(.terminated) }
        guard counter < Int.max else { return .failure(.exhausted) }
        for module in actionable {
            if let expected = request.expectedRevisions[module], expected != modules[module].revision {
                return .failure(.stale(module))
            }
        }
        counter += 1
        let group = counter
        // Only an explicit Start changes a module's control. The companion is recorded in the ticket, and DNS's slot, save and revision stay.
        for module in actionable where request.actions[module] == .start {
            supersede(module, at: group)
            var intent = modules[module]
            // A Start that replaces an authorized one not yet settled inherits its prior, so the chain never confirms an unproven start.
            let prior = intent.authorized
            intent.pending = .start(RuntimeModuleStart(
                group: group,
                priorEnabled: prior?.priorEnabled ?? intent.enabled,
                priorFenced: prior?.priorFenced ?? intent.fenced
            ))
            intent.startedGroup = nil
            intent.revision = group
            modules[module] = intent
        }
        return .success(RuntimeLifecycleTicket(
            group: group,
            actions: request.actions,
            dnsRevision: modules.dns.revision,
            dnsStaged: stagedDNSForwarderEnabled
        ))
    }

    /// Admits a Stop of `stopped` in one turn: each is fenced and loses its permission at once, before any await. A session Stop of DNS also
    /// sets its durable intent false and reserves its save. A terminal stop latches, persists no disable, and keeps a DNS save an earlier
    /// session Stop reserved, since that obligation predates it. At the maximum the counter cannot advance, and the fence holds anyway.
    @discardableResult
    mutating func stop(_ stopped: Set<ControlModule>, terminal latch: Bool) -> Int {
        if counter < Int.max { counter += 1 }
        let revision = counter
        if latch { terminal = true }
        for module in ControlModule.allCases where stopped.contains(module) {
            let keepsSave = latch && module == .dns && modules.dns.pending.isStopSave
            if !keepsSave { supersede(module, at: revision) }
            var intent = modules[module]
            intent.enabled = false
            intent.fenced = true
            intent.authorized = nil
            intent.startedGroup = nil
            intent.revision = revision
            if module == .dns, !latch {
                dnsConfigured = false
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

    private mutating func endGroup(_ group: Int, at revision: Int?) {
        for module in ControlModule.allCases where modules[module].pending?.group == group {
            modules[module].pending = nil
            if let revision { modules[module].revision = revision }
        }
    }

    // MARK: - Start lifecycle

    /// Whether a ticket's shared prepare still stands: its members are still pending, no terminal stop latched, the staged
    /// `dnsForwarderEnabled` is the one it was admitted on, and, for a group with a companion, no newer DNS admission came.
    func isPending(_ ticket: RuntimeLifecycleTicket) -> Bool {
        !terminal && !members(of: ticket.group).isEmpty && stagedDNSForwarderEnabled == ticket.dnsStaged
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
            modules[module].enabled = true
            modules[module].fenced = false
        }
        return members
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

    mutating func finishStopSave(revision: Int) {
        if stopSaveIsCurrent(revision: revision) { modules.dns.pending = nil }
    }

    // MARK: - Observation

    /// A reload's adopted `forwarderEnabled`. It is a durable observation, not a permission: it can lower DNS's permission and never raise
    /// it. A fenced DNS, or one with an explicit Start in flight, keeps its own intent.
    mutating func observeDurableDNS(_ enabled: Bool) {
        let dns = modules.dns
        guard !dns.fenced, dns.authorized == nil else { return }
        guard dns.pending == nil else { return }
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
}
