// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

/// Stands in for `AppState`: records every call in order, answers a fixed
/// runtime state, fails the actions it is told to, and can hold the config
/// apply open so a test can land a second save while the first pass is
/// suspended — the window every rule in `RuntimeReconciler` is about.
@MainActor
private final class RecordingHost: RuntimeReconcilerHost {
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

    var performed: [PlatformIntegrationReconciler.Action] {
        calls.compactMap { if case .perform(let action, _) = $0 { action } else { nil } }
    }

    func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async {
        calls.append(.applyConfigChange(port: new.localPort))
        if holdNextApply {
            holdNextApply = false
            await withCheckedContinuation { held = $0 }
        }
    }

    func resume() {
        held?.resume()
        held = nil
    }

    func runtimeState() -> RuntimeReconciler.RuntimeState { runtime }

    func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) {
        calls.append(.reapply(platform: pass.platform))
    }

    func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action) {
        calls.append(.decision(action))
    }

    func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig
    ) -> Bool {
        calls.append(.perform(action, platform: platform))
        return !failing.contains(action)
    }
}

@MainActor
final class RuntimeReconcilerTests: XCTestCase {

    private var host: RecordingHost!
    private var reconciler: RuntimeReconciler!
    private let baseConfig = ProxyConfig.testFixture()
    private let proxyOn = PlatformIntegrationConfig(manageSystemProxy: true)
    private let proxyOff = PlatformIntegrationConfig(manageSystemProxy: false)

    override func setUp() {
        super.setUp()
        host = RecordingHost()
        reconciler = RuntimeReconciler(config: baseConfig, platformConfig: proxyOn, host: host)
    }

    private func edited(port: Int) -> ProxyConfig {
        var config = baseConfig
        config.localPort = port
        return config
    }

    private func settle(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)", file: file, line: line)
    }

    func testASaveThatChangesNothingQueuesNoPass() async {
        reconciler.reconcile(config: baseConfig, platformConfig: proxyOn)

        XCTAssertFalse(reconciler.hasPassInFlight)
        await reconciler.drain()
        XCTAssertEqual(host.calls, [])
    }

    /// A lifecycle flip is already live in the runtime; marking it
    /// reconciled is what keeps its own save from restarting the subsystem.
    func testAConfigMarkedReconciledDoesNotQueueAPass() async {
        let flipped = edited(port: 18081)
        reconciler.markReconciled(config: flipped)

        reconciler.reconcile(config: flipped, platformConfig: proxyOn)

        XCTAssertFalse(reconciler.hasPassInFlight)
        XCTAssertEqual(host.calls, [])
    }

    /// The login item needs no runtime state and must not wait for the
    /// pass: a quit right after the save would lose it.
    func testLaunchAtLoginRunsBeforeThePassIsQueued() async {
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
    func testASaveArrivingWhileAPassIsSuspendedRunsAfterIt() async {
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
    func testAPassCarriesTheFlagsOfItsOwnSave() async {
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
    func testAFailedActionIsRetriedByTheNextSave() async {
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

    /// The rewind must not undo a later save. A's clear fails after B has
    /// already moved the flag back on; rewinding would mark "on" as
    /// unreconciled and make the next save clear a surface B just applied.
    func testAFailedActionIsNotRewoundWhenALaterSaveMovedTheFlag() async {
        host.failing = [.clearSystemProxy]
        let editedConfig = edited(port: 18081)
        host.holdNextApply = true
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOff)
        await settle("pass A is suspended in applyConfigChange") { self.host.isHolding }
        reconciler.reconcile(config: editedConfig, platformConfig: proxyOn)

        host.resume()
        await reconciler.drain()

        XCTAssertEqual(host.performed, [.clearSystemProxy, .applySystemProxy])
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "B owns the flag now")

        reconciler.reconcile(config: edited(port: 18082), platformConfig: proxyOn)
        await reconciler.drain()
        XCTAssertEqual(host.performed, [.clearSystemProxy, .applySystemProxy], "no phantom retry of A's clear")
    }

    /// An apply needs its runtime up; with it down, the start path applies
    /// the surface later. The pass reads the runtime after the config
    /// change has settled, so the table sees the state it produced.
    func testAnApplyWaitsForItsRuntime() async {
        host.runtime = RuntimeReconciler.RuntimeState(proxyIsUp: false, dnsIsUp: false)
        reconciler = RuntimeReconciler(config: baseConfig, platformConfig: proxyOff, host: host)

        reconciler.reconcile(config: baseConfig, platformConfig: proxyOn)
        await reconciler.drain()

        XCTAssertEqual(host.performed, [])
        XCTAssertEqual(reconciler.lastReconciledPlatformConfig, proxyOn, "reconciled: the start path owns it from here")
    }
}
