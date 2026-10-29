// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The runtime owner is `RuntimeActor`, not the main thread (decision 0031). With the main thread parked, the actual host answers
/// through the production framed and private clients, and a held machine effect waits on the queue it belongs to while the owner keeps
/// answering. Every test method is nonisolated, so it runs off the main thread and can park it; every wait is bounded, and the park
/// ends at its own limit, so a failure fails the test instead of hanging XCTest.
final class RuntimeActorPlacementTests: XCTestCase {
    private static let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)
    /// Harnesses not torn down yet, so a test that fails part way still releases its root.
    private var open: [InteractiveHostHarness] = []

    override func tearDown() async throws {
        for harness in open { await harness.tearDown() }
        open = []
        try await super.tearDown()
    }

    private func finish(_ composed: Composed) async {
        open.removeAll { $0 === composed.harness }
        await composed.harness.tearDown()
    }

    /// The host over a fresh harness, composed on the owner, with the clients the app holds.
    private struct Composed: Sendable {
        let harness: InteractiveHostHarness
        let control: any RuntimeClient
        let editor: PrivateEditorClient
    }

    @RuntimeActor
    private static func compose(
        platform: PlatformIntegrationConfig, dnsForwarderEnabled: Bool, tunnels: [TunnelDefinition] = []
    ) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: platform, dnsForwarderEnabled: dnsForwarderEnabled, tunnels: tunnels)
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(subscribers: 2), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let control = try makeFramedRuntimeClient(
            transport: composition.transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return Composed(harness: harness, control: control, editor: PrivateEditorClient(transport: composition.transport))
    }

    private func deadline() -> RuntimeDeadline { .after(.seconds(30), from: .now) }

    private func submit(_ composed: Composed, _ command: ControlRuntimeCommand, _ incarnation: ControlHostIncarnation) async throws
        -> ControlOperationID {
        let admission = try await composed.control.submit(
            command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: deadline()
        )
        guard case .accepted(let operation) = admission else {
            XCTFail("\(command) was admitted: \(admission)")
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    /// The stream's frames up to the named operation's settlement, bounded.
    private func settlement(of operation: ControlOperationID, on stream: RuntimeSubscription) async throws -> ControlOperationOutcome {
        for _ in 0..<128 {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                return finished.outcome
            }
        }
        XCTFail("the operation's settlement never reached the stream")
        throw RuntimeClientError.unexpectedReply
    }

    // MARK: - Framed progress with the main thread parked

    /// Start, status, snapshot, a page, the live observation, a private editor read, a reload, a Stop and the app's Quit all complete
    /// through the production clients while the main thread stays parked: nothing on that path needs it.
    func testEveryFramedCallCompletesWhileTheMainThreadIsParked() async throws {
        XCTAssertFalse(Thread.isMainThread, "the test runs off the main thread, so it can park it")
        let composed = try await Self.compose(platform: PlatformIntegrationConfig(manageSystemProxy: true), dnsForwarderEnabled: false)
        open.append(composed.harness)
        let park = MainThreadPark()
        defer { park.release() }
        await park.park(limit: .seconds(60))

        let status = try await composed.control.readSnapshot(deadline: deadline())
        let incarnation = status.stamp.incarnation
        let modules = try XCTUnwrap(status.stamp.modules)
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }

        let start = try await submit(composed, .start(.proxy, ifModuleRevision: modules.proxy), incarnation)
        _ = try await settlement(of: start, on: stream)
        let started = try await composed.control.readSnapshot(deadline: deadline())
        XCTAssertEqual(started.proxyState, .running, "the Start completed")

        _ = try await composed.control.readPage(
            ControlPageRequest(expectedIncarnation: incarnation, collection: .activeConnections), deadline: deadline()
        )
        let reading = deadline()
        guard case .observation = try await composed.editor.read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
            budget: try reading.wireBudget(at: .now, cappedAt: .seconds(30)), deadline: reading
        ) else { return XCTFail("the private editor read an observation") }

        let reload = try await submit(composed, .reload, incarnation)
        _ = try await settlement(of: reload, on: stream)
        let stop = try await submit(composed, .stop(.proxy), incarnation)
        _ = try await settlement(of: stop, on: stream)
        let stopped = try await composed.control.readSnapshot(deadline: deadline())
        XCTAssertNotEqual(stopped.proxyState, .running, "the Stop completed")

        let quit = await RuntimeClientQuit.quit(
            control: composed.control, editor: composed.editor, incarnation: incarnation, total: .seconds(10)
        )
        guard case .settled = quit.quit else { return XCTFail("the Quit settled: \(quit.quit)") }
        XCTAssertTrue(park.isParked, "the main thread stayed parked through every call")
        park.release()
        await finish(composed)
    }

    // MARK: - Held effects

    /// One machine effect the table holds: the platform it needs, the framed command or observer report that queues it, and the module
    /// a Stop admitted while it is held names.
    private struct HeldEffect: Sendable {
        enum Trigger: Sendable { case start(ControlModule), vpnConnected }

        let name: String
        let platform: PlatformIntegrationConfig
        let dnsForwarderEnabled: Bool
        let operation: PrivilegedOperation
        let trigger: Trigger
        let stop: ControlModule
        /// The tunnels the configuration names; a proxied one's resolver file is written by the tunnel start and removed by its Stop.
        var tunnels: [TunnelDefinition] = []
    }

    /// One enabled proxied tunnel on an ephemeral loopback port. Its start binds the tunnel DNS responder on the fixed
    /// `TunnelResolverPort`, then writes the remote host's resolver file through the helper.
    private static let resolvedTunnel = TunnelDefinition(
        localPort: 0, remoteHost: "db.resolver-row.test", remotePort: 5432, proxied: true, label: "Resolver row"
    )

    private static let heldEffects: [HeldEffect] = [
        HeldEffect(name: "system proxy apply", platform: PlatformIntegrationConfig(manageSystemProxy: true), dnsForwarderEnabled: false,
                   operation: .applySystemProxy, trigger: .start(.proxy), stop: .proxy),
        HeldEffect(name: "system DNS", platform: proxyAndDNS, dnsForwarderEnabled: true,
                   operation: .setDNSServers, trigger: .start(.dns), stop: .dns),
        HeldEffect(name: "split-DNS entry file", platform: PlatformIntegrationConfig(manageSystemProxy: true, manageDNSResolvers: true),
                   dnsForwarderEnabled: false, operation: .applyDNS, trigger: .vpnConnected, stop: .proxy),
        HeldEffect(name: "tunnel resolver file", platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false,
                   operation: .applyDNS, trigger: .start(.tunnels), stop: .tunnels, tunnels: [resolvedTunnel]),
    ]

    /// Puts the VPN down and lets its delivery land, so the next `.connected` writes the entry file.
    @RuntimeActor
    private static func vpnDown(_ harness: InteractiveHostHarness) async {
        harness.vpn.emit(.disconnected(reason: .userInitiated))
        await harness.host?.deliveries.drain()
    }

    /// Each effect, held on the host's platform queue with the main thread parked: it arrived there and nowhere else, the status read
    /// answers and the Stop is admitted while it is held, and once released the Stop settles after it. The other held effects keep their
    /// own witnesses: the relay (`RuntimeHostControlOwnerTests`, `RelayLifecycleTests`), the logger drain
    /// (`testAHeldLoggerDrainLeavesStatusReadsAndStopAdmissionAnswered`) and the DNS retry and repair suites.
    func testEachHeldEffectWaitsOnItsQueueWhileTheOwnerAnswersWithTheMainThreadParked() async throws {
        XCTAssertFalse(Thread.isMainThread, "the test runs off the main thread, so it can park it")
        for effect in Self.heldEffects {
            let composed = try await Self.compose(
                platform: effect.platform, dnsForwarderEnabled: effect.dnsForwarderEnabled, tunnels: effect.tunnels
            )
            open.append(composed.harness)
            let hold = composed.harness.hold
            defer { hold.releaseAll() }
            let first = try await composed.control.readSnapshot(deadline: deadline())
            let incarnation = first.stamp.incarnation
            let stream = try await composed.control.subscribe(.live, deadline: deadline())
            defer { stream.cancel() }
            guard case .baseline = try await stream.next(deadline()) else { return XCTFail("\(effect.name): a baseline") }
            if case .vpnConnected = effect.trigger {
                let modules = try XCTUnwrap(first.stamp.modules)
                _ = try await settlement(of: try await submit(composed, .start(.proxy, ifModuleRevision: modules.proxy), incarnation), on: stream)
                await Self.vpnDown(composed.harness)
            }

            let park = MainThreadPark()
            defer { park.release() }
            await park.park(limit: .seconds(60))
            hold.arm(onQueueLabeled: ".platform-work", otherQueues: .recorded) { name, _ in name == effect.operation.rawValue }
            switch effect.trigger {
            case .start(let module):
                let current = try await composed.control.readSnapshot(deadline: deadline())
                let modules = try XCTUnwrap(current.stamp.modules)
                let revision = switch module {
                case .proxy: modules.proxy
                case .dns: modules.dns
                case .tunnels: modules.tunnels
                }
                _ = try await submit(composed, .start(module, ifModuleRevision: revision), incarnation)
            case .vpnConnected:
                composed.harness.vpn.emit(.connected)
            }
            let reached = await hold.waitUntilReached(within: .seconds(10))
            XCTAssertTrue(reached, "\(effect.name): the effect arrived")
            XCTAssertTrue(hold.reachedOnArmedQueue, "\(effect.name): on \(hold.reachedQueueLabel ?? "nothing")")
            XCTAssertFalse(hold.reachedOnMainThread, "\(effect.name): not on the main thread")
            XCTAssertFalse(hold.reachedOnCooperativePool, "\(effect.name): not on the concurrency pool")
            XCTAssertTrue(hold.isHolding, "\(effect.name): held")

            let held = try await composed.control.readSnapshot(deadline: deadline())
            XCTAssertEqual(held.stamp.incarnation, incarnation, "\(effect.name): the status read answered while it was held")
            let stop = try await submit(composed, .stop(effect.stop), incarnation)
            XCTAssertTrue(hold.isHolding, "\(effect.name): the Stop was admitted while it was held")
            hold.release()
            _ = try await settlement(of: stop, on: stream)
            XCTAssertTrue(composed.harness.machine.privilege.commands.contains { $0.command == effect.operation },
                          "\(effect.name): the held effect landed")
            // The Stop admitted while a tunnel start's resolver write was held joins that start, then removes what it wrote.
            for tunnel in effect.tunnels where tunnel.proxied {
                let host = tunnel.remoteHost
                XCTAssertTrue(composed.harness.machine.privilege.commands(matching: .applyDNS).contains { $0.first == host },
                              "\(effect.name): the held write was for the tunnel's host")
                XCTAssertTrue(composed.harness.machine.privilege.commands(matching: .removeDNS).contains { $0.first == host },
                              "\(effect.name): the Stop removed it through the helper")
                XCTAssertNil(composed.harness.machine.resolverFile(for: host), "\(effect.name): no resolver file is left")
                let stopped = try await composed.control.readSnapshot(deadline: deadline())
                XCTAssertEqual(stopped.tunnelsRunState, .stopped, "\(effect.name): the tunnels are stopped")
            }
            XCTAssertTrue(park.isParked, "\(effect.name): the main thread stayed parked")
            park.release()
            stream.cancel()
            await finish(composed)
        }
    }
}
