// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// `pm-sim relay-reassert-after-stop` (#199). The transparent-relay reassert
/// probes the intercept address off the main actor, for up to its connect
/// timeout. A stop that lands while the probe is out must win: the stale
/// "nothing accepts" verdict is dropped with `tcp_relay.reassert_superseded`
/// instead of restarting the relay the user just turned off. And a reassert
/// whose relay start is already out, on the platform queue, runs in the DNS
/// module's slot: a DNS stop admitted meanwhile tears down after it and
/// stops the relay it raised. The helper is `RecordingPrivilegeClient`, so
/// nothing on the machine changes.
enum RelayReassertScenarios {
    /// The platform queue the scenario's relay commands run on, as the host's do on its own.
    private static let relayQueueLabel = "io.github.srps.Conduit.pm-sim.relay-platform-work"

    @MainActor
    static func stopDuringProbe() async throws -> ScenarioResult {
        let start = Date()
        let host = "127.44.3.0"
        let client = RecordingPrivilegeClient()
        let probe = HeldStep()
        defer { probe.release() }
        let orchestrator = makeOrchestrator(client: client, relay: HeldStep()) { _, _ in
            probe.pass()
            return false
        }
        await orchestrator.startDNS()
        let dnsUp = orchestrator.snapshot.dnsRunState == .running
        // The first probe answers at once: the relay is gone, so it comes up.
        await orchestrator.reassertTransparentRelay(host: host, targetPort: 10443)
        let afterFirst = client.commands.map(\.command)

        probe.arm()
        let pending = Task { @MainActor in
            await orchestrator.reassertTransparentRelayOffMain(host: host, targetPort: 10443)
        }
        let probeHeld = await probe.waitUntilHeld(within: .seconds(10))
        await orchestrator.stopDNS()
        probe.release()
        await pending.value

        let events = orchestrator.eventLog.events
        let slot = await heldStartAgainstAStop(host: host)
        return ScenarioResult(
            name: "relay-reassert-after-stop", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the DNS module is up, so a reassert may run in its slot", dnsUp),
                .init("a gone relay is reissued when nothing intervenes", afterFirst == [.startTCPRelay]),
                .init("the second probe is out when the stop lands", probeHeld),
                .init("a stop during the probe is not followed by a start",
                      client.commands.map(\.command) == [.startTCPRelay, .stopTCPRelay]),
                .init("the stale verdict is one tcp_relay.reassert_superseded",
                      events.filter { $0.event == "tcp_relay.reassert_superseded" }.map(\.detail)
                          == ["host=\(host) target=10443 relay_active=false"]),
                .init("only the first reassert reports tcp_relay.reasserted",
                      events.filter { $0.event == "tcp_relay.reasserted" }.count == 1),
                .init("a reassert's relay start is held on the platform queue", slot.heldOnPlatformQueue),
                .init("a DNS stop admitted while it is held tears down after it", slot.teardownWaited),
                .init("the stop's teardown stops the relay the reassert raised",
                      slot.commands == [.startTCPRelay, .stopTCPRelay]),
                .init("the DNS module ends stopped", slot.stopped),
            ],
            notes: ["held relay start ran on: \(slot.queueLabel ?? "nothing reached")"]
        )
    }

    /// What the held-start row saw.
    private struct SlotWitness {
        var heldOnPlatformQueue = false
        var queueLabel: String?
        var teardownWaited = false
        var commands: [PrivilegedOperation] = []
        var stopped = false
    }

    /// A reassert whose relay start is held on the platform queue, inside the DNS module's slot, then a DNS stop. The stop's teardown
    /// must wait for the reassert's effect and then stop the relay it raised. Every wait is bounded, and the hold is released on every
    /// path.
    @MainActor
    private static func heldStartAgainstAStop(host: String) async -> SlotWitness {
        let client = RecordingPrivilegeClient()
        let relay = HeldStep()
        defer { relay.release() }
        let orchestrator = makeOrchestrator(client: client, relay: relay) { _, _ in false }
        await orchestrator.startDNS()
        var witness = SlotWitness()
        relay.arm(onQueueLabeled: relayQueueLabel)
        let reassert = Task { @MainActor in
            await orchestrator.reassertTransparentRelay(host: host, targetPort: 10443)
        }
        let reached = await relay.waitUntilHeld(within: .seconds(10))
        witness.heldOnPlatformQueue = reached && relay.heldOnExpectedQueue
        witness.queueLabel = relay.queueLabel
        let stop = Task { @MainActor in await orchestrator.stopDNS() }
        // A teardown beside the slot closes the forwarder within a few milliseconds; give it that long to show.
        for _ in 0..<500 where orchestrator.snapshot.dnsRunState == .running {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        witness.teardownWaited = reached && orchestrator.snapshot.dnsRunState == .running && client.commands.isEmpty
        relay.release()
        await reassert.value
        await stop.value
        witness.commands = client.commands.map(\.command)
        witness.stopped = orchestrator.snapshot.dnsRunState == .stopped
        return witness
    }

    /// An orchestrator whose forwarder binds an ephemeral loopback port and whose relay commands run one at a time on the scenario's
    /// own platform queue, each offered to `relay` there first.
    @MainActor
    private static func makeOrchestrator(
        client: RecordingPrivilegeClient,
        relay: HeldStep,
        probe: @escaping @Sendable (String, Int) -> Bool
    ) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderPort = 0
        let work = PlatformWork(label: relayQueueLabel)
        return ProxyOrchestrator(
            config: config,
            relayCommand: { step in
                try await work.run {
                    Result {
                        relay.pass()
                        try client.execute(step.operation, values: step.values)
                    }
                }.get()
            },
            relayAcceptProbe: probe
        )
    }

    /// Parks the first call after `arm()` until `release()`, bounded, so the scenario can act while it is out. Armed with a queue label,
    /// it parks only a call made on that queue: one made anywhere else, the main thread or the generic executor, is recorded and let
    /// through, so the placement check fails instead of the run waiting out its bound.
    private final class HeldStep: @unchecked Sendable {
        private let lock = NSLock()
        private let reachedSignal = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private var armed = false
        private var expectedQueue: String?
        private var onExpectedQueue = false
        private var label: String?

        var heldOnExpectedQueue: Bool { lock.withLock { onExpectedQueue } }
        var queueLabel: String? { lock.withLock { label } }

        func arm(onQueueLabeled expectedQueue: String? = nil) {
            lock.withLock {
                armed = true
                self.expectedQueue = expectedQueue
                onExpectedQueue = false
                label = nil
            }
        }

        func pass() {
            let isMain = Thread.isMainThread
            let queueLabel = String(cString: __dispatch_queue_get_label(nil))
            let parks = lock.withLock { () -> Bool? in
                guard armed else { return nil }
                armed = false
                label = queueLabel
                onExpectedQueue = !isMain && (expectedQueue.map { queueLabel == $0 } ?? true)
                return onExpectedQueue
            }
            guard let parks else { return }
            reachedSignal.signal()
            if parks { _ = gate.wait(timeout: .now() + 10) }
        }

        /// Waits, off the main actor, until the armed call has arrived; false after `limit`.
        func waitUntilHeld(within limit: Duration) async -> Bool {
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    continuation.resume(returning: self.reachedSignal.wait(timeout: .now() + seconds) == .success)
                }
            }
        }

        /// Lets the parked call go on.
        func release() {
            gate.signal()
        }
    }
}
