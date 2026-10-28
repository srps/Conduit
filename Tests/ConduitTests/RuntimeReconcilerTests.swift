// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

/// Stands in for `AppState`: records every call in order, answers a fixed
/// runtime state, fails the actions it is told to, and can hold the config
/// apply open so a test can land a second save while the first pass is
/// suspended — the window every rule in `RuntimeReconciler` is about.
@RuntimeActor
final class RecordingHost: RuntimeReconcilerHost {
    enum Call: Equatable {
        case applyConfigChange(port: Int)
        case reapply(platform: PlatformIntegrationConfig)
        case decision(PlatformIntegrationReconciler.Action)
        case perform(PlatformIntegrationReconciler.Action, platform: PlatformIntegrationConfig)
    }

    var calls: [Call] = []
    var runtime = RuntimeReconciler.RuntimeState(proxyIsUp: true, dnsIsUp: false)
    var failing: [PlatformIntegrationReconciler.Action] = []
    /// Holds the next `applyConfigChange` open until `resume()`.
    var holdNextApply = false
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    /// Holds every lifecycle wait open until `releaseLifecycle()`, as a start or stop in flight does.
    var holdLifecycle = false
    private var lifecycle: [CheckedContinuation<Void, Never>] = []
    var isWaitingForLifecycle: Bool { !lifecycle.isEmpty }
    /// What the next push holds in place of the requested input, as an adjusting host (the app's DNS flag) does.
    var heldOverride: ProxyConfig?
    /// Makes every push report that it held nothing.
    var refuseApply = false
    /// Holds the next flag action open until `resumeAction()`, as a host whose platform work is out.
    var holdNextAction = false
    private var heldAction: CheckedContinuation<Void, Never>?
    var isHoldingAction: Bool { heldAction != nil }
    /// The surface re-applies, each with the diff it was given.
    private(set) var reapplied: [(old: ProxyConfig, new: ProxyConfig)] = []

    var performed: [PlatformIntegrationReconciler.Action] {
        calls.compactMap { if case .perform(let action, _) = $0 { action } else { nil } }
    }

    func awaitLifecycleIdle() async {
        guard holdLifecycle else { return }
        await withCheckedContinuation { lifecycle.append($0) }
    }

    func releaseLifecycle() {
        holdLifecycle = false
        for waiter in lifecycle { waiter.resume() }
        lifecycle = []
    }

    func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async -> RuntimeConfigApplication {
        calls.append(.applyConfigChange(port: new.localPort))
        if holdNextApply {
            holdNextApply = false
            await withCheckedContinuation { held = $0 }
        }
        if refuseApply { return .notHeld }
        return .held(heldOverride ?? new)
    }

    func resume() {
        held?.resume()
        held = nil
    }

    func runtimeState() -> RuntimeReconciler.RuntimeState { runtime }

    func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) async {
        calls.append(.reapply(platform: pass.platform))
        reapplied.append((old: pass.old, new: pass.new))
    }

    func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action) {
        calls.append(.decision(action))
    }

    func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) async -> Bool {
        calls.append(.perform(action, platform: platform))
        if holdNextAction {
            holdNextAction = false
            await withCheckedContinuation { heldAction = $0 }
        }
        return !failing.contains(action)
    }

    func resumeAction() {
        heldAction?.resume()
        heldAction = nil
    }

    func performImmediate(
        _ action: PlatformIntegrationReconciler.Action,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) -> Bool {
        calls.append(.perform(action, platform: platform))
        return !failing.contains(action)
    }
}

final class RuntimeReconcilerTests: XCTestCase {

    private var host: RecordingHost!
    private var reconciler: RuntimeReconciler!
    private let baseConfig = ProxyConfig.testFixture()
    private let proxyOn = PlatformIntegrationConfig(manageSystemProxy: true)
    private let proxyOff = PlatformIntegrationConfig(manageSystemProxy: false)

    // The async override runs on the owner, where the host and the
    // reconciler live; the synchronous one inherits XCTest's nonisolation.
    @RuntimeActor override func setUp() async throws {
        try await super.setUp()
        host = RecordingHost()
        reconciler = RuntimeReconciler(config: baseConfig, platformConfig: proxyOn, host: host)
    }

    @RuntimeActor private func edited(port: Int) -> ProxyConfig {
        var config = baseConfig
        config.localPort = port
        return config
    }

    @RuntimeActor private func settle(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @RuntimeActor () -> Bool
    ) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)", file: file, line: line)
    }

    /// #246: a save that only respells a URL (see `Respelled`) is runtime input the baseline does not hold. It queues a pass that pushes
    /// the new bytes, and the baseline moves to them.
    @RuntimeActor func testASaveThatOnlyRespellsTheInputPushesTheNewBytes() async {
        var old = baseConfig
        old.pacURL = "https://pac.example.test/\(Respelled.composed).pac"
        reconciler = RuntimeReconciler(config: old, platformConfig: proxyOn, host: host)
        var respelled = old
        respelled.pacURL = "https://pac.example.test/\(Respelled.decomposed).pac"
        XCTAssertTrue(reconciler.lags(config: respelled, platformConfig: proxyOn), "the baseline holds the old bytes")

        reconciler.reconcile(config: respelled, platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertTrue(host.calls.contains(.applyConfigChange(port: respelled.localPort)), "the respelled input is pushed: \(host.calls)")
        assertSameUTF8(reconciler.lastReconciledConfig.pacURL, respelled.pacURL, "the baseline holds the pushed bytes")
        XCTAssertFalse(reconciler.lags(config: respelled, platformConfig: proxyOn))
    }

    @RuntimeActor func testASaveThatChangesNothingQueuesNoPass() async {
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOn)

        XCTAssertFalse(reconciler.hasPassInFlight)
        await reconciler.drain()
        XCTAssertEqual(host.calls, [])
    }

    /// A lifecycle flip is already live in the runtime; marking it
    /// reconciled is what keeps its own save from restarting the subsystem.
    @RuntimeActor func testADNSFlipMarkedReconciledDoesNotQueueAPass() async {
        var flipped = baseConfig
        flipped.dnsForwarderEnabled.toggle()
        reconciler.markReconciled(dnsForwarderEnabled: flipped.dnsForwarderEnabled)

        reconciler.reconcile(config: flipped, platformConfig: proxyOn)

        XCTAssertFalse(reconciler.hasPassInFlight)
        XCTAssertEqual(host.calls, [])
    }

    /// Only the flag is absorbed: an edit made beside it still gets its pass.
    @RuntimeActor func testMarkingTheDNSFlipLeavesOtherEditsToReconcile() async {
        var edited = edited(port: 18081)
        edited.dnsForwarderEnabled.toggle()
        reconciler.markReconciled(dnsForwarderEnabled: edited.dnsForwarderEnabled)

        reconciler.reconcile(config: edited, platformConfig: proxyOn)

        XCTAssertTrue(reconciler.hasPassInFlight)
        await reconciler.drain()
    }

    /// A failed action records nothing, so the baseline stays behind the
    /// request and a retry reaches the save's own target, not a later edit.
    @RuntimeActor func testARetryRunsTheLastRequestAgain() async {
        host.failing = [.clearSystemProxy]
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff)
        await reconciler.drain()
        XCTAssertTrue(reconciler.requestLags)
        XCTAssertEqual(reconciler.requestedPlatformConfig, proxyOff)

        host.failing = []
        reconciler.retryRequest()
        await reconciler.drain()

        XCTAssertEqual(host.performed, [.clearSystemProxy, .clearSystemProxy])
        XCTAssertFalse(reconciler.requestLags)
    }

    /// Nothing failed: there is nothing to retry, whatever was edited since.
    @RuntimeActor func testARequestThatLandedDoesNotLag() async {
        reconciler.reconcile(config: edited(port: 18082), platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertFalse(reconciler.requestLags)
        XCTAssertTrue(reconciler.lags(config: edited(port: 18083), platformConfig: proxyOn))
    }

    /// The login item needs no runtime state and must not wait for the
    /// pass: a quit right after the save would lose it.
    @RuntimeActor func testLaunchAtLoginRunsBeforeThePassIsQueued() async {
        var platform = proxyOn
        platform.launchAtLogin = true

        reconciler.reconcile(config: baseConfig, platformConfig: platform)

        XCTAssertEqual(
            host.calls,
            [.decision(.setLaunchAtLogin(true)), .perform(.setLaunchAtLogin(true), platform: platform)],
            "performed synchronously, before anything is awaited"
        )
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.setLaunchAtLogin(true)], "and never again from the pass")
    }

    /// The window: save A's pass is suspended inside `applyConfigChange`
    /// when save B lands. B must wait, and the machine must end in B's
    /// state, with A's actions run first.
    @RuntimeActor func testASaveArrivingWhileAPassIsSuspendedRunsAfterIt() async {
        let editedConfig = edited(port: 18081)
        host.holdNextApply = true
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOff)
        await settle("pass A is suspended in applyConfigChange") { self.host.isHolding }

        reconciler.reconcile(config: editedConfig, platformConfig: proxyOn)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(host.calls, [.applyConfigChange(port: 18081)], "B ran nothing while A was suspended")
        XCTAssertTrue(reconciler.hasPassInFlight)

        host.resume()
        await reconciler.drain()

        XCTAssertEqual(
            host.performed,
            [.clearSystemProxy, .applySystemProxy],
            "A's clear, then B's apply: the last save wins because it runs last"
        )
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn)
        XCTAssertFalse(reconciler.hasPassInFlight, "the last pass in the chain released the handle")
    }

    /// The bug the live-flag fix removed: pass A used to read the *current*
    /// flags for its config-driven re-apply, which by then said "on" again,
    /// so it re-applied a surface it was about to clear. The pass carries
    /// the flags of its own save and the host reads only those.
    @RuntimeActor func testAPassCarriesTheFlagsOfItsOwnSave() async {
        let editedConfig = edited(port: 18081)
        host.holdNextApply = true
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOff)
        await settle("pass A is suspended in applyConfigChange") { self.host.isHolding }
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOn)

        host.resume()
        await reconciler.drain()

        XCTAssertEqual(
            host.calls.filter { if case .reapply = $0 { true } else { false } },
            [.reapply(platform: proxyOff)],
            "A's re-apply sees A's flags, not B's; B changed no config so it re-applies nothing"
        )
        XCTAssertEqual(
            host.calls.compactMap { call -> PlatformIntegrationConfig? in
                if case .perform(_, let platform) = call { platform } else { nil }
            },
            [proxyOff, proxyOn]
        )
    }

    /// A clear that did not land leaves the flag where the machine is, so
    /// the next save — any save — diffs it again and retries.
    @RuntimeActor func testAFailedActionIsRetriedByTheNextSave() async {
        host.failing = [.clearSystemProxy]
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff)
        await reconciler.drain()

        XCTAssertEqual(host.performed, [.clearSystemProxy])
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "rewound to where the machine is")

        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy, .clearSystemProxy], "retried")

        host.failing = []
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy, .clearSystemProxy, .clearSystemProxy])
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOff, "landed, so reconciled")

        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff)
        XCTAssertFalse(reconciler.hasPassInFlight, "nothing left to retry")
    }

    /// A's clear fails after B has moved the flag back on. The machine still has the system proxy on, which is what B asks for, so B has
    /// nothing to apply, and A's failed clear is not retried against the save that now owns the flag.
    @RuntimeActor func testAFailedActionIsNotRewoundWhenALaterSaveMovedTheFlag() async {
        host.failing = [.clearSystemProxy]
        let editedConfig = edited(port: 18081)
        host.holdNextApply = true
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOff)
        await settle("pass A is suspended in applyConfigChange") { self.host.isHolding }
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOn)

        host.resume()
        await reconciler.drain()

        XCTAssertEqual(host.performed, [.clearSystemProxy], "B has nothing to do: the machine still holds the proxy on")
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "the failed clear left the flag where the machine is")
        XCTAssertFalse(reconciler.requestLags, "the request matches what the machine holds")

        reconciler.reconcile(config: edited(port: 18082), platformConfig: proxyOn)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy], "no phantom retry of A's clear")
    }

    /// An apply needs its runtime up; with it down, the start path applies
    /// the surface later. The pass reads the runtime after the config
    /// change has settled, so the table sees the state it produced.
    @RuntimeActor func testAnApplyWaitsForItsRuntime() async {
        host.runtime = RuntimeReconciler.RuntimeState(proxyIsUp: false, dnsIsUp: false)
        reconciler = RuntimeReconciler(config: baseConfig, platformConfig: proxyOff, host: host)

        reconciler.reconcile(config: baseConfig, platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertEqual(host.performed, [])
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "reconciled: the start path owns it from here")
    }

    /// The admission is a single authority. A retry runs under the admission its request was recorded with, so a fence
    /// that lapses before the retry stops it, and one that stands again lets it run.
    @RuntimeActor func testARetryRunsUnderTheAdmissionItsRequestWasRecordedWith() async {
        let admission = AdmissionBox()
        host.failing = [.clearSystemProxy]
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOff, isCurrent: { admission.stands })
        await reconciler.drain()
        XCTAssertTrue(reconciler.requestLags)

        admission.stands = false
        reconciler.retryRequest()
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy], "a retry under a lapsed admission runs nothing")

        admission.stands = true
        host.failing = []
        reconciler.retryRequest()
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy, .clearSystemProxy])
        XCTAssertFalse(reconciler.requestLags)
    }

    /// An admission that lapses while the pass's push is out stops the pass at its next step (decision 0032). The push already out lands,
    /// so the runtime baseline is the input it held, with no rewind. No platform action runs after it, so the flag it skipped is not
    /// recorded as reconciled, and the request still names the work. The same request under a standing admission then runs the action.
    @RuntimeActor func testAPassWhoseAdmissionLapsesDuringItsPushRunsNoActionAndRecordsNoFlag() async {
        let admission = AdmissionBox()
        let changed = edited(port: 18081)
        host.holdNextApply = true
        reconciler.reconcile(config: changed, platformConfig: proxyOff, isCurrent: { admission.stands })
        await settle("the pass's push is suspended") { self.host.isHolding }
        admission.stands = false
        host.resume()
        await reconciler.drain()

        XCTAssertEqual(host.calls, [.applyConfigChange(port: 18081)], "only the push that was already out ran")
        XCTAssertEqual(reconciler.lastReconciledConfig, changed, "the push held, so the runtime baseline is its input")
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "the skipped flag is not recorded as reconciled")
        XCTAssertTrue(reconciler.requestLags, "the request still names the skipped work")

        reconciler.reconcile(config: changed, platformConfig: proxyOff)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy], "a standing admission runs the action the lapsed pass skipped")
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOff)
        XCTAssertFalse(reconciler.requestLags)
    }

    /// A flag action is the effect running while its work is out (#47), so quiescence waits for it. A Stop that lapses the admission while it
    /// is held runs no further action. The held action landed, so it is recorded at the value its own save carried; the action it skipped and
    /// the group no action named are not, and the request still names the skipped work.
    @RuntimeActor func testQuiescenceWaitsForAHeldFlagActionAndALapsedAdmissionRecordsOnlyWhatLanded() async {
        let admission = AdmissionBox()
        var request = proxyOff
        request.manageEnvironmentVariables = true
        // DNS is down, so no action names this group; a pass that completes records it.
        request.manageSystemDNS = true
        host.holdNextAction = true
        reconciler.reconcile(config: baseConfig, platformConfig: request, isCurrent: { admission.stands })
        await settle("the first flag action is held") { self.host.isHoldingAction }
        XCTAssertEqual(host.performed, [.clearSystemProxy])

        let order = LockedLog<String>()
        let quiescence = Task { @RuntimeActor in
            order.append("waiting")
            await self.reconciler.quiesceEffects()
            order.append("quiesced")
        }
        await settle("quiescence waits on the held action") { order.values == ["waiting"] }
        admission.stands = false
        order.append("released")
        host.resumeAction()
        await quiescence.value
        await reconciler.drain()

        XCTAssertEqual(order.values, ["waiting", "released", "quiesced"], "quiescence waited for the held action, not for nothing")
        XCTAssertEqual(host.performed, [.clearSystemProxy], "the lapsed admission ran no further action")
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOff, "only the landed clear is recorded, at its save's value")
        XCTAssertEqual(reconciler.requestedPlatformConfig, request, "the completion leaves the save's request as it was")
        XCTAssertTrue(reconciler.requestLags, "the request still names the skipped work")
    }

    /// A request whose admission lapsed before it was recorded changes nothing: no request, no login item, no pass.
    @RuntimeActor func testALapsedAdmissionRecordsNothingAndRunsNoLaunchAction() async {
        let admission = AdmissionBox()
        admission.stands = false
        var platform = proxyOn
        platform.launchAtLogin = true

        reconciler.reconcile(config: edited(port: 18081), platformConfig: platform, isCurrent: { admission.stands })
        await reconciler.drain()

        XCTAssertEqual(host.calls, [], "no decision, no action, no push")
        XCTAssertEqual(reconciler.requestedConfig, baseConfig)
        XCTAssertEqual(reconciler.requestedPlatformConfig, proxyOn)
        XCTAssertFalse(reconciler.hasPassInFlight)
    }

    /// An older pass waiting on the lifecycle is superseded by a newer request: it never pushes the config it was given, and the newer
    /// request is the one that runs, diffing from what the machine holds.
    @RuntimeActor func testAnOlderWaitingPassIsSupersededByANewerRequest() async {
        host.holdLifecycle = true
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOn)
        await settle("the older pass waits for the lifecycle") { self.host.isWaitingForLifecycle }

        reconciler.reconcile(config: edited(port: 18082), platformConfig: proxyOff)
        host.releaseLifecycle()
        await reconciler.drain()

        XCTAssertEqual(host.calls.filter { if case .applyConfigChange = $0 { true } else { false } }, [.applyConfigChange(port: 18082)])
        XCTAssertEqual(host.performed, [.clearSystemProxy])
        XCTAssertEqual(reconciler.lastReconciledConfig, edited(port: 18082))
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOff)
    }

    /// A Start that overtakes a waiting reload pass must not see its config as already applied. The baseline never moved to the reload's
    /// input, so the Start's request still diffs against what the machine holds.
    @RuntimeActor func testARequestOvertakingAWaitingPassDiffsFromTheHeldBaseline() async {
        host.holdLifecycle = true
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOn)
        await settle("the reload's pass waits for the lifecycle") { self.host.isWaitingForLifecycle }
        XCTAssertEqual(reconciler.lastReconciledConfig, baseConfig, "queued, not applied: no baseline moved yet")

        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOn)
        host.releaseLifecycle()
        await reconciler.drain()

        XCTAssertEqual(host.calls.filter { if case .applyConfigChange = $0 { true } else { false } }, [.applyConfigChange(port: 18081)],
                       "the start's request still runs the push")
        XCTAssertEqual(reconciler.lastReconciledConfig, edited(port: 18081))
    }

    /// Partial Y, then back to X while the machine still holds Y. The push of Y landed and its surface re-apply never ran, so the baseline
    /// is Y. A request for X therefore pushes X: a diff against X would skip work the orchestrator still needs.
    @RuntimeActor func testReturningToTheOriginalConfigPushesItWhileTheMachineStillHoldsThePartialOne() async {
        let admission = AdmissionBox()
        host.holdNextApply = true
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOn, isCurrent: { admission.stands })
        await settle("the push of Y is suspended") { self.host.isHolding }
        admission.stands = false
        host.resume()
        await reconciler.drain()
        XCTAssertEqual(reconciler.lastReconciledConfig, edited(port: 18081), "the push of Y held, so the baseline is Y")

        reconciler.reconcile(config: baseConfig, platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertEqual(
            host.calls.filter { if case .applyConfigChange = $0 { true } else { false } },
            [.applyConfigChange(port: 18081), .applyConfigChange(port: baseConfig.localPort)]
        )
        XCTAssertEqual(reconciler.lastReconciledConfig, baseConfig)
    }

    /// A push that held nothing leaves the runtime baseline where it was and runs no surface, so the next request diffs the change again. The
    /// flag still settles: it needs no runtime input, and it is what the machine is asked to hold.
    @RuntimeActor func testAPushThatHeldNothingLeavesTheBaselineAndRunsNoSurface() async {
        host.refuseApply = true
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOff)
        await reconciler.drain()

        XCTAssertEqual(host.calls, [.applyConfigChange(port: 18081), .decision(.clearSystemProxy), .perform(.clearSystemProxy, platform: proxyOff)])
        XCTAssertEqual(reconciler.lastReconciledConfig, baseConfig)
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOff)
        XCTAssertTrue(reconciler.requestLags, "the runtime half still lags the request")
        XCTAssertTrue(host.reapplied.isEmpty)
    }

    /// The pass acts on the input the runtime holds, which is what the app's DNS flag adjusts, rather than on the request.
    @RuntimeActor func testTheSurfacesFollowTheHeldInputNotTheRequest() async {
        host.heldOverride = edited(port: 18090)
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertEqual(reconciler.lastReconciledConfig, edited(port: 18090))
        XCTAssertEqual(host.reapplied.map { $0.new.localPort }, [18090])
        XCTAssertEqual(host.reapplied.map { $0.old.localPort }, [baseConfig.localPort])
    }

    /// A Stop can revoke a pass between its push and its surface re-apply. The next pass with the same input has no runtime change, yet the
    /// re-apply it owes still runs, with the diff from the config before the push. A changed port and a changed bypass list both owe it.
    @RuntimeActor func testAStopRevokedSurfaceReapplyIsOwedToTheNextPassWithTheSameInput() async {
        var bypass = baseConfig
        bypass.noProxyHosts.append("bypass.example")
        for (name, changed) in [("port", edited(port: 18081)), ("bypass", bypass)] {
            host = RecordingHost()
            reconciler = RuntimeReconciler(config: baseConfig, platformConfig: proxyOn, host: host)
            let admission = AdmissionBox()
            host.holdNextApply = true
            reconciler.reconcile(config: changed, platformConfig: proxyOn, isCurrent: { admission.stands })
            await settle("the push is suspended (\(name))") { self.host.isHolding }
            admission.stands = false
            host.resume()
            await reconciler.drain()
            XCTAssertTrue(host.reapplied.isEmpty, "the revoked pass re-applied nothing (\(name))")

            reconciler.reconcile(config: changed, platformConfig: proxyOn)
            await reconciler.drain()

            XCTAssertEqual(host.reapplied.count, 1, "the owed re-apply ran once (\(name))")
            XCTAssertEqual(host.reapplied.first?.new, changed, "with the input the push held (\(name))")
            XCTAssertEqual(host.reapplied.first?.old, baseConfig, "diffed from before the push (\(name))")
        }
    }

    /// A refused push leaves the runtime change owed to the next request, which pushes it and applies its surfaces once with its own diff.
    @RuntimeActor func testARefusedPushIsRetriedByTheNextRequestWithItsOwnDiff() async {
        host.refuseApply = true
        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOff)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy], "the flag settles behind a push that held nothing")
        XCTAssertTrue(host.reapplied.isEmpty)
        host.refuseApply = false

        reconciler.reconcile(config: edited(port: 18081), platformConfig: proxyOff)
        await reconciler.drain()

        XCTAssertEqual(host.reapplied.count, 1)
        XCTAssertEqual(host.reapplied.first?.old, baseConfig)
        XCTAssertEqual(host.performed, [.clearSystemProxy], "no second clear: the flag already holds")
    }
}

/// An admission a test can lapse between two steps of one pass.
private final class AdmissionBox {
    var stands = true
}
