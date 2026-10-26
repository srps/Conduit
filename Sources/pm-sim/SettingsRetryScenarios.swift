// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// Issue #176. Settings save on their own (#171), and closing a section
/// while a pass is out looks again once it drains. This drives the shared
/// piece that look relies on: a real `RuntimeReconciler` over a real
/// `SystemProxyManager` on `FakeMachine`, with the clear refused once.
///
/// - The refused clear rewinds the baseline, not the request, so the save
///   still reads as not landed.
/// - The retry runs that save's request again, and the machine is cleared.
/// - An edit made since, one that would block a proxy start, is not part
///   of the retry: it is neither applied nor reconciled.
///
/// The app is an executable and cannot be linked here; the debounce, the
/// start-blocking hold and the section close are covered end to end by
/// `AppStateHarnessTests`.
enum SettingsRetryScenarios {

    /// `AppState`'s reconcile hooks, reduced to the system proxy.
    @MainActor
    private final class Host: RuntimeReconcilerHost {
        let manager: SystemProxyManager
        let events = RuntimeEventLog(capacity: 64)
        private(set) var appliedConfigs: [ProxyConfig] = []

        init(manager: SystemProxyManager) {
            self.manager = manager
        }

        func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async -> RuntimeConfigApplication {
            appliedConfigs.append(new)
            return .held(new)
        }

        func runtimeState() -> RuntimeReconciler.RuntimeState {
            RuntimeReconciler.RuntimeState(proxyIsUp: true, dnsIsUp: false)
        }

        func awaitLifecycleIdle() async {}

        func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) {}

        func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action) {
            events.append(RuntimeEvent(kind: .config, event: "config.platform_integration", detail: String(describing: action)))
        }

        func perform(
            _ action: PlatformIntegrationReconciler.Action,
            config: ProxyConfig,
            previousConfig: ProxyConfig,
            platform: PlatformIntegrationConfig,
            previousPlatform: PlatformIntegrationConfig
        ) -> Bool {
            do {
                switch action {
                case .applySystemProxy:
                    try manager.apply(config: config, mode: platform.systemProxyMode, logger: nil)
                case .clearSystemProxy:
                    // As `AppState.perform`: a partial teardown keeps its
                    // journal records instead of throwing, so the journal
                    // says whether the clear landed.
                    try manager.clear(logger: nil)
                    return !manager.hasManagedState()
                default:
                    break
                }
                return true
            } catch {
                events.append(RuntimeEvent(kind: .config, event: "pm_sim.action_failed",
                                           detail: "action=\(action) reason=\(error.localizedDescription)"))
                return false
            }
        }

        func count(_ event: String) -> Int {
            events.events.filter { $0.event == event }.count
        }
    }

    @MainActor
    static func retryRequest() async throws -> ScenarioResult {
        let name = "settings-retry-request"
        let began = Date()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-sim-settings-\(UUID().uuidString)", isDirectory: true)
        ScenarioCleanup.register {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                ConsoleLogSink().log(.warning, "pm-sim could not remove \(directory.path): \(error.localizedDescription)", category: .general)
            }
        }
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver", isDirectory: true))
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
        let manager = SystemProxyManager(
            privilegeClient: machine,
            journal: journal,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            portProbe: { _ in false }
        )
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 3128
        let on = PlatformIntegrationConfig(manageSystemProxy: true)
        var off = on
        off.manageSystemProxy = false
        try manager.apply(config: config, mode: on.systemProxyMode, logger: nil)
        let host = Host(manager: manager)
        let reconciler = RuntimeReconciler(config: config, platformConfig: on, host: host)
        var notes: [String] = []

        // 1. The section close saves the switch off; the clear is refused.
        machine.privilege.failing = [.setWebProxyEndpoint]
        reconciler.reconcile(config: config, platformConfig: off)
        await reconciler.drain()
        let refusedLeftRouting = machine.service("Wi-Fi").routesThroughAProxy
        let refusedLags = reconciler.requestLags
        notes.append("refused: routed=\(refusedLeftRouting) requestLags=\(refusedLags)")

        // 2. An edit made in the next section, still unsaved: a half-typed host.
        var later = config
        later.localHost = "127.0."
        let laterBlocksStart = later.validate().contains(where: \.blocksProxyStart)

        // 3. The drained close looks again.
        machine.privilege.failing = []
        reconciler.retryRequest()
        await reconciler.drain()
        let cleared = !machine.service("Wi-Fi").routesThroughAProxy
        notes.append("retry: routed=\(!cleared) requestLags=\(reconciler.requestLags) decisions=\(host.count("config.platform_integration"))")

        return ScenarioResult(
            name: name, clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a refused clear left the machine routed and the request not landed", refusedLeftRouting && refusedLags),
                .init("the retry ran the clear again and the machine is cleared", cleared && host.count("config.platform_integration") == 2),
                .init("the request has landed", !reconciler.requestLags),
                .init("the later edit blocks a start", laterBlocksStart),
                .init("and the retry neither applied nor reconciled it",
                      !host.appliedConfigs.contains(later) && reconciler.lastReconciledConfig.localHost != later.localHost),
            ],
            notes: notes
        )
    }
}
