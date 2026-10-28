// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// The app's one observation of the runtime: a single subscription pulled by one task, and one coalesced collection refresh
/// (decisions 0031 and 0038). It feeds the presentation adapter from wire frames only, hands typed events to the app, and answers the
/// settlement of the operations the app submitted. Nothing it observes grants the editor any authority.
///
/// Bounds: one pull task and at most one refresh task. At most `maximumCallers` callers wait for settlements at once, across every
/// operation; callers of one joined operation share one record, released by the last of them. A refresh assembles at most one complete
/// capture of the service's own count and byte bound. When the stream ends or fails, the adapter's claims are cleared and the task
/// resubscribes after a bounded backoff; it never polls status. A host shutdown ends the observation and resolves every caller unsettled.
@MainActor
final class RuntimeObserver {
    /// The most callers waiting for settlements at once: the app's commands in flight, the editor's one operation, its notices and the
    /// quit's own read.
    nonisolated static let maximumCallers = 16
    /// How long one pull waits before it pulls again. A wait that ends here consumed no frame.
    nonisolated static let pullWindow: Duration = .seconds(30)
    /// The lookups in a row, one per `relookupInterval`, that may fail to reach the host before one settlement wait ends unsettled. A
    /// `pending` answer is the host still holding the operation, so it is no failure and starts the count again.
    static let relookupRounds = 4
    /// The resubscription backoff, doubled per failed attempt up to the ceiling and reset by a baseline.
    static let resubscribeFloor: Duration = .milliseconds(250)
    static let resubscribeCeiling: Duration = .seconds(5)

    private let control: any RuntimeClient
    private let presentation: RuntimePresentationAdapter
    /// The complete capture one refresh may assemble: the service's own bound.
    private let rowBudget: ControlRowBudget
    /// How long a settlement wait waits before it looks its own operation up again: one pull window.
    private let relookupInterval: Duration
    private(set) var incarnation: ControlHostIncarnation
    /// Typed events, in stream order. The app classifies its notifications from them.
    var onEvents: (@MainActor ([ControlRuntimeEvent]) -> Void)?
    /// Every applied snapshot, after the adapter took it.
    var onSnapshot: (@MainActor (ControlRuntimeSnapshot) -> Void)?
    /// A diagnosable failure of the observation itself: a page read that failed, a capture over its bound. Once per episode and kind.
    var onFailure: (@MainActor (String) -> Void)?

    private var pull: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var refreshAgain = false
    private var failingKinds: Set<ControlCollectionKind> = []
    private var settlements = SettlementTable()
    private var ended = false

    init(
        control: any RuntimeClient, presentation: RuntimePresentationAdapter, incarnation: ControlHostIncarnation,
        rowBudget: ControlRowBudget,
        relookupInterval: Duration = RuntimeObserver.pullWindow
    ) {
        self.control = control
        self.presentation = presentation
        self.incarnation = incarnation
        self.rowBudget = rowBudget
        self.relookupInterval = relookupInterval
    }

    func start() {
        guard pull == nil, !ended else { return }
        pull = Task { @MainActor [weak self] in await self?.run() }
    }

    /// Stops observing, after the runtime's quit. Nothing is claimed any more, and every caller is resolved unsettled.
    func stop() {
        ended = true
        pull?.cancel()
        pull = nil
        refresh?.cancel()
        refresh = nil
        presentation.observationEnded()
        settlements.resolveAll()
    }

    /// The settlement of `operation`: the outcome the stream or a lookup reports, or nil when observation ended first, the caller was
    /// cancelled, the caller bound was reached, or the host cannot say. Nil is not proof that nothing ran.
    func settlement(of operation: ControlOperationID) async -> ControlOperationOutcome? {
        guard !ended, settlements.admit(operation) else { return nil }
        defer { settlements.release(operation) }
        if let outcome = settlements.finished(operation) { return outcome }
        if case .finished(let outcome)? = await lookup(operation) {
            settlements.record(operation, outcome)
            return outcome
        }
        if let outcome = settlements.finished(operation) { return outcome }
        guard !ended, !Task.isCancelled else { return nil }
        let token = UUID()
        // A settlement frame can precede this watch, and a lookup can be refused busy. So the wait asks again, operation by operation,
        // once per pull window. An operation the host cannot name, or lookups that fail `relookupRounds` times in a row, end this caller's
        // wait unsettled. A pending answer is the host's own word that the operation is still running: it is waited for, never guessed,
        // and it ends when the host settles it (a private update within its own budget), the caller is cancelled or the observation ends.
        let interval = relookupInterval
        let relookup = Task { @MainActor [weak self] in
            var failedInARow = 0
            while failedInARow < Self.relookupRounds {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                switch await self.lookup(operation) {
                case .finished(let outcome)?:
                    self.settlements.record(operation, outcome)
                    return
                case .unknown?:
                    self.settlements.cancel(operation, token: token)
                    return
                case .pending?:
                    failedInARow = 0
                case nil:
                    failedInARow += 1
                }
            }
            self?.settlements.cancel(operation, token: token)
        }
        defer { relookup.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                settlements.wait(operation, token: token, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settlements.cancel(operation, token: token) }
        }
    }

    // MARK: - The pull loop

    private func run() async {
        var backoff = Self.resubscribeFloor
        while !Task.isCancelled, !ended {
            let stream: RuntimeSubscription
            do {
                stream = try await control.subscribe(.live, deadline: .after(Self.pullWindow, from: .now))
            } catch RuntimeClientError.streamClosed(.hostShutdown) {
                return finish()
            } catch {
                presentation.observationLost()
                guard await sleep(backoff) else { return }
                backoff = min(backoff * 2, Self.resubscribeCeiling)
                continue
            }
            backoff = Self.resubscribeFloor
            switch await read(stream) {
            case .shutdown:
                return finish()
            case .lost:
                presentation.observationLost()
                guard await sleep(backoff) else { return }
            case .cancelled:
                return
            }
        }
    }

    private enum StreamEnd {
        case lost
        case shutdown
        case cancelled
    }

    private func read(_ stream: RuntimeSubscription) async -> StreamEnd {
        defer { stream.cancel() }
        while !Task.isCancelled {
            let frame: ControlRuntimeFrame
            do {
                frame = try await stream.next(.after(Self.pullWindow, from: .now))
            } catch RuntimeClientError.readAborted(.deadlineExpired) {
                continue
            } catch RuntimeClientError.readAborted(.cancelled) {
                return .cancelled
            } catch RuntimeClientError.streamClosed(.hostShutdown) {
                return .shutdown
            } catch {
                return .lost
            }
            switch frame {
            case .baseline(let baseline):
                incarnation = baseline.incarnation
                apply(baseline.snapshot)
                await lookUpWaiting()
            case .snapshot(let snapshot):
                apply(snapshot)
            case .events(let batch):
                let known = batch.events.compactMap { record -> ControlRuntimeEvent? in
                    if case .known(let event) = record { return event }
                    return nil
                }
                if !known.isEmpty { onEvents?(known) }
            case .operationFinished(let done):
                settlements.record(done.operationID, done.outcome)
            case .replayCaughtUp:
                continue
            case .end(let end):
                return end.reason == .hostShutdown ? .shutdown : .lost
            }
        }
        return .cancelled
    }

    private func apply(_ snapshot: ControlRuntimeSnapshot) {
        presentation.apply(snapshot: snapshot)
        onSnapshot?(snapshot)
        scheduleRefresh()
    }

    private func finish() {
        ended = true
        presentation.observationEnded()
        settlements.resolveAll()
    }

    /// Waits `duration`; false when the task was cancelled.
    private func sleep(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }

    /// After a baseline, every awaited operation is looked up once: a settlement published while no stream was open is not missed. An
    /// operation the host cannot name is resolved unsettled.
    private func lookUpWaiting() async {
        for operation in settlements.waitingOperations {
            switch await lookup(operation) {
            case .finished(let outcome)?: settlements.record(operation, outcome)
            case .unknown?: settlements.resolveUnsettled(operation)
            case .pending?, nil: continue
            }
        }
    }

    private func lookup(_ operation: ControlOperationID) async -> ControlOperationLookup? {
        do {
            return try await control.outcome(of: operation, expectedIncarnation: incarnation, deadline: .after(Self.pullWindow, from: .now))
        } catch {
            return nil
        }
    }

    // MARK: - Collections

    /// One refresh task at a time; a snapshot that arrives while it runs asks for one more pass after it.
    func scheduleRefresh() {
        guard !presentation.collectionsToRefresh.isEmpty else { return }
        guard refresh == nil else {
            refreshAgain = true
            return
        }
        refresh = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                for kind in self.presentation.collectionsToRefresh {
                    guard !Task.isCancelled else { break }
                    await self.read(kind)
                }
            } while self.refreshAgain && !Task.isCancelled
            self.refresh = nil
        }
    }

    /// Every page of the current revision of `kind`, assembled within the capture bound and applied only if that revision is still the
    /// snapshot's when the last page arrives. A newer revision asks for one more pass; a failure withholds the rows and is reported.
    private func read(_ kind: ControlCollectionKind) async {
        let incarnation = self.incarnation
        var cursor: ControlPageCursor?
        var collector = PageCollector(kind: kind, budget: rowBudget)
        while true {
            let reply: ControlPageReply
            do {
                reply = try await control.readPage(
                    ControlPageRequest(expectedIncarnation: incarnation, collection: kind, cursor: cursor),
                    deadline: .after(Self.pullWindow, from: .now)
                )
            } catch {
                return failed(kind, "the \(kind.rawValue) list could not be read (\(error))")
            }
            switch collector.add(reply) {
            case .next(let next):
                cursor = next
            case .complete(let rows, let revision):
                guard presentation.apply(rows: rows, revision: revision, incarnation: incarnation) else {
                    refreshAgain = true
                    return
                }
                failingKinds.remove(kind)
                return
            case .stale:
                // The rows belong to an older revision: none is shown as current, and the newer one is read next.
                presentation.rowsNotCurrent(kind)
                refreshAgain = true
                return
            case .unavailable(let total):
                presentation.rowsUnavailable(kind, knownTotal: total)
                return
            case .overBudget:
                presentation.rowsUnavailable(kind, knownTotal: nil)
                return failed(kind, "the \(kind.rawValue) list is larger than one complete capture may hold")
            case .inconsistent:
                presentation.rowsNotCurrent(kind)
                return failed(kind, "the \(kind.rawValue) pages did not form one revision")
            }
        }
    }

    private func failed(_ kind: ControlCollectionKind, _ reason: String) {
        presentation.rowsNotCurrent(kind)
        if failingKinds.insert(kind).inserted { onFailure?(reason) }
    }
}

/// The callers waiting for settlements. One record per operation, shared by every caller of a joined operation and released by the last;
/// at most `RuntimeObserver.maximumCallers` callers at once, each holding at most one continuation.
private struct SettlementTable {
    private struct Record {
        var callers = 0
        var outcome: ControlOperationOutcome?
        var waiting: [UUID: CheckedContinuation<ControlOperationOutcome?, Never>] = [:]
    }

    private var records: [ControlOperationID: Record] = [:]
    private var callers = 0

    var waitingOperations: [ControlOperationID] {
        records.filter { !$0.value.waiting.isEmpty }.map(\.key)
    }

    /// Admits one caller of `operation`; false at the bound.
    mutating func admit(_ operation: ControlOperationID) -> Bool {
        guard callers < RuntimeObserver.maximumCallers else { return false }
        callers += 1
        records[operation, default: Record()].callers += 1
        return true
    }

    mutating func release(_ operation: ControlOperationID) {
        callers -= 1
        guard var record = records[operation] else { return }
        record.callers -= 1
        records[operation] = record.callers == 0 ? nil : record
    }

    func finished(_ operation: ControlOperationID) -> ControlOperationOutcome? {
        records[operation]?.outcome
    }

    /// An outcome for an operation someone waits for: kept for its other callers and handed to every one waiting.
    mutating func record(_ operation: ControlOperationID, _ outcome: ControlOperationOutcome) {
        guard var record = records[operation] else { return }
        record.outcome = outcome
        let waiting = record.waiting
        record.waiting = [:]
        records[operation] = record
        for continuation in waiting.values { continuation.resume(returning: outcome) }
    }

    mutating func wait(
        _ operation: ControlOperationID, token: UUID, _ continuation: CheckedContinuation<ControlOperationOutcome?, Never>
    ) {
        guard records[operation] != nil else { return continuation.resume(returning: nil) }
        if let outcome = records[operation]?.outcome { return continuation.resume(returning: outcome) }
        records[operation]?.waiting[token] = continuation
    }

    /// A caller's task was cancelled: its own wait ends unsettled; the others keep waiting.
    mutating func cancel(_ operation: ControlOperationID, token: UUID) {
        records[operation]?.waiting.removeValue(forKey: token)?.resume(returning: nil)
    }

    mutating func resolveUnsettled(_ operation: ControlOperationID) {
        guard let waiting = records[operation]?.waiting else { return }
        records[operation]?.waiting = [:]
        for continuation in waiting.values { continuation.resume(returning: nil) }
    }

    mutating func resolveAll() {
        for operation in Array(records.keys) { resolveUnsettled(operation) }
    }
}

/// The pages of one revision of one collection, collected in order within one complete capture's bound.
struct PageCollector {
    enum Step {
        case next(ControlPageCursor)
        case complete(ControlProjectedRows, ControlCollectionRevision)
        /// The host answered with rows of a revision it already superseded.
        case stale
        /// The host could not serve the collection whole; its exact total when it knows one.
        case unavailable(ControlCount?)
        /// The pages hold more rows or encoded bytes than one capture may.
        case overBudget
        /// A page of another kind, revision, total or offset than the pages before it.
        case inconsistent
    }

    let kind: ControlCollectionKind
    private let budget: ControlRowBudget
    private var revision: ControlCollectionRevision?
    private var total: ControlCount?
    private var count = 0
    private var bytes = 0
    private var connections: [ControlConnectionRow] = []
    private var upstreams: [ControlUpstreamRow] = []
    private var tunnels: [ControlTunnelBindingRow] = []
    private var hosts: [ControlTunnelDNSHostRow] = []

    init(kind: ControlCollectionKind, budget: ControlRowBudget) {
        self.kind = kind
        self.budget = budget
    }

    mutating func add(_ reply: ControlPageReply) -> Step {
        guard reply.collection == kind else { return .inconsistent }
        switch reply {
        case .activeConnections(let page):
            return add(page) { $0.connections += $1 }
        case .upstreamHealth(let page):
            return add(page) { $0.upstreams += $1 }
        case .tunnelBindings(let page):
            return add(page) { $0.tunnels += $1 }
        case .tunnelDNSHosts(let page):
            return add(page) { $0.hosts += $1 }
        case .unavailable(_, _, let knownTotal):
            return .unavailable(knownTotal)
        }
    }

    /// Checks the page against the ones before it, then measures its rows within what the capture has left, before keeping them.
    private mutating func add<Row>(_ page: ControlCollectionPage<Row>, _ append: (inout PageCollector, [Row]) -> Void) -> Step {
        switch page.status {
        case .current: break
        case .staleRevision: return .stale
        case .expiredRevision, .unavailable: return .inconsistent
        }
        if let revision, revision != page.revision { return .inconsistent }
        if let total, total != page.totalCount { return .inconsistent }
        guard page.offset.rawValue == count else { return .inconsistent }
        guard page.totalCount.rawValue <= budget.maxRows else { return .overBudget }
        revision = page.revision
        total = page.totalCount
        let remaining = ControlRowBudget(maxRows: budget.maxRows - count, maxBytes: budget.maxBytes - bytes)
        switch remaining.measure(page.rows, { $0 }) {
        case .complete(let rows, let measured):
            append(&self, rows)
            count += rows.count
            bytes += measured
        case .overBudget:
            return .overBudget
        case .internalFailure:
            return .inconsistent
        }
        if let next = page.nextCursor {
            // Each page moves the cursor forward, so a bounded total ends the read.
            guard next.offset.rawValue == count, count > page.offset.rawValue else { return .inconsistent }
            return .next(next)
        }
        guard count == page.totalCount.rawValue else { return .inconsistent }
        return .complete(rows, page.revision)
    }

    private var rows: ControlProjectedRows {
        switch kind {
        case .activeConnections: .activeConnections(connections)
        case .upstreamHealth: .upstreamHealth(upstreams)
        case .tunnelBindings: .tunnelBindings(tunnels)
        case .tunnelDNSHosts: .tunnelDNSHosts(hosts)
        }
    }
}
