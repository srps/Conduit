// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import ProxyControlBridge
import RuntimeEvents

/// A request a test built ahead, sent through the client's single-use producer. Test-only: production maps inside the exchange.
fileprivate extension PrivateEditorClient {
    func submit(_ request: PrivateConfigurationRequest, deadline: RuntimeDeadline) async throws -> ControlAdmission {
        try await submit(requestID: request.requestID, deadline: deadline) { request }
    }
}

/// The explicit reload as a framed command (decision 0032) over the actual host, service, in-memory transport, framed client and private
/// editor client, on a `FakeMachine` and a scratch root. Waits end on the operation's own `operationFinished` frame, a held store read or a
/// held machine call, within a failure deadline.
@MainActor
final class RuntimeHostReloadCommandTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)

    @MainActor
    private struct Composed {
        let host: RuntimeHost
        let harness: InteractiveHostHarness
        let composition: RuntimeControlComposition
        let client: any RuntimeClient

        var environment: RuntimeEnvironment { harness.environment }
        var editor: PrivateEditorClient { PrivateEditorClient(transport: composition.transport) }
    }

    private func compose(stateFiles: (any StateFileAccessing)? = nil) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        if let stateFiles { harness.stateFiles = stateFiles }
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return Composed(host: host, harness: harness, composition: composition, client: client)
    }

    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    private func finished(_ operation: ControlOperationID, on stream: RuntimeSubscription) async throws -> ControlOperationOutcome {
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                return finished.outcome
            }
        }
        XCTFail("the operation's settlement never reached the stream")
        throw RuntimeClientError.unexpectedReply
    }

    private func submit(
        _ composed: Composed, _ command: ControlRuntimeCommand, requestID: ControlRequestID = ControlRequestID(rawValue: UUID())
    ) async throws -> ControlAdmission {
        try await composed.client.submit(command, requestID: requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline())
    }

    private func accepted(_ admission: ControlAdmission, file: StaticString = #filePath, line: UInt = #line) throws -> ControlOperationID {
        guard case .accepted(let operation) = admission else {
            XCTFail("expected an accepted admission, got \(admission)", file: file, line: line)
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    /// The reload result a completion carries, or nil for any other outcome.
    private func reloaded(_ outcome: ControlOperationOutcome?) -> ControlReloadResult? {
        guard case .completed(let completion)? = outcome, completion.command == .reload, case .reload(let result) = completion.result else {
            return nil
        }
        return result
    }

    private func reload(_ composed: Composed, on stream: RuntimeSubscription) async throws -> ControlReloadResult? {
        reloaded(try await finished(try accepted(try await submit(composed, .reload)), on: stream))
    }

    private func observation(_ composed: Composed) async throws -> PrivateEditorObservation {
        let answer = try await composed.editor.read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation,
            budget: try ControlWireBudget(1_000), deadline: deadline()
        )
        guard case .observation(let observed) = answer else {
            XCTFail("a read answers an observation: \(answer)")
            throw RuntimeClientError.unexpectedReply
        }
        return observed
    }

    /// A save-only draft of `observed` with `profileName`, at the exact baselines that observation named.
    private func save(
        _ composed: Composed, from observed: PrivateEditorObservation, profileName: String, on stream: RuntimeSubscription
    ) async throws -> ControlConfigurationReceipt {
        var values = try PrivateConfigurationBridge.makeValues(from: observed)
        values.config.profileName = profileName
        let request = try PrivateConfigurationBridge.makeRequest(
            config: values.config, platform: values.platform, requestID: ControlRequestID(rawValue: UUID()),
            incarnation: composed.host.incarnation, budget: try ControlWireBudget(1_000),
            runtimeBaseline: try XCTUnwrap(observed.components.runtime.baseline),
            platformBaseline: try XCTUnwrap(observed.components.platform.baseline),
            modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        )
        let outcome = try await finished(try accepted(try await composed.editor.submit(request, deadline: deadline())), on: stream)
        guard case .configurationSettled(let receipt) = outcome else {
            XCTFail("a save settles with its receipt: \(outcome)")
            throw RuntimeClientError.unexpectedReply
        }
        return receipt
    }

    private func editRuntime(_ composed: Composed, _ edit: (inout ProxyConfig) -> Void) throws -> Data {
        var config = try ProxyConfigPersistence.load(in: composed.environment, allowMissing: false)
        edit(&config)
        try ProxyConfigPersistence.save(config, in: composed.environment)
        return try Data(contentsOf: composed.environment.configFile)
    }

    /// A failure bound on real effects: polls an observed boundary, never decides by time.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - External edits and drafts

    /// Decision 0027 then 0032 through the actual clients. A draft observed at A is refused over an external B, and B is kept. The explicit
    /// reload adopts B, writes nothing and answers a reconcile attempted under its current admission. The dirty draft's original tokens are
    /// not refreshed by the reload, so its next save is still refused; only a fresh read takes B and the baselines that may save over it.
    func testAReloadAdoptsAnExternalEditAndOnlyAFreshReadMaySaveOverIt() async throws {
        let composed = try await compose()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observedA = try await observation(composed)
        let bytesB = try editRuntime(composed) { $0.profileName = "External B" }

        let stale = try await save(composed, from: observedA, profileName: "Draft over A", on: stream)
        XCTAssertEqual(stale.runtime.write, .conflict)
        XCTAssertEqual(try Data(contentsOf: composed.environment.configFile), bytesB, "the external edit is kept")

        let adoptedB = try await reload(composed, on: stream)
        XCTAssertEqual(adoptedB, .adopted(.reconcileAttempted(currentAtEnd: true)))
        XCTAssertEqual(try Data(contentsOf: composed.environment.configFile), bytesB, "the reload wrote nothing")
        XCTAssertEqual(composed.host.config.profileName, "External B")

        let dirty = try await save(composed, from: observedA, profileName: "Draft over A again", on: stream)
        XCTAssertFalse(dirty.runtime.write.isVerified, "the draft's original tokens were not refreshed")
        XCTAssertEqual(try Data(contentsOf: composed.environment.configFile), bytesB)

        let observedB = try await observation(composed)
        XCTAssertEqual(try PrivateConfigurationBridge.makeValues(from: observedB).config.profileName, "External B")
        XCTAssertNotEqual(observedB.components.runtime.baseline, observedA.components.runtime.baseline)
        let fresh = try await save(composed, from: observedB, profileName: "Saved over B", on: stream)
        XCTAssertEqual(fresh.runtime.write, .persisted(reportedError: false))
        XCTAssertEqual(try ProxyConfigPersistence.load(in: composed.environment, allowMissing: false).profileName, "Saved over B")
    }

    // MARK: - Typed answers

    /// Each answer through the client, with no write of its own. A malformed file is refused whole and left as it is. A permitted absent
    /// platform file is adopted and held uncommitted, and no default is written. A start-blocking edit is adopted for editing and held, and
    /// the applied view stays. A reload that finds the store's one slot taken by another is refused busy. After the quit none is admitted.
    func testEachReloadAnswerThroughTheClientWritesNothing() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(stateFiles: files)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let environment = composed.environment
        let valid = try Data(contentsOf: environment.configFile)

        let malformed = Data("{".utf8)
        try malformed.write(to: environment.configFile)
        let refusedMalformed = try await reload(composed, on: stream)
        XCTAssertEqual(refusedMalformed, .refused(.invalidContent))
        XCTAssertEqual(try Data(contentsOf: environment.configFile), malformed)
        try valid.write(to: environment.configFile)

        try FileManager.default.removeItem(at: environment.platformConfigFile)
        let heldAbsent = try await reload(composed, on: stream)
        XCTAssertEqual(heldAbsent, .adopted(.held(.unit, .uncommitted)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.platformConfigFile.path), "a reload writes no default")
        XCTAssertEqual(try Data(contentsOf: environment.configFile), valid)
        try PlatformConfigPersistence.save(proxyAndDNS, in: environment)

        let applied = composed.host.config.maxConnections
        let blocking = try editRuntime(composed) { $0.maxConnections = 0 }
        let heldBlocking = try await reload(composed, on: stream)
        XCTAssertEqual(heldBlocking, .adopted(.held(.runtime, .startBlocking)))
        XCTAssertEqual(try Data(contentsOf: environment.configFile), blocking)
        XCTAssertEqual(composed.host.config.maxConnections, applied, "the held edit does not replace the applied view")
        try valid.write(to: environment.configFile)

        files.hold.arm { name, values in name == "read" && values == [composed.harness.session.plan.platformConfig.path] }
        defer { files.hold.release() }
        let parked = Task { await composed.host.reloadConfiguration() }
        await files.hold.waitUntilReached()
        let refusedBusy = try await reload(composed, on: stream)
        XCTAssertEqual(refusedBusy, .refused(.busy))
        files.hold.release()
        let facade = await parked.value
        XCTAssertEqual(facade, .adopted(.reconcileAttempted(currentAtEnd: true)))

        await composed.host.shutdown()
        let afterQuit = try await submit(composed, .reload)
        XCTAssertEqual(afterQuit, .rejected(.hostStopping))
    }

    /// The facade and the command run the one primitive: over the same inputs, each command answer is the facade's decision through the
    /// one mapping.
    func testTheFacadeAndTheCommandAnswerAlike() async throws {
        let composed = try await compose()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let environment = composed.environment
        let valid = try Data(contentsOf: environment.configFile)

        for (label, bytes) in [("valid", valid), ("malformed", Data("{".utf8))] {
            try bytes.write(to: environment.configFile)
            let facade = await composed.host.reloadConfiguration()
            let command = try await reload(composed, on: stream)
            XCTAssertEqual(command, RuntimeHost.reloadResult(facade), label)
        }
        try valid.write(to: environment.configFile)
    }

    // MARK: - Capture and fences

    /// The fence captures the generation in the admission turn and counts the reload pending from there, before its effect launches.
    /// A Stop admitted between the fence and the launch makes the observation stale: the store adopts it, nothing applies, and the answer
    /// says so. Manual hops hold the launch.
    func testTheFenceCapturesItsGenerationBeforeTheEffectLaunches() async throws {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let applied = host.config.profileName
        var edited = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
        edited.profileName = "Edited before the launch"
        try ProxyConfigPersistence.save(edited, in: harness.environment)

        let generation = host.workflow.generation
        let operation = try accepted(composition.service.submit(ControlOperationRequest(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation, command: .reload
        )))
        guard case .reload(let captured, _)? = host.controlAdmissions[operation] else { return XCTFail("the fence admitted a reload") }
        XCTAssertEqual(captured, generation)
        XCTAssertEqual(host.pendingAdmissions, 1, "pending from its admission")

        await host.stopRuntime()
        XCTAssertGreaterThan(host.workflow.generation, captured)
        scheduling.drainAll()
        let quiet = try await eventually { host.pendingAdmissions == 0 }
        XCTAssertTrue(quiet)
        scheduling.drainAll()
        guard case .finished(let outcome) = composition.service.operationLookup(
            ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation)
        ) else {
            return XCTFail("the reload settled")
        }
        XCTAssertEqual(reloaded(outcome), .adopted(.superseded))
        XCTAssertEqual(host.config.profileName, applied, "the stale observation applied nothing")
        XCTAssertEqual(host.workflow.editorCapture().values.runtime.profileName, edited.profileName, "but the store adopted it")
    }

    /// A Stop, and then a saved Start, each admitted while the reload's read is parked supersede it: the store adopts the observation,
    /// and the host view stays. The Start finds the store's slot taken and fails without a capture.
    func testAStopOrStartAdmittedDuringTheReadSupersedesTheReload() async throws {
        let files = HeldStateFileRead()
        let composed = try await compose(stateFiles: files)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let platformPath = composed.harness.session.plan.platformConfig.path
        let applied = composed.host.config.profileName
        defer { files.hold.release() }

        _ = try editRuntime(composed) { $0.profileName = "Edited during the Stop" }
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        let duringStop = try accepted(try await submit(composed, .reload))
        await files.hold.waitUntilReached()
        let stop = try await finished(try accepted(try await submit(composed, .stop(.proxy))), on: stream)
        guard case .completed(let stopped) = stop else { return XCTFail("the Stop settles while the read is parked: \(stop)") }
        XCTAssertEqual(stopped.command, .stop)
        files.hold.release()
        let stopSuperseded = try await finished(duringStop, on: stream)
        XCTAssertEqual(reloaded(stopSuperseded), .adopted(.superseded))
        XCTAssertEqual(composed.host.config.profileName, applied)

        _ = try editRuntime(composed) { $0.profileName = "Edited during the Start" }
        files.hold.arm { name, values in name == "read" && values == [platformPath] }
        let duringStart = try accepted(try await submit(composed, .reload))
        await files.hold.waitUntilReached()
        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        let modules = try XCTUnwrap(snapshot.stamp.modules)
        let start = try await finished(
            try accepted(try await submit(composed, .start(.proxy, ifModuleRevision: modules.proxy))), on: stream
        )
        XCTAssertEqual(start, .failed(.storeBusy))
        files.hold.release()
        let startSuperseded = try await finished(duringStart, on: stream)
        XCTAssertEqual(reloaded(startSuperseded), .adopted(.superseded))
        XCTAssertEqual(composed.host.config.profileName, applied)
        let stored = try await observation(composed)
        XCTAssertEqual(try PrivateConfigurationBridge.makeValues(from: stored).config.profileName,
                       "Edited during the Start", "the store adopted each stale observation")
    }

    /// A Stop admitted while the reload's reconcile pass is held on its first machine call ends the attempt not current: the answer never
    /// claims the pass ran under a standing admission.
    func testAStopDuringTheHeldPassEndsTheAttemptNotCurrent() async throws {
        let (reload, stop, composed) = try await duringHeldPass { _ in .stop(.proxy) }
        XCTAssertEqual(reloaded(reload), .adopted(.reconcileAttempted(currentAtEnd: false)))
        guard case .completed(let stopped) = stop else { return XCTFail("the Stop completes: \(stop)") }
        XCTAssertEqual(stopped.command, .stop)
        XCTAssertFalse(composed.harness.machine.service("Wi-Fi").routesThroughAProxy)
    }

    /// A saved Start admitted while the pass is held ends it not current too. The Start runs after the pass, from its own capture.
    func testASavedStartDuringTheHeldPassEndsTheAttemptNotCurrent() async throws {
        let (reload, start, _) = try await duringHeldPass { composed in
            let snapshot = try await composed.client.readSnapshot(deadline: self.deadline())
            let modules = try XCTUnwrap(snapshot.stamp.modules)
            return .start(.dns, ifModuleRevision: modules.dns)
        }
        XCTAssertEqual(reloaded(reload), .adopted(.reconcileAttempted(currentAtEnd: false)))
        guard case .configurationSettled(let receipt) = start else { return XCTFail("the Start settles with its receipt: \(start)") }
        XCTAssertEqual(receipt.modules, [ControlModuleReceipt(module: .dns, result: .started)])
    }

    /// An eligible reload C that adopts a newer accepted view while B's pass is held stops B before its next step (decision 0032): B
    /// answers not current, and B's flag action, the environment cleared, never runs. C runs from the baseline the machine holds and
    /// answers current; no intent moved.
    func testANewerEligibleReloadDuringTheHeldPassStopsItsUnstartedFlagAction() async throws {
        let (reload, newer, composed) = try await duringHeldPass(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: false, manageSystemDNS: true),
            { composed in
                try PlatformConfigPersistence.save(self.proxyAndDNS, in: composed.environment)
                return .reload
            },
            heldUntil: { $0.host.platformConfig.manageEnvironmentVariables }
        )
        XCTAssertEqual(reloaded(reload), .adopted(.reconcileAttempted(currentAtEnd: false)), "a newer accepted view replaced B")
        XCTAssertEqual(reloaded(newer), .adopted(.reconcileAttempted(currentAtEnd: true)))
        XCTAssertEqual(environmentClears(composed.host), 0, "B's unstarted clear never ran after C was adopted")
        XCTAssertTrue(composed.host.platformConfig.manageEnvironmentVariables)
        XCTAssertTrue(composed.host.completedPlatformBaseline.manageEnvironmentVariables, "the machine's baseline ends at C")
    }

    /// An ineligible observation during B's pass replaces no accepted view: a start-blocking C is adopted by the store for editing and
    /// held, so B stays current and its flag action runs.
    func testAHeldReloadDuringTheHeldPassLeavesItCurrent() async throws {
        let (reload, held, composed) = try await duringHeldPass(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: false, manageSystemDNS: true),
            { composed in
                _ = try self.editRuntime(composed) { $0.maxConnections = 0 }
                return .reload
            },
            heldUntil: { $0.host.workflow.editorCapture().values.runtime.maxConnections == 0 }
        )
        XCTAssertEqual(reloaded(held), .adopted(.held(.runtime, .startBlocking)))
        XCTAssertEqual(reloaded(reload), .adopted(.reconcileAttempted(currentAtEnd: true)), "a held draft does not stop prior eligible work")
        XCTAssertEqual(environmentClears(composed.host), 1, "B's flag action ran")
        XCTAssertFalse(composed.host.completedPlatformBaseline.manageEnvironmentVariables)
    }

    /// The reconciler's recorded decisions to clear the environment, each made before its action.
    private func environmentClears(_ host: RuntimeHost) -> Int {
        host.orchestrator.eventLog.events.filter { $0.event == "config.platform_integration" && $0.detail == "clearEnvironment" }.count
    }

    /// A running host whose reload B adopts a bypass edit, with `platform` saved beside it when given, its pass held on its first
    /// platform-queue machine call while `intervening` is admitted. The hold is released once `heldUntil` holds; both settlements follow.
    private func duringHeldPass(
        platform: PlatformIntegrationConfig? = nil,
        _ intervening: (Composed) async throws -> ControlRuntimeCommand,
        heldUntil: @escaping @MainActor (Composed) -> Bool = { _ in true }
    ) async throws -> (reload: ControlOperationOutcome, intervening: ControlOperationOutcome, composed: Composed) {
        let composed = try await compose()
        try await composed.host.startRuntime()
        await composed.host.deliveries.drain()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        var hosts: [String] = []
        _ = try editRuntime(composed) {
            $0.routing.noProxyHosts.append("reload-pass.example.test")
            hosts = $0.routing.noProxyHosts
        }
        if let platform { try PlatformConfigPersistence.save(platform, in: composed.environment) }

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { _, _ in true }
        defer { composed.harness.hold.release() }
        let reload = try accepted(try await submit(composed, .reload))
        await composed.harness.hold.waitUntilReached()
        let adopted = try await eventually {
            composed.host.config.routing.noProxyHosts == hosts && (platform.map { composed.host.platformConfig == $0 } ?? true)
        }
        XCTAssertTrue(adopted, "the host view took the edit and submitted its pass")
        let other = try accepted(try await submit(composed, try await intervening(composed)))
        let ready = try await eventually { heldUntil(composed) }
        XCTAssertTrue(ready, "the intervening operation reached its point before B's pass resumes")
        composed.harness.hold.release()

        var outcomes: [ControlOperationID: ControlOperationOutcome] = [:]
        for _ in 0..<128 where outcomes[reload] == nil || outcomes[other] == nil {
            if case .operationFinished(let finished) = try await stream.next(deadline()) { outcomes[finished.operationID] = finished.outcome }
        }
        return (try XCTUnwrap(outcomes[reload]), try XCTUnwrap(outcomes[other]), composed)
    }

    // MARK: - Recovery

    /// A client that lost the admission reply looks the request up and reads the outcome; it never sends the reload again, so the store
    /// observed once.
    func testALostAnswerIsRecoveredByLookupWithoutASecondReload() async throws {
        let composed = try await compose()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        func reloadsObserved() -> Int {
            composed.harness.typedEvents().filter {
                guard case .configWorkflow(.observed(let observed)) = $0 else { return false }
                return observed.phase == .reload
            }.count
        }
        let before = reloadsObserved()
        let requestID = ControlRequestID(rawValue: UUID())
        _ = try await submit(composed, .reload, requestID: requestID)

        let lookup = try await composed.client.lookupAdmission(
            of: requestID, expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        guard case .admission(.accepted(let operation)) = lookup else { return XCTFail("the alias recovers the admission: \(lookup)") }
        let settled = try await finished(operation, on: stream)
        XCTAssertEqual(reloaded(settled), .adopted(.reconcileAttempted(currentAtEnd: true)))
        let read = try await composed.client.outcome(of: operation, expectedIncarnation: composed.host.incarnation, deadline: deadline())
        XCTAssertEqual(read, .finished(settled))
        XCTAssertEqual(reloadsObserved(), before + 1, "one observation for one request")
    }
}
