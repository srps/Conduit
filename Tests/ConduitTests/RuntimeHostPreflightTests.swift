// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// One actual host, its control service and the framed client, over the interactive harness's fakes and scratch root. Every bound is the
/// explicit fixture profile.
@MainActor
private struct PreflightComposed {
    let host: RuntimeHost
    let harness: InteractiveHostHarness
    let composition: RuntimeControlComposition
    let client: any RuntimeClient

    static func make(
        helper: FakeHelperLifecycle?,
        credentials: any SecretStore = InMemorySecretStore(),
        ordinaryPending: Int = 2
    ) async throws -> PreflightComposed {
        let harness = try makeInteractiveHarness(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true),
            dnsForwarderEnabled: false
        )
        harness.helperStatus = helper
        harness.credentials = credentials
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            // An actual host's composition streams its own events, so the event ring and ingress carry a Start's burst.
            host: host, limits: try RuntimeServiceFixtures.hostLimits(ordinaryPending: ordinaryPending), timing: .system,
            scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return PreflightComposed(host: host, harness: harness, composition: composition, client: client)
    }

    /// A failure bound only: every wait ends on its own frame or reply long before it.
    static func deadline() -> RuntimeDeadline { .after(.seconds(30), from: ContinuousClock.now) }

    func submit(_ command: ControlRuntimeCommand) async throws -> ControlAdmission {
        try await client.submit(command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation,
                                deadline: Self.deadline())
    }

    func accepted(_ command: ControlRuntimeCommand, file: StaticString = #filePath, line: UInt = #line) async throws -> ControlOperationID {
        let admission = try await submit(command)
        guard case .accepted(let operation) = admission else {
            XCTFail("expected an accepted admission, got \(admission)", file: file, line: line)
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    /// The stream's settlements of every named operation. Bounded: a stream that never settles one fails the test.
    func finished(_ operations: Set<ControlOperationID>, on stream: RuntimeSubscription) async throws -> [ControlOperationID: ControlOperationOutcome] {
        var outcomes: [ControlOperationID: ControlOperationOutcome] = [:]
        for _ in 0..<256 where !operations.isSubset(of: Set(outcomes.keys)) {
            if case .operationFinished(let finished) = try await stream.next(Self.deadline()), operations.contains(finished.operationID) {
                outcomes[finished.operationID] = finished.outcome
            }
        }
        XCTAssertTrue(operations.isSubset(of: Set(outcomes.keys)), "every operation's settlement reached the stream")
        return outcomes
    }

    func finished(_ operation: ControlOperationID, on stream: RuntimeSubscription) async throws -> ControlOperationOutcome {
        guard let outcome = try await finished([operation], on: stream)[operation] else { throw RuntimeClientError.unexpectedReply }
        return outcome
    }
}

/// The observed items of a completed preflight. Fails the test for any other outcome.
private func items(_ outcome: ControlOperationOutcome?, file: StaticString = #filePath, line: UInt = #line) throws -> ControlPreflightItems {
    guard case .completed(let completion)? = outcome, case .preflight(let observation) = completion.result,
          case .observed(let items) = observation.reading else {
        XCTFail("a preflight completes with an observed reading: \(String(describing: outcome))", file: file, line: line)
        throw RuntimeClientError.unexpectedReply
    }
    return items
}

/// The host's preflight through the actual framed client (twin of `AppState.refreshPreflight`): its held helper verdict, its two passes,
/// its revocation by a helper replacement or the quit, and its repairs. Reads are counted on the fake, never timed.
@MainActor
final class RuntimeHostPreflightTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        harness?.hold.release()
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func compose(helper: FakeHelperLifecycle?, ordinaryPending: Int = 2) async throws -> PreflightComposed {
        let composed = try await PreflightComposed.make(helper: helper, ordinaryPending: ordinaryPending)
        harness = composed.harness
        return composed
    }

    private func subscribe(_ composed: PreflightComposed) async throws -> RuntimeSubscription {
        let stream = try await composed.client.subscribe(.live, deadline: PreflightComposed.deadline())
        _ = try await stream.next(PreflightComposed.deadline())
        return stream
    }

    /// The repair a newly conclusive install delivers is observed on the environment drift pass it schedules: a wiped variable comes back.
    private func wipeEnvironment(_ composed: PreflightComposed) throws {
        _ = try composed.harness.machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])
    }

    private func repaired(_ composed: PreflightComposed) -> Bool {
        composed.harness.machine.launchdEnvironment["HTTP_PROXY"] != nil
    }

    /// The held verdict, as the app holds it. A conclusive install repairs the running proxy's surfaces. A `busy` read keeps `installed` on
    /// display, says it was busy and repairs nothing. After a replacement the old verdict is not kept, so a `busy` read stands on its own;
    /// the next conclusive install is a new one and repairs again.
    func testABusyReadKeepsTheHeldVerdictAndOnlyAConclusiveInstallRepairs() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        let composed = try await compose(helper: helper)
        try await composed.host.startRuntime()
        let stream = try await subscribe(composed)
        defer { stream.cancel() }
        func refresh(helperReplaced: Bool = false) async throws -> ControlPreflightItems {
            let operation = try await composed.accepted(.refreshPreflight(helperReplaced: helperReplaced))
            let reading = try items(try await composed.finished(operation, on: stream))
            await composed.host.deliveries.drain()
            return reading
        }

        try wipeEnvironment(composed)
        let first = try await refresh()
        XCTAssertEqual(first.helper, .installed)
        XCTAssertFalse(first.helperReadBusy)
        XCTAssertTrue(repaired(composed), "a newly conclusive install repairs the running proxy's surfaces")

        helper.status = .busy
        try wipeEnvironment(composed)
        let busy = try await refresh()
        XCTAssertEqual(busy.helper, .installed, "a busy read keeps the held verdict on display")
        XCTAssertTrue(busy.helperReadBusy, "and says so, for the client's one re-read")
        XCTAssertFalse(repaired(composed), "a busy read grants nothing")

        let replaced = try await refresh(helperReplaced: true)
        XCTAssertEqual(replaced.helper, .busy, "after a replacement the old verdict is not kept")
        XCTAssertTrue(replaced.helperReadBusy)
        XCTAssertFalse(repaired(composed))

        helper.status = .installed
        let conclusive = try await refresh()
        XCTAssertEqual(conclusive.helper, .installed)
        XCTAssertFalse(conclusive.helperReadBusy)
        XCTAssertTrue(repaired(composed), "the replaced helper's first conclusive install repairs")
    }

    /// A replacement admitted while a pass is reading drops that pass: its request fails `staleRevision`, and it updates no verdict, so the
    /// pass after it still sees a newly conclusive install and repairs. The requests admitted while it read, the replacing one included,
    /// share that next pass and its one fresh reading. Two passes read the helper.
    func testAReplacementDropsTheReadingAPassBeganBeforeIt() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        // Three requests stay unquiesced at once while the first pass reads, so the fixture admits three ordinary operations.
        let composed = try await compose(helper: helper, ordinaryPending: 3)
        try await composed.host.startRuntime()
        let stream = try await subscribe(composed)
        defer { stream.cancel() }
        let reads = helper.statusReads
        try wipeEnvironment(composed)

        composed.harness.hold.arm { name, _ in name == "helper-status" }
        let early = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        await composed.harness.hold.waitUntilReached()
        XCTAssertFalse(composed.harness.hold.reachedOnMainThread, "the helper is read off the main actor")
        let joined = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        let replacing = try await composed.accepted(.refreshPreflight(helperReplaced: true))
        // Both join the pending pass at launch; every launch has run once the host holds no admission.
        for _ in 0..<2_000 where !composed.host.controlAdmissions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(composed.host.controlAdmissions.isEmpty)
        composed.harness.hold.release()

        let outcomes = try await composed.finished([early, joined, replacing], on: stream)
        XCTAssertEqual(outcomes[early], .failed(.staleRevision), "the reading taken before the replacement is dropped")
        let fresh = try items(outcomes[joined])
        XCTAssertEqual(try items(outcomes[replacing]), fresh, "both share the one pass that began after the replacement")
        XCTAssertEqual(fresh.helper, .installed)
        XCTAssertEqual(helper.statusReads - reads, 2)
        await composed.host.deliveries.drain()
        XCTAssertTrue(repaired(composed), "the dropped pass held no verdict, so the fresh install is new and repairs")
    }

    /// At most two passes exist: the one reading, and the one every later request joins. The service's ordinary capacity bounds the
    /// requests, so the one past it is refused there and the host keeps no queue of its own.
    func testPreflightRequestsShareAtMostTwoPassesAndTheServiceBoundsTheRest() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        let composed = try await compose(helper: helper, ordinaryPending: 4)
        let stream = try await subscribe(composed)
        defer { stream.cancel() }
        let reads = helper.statusReads

        composed.harness.hold.arm { name, _ in name == "helper-status" }
        let first = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        await composed.harness.hold.waitUntilReached()
        var joined: [ControlOperationID] = []
        for _ in 0..<3 { joined.append(try await composed.accepted(.refreshPreflight(helperReplaced: false))) }
        let refused = try await composed.submit(.refreshPreflight(helperReplaced: false))
        XCTAssertEqual(refused, .rejected(.queueFull))
        XCTAssertEqual(composed.host.pendingAdmissions, 4, "each admitted request is pending work from its fence")
        // The later three join the pending pass as each launches; every launch has run once the host holds no admission.
        for _ in 0..<2_000 where !composed.host.controlAdmissions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(composed.host.controlAdmissions.isEmpty, "every request launched while the first pass was reading")
        XCTAssertNotNil(composed.host.preflight.running)
        XCTAssertNotNil(composed.host.preflight.pending)
        composed.harness.hold.release()

        let outcomes = try await composed.finished(Set([first] + joined), on: stream)
        _ = try items(outcomes[first])
        for operation in joined { _ = try items(outcomes[operation]) }
        XCTAssertTrue(joined.allSatisfy { outcomes[$0] == outcomes[joined[0]] }, "the later three joined one pass")
        XCTAssertEqual(helper.statusReads - reads, 2, "two passes read the helper")
        XCTAssertNil(composed.host.preflight.running)
        XCTAssertNil(composed.host.preflight.pending)
    }

    /// The fence starts no effect. An accepted request whose launch has not run has made no pass and read nothing, yet it is pending work,
    /// and a replacement it names is already recorded: the generation moved at the fence. Manual hops hold the launches. Once they run,
    /// both requests join one pass, which reads once.
    func testAnAdmittedRequestStartsNoPassUntilItsEffectLaunches() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        harness.helperStatus = helper
        self.harness = harness
        let host = try await harness.makeHost()
        let scheduling = ManualOwnerScheduling()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.limits(), timing: ManualRuntimeTiming().timing, scheduling: scheduling
        )
        let reads = helper.statusReads
        let generation = host.preflight.generation
        func admit(helperReplaced: Bool) throws -> ControlOperationID {
            let admission = composition.service.submit(ControlOperationRequest(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation,
                command: .refreshPreflight(helperReplaced: helperReplaced)
            ))
            guard case .accepted(let operation) = admission else {
                XCTFail("expected an accepted admission, got \(admission)")
                throw RuntimeClientError.unexpectedReply
            }
            return operation
        }

        let first = try admit(helperReplaced: false)
        let second = try admit(helperReplaced: true)
        XCTAssertEqual(host.pendingAdmissions, 2, "each accepted request is pending work before it launches")
        XCTAssertEqual(host.preflight.generation, generation + 1, "the replacement is recorded at the fence")
        XCTAssertNil(host.preflight.running)
        XCTAssertNil(host.preflight.pending, "the fence made no pass")
        XCTAssertEqual(helper.statusReads, reads, "and nothing was read")

        scheduling.drainAll()
        for _ in 0..<2_000 where host.pendingAdmissions > 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(host.pendingAdmissions, 0)
        scheduling.drainAll()
        func lookup(_ operation: ControlOperationID) -> ControlOperationLookup {
            composition.service.operationLookup(ControlOperationQuery(expectedIncarnation: host.incarnation, operationID: operation))
        }
        guard case .finished(let outcome) = lookup(first) else { return XCTFail("the first request settled: \(lookup(first))") }
        _ = try items(outcome)
        XCTAssertEqual(lookup(second), lookup(first), "both launched requests joined one pass")
        XCTAssertEqual(helper.statusReads - reads, 1)
    }

    /// The quit does not wait for a pass that is reading, and a request after its latch is refused as stopping. The pass reading at the
    /// latch and the one pending behind it both fail `staleRevision`, and the pending one never reads the helper.
    func testTheQuitWaitsForNoReadingPassAndTheOnePendingAtItsLatchReadsNothing() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        // The two passes' requests stay unquiesced while the read is held; a third slot lets the late request reach the host's fence,
        // which the service's capacity check would otherwise answer first with `queueFull`.
        let composed = try await compose(helper: helper, ordinaryPending: 3)
        let reads = helper.statusReads

        composed.harness.hold.arm { name, _ in name == "helper-status" }
        let reading = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        await composed.harness.hold.waitUntilReached()
        let pending = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        await composed.host.shutdown()
        XCTAssertTrue(composed.host.workflow.isTerminal, "the quit completed while the pass was still reading")
        let late = try await composed.submit(.refreshPreflight(helperReplaced: false))
        XCTAssertEqual(late, .rejected(.hostStopping))
        composed.harness.hold.release()

        var ended = false
        for _ in 0..<2_000 where !ended {
            ended = composed.host.preflight.running == nil && composed.host.preflight.pending == nil && composed.host.pendingAdmissions == 0
            if !ended { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertTrue(ended, "both passes ended")
        func lookup(_ operation: ControlOperationID) -> ControlOperationLookup {
            composed.composition.service.operationLookup(ControlOperationQuery(expectedIncarnation: composed.host.incarnation, operationID: operation))
        }
        var settled = false
        for _ in 0..<2_000 where !settled {
            settled = lookup(reading) != .pending && lookup(pending) != .pending
            if !settled { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(lookup(reading), .finished(.failed(.staleRevision)))
        XCTAssertEqual(lookup(pending), .finished(.failed(.staleRevision)))
        XCTAssertEqual(helper.statusReads - reads, 1, "the pass pending at the latch read nothing")
    }

    /// A pass reads and evaluates off `platformWork`, so it completes while a Stop's teardown holds that queue.
    func testAPassCompletesWhileAStopsPlatformWorkIsHeld() async throws {
        let helper = FakeHelperLifecycle(status: .installed)
        let composed = try await compose(helper: helper)
        try await composed.host.startRuntime()
        let stream = try await subscribe(composed)
        defer { stream.cancel() }

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let stop = try await composed.accepted(.stop(.proxy))
        await composed.harness.hold.waitUntilReached()
        let pass = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        let completed = try await composed.finished(pass, on: stream)
        XCTAssertEqual(try items(completed).helper, .installed)
        XCTAssertFalse(composed.host.lanes.proxy.isIdle, "the Stop's teardown was still held when the pass completed")
        composed.harness.hold.release()
        _ = try await composed.finished(stop, on: stream)
    }

    /// A host given no helper status source observes none: the reading is `notObserved`, never a guessed verdict.
    func testAHostWithNoHelperSourceReportsNotObserved() async throws {
        let composed = try await compose(helper: nil)
        let stream = try await subscribe(composed)
        defer { stream.cancel() }
        let operation = try await composed.accepted(.refreshPreflight(helperReplaced: false))
        guard case .completed(let completion) = try await composed.finished(operation, on: stream),
              case .preflight(let observation) = completion.result else {
            return XCTFail("a preflight completes")
        }
        XCTAssertEqual(observation.reading, .unavailable(.notObserved))
        XCTAssertEqual(observation.stamp.incarnation, composed.host.incarnation)
    }
}

/// A saved-password store that reads its value first and then offers the read to a `HeldCall` as `("secret-load", [])`, so a test can hold a
/// read that already has its answer: the answer from before a change.
private final class ReadThenHoldSecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    let hold = HeldCall()

    func save(secret: SecretBytes, account: String) throws { try inner.save(secret: secret, account: account) }
    func exists(account: String) throws -> Bool { try inner.exists(account: account) }
    func delete(account: String) throws { try inner.delete(account: account) }

    func load(account: String) throws -> SecretBytes? {
        let value = try inner.load(account: account)
        hold.pass("secret-load", [])
        return value
    }
}

/// The app writes the saved password into the store it shares with the host, then tells the host (`credentialsChanged`). The host drops
/// what it cached; a read already out discards its answer. Nothing names the secret on the wire.
@MainActor
final class RuntimeHostCredentialsChangeTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let upstream = UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)

    /// The app's enrollment writer over the shared store, keyed by the host's own identity.
    private func appWriter(_ host: RuntimeHost, store: any SecretStore) -> CredentialManager {
        let domain = host.config.domain, username = host.config.username, profileName = host.config.profileName
        return CredentialManager(identityProvider: { (domain: domain, username: username, profileName: profileName) }, store: store)
    }

    private func credentials(_ workstation: String) -> ProxyCredentials {
        ProxyCredentials(username: "user", domain: "CORP", workstation: workstation, ntHash: SecretBytes(Array(repeating: UInt8(7), count: 16)))
    }

    /// The host's read, on a thread of its own: a read waits on the store's answer.
    private func hostRead(_ host: RuntimeHost) async -> Result<ProxyCredentials?, any Error> {
        let manager = host.credentialManager, upstream = self.upstream
        return await Task.detached { Result { try manager.credentials(for: upstream) } }.value
    }

    private func notify(_ composed: PreflightComposed, on stream: RuntimeSubscription) async throws {
        let operation = try await composed.accepted(.credentialsChanged)
        guard case .completed(let completion) = try await composed.finished(operation, on: stream) else {
            return XCTFail("the invalidation completes")
        }
        XCTAssertEqual(completion.command, .credentialsChanged)
        XCTAssertEqual(completion.result, .settled)
    }

    /// The host caches what it read, so an app-side save is not seen until the app says so; then the new value is, and a clear is too.
    func testTheHostServesTheAppsSaveAndClearOnlyOnceTold() async throws {
        let store = InMemorySecretStore()
        let composed = try await PreflightComposed.make(helper: nil, credentials: store)
        harness = composed.harness
        let stream = try await composed.client.subscribe(.live, deadline: PreflightComposed.deadline())
        defer { stream.cancel() }
        _ = try await stream.next(PreflightComposed.deadline())
        let writer = appWriter(composed.host, store: store)

        func served() async throws -> String? { try await hostRead(composed.host).get()?.workstation }

        let before = try await served()
        XCTAssertNil(before)
        try writer.setCredentials(credentials("A"), for: upstream)
        let cached = try await served()
        XCTAssertNil(cached, "the host still holds what it read")
        try await notify(composed, on: stream)
        let saved = try await served()
        XCTAssertEqual(saved, "A")

        try writer.setCredentials(credentials("B"), for: upstream)
        try await notify(composed, on: stream)
        let replaced = try await served()
        XCTAssertEqual(replaced, "B")

        try writer.clear(for: composed.host.config)
        try await notify(composed, on: stream)
        let cleared = try await served()
        XCTAssertNil(cleared, "a clear is served once told")
    }

    /// A read that already has the old answer when the app saves and tells the host lands after the invalidation, so its answer is dropped:
    /// the host never serves it, and one more read, bounded to one, serves the new value.
    func testAReadOutBeforeTheChangeIsNeverServed() async throws {
        let store = ReadThenHoldSecretStore()
        let composed = try await PreflightComposed.make(helper: nil, credentials: store)
        harness = composed.harness
        let stream = try await composed.client.subscribe(.live, deadline: PreflightComposed.deadline())
        defer { stream.cancel() }
        _ = try await stream.next(PreflightComposed.deadline())
        let writer = appWriter(composed.host, store: store.inner)
        try writer.setCredentials(credentials("old"), for: upstream)

        store.hold.arm { name, _ in name == "secret-load" }
        let early = Task { await hostRead(composed.host) }
        await store.hold.waitUntilReached()
        try writer.setCredentials(credentials("new"), for: upstream)
        try await notify(composed, on: stream)
        store.hold.release()

        // The early caller may have given up waiting (`read_pending`) or been served the re-read; it is never the dropped answer.
        if case .success(let served) = await early.value {
            XCTAssertNotEqual(served?.workstation, "old")
        }
        let current = try await hostRead(composed.host).get()
        XCTAssertEqual(current?.workstation, "new")
        XCTAssertEqual(store.inner.loads, 2, "the dropped read and one current read")
    }
}
