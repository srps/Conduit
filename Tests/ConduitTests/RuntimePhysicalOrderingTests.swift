// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// Holds the first armed caller until `open`. The DNS tests arm it through the forwarder's own `willBindTCP` seam, so a start waits with
/// its UDP socket bound and its TCP socket not yet bound, and its channels not yet published.
private actor BindGate {
    private var armed: Bool
    private(set) var heldPort: Int?
    private var release: CheckedContinuation<Void, Never>?

    init(armed: Bool = true) { self.armed = armed }

    func arm() {
        armed = true
        heldPort = nil
    }

    func hold(_ port: Int) async {
        guard armed else { return }
        armed = false
        heldPort = port
        await withCheckedContinuation { release = $0 }
    }

    /// Releases the held caller, if any, and lets every later caller through.
    func open() {
        armed = false
        release?.resume()
        release = nil
    }
}

/// Waits, bounded, for something the event loops do off the main actor, such as accepting a connection.
@MainActor
private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<1_000 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "the condition never held", file: file, line: line)
}

/// A bounded wait or search ran out; the caller has already failed the test with the reason.
private struct BoundExhausted: Error {}

/// The port the held caller passed. Bounded: if no caller reaches the gate, it fails the test, opens the gate so a late caller does not
/// park, and throws, so the test's teardown stops what it started.
@MainActor
private func arrival(at gate: BindGate, file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
    for _ in 0..<1_000 {
        if let port = await gate.heldPort { return port }
        try await Task.sleep(for: .milliseconds(10))
    }
    await gate.open()
    XCTFail("no caller reached the gate", file: file, line: line)
    throw BoundExhausted()
}

/// Every DNS and tunnel run state change the orchestrator publishes once `record` is called, so a test sees a stale `running` even when a
/// later teardown publishes `stopped` over it. Changes only: other publishes, such as a config edit's, repeat the module's state unchanged.
@MainActor
private final class PublishedStates {
    var dns: [ModuleRunState] = []
    var tunnels: [ModuleRunState] = []

    func record(_ orchestrator: ProxyOrchestrator) {
        let dnsBefore = orchestrator.snapshot.dnsRunState
        let tunnelsBefore = orchestrator.snapshot.tunnelsRunState
        orchestrator.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            if snapshot.dnsRunState != (self.dns.last ?? dnsBefore) { self.dns.append(snapshot.dnsRunState) }
            if snapshot.tunnelsRunState != (self.tunnels.last ?? tunnelsBefore) { self.tunnels.append(snapshot.tunnelsRunState) }
        }
    }
}

@MainActor
private final class Trace {
    var steps: [String] = []
}

@MainActor
private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    var turns = 0
    while !condition(), turns < 10_000 {
        turns += 1
        await Task.yield()
    }
    XCTAssertTrue(condition(), "the condition never held", file: file, line: line)
}

/// The DNS forwarder and the tunnel listeners on real loopback sockets. A stop admitted while a DNS start or restart is inside its bind
/// (held at `willBindTCP`), or while a tunnel start or reconcile is queued behind a held effect, leaves no listener open and nothing
/// published; a config edit never starts a stopped module, nor restarts or reconciles one whose stop is still tearing down.
@MainActor
final class RuntimePhysicalOrderingTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    /// A configured `port`, so the forwarder binds the pair once, on that number, and the gate's port is its own: with `port: 0` it rightly
    /// retries past a TCP number another socket holds, and the gate would keep the number it gave up.
    private func makeDNSOrchestrator(gate: BindGate, port: Int) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.upstreams = []
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = port
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        orchestrator.dnsForwarder = LocalDNSForwarder(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            willBindTCP: { port in await gate.hold(port) }
        )
        return orchestrator
    }

    private func makeTunnelOrchestrator(ports: [Int], upstreams: [UpstreamProxy] = []) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.upstreams = upstreams
        config.tunnels.definitions = ports.map(Self.tunnel(port:))
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    private static func tunnel(port: Int) -> TunnelDefinition {
        TunnelDefinition(localPort: port, remoteHost: "db.example.com", remotePort: 5432, proxied: false, label: "T\(port)")
    }

    /// Below the macOS ephemeral range (49152 up), whose numbers any outbound socket on the machine, or another test process, may take
    /// after a release, so a probe there cannot tell a leak from a stranger. Each pick is used once per process; the window comes from the
    /// pid so concurrent test processes start apart.
    private static var nextPort = 20_000 + Int(getpid()) % 280 * 100

    /// A loopback port free on both TCP and UDP right now, distinct from `excluding`, in a bounded number of picks.
    private func freePort(excluding: Set<Int> = []) async throws -> Int {
        for _ in 0..<64 {
            let port = Self.nextPort
            Self.nextPort = port + 1 < 48_000 ? port + 1 : 20_000
            if !excluding.contains(port), try await isFree(port) { return port }
        }
        XCTFail("no port below the ephemeral range was free on both TCP and UDP")
        throw BoundExhausted()
    }

    /// Binds both without `SO_REUSEADDR`, as the release probes do; only `EADDRINUSE` means taken.
    private func isFree(_ port: Int) async throws -> Bool {
        do {
            let tcp = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            try await tcp.close().get()
            let udp = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            try await udp.close().get()
            return true
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            return false
        }
    }

    /// Binds without `SO_REUSEADDR`, so a listener still open on `port` fails it.
    private func assertReleased(tcp port: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let probe = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            try await probe.close().get()
        } catch {
            XCTFail("TCP port \(port) is still bound: \(error)", file: file, line: line)
        }
    }

    private func assertReleased(udp port: Int, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let probe = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
            try await probe.close().get()
        } catch {
            XCTFail("UDP port \(port) is still bound: \(error)", file: file, line: line)
        }
    }

    private func assertDNSStopped(_ orchestrator: ProxyOrchestrator, port: Int, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .stopped, file: file, line: line)
        XCTAssertNil(orchestrator.snapshot.bindings.dnsPort, file: file, line: line)
        XCTAssertNil(orchestrator.dnsForwarder.listeningPort, file: file, line: line)
        XCTAssertNil(orchestrator.dnsForwarder.tcpListeningPort, file: file, line: line)
        await assertReleased(udp: port, file: file, line: line)
        await assertReleased(tcp: port, file: file, line: line)
    }

    /// Holds `lifecycle`'s slot with a gated effect under the latest epoch, so the next operation queues behind it, before its claim.
    private func holdSlot(_ lifecycle: PhysicalLifecycle, gate: BindGate) async throws -> Task<Bool, Error> {
        let epoch = lifecycle.epoch
        let held = Task { try await lifecycle.run(epoch: epoch) { await gate.hold(0) } }
        _ = try await arrival(at: gate)
        return held
    }

    /// Applies `edited` in a task and waits, bounded, for it to return without the held slot opening: an edit that queued a restart or
    /// reconcile behind the slot fails here, and the caller still opens the gate and joins.
    private func applyWhileHeld(
        _ edited: ProxyConfig,
        to orchestrator: ProxyOrchestrator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Task<Void, Never> {
        let trace = Trace()
        let apply = Task {
            await orchestrator.applyConfigChange(edited)
            trace.steps.append("applied")
        }
        await waitUntil({ trace.steps == ["applied"] }, file: file, line: line)
        return apply
    }

    // MARK: - DNS

    /// The stop used to find no channel while the bind was pending, publish `stopped`, and then watch the start publish `running` over it
    /// with both listeners open.
    func testDNSStopAdmittedDuringTheBindClosesItAndPublishesStopped() async throws {
        let port = try await freePort()
        let gate = BindGate()
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }

        let start = Task { await orchestrator.startDNS() }
        let held = try await arrival(at: gate)
        XCTAssertEqual(held, port, "the held start bound its UDP socket on the configured port")
        let stopEpoch = orchestrator.dnsLifecycle.epoch + 1
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == stopEpoch }
        let published = PublishedStates()
        published.record(orchestrator)
        await gate.open()
        await start.value
        await stop.value

        await assertDNSStopped(orchestrator, port: port)
        XCTAssertFalse(orchestrator.dnsLifecycle.admitsRunning)
        XCTAssertFalse(published.dns.contains(.running), "the superseded start publishes nothing: \(published.dns)")
        XCTAssertEqual(published.dns.last, .stopped)
    }

    /// The restart used to await the stop, then call the public start, which bound again after a stop admitted during it.
    func testDNSConfigRestartSupersededByAStopDuringItsRebindStaysStopped() async throws {
        let port = try await freePort()
        let gate = BindGate(armed: false)
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        let startEpoch = orchestrator.dnsLifecycle.epoch

        await gate.arm()
        var edited = orchestrator.config
        edited.dohProviders = ["9.9.9.9"]
        let apply = Task { await orchestrator.applyConfigChange(edited) }
        let held = try await arrival(at: gate)
        XCTAssertEqual(held, port, "the rebind took the same UDP port, so the restart closed the running one first")
        XCTAssertEqual(orchestrator.dnsLifecycle.epoch, startEpoch, "a restart takes no epoch of its own")
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == startEpoch + 1 }
        let published = PublishedStates()
        published.record(orchestrator)
        await gate.open()
        await apply.value
        await stop.value

        await assertDNSStopped(orchestrator, port: port)
        XCTAssertFalse(published.dns.contains(.running), "the superseded restart publishes nothing: \(published.dns)")
        XCTAssertEqual(published.dns.last, .stopped)
        let restarts = orchestrator.eventLog.events.filter { $0.event == "config.dns_restart" }.map(\.detail)
        XCTAssertEqual(restarts, ["reason=dns_section", "reason=dns_section outcome=superseded"])
    }

    /// A stop skipped because a newer start superseded it before its teardown leaves the stale bind to that start, which closes it before
    /// binding its own. Both bind the one configured port, and neither UDP nor TCP admits a second socket on it, so the newer start holds
    /// the full pair only if it closed the stale one.
    func testANewerStartClosesTheBindOfTheStartItSuperseded() async throws {
        let port = try await freePort()
        let gate = BindGate()
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }

        let first = Task { await orchestrator.startDNS() }
        let held = try await arrival(at: gate)
        XCTAssertEqual(held, port, "the stale start bound its UDP socket on the configured port")
        let epoch = orchestrator.dnsLifecycle.epoch
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 1 }
        let second = Task { await orchestrator.startDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 2 }
        await gate.open()
        await first.value
        await stop.value
        await second.value

        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port, "a configured TCP bind that fails leaves UDP only")
        XCTAssertEqual(orchestrator.snapshot.bindings.dnsPort, port)

        await orchestrator.stopDNS()
        await assertDNSStopped(orchestrator, port: port)
    }

    /// A start while running, with no stop since, never reaches a bind: the armed gate stays empty and the listeners keep their port. The
    /// config restart still rebinds, on the edited port.
    func testADNSStartWhileRunningIsANoOpAndARestartStillBindsTheEditedPort() async throws {
        let port = try await freePort()
        let gate = BindGate(armed: false)
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        let epoch = orchestrator.dnsLifecycle.epoch

        await gate.arm()
        await orchestrator.startDNS()
        let held = await gate.heldPort
        XCTAssertNil(held, "a start while running must not bind again")
        XCTAssertEqual(orchestrator.dnsLifecycle.epoch, epoch, "a start while running admits nothing")
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)

        await gate.open()
        let editedPort = try await freePort(excluding: [port])
        var edited = orchestrator.config
        edited.dnsForwarderPort = editedPort
        await orchestrator.applyConfigChange(edited)
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, editedPort, "the restart binds the edited settings")
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, editedPort)
        XCTAssertEqual(orchestrator.snapshot.bindings.dnsPort, editedPort)
        await assertReleased(udp: port)
        await assertReleased(tcp: port)
    }

    func testAConfigEditLeavesStoppedDNSStopped() async throws {
        let port = try await freePort()
        let orchestrator = makeDNSOrchestrator(gate: BindGate(armed: false), port: port)
        addTeardownBlock { await orchestrator.stopDNS() }
        var edited = orchestrator.config
        edited.dohProviders = ["9.9.9.9"]
        await orchestrator.applyConfigChange(edited)
        XCTAssertNotEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertNil(orchestrator.dnsForwarder.listeningPort, "an edit must not cold-start a forwarder that never started")

        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        await orchestrator.stopDNS()
        edited.dohProviders = ["1.1.1.1"]
        await orchestrator.applyConfigChange(edited)
        await assertDNSStopped(orchestrator, port: port)
    }

    /// A stop admitted while its teardown waits behind a held effect leaves the snapshot `running`. A DNS edit then must not restart: the
    /// restart would run under the stop's epoch, after its teardown, and bind the edited port with nothing left to close it.
    func testADNSEditDuringAStopsHeldTeardownNeitherRestartsNorBinds() async throws {
        let port = try await freePort()
        let editedPort = try await freePort(excluding: [port])
        let orchestrator = makeDNSOrchestrator(gate: BindGate(armed: false), port: port)
        let slot = BindGate()
        addTeardownBlock {
            await slot.open()
            await orchestrator.stopDNS()
        }
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        let held = try await holdSlot(orchestrator.dnsLifecycle, gate: slot)

        let epoch = orchestrator.dnsLifecycle.epoch
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 1 }
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "the stop's teardown has not run")
        let published = PublishedStates()
        published.record(orchestrator)
        var edited = orchestrator.config
        edited.dnsForwarderPort = editedPort
        let apply = await applyWhileHeld(edited, to: orchestrator)
        XCTAssertEqual(published.dns, [], "the edit changes no run state while the stop is in flight")
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, port, "the edit closed nothing")
        await slot.open()
        _ = try await held.value
        await apply.value
        await stop.value

        await assertDNSStopped(orchestrator, port: port)
        await assertReleased(udp: editedPort)
        await assertReleased(tcp: editedPort)
        XCTAssertEqual(published.dns, [.stopped], "only the stop publishes; nothing binds after it")
        let restarts = orchestrator.eventLog.events.filter { $0.event == "config.dns_restart" }.map(\.detail)
        XCTAssertEqual(restarts, [], "the edit decided no restart")
    }

    /// A restart takes the epoch of the start it found running. A stop and then a newer start admitted during its rebind supersede it: its
    /// partial bind publishes nothing, and the newer start closes that bind and holds the full edited pair itself.
    func testADNSRestartSupersededDuringItsRebindByAStopAndANewerStartLeavesTheNewerStartRunning() async throws {
        let port = try await freePort()
        let editedPort = try await freePort(excluding: [port])
        let gate = BindGate(armed: false)
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        let epoch = orchestrator.dnsLifecycle.epoch

        await gate.arm()
        var edited = orchestrator.config
        edited.dnsForwarderPort = editedPort
        let apply = Task { await orchestrator.applyConfigChange(edited) }
        let held = try await arrival(at: gate)
        XCTAssertEqual(held, editedPort, "the restart's rebind bound its UDP socket on the edited port")
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 1 }
        let start = Task { await orchestrator.startDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 2 }
        let published = PublishedStates()
        published.record(orchestrator)
        await gate.open()
        await apply.value
        await stop.value
        await start.value

        XCTAssertEqual(published.dns, [.running], "only the newer start publishes")
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(orchestrator.dnsForwarder.listeningPort, editedPort)
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, editedPort, "the newer start closed the restart's partial bind first")
        XCTAssertEqual(orchestrator.snapshot.bindings.dnsPort, editedPort)
        let restarts = orchestrator.eventLog.events.filter { $0.event == "config.dns_restart" }.map(\.detail)
        XCTAssertEqual(restarts, ["reason=dns_section", "reason=dns_section outcome=superseded"])
        await assertReleased(udp: port)
        await assertReleased(tcp: port)

        await orchestrator.stopDNS()
        await assertDNSStopped(orchestrator, port: editedPort)
    }

    /// A second start while the first is inside its bind joins that start's completion, the forwarder and what it publishes together. It
    /// admits nothing, and returns only once the first published `running`, rather than reading the first's `starting` as done.
    func testADNSStartBesideABindInFlightReturnsWithThatBindsCompletion() async throws {
        let port = try await freePort()
        let gate = BindGate()
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }
        let first = Task { await orchestrator.startDNS() }
        _ = try await arrival(at: gate)
        let epoch = orchestrator.dnsLifecycle.epoch
        let trace = Trace()
        let second = Task {
            await orchestrator.startDNS()
            trace.steps.append("joined \(orchestrator.snapshot.dnsRunState.rawValue)")
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(trace.steps, [], "the joiner waits for the bind in flight")
        XCTAssertEqual(orchestrator.dnsLifecycle.epoch, epoch, "and admits nothing")
        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(trace.steps, ["joined running"])
        XCTAssertEqual(orchestrator.dnsForwarder.tcpListeningPort, port)
        XCTAssertEqual(orchestrator.snapshot.bindings.dnsPort, port)
    }

    /// A stop admitted while a joiner waits on the start in flight still wins: it supersedes that start, and the joiner returns to the stop's
    /// outcome having admitted and bound nothing of its own.
    func testAStopDuringAJoinedDNSStartStillWins() async throws {
        let port = try await freePort()
        let gate = BindGate()
        let orchestrator = makeDNSOrchestrator(gate: gate, port: port)
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopDNS()
        }
        let first = Task { await orchestrator.startDNS() }
        _ = try await arrival(at: gate)
        let epoch = orchestrator.dnsLifecycle.epoch
        let second = Task { await orchestrator.startDNS() }
        for _ in 0..<100 { await Task.yield() }
        let stop = Task { await orchestrator.stopDNS() }
        await waitUntil { orchestrator.dnsLifecycle.epoch == epoch + 1 }
        await gate.open()
        await first.value
        await second.value
        await stop.value

        XCTAssertEqual(orchestrator.dnsLifecycle.epoch, epoch + 1, "the joiner admitted nothing")
        await assertDNSStopped(orchestrator, port: port)
    }

    // MARK: - Tunnels

    /// A second tunnel start while the first is queued behind a held effect joins it: it admits nothing and returns with the first's
    /// published `running`.
    func testATunnelStartBesideAStartInFlightReturnsWithItsCompletion() async throws {
        let port = try await freePort()
        let orchestrator = makeTunnelOrchestrator(ports: [port])
        let gate = BindGate()
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopTunnels()
        }
        let held = try await holdSlot(orchestrator.tunnelLifecycle, gate: gate)
        let epoch = orchestrator.tunnelLifecycle.epoch
        let first = Task { await orchestrator.startTunnels() }
        await waitUntil { orchestrator.tunnelLifecycle.epoch == epoch + 1 }
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .starting)
        let trace = Trace()
        let second = Task {
            await orchestrator.startTunnels()
            trace.steps.append("joined \(orchestrator.snapshot.tunnelsRunState.rawValue)")
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(trace.steps, [], "the joiner waits for the start in flight")
        await gate.open()
        _ = try await held.value
        await first.value
        await second.value

        XCTAssertEqual(trace.steps, ["joined running"])
        XCTAssertEqual(orchestrator.tunnelLifecycle.epoch, epoch + 1, "the joiner admitted nothing")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.map(\.localPort), [port])
    }

    /// The point tested is before the claim, not inside the bind: a start queued behind a held effect, then superseded by a stop, binds
    /// nothing and publishes nothing. (The real partial-bind case is the DNS tests' `willBindTCP` hold.) The old start never waited for
    /// anything, so it bound and published `running` around a stop admitted meanwhile.
    func testATunnelStartQueuedBehindAHeldEffectAndSupersededByAStopBindsNothing() async throws {
        let port = try await freePort()
        let orchestrator = makeTunnelOrchestrator(ports: [port])
        let gate = BindGate()
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopTunnels()
        }
        let held = try await holdSlot(orchestrator.tunnelLifecycle, gate: gate)

        let epoch = orchestrator.tunnelLifecycle.epoch
        let start = Task { await orchestrator.startTunnels() }
        // The start admits its epoch and queues behind the held effect in one turn.
        await waitUntil { orchestrator.tunnelLifecycle.epoch == epoch + 1 }
        let stop = Task { await orchestrator.stopTunnels() }
        await waitUntil { orchestrator.tunnelLifecycle.epoch == epoch + 2 }
        let published = PublishedStates()
        published.record(orchestrator)
        await gate.open()
        _ = try await held.value
        await start.value
        await stop.value

        XCTAssertFalse(published.tunnels.contains(.running), "the superseded start publishes nothing: \(published.tunnels)")
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .stopped)
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 0)
        XCTAssertTrue(orchestrator.snapshot.bindings.tunnels.isEmpty)
        await assertReleased(tcp: port)
    }

    /// Before the claim, as above: a reconcile queued behind a held effect, then superseded by a stop, binds no added tunnel, and the stop
    /// closes the running one.
    func testATunnelReconcileQueuedBehindAHeldEffectAndSupersededByAStopBindsNothing() async throws {
        let kept = try await freePort()
        let added = try await freePort(excluding: [kept])
        let orchestrator = makeTunnelOrchestrator(ports: [kept])
        let gate = BindGate()
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopTunnels()
        }
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)
        let held = try await holdSlot(orchestrator.tunnelLifecycle, gate: gate)

        var edited = orchestrator.config
        edited.tunnels.definitions.append(Self.tunnel(port: added))
        orchestrator.config = edited
        // The reconcile takes no epoch, so it marks its entry; it runs from there to its wait behind the held effect without a suspension.
        let trace = Trace()
        let reconcile = Task {
            trace.steps.append("reconcile")
            await orchestrator.reconcileTunnels()
        }
        await waitUntil { trace.steps == ["reconcile"] }
        let epoch = orchestrator.tunnelLifecycle.epoch
        let stop = Task { await orchestrator.stopTunnels() }
        await waitUntil { orchestrator.tunnelLifecycle.epoch == epoch + 1 }
        await gate.open()
        _ = try await held.value
        await reconcile.value
        await stop.value

        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .stopped)
        XCTAssertTrue(orchestrator.snapshot.bindings.tunnels.isEmpty)
        await assertReleased(tcp: kept)
        await assertReleased(tcp: added)
    }

    /// The pool is shared with the transparent proxy, so a first tunnel start leaves its connections alone; only an explicit stop, or a
    /// start whose every bind failed, closes them. A start while running, with no stop since, is a no-op: the same listener, the same
    /// session and its count, the same pooled connection. A start after a stop runs.
    func testATunnelStartLeavesTheSharedPoolAloneAndARepeatedStartKeepsListenerAndSessions() async throws {
        // Loopback only: the fake upstream is both the pooled connection's proxy and the tunnel's remote.
        let upstream = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await upstream.close().get() }
        let upstreamPort = try XCTUnwrap(upstream.localAddress?.port)
        let port = try await freePort(excluding: [upstreamPort])
        let orchestrator = makeTunnelOrchestrator(
            ports: [],
            upstreams: [UpstreamProxy(name: "Shared", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        )
        orchestrator.config.tunnels.definitions = [
            TunnelDefinition(localPort: port, remoteHost: "127.0.0.1", remotePort: upstreamPort, proxied: false, label: "Loop")
        ]
        addTeardownBlock { await orchestrator.stopTunnels() }
        // A connection someone else holds in the shared pool, as the transparent proxy's would be.
        let (pooled, _) = try await orchestrator.tunnelConnectionPool.makeDedicatedTunnelConnection().get()

        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running)
        XCTAssertEqual(orchestrator.tunnelConnectionPool.allConnectionSnapshot.map(\.id), [pooled.id], "a first start flushes no pool")
        XCTAssertTrue(pooled.channel.isActive)
        let listener = try XCTUnwrap(orchestrator.tunnelForwarder.listenersByID.values.first)
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
        addTeardownBlock { try await client.close().get() }
        let tracker = orchestrator.tunnelForwarder.sessionTracker
        try await eventually { tracker.totalActiveSessions == 1 }
        let epoch = orchestrator.tunnelLifecycle.epoch

        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.tunnelLifecycle.epoch, epoch, "a start while running admits nothing")
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running)
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.map(\.localPort), [port])
        let listeners = orchestrator.tunnelForwarder.listenersByID.values.map(ObjectIdentifier.init)
        XCTAssertEqual(listeners, [ObjectIdentifier(listener)], "the running listener is kept, not rebound")
        XCTAssertTrue(listener.isActive)
        XCTAssertEqual(tracker.totalActiveSessions, 1, "the live session keeps its count")
        XCTAssertTrue(client.isActive)
        XCTAssertEqual(orchestrator.tunnelConnectionPool.allConnectionSnapshot.map(\.id), [pooled.id], "a repeated start flushes no pool")
        XCTAssertTrue(pooled.channel.isActive)

        // The accepted session outlives the listener by design and still holds a connected socket on `port`, so a plain bind probe would
        // meet it; the listener itself is what the stop must close.
        await orchestrator.stopTunnels()
        try await listener.closeFuture.get()
        XCTAssertTrue(orchestrator.tunnelForwarder.listenersByID.isEmpty)
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running, "a start after a stop runs")
        XCTAssertEqual(orchestrator.tunnelLifecycle.epoch, epoch + 2)
    }

    func testAConfigEditLeavesStoppedTunnelsStopped() async throws {
        let port = try await freePort()
        let added = try await freePort(excluding: [port])
        let orchestrator = makeTunnelOrchestrator(ports: [port])
        addTeardownBlock { await orchestrator.stopTunnels() }
        await orchestrator.startTunnels()
        await orchestrator.stopTunnels()

        var edited = orchestrator.config
        edited.tunnels.definitions.append(Self.tunnel(port: added))
        await orchestrator.applyConfigChange(edited)
        await orchestrator.reconcileTunnels()

        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .stopped)
        XCTAssertTrue(orchestrator.snapshot.bindings.tunnels.isEmpty)
        await assertReleased(tcp: port)
        await assertReleased(tcp: added)
    }

    /// As for DNS: a tunnel edit while a stop's teardown waits behind a held effect, with the snapshot still `running`, decides no
    /// reconcile. The reconcile's own `admitsRunning` check would still bind nothing, so the decision event is what tells them apart.
    func testATunnelEditDuringAStopsHeldTeardownNeitherReconcilesNorBinds() async throws {
        let kept = try await freePort()
        let added = try await freePort(excluding: [kept])
        let orchestrator = makeTunnelOrchestrator(ports: [kept])
        let gate = BindGate()
        addTeardownBlock {
            await gate.open()
            await orchestrator.stopTunnels()
        }
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running)
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)
        let held = try await holdSlot(orchestrator.tunnelLifecycle, gate: gate)

        let epoch = orchestrator.tunnelLifecycle.epoch
        let stop = Task { await orchestrator.stopTunnels() }
        await waitUntil { orchestrator.tunnelLifecycle.epoch == epoch + 1 }
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running, "the stop's teardown has not run")
        let published = PublishedStates()
        published.record(orchestrator)
        var edited = orchestrator.config
        edited.tunnels.definitions.append(Self.tunnel(port: added))
        let apply = await applyWhileHeld(edited, to: orchestrator)
        XCTAssertEqual(published.tunnels, [], "the edit changes no run state while the stop is in flight")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.map(\.localPort), [kept], "the edit bound nothing")
        await gate.open()
        _ = try await held.value
        await apply.value
        await stop.value

        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .stopped)
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 0)
        XCTAssertTrue(orchestrator.snapshot.bindings.tunnels.isEmpty)
        XCTAssertEqual(published.tunnels, [.stopped], "only the stop publishes; nothing binds after it")
        let reconciles = orchestrator.eventLog.events.filter { $0.event.hasPrefix("config.tunnels_reconcile") }.map(\.event)
        XCTAssertEqual(reconciles, [], "the edit decided no reconcile")
        await assertReleased(tcp: kept)
        await assertReleased(tcp: added)
    }
}

/// Three direct histories of the helper alone, not an exploration of its interleavings: the order its effects run in, and which run at all.
@MainActor
final class PhysicalLifecycleTests: XCTestCase {
    func testAnEffectSupersededBeforeItsClaimRunsNothing() async throws {
        let lifecycle = PhysicalLifecycle()
        let trace = Trace()
        let start = lifecycle.admit(running: true)
        _ = lifecycle.admit(running: false)

        let ran = try await lifecycle.run(epoch: start) { trace.steps.append("bind") }

        XCTAssertFalse(ran)
        XCTAssertEqual(trace.steps, [])
        XCTAssertFalse(lifecycle.admitsRunning)
    }

    /// A claimed bind runs to its end even once superseded; the teardown admitted meanwhile runs after it, never beside it, and an operation
    /// superseded while it waited runs nothing.
    func testAClaimedEffectRunsToItsEndBeforeTheNextAndAStaleWaiterRunsNothing() async throws {
        let lifecycle = PhysicalLifecycle()
        let gate = BindGate()
        let trace = Trace()

        let start = lifecycle.admit(running: true)
        let bind = Task {
            try await lifecycle.run(epoch: start) {
                trace.steps.append("bind.begin")
                await gate.hold(0)
                trace.steps.append("bind.end")
            }
        }
        addTeardownBlock { await gate.open() }
        _ = try await arrival(at: gate)
        let stop = lifecycle.admit(running: false)
        let teardown = Task { try await lifecycle.run(epoch: stop) { trace.steps.append("teardown") } }
        let restart = lifecycle.admit(running: true)
        let rebind = Task { try await lifecycle.run(epoch: restart) { trace.steps.append("rebind") } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(trace.steps, ["bind.begin"], "nothing runs beside a claimed effect")

        await gate.open()
        let bindRan = try await bind.value
        let teardownRan = try await teardown.value
        let rebindRan = try await rebind.value

        XCTAssertTrue(bindRan)
        XCTAssertFalse(teardownRan, "the stop was superseded while it waited")
        XCTAssertTrue(rebindRan)
        XCTAssertEqual(trace.steps, ["bind.begin", "bind.end", "rebind"])
        XCTAssertTrue(lifecycle.admitsRunning)
    }

    func testABodyFailureReachesTheCallerAndFreesTheSlot() async throws {
        struct BindFailed: Error {}
        let lifecycle = PhysicalLifecycle()
        let trace = Trace()
        let start = lifecycle.admit(running: true)
        do {
            try await lifecycle.run(epoch: start) { throw BindFailed() }
            XCTFail("the body's error must reach the caller")
        } catch is BindFailed {}

        let stop = lifecycle.admit(running: false)
        let ran = try await lifecycle.run(epoch: stop) { trace.steps.append("teardown") }
        XCTAssertTrue(ran)
        XCTAssertEqual(trace.steps, ["teardown"])
    }

    /// The one joinable start: a stop leaves none, a start admitted after it is the joinable one, and the older start's completion never
    /// clears it. A start clears only its own, and a joiner gets the start's own error.
    func testOnlyTheLatestStartIsJoinableAndAnOlderCompletionNeverClearsIt() async throws {
        struct BindFailed: Error {}
        let lifecycle = PhysicalLifecycle()
        let olderGate = BindGate()
        let newerGate = BindGate()
        addTeardownBlock {
            await olderGate.open()
            await newerGate.open()
        }
        let older = lifecycle.admit(running: true)
        let first = Task { try await lifecycle.runStart(epoch: older) { await olderGate.hold(1) } }
        _ = try await arrival(at: olderGate)
        XCTAssertNotNil(lifecycle.joinableStart(), "a start is joinable from its admission")
        _ = lifecycle.admit(running: false)
        XCTAssertNil(lifecycle.joinableStart(), "after a stop there is nothing to join")

        let newer = lifecycle.admit(running: true)
        let second = Task {
            try await lifecycle.runStart(epoch: newer) {
                await newerGate.hold(2)
                throw BindFailed()
            }
        }
        _ = try await arrival(at: newerGate)
        let joinable = try XCTUnwrap(lifecycle.joinableStart())
        await olderGate.open()
        try await first.value
        XCTAssertEqual(lifecycle.joinableStart(), joinable, "the older completion left the newer one in place")

        await newerGate.open()
        do {
            try await joinable.value
            XCTFail("a joiner gets the start's own failure")
        } catch is BindFailed {}
        do {
            try await second.value
            XCTFail("the start's caller gets it too")
        } catch is BindFailed {}
        XCTAssertNil(lifecycle.joinableStart(), "a finished start clears its own")
    }
}
