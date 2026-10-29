// SPDX-License-Identifier: Apache-2.0
import Combine
import NIOConcurrencyHelpers
import XCTest
import ConduitShared
@testable import Conduit
@testable import ConduitRuntime
import ProxyControlBridge
@testable import ProxyKernel

/// Wire snapshots for the adapter, projected from kernel fixtures through the actual Bridge projection, as the host projects them.
enum WireSnapshotFixture {
    static let incarnation = ControlHostIncarnation(rawValue: UUID())

    static func revision(_ value: Int) -> ControlCollectionRevision {
        ControlCollectionRevision(rawValue: value)!
    }

    /// Every collection captured at `revision`, as the host's snapshots carry them.
    static func revisions(_ value: Int) -> ControlCollectionRevisions {
        ControlCollectionRevisions(
            activeConnections: revision(value), upstreamHealth: revision(value),
            tunnelBindings: revision(value), tunnelDNSHosts: revision(value)
        )
    }

    static func snapshot(
        _ kernel: ProxyOrchestratorSnapshot,
        collections: ControlCollectionRevisions = revisions(1),
        incarnation: ControlHostIncarnation = incarnation,
        presentation: Int = 0
    ) throws -> ControlRuntimeSnapshot {
        let zero = ControlLifecycleRevision(rawValue: 0)!
        let stamp = ControlRuntimeStamp(
            incarnation: incarnation, presentationRevision: ControlPresentationRevision(rawValue: presentation)!,
            configRevision: ControlConfigRevision(rawValue: 0)!, lifecycleRevision: zero,
            modules: ControlModuleRevisions(proxy: zero, dns: zero, tunnels: zero)
        )
        return try RuntimeSnapshotControlProjection.snapshot(kernel, stamp: stamp, profileName: "", collectionRevisions: collections)
    }

    static func connectionRows(_ kernel: ProxyOrchestratorSnapshot) throws -> ControlProjectedRows {
        guard case .rows(let rows, _) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel, within: ControlRowBudget(maxRows: 10_000, maxBytes: 4_194_304)
        ) else { throw RuntimeServiceProfileError.internalFailure }
        return rows
    }
}

@MainActor
final class AppStatePresentationAdapterTests: XCTestCase {

    func testASnapshotSetsScalarsAndCountersAtOnce() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.state = .running
        kernel.runtimeStatus.activeUpstream = "proxy.example.com:8080"
        kernel.dnsRunState = .running
        kernel.bindings.proxyHost = "127.0.0.1"
        kernel.bindings.proxyPort = 3128
        kernel.runtimeStatus.metrics.requestsHandled = 42
        kernel.runtimeStatus.metrics.failedRequests = 3
        kernel.runtimeStatus.metrics.vpnFlapCount = 2
        kernel.runtimeStatus.metrics.successfulRecoveries = 5
        kernel.runtimeStatus.metrics.vpnFlapTotalDuration = 4
        kernel.runtimeStatus.metrics.lastVpnFlapAt = Date(timeIntervalSince1970: 1_700_000_000)
        kernel.runtimeStatus.metrics.streamsPreservedAcrossFlaps = 12
        kernel.dnsQueryCount = 100
        kernel.dnsDoHFallbackCount = 6
        kernel.dnsCacheHitCount = 70
        kernel.tunnelActiveCount = 1
        kernel.tunnelSessionCount = 9

        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))

        XCTAssertTrue(adapter.isLive)
        XCTAssertEqual(adapter.runtimeStatus.state, .running)
        XCTAssertEqual(adapter.runtimeStatus.activeUpstream, "proxy.example.com:8080")
        XCTAssertEqual(adapter.dnsRunState, .running)
        XCTAssertEqual(adapter.bindings.proxyPort, 3128)
        XCTAssertEqual(adapter.requestsHandled, 42)
        XCTAssertEqual(adapter.failedRequests, 3)
        XCTAssertEqual(adapter.vpnFlapCount, 2)
        XCTAssertEqual(adapter.dnsQueryCount, 100)
        // The counters the Overview and the flap row show, each from its own snapshot field.
        XCTAssertEqual(adapter.successfulRecoveries, 5)
        XCTAssertEqual(adapter.dnsDoHFallbackCount, 6)
        XCTAssertEqual(adapter.dnsCacheHitCount, 70)
        XCTAssertEqual(adapter.tunnelActiveCount, 1)
        XCTAssertEqual(adapter.tunnelSessionCount, 9)
        XCTAssertEqual(adapter.vpnFlapTotalDuration, 4)
        XCTAssertEqual(adapter.lastVpnFlapAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(adapter.streamsPreservedAcrossFlaps, 12)
    }

    func testAnIdenticalSnapshotPublishesNothing() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.state = .running
        let snapshot = try WireSnapshotFixture.snapshot(kernel)
        adapter.apply(snapshot: snapshot)
        var publishes = 0
        let cancellable = adapter.objectWillChange.sink { _ in publishes += 1 }
        adapter.apply(snapshot: snapshot)
        XCTAssertEqual(publishes, 0)
        _ = cancellable
    }

    /// A lost stream clears every current claim. Nothing reads as stopped: the views say the status is unavailable.
    func testLosingTheObservationClearsEveryClaim() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = RuntimeServiceProfileKernels.typical(connections: 3)
        kernel.runtimeStatus.state = .running
        kernel.bindings.proxyPort = 3128
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertTrue(adapter.apply(rows: try WireSnapshotFixture.connectionRows(kernel), revision: WireSnapshotFixture.revision(1),
                                    incarnation: WireSnapshotFixture.incarnation))
        XCTAssertEqual(adapter.activeConnections.count, 3)

        adapter.observationLost()

        XCTAssertFalse(adapter.isLive)
        XCTAssertEqual(adapter.runtimeStatus, .unobserved)
        XCTAssertNil(adapter.bindings.proxyPort)
        XCTAssertEqual(adapter.activeConnectionCount, 0)
        XCTAssertTrue(adapter.activeConnections.isEmpty)
        XCTAssertNil(adapter.stamp, "no command can be built from a lost observation")
        XCTAssertNotNil(RuntimeStatusText.unavailable(phase: .ready, observation: adapter.observation))
        adapter.observationEnded()
        adapter.observationLost()
        XCTAssertEqual(adapter.observation, .ended, "a shut-down runtime is not reported as reconnecting")
    }

    /// The host's DNS health observation arrives as the snapshot's error; a later snapshot without it clears it. No app-side override.
    func testTheHostsDNSHealthErrorIsShownAsTheSnapshotCarriesIt() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = ProxyOrchestratorSnapshot()
        kernel.dnsRunState = .running
        kernel.dnsError = "DNS pipeline unresponsive"
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertEqual(adapter.dnsError, "DNS pipeline unresponsive")
        XCTAssertEqual(adapter.dnsRunState, .running)
        kernel.dnsError = nil
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertNil(adapter.dnsError)
    }

    func testResetZeroesDisplayedCountersAndDeltasResume() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.metrics.requestsHandled = 100
        kernel.runtimeStatus.metrics.failedRequests = 40
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.resetActivityCounters()
        XCTAssertEqual(adapter.requestsHandled, 0)
        XCTAssertEqual(adapter.failedRequests, 0)
        kernel.runtimeStatus.metrics.requestsHandled = 130
        kernel.runtimeStatus.metrics.failedRequests = 41
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertEqual(adapter.requestsHandled, 30, "the display shows the delta since the reset")
        XCTAssertEqual(adapter.failedRequests, 1)
    }

    func testTheResetBaselineClearsWhenTheRawCounterRestarts() throws {
        let adapter = RuntimePresentationAdapter()
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.metrics.requestsHandled = 500
        kernel.runtimeStatus.metrics.failedRequests = 50
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.resetActivityCounters()
        kernel.runtimeStatus.metrics.requestsHandled = 10
        kernel.runtimeStatus.metrics.failedRequests = 2
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertEqual(adapter.requestsHandled, 10)
        XCTAssertEqual(adapter.failedRequests, 2)
    }

    // MARK: Collections

    /// Rows are taken only for the revision the latest snapshot names; an older or newer revision changes nothing.
    func testRowsOfAnotherRevisionThanTheSnapshotsAreNotTaken() throws {
        let adapter = RuntimePresentationAdapter()
        let kernel = RuntimeServiceProfileKernels.typical(connections: 2)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel, collections: WireSnapshotFixture.revisions(2)))
        let rows = try WireSnapshotFixture.connectionRows(kernel)
        XCTAssertFalse(adapter.apply(rows: rows, revision: WireSnapshotFixture.revision(1), incarnation: WireSnapshotFixture.incarnation))
        XCTAssertFalse(adapter.apply(rows: rows, revision: WireSnapshotFixture.revision(3), incarnation: WireSnapshotFixture.incarnation))
        XCTAssertFalse(adapter.apply(rows: rows, revision: WireSnapshotFixture.revision(2), incarnation: ControlHostIncarnation(rawValue: UUID())))
        XCTAssertTrue(adapter.activeConnections.isEmpty)
        XCTAssertTrue(adapter.apply(rows: rows, revision: WireSnapshotFixture.revision(2), incarnation: WireSnapshotFixture.incarnation))
        XCTAssertEqual(adapter.rows(.activeConnections), .current)
        XCTAssertEqual(adapter.activeConnections.count, 2)
    }

    /// A newer revision marks the held rows stale; a list the host cannot capture whole drops its rows and keeps the exact count.
    func testANewerRevisionMarksRowsStaleAndAnUnavailableListKeepsItsExactCount() throws {
        let adapter = RuntimePresentationAdapter()
        let kernel = RuntimeServiceProfileKernels.typical(connections: 3)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.apply(rows: try WireSnapshotFixture.connectionRows(kernel), revision: WireSnapshotFixture.revision(1),
                      incarnation: WireSnapshotFixture.incarnation)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel, collections: WireSnapshotFixture.revisions(2)))
        XCTAssertEqual(adapter.rows(.activeConnections), .stale)
        XCTAssertEqual(adapter.activeConnections.count, 3, "stale rows are shown as stale, not dropped")

        let larger = RuntimeServiceProfileKernels.typical(connections: 5)
        var uncaptured = WireSnapshotFixture.revisions(3)
        uncaptured.activeConnections = nil
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(larger, collections: uncaptured))
        XCTAssertEqual(adapter.rows(.activeConnections), .unavailable)
        XCTAssertTrue(adapter.activeConnections.isEmpty)
        XCTAssertEqual(adapter.activeConnectionCount, 5, "the exact total stays; the connections are still served")
    }

    func testAReadFailureLeavesNoRowsClaimedCurrent() throws {
        let adapter = RuntimePresentationAdapter()
        let kernel = RuntimeServiceProfileKernels.typical(connections: 1)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.apply(rows: try WireSnapshotFixture.connectionRows(kernel), revision: WireSnapshotFixture.revision(1),
                      incarnation: WireSnapshotFixture.incarnation)
        adapter.rowsNotCurrent(.activeConnections)
        XCTAssertEqual(adapter.rows(.activeConnections), .stale)
        adapter.showing(.activeConnections, true)
        XCTAssertTrue(adapter.collectionsToRefresh.contains(.activeConnections), "the failed list is read again while it is shown")
    }

    /// A list the host answered unavailable at revision R stays shown unavailable through later snapshots at R and is not read again,
    /// rather than reading "Reading the list…" for good; a newer revision, or showing the list again, reads it.
    func testAPageReadAnsweredUnavailableStaysUnavailableAtItsRevision() throws {
        let adapter = RuntimePresentationAdapter()
        let kernel = RuntimeServiceProfileKernels.typical(connections: 2)
        adapter.showing(.activeConnections, true)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.rowsUnavailable(.activeConnections, knownTotal: try ControlCount(2))
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        XCTAssertEqual(adapter.rows(.activeConnections), .unavailable, "the same revision keeps its unavailable answer")
        XCTAssertFalse(adapter.collectionsToRefresh.contains(.activeConnections), "and is not read again")
        adapter.showing(.activeConnections, false)
        adapter.showing(.activeConnections, true)
        XCTAssertTrue(adapter.collectionsToRefresh.contains(.activeConnections), "a list shown again is read again")
        adapter.rowsUnavailable(.activeConnections, knownTotal: nil)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel, collections: WireSnapshotFixture.revisions(2)))
        XCTAssertEqual(adapter.rows(.activeConnections), .notRead)
        XCTAssertTrue(adapter.collectionsToRefresh.contains(.activeConnections), "a newer revision is read")
    }

    func testANewIncarnationDropsEveryRow() throws {
        let adapter = RuntimePresentationAdapter()
        let kernel = RuntimeServiceProfileKernels.typical(connections: 2)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel))
        adapter.apply(rows: try WireSnapshotFixture.connectionRows(kernel), revision: WireSnapshotFixture.revision(1),
                      incarnation: WireSnapshotFixture.incarnation)
        adapter.apply(snapshot: try WireSnapshotFixture.snapshot(kernel, incarnation: ControlHostIncarnation(rawValue: UUID())))
        XCTAssertTrue(adapter.activeConnections.isEmpty)
        XCTAssertEqual(adapter.rows(.activeConnections), .notRead)
    }
}

/// The pages of one capture, assembled within the service's own count and byte bound.
final class AppStatePageCollectorTests: XCTestCase {
    private let incarnation = WireSnapshotFixture.incarnation

    private func rows(_ count: Int) throws -> [ControlConnectionRow] {
        guard case .activeConnections(let rows) = try WireSnapshotFixture.connectionRows(RuntimeServiceProfileKernels.typical(connections: count))
        else { throw RuntimeServiceProfileError.wrongCollection }
        return rows
    }

    private func page(
        _ rows: [ControlConnectionRow], offset: Int, total: Int, revision: Int = 1, next: Int? = nil, status: ControlPageStatus = .current
    ) throws -> ControlPageReply {
        let cursor = try next.map { ControlPageCursor(revision: WireSnapshotFixture.revision(revision), offset: try ControlCount($0)) }
        return .activeConnections(try ControlCollectionPage(
            incarnation: incarnation, revision: WireSnapshotFixture.revision(revision), offset: try ControlCount(offset),
            totalCount: try ControlCount(total), rows: rows, nextCursor: cursor, status: status
        ))
    }

    private var budget: ControlRowBudget { ControlRowBudget(maxRows: 10_000, maxBytes: 4_194_304) }

    func testPagesOfOneRevisionComplete() throws {
        let all = try rows(4)
        var collector = PageCollector(kind: .activeConnections, budget: budget)
        guard case .next = collector.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2)) else { return XCTFail("a next page") }
        guard case .complete(.activeConnections(let collected), let revision) = collector.add(try page(Array(all[2...]), offset: 2, total: 4))
        else { return XCTFail("the capture completes") }
        XCTAssertEqual(collected, all)
        XCTAssertEqual(revision, WireSnapshotFixture.revision(1))
    }

    func testAPageOfAnotherRevisionOrOffsetIsInconsistent() throws {
        let all = try rows(4)
        var moved = PageCollector(kind: .activeConnections, budget: budget)
        _ = moved.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2))
        guard case .inconsistent = moved.add(try page(Array(all[2...]), offset: 2, total: 4, revision: 2)) else {
            return XCTFail("a page of a newer revision is not appended")
        }
        var gapped = PageCollector(kind: .activeConnections, budget: budget)
        _ = gapped.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2))
        guard case .inconsistent = gapped.add(try page(Array(all[3...]), offset: 3, total: 4)) else {
            return XCTFail("a gap in the offsets is refused")
        }
    }

    func testAStalePageIsNotTakenAsCurrent() throws {
        var collector = PageCollector(kind: .activeConnections, budget: budget)
        guard case .stale = collector.add(try page(try rows(1), offset: 0, total: 1, status: .staleRevision(current: WireSnapshotFixture.revision(2))))
        else { return XCTFail("a stale page is reported stale") }
    }

    /// A capture past the count or the byte bound is refused whole before its rows are kept.
    func testACapturePastItsCountOrByteBoundIsRefusedWhole() throws {
        let all = try rows(3)
        var byCount = PageCollector(kind: .activeConnections, budget: ControlRowBudget(maxRows: 2, maxBytes: 4_194_304))
        guard case .overBudget = byCount.add(try page(all, offset: 0, total: 3)) else { return XCTFail("the count bound refuses") }
        var byBytes = PageCollector(kind: .activeConnections, budget: ControlRowBudget(maxRows: 10, maxBytes: 64))
        guard case .overBudget = byBytes.add(try page(all, offset: 0, total: 3)) else { return XCTFail("the byte bound refuses") }
    }

    /// The byte bound is the whole capture's, across pages: each page is measured against what the earlier pages left, before it is
    /// kept. A capture of exactly the bound completes; one byte less refuses at the second page, though either page alone fits.
    func testTheByteBoundIsCumulativeAcrossPagesAndExactAtItsEdge() throws {
        let all = try rows(4)
        func cost(_ rows: ArraySlice<ControlConnectionRow>) throws -> Int {
            guard case .complete(_, let measured) = budget.measure(Array(rows), { $0 }) else { throw RuntimeServiceProfileError.internalFailure }
            return measured
        }
        let first = try cost(all[0..<2])
        let second = try cost(all[2...])
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, 0)
        let exact = ControlRowBudget(maxRows: 4, maxBytes: first + second)
        var fits = PageCollector(kind: .activeConnections, budget: exact)
        guard case .next = fits.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2)) else { return XCTFail("the first page fits") }
        guard case .complete = fits.add(try page(Array(all[2...]), offset: 2, total: 4)) else { return XCTFail("exactly the bound completes") }

        let short = ControlRowBudget(maxRows: 4, maxBytes: first + second - 1)
        XCTAssertLessThan(max(first, second), short.maxBytes, "either page alone fits the bound")
        var over = PageCollector(kind: .activeConnections, budget: short)
        guard case .next = over.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2)) else { return XCTFail("the first page fits") }
        guard case .overBudget = over.add(try page(Array(all[2...]), offset: 2, total: 4)) else {
            return XCTFail("the second page is measured against what the first left")
        }
        // The count bound is the whole capture's too: a total past it is refused at the first page.
        var counted = PageCollector(kind: .activeConnections, budget: ControlRowBudget(maxRows: 3, maxBytes: 4_194_304))
        guard case .overBudget = counted.add(try page(Array(all[0..<2]), offset: 0, total: 4, next: 2)) else {
            return XCTFail("a total past the count bound is refused before any row is kept")
        }
    }

    func testAnUnavailableReplyKeepsItsKnownTotal() throws {
        var collector = PageCollector(kind: .activeConnections, budget: budget)
        guard case .unavailable(let total) = collector.add(.unavailable(.activeConnections, .retentionBudgetExceeded, knownTotal: try ControlCount(12_000)))
        else { return XCTFail("unavailable") }
        XCTAssertEqual(total?.rawValue, 12_000)
    }
}

/// The app's whole collection path at the shipping scale: the actual `RuntimeObserver`, `PageCollector` and `RuntimePresentationAdapter`
/// over the actual framed client, in-memory transport and service core, under the one shipping profile, with the production projection
/// of 10,000 typical connection rows. The structural assertions always run and assert no timing or app memory figure. Under the existing
/// `CONDUIT_RUNTIME_RESOURCE_PROBES=1` gate the test also logs observations only (`APPSTATE-COLLECTION` lines): per-pass wall time, a
/// main-actor heartbeat's lateness, which includes the OS timer's and the scheduler's own delay and so is not an exact measure of main-actor
/// unavailability, one synchronous `apply(rows:)`, and the process's peak RSS and malloc in use, which are test-process samples, not
/// a RAM bound.
@MainActor
final class AppStateCollectionCaptureCostTests: XCTestCase {
    private static let rows = 10_000
    private static let passes = 4

    /// The fake owner over `kernel` and the production service and transport over it, built on the owner. Each connection capture the
    /// service asks the owner for is counted.
    @RuntimeActor
    private static func service(
        snapshot: ControlRuntimeSnapshot, kernel: ProxyOrchestratorSnapshot, limits: RuntimeServiceLimits,
        countingConnectionProjections projections: NIOLockedValueBox<Int>
    ) -> (FakeCommandOwner, RuntimeServiceCore, RuntimeInMemoryTransport) {
        let owner = FakeCommandOwner(incarnation: snapshot.stamp.incarnation, snapshot: snapshot)
        owner.projectionOverride = { kind, budget in
            if kind == .activeConnections { projections.withLockedValue { $0 += 1 } }
            return RuntimeSnapshotControlProjection.projectRows(kind, from: kernel, within: budget)
        }
        let core = RuntimeServiceCore(
            owner: owner, limits: limits, timing: .system, scheduling: TaskOwnerScheduling(),
            makeOperationID: { ControlOperationID(rawValue: UUID()) }
        )
        return (owner, core, RuntimeInMemoryTransport(core: core, limits: limits, timing: .system, scheduling: TaskOwnerScheduling()))
    }

    /// A new revision of the owner's snapshot, reported to the service in the same owner turn.
    @RuntimeActor
    private static func advance(_ owner: FakeCommandOwner, _ core: RuntimeServiceCore, to snapshot: ControlRuntimeSnapshot) {
        owner.snapshotValue = snapshot
        core.ownerDidChange()
    }

    func testATenThousandRowCaptureThroughTheAppObserverIsWholeAndHostCustodyStaysBounded() async throws {
        let probes = ProcessInfo.processInfo.environment["CONDUIT_RUNTIME_RESOURCE_PROBES"] == "1"
        var samples: [RuntimeServiceProfileResourceSample] = []
        func sample(_ stage: String) throws { if probes { samples.append(try RuntimeServiceProfileResource.sample(stage)) } }
        try sample("before-composition")

        let profile = try RuntimeServiceProfile.inProcessApp()
        let incarnation = RuntimeServiceFixtures.incarnation(1)
        let kernel = RuntimeServiceProfileKernels.typical(connections: Self.rows)
        let reference = try RuntimeServiceProfileKernels.connectionRows(
            kernel, maxRows: profile.limits.collectionRowCapacity, maxBytes: profile.limits.collectionByteCapacity
        )
        XCTAssertEqual(reference.rows.count, Self.rows)
        try sample("kernel-built")

        // The host side is the owner's; the app's observer and adapter below stay on the main actor.
        let connectionProjections = NIOLockedValueBox(0)
        let (owner, core, transport) = await Self.service(
            snapshot: try WireSnapshotFixture.snapshot(kernel, incarnation: incarnation), kernel: kernel, limits: profile.limits,
            countingConnectionProjections: connectionProjections
        )
        let client = try makeFramedRuntimeClient(
            transport: transport, limits: profile.clientFrameLimits, wireBudgetCap: profile.wireBudgetCap
        )
        let adapter = RuntimePresentationAdapter()
        adapter.showing(.activeConnections, true)
        let observer = RuntimeObserver(
            control: client, presentation: adapter, incarnation: incarnation, rowBudget: profile.collectionRowBudget
        )
        var failures: [String] = []
        observer.onFailure = { failures.append($0) }

        // The heartbeat runs only when measuring.
        var lateness: [Duration] = []
        let heartbeat: Task<Void, Never>? = probes ? Task { @MainActor in
            while !Task.isCancelled {
                let asked = ContinuousClock.now
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                lateness.append(asked.duration(to: .now) - .milliseconds(1))
            }
        } : nil

        /// Bounded: a pass that never completes fails here instead of hanging the suite.
        func passCompleted(_ pass: Int) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline {
                if connectionProjections.withLockedValue({ $0 }) == pass, adapter.rows(.activeConnections) == .current { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }

        var passTimes: [Duration] = []
        var began = ContinuousClock.now
        observer.start()
        let first = await passCompleted(1)
        passTimes.append(began.duration(to: .now))
        XCTAssertTrue(first, "the first capture completed")
        XCTAssertEqual(adapter.activeConnections.count, Self.rows)
        XCTAssertEqual(adapter.activeConnectionCount, Self.rows)
        XCTAssertEqual(adapter.activeConnections.first?.id, ConnectionDisplay(reference.rows[0]).id)
        XCTAssertEqual(adapter.activeConnections.last?.id, ConnectionDisplay(reference.rows[Self.rows - 1]).id)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(connectionProjections.withLockedValue { $0 }, 1, "one host capture per revision; every page came from the retained rows")
        let afterFirst = await core.collectionRetention(.activeConnections)
        XCTAssertEqual(afterFirst.rowSets, 1)
        XCTAssertEqual(afterFirst.retainedBytes, reference.encodedBytes)
        XCTAssertLessThanOrEqual(reference.encodedBytes, profile.limits.collectionByteCapacity)
        try sample("after-pass-1")

        for pass in 2...Self.passes {
            began = ContinuousClock.now
            // A new revision of the list is a new presentation, as the host stamps it.
            await Self.advance(owner, core, to: try WireSnapshotFixture.snapshot(
                kernel, collections: WireSnapshotFixture.revisions(pass), incarnation: incarnation, presentation: pass - 1
            ))
            let completed = await passCompleted(pass)
            passTimes.append(began.duration(to: .now))
            XCTAssertTrue(completed, "capture \(pass) completed")
        }
        XCTAssertEqual(connectionProjections.withLockedValue { $0 }, Self.passes)
        let retention = await core.collectionRetention(.activeConnections)
        XCTAssertLessThanOrEqual(retention.rowSets, profile.limits.collectionRowRevisionsPerKind)
        XCTAssertLessThanOrEqual(retention.retainedBytes, 2 * reference.encodedBytes)
        XCTAssertLessThanOrEqual(retention.retainedBytes, profile.limits.collectionRetainedByteCapacity)
        XCTAssertEqual(adapter.activeConnections.count, Self.rows)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        try sample("after-pass-\(Self.passes)")

        heartbeat?.cancel()
        if probes {
            let applyBegan = ContinuousClock.now
            _ = adapter.apply(
                rows: .activeConnections(reference.rows), revision: WireSnapshotFixture.revision(Self.passes), incarnation: incarnation
            )
            let applyElapsed = applyBegan.duration(to: .now)
            let pages = try RuntimeServiceProfileKernels.pack(reference.rows, limits: profile.clientFrameLimits).pages
            let worst = lateness.max() ?? .zero
            print("APPSTATE-COLLECTION scope=xctest-process rows=\(Self.rows) encodedBytes=\(reference.encodedBytes) pages=\(pages)"
                  + " passes=\(passTimes.map { "\($0)" }.joined(separator: ","))")
            print("APPSTATE-COLLECTION heartbeat wakes=\(lateness.count) maxLateness=\(worst)"
                  + " over16ms=\(lateness.filter { $0 > .milliseconds(16) }.count) over100ms=\(lateness.filter { $0 > .milliseconds(100) }.count)"
                  + " note=includes-os-timer-and-scheduler-delay")
            print("APPSTATE-COLLECTION apply rows=\(Self.rows) elapsed=\(applyElapsed)")
            print("APPSTATE-COLLECTION host-retention rowSets=\(retention.rowSets) retainedBytes=\(retention.retainedBytes)")
        }
        adapter.showing(.activeConnections, false)
        observer.stop()
        try sample("after-hide-and-stop")
        XCTAssertTrue(adapter.activeConnections.isEmpty, "hiding the list drops its rows")
        for sample in samples {
            print("APPSTATE-COLLECTION resource stage=\(sample.stage) peakRSSBytes=\(sample.peakRSSBytes) mallocInUseBytes=\(sample.mallocInUseBytes)"
                  + " note=test-process-observation")
        }
    }
}

/// `ProxyMetrics` decoded from a payload that pre-dates the flap fields still decodes; the new fields default to zero.
final class ProxyMetricsCodableBackcompatTests: XCTestCase {

    func testLegacyPayloadDecodesWithZeroFlapMetrics() throws {
        let legacyJSON = """
        {
            "requestsHandled": 100,
            "successfulRecoveries": 2,
            "failedRequests": 5,
            "openConnections": 3,
            "inboundConnections": 7,
            "uptimeStartedAt": null,
            "lastFailure": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyMetrics.self, from: legacyJSON)
        XCTAssertEqual(decoded.requestsHandled, 100)
        XCTAssertEqual(decoded.failedRequests, 5)
        XCTAssertEqual(decoded.openConnections, 3)
        XCTAssertEqual(decoded.vpnFlapCount, 0, "Missing vpnFlapCount must default to 0 (decodeIfPresent ?? 0)")
        XCTAssertEqual(decoded.vpnFlapTotalDuration, 0)
        XCTAssertNil(decoded.lastVpnFlapAt)
        XCTAssertEqual(decoded.streamsPreservedAcrossFlaps, 0)
    }

    func testRoundTripPreservesPhase7Fields() throws {
        let original = ProxyMetrics(
            requestsHandled: 10,
            successfulRecoveries: 1,
            failedRequests: 2,
            openConnections: 0,
            inboundConnections: 0,
            uptimeStartedAt: nil,
            lastFailure: nil,
            vpnFlapCount: 7,
            vpnFlapTotalDuration: 4.5,
            lastVpnFlapAt: Date(timeIntervalSince1970: 1_700_000_000),
            streamsPreservedAcrossFlaps: 12
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyMetrics.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyEqualsZeroDefaults() {
        let empty = ProxyMetrics.empty
        XCTAssertEqual(empty.requestsHandled, 0)
        XCTAssertEqual(empty.vpnFlapCount, 0)
        XCTAssertEqual(empty.vpnFlapTotalDuration, 0)
        XCTAssertNil(empty.lastVpnFlapAt)
        XCTAssertEqual(empty.streamsPreservedAcrossFlaps, 0)
    }
}
