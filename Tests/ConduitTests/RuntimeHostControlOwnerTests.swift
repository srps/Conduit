// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import ProxyControlBridge
import RuntimeEvents

/// A loopback TCP listener the test holds, so a proxy that binds its port fails as on a contended port.
private final class HeldTCPListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var chosen = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &chosen) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0, named == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: chosen.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// The actual framed client, except that every subscription it opens takes its slot and then ends at once, as a stream the host ended early.
private struct EarlyEndingClient: RuntimeClient {
    let inner: any RuntimeClient

    func submit(
        _ command: ControlRuntimeCommand, requestID: ControlRequestID, expectedIncarnation: ControlHostIncarnation, deadline: RuntimeDeadline
    ) async throws -> ControlAdmission {
        try await inner.submit(command, requestID: requestID, expectedIncarnation: expectedIncarnation, deadline: deadline)
    }

    func lookupAdmission(
        of requestID: ControlRequestID, expectedIncarnation: ControlHostIncarnation, deadline: RuntimeDeadline
    ) async throws -> ControlRequestLookup {
        try await inner.lookupAdmission(of: requestID, expectedIncarnation: expectedIncarnation, deadline: deadline)
    }

    func outcome(
        of operation: ControlOperationID, expectedIncarnation: ControlHostIncarnation, deadline: RuntimeDeadline
    ) async throws -> ControlOperationLookup {
        try await inner.outcome(of: operation, expectedIncarnation: expectedIncarnation, deadline: deadline)
    }

    func subscribe(_ request: ControlSubscriptionRequest, deadline: RuntimeDeadline) async throws -> RuntimeSubscription {
        let opened = try await inner.subscribe(request, deadline: deadline)
        return RuntimeSubscription(next: { _ in .end(ControlStreamEnd(reason: .resyncRequired)) }, cancel: opened.cancel)
    }

    func readPage(_ request: ControlPageRequest, deadline: RuntimeDeadline) async throws -> ControlPageReply {
        try await inner.readPage(request, deadline: deadline)
    }

    func readSnapshot(deadline: RuntimeDeadline) async throws -> ControlRuntimeSnapshot {
        try await inner.readSnapshot(deadline: deadline)
    }
}

/// A request a test built ahead, sent through the client's single-use producer. Test-only: production maps inside the exchange.
fileprivate extension PrivateEditorClient {
    func submit(_ request: PrivateConfigurationRequest, deadline: RuntimeDeadline) async throws -> ControlAdmission {
        try await submit(requestID: request.requestID, deadline: deadline) { request }
    }
}

/// The actual `RuntimeHost` as the control service's one command owner (decisions 0014, 0031, 0035 and 0036): host, then
/// `RuntimeServiceCore`, then the in-memory transport, then the framed client, over a `FakeMachine` and a scratch root. Every bound is
/// the explicit test fixture profile, never a shipping default. Waits end on observed boundaries: a held machine call, or the
/// operation's own `operationFinished` frame within a failure deadline.
@MainActor
final class RuntimeHostControlOwnerTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)

    /// The composed path over one running host.
    private struct Composed {
        let host: RuntimeHost
        let harness: InteractiveHostHarness
        let composition: RuntimeControlComposition
        let client: any RuntimeClient
    }

    /// `beforeOpen` shapes the scratch root's saved files or the harness's effects before the host opens over them.
    private func compose(
        dnsForwarderEnabled: Bool = true,
        stateFiles: (any StateFileAccessing)? = nil,
        beforeOpen: (InteractiveHostHarness) throws -> Void = { _ in }
    ) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: dnsForwarderEnabled)
        self.harness = harness
        if let stateFiles { harness.stateFiles = stateFiles }
        try beforeOpen(harness)
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host,
            limits: try RuntimeServiceFixtures.limits(),
            timing: .system,
            scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport,
            limits: ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(30)
        )
        return Composed(host: host, harness: harness, composition: composition, client: client)
    }

    /// A failure bound only: every wait below ends on its own frame or reply long before it.
    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    /// The stream's frames up to the named operation's settlement. Bounded: a stream that never settles it fails the test.
    private func finished(_ operation: ControlOperationID, on stream: RuntimeSubscription) async throws -> ControlOperationOutcome {
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                return finished.outcome
            }
        }
        XCTFail("the operation's settlement never reached the stream")
        throw RuntimeClientError.unexpectedReply
    }

    /// The stream's frames up to every named operation's settlement, with each outcome. Bounded like `finished`.
    private func finishedAll(
        _ operations: Set<ControlOperationID>,
        on stream: RuntimeSubscription
    ) async throws -> [ControlOperationID: ControlOperationOutcome] {
        var outcomes: [ControlOperationID: ControlOperationOutcome] = [:]
        for _ in 0..<128 where !operations.isSubset(of: Set(outcomes.keys)) {
            if case .operationFinished(let finished) = try await stream.next(deadline()) {
                outcomes[finished.operationID] = finished.outcome
            }
        }
        XCTAssertTrue(operations.isSubset(of: Set(outcomes.keys)), "every operation's settlement reached the stream")
        return outcomes
    }

    private func submit(_ composed: Composed, _ command: ControlRuntimeCommand) async throws -> ControlAdmission {
        try await composed.client.submit(
            command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
    }

    /// The typed projection-failure records, each checked as the health record its value derives, on the kernel log and on the wire.
    private func unavailableEvents(_ host: RuntimeHost) -> Int {
        let recorded = host.orchestrator.eventLog.events.filter { $0.typed == .runtimeService(.snapshotUnavailable(.projectionFailed)) }
        for event in recorded {
            XCTAssertEqual(event.kind, .health)
            XCTAssertEqual(event.detail, "reason=projection_failed")
            XCTAssertEqual(ControlRuntimeEvent(event).typed, .runtimeService(.snapshotUnavailable(.projectionFailed)))
        }
        return recorded.count
    }

    private func accepted(_ admission: ControlAdmission, file: StaticString = #filePath, line: UInt = #line) throws -> ControlOperationID {
        guard case .accepted(let operation) = admission else {
            XCTFail("expected an accepted admission, got \(admission)", file: file, line: line)
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    /// The command a lifecycle completion names: settled, or a DNS Stop's causal disable write.
    private func completed(_ outcome: ControlOperationOutcome) -> ControlRuntimeCommandKind? {
        guard case .completed(let completion) = outcome else { return nil }
        switch completion.result {
        case .settled, .dnsDisable: return completion.command
        case .upstreamProbe, .dnsLiveness, .preflight, .platformWrite: return nil
        }
    }

    // MARK: - One incarnation

    /// The host, its workflow's store contexts, its service and its snapshots name one incarnation, and the stamp carries the v1
    /// accepted-view counter and the whole-host lifecycle counter, read through the actual framed client.
    func testTheServiceSnapshotNamesTheHostIncarnationAndItsCounters() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        XCTAssertEqual(composed.composition.service.incarnation, composed.host.incarnation)

        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(snapshot.stamp.incarnation, composed.host.incarnation)
        XCTAssertEqual(snapshot.stamp.lifecycleRevision.rawValue, composed.host.workflow.generation)
        XCTAssertEqual(snapshot.stamp.configRevision.rawValue, composed.host.configGeneration)
        XCTAssertEqual(snapshot.proxyState, .running)
        for kind in ControlCollectionKind.allCases {
            guard case .available = snapshot.collections.reference(for: kind).state else {
                return XCTFail("\(kind) names the revision of the kernel value it was taken from")
            }
        }
        let modules = try XCTUnwrap(snapshot.stamp.modules)
        let revisions = composed.host.workflow.revisions
        XCTAssertEqual([modules.proxy.rawValue, modules.dns.rawValue, modules.tunnels.rawValue],
                       ControlModule.allCases.map { revisions[$0] })

        let again = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(again.stamp.presentationRevision, snapshot.stamp.presentationRevision, "an unchanged body keeps its revision")
    }

    /// A page through the client is captured from the host in the turn that names its revision: the upstream rows are the configured
    /// upstream, at the snapshot's revision. A change of the kernel collection names a newer revision, and the old cursor reads as stale.
    func testAPageThroughTheClientIsCapturedAtTheSnapshotsCollectionRevision() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        guard case .available(let revision) = snapshot.collections.upstreamHealth.state else {
            return XCTFail("the upstream collection names a revision")
        }
        let first = try await composed.client.readPage(
            ControlPageRequest(expectedIncarnation: composed.host.incarnation, collection: .upstreamHealth, cursor: nil), deadline: deadline()
        )
        guard case .upstreamHealth(let page) = first else { return XCTFail("an upstream page: \(first)") }
        XCTAssertEqual(page.revision, revision)
        XCTAssertEqual(page.status, .current)
        XCTAssertEqual(page.rows.map(\.name), ["Synthetic"])

        composed.host.orchestrator.mutateSnapshotForTesting { $0.upstreamStatuses = [] }
        let moved = try await composed.client.readSnapshot(deadline: deadline())
        guard case .available(let newer) = moved.collections.upstreamHealth.state else { return XCTFail("a newer revision") }
        XCTAssertGreaterThan(newer, revision)
        let again = try await composed.client.readPage(
            ControlPageRequest(
                expectedIncarnation: composed.host.incarnation, collection: .upstreamHealth,
                cursor: ControlPageCursor(revision: revision, offset: try ControlCount(0))
            ),
            deadline: deadline()
        )
        guard case .upstreamHealth(let stale) = again else { return XCTFail("the retained revision: \(again)") }
        XCTAssertEqual(stale.status, .staleRevision(current: newer), "the old revision's rows are named stale, never relabelled")
        XCTAssertEqual(stale.rows.map(\.name), ["Synthetic"])
    }

    // MARK: - Private editor channel

    private func editor(_ composed: Composed) -> PrivateEditorClient {
        PrivateEditorClient(transport: composed.composition.transport)
    }

    private func observation(_ composed: Composed) async throws -> PrivateEditorObservation {
        let answer = try await editor(composed).read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation,
            budget: try ControlWireBudget(1_000), deadline: deadline()
        )
        guard case .observation(let observed) = answer else {
            XCTFail("a read answers an observation: \(answer)")
            throw RuntimeClientError.unexpectedReply
        }
        return observed
    }

    /// An update of `observed`'s values with `edit` applied, at its exact baselines, with one intent per module.
    private func update(
        _ composed: Composed,
        from observed: PrivateEditorObservation,
        modules: PrivateModuleSlots<PrivateModuleIntent> = PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly),
        requestID: ControlRequestID = ControlRequestID(rawValue: UUID()),
        budgetMilliseconds: Int = 1_000,
        editPlatform: (inout PlatformIntegrationConfig) -> Void = { _ in },
        edit: (inout ProxyConfig) -> Void
    ) throws -> PrivateConfigurationRequest {
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        edit(&values.config)
        editPlatform(&values.platform)
        return try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: requestID, incarnation: composed.host.incarnation,
            budget: try ControlWireBudget(budgetMilliseconds),
            runtimeBaseline: try XCTUnwrap(observed.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
            modules: modules
        )
    }

    private func receipt(_ outcome: ControlOperationOutcome) throws -> ControlConfigurationReceipt {
        guard case .configurationSettled(let receipt) = outcome else {
            XCTFail("an update settles with its receipt: \(outcome)")
            throw RuntimeClientError.unexpectedReply
        }
        return receipt
    }

    /// A private read through the actual channel is one owner turn of the store's values, exact baselines and module intents.
    func testAPrivateReadIsTheStoresObservationThroughTheActualChannel() async throws {
        let composed = try await compose()
        let observed = try await observation(composed)
        let capture = composed.host.workflow.editorCapture()
        XCTAssertEqual(observed.components, capture.components)
        XCTAssertEqual(observed.modules, capture.modules)
        XCTAssertEqual(composed.composition.privateCustody.held.transfer, false, "the transfer ends with the exchange")

        let other = try await editor(composed).read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: ControlHostIncarnation(rawValue: UUID()),
            budget: try ControlWireBudget(1_000), deadline: deadline()
        )
        XCTAssertEqual(other, .refused(.changedIncarnation))
    }

    /// An all-save-only update persists its frozen values at the exact baselines it names and changes no lifecycle intent. Its receipt names
    /// the request, the host, each file's write with its new baseline and the DNS bit merged in its claim. The frozen-input slot is held until
    /// the operation quiesced. Its request ID is lookup-only afterwards, on either channel. The same old baselines then conflict as stale.
    func testASaveOnlyUpdateSettlesWithItsCausalReceiptAndItsIDIsLookupOnly() async throws {
        let composed = try await compose()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let revisions = composed.host.workflow.revisions
        let request = try update(composed, from: observed) { $0.profileName = "Edited" }

        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let outcome = try await finished(operation, on: stream)
        let settled = try receipt(outcome)
        XCTAssertEqual(settled.requestID, request.requestID)
        XCTAssertEqual(settled.incarnation, composed.host.incarnation)
        XCTAssertEqual(settled.runtime.write, .persisted(reportedError: false))
        XCTAssertGreaterThan(try XCTUnwrap(settled.runtime.baseline).version, request.runtimeBaseline.version)
        XCTAssertEqual(settled.committedDNSForwarderEnabled, observed.runtime.dns.forwarderEnabled)
        XCTAssertEqual(settled.modules, [])
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Edited")
        XCTAssertEqual(composed.host.workflow.revisions, revisions, "a save changes no lifecycle revision")
        XCTAssertEqual(composed.composition.privateCustody.held.input, false, "the frozen input is released at quiescence")
        XCTAssertEqual(composed.composition.service.liveOperationCount, 0)

        let resent = try await editor(composed).submit(request, deadline: deadline())
        XCTAssertEqual(resent, .rejected(.requestReused))
        let ordinary = try await composed.client.submit(
            .stop(.tunnels), requestID: request.requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(ordinary, .rejected(.requestReused), "an ordinary submit may not reuse a private ID")

        let stale = try update(composed, from: observed) { $0.profileName = "Older draft" }
        let staleOperation = try accepted(try await editor(composed).submit(stale, deadline: deadline()))
        let staleOutcome = try await finished(staleOperation, on: stream)
        let refused = try receipt(staleOutcome)
        XCTAssertEqual(refused.runtime.write, .notAttempted(.baselineMismatch), "an old baseline never overwrites a newer file")
        XCTAssertNil(refused.runtime.baseline)
        XCTAssertNil(refused.committedDNSForwarderEnabled)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Edited")
    }

    /// A Start slot starts its module from the frozen values through the one Start path, and the receipt carries the member's result. A
    /// stale Start revision refuses the whole request before anything is written.
    func testAStartUpdateStartsFromTheFrozenValuesAndAStaleOneIsRefusedWhole() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let start = try update(
            composed, from: observed,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly)
        ) { $0.profileName = "Started" }
        let operation = try accepted(try await editor(composed).submit(start, deadline: deadline()))
        let outcome = try await finished(operation, on: stream)
        let settled = try receipt(outcome)
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.host.config.profileName, "Started", "the host adopted the frozen values it verified")

        let after = try await observation(composed)
        let stale = try update(
            composed, from: after,
            modules: PrivateModuleSlots(proxy: .start(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly)
        ) { $0.profileName = "Never" }
        let refusedWhole = try await editor(composed).submit(stale, deadline: deadline())
        XCTAssertEqual(refusedWhole, .rejected(.staleRevision))
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Started")
        XCTAssertEqual(composed.composition.privateCustody.held.input, false, "a refused update releases its slot with its exchange")
    }

    /// An update whose wait ended before its frame was handed over, by an expired deadline or a cancelled task, is not sent: nothing is
    /// admitted, recorded or written, and both custody terms are released with the exchange.
    func testAPrivateUpdateEndedBeforeItsSendIsNotSentAndAdmitsNothing() async throws {
        let composed = try await compose()
        let observed = try await observation(composed)
        let request = try update(composed, from: observed) { $0.profileName = "Never" }
        let editor = editor(composed)
        do {
            _ = try await editor.submit(request, deadline: RuntimeDeadline(instant: ContinuousClock.now.advanced(by: .seconds(-1))))
            XCTFail("an expired update is not sent")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .notSent(.deadlineExpired))
        }
        let limit = deadline()
        let cancelled = Task { () async -> RuntimeClientError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await editor.submit(request, deadline: limit)
                return nil
            } catch let error as RuntimeClientError {
                return error
            } catch {
                return nil
            }
        }
        let error = await cancelled.value
        XCTAssertEqual(error, .notSent(.cancelled))
        let lookup = try await composed.client.lookupAdmission(
            of: request.requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(lookup, .unknown(.notRecorded), "nothing was admitted or recorded")
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName,
                       observed.runtime.profileName)
        XCTAssertEqual(composed.composition.privateCustody.held.transfer, false)
        XCTAssertEqual(composed.composition.privateCustody.held.input, false)
    }

    /// A busy channel refuses an update before its producer maps anything, so a peer never builds a second full request. A frozen input
    /// still held by an admitted operation refuses another update, but not a read, which takes only the transfer.
    func testABusyUpdateRefusesBeforeItsRequestIsMappedAndAHeldInputLeavesReadsOpen() async throws {
        let composed = try await compose()
        let custody = composed.composition.privateCustody
        let transfer = try XCTUnwrap(custody.reserve(.update))
        // Set to 1 by a producer call; it stays at its initial -1 while no producer runs.
        let mapped = LockedCount()
        do {
            _ = try await editor(composed).submit(requestID: ControlRequestID(rawValue: UUID()), deadline: deadline()) {
                mapped.set(1)
                throw RuntimeClientError.unexpectedReply
            }
            XCTFail("a busy channel refuses the update")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .notSent(.transportBusy))
        }
        XCTAssertEqual(mapped.value, -1, "the producer is never called while the channel is busy")

        // An admitted operation keeps the input after its exchange ends.
        let input = try XCTUnwrap(transfer.takeInputSlot())
        transfer.end()
        XCTAssertEqual(custody.held.transfer, false)
        XCTAssertEqual(custody.held.input, true)
        _ = try await observation(composed)
        do {
            _ = try await editor(composed).submit(requestID: ControlRequestID(rawValue: UUID()), deadline: deadline()) {
                mapped.set(1)
                throw RuntimeClientError.unexpectedReply
            }
            XCTFail("a held frozen input refuses another update")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .notSent(.transportBusy))
        }
        XCTAssertEqual(mapped.value, -1)
        input.release()
        XCTAssertEqual(custody.held.input, false)
    }

    /// An apply-while-running update saves, then applies its verified pair to the module running at the revision it named, with no lifecycle
    /// change. Once the module is stopped the same kind of update is persisted and held. A moved revision refuses it whole.
    func testAnApplyWhileRunningUpdateAppliesOnlyToTheModuleStillRunningAtItsRevision() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let revisions = composed.host.workflow.revisions
        let apply = PrivateModuleSlots<PrivateModuleIntent>(
            proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        )
        let request = try update(composed, from: observed, modules: apply) { $0.profileName = "Applied" }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let outcome = try await finished(operation, on: stream)
        let settled = try receipt(outcome)
        XCTAssertEqual(settled.applied, true)
        XCTAssertEqual(composed.host.config.profileName, "Applied", "the running proxy took the verified pair")
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.host.workflow.revisions, revisions, "applying changes no lifecycle revision")

        let stop = try accepted(try await submit(composed, .stop(.proxy)))
        _ = try await finished(stop, on: stream)
        let stopped = try await observation(composed)
        let held = try update(composed, from: stopped, modules: PrivateModuleSlots(
            proxy: .applyWhileRunning(ifLifecycleRevision: stopped.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        )) { $0.profileName = "Saved only" }
        let heldOperation = try accepted(try await editor(composed).submit(held, deadline: deadline()))
        let heldOutcome = try await finished(heldOperation, on: stream)
        let heldReceipt = try receipt(heldOutcome)
        XCTAssertEqual(heldReceipt.applied, false, "a stopped module is not started by an apply")
        XCTAssertEqual(heldReceipt.runtime.write, .persisted(reportedError: false), "the values are still saved")
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)

        let moved = try update(composed, from: stopped, modules: apply) { $0.profileName = "Never" }
        let refused = try await editor(composed).submit(moved, deadline: deadline())
        XCTAssertEqual(refused, .rejected(.staleRevision))
    }

    /// The `lifecycle.module_settled` values recorded for `group`, by module.
    private func settlements(_ harness: InteractiveHostHarness, group: Int) -> [ControlModuleReceipt] {
        harness.typedEvents().compactMap { payload in
            guard case .lifecycle(.moduleSettled(let settled)) = payload, settled.group == group,
                  case .explicit(let module, let result) = settled.settlement else { return nil }
            let control: ControlModule = switch module {
            case .proxy: .proxy
            case .dns: .dns
            case .tunnels: .tunnels
            }
            return ControlModuleReceipt(module: control, result: ControlLifecycleModuleResult(result))
        }
    }

    /// A frozen Start whose proxy cannot bind reports each member's recorded settlement, the same values its `lifecycle.module_settled`
    /// events carry: the proxy failed, and in a combined Start the DNS member it held is superseded.
    func testAFrozenStartsReceiptCarriesTheRecordedSettlementsOfAFailedBind() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        let occupied = try HeldTCPListener()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        for withDNS in [false, true] {
            let observed = try await observation(composed)
            let group = composed.host.workflow.generation + 1
            let modules = PrivateModuleSlots<PrivateModuleIntent>(
                proxy: .start(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision),
                dns: withDNS ? .start(ifLifecycleRevision: observed.modules.dns.lifecycleRevision) : .saveOnly,
                tunnels: .saveOnly
            )
            let request = try update(composed, from: observed, modules: modules) { $0.localPort = occupied.port }
            let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
            let outcome = try await finished(operation, on: stream)
            let settled = try receipt(outcome)
            let expected: [ControlModuleReceipt] = withDNS
                ? [ControlModuleReceipt(module: .proxy, result: .failed), ControlModuleReceipt(module: .dns, result: .superseded)]
                : [ControlModuleReceipt(module: .proxy, result: .failed)]
            XCTAssertEqual(settled.modules, expected, "combined: \(withDNS)")
            XCTAssertEqual(settlements(composed.harness, group: group), expected, "the receipt and the events agree (combined: \(withDNS))")
            XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        }
    }

    /// A request whose own budget lapsed before the admission turn is refused with the typed `deadlineExpired`: nothing is admitted or
    /// recorded, nothing is written, and the slot is released. A read at the same budget is refused the same way.
    func testAPrivateRequestWhoseBudgetLapsedBeforeAdmissionIsRefusedTyped() async throws {
        let composed = try await compose()
        let observed = try await observation(composed)
        let request = try update(composed, from: observed, budgetMilliseconds: 0) { $0.profileName = "Never" }
        let admission = try await editor(composed).submit(request, deadline: deadline())
        XCTAssertEqual(admission, .rejected(.deadlineExpired))
        let lookup = try await composed.client.lookupAdmission(
            of: request.requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(lookup, .unknown(.notRecorded), "a lapsed budget records no alias")
        XCTAssertEqual(composed.composition.privateCustody.held.input, false)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName,
                       observed.runtime.profileName)

        let read = try await editor(composed).read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation,
            budget: try ControlWireBudget(0), deadline: deadline()
        )
        XCTAssertEqual(read, .refused(.deadlineExpired))
    }

    /// A save stages DNS's durable intent, never the draft's DNS bit: after a session DNS Stop, a frozen draft that still says enabled
    /// writes the Stop's disable, and the receipt names it.
    func testASaveMergesTheDNSStopsDisableOverTheDraftsEnable() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let draft = try await observation(composed)
        XCTAssertTrue(draft.runtime.dns.forwarderEnabled)
        let stop = try accepted(try await submit(composed, .stop(.dns)))
        _ = try await finished(stop, on: stream)
        let current = try await observation(composed)

        // The draft's values, at the current baselines: its DNS bit is still the enable the user saw before the Stop.
        var values = try PrivateConfigurationBridge.makeValues(from: draft)
        values.config.profileName = "Merged"
        let request = try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: composed.host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(current.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(current.components.platform.baseline),
            modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        )
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let outcome = try await finished(operation, on: stream)
        let settled = try receipt(outcome)
        XCTAssertEqual(settled.committedDNSForwarderEnabled, false)
        let saved = try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false)
        XCTAssertEqual(saved.profileName, "Merged")
        XCTAssertFalse(saved.dnsForwarderEnabled, "the Stop's disable stands")
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "a save never clears a fence")
    }

    /// A save-only slot beside another module's Start: the one verified pair reaches every running module, so the running proxy takes the
    /// saved proxy values too (decisions 0025 and 0037).
    func testASaveOnlySlotBesideAnotherModulesStartReachesTheRunningModule() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let request = try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .saveOnly, dns: .saveOnly, tunnels: .start(ifLifecycleRevision: observed.modules.tunnels.lifecycleRevision)
        )) { $0.profileName = "Whole pair" }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        _ = try await finished(operation, on: stream)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.host.heldRuntimeConfig.profileName, "Whole pair", "the running proxy holds the one applied input")
    }

    /// The login-item administration saves the platform file's flag alone, under its exact platform baseline, and applies nothing; an old
    /// baseline is refused as stale; and a later editor save merges the stored flag, so an older draft cannot restore it.
    func testLaunchAtLoginAdministrationWritesOnlyItsFlagAndAnEditorSaveKeepsIt() async throws {
        let composed = try await compose()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        XCTAssertFalse(observed.launchAtLogin)
        let platformBaseline = try XCTUnwrap(observed.components.platform.baseline)

        let admin = try accepted(try await submit(composed, .setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline)))
        let outcome = try await finished(admin, on: stream)
        guard case .completed(let completion) = outcome, case .platformWrite(let write) = completion.result else {
            return XCTFail("the admin write completes with its platform write: \(outcome)")
        }
        XCTAssertEqual(write.write, .persisted(reportedError: false))
        XCTAssertGreaterThan(try XCTUnwrap(write.baseline).version, platformBaseline.version)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: composed.harness.environment).launchAtLogin)

        let again = try accepted(try await submit(composed, .setLaunchAtLogin(false, ifPlatformBaseline: platformBaseline)))
        let staleOutcome = try await finished(again, on: stream)
        guard case .completed(let staleCompletion) = staleOutcome, case .platformWrite(let stale) = staleCompletion.result else {
            return XCTFail("the stale admin write still settles: \(staleOutcome)")
        }
        XCTAssertEqual(stale.write, .notAttempted(.baselineMismatch))

        // The draft from before the admin write, saved at the current baselines: the stored flag stays.
        let current = try await observation(composed)
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        values.config.profileName = "After admin"
        let request = try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: composed.host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(current.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(current.components.platform.baseline),
            modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        )
        let save = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        _ = try await finished(save, on: stream)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: composed.harness.environment).launchAtLogin, "the editor save kept the flag")
    }

    /// The quit's one reserved flush: after the latch, one all-save-only update is admitted and written, nothing is applied, and the quit
    /// waits for it within its total deadline. A second update, or one after a deadline already past, is refused as stopping.
    func testTheQuitAdmitsOneReservedFlushWithinItsDeadlineAndNothingAfter() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let applied = composed.host.config.profileName
        let host = composed.host
        // The final save's ID is minted before the Quit names it; an older autosave and another client's save carry their own IDs.
        let flush = try update(composed, from: observed) { $0.profileName = "Flushed" }
        let reserved = try ControlQuitFlush(configuration: flush.requestID, preferences: nil)
        let quit = Task { @MainActor in
            await host.shutdown(reservingFlushUntil: ContinuousClock.now.advanced(by: .seconds(30)), flushing: reserved)
        }
        let latched = try await eventually { host.workflow.isTerminal }
        XCTAssertTrue(latched)

        let autosave = try update(composed, from: observed) { $0.profileName = "Old autosave" }
        let autosaved = try await editor(composed).submit(autosave, deadline: deadline())
        XCTAssertEqual(autosaved, .rejected(.hostStopping), "an unrelated save after the latch cannot spend the reserved final save")
        let otherClient = PrivateEditorClient(transport: composed.composition.transport)
        let foreign = try update(composed, from: observed) { $0.profileName = "Another client" }
        let foreignAnswer = try await otherClient.submit(foreign, deadline: deadline())
        XCTAssertEqual(foreignAnswer, .rejected(.hostStopping))
        _ = try accepted(try await editor(composed).submit(flush, deadline: deadline()))
        await quit.value
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Flushed")
        XCTAssertEqual(host.config.profileName, applied, "the flush applies nothing")
        XCTAssertFalse(host.runtimeState().proxyIsUp)

        let after = try await observation(composed)
        let second = try update(composed, from: after) { $0.profileName = "Too late" }
        let refused = try await editor(composed).submit(second, deadline: deadline())
        XCTAssertEqual(refused, .rejected(.hostStopping))
    }

    /// A quit whose deadline already passed opens no window: it does not wait, and a flush is refused as stopping.
    func testAQuitWhoseDeadlinePassedAdmitsNoFlush() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let observed = try await observation(composed)
        await composed.host.shutdown(reservingFlushUntil: ContinuousClock.now.advanced(by: .seconds(-1)))
        let flush = try update(composed, from: observed) { $0.profileName = "Never" }
        let refused = try await editor(composed).submit(flush, deadline: deadline())
        XCTAssertEqual(refused, .rejected(.hostStopping))
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName,
                       observed.runtime.profileName)
    }

    /// A preferences update through the actual client: the preferences file alone is written under its exact baseline, its safe receipt
    /// names the new baseline, nothing starts or applies, the request ID stays lookup-only, and a draft at the old baseline is refused.
    func testAPreferencesUpdateWritesOnlyThePreferencesFileAndSettlesWithItsReceipt() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let environment = composed.harness.environment
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let baseline = try XCTUnwrap(observed.components.preferences.baseline)
        let runtimeBytes = try Data(contentsOf: environment.configFile)
        let platformBytes = try? Data(contentsOf: environment.platformConfigFile)
        let generation = composed.host.workflow.generation
        var preferences = try PrivateConfigurationBridge.makeValues(from: observed).preferences
        preferences.preferredBrowserTestURL = "https://preferences.example.test/?token=private"
        preferences.showMenuBarIcon.toggle()
        let requestID = ControlRequestID(rawValue: UUID())
        let edited = preferences
        let request = try PrivateConfigurationBridge.makePreferencesRequest(
            preferences: edited, requestID: requestID, incarnation: composed.host.incarnation,
            budget: try ControlWireBudget(1_000), preferencesBaseline: baseline
        )

        let operation = try accepted(try await editor(composed).submitPreferences(requestID: requestID, deadline: deadline()) { request })
        let outcome = try await finished(operation, on: stream)
        guard case .preferencesSettled(let receipt) = outcome else { return XCTFail("a preferences update settles with its receipt: \(outcome)") }
        XCTAssertEqual(receipt.requestID, requestID)
        XCTAssertEqual(receipt.incarnation, composed.host.incarnation)
        XCTAssertEqual(receipt.preferences.write, .persisted(reportedError: false))
        let newer = try XCTUnwrap(receipt.preferences.baseline)
        XCTAssertEqual(newer.component, .preferences)
        XCTAssertGreaterThan(newer.version, baseline.version)
        XCTAssertEqual(try AppPreferencesPersistence.load(in: environment), edited)
        XCTAssertEqual(try Data(contentsOf: environment.configFile), runtimeBytes, "the runtime file is not touched")
        XCTAssertEqual(try? Data(contentsOf: environment.platformConfigFile), platformBytes, "nor the platform file")
        XCTAssertEqual(composed.host.workflow.generation, generation, "no lifecycle admission")
        let reread = try await observation(composed)
        XCTAssertEqual(reread.components.preferences, .verified(newer), "the store holds the receipt's baseline")
        XCTAssertEqual(composed.composition.privateCustody.held.input, false)

        let lookup = try await composed.client.lookupAdmission(of: requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline())
        XCTAssertEqual(lookup, .admission(.accepted(operation)), "the alias recovers the admission")
        let reused = try await editor(composed).submitPreferences(requestID: requestID, deadline: deadline()) { request }
        XCTAssertEqual(reused, .rejected(.requestReused), "a live private ID is lookup-only")

        var older = edited
        older.fileLoggingEnabled.toggle()
        let staleRequest = try PrivateConfigurationBridge.makePreferencesRequest(
            preferences: older, requestID: ControlRequestID(rawValue: UUID()), incarnation: composed.host.incarnation,
            budget: try ControlWireBudget(1_000), preferencesBaseline: baseline
        )
        let stale = try accepted(try await editor(composed).submitPreferences(requestID: staleRequest.requestID, deadline: deadline()) {
            staleRequest
        })
        guard case .preferencesSettled(let refused) = try await finished(stale, on: stream) else { return XCTFail("the stale draft settles") }
        XCTAssertEqual(refused.preferences.write, .notAttempted(.baselineMismatch))
        XCTAssertNil(refused.preferences.baseline)
        XCTAssertEqual(try AppPreferencesPersistence.load(in: environment), edited, "the stale draft wrote nothing")
    }

    /// The admin write's completion takes the one completion path: while the projection fails it names the next revision, above any body
    /// a subscriber holds, and the first snapshot after recovery takes exactly that revision.
    func testAnAdminWriteCompletedWhileTheSnapshotFailsNamesTheRevisionTheRecoveredSnapshotTakes() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let platformBaseline = try XCTUnwrap(observed.components.platform.baseline)
        let before = try await composed.client.readSnapshot(deadline: deadline()).stamp.presentationRevision

        composed.host.orchestrator.mutateSnapshotForTesting { $0.runtimeStatus.metrics.vpnFlapTotalDuration = -1 }
        do {
            _ = try await composed.client.readSnapshot(deadline: deadline())
            XCTFail("a read fails closed while the projection fails")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .wire(.internalFailure))
        }
        let operation = try accepted(try await submit(composed, .setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline)))
        let outcome = try await finished(operation, on: stream)
        guard case .completed(let completion) = outcome, case .platformWrite(let write) = completion.result else {
            return XCTFail("the admin write completes with its platform write: \(outcome)")
        }
        XCTAssertEqual(write.write, .persisted(reportedError: false))
        XCTAssertGreaterThan(completion.presentationRevision, before, "the completion never names the body from before it")

        composed.host.orchestrator.mutateSnapshotForTesting { $0.runtimeStatus.metrics.vpnFlapTotalDuration = 0 }
        let recovered = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(recovered.stamp.presentationRevision, completion.presentationRevision)
        XCTAssertEqual(unavailableEvents(composed.host), 1)
    }

    /// A reserved flush admitted inside the window but not launched before its deadline writes nothing afterwards: the window's close revokes
    /// its claim. The quit returns at the deadline; the late launch then settles stale, and its custody and admission are released.
    func testAFlushAdmittedButNotStartedBeforeTheQuitDeadlineWritesNothingAfterIt() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let editor = PrivateEditorClient(transport: composition.transport)
        let observed = try host.workflow.editorCapture().observation()
        let before = try Data(contentsOf: harness.environment.configFile)
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        values.config.profileName = "Too late"
        let request = try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(observed.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
            modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        )
        // The window is the quit's own deadline, the seam that closes it; the flush is admitted well inside it, and its launch hop is held.
        let reserved = try ControlQuitFlush(configuration: request.requestID, preferences: nil)
        let quit = Task { @MainActor in
            await host.shutdown(reservingFlushUntil: ContinuousClock.now.advanced(by: .seconds(2)), flushing: reserved)
        }
        let latched = try await eventually { host.workflow.isTerminal }
        XCTAssertTrue(latched)
        let operation = try accepted(try await admitInOneRound(editor, request, scheduling: scheduling))
        await quit.value
        XCTAssertFalse(host.workflow.isIdle && host.pendingAdmissions == 0, "the admitted flush has not run yet")

        scheduling.drainAll()
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), before, "the revoked flush wrote nothing")
        XCTAssertEqual(composition.service.operationLookup(ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation)),
                       .finished(.failed(.staleRevision)))
        XCTAssertEqual(composition.privateCustody.held.input, false)
    }

    /// With ordinary capacity exhausted by held work, a Quit through the actual framed client is still admitted and latches at once, and its
    /// reserved flush is admitted in the quit's own partition. Once the held work is released, the flush writes, the held Restart ends
    /// under the quit, and the Quit completes; every admission and the custody are released.
    func testAQuitBehindExhaustedOrdinaryCapacityLatchesAtOnceAndAdmitsItsReservedFlush() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        try await host.startRuntime()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(ordinaryPending: 1), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        let editor = PrivateEditorClient(transport: composition.transport)
        let stream = try await client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try host.workflow.editorCapture().observation()
        func send(_ command: ControlRuntimeCommand) async throws -> ControlAdmission {
            try await client.submit(command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, deadline: deadline())
        }

        // The held work: a Restart parked on its first system-proxy read takes the one ordinary slot.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let lifecycle = try XCTUnwrap(ControlLifecycleRevision(rawValue: host.workflow.generation))
        let restart = try accepted(try await send(.restart(.proxy, ifLifecycleRevision: lifecycle)))
        await harness.hold.waitUntilReached()
        let platformBaseline = try XCTUnwrap(observed.components.platform.baseline)
        let full = try await send(.setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline))
        XCTAssertEqual(full, .rejected(.queueFull), "ordinary capacity is exhausted")

        // The final save's ID is minted before the Quit names it.
        let request = try update(host: host, from: observed) { $0.profileName = "Flushed at quit" }
        let quitID = ControlRequestID(rawValue: UUID())
        let quitCommand = ControlRuntimeCommand.quit(
            total: try ControlWireBudget(30_000), flush: try ControlQuitFlush(configuration: request.requestID, preferences: nil)
        )
        let selfNamed = try await client.submit(
            .quit(total: try ControlWireBudget(30_000), flush: try ControlQuitFlush(configuration: nil, preferences: quitID)),
            requestID: quitID, expectedIncarnation: host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(selfNamed, .rejected(.requestConflict), "a Quit naming its own ID as a final save latches nothing")
        XCTAssertFalse(host.workflow.isTerminal)
        let quitRequest = ControlRequestID(rawValue: UUID())
        let quit = try accepted(try await client.submit(quitCommand, requestID: quitRequest, expectedIncarnation: host.incarnation, deadline: deadline()))
        XCTAssertTrue(host.workflow.isTerminal, "the quit latched in its admission turn")
        let second = try await send(.quit(total: try ControlWireBudget(30_000), flush: .none))
        XCTAssertEqual(second, .rejected(.hostStopping), "one quit per host")

        harness.hold.release()
        _ = try await finishedAll([restart], on: stream)
        // A burst of unrelated saves past the alias capacity while the window is open: each is refused as ordinary work, in the ordinary
        // alias partition, so the Quit's own alias survives it.
        for _ in 0..<9 {
            let unrelated = try update(host: host, from: observed) { $0.profileName = "Unrelated" }
            let answer = try await editor.submit(unrelated, deadline: deadline())
            XCTAssertEqual(answer, .rejected(.hostStopping))
        }
        let quitAlias = try await client.lookupAdmission(of: quitRequest, expectedIncarnation: host.incarnation, deadline: deadline())
        XCTAssertEqual(quitAlias, .admission(.accepted(quit)), "the Quit's alias survives the burst")
        let flush = try accepted(try await editor.submit(request, deadline: deadline()))
        let outcomes = try await finishedAll([quit, flush], on: stream)
        XCTAssertEqual(outcomes[quit].flatMap(completed), .quit)
        XCTAssertEqual(try receipt(try XCTUnwrap(outcomes[flush])).runtime.write, .persisted(reportedError: false))
        XCTAssertEqual(try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false).profileName, "Flushed at quit")
        let quiet = try await eventually { host.pendingAdmissions == 0 && host.workflow.isIdle }
        XCTAssertTrue(quiet)
        XCTAssertFalse(host.runtimeState().proxyIsUp)
        XCTAssertEqual(composition.privateCustody.held.input, false)
    }

    /// The private round waits in the transport's own gate: with its owner hop held in the seam, the request's budget ends the caller's wait
    /// with the typed refusal and a cancelled caller ends unsent, both before any claim. Neither admits or records an alias, and neither frees
    /// the transfer or the input before its queued round has physically run. A Stop stays independent of the held round.
    func testAPrivateRoundHeldInTheSeamDetachesItsCallerAndReleasesItsCustodyOnlyAfterCleanup() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        let scheduling = ManualOwnerScheduling()
        let clock = ManualRuntimeTiming()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: clock.timing, scheduling: scheduling
        )
        let editor = PrivateEditorClient(transport: composition.transport)
        let custody = composition.privateCustody
        let observed = try host.workflow.editorCapture().observation()
        let before = try Data(contentsOf: harness.environment.configFile)
        func lookup(_ request: PrivateConfigurationRequest) -> ControlRequestLookup {
            composition.service.requestLookup(ControlRequestQuery(expectedIncarnation: host.incarnation, requestID: request.requestID))
        }

        // Each caller's answer lands in a slot, so the test sees whether it arrived while the round is still held without awaiting the
        // caller first. The round is always drained before a caller is awaited, so a caller that is not detached fails the test, not hangs it.
        func submitting(_ request: PrivateConfigurationRequest) -> (Task<Void, Never>, LockedSlot<Result<ControlAdmission, any Error>>) {
            let answer = LockedSlot<Result<ControlAdmission, any Error>>()
            let task = Task {
                do {
                    answer.set(.success(try await editor.submit(request, deadline: deadline())))
                } catch {
                    answer.set(.failure(error))
                }
            }
            return (task, answer)
        }

        // The request's one-second budget ends before the caller's own deadline while its round waits in the seam.
        let budgeted = try update(host: host, from: observed) { $0.profileName = "Never admitted" }
        let hopsBeforeBudgeted = scheduling.queuedHopCount
        let timersBefore = clock.armedTimerCount
        let (waiting, budgetedAnswer) = submitting(budgeted)
        let armed = try await eventually {
            clock.armedTimerCount > timersBefore && scheduling.queuedHopCount > hopsBeforeBudgeted
        }
        XCTAssertTrue(armed, "the wait armed its timer and queued its round")
        clock.advance(by: .seconds(2))
        clock.fireAll()
        let budgetAnswered = try await eventually { budgetedAnswer.value != nil }
        XCTAssertTrue(budgetAnswered, "the budget detaches the caller while its round is still held")
        XCTAssertEqual(custody.held.transfer, true, "the queued round still holds the transfer")
        XCTAssertEqual(custody.held.input, true, "and the input it could still have admitted")
        _ = try accepted(composition.service.submit(ControlOperationRequest(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .stop(.tunnels)
        )))
        scheduling.drainAll()
        await waiting.value
        guard case .success(let refused)? = budgetedAnswer.value else {
            return XCTFail("the budgeted caller is answered: \(String(describing: budgetedAnswer.value))")
        }
        XCTAssertEqual(refused, .rejected(.deadlineExpired), "the typed budget refusal, before any claim")
        let released = try await eventually { !custody.held.transfer && !custody.held.input }
        XCTAssertTrue(released, "the transfer and the input return once the round ran unclaimed")
        XCTAssertEqual(lookup(budgeted), .unknown(.notRecorded), "nothing was admitted or recorded")

        // A caller cancelled while its round waits ends unsent; the round then runs unclaimed.
        let cancelled = try update(host: host, from: observed) { $0.profileName = "Cancelled" }
        let hopsBeforeCancelled = scheduling.queuedHopCount
        let (task, cancelledAnswer) = submitting(cancelled)
        let queued = try await eventually { scheduling.queuedHopCount > hopsBeforeCancelled }
        XCTAssertTrue(queued, "the cancelled caller's round waits in the seam")
        task.cancel()
        let cancelAnswered = try await eventually { cancelledAnswer.value != nil }
        XCTAssertTrue(cancelAnswered, "cancellation detaches the caller while its round is still held")
        XCTAssertEqual(custody.held.transfer, true, "the cancelled caller's round still holds the transfer")
        scheduling.drainAll()
        await task.value
        guard case .failure(let error as RuntimeClientError)? = cancelledAnswer.value else {
            return XCTFail("a cancelled wait is not answered: \(String(describing: cancelledAnswer.value))")
        }
        XCTAssertEqual(error, .notSent(.cancelled))
        let cleaned = try await eventually { !custody.held.transfer && !custody.held.input }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(lookup(cancelled), .unknown(.notRecorded))
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), before, "nothing was written")
    }

    /// An update whose one owner round waits in the manual seam: that round alone is run, so the update is admitted and its launch hop
    /// stays queued for the test to order.
    private func admitInOneRound(
        _ editor: PrivateEditorClient,
        _ request: PrivateConfigurationRequest,
        scheduling: ManualOwnerScheduling
    ) async throws -> ControlAdmission {
        let before = scheduling.queuedHopCount
        let earlier = scheduling.pendingCount
        let submit = Task { try await editor.submit(request, deadline: deadline()) }
        let queued = try await eventually { scheduling.queuedHopCount > before }
        XCTAssertTrue(queued, "the private round waits in the scheduling seam")
        // The hops queued before it run first, in order, then the round; anything they or the round queue stays behind.
        for _ in 0...earlier { scheduling.runNext() }
        return try await submit.value
    }

    /// A save-only update of `observed`'s values with `edit` applied, at its exact baselines, for a host composed in the test itself.
    private func update(host: RuntimeHost, from observed: PrivateEditorObservation, edit: (inout ProxyConfig) -> Void) throws
        -> PrivateConfigurationRequest
    {
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        edit(&values.config)
        return try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(observed.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
            modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        )
    }

    /// A Stop of a module an apply-while-running save names, fenced after the save's admission and before its queued launch, revokes the
    /// unstarted write (decision 0035): nothing is written, the update settles stale, and its slot and admission are released.
    func testAStopAfterAnApplysAdmissionRevokesItsUnstartedWrite() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        try await host.startRuntime()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let editor = PrivateEditorClient(transport: composition.transport)
        let capture = host.workflow.editorCapture()
        let observed = try capture.observation()
        let before = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false).profileName
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        values.config.profileName = "Revoked"
        let request = try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(observed.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
            modules: PrivateModuleSlots(
                proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
            )
        )
        let operation = try accepted(try await admitInOneRound(editor, request, scheduling: scheduling))
        _ = try accepted(composition.service.submit(ControlOperationRequest(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .stop(.proxy)
        )))
        scheduling.drainAll()
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false).profileName, before,
                       "the revoked save wrote nothing")
        XCTAssertEqual(composition.service.operationLookup(ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation)),
                       .finished(.failed(.staleRevision)))
        XCTAssertEqual(composition.privateCustody.held.input, false)
    }

    /// A Stop of the module an apply names, admitted while that apply's store commit is parked on its platform verification read, revokes
    /// the runtime write that has not started (decision 0035). The parked read finishes, nothing is written, the receipt reports the runtime
    /// write not attempted with no new baseline and no apply, and the Stop settles while the store step is still parked.
    func testAStopAdmittedWhileAnApplysCommitIsParkedRevokesItsUnstartedRuntimeWrite() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let saved = try Data(contentsOf: composed.harness.environment.configFile)
        let request = try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        )) { $0.profileName = "Revoked while parked" }

        // The platform value is unchanged, so the coupled commit verifies the platform file by reading it before the runtime write.
        let platformPath = composed.harness.session.plan.platformConfig.path
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        await files.hold.waitUntilReached()
        XCTAssertFalse(files.hold.reachedOnMainThread)

        let stop = try accepted(try await submit(composed, .stop(.proxy)))
        let stopOutcome = try await finished(stop, on: stream)
        XCTAssertNotNil(completed(stopOutcome), "the Stop settles without the parked store step")
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        files.hold.release()
        let settled = try receipt(try await finished(operation, on: stream))
        XCTAssertEqual(settled.platform.write, .unchanged)
        guard case .notAttempted = settled.runtime.write else {
            return XCTFail("the revoked runtime write is not attempted: \(settled.runtime.write)")
        }
        XCTAssertNil(settled.runtime.baseline, "no new runtime baseline without a verified write")
        XCTAssertEqual(settled.applied, false)
        XCTAssertEqual(try Data(contentsOf: composed.harness.environment.configFile), saved, "the revoked save wrote nothing")
        XCTAssertEqual(composed.composition.privateCustody.held.input, false)
    }

    /// The client quit over the actual framed and private clients while an earlier update still holds the one frozen input in a parked
    /// store step: the Quit fences first, its final saves wait for that update's settlement, and the configuration save rebases only from
    /// that update's causal receipt. Both declared saves then flush under the IDs the Quit named, and the Quit completes.
    func testTheClientQuitFencesFirstThenFlushesOnceTheEarlierUpdateReleasesItsInput() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let prior = try update(composed, from: observed) { $0.profileName = "Prior" }
        let platformPath = composed.harness.session.plan.platformConfig.path
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        _ = try accepted(try await editor(composed).submit(prior, deadline: deadline()))
        await files.hold.waitUntilReached()

        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let observedRuntime = try XCTUnwrap(observed.components.runtime.baseline)
        let observedPlatform = try XCTUnwrap(observed.components.platform.baseline)
        let preferencesBaseline = try XCTUnwrap(observed.components.preferences.baseline)
        let handedPrior = LockedSlot<RuntimeQuitStep>()
        let configuration = Self.finalConfiguration(
            values, incarnation: incarnation, runtime: observedRuntime, platform: observedPlatform, handedPrior: handedPrior
        )
        let quitting = Task { [client = composed.client, editor = editor(composed)] in
            await RuntimeClientQuit.quit(
                control: client, editor: editor, incarnation: incarnation, total: .seconds(30), priorUpdate: prior.requestID,
                configuration: configuration,
                preferences: { requestID, _ in
                    var preferences = values.preferences
                    preferences.preferredBrowserTestURL = "https://final.example.test/"
                    return try PrivateConfigurationBridge.makePreferencesRequest(
                        preferences: preferences, requestID: requestID, incarnation: incarnation,
                        budget: try ControlWireBudget(1_000), preferencesBaseline: preferencesBaseline
                    )
                }
            )
        }
        let fenced = try await eventually { composed.host.workflow.isTerminal }
        XCTAssertTrue(fenced, "the Quit fences while the earlier update is still in the store")
        XCTAssertEqual(composed.composition.privateCustody.held.input, true, "the earlier update still holds the one frozen input")
        XCTAssertNil(handedPrior.value, "no final save is mapped while that input is held")
        files.hold.release()
        let result = await quitting.value

        guard case .settled(.configurationSettled(let priorReceipt)) = result.priorUpdate else {
            return XCTFail("the earlier update settles with its receipt: \(result.priorUpdate)")
        }
        // The earlier save is ordinary work: the Quit's latch revoked its runtime write, which had not started, and its platform file was
        // verified. The final save keeps the runtime baseline it was submitted at, because the receipt names no new one.
        XCTAssertEqual(priorReceipt.runtime.write, .notAttempted(.superseded))
        XCTAssertNil(priorReceipt.runtime.baseline)
        XCTAssertEqual(priorReceipt.platform.write, .unchanged)
        XCTAssertEqual(handedPrior.value, result.priorUpdate, "the producer saw that receipt")
        guard case .settled(.configurationSettled(let final)) = result.configuration else {
            return XCTFail("the final configuration save settles with its receipt: \(result.configuration)")
        }
        XCTAssertEqual(final.runtime.write, .persisted(reportedError: false))
        guard case .settled(.preferencesSettled(let preferences)) = result.preferences else {
            return XCTFail("the final preferences save settles with its receipt: \(result.preferences)")
        }
        XCTAssertEqual(preferences.preferences.write, .persisted(reportedError: false))
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit settles: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertNil(result.observationFailure)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Final")
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.composition.privateCustody.held.input, false)
    }

    /// A final configuration producer for the client quit: `values` renamed "Final", at the baselines the draft was submitted at, rebased
    /// only from the earlier update's settled receipt. It records the prior step it was handed.
    private nonisolated static func finalConfiguration(
        _ values: (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences),
        incarnation: ControlHostIncarnation,
        runtime: PrivateBaseline,
        platform: PrivateBaseline,
        handedPrior: LockedSlot<RuntimeQuitStep>
    ) -> @Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest {
        { requestID, prior in
            handedPrior.set(prior)
            var runtimeBaseline = runtime
            var platformBaseline = platform
            if case .settled(.configurationSettled(let receipt)) = prior {
                runtimeBaseline = receipt.runtime.baseline ?? runtimeBaseline
                platformBaseline = receipt.platform.baseline ?? platformBaseline
            }
            var config = values.config
            config.profileName = "Final"
            return try PrivateConfigurationBridge.makeRequest(
                config: config, platform: values.platform, requestID: requestID, incarnation: incarnation,
                budget: try ControlWireBudget(1_000), runtimeBaseline: runtimeBaseline, platformBaseline: platformBaseline,
                modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
            )
        }
    }

    /// A settled earlier update whose own client is still decoding its reply keeps the one private transfer: the logical settlement comes
    /// before physical quiescence. The client quit sees that receipt, its final save waits for the custody's release within the same
    /// deadline instead of taking the busy transfer as its answer, and once the earlier exchange ends the declared save flushes.
    func testTheClientQuitsFinalSaveWaitsForATransferHeldPastTheEarlierUpdatesSettlement() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let held = HeldPrivateTransport(inner: composed.composition.transport)
        defer { held.release() }
        let prior = try update(composed, from: observed) { $0.profileName = "Prior" }
        held.arm(.afterReply)
        let priorCaller = Task { try await PrivateEditorClient(transport: held).submit(prior, deadline: deadline()) }
        await held.waitUntilHeld()
        // The host settled the earlier update while its caller still holds the transfer to decode the reply.
        var priorSettled = false
        for _ in 0..<64 where !priorSettled {
            if case .operationFinished(let finished) = try await stream.next(deadline()),
               case .configurationSettled(let receipt) = finished.outcome, receipt.requestID == prior.requestID {
                priorSettled = true
            }
        }
        XCTAssertTrue(priorSettled, "the earlier update settled")
        let custody = composed.composition.privateCustody
        XCTAssertEqual(custody.held.transfer, true, "its caller still holds the transfer")
        XCTAssertEqual(custody.held.input, false, "its frozen input was released before its settlement")

        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let handedPrior = LockedSlot<RuntimeQuitStep>()
        let configuration = Self.finalConfiguration(
            values, incarnation: incarnation, runtime: try XCTUnwrap(observed.components.runtime.baseline),
            platform: try XCTUnwrap(observed.components.platform.baseline), handedPrior: handedPrior
        )
        let quitting = Task { [client = composed.client, editor = editor(composed)] in
            await RuntimeClientQuit.quit(
                control: client, editor: editor, incarnation: incarnation, total: .seconds(30), priorUpdate: prior.requestID,
                configuration: configuration
            )
        }
        let waiting = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waiting, "the final save waits for the custody, not refused busy")
        XCTAssertTrue(composed.host.workflow.isTerminal, "the Quit fenced first")
        XCTAssertNil(handedPrior.value, "nothing is mapped before the transfer is free")
        held.release()
        _ = try accepted(try await priorCaller.value)
        let result = await quitting.value

        guard case .settled(.configurationSettled(let priorReceipt)) = result.priorUpdate else {
            return XCTFail("the earlier update's receipt is the routine's prior step: \(result.priorUpdate)")
        }
        XCTAssertEqual(priorReceipt.runtime.write, .persisted(reportedError: false))
        XCTAssertEqual(handedPrior.value, result.priorUpdate)
        guard case .settled(.configurationSettled(let final)) = result.configuration else {
            return XCTFail("the declared final save flushes once the transfer is free: \(result.configuration)")
        }
        XCTAssertEqual(final.runtime.write, .persisted(reportedError: false), "rebased from the earlier receipt")
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit settles: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Final")
        XCTAssertEqual(custody.held.transfer, false)
        XCTAssertEqual(custody.held.input, false)
    }

    /// An earlier update whose frame has not reached the host yet holds the custody while the host has no record of it. The client quit's
    /// lookup of it proves nothing, so its final save waits for the custody's release; the earlier update then arrives after the Quit's
    /// latch, is refused as ordinary work, and frees the custody, and the declared save flushes.
    func testTheClientQuitsFinalSaveWaitsForAnEarlierUpdateTheHostHasNotRecordedYet() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let held = HeldPrivateTransport(inner: composed.composition.transport)
        defer { held.release() }
        let prior = try update(composed, from: observed) { $0.profileName = "Prior" }
        held.arm(.beforeSend)
        let priorCaller = Task { try await PrivateEditorClient(transport: held).submit(prior, deadline: deadline()) }
        await held.waitUntilHeld()
        let custody = composed.composition.privateCustody
        XCTAssertEqual(custody.held.transfer, true)
        XCTAssertEqual(custody.held.input, true)

        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let handedPrior = LockedSlot<RuntimeQuitStep>()
        let configuration = Self.finalConfiguration(
            values, incarnation: incarnation, runtime: try XCTUnwrap(observed.components.runtime.baseline),
            platform: try XCTUnwrap(observed.components.platform.baseline), handedPrior: handedPrior
        )
        let quitting = Task { [client = composed.client, editor = editor(composed)] in
            await RuntimeClientQuit.quit(
                control: client, editor: editor, incarnation: incarnation, total: .seconds(30), priorUpdate: prior.requestID,
                configuration: configuration
            )
        }
        let waiting = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waiting, "the final save waits for the custody the unrecorded update holds")
        XCTAssertTrue(composed.host.workflow.isTerminal, "the Quit fenced first")
        held.release()
        let priorAdmission = try await priorCaller.value
        XCTAssertEqual(priorAdmission, .rejected(.hostStopping), "the earlier update arrived after the latch, as ordinary work")
        let result = await quitting.value

        XCTAssertEqual(result.priorUpdate, .notRecorded(.notRecorded))
        XCTAssertEqual(handedPrior.value, .notRecorded(.notRecorded))
        guard case .settled(.configurationSettled(let final)) = result.configuration else {
            return XCTFail("the declared final save flushes once the custody is free: \(result.configuration)")
        }
        XCTAssertEqual(final.runtime.write, .persisted(reportedError: false))
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit settles: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Final")
        XCTAssertEqual(custody.held.transfer, false)
        XCTAssertEqual(custody.held.input, false)
    }

    /// The client quit gets no stream: the app's own subscription and another window's hold both subscriber slots, so its own is refused.
    /// The earlier update is parked in its store step, so the one wait for it finds it pending. Both declared saves are still attempted:
    /// the configuration save waits for the held input, its producer is handed the receipt the one lookup after the release found, and the
    /// preferences save, attempted though no stream reports the configuration save, flushes after that save's release. With no stream to
    /// report the Quit, the routine keeps its caller to the end of the short total and reads the Quit completed there, so it never returns
    /// while the host's teardown may still run.
    func testTheClientQuitFlushesBothDeclaredSavesWhenItsSubscriptionIsRefused() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files)
        try await composed.host.startRuntime()
        let app = try await composed.client.subscribe(.live, deadline: deadline())
        defer { app.cancel() }
        let window = try await composed.client.subscribe(.live, deadline: deadline())
        defer { window.cancel() }
        _ = try await app.next(deadline())
        _ = try await window.next(deadline())
        let observed = try await observation(composed)
        let prior = try update(composed, from: observed) { $0.profileName = "Prior" }
        files.hold.arm { [platformPath = composed.harness.session.plan.platformConfig.path] name, values in
            name == "read" && values == [platformPath]
        }
        _ = try accepted(try await editor(composed).submit(prior, deadline: deadline()))
        await files.hold.waitUntilReached()

        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let preferencesBaseline = try XCTUnwrap(observed.components.preferences.baseline)
        let handedPrior = LockedSlot<RuntimeQuitStep>()
        let configuration = Self.finalConfiguration(
            values, incarnation: incarnation, runtime: try XCTUnwrap(observed.components.runtime.baseline),
            platform: try XCTUnwrap(observed.components.platform.baseline), handedPrior: handedPrior
        )
        let quitting = Task { [client = composed.client, editor = editor(composed)] in
            await RuntimeClientQuit.quit(
                control: client, editor: editor, incarnation: incarnation, total: .seconds(3), priorUpdate: prior.requestID,
                configuration: configuration,
                preferences: { requestID, _ in
                    var preferences = values.preferences
                    preferences.preferredBrowserTestURL = "https://final.example.test/"
                    return try PrivateConfigurationBridge.makePreferencesRequest(
                        preferences: preferences, requestID: requestID, incarnation: incarnation,
                        budget: try ControlWireBudget(1_000), preferencesBaseline: preferencesBaseline
                    )
                }
            )
        }
        let custody = composed.composition.privateCustody
        let waiting = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waiting, "the final save waits for the held input though the quit has no stream")
        XCTAssertTrue(composed.host.workflow.isTerminal, "the Quit fenced first")
        XCTAssertNil(handedPrior.value, "nothing is mapped while that input is held")
        files.hold.release()
        let result = await quitting.value

        XCTAssertEqual(result.observationFailure, .wire(.subscriberLimit))
        guard case .settled(.configurationSettled(let priorReceipt)) = result.priorUpdate else {
            return XCTFail("the one lookup after the release reads the earlier update's receipt: \(result.priorUpdate)")
        }
        XCTAssertEqual(priorReceipt.runtime.write, .notAttempted(.superseded))
        XCTAssertEqual(handedPrior.value, result.priorUpdate, "the producer was handed that receipt")
        guard case .settled(.configurationSettled(let final)) = result.configuration else {
            return XCTFail("the configuration save is read once the preferences save holds its released input: \(result.configuration)")
        }
        XCTAssertEqual(final.runtime.write, .persisted(reportedError: false))
        switch result.preferences {
        case .settled(.preferencesSettled(let receipt)): XCTAssertEqual(receipt.preferences.write, .persisted(reportedError: false))
        case .unsettled: break
        default: XCTFail("the preferences save is admitted: \(result.preferences)")
        }
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit is read settled before the routine returns: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp, "the host's teardown ended before the routine returned")
        XCTAssertEqual(custody.held.input, false)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Final")
        XCTAssertEqual(try AppPreferencesPersistence.load(in: composed.harness.environment).preferredBrowserTestURL, "https://final.example.test/")
    }

    /// The client quit's stream ends before the earlier update settles. Its declared save is still attempted under the same capacity wait,
    /// rebases only from the receipt the one lookup after the release reads, and is written. With the stream gone, the routine keeps its
    /// caller to the end of the short total and reads the Quit completed there, so it never returns while the host's teardown may run.
    func testTheClientQuitFlushesItsDeclaredSaveWhenItsStreamEndsEarly() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let prior = try update(composed, from: observed) { $0.profileName = "Prior" }
        files.hold.arm { [platformPath = composed.harness.session.plan.platformConfig.path] name, values in
            name == "read" && values == [platformPath]
        }
        _ = try accepted(try await editor(composed).submit(prior, deadline: deadline()))
        await files.hold.waitUntilReached()

        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let handedPrior = LockedSlot<RuntimeQuitStep>()
        let configuration = Self.finalConfiguration(
            values, incarnation: incarnation, runtime: try XCTUnwrap(observed.components.runtime.baseline),
            platform: try XCTUnwrap(observed.components.platform.baseline), handedPrior: handedPrior
        )
        let quitting = Task { [client = EarlyEndingClient(inner: composed.client), editor = editor(composed)] in
            await RuntimeClientQuit.quit(
                control: client, editor: editor, incarnation: incarnation, total: .seconds(3), priorUpdate: prior.requestID,
                configuration: configuration
            )
        }
        let custody = composed.composition.privateCustody
        let waiting = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waiting, "the final save waits for the held input after the stream ended")
        XCTAssertNil(handedPrior.value)
        files.hold.release()
        let result = await quitting.value

        XCTAssertEqual(result.observationFailure, .streamClosed(.resyncRequired))
        guard case .settled(.configurationSettled) = result.priorUpdate else {
            return XCTFail("the one lookup after the release reads the earlier update's receipt: \(result.priorUpdate)")
        }
        XCTAssertEqual(handedPrior.value, result.priorUpdate)
        switch result.configuration {
        case .settled(.configurationSettled(let final)): XCTAssertEqual(final.runtime.write, .persisted(reportedError: false))
        case .unsettled: break
        default: XCTFail("the declared save is admitted: \(result.configuration)")
        }
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit is read settled before the routine returns: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp, "the host's teardown ended before the routine returned")
        XCTAssertEqual(custody.held.input, false)
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Final")
    }

    /// With no stream to report it and the host's teardown held on a machine call, the Quit is still pending at the one final read, so the
    /// client quit reports it unsettled, and only once the whole total deadline has passed: its caller is never let go while that teardown
    /// may still run. The real clock bounds only from below; nothing is timed.
    func testTheClientQuitKeepsItsCallerToTheTotalDeadlineWhileAnUnobservedTeardownIsHeld() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let total = Duration.seconds(2)
        let began = ContinuousClock.now
        let quitting = Task { [client = EarlyEndingClient(inner: composed.client), editor = editor(composed), incarnation = composed.host.incarnation] in
            await RuntimeClientQuit.quit(control: client, editor: editor, incarnation: incarnation, total: total, now: began)
        }
        await composed.harness.hold.waitUntilReached()
        XCTAssertTrue(composed.host.workflow.isTerminal, "the Quit latched and its teardown is held")
        let result = await quitting.value
        let returned = ContinuousClock.now

        guard case .unsettled = result.quit else { return XCTFail("a Quit still tearing down is reported unsettled: \(result.quit)") }
        XCTAssertEqual(result.observationFailure, .streamClosed(.resyncRequired))
        XCTAssertGreaterThanOrEqual(returned, began.advanced(by: total), "the caller is kept to the total deadline itself")
        XCTAssertGreaterThan(composed.host.pendingAdmissions, 0, "the quit's held work had not ended when the routine returned")

        composed.harness.hold.release()
        let ended = try await eventually { !composed.host.runtimeState().proxyIsUp && composed.host.pendingAdmissions == 0 }
        XCTAssertTrue(ended, "the released teardown ends the quit")
    }

    /// A client quit whose total deadline has already passed reports the deadline, not an invalid value, and latches nothing.
    func testTheClientQuitReportsAnExhaustedBudgetAsItsDeadline() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let result = await RuntimeClientQuit.quit(
            control: composed.client, editor: editor(composed), incarnation: composed.host.incarnation, total: .zero
        )
        XCTAssertEqual(result.quit, .clientFailure(.notSent(.deadlineExpired)))
        XCTAssertFalse(composed.host.workflow.isTerminal)
    }

    /// An invalid runtime draft does not hold back a valid sidecar edit at quit: the final save carries the last clean runtime value under
    /// its exact submitted baseline, so the runtime file is verified unchanged and only the platform file is written. The quit applies
    /// nothing and writes no DNS disable.
    func testTheClientQuitFlushesASidecarEditBesideTheCleanRuntimeValueAndWritesNoDisable() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let values = try PrivateConfigurationBridge.makeValues(from: observed)
        let incarnation = composed.host.incarnation
        let runtimeBaseline = try XCTUnwrap(observed.components.runtime.baseline)
        let platformBaseline = try XCTUnwrap(observed.components.platform.baseline)
        let result = await RuntimeClientQuit.quit(
            control: composed.client, editor: editor(composed), incarnation: incarnation, total: .seconds(30),
            configuration: { requestID, _ in
                var platform = values.platform
                platform.manageEnvironmentVariables = false
                return try PrivateConfigurationBridge.makeRequest(
                    config: values.config, platform: platform, requestID: requestID, incarnation: incarnation,
                    budget: try ControlWireBudget(1_000), runtimeBaseline: runtimeBaseline, platformBaseline: platformBaseline,
                    modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
                )
            }
        )
        XCTAssertEqual(result.priorUpdate, .notDeclared)
        XCTAssertEqual(result.preferences, .notDeclared)
        guard case .settled(.configurationSettled(let receipt)) = result.configuration else {
            return XCTFail("the final save settles with its receipt: \(result.configuration)")
        }
        XCTAssertEqual(receipt.runtime.write, .unchanged, "the clean runtime value is verified, not rewritten")
        XCTAssertEqual(receipt.platform.write, .persisted(reportedError: false))
        XCTAssertNil(receipt.applied, "the final save applies nothing")
        guard case .settled(let quit) = result.quit else { return XCTFail("the Quit settles: \(result.quit)") }
        XCTAssertEqual(completed(quit), .quit)
        XCTAssertFalse(try PlatformConfigPersistence.load(in: composed.harness.environment).manageEnvironmentVariables)
        XCTAssertEqual(composed.harness.savedDNSEnabled, true, "the quit writes no DNS disable")
    }

    /// A final save that asks for anything but save-only is refused before it leaves the client, so the quit never applies or starts a
    /// module. The declared part then keeps the host's window open until the short total deadline; only the refusal and the unchanged file
    /// are checked, nothing about timing.
    func testTheClientQuitRefusesANonSaveOnlyFinalSaveLocally() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let observed = try await observation(composed)
        let incarnation = composed.host.incarnation
        let request = try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        )) { $0.profileName = "Never applied" }
        let saved = try Data(contentsOf: composed.harness.environment.configFile)
        let result = await RuntimeClientQuit.quit(
            control: composed.client, editor: editor(composed), incarnation: incarnation, total: .seconds(2),
            configuration: { requestID, _ in
                var asked = request
                asked.requestID = requestID
                return asked
            }
        )
        XCTAssertEqual(result.configuration, .clientFailure(.localRefusal(.invalidValue)))
        XCTAssertEqual(try Data(contentsOf: composed.harness.environment.configFile), saved)
    }

    /// The saved pair an apply verified is replaced while the apply is parked inside its reconciler pass, after the push and before its flag
    /// actions: a login-item administration write moves the platform file's version and changes no module revision, so only the store's
    /// still-holds check sees it (decision 0037). The rest of that apply holds: its environment clear never runs, and its receipt does not
    /// claim the pair was applied. A module Stop during the apply is the revision witness, separately.
    func testASavedPairReplacedWhileAnApplyIsParkedHoldsTheRestOfThatApply() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        XCTAssertFalse(composed.harness.machine.launchdEnvironment.isEmpty, "the running proxy manages the environment")
        let observed = try await observation(composed)
        let revisions = composed.host.workflow.revisions
        let request = try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        ), editPlatform: { $0.manageEnvironmentVariables = false }) { $0.noProxyHosts.append("bypass.example") }

        // The pass pushes the runtime input, then re-advertises the bypass list in the manual-mode system proxy before any flag action.
        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        await composed.harness.hold.waitUntilReached()
        XCTAssertFalse(composed.harness.hold.reachedOnMainThread)
        XCTAssertTrue(composed.host.heldRuntimeConfig.noProxyHosts.contains("bypass.example"), "the push already ran")

        let platformBaseline = try XCTUnwrap(composed.host.workflow.editorCapture().observation().components.platform.baseline)
        XCTAssertGreaterThan(platformBaseline.version, try XCTUnwrap(observed.components.platform.baseline).version,
                             "the apply's own platform write verified")
        let admin = try accepted(try await submit(composed, .setLaunchAtLogin(true, ifPlatformBaseline: platformBaseline)))
        guard case .completed(let completion) = try await finished(admin, on: stream),
              case .platformWrite(let write) = completion.result else {
            return XCTFail("the administration write completes with its platform write")
        }
        XCTAssertEqual(write.write, .persisted(reportedError: false))

        composed.harness.hold.release()
        let settled = try receipt(try await finished(operation, on: stream))
        XCTAssertEqual(settled.platform.write, .persisted(reportedError: false))
        XCTAssertEqual(settled.applied, false, "a replaced pair is not reported applied")
        XCTAssertFalse(composed.harness.machine.launchdEnvironment.isEmpty, "the replaced pair's environment clear never ran")
        XCTAssertEqual(composed.host.workflow.revisions, revisions)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
    }

    /// An apply that moves the proxy onto an occupied port: the runtime takes the new input though its listener cannot bind. The receipt says
    /// the runtime took it, the accepted view follows it rather than lagging behind, and the snapshot shows the listener down.
    func testAnApplyOntoAnOccupiedPortReportsTheInputTakenAndTheListenerDown() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let occupied = try HeldTCPListener()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let generation = composed.host.configGeneration
        let request = try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .applyWhileRunning(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision), dns: .saveOnly, tunnels: .saveOnly
        )) { $0.localPort = occupied.port }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let outcome = try await finished(operation, on: stream)
        let settled = try receipt(outcome)
        XCTAssertEqual(settled.applied, true, "the runtime took the input")
        XCTAssertEqual(composed.host.heldRuntimeConfig.localPort, occupied.port)
        XCTAssertEqual(composed.host.config.localPort, occupied.port, "the accepted view does not lag the runtime")
        XCTAssertGreaterThan(composed.host.configGeneration, generation)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp, "the failed listener is not reported as running")
        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertNotEqual(snapshot.proxyState, .running)
    }

    /// A capacity wait holds the custody's one permit and one timer. A physical release wakes it and its caller has the reservation at
    /// once; a cancelled caller has its end at once. In both cases the cancelled timer keeps the permit until it physically ends, so a
    /// second waiter is refused busy and arms no timer meanwhile. A deadline ends a wait the same way.
    func testACapacityWaitHoldsOnePermitAndTimerUntilTheTimerPhysicallyEnds() async throws {
        let custody = RuntimePrivateCustody(limits: try RuntimeServiceFixtures.limits())
        let clock = ManualRuntimeTiming()
        clock.holdCancelledCompletions()
        let deadline = RuntimeDeadline.after(.seconds(30), from: clock.now)
        // Each answer lands in a slot; every task is cancelled, or its clock released, before it is awaited, so a regression fails an
        // assertion instead of hanging the test.
        func waiting(_ purpose: PrivateExchangePurpose) -> (Task<Void, Never>, LockedSlot<Result<RuntimePrivateReservation, RuntimeWaitEnd>>) {
            let answer = LockedSlot<Result<RuntimePrivateReservation, RuntimeWaitEnd>>()
            let task = Task { answer.set(await custody.reserve(purpose, until: deadline, timing: clock.timing)) }
            return (task, answer)
        }
        func secondWaiterRefusedWithoutATimer() async throws -> Bool {
            let timers = clock.armedTimerCount
            let (task, answer) = waiting(.read)
            let answered = try await eventually { answer.value != nil }
            task.cancel()
            await task.value
            guard answered, case .failure(.transportBusy)? = answer.value else { return false }
            return clock.armedTimerCount == timers
        }

        // Woken by a release: the caller reserves while its cancelled timer is still held.
        let first = try XCTUnwrap(custody.reserve(.update))
        let (woken, wokenAnswer) = waiting(.update)
        let registered = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(registered)
        XCTAssertEqual(clock.armedTimerCount, 1, "one timer for the wait")
        first.end()
        let reserved = try await eventually { wokenAnswer.value != nil }
        XCTAssertTrue(reserved, "the release wakes the wait")
        XCTAssertEqual(clock.heldCancellationCount, 1, "the caller has its answer before its cancelled timer ended")
        XCTAssertTrue(custody.capacityPermitHeld, "that timer keeps the permit")
        let refusedWhileHeld = try await secondWaiterRefusedWithoutATimer()
        XCTAssertTrue(refusedWhileHeld, "a second waiter is refused busy and arms no timer")
        clock.releaseHeldCancellations()
        woken.cancel()
        await woken.value
        guard case .success(let reservation)? = wokenAnswer.value else { return XCTFail("the release lets the wait reserve") }
        defer { reservation.end() }
        let freed = try await eventually { !custody.capacityPermitHeld }
        XCTAssertTrue(freed, "the permit returns once the timer has ended")

        // A cancelled caller has its end at once; its timer again holds the permit until it ends.
        let (cancelled, cancelledAnswer) = waiting(.update)
        let waitingAgain = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waitingAgain)
        cancelled.cancel()
        let ended = try await eventually { cancelledAnswer.value != nil }
        XCTAssertTrue(ended)
        if case .failure(.cancelled)? = cancelledAnswer.value {} else { XCTFail("the cancelled caller ends unsent") }
        XCTAssertEqual(clock.heldCancellationCount, 1)
        let refusedAfterCancel = try await secondWaiterRefusedWithoutATimer()
        XCTAssertTrue(refusedAfterCancel)
        clock.releaseHeldCancellations()
        await cancelled.value
        let freedAgain = try await eventually { !custody.capacityPermitHeld }
        XCTAssertTrue(freedAgain)

        // The deadline ends the wait through its own timer, which then ends too.
        let (expiring, expiringAnswer) = waiting(.update)
        let waitingLast = try await eventually { custody.isAwaitingCapacity }
        XCTAssertTrue(waitingLast)
        clock.advance(by: .seconds(31))
        clock.fireAll()
        let expired = try await eventually { expiringAnswer.value != nil }
        expiring.cancel()
        clock.releaseHeldCancellations()
        await expiring.value
        XCTAssertTrue(expired)
        if case .failure(.deadlineExpired)? = expiringAnswer.value {} else { XCTFail("the deadline ends the wait") }
        let freedLast = try await eventually { !custody.capacityPermitHeld }
        XCTAssertTrue(freedLast)
        XCTAssertEqual(clock.armedTimerCount, 0)
    }

    /// While the composition's private transfer is held, another private exchange is refused before anything is encoded, and ordinary
    /// status still answers.
    func testABusyPrivateTransferRefusesBeforeEncodingAndStatusStillAnswers() async throws {
        let composed = try await compose()
        let held = try XCTUnwrap(composed.composition.privateCustody.reserve(.read))
        do {
            _ = try await editor(composed).read(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation,
                budget: try ControlWireBudget(1_000), deadline: deadline()
            )
            XCTFail("a second private exchange is refused")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .notSent(.transportBusy))
        }
        _ = try await composed.client.readSnapshot(deadline: deadline())
        held.end()
        XCTAssertEqual(composed.composition.privateCustody.held.transfer, false)
    }

    // MARK: - Presentation revision

    private func projected(_ profile: String, at revision: Int) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded),
            stamp: ControlRuntimeStamp(
                incarnation: RuntimeServiceFixtures.incarnation(1),
                presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: revision)),
                configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 0)),
                lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 0))
            ),
            profileName: profile,
            collectionRevisions: ControlCollectionRevisions()
        )
    }

    /// The revision moves only with the body; a settlement no projection reflects reserves the next revision once, which the next body
    /// takes; a failure episode is reported once; and at the maximum a changed body and a reservation both fail closed.
    func testThePresentationRevisionMovesWithItsBodyReservesForASettlementAndFailsClosedAtTheMaximum() throws {
        var presentation = RuntimeHostPresentation()
        let first = try XCTUnwrap(presentation.stamp(try projected("A", at: 0)))
        XCTAssertEqual(presentation.stamp(try projected("A", at: 0)), first, "an equal body keeps its revision")
        XCTAssertEqual(presentation.stamp(try projected("B", at: 0))?.stamp.presentationRevision.rawValue, 1)

        XCTAssertTrue(presentation.projectionFailed(), "a failure begins an episode")
        XCTAssertFalse(presentation.projectionFailed(), "a repeated failure is the same episode")
        XCTAssertTrue(presentation.reserveUnprojected())
        XCTAssertTrue(presentation.reserveUnprojected())
        XCTAssertEqual(presentation.revision, 2, "repeated reservations name one revision")
        let recovered = presentation.stamp(try projected("B", at: 2))
        XCTAssertEqual(recovered?.stamp.presentationRevision.rawValue, 2, "the first body after a reservation takes it")
        XCTAssertFalse(presentation.failing, "a stamped body ends the episode")
        XCTAssertTrue(presentation.projectionFailed(), "a later failure begins a new episode")

        var exhausted = RuntimeHostPresentation(revision: Int.max)
        XCTAssertNotNil(exhausted.stamp(try projected("A", at: Int.max)))
        XCTAssertNil(exhausted.stamp(try projected("B", at: Int.max)), "a changed body past the maximum is refused, not given the old revision")
        XCTAssertFalse(exhausted.reserveUnprojected(), "no newer revision exists for a settlement")
        XCTAssertEqual(exhausted.last?.profileName, "A")
    }

    /// While the host cannot project its state, reads fail closed and the diagnostic is recorded once. A DNS Stop completed meanwhile names
    /// the next revision, above any snapshot a subscriber holds, and the first snapshot after recovery takes exactly that revision and shows
    /// the Stop. The negative flap total is the reachable failure the review traced from a wall-clock step.
    func testAStopCompletedWhileTheSnapshotFailsNamesTheRevisionTheRecoveredSnapshotTakes() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let before = try await composed.client.readSnapshot(deadline: deadline()).stamp.presentationRevision

        composed.host.orchestrator.mutateSnapshotForTesting { $0.runtimeStatus.metrics.vpnFlapTotalDuration = -1 }
        for _ in 0..<2 {
            do {
                _ = try await composed.client.readSnapshot(deadline: deadline())
                XCTFail("a read fails closed while the projection fails")
            } catch let error as RuntimeClientError {
                XCTAssertEqual(error, .wire(.internalFailure))
            }
        }
        let operation = try accepted(try await submit(composed, .stop(.dns)))
        let outcome = try await finished(operation, on: stream)
        guard case .completed(let completion) = outcome else { return XCTFail("the Stop's effect completed: \(outcome)") }
        XCTAssertEqual(completion.command, .stop)
        XCTAssertGreaterThan(completion.presentationRevision, before, "the completion never names the body from before it")
        XCTAssertEqual(composed.host.orchestrator.snapshot.runtimeStatus.metrics.vpnFlapTotalDuration, -1, "the DNS Stop kept the failure")
        XCTAssertEqual(unavailableEvents(composed.host), 1, "one diagnostic for the whole failure episode")

        composed.host.orchestrator.mutateSnapshotForTesting { $0.runtimeStatus.metrics.vpnFlapTotalDuration = 0 }
        let recovered = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(recovered.stamp.presentationRevision, completion.presentationRevision)
        XCTAssertNotEqual(recovered.dnsRunState, .running, "the recovered snapshot shows the Stop")
        XCTAssertEqual(unavailableEvents(composed.host), 1)
    }

    /// Every service fault the owner receives is recorded as its own typed health value, whose detail keeps the untyped record's
    /// `fault=` spelling, and the bridge carries the same value to the wire. One record per report: the owner adds no coalescing.
    func testEveryServiceFaultIsRecordedAsItsOwnTypedHealthEvent() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let faults: [(ControlServiceFault, RuntimeServiceFault, String)] = [
            (.submitCommandNotEncodable, .submitCommandNotEncodable, "submit_command_not_encodable"),
            (.outcomeNotEncodable, .outcomeNotEncodable, "outcome_not_encodable"),
            (.projectionNotEncodable, .projectionNotEncodable, "projection_not_encodable"),
            (.projectionCountMismatch, .projectionCountMismatch, "projection_count_mismatch"),
            (.snapshotIncarnationMismatch, .snapshotIncarnationMismatch, "snapshot_incarnation_mismatch"),
            (.revisionTotalChanged, .revisionTotalChanged, "revision_total_changed"),
            (.collectionAccountingMismatch, .collectionAccountingMismatch, "collection_accounting_mismatch"),
            (.quiescenceAccountingMismatch, .quiescenceAccountingMismatch, "quiescence_accounting_mismatch"),
            (.snapshotNotEncodable, .snapshotNotEncodable, "snapshot_not_encodable"),
            (.snapshotOverBound, .snapshotOverBound, "snapshot_over_bound"),
            (.snapshotRevisionConflict, .snapshotRevisionConflict, "snapshot_revision_conflict"),
            (.snapshotRevisionRegressed, .snapshotRevisionRegressed, "snapshot_revision_regressed"),
        ]
        XCTAssertEqual(Set(faults.map(\.1)), Set(RuntimeServiceFault.allCases), "each domain fault has exactly one service site")
        for (fault, recorded, spelling) in faults {
            composed.host.serviceFault(fault)
            let event = try XCTUnwrap(composed.host.orchestrator.eventLog.events.last)
            XCTAssertEqual(event.typed, .runtimeService(.fault(recorded)))
            XCTAssertEqual(event.kind, .health)
            XCTAssertEqual(event.event, RuntimeServiceEventName.fault.rawValue)
            XCTAssertEqual(event.detail, "fault=\(spelling)")
            XCTAssertEqual(ControlRuntimeEvent(event).typed, .runtimeService(.fault(try XCTUnwrap(ControlRuntimeServiceFault(rawValue: spelling)))))
        }
        composed.host.serviceFault(.snapshotOverBound)
        let reports = composed.host.orchestrator.eventLog.events.filter { $0.typed == .runtimeService(.fault(.snapshotOverBound)) }
        XCTAssertEqual(reports.count, 2)
    }

    // MARK: - Stop

    /// A Stop through the client is fenced in the service's admission turn, before its teardown's first machine call and before any store
    /// work. Held at that call, DNS is already fenced and nothing is saved; released, the teardown restores system DNS and the session
    /// Stop's disable is saved, and the operation settles as a completed Stop.
    func testAStopThroughTheClientFencesBeforeItsTeardownAndSavesItsDisableAfter() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.setDNSServers.rawValue }
        let revisionBefore = composed.host.workflow.revisions.dns
        let admission = try await composed.client.submit(
            .stop(.dns), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        let operation = try accepted(admission)
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "the fence holds at admission")
        XCTAssertGreaterThan(composed.host.workflow.revisions.dns, revisionBefore)

        await composed.harness.hold.waitUntilReached()
        XCTAssertFalse(composed.harness.hold.reachedOnMainThread)
        XCTAssertTrue(composed.host.workflow.isIdle, "no store work runs before the teardown")
        XCTAssertEqual(composed.harness.savedDNSEnabled, true, "nothing is saved while the teardown is held")
        composed.harness.hold.release()

        let outcome = try await finished(operation, on: stream)
        XCTAssertEqual(completed(outcome), .stop)
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning, "system DNS is restored")
        XCTAssertEqual(composed.harness.savedDNSEnabled, false, "the session Stop's disable is saved after the teardown")
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp, "the proxy keeps running")
        XCTAssertEqual(composed.composition.service.liveOperationCount, 0, "the operation quiesced")
    }

    /// A second Stop of the same module while the first is pending joins it: one fence, one teardown and one settlement.
    func testARepeatedStopJoinsThePendingStopWhileItsFenceStands() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let first = try accepted(try await composed.client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        ))
        await composed.harness.hold.waitUntilReached()
        let revision = composed.host.workflow.revisions.proxy
        let second = try await composed.client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(second, .joined(first))
        XCTAssertEqual(composed.host.workflow.revisions.proxy, revision, "a joined Stop takes no new fence")
        composed.harness.hold.release()

        let outcome = try await finished(first, on: stream)
        XCTAssertEqual(completed(outcome), .stop)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.host.orchestrator.snapshot.dnsRunState, .running, "DNS is outside the Stop's scope")
    }

    /// A Stop queued behind an active one is dropped when a newer Stop replaces it. Stop A is held at its teardown; a Restart moves the
    /// proxy's revision, so Stop B fences again and queues behind A; another Restart moves it again, and Stop C replaces the queued B. B is
    /// settled as superseded by C and never runs, its admission is released, and once everything ends no admission or operation is left.
    func testAQueuedStopReplacedByANewerStopIsDroppedAndItsAdmissionReleased() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        func restart() async throws -> ControlOperationID {
            let observed = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision
            return try accepted(try await submit(composed, .restart(.proxy, ifLifecycleRevision: observed)))
        }

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let stopA = try accepted(try await submit(composed, .stop(.proxy)))
        await composed.harness.hold.waitUntilReached()
        let restart1 = try await restart()
        let stopB = try accepted(try await submit(composed, .stop(.proxy)))
        XCTAssertEqual(composed.composition.service.stopSlotState(.proxy).queued, true, "B queues behind the active A")
        let restart2 = try await restart()
        let stopC = try accepted(try await submit(composed, .stop(.proxy)))
        let dropped = try await composed.client.outcome(of: stopB, expectedIncarnation: composed.host.incarnation, deadline: deadline())
        XCTAssertEqual(dropped, .finished(.superseded(by: stopC)))
        composed.harness.hold.release()

        let outcomes = try await finishedAll([stopA, stopB, stopC, restart1, restart2], on: stream)
        XCTAssertEqual(outcomes[stopA], .superseded(by: stopB))
        XCTAssertEqual(outcomes[stopC].flatMap { completed($0) }, .stop)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp, "the latest Stop holds the proxy down")
        XCTAssertEqual(composed.composition.service.liveOperationCount, 0, "every operation quiesced")
        XCTAssertEqual(composed.host.pendingAdmissions, 0, "the dropped Stop's admission was released")
        XCTAssertTrue(composed.host.controlAdmissions.isEmpty)
    }

    /// A failure bound on real effects: polls an observed boundary, never decides by time.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// An admitted Stop launches even when every caller reference to its composition is gone before its launch hop runs: the hop holds the
    /// service, so the fenced work is not stranded in the owner. Manual hops make the order exact.
    func testAnAdmittedStopLaunchesAndQuiescesAfterItsCallerDroppedTheComposition() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: true)
        self.harness = harness
        let host = try await harness.makeHost()
        try await host.startRuntime()
        let scheduling = ManualOwnerScheduling()
        weak var released: RuntimeServiceCore?
        do {
            let composition = RuntimeControlComposition(
                host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
            )
            released = composition.service
            let admission = composition.service.submit(ControlOperationRequest(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .stop(.dns)
            ))
            _ = try accepted(admission)
        }
        XCTAssertNotNil(released, "the queued launch keeps the service")
        XCTAssertEqual(host.controlAdmissions.count, 1)
        XCTAssertTrue(host.workflow.dnsIntent.fenced)
        scheduling.drainAll()
        XCTAssertTrue(host.controlAdmissions.isEmpty, "the launch handed the admission to its effect")
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet, "the effect ran to its end")
        XCTAssertFalse(harness.machine.dnsRelayRunning, "the fenced Stop tore DNS down")
        XCTAssertEqual(harness.savedDNSEnabled, false, "and saved its disable")
    }

    /// A Stop whose launch is delayed until after a newer Start of its module acts on nothing: its teardown names only modules still at the
    /// revision its fence took, so the newer runtime keeps running and the Stop settles as stale.
    func testAStopLaunchedAfterANewerStartLeavesTheNewerRuntimeRunning() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        try await host.startRuntime()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let operation = try accepted(composition.service.submit(ControlOperationRequest(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .stop(.proxy)
        )))
        let restarted = try await host.startProxy(conditionalDNS: false)
        XCTAssertEqual(restarted.modules.proxy, .started, "the newer Start clears the fence and runs")

        scheduling.drainAll()
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet)
        XCTAssertTrue(host.runtimeState().proxyIsUp, "the stale Stop did not stop the newer runtime")
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertEqual(composition.service.operationLookup(ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation)),
                       .finished(.failed(.staleRevision)))
    }

    // MARK: - Restart

    /// The ordinary menu Restart names the whole-host lifecycle counter the client read. It restarts the proxy through the host's one Start
    /// path, with no companion and no editor values, and settles with its causal receipt under its own group: the proxy member started, and
    /// the saved pair it verified unchanged against the baselines it captured. The same request at the old counter is then refused whole,
    /// and nothing changes.
    func testAProxyRestartAtTheObservedRevisionRestartsAndAStaleOneIsRefusedWhole() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision
        let before = try await observation(composed).components

        let requestID = ControlRequestID(rawValue: UUID())
        let operation = try accepted(try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: observed), requestID: requestID,
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        ))
        let settled = try receipt(try await finished(operation, on: stream))
        XCTAssertEqual(settled.requestID, requestID)
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertNil(settled.conditionalDNS)
        XCTAssertEqual(settled.runtime.write, .unchanged)
        XCTAssertEqual(settled.prior, ControlCommitPrior(runtime: before.runtime.baseline, platform: before.platform.baseline))
        XCTAssertEqual(settled.runtime.baseline, before.runtime.baseline, "an unchanged pair keeps its baselines")
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        let group = observed.rawValue + 1
        XCTAssertTrue(composed.harness.typedEvents().contains(.lifecycle(.moduleSettled(
            LifecycleModuleSettled(settlement: .explicit(.proxy, .started), group: group)
        ))), "the Restart's proxy member settles under its own group")
        XCTAssertFalse(composed.harness.typedEvents().contains { payload in
            if case .lifecycle(.moduleSettled(let settled)) = payload, settled.group == group,
               case .conditionalDNS = settled.settlement { return true }
            return false
        }, "a Restart that names no DNS revision has no companion")

        let generation = composed.host.workflow.generation
        let stale = try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: observed), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(stale, .rejected(.staleRevision))
        XCTAssertEqual(composed.host.workflow.generation, generation, "a refused request changes no intent")
        XCTAssertTrue(composed.harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .staleRevision
        )))))
    }

    /// A menu Restart that names the DNS revision the client read asks for the conditional companion: with DNS configured, unfenced and
    /// down, the companion starts it beside the proxy. Once a DNS Stop moves DNS's revision, a Restart naming the old one is refused whole,
    /// even at the current whole-host counter, and nothing changes.
    func testARestartNamingTheObservedDNSRevisionStartsTheCompanionAndAMovedOneIsRefusedWhole() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await composed.client.readSnapshot(deadline: deadline()).stamp
        let modules = try XCTUnwrap(observed.modules, "the host reports each module's revision")
        XCTAssertEqual(modules.dns.rawValue, composed.host.workflow.revisions.dns)

        let restart = try accepted(try await submit(
            composed, .restart(.proxy, ifLifecycleRevision: observed.lifecycleRevision, conditionalDNSRevision: modules.dns)
        ))
        let settled = try receipt(try await finished(restart, on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.conditionalDNS, .started, "the companion's own result, apart from the members")
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning, "the companion started the configured DNS")
        XCTAssertTrue(composed.harness.typedEvents().contains(.lifecycle(.moduleSettled(LifecycleModuleSettled(
            settlement: .conditionalDNS(.started), group: observed.lifecycleRevision.rawValue + 1
        )))))

        let stop = try accepted(try await submit(composed, .stop(.dns)))
        _ = try await finished(stop, on: stream)
        let current = try await composed.client.readSnapshot(deadline: deadline()).stamp
        let generation = composed.host.workflow.generation
        let stale = try await submit(
            composed, .restart(.proxy, ifLifecycleRevision: current.lifecycleRevision, conditionalDNSRevision: modules.dns)
        )
        XCTAssertEqual(stale, .rejected(.staleRevision), "the client's DNS revision is checked as given")
        XCTAssertEqual(composed.host.workflow.generation, generation)
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning)
    }

    /// A private proxy Start whose DNS slot is the conditional companion, at the DNS revision the client observed.
    private func conditionalStart(
        _ composed: Composed,
        from observed: PrivateEditorObservation,
        dnsRevision: ControlLifecycleRevision? = nil,
        edit: (inout ProxyConfig) -> Void = { _ in }
    ) throws -> PrivateConfigurationRequest {
        try update(composed, from: observed, modules: PrivateModuleSlots(
            proxy: .start(ifLifecycleRevision: observed.modules.proxy.lifecycleRevision),
            dns: .conditionalStart(ifLifecycleRevision: dnsRevision ?? observed.modules.dns.lifecycleRevision),
            tunnels: .saveOnly
        ), edit: edit)
    }

    /// A private proxy Start with the conditional DNS slot starts configured, unfenced, down DNS from the Start's own verified pair, as
    /// the menu Restart's companion does (decision 0036). Its receipt reports the companion's result apart from the proxy member, and
    /// the companion changes no DNS control and writes no enable.
    func testAPrivateProxyStartsConditionalSlotStartsConfiguredDNSFromTheSamePair() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let dnsRevision = composed.host.workflow.revisions.dns
        let request = try conditionalStart(composed, from: observed) { $0.profileName = "Shared pair" }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let settled = try receipt(try await finished(operation, on: stream))

        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.conditionalDNS, .started)
        XCTAssertEqual(settled.runtime.write, .persisted(reportedError: false))
        XCTAssertEqual(settled.committedDNSForwarderEnabled, true)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning, "the companion started the configured DNS")
        XCTAssertEqual(composed.host.heldRuntimeConfig.profileName, "Shared pair", "both modules run the Start's one verified pair")
        XCTAssertNil(settled.prior, "a private Start's priors are the baselines it submitted")
        XCTAssertEqual(composed.host.workflow.revisions.dns, dnsRevision, "the companion changes no DNS control")
        XCTAssertEqual(composed.harness.savedDNSEnabled, true)
    }

    /// Disabled, running and fenced DNS are each the companion's typed no-op through the private Start, and none of them enables DNS or
    /// clears its fence. A DNS revision the client observed before a Stop moved it refuses the whole Start before anything changes.
    func testAPrivateConditionalSlotIsATypedNoOpForDisabledRunningOrFencedDNSAndAStaleOneIsRefusedWhole() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())

        let disabled = try await observation(composed)
        let first = try accepted(try await editor(composed).submit(try conditionalStart(composed, from: disabled), deadline: deadline()))
        let notConfigured = try receipt(try await finished(first, on: stream))
        XCTAssertEqual(notConfigured.conditionalDNS, .notConfigured)
        XCTAssertEqual(notConfigured.committedDNSForwarderEnabled, false, "the companion writes no enable")
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)

        // An explicit DNS Start enables DNS; a companion then finds it running.
        let enabling = try await observation(composed)
        let dns = try accepted(try await editor(composed).submit(try update(composed, from: enabling, modules: PrivateModuleSlots(
            proxy: .saveOnly, dns: .start(ifLifecycleRevision: enabling.modules.dns.lifecycleRevision), tunnels: .saveOnly
        )) { _ in }, deadline: deadline()))
        let dnsReceipt = try receipt(try await finished(dns, on: stream))
        XCTAssertEqual(dnsReceipt.modules, [ControlModuleReceipt(module: .dns, result: .started)])
        let running = try await observation(composed)
        let again = try accepted(try await editor(composed).submit(try conditionalStart(composed, from: running), deadline: deadline()))
        let activeReceipt = try receipt(try await finished(again, on: stream))
        XCTAssertEqual(activeReceipt.conditionalDNS, .alreadyActive)

        // A DNS Stop fences DNS and moves its revision: the companion finds the fence, and a Start naming the old revision is stale.
        let stop = try accepted(try await submit(composed, .stop(.dns)))
        _ = try await finished(stop, on: stream)
        let fencedView = try await observation(composed)
        let fenced = try accepted(try await editor(composed).submit(try conditionalStart(composed, from: fencedView), deadline: deadline()))
        let fencedReceipt = try receipt(try await finished(fenced, on: stream))
        XCTAssertEqual(fencedReceipt.conditionalDNS, .fenced)
        XCTAssertEqual(fencedReceipt.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning, "the fenced DNS stays down")
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "and its fence stays")
        XCTAssertEqual(composed.harness.savedDNSEnabled, false)

        // Current baselines and proxy revision, with the DNS revision read before the Stop.
        let latest = try await observation(composed)
        XCTAssertNotEqual(latest.modules.dns.lifecycleRevision, running.modules.dns.lifecycleRevision, "the Stop moved DNS's revision")
        let saved = try Data(contentsOf: composed.harness.environment.configFile)
        let generation = composed.host.workflow.generation
        let stale = try conditionalStart(
            composed, from: latest, dnsRevision: running.modules.dns.lifecycleRevision
        ) { $0.profileName = "Never" }
        let refused = try await editor(composed).submit(stale, deadline: deadline())
        XCTAssertEqual(refused, .rejected(.staleRevision), "the observed DNS revision is checked as given")
        XCTAssertEqual(composed.host.workflow.generation, generation, "a refused request changes no intent")
        XCTAssertEqual(try Data(contentsOf: composed.harness.environment.configFile), saved, "and writes nothing")
    }

    /// A companion whose forwarder cannot bind on the frozen request's port reports its own failure in the receipt: the proxy member
    /// started and stays up, and DNS's configured intent and fence are left as they were.
    func testAPrivateConditionalSlotsFailedBindLeavesTheProxyUp() async throws {
        let held = try HeldUDPPort()
        let composed = try await compose(dnsForwarderEnabled: true)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let request = try conditionalStart(composed, from: observed) { $0.dnsForwarderPort = held.port }
        let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
        let settled = try receipt(try await finished(operation, on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.conditionalDNS, .failed)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp, "the proxy stays up")
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning)
        XCTAssertEqual(composed.host.workflow.dnsIntent.configured, true, "the failed companion keeps DNS's configured intent")
        XCTAssertEqual(composed.host.workflow.dnsIntent.fenced, false, "and sets no fence")
    }

    /// A session DNS Stop's disable write, read from its completion. Fails the test for any other completion.
    private func dnsDisable(_ outcome: ControlOperationOutcome) throws -> ControlDNSDisableWrite {
        guard case .completed(let completion) = outcome, case .dnsDisable(let write) = completion.result else {
            XCTFail("a DNS Stop completes with its disable write: \(outcome)")
            throw RuntimeClientError.unexpectedReply
        }
        return write
    }

    /// A client's dirty draft and its own DNS Stop: the Stop's completion names the runtime baseline its disable was conditional on, which
    /// is the draft's own, so the draft alone moves to the new baseline. Without that the next save conflicts with the client's own Stop;
    /// with it the later local edit persists and the committed DNS bit stays false. Nothing is reread or rebound by value.
    func testADNSStopsCausalWriteLetsTheSameClientsDirtyDraftSaveOverIt() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let draftRuntime = try XCTUnwrap(observed.components.runtime.baseline)

        let stop = try accepted(try await submit(composed, .stop(.dns)))
        let disable = try dnsDisable(try await finished(stop, on: stream))
        XCTAssertEqual(disable.prior, draftRuntime, "the disable was conditional on the baseline this draft holds")
        XCTAssertEqual(disable.runtime.write, .persisted(reportedError: false))
        let moved = try XCTUnwrap(disable.runtime.baseline)
        XCTAssertGreaterThan(moved.version, draftRuntime.version)

        // The draft as submitted: the Stop's own write conflicts with it.
        func save(at runtime: PrivateBaseline) async throws -> ControlConfigurationReceipt {
            var values = try PrivateConfigurationBridge.makeValues(from: observed)
            values.config.profileName = "Dirty"
            let request = try PrivateConfigurationBridge.makeRequest(
                config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
                incarnation: composed.host.incarnation, budget: try ControlWireBudget(1_000), runtimeBaseline: runtime,
                platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
                modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
            )
            let operation = try accepted(try await editor(composed).submit(request, deadline: deadline()))
            return try receipt(try await finished(operation, on: stream))
        }
        let unrebased = try await save(at: draftRuntime)
        XCTAssertEqual(unrebased.runtime.write, .notAttempted(.baselineMismatch), "the client's own Stop moved the baseline")

        // The causal rule: only a draft at the write's prior baseline moves to its new one.
        let rebased = disable.prior == draftRuntime ? moved : draftRuntime
        let saved = try await save(at: rebased)
        XCTAssertEqual(saved.runtime.write, .persisted(reportedError: false), "the later local edit persists")
        XCTAssertEqual(saved.committedDNSForwarderEnabled, false, "and the committed DNS bit stays the Stop's false")
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Dirty")
        XCTAssertEqual(composed.harness.savedDNSEnabled, false)
    }

    /// Another client's write between this client's observation and its DNS Stop: the Stop's disable is conditional on the other client's
    /// baseline, not this draft's, so the draft does not move and its save still conflicts. The other client's edit is kept.
    func testADNSStopAfterAnotherClientsWriteDoesNotRebaseThisDraft() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let draftRuntime = try XCTUnwrap(observed.components.runtime.baseline)

        let other = PrivateEditorClient(transport: composed.composition.transport)
        let otherOperation = try accepted(try await other.submit(
            try update(composed, from: observed) { $0.profileName = "Other" }, deadline: deadline()
        ))
        let otherReceipt = try receipt(try await finished(otherOperation, on: stream))
        let otherBaseline = try XCTUnwrap(otherReceipt.runtime.baseline)

        let stop = try accepted(try await submit(composed, .stop(.dns)))
        let disable = try dnsDisable(try await finished(stop, on: stream))
        XCTAssertEqual(disable.prior, otherBaseline, "the disable was conditional on the other client's write")
        XCTAssertNotEqual(disable.prior, draftRuntime)
        let rebased = disable.prior == draftRuntime ? try XCTUnwrap(disable.runtime.baseline) : draftRuntime

        let mine = try update(composed, from: observed) { $0.profileName = "Mine" }
        XCTAssertEqual(mine.runtimeBaseline, rebased, "the draft keeps the baseline it was submitted at")
        let operation = try accepted(try await editor(composed).submit(mine, deadline: deadline()))
        let settled = try receipt(try await finished(operation, on: stream))
        XCTAssertEqual(settled.runtime.write, .notAttempted(.baselineMismatch), "the intervening write still conflicts")
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Other")
        XCTAssertEqual(composed.harness.savedDNSEnabled, false)
    }

    /// Test DNS through the actual client probes the port the app's own Test DNS chooses, from the host's state and no editor value: port
    /// 53 while the host manages system DNS. The completion carries the probe's reading, which here is the fake's silence, and changes no
    /// intent. After the quit it is refused as stopping.
    func testTestDNSProbesTheHostsManagedPortAndReportsItsReading() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let revisions = composed.host.workflow.revisions
        let probe = try accepted(try await submit(composed, .testDNS))
        guard case .completed(let completion) = try await finished(probe, on: stream) else { return XCTFail("the probe completes") }
        XCTAssertEqual(completion.command, .testDNS)
        XCTAssertEqual(completion.result, .dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(53), answered: false)))
        XCTAssertEqual(composed.host.workflow.revisions, revisions, "a probe changes no intent")

        await composed.host.shutdown()
        let refused = try await submit(composed, .testDNS)
        XCTAssertEqual(refused, .rejected(.hostStopping))
    }

    /// A Test DNS probe waiting out its timeout holds no platform work: held inside the injected probe, off the main thread and off the
    /// platform queue, a DNS Stop's teardown and a quit's both complete through the client meanwhile. A second Test DNS of the same port
    /// joins the held probe rather than queueing its own, and both report that probe's reading once it answers.
    ///
    /// The hold is armed on whatever thread the probe runs on, so the test proves the behaviour, not a queue: a probe on the platform queue
    /// parks that queue and the Stop's teardown with it, and the bounded wait below then fails on its assertion while the probe is still
    /// held. One reader task alone pulls the stream and records each settlement; the hold is released and the reader drained on every exit.
    func testAHeldTestDNSProbeDelaysNeitherAStopNorAQuitAndARepeatJoinsIt() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())

        // The only puller of the stream from here on. It ends when the stream is cancelled; a settlement it never read shows as missing.
        let settled = LockedSlot<[ControlOperationID: ControlOperationOutcome]>()
        settled.set([:])
        let readUntil = deadline()
        let reader = Task {
            do {
                for _ in 0..<256 {
                    if case .operationFinished(let done) = try await stream.next(readUntil) {
                        var seen = settled.value ?? [:]
                        seen[done.operationID] = done.outcome
                        settled.set(seen)
                    }
                }
            } catch {
                // The test cancels the stream once it has read what it needs.
            }
        }
        func outcome(_ operation: ControlOperationID) -> ControlOperationOutcome? { settled.value?[operation] }
        let hold = composed.harness.hold
        defer { hold.release() }

        hold.arm { name, _ in name == "dns-probe" }
        let first = try accepted(try await submit(composed, .testDNS))
        await hold.waitUntilReached()
        XCTAssertFalse(hold.reachedOnMainThread, "the probe runs off the main actor")
        let second = try accepted(try await submit(composed, .testDNS))

        let stop = try accepted(try await submit(composed, .stop(.dns)))
        let stopSettled = try await eventually { outcome(stop) != nil }
        XCTAssertTrue(stopSettled, "the DNS Stop settles while the probe is held")
        XCTAssertNil(outcome(first), "the probe was still held when the Stop settled")
        XCTAssertEqual(outcome(stop).flatMap { completed($0) }, .stop, "the DNS Stop completed: \(String(describing: outcome(stop)))")
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning, "its teardown restored system DNS meanwhile")

        let quit = try accepted(try await submit(composed, .quit(total: try ControlWireBudget(30_000), flush: .none)))
        let quitSettled = try await eventually { outcome(quit) != nil }
        XCTAssertTrue(quitSettled, "the quit settles while the probe is held")
        XCTAssertNil(outcome(first), "the probe was still held when the quit settled")
        XCTAssertEqual(outcome(quit).flatMap { completed($0) }, .quit, "the quit completed: \(String(describing: outcome(quit)))")
        let asked = composed.harness.dnsProbes.values.count

        hold.release()
        let probesSettled = try await eventually { outcome(first) != nil && outcome(second) != nil }
        stream.cancel()
        await reader.value
        XCTAssertTrue(probesSettled, "each Test DNS settles once the probe answers")
        let reading = ControlCommandResult.dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(53), answered: false))
        for operation in [first, second] {
            guard case .completed(let completion)? = outcome(operation) else {
                XCTFail("each Test DNS completes: \(String(describing: outcome(operation)))")
                continue
            }
            XCTAssertEqual(completion.result, reading)
        }
        XCTAssertEqual(composed.harness.dnsProbes.values.count, asked, "the repeat joined the held probe and asked no port of its own")
    }

    // MARK: - Saved Start

    /// A saved Start through the actual framed client, at the module revision the client's own snapshot stamp names.
    private func savedStart(
        _ composed: Composed,
        _ module: ControlModule,
        conditionalDNS: Bool = false,
        requestID: ControlRequestID = ControlRequestID(rawValue: UUID())
    ) async throws -> ControlAdmission {
        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        let modules = try XCTUnwrap(snapshot.stamp.modules)
        let revision = switch module {
        case .proxy: modules.proxy
        case .dns: modules.dns
        case .tunnels: modules.tunnels
        }
        return try await composed.client.submit(
            .start(module, ifModuleRevision: revision, conditionalDNSRevision: conditionalDNS ? modules.dns : nil),
            requestID: requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
    }

    /// The menu's saved DNS Start beside a client's dirty draft (decision 0037). The Start carries no draft value: DNS starts from the saved
    /// pair its preparation captured, and the receipt names the baselines its enable was conditional on, which are this draft's, and the
    /// runtime baseline it wrote. The draft as it stands now conflicts with that write; moved by the causal rule alone, its later local edit
    /// saves over it, and the committed DNS bit stays the Start's enable rather than the draft's stale false.
    func testASavedDNSStartRunsTheSavedPairAndItsReceiptRebasesOnlyTheDraftAtItsPrior() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let draft = (runtime: try XCTUnwrap(observed.components.runtime.baseline), platform: try XCTUnwrap(observed.components.platform.baseline))
        let saved = try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName

        let requestID = ControlRequestID(rawValue: UUID())
        let start = try accepted(try await savedStart(composed, .dns, requestID: requestID))
        let settled = try receipt(try await finished(start, on: stream))
        XCTAssertEqual(settled.requestID, requestID)
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .dns, result: .started)])
        XCTAssertEqual(settled.prior, ControlCommitPrior(runtime: draft.runtime, platform: draft.platform))
        XCTAssertEqual(settled.runtime.write, .persisted(reportedError: false), "the explicit enable is a write")
        XCTAssertEqual(settled.committedDNSForwarderEnabled, true)
        let written = try XCTUnwrap(settled.runtime.baseline)
        XCTAssertGreaterThan(written.version, draft.runtime.version)
        XCTAssertEqual(settled.platform.baseline, draft.platform, "the platform file verified unchanged")
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning)
        XCTAssertEqual(composed.host.heldRuntimeConfig.profileName, saved, "DNS runs the saved pair, not any editor draft")

        func save(at runtime: PrivateBaseline, platform: PrivateBaseline) async throws -> ControlConfigurationReceipt {
            var values = try PrivateConfigurationBridge.makeValues(from: observed)
            values.config.profileName = "Dirty draft"
            let request = try PrivateConfigurationBridge.makeRequest(
                config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
                incarnation: composed.host.incarnation, budget: try ControlWireBudget(1_000), runtimeBaseline: runtime,
                platformBaseline: platform, modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
            )
            return try receipt(try await finished(try accepted(try await editor(composed).submit(request, deadline: deadline())), on: stream))
        }
        let unrebased = try await save(at: draft.runtime, platform: draft.platform)
        XCTAssertEqual(unrebased.runtime.write, .notAttempted(.baselineMismatch), "the Start's own enable moved the runtime baseline")

        // The causal rule, per file: only a draft at exactly the prior moves to the new baseline.
        let prior = try XCTUnwrap(settled.prior)
        let rebasedRuntime = prior.runtime == draft.runtime ? written : draft.runtime
        let rebasedPlatform = prior.platform == draft.platform ? try XCTUnwrap(settled.platform.baseline) : draft.platform
        let rebased = try await save(at: rebasedRuntime, platform: rebasedPlatform)
        XCTAssertEqual(rebased.runtime.write, .persisted(reportedError: false), "the later local edit persists")
        XCTAssertEqual(rebased.committedDNSForwarderEnabled, true, "the draft's stale DNS bit never reverts the Start's enable")
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false).profileName, "Dirty draft")
        XCTAssertEqual(composed.harness.savedDNSEnabled, true)
    }

    /// A saved Start over an absent platform file persists its defaults before it starts (decision 0036), and the receipt's platform prior
    /// is the absent file's own baseline, so a draft that observed the absence is the one that may move to the written baseline.
    func testASavedStartPersistsAnAbsentPlatformFilesDefaultsFromItsAbsentPrior() async throws {
        let composed = try await compose(dnsForwarderEnabled: false) { harness in
            try FileManager.default.removeItem(at: harness.environment.platformConfigFile)
        }
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        guard case .absent(let absent) = try await observation(composed).components.platform else {
            return XCTFail("the platform file is observed absent")
        }

        let settled = try receipt(try await finished(try accepted(try await savedStart(composed, .proxy)), on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.prior?.platform, absent)
        XCTAssertEqual(settled.platform.write, .persisted(reportedError: false))
        XCTAssertGreaterThan(try XCTUnwrap(settled.platform.baseline).version, absent.version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: composed.harness.environment.platformConfigFile.path), "the defaults were saved")
        guard case .verified(let now) = try await observation(composed).components.platform else {
            return XCTFail("the saved defaults are now a verified file")
        }
        XCTAssertEqual(now, settled.platform.baseline)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
    }

    /// A saved Start names the exact revisions it observed (decision 0035). After a DNS Stop moved DNS's revision, a DNS Start at the old
    /// one, and a proxy Start whose companion names it, are each refused whole before any write. At the current revisions the proxy starts,
    /// and its companion finds the Stop's fence: it starts nothing, keeps the fence and writes no enable (decision 0036).
    func testASavedStartAtAMovedRevisionIsRefusedWholeAndItsCompanionKeepsTheStopFence() async throws {
        let composed = try await compose(dnsForwarderEnabled: true)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let first = try await composed.client.readSnapshot(deadline: deadline())
        let before = try XCTUnwrap(first.stamp.modules)
        _ = try await finished(try accepted(try await submit(composed, .stop(.dns))), on: stream)
        let saved = try Data(contentsOf: composed.harness.environment.configFile)
        let generation = composed.host.workflow.generation
        let second = try await composed.client.readSnapshot(deadline: deadline())
        let current = try XCTUnwrap(second.stamp.modules)
        XCTAssertNotEqual(current.dns, before.dns)

        for stale in [
            ControlRuntimeCommand.start(.dns, ifModuleRevision: before.dns),
            .start(.proxy, ifModuleRevision: current.proxy, conditionalDNSRevision: before.dns),
        ] {
            let refused = try await submit(composed, stale)
            XCTAssertEqual(refused, .rejected(.staleRevision), "\(stale)")
        }
        XCTAssertEqual(composed.host.workflow.generation, generation, "a refused request changes no intent")
        XCTAssertEqual(try Data(contentsOf: composed.harness.environment.configFile), saved, "and writes nothing")

        let settled = try receipt(try await finished(try accepted(try await savedStart(composed, .proxy, conditionalDNS: true)), on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.conditionalDNS, .fenced)
        XCTAssertEqual(settled.committedDNSForwarderEnabled, false, "the companion writes no enable")
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning)
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "and the Stop's fence stays")
    }

    /// A reload that adopts an external edit after a saved Start was admitted and before its preparation supplies the pair it captures
    /// (decision 0037): the receipt's prior is the reloaded baseline, not the one current at admission, and the proxy runs the edit. Manual
    /// hops hold the launch between the two.
    func testAReloadBeforeASavedStartsPreparationSuppliesThePairItCaptures() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let admitted = try XCTUnwrap(host.workflow.editorCapture().components.runtime.baseline)
        guard let proxy = ControlLifecycleRevision(rawValue: host.workflow.revisions.proxy) else { return XCTFail("a revision") }
        let operation = try accepted(composition.service.submit(ControlOperationRequest(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .start(.proxy, ifModuleRevision: proxy)
        )))

        var edited = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
        edited.profileName = "Reloaded before preparation"
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        await host.reloadConfiguration()
        let reloaded = try XCTUnwrap(host.workflow.editorCapture().components.runtime.baseline)
        XCTAssertNotEqual(reloaded, admitted, "the reload observed the edit")

        scheduling.drainAll()
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet)
        scheduling.drainAll()
        guard case .finished(.configurationSettled(let settled)) = composition.service.operationLookup(
            ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation)
        ) else {
            return XCTFail("the saved Start settles with its receipt")
        }
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .started)])
        XCTAssertEqual(settled.prior?.runtime, reloaded, "the capture was made at preparation, after the reload")
        XCTAssertEqual(host.heldRuntimeConfig.profileName, edited.profileName)
    }

    /// A reload that replaces the pair after a saved Start captured and committed it holds the Start's remaining effects (decision 0037):
    /// held on its PAC fetch, the Start sees the reload adopt an edit, then ends with its proxy member `superseded` and no listener left,
    /// never rebound to the edit. Its receipt still reports the verified commit and the prior it was conditional on.
    func testAReplacementAfterASavedStartsCaptureHoldsItsRemainingEffects() async throws {
        let fetch = HeldPACFetch()
        let composed = try await compose(dnsForwarderEnabled: false) { harness in
            var config = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
            config.pacRoutingEnabled = true
            config.pacURL = "http://pac.example.test/captured.pac"
            try ProxyConfigPersistence.save(config, in: harness.environment)
            harness.pacEvaluator = fetch
        }
        defer { fetch.release() }
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await observation(composed)
        let captured = try XCTUnwrap(observed.components.runtime.baseline)

        let start = try accepted(try await savedStart(composed, .proxy))
        let held = try await eventually { fetch.isHeld }
        XCTAssertTrue(held, "the Start is held on its PAC fetch, after its capture and commit")
        var edited = try ProxyConfigPersistence.load(in: composed.harness.environment, allowMissing: false)
        edited.profileName = "Edited after the capture"
        try ProxyConfigPersistence.save(edited, in: composed.harness.environment)
        let reload = Task { await composed.host.reloadConfiguration() }
        let adopted = try await eventually { composed.host.config.profileName == edited.profileName }
        XCTAssertTrue(adopted, "the reload adopted the edit while the Start was held")
        fetch.release()

        let settled = try receipt(try await finished(start, on: stream))
        await reload.value
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .superseded)], "no success for a replaced capture")
        XCTAssertEqual(settled.prior?.runtime, captured)
        XCTAssertTrue(settled.runtime.write.isVerified, "the commit it made stays a reported fact")
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp, "the held Start leaves no listener")
        XCTAssertFalse(composed.harness.machine.service("Wi-Fi").routesThroughAProxy)
    }

    /// A DNS Stop admitted while a saved DNS Start's commit is parked on its platform verification read is admitted and settles at once
    /// (decision 0015): the Start does not hold it. Released, the Start's runtime write is revoked before it begins, so the enable is never
    /// saved, and the Start reports its superseded member with no new runtime baseline and no success. DNS stays down and fenced, with no
    /// configured intent left behind.
    func testAStopWinsASavedStartParkedInItsCommitAndTheStartReportsNoSuccess() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let saved = try Data(contentsOf: composed.harness.environment.configFile)
        let platformPath = composed.harness.session.plan.platformConfig.path
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        defer { files.hold.release() }

        let start = try accepted(try await savedStart(composed, .dns))
        await files.hold.waitUntilReached()
        let stop = try accepted(try await submit(composed, .stop(.dns)))
        let stopped = try await finished(stop, on: stream)
        XCTAssertEqual(completed(stopped), .stop, "the Stop settles while the Start's store step is parked")
        files.hold.release()

        let settled = try receipt(try await finished(start, on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .dns, result: .superseded)])
        guard case .notAttempted = settled.runtime.write else {
            return XCTFail("the revoked enable is not attempted: \(settled.runtime.write)")
        }
        XCTAssertNil(settled.runtime.baseline)
        XCTAssertNil(settled.committedDNSForwarderEnabled)
        XCTAssertNotNil(settled.prior?.runtime, "the prior the revoked write would have been conditional on")
        XCTAssertEqual(try Data(contentsOf: composed.harness.environment.configFile), saved, "the enable was never saved")
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning)
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "the Stop's fence stands")
        XCTAssertFalse(composed.host.workflow.dnsIntent.configured, "and no enable was left behind")
    }

    /// The ordinary meaning of a saved Start that does not start. One that finds the store's one slot taken, here by a reload parked on its
    /// read, captured and wrote nothing, so it fails `storeBusy` with no receipt. One whose proxy cannot bind its saved port ran its commit,
    /// so it settles with its receipt: the verified pair and its prior stay reported facts, and the member is `failed`, never a success or a
    /// bare `effectFailed`.
    func testASavedStartOnABusyStoreFailsAndOneWhoseBindFailsReportsItsFailedMember() async throws {
        let occupied = try HeldTCPListener()
        let files = HeldStateFileRead()
        let composed = try await compose(dnsForwarderEnabled: false, stateFiles: files) { harness in
            var config = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
            config.localPort = occupied.port
            try ProxyConfigPersistence.save(config, in: harness.environment)
        }
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())

        let platformPath = composed.harness.session.plan.platformConfig.path
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        defer { files.hold.release() }
        let reload = Task { await composed.host.reloadConfiguration() }
        await files.hold.waitUntilReached()
        let busy = try await finished(try accepted(try await savedStart(composed, .proxy)), on: stream)
        XCTAssertEqual(busy, .failed(.storeBusy))
        files.hold.release()
        await reload.value

        let observed = try await observation(composed)
        let settled = try receipt(try await finished(try accepted(try await savedStart(composed, .proxy)), on: stream))
        XCTAssertEqual(settled.modules, [ControlModuleReceipt(module: .proxy, result: .failed)])
        XCTAssertTrue(settled.runtime.write.isVerified && settled.platform.write.isVerified, "the commit it ran stays reported")
        XCTAssertEqual(settled.prior, ControlCommitPrior(
            runtime: observed.components.runtime.baseline, platform: observed.components.platform.baseline
        ))
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        XCTAssertFalse(composed.harness.machine.service("Wi-Fi").routesThroughAProxy, "the failed bind leaves no system proxy")
    }

    /// The companion key is additive: a Restart without it encodes exactly as before, one with it round-trips, and a non-proxy Restart
    /// that names one is refused on decode. A saved Start names its module's own revision under its own key, with the same companion rule.
    func testTheRestartCompanionKeyIsAdditiveAndOnlyForTheProxy() throws {
        let revision = try XCTUnwrap(ControlLifecycleRevision(rawValue: 7))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = String(decoding: try encoder.encode(ControlRuntimeCommand.restart(.proxy, ifLifecycleRevision: revision)), as: UTF8.self)
        XCTAssertEqual(plain, #"{"lifecycleRevision":7,"module":"proxy","type":"restart"}"#)
        let companion = ControlRuntimeCommand.restart(.proxy, ifLifecycleRevision: revision, conditionalDNSRevision: revision)
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeCommand.self, from: try encoder.encode(companion)), companion)
        let invalid = Data(#"{"conditionalDNSRevision":7,"lifecycleRevision":7,"module":"dns","type":"restart"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlRuntimeCommand.self, from: invalid))
        XCTAssertThrowsError(try encoder.encode(ControlRuntimeCommand.restart(.dns, ifLifecycleRevision: revision, conditionalDNSRevision: revision)))

        let start = String(decoding: try encoder.encode(ControlRuntimeCommand.start(.tunnels, ifModuleRevision: revision)), as: UTF8.self)
        XCTAssertEqual(start, #"{"module":"tunnels","moduleRevision":7,"type":"start"}"#)
        let startCompanion = ControlRuntimeCommand.start(.proxy, ifModuleRevision: revision, conditionalDNSRevision: revision)
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeCommand.self, from: try encoder.encode(startCompanion)), startCompanion)
        let dnsCompanion = Data(#"{"conditionalDNSRevision":7,"module":"dns","moduleRevision":7,"type":"start"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlRuntimeCommand.self, from: dnsCompanion))
        XCTAssertThrowsError(try encoder.encode(ControlRuntimeCommand.start(.dns, ifModuleRevision: revision, conditionalDNSRevision: revision)))
        let wholeHost = Data(#"{"lifecycleRevision":7,"module":"dns","type":"start"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlRuntimeCommand.self, from: wholeHost), "a Start names its module's revision")
    }

    /// A saved command's receipt prior is consistent with its writes: a verified write follows a prior of its own file, and a file with no
    /// prior verified nothing. A private receipt names no prior, and encodes as before.
    func testAReceiptPriorIsRefusedWhenItCannotPrecedeItsWrites() throws {
        let namespace = PrivateBaselineNamespace(rawValue: UUID())
        func baseline(_ file: ControlConfigWorkflowFile, _ version: UInt64) -> PrivateBaseline {
            PrivateBaseline(namespace: namespace, component: file, version: version)
        }
        let runtime = try ControlComponentWrite(write: .persisted(reportedError: false), baseline: baseline(.runtime, 2))
        let platform = try ControlComponentWrite(write: .unchanged, baseline: baseline(.platform, 1))
        func make(_ prior: ControlCommitPrior?) throws -> ControlConfigurationReceipt {
            try ControlConfigurationReceipt(
                requestID: ControlRequestID(rawValue: UUID()), incarnation: ControlHostIncarnation(rawValue: UUID()),
                runtime: runtime, platform: platform, committedDNSForwarderEnabled: true,
                modules: [ControlModuleReceipt(module: .dns, result: .started)], prior: prior
            )
        }
        let saved = try make(ControlCommitPrior(runtime: baseline(.runtime, 1), platform: baseline(.platform, 1)))
        XCTAssertEqual(try JSONDecoder().decode(ControlConfigurationReceipt.self, from: try JSONEncoder().encode(saved)), saved)
        XCTAssertThrowsError(try make(ControlCommitPrior(runtime: nil, platform: baseline(.platform, 1))), "a verified write had a baseline")
        XCTAssertThrowsError(try make(ControlCommitPrior(runtime: baseline(.platform, 1), platform: baseline(.platform, 1))), "of its own file")
        let privateReceipt = try make(nil)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(privateReceipt), as: UTF8.self).contains("prior"))
    }

    /// Commands this owner has not adopted are refused whole at the fence. After the process quit, a Restart, a saved Start, a preflight
    /// refresh and a credentials invalidation are each refused as stopping.
    func testUnadoptedCommandsAreRefusedAndARestartAfterQuitIsRefused() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        let revision = snapshot.stamp.lifecycleRevision
        let upstream = ControlUpstreamReference(configRevision: snapshot.stamp.configRevision, upstreamID: ControlUpstreamID(rawValue: UUID()))
        for command in [ControlRuntimeCommand.restart(.dns, ifLifecycleRevision: revision), .testUpstream(upstream)] {
            let admission = try await composed.client.submit(
                command, requestID: ControlRequestID(rawValue: UUID()),
                expectedIncarnation: composed.host.incarnation, deadline: deadline()
            )
            XCTAssertEqual(admission, .rejected(.notImplemented), "\(command.kind.rawValue)")
        }
        XCTAssertEqual(composed.host.workflow.generation, revision.rawValue)

        await composed.host.shutdown()
        let stamp = try await composed.client.readSnapshot(deadline: deadline()).stamp
        let modules = try XCTUnwrap(stamp.modules)
        for command in [
            ControlRuntimeCommand.restart(.proxy, ifLifecycleRevision: stamp.lifecycleRevision),
            .start(.dns, ifModuleRevision: modules.dns),
            .refreshPreflight(helperReplaced: false),
            .credentialsChanged,
        ] {
            let afterQuit = try await composed.client.submit(
                command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation, deadline: deadline()
            )
            XCTAssertEqual(afterQuit, .rejected(.hostStopping), "\(command.kind.rawValue)")
        }
    }
}
