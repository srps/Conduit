// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// `pm-sim relay-reassert-after-stop` (#199). The transparent-relay reassert
/// probes the intercept address off the main actor, for up to its connect
/// timeout. A stop that lands while the probe is out must win: the stale
/// "nothing accepts" verdict is dropped with `tcp_relay.reassert_superseded`
/// instead of restarting the relay the user just turned off. The helper is
/// `RecordingPrivilegeClient`, so nothing on the machine changes.
enum RelayReassertScenarios {
    @MainActor
    static func stopDuringProbe() async throws -> ScenarioResult {
        let start = Date()
        let client = RecordingPrivilegeClient()
        let probe = HeldProbe()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { host, port in probe.accepts(host, port) }
        )
        let host = "127.44.3.0"
        // The first probe answers at once: the relay is gone, so it comes up.
        orchestrator.reassertTransparentRelay(host: host, targetPort: 10443)
        let afterFirst = client.commands.map(\.command)

        let pending = Task { @MainActor in
            await orchestrator.reassertTransparentRelayOffMain(host: host, targetPort: 10443)
        }
        await probe.waitUntilHeld()
        await orchestrator.stopDNS()
        probe.release()
        await pending.value

        let events = orchestrator.eventLog.events
        return ScenarioResult(
            name: "relay-reassert-after-stop", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a gone relay is reissued when nothing intervenes", afterFirst == [.startTCPRelay]),
                .init("a stop during the probe is not followed by a start",
                      client.commands.map(\.command) == [.startTCPRelay, .stopTCPRelay]),
                .init("the stale verdict is one tcp_relay.reassert_superseded",
                      events.filter { $0.event == "tcp_relay.reassert_superseded" }.map(\.detail)
                          == ["host=\(host) target=10443 relay_active=false"]),
                .init("only the first reassert reports tcp_relay.reasserted",
                      events.filter { $0.event == "tcp_relay.reasserted" }.count == 1),
            ],
            notes: []
        )
    }

    /// Answers the first probe at once (not accepting) and holds every later
    /// one until released.
    private final class HeldProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let held = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)

        func accepts(_ host: String, _ port: Int) -> Bool {
            let call = lock.withLock { () -> Int in
                calls += 1
                return calls
            }
            guard call > 1 else { return false }
            held.signal()
            gate.wait()
            return false
        }

        func waitUntilHeld() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.held.wait()
                    continuation.resume()
                }
            }
        }

        func release() {
            gate.signal()
        }
    }
}
