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

    private func compose(dnsForwarderEnabled: Bool = true) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: dnsForwarderEnabled)
        self.harness = harness
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

    private func unavailableEvents(_ host: RuntimeHost) -> Int {
        host.orchestrator.eventLog.events.filter { $0.event == "runtime_service.snapshot_unavailable" }.count
    }

    private func accepted(_ admission: ControlAdmission, file: StaticString = #filePath, line: UInt = #line) throws -> ControlOperationID {
        guard case .accepted(let operation) = admission else {
            XCTFail("expected an accepted admission, got \(admission)", file: file, line: line)
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    private func completed(_ outcome: ControlOperationOutcome) -> ControlRuntimeCommandKind? {
        if case .completed(let completion) = outcome, completion.result == .settled { return completion.command }
        return nil
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
        edit: (inout ProxyConfig) -> Void
    ) throws -> PrivateConfigurationRequest {
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        edit(&values.config)
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
        let quit = Task { @MainActor in await host.shutdown(reservingFlushUntil: ContinuousClock.now.advanced(by: .seconds(30))) }
        let latched = try await eventually { host.workflow.isTerminal }
        XCTAssertTrue(latched)

        let flush = try update(composed, from: observed) { $0.profileName = "Flushed" }
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
        let quit = Task { @MainActor in await host.shutdown(reservingFlushUntil: ContinuousClock.now.advanced(by: .seconds(2))) }
        let latched = try await eventually { host.workflow.isTerminal }
        XCTAssertTrue(latched)
        let operation = try accepted(try await editor.submit(request, deadline: deadline()))
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

        let quit = try accepted(try await send(.quit(total: try ControlWireBudget(30_000), flush: ControlQuitFlush(configuration: true, preferences: false))))
        XCTAssertTrue(host.workflow.isTerminal, "the quit latched in its admission turn")
        let second = try await send(.quit(total: try ControlWireBudget(30_000), flush: ControlQuitFlush(configuration: false, preferences: false)))
        XCTAssertEqual(second, .rejected(.hostStopping), "one quit per host")
        let request = try update(host: host, from: observed) { $0.profileName = "Flushed at quit" }
        let flush = try accepted(try await editor.submit(request, deadline: deadline()))

        harness.hold.release()
        let outcomes = try await finishedAll([restart, quit, flush], on: stream)
        XCTAssertEqual(outcomes[quit].flatMap(completed), .quit)
        XCTAssertEqual(try receipt(try XCTUnwrap(outcomes[flush])).runtime.write, .persisted(reportedError: false))
        XCTAssertEqual(try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false).profileName, "Flushed at quit")
        let quiet = try await eventually { host.pendingAdmissions == 0 && host.workflow.isIdle }
        XCTAssertTrue(quiet)
        XCTAssertFalse(host.runtimeState().proxyIsUp)
        XCTAssertEqual(composition.privateCustody.held.input, false)
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
        let operation = try accepted(try await editor.submit(request, deadline: deadline()))
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
    /// path, with no companion and no editor values, and settles as a completed Restart under its own group. The same request at the old
    /// counter is then refused whole, and nothing changes.
    func testAProxyRestartAtTheObservedRevisionRestartsAndAStaleOneIsRefusedWhole() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision

        let operation = try accepted(try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: observed), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        ))
        let outcome = try await finished(operation, on: stream)
        XCTAssertEqual(completed(outcome), .restart)
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
        let outcome = try await finished(restart, on: stream)
        XCTAssertEqual(completed(outcome), .restart)
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

    /// The companion key is additive: a Restart without it encodes exactly as before, one with it round-trips, and a non-proxy Restart
    /// that names one is refused on decode.
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
    }

    /// Commands this owner has not adopted are refused whole at the fence, and a Restart after the process quit is refused as stopping.
    func testUnadoptedCommandsAreRefusedAndARestartAfterQuitIsRefused() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let revision = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision
        for command in [ControlRuntimeCommand.restart(.dns, ifLifecycleRevision: revision), .testDNS, .refreshPreflight] {
            let admission = try await composed.client.submit(
                command, requestID: ControlRequestID(rawValue: UUID()),
                expectedIncarnation: composed.host.incarnation, deadline: deadline()
            )
            XCTAssertEqual(admission, .rejected(.notImplemented), "\(command.kind.rawValue)")
        }
        XCTAssertEqual(composed.host.workflow.generation, revision.rawValue)

        await composed.host.shutdown()
        let afterQuit = try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision),
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(afterQuit, .rejected(.hostStopping))
    }
}
