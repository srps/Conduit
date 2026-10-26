// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// Covers `LocalProxyServer`'s accept-socket lifecycle on a *fixed* port.
///
/// Every pre-existing test that starts a `LocalProxyServer` sets
/// `config.localPort = 0` and lets the OS pick an ephemeral port. That choice
/// is what hid the recycle bug for the life of the feature: with port 0 each
/// bind lands somewhere new, so `recycleListener()` "succeeded" without ever
/// rebinding the address it is supposed to preserve. Production always runs a
/// fixed port. These tests pin one.
final class ListenerRecycleTests: XCTestCase {

    // MARK: - Harness

    /// Server plus the box that lets a test move the configured port after the
    /// OS has assigned one, so the recycle path binds a *known* address.
    private struct Harness {
        let server: LocalProxyServer
        let portBox: NIOLockedValueBox<Int>
    }

    /// `bindRetryLimit: 1` for the conflict tests — production retries a
    /// contended bind for ten seconds to ride out an instance handoff, which is
    /// pure wall-clock in a test that means the conflict to be permanent.
    private func makeHarness(bindRetryLimit: Int = 10) -> Harness {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 0

        let portBox = NIOLockedValueBox(0)
        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: {
                var c = config
                c.localPort = portBox.withLockedValue { $0 }
                return c
            },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in RecycleNoOpAuthenticator() },
            directConnectDetector: DirectConnectDetector(
                group: MultiThreadedEventLoopGroup.singleton,
                logger: DiscardingLogSink()
            ),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            bindRetryLimit: bindRetryLimit
        )
        return Harness(server: server, portBox: portBox)
    }

    /// Configures a concrete free port *before* starting, the way production
    /// runs: `localPort` is a fixed number from the outset, so every subsequent
    /// bind must reclaim that exact address.
    ///
    /// Pinning the port after the start instead would be a genuine config
    /// change — "any port" becoming "this port" — which recycling is right to
    /// act on, and which would mask what these tests are checking.
    private func startOnPinnedPort(_ harness: Harness) async throws -> Int {
        let port = try await reserveFreePort()
        harness.portBox.withLockedValue { $0 = port }
        try await harness.server.start()
        XCTAssertEqual(harness.server.listeningPort, port, "server should take the configured port")
        return port
    }

    /// Binds an OS-assigned port and releases it, so the caller has a port
    /// number that was free a moment ago.
    private func reserveFreePort() async throws -> Int {
        let scout = try await squat(on: 0)
        let port = try XCTUnwrap(scout.localAddress?.port)
        _ = try? await scout.close().get()
        return port
    }

    private func canConnect(to port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    // MARK: - The incident

    /// The regression behind the field failure: on Darwin `SO_REUSEADDR` does
    /// not permit a second bind over a socket that is already `LISTEN`ing, so
    /// the old bind-new-before-close-old ordering could never succeed. It spent
    /// the full retry budget on `EADDRINUSE` against *its own* listener and
    /// then threw a raw NIO `IOError` — which is what reached the user.
    func testRecycleOnAFixedPortSucceedsAndKeepsServing() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        addTeardownBlock { await harness.server.stop() }

        try await harness.server.recycleListener()

        XCTAssertEqual(harness.server.listeningPort, port, "recycle must preserve the configured port")
        XCTAssertTrue(canConnect(to: port), "listener must still accept connections after a recycle")
    }

    /// A healthy accept socket must never be dropped and re-created. Releasing
    /// a working listener opens a window for any other process to take the
    /// port — in the field a corporate proxy agent won exactly that race and
    /// the proxy could never bind again. Recycling cannot fix an upstream
    /// health failure anyway, so the healthy case is a no-op.
    func testRecycleDoesNotRebindAHealthyListener() async throws {
        let harness = makeHarness()
        _ = try await startOnPinnedPort(harness)
        addTeardownBlock { await harness.server.stop() }

        let generationBefore = harness.server.listenerGeneration
        try await harness.server.recycleListener()

        XCTAssertEqual(
            harness.server.listenerGeneration,
            generationBefore,
            "a healthy listener must not be rebound — the port is never voluntarily released"
        )
    }

    /// The case recycling exists for: the accept socket died without a
    /// `stop()`. Here the rebind must actually happen.
    func testRecycleRebindsAfterTheAcceptSocketDies() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        addTeardownBlock { await harness.server.stop() }

        let generationBefore = harness.server.listenerGeneration
        await harness.server.simulateListenerLossForTesting()
        XCTAssertFalse(canConnect(to: port), "precondition: the accept socket is gone")

        try await harness.server.recycleListener()

        XCTAssertGreaterThan(
            harness.server.listenerGeneration,
            generationBefore,
            "a dead listener must be rebound"
        )
        XCTAssertEqual(harness.server.listeningPort, port)
        XCTAssertTrue(canConnect(to: port), "listener must serve again after repair")
    }

    /// A healthy listener bound to the *wrong* address is the other case a
    /// recycle must repair: the config moved the listener and the socket has to
    /// follow it, even though the old socket is perfectly alive.
    func testRecycleRebindsWhenTheConfiguredPortMoved() async throws {
        let harness = makeHarness()
        let firstPort = try await startOnPinnedPort(harness)
        addTeardownBlock { await harness.server.stop() }

        // Point the config at a different port, as a settings edit would.
        let secondPort = try await reserveFreePort()
        harness.portBox.withLockedValue { $0 = secondPort }

        let generationBefore = harness.server.listenerGeneration
        try await harness.server.recycleListener()

        XCTAssertGreaterThan(harness.server.listenerGeneration, generationBefore)
        XCTAssertEqual(harness.server.listeningPort, secondPort, "the listener must follow the config")
        XCTAssertFalse(canConnect(to: firstPort), "the old address must be released")
        XCTAssertTrue(canConnect(to: secondPort))
    }

    /// An OS-assigned port must still count as "where the config wants it".
    ///
    /// The healthy-listener no-op originally compared the *bound* address with
    /// the raw config, so `localPort = 0` — which the channel reports as the
    /// concrete port it got — never compared equal. That made the no-op
    /// unreachable for every port-0 configuration (`pm-proxy --port 0`, the
    /// documented isolated-runtime invocation), so recovery dropped a healthy
    /// socket and came back on a *different* port than clients were told.
    /// Caught in review on #54.
    func testRecycleLeavesAHealthyListenerAloneOnAnOSAssignedPort() async throws {
        let harness = makeHarness()
        // Note: no `startOnPinnedPort` — the config stays at port 0 throughout.
        try await harness.server.start()
        addTeardownBlock { await harness.server.stop() }
        let port = try XCTUnwrap(harness.server.listeningPort)

        let generationBefore = harness.server.listenerGeneration
        try await harness.server.recycleListener()

        XCTAssertEqual(
            harness.server.listenerGeneration,
            generationBefore,
            "an OS-assigned port is still the configured address; the listener must not be rebound"
        )
        XCTAssertEqual(harness.server.listeningPort, port, "the port clients were told must not move")
    }

    /// Same defect through the host half of the comparison: config validation
    /// accepts a hostname, but the channel reports the resolved literal, so
    /// `localhost` could never compare equal to `127.0.0.1` and every recovery
    /// cycle released a working port. Caught in review on #54.
    func testRecycleLeavesAHealthyListenerAloneWhenTheHostIsAName() async throws {
        var config = ProxyConfig.testFixture()
        config.localHost = "localhost"
        config.localPort = 0

        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in RecycleNoOpAuthenticator() },
            directConnectDetector: DirectConnectDetector(
                group: MultiThreadedEventLoopGroup.singleton,
                logger: DiscardingLogSink()
            ),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        let generationBefore = server.listenerGeneration
        try await server.recycleListener()

        XCTAssertEqual(
            server.listenerGeneration,
            generationBefore,
            "a host that resolves to the bound address is still the configured address"
        )
    }

    /// A recovery step that decides to do nothing still has to say so on the
    /// event stream — otherwise UI, pmctl and pm-sim cannot tell it apart from
    /// a step that ran and silently failed. AGENTS.md: "Always emit a
    /// RuntimeEvent first". Caught in review on #54.
    func testSkippedRecycleIsVisibleOnTheEventStream() async throws {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 0

        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in RecycleNoOpAuthenticator() },
            directConnectDetector: DirectConnectDetector(
                group: MultiThreadedEventLoopGroup.singleton,
                logger: DiscardingLogSink()
            ),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        try await server.recycleListener()

        let recorded = events.withLockedValue { $0 }
        XCTAssertTrue(
            recorded.contains { $0.event == "proxy.listener_recycle_skipped" },
            "the skip must be on the event stream, not only in a debug log: \(recorded.map(\.event))"
        )
    }

    /// A recycle whose rebind fails must leave honest state behind: no stale
    /// reference to a closed channel, so a later `start()` repairs rather than
    /// short-circuiting on an "already active" check.
    func testFailedRebindLeavesNoStaleListenerReference() async throws {
        let harness = makeHarness(bindRetryLimit: 1)
        let port = try await startOnPinnedPort(harness)
        addTeardownBlock { await harness.server.stop() }

        await harness.server.simulateListenerLossForTesting()

        // Steal the port while the server has no listener, so the rebind fails.
        let squatter = try await squat(on: port)
        addTeardownBlock { _ = try? await squatter.close().get() }

        do {
            try await harness.server.recycleListener()
            XCTFail("rebind should fail while the port is held by another socket")
        } catch let error as ListenerBindError {
            XCTAssertEqual(error, .addressInUse(listener: "Local proxy", host: "127.0.0.1", port: port, holder: nil))
        }

        XCTAssertNil(harness.server.listeningPort, "a failed rebind must not leave a closed channel installed")
    }

    // MARK: - Port conflict reporting

    /// A port conflict must arrive as an actionable, typed error. Previously it
    /// surfaced as `IOError { errnoCode: 48, reason: bind(descriptor:ptr:bytes:) }`,
    /// because `Error.displayDescription` forwards `IOError.description` verbatim.
    func testStartOnAnOccupiedPortReportsAnActionableConflict() async throws {
        let harness = makeHarness(bindRetryLimit: 1)

        // Take a real port, then point the server at it.
        let probe = try await squat(on: 0)
        let port = try XCTUnwrap(probe.localAddress?.port)
        harness.portBox.withLockedValue { $0 = port }
        addTeardownBlock { _ = try? await probe.close().get() }

        do {
            try await harness.server.start()
            XCTFail("start should fail when the configured port is occupied")
        } catch let error as ListenerBindError {
            XCTAssertEqual(error, .addressInUse(listener: "Local proxy", host: "127.0.0.1", port: port, holder: nil))

            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("\(port)"), "message must name the port: \(message)")
            XCTAssertTrue(message.contains("lsof"), "message must tell the user how to find the holder: \(message)")
            XCTAssertFalse(message.contains("errnoCode"), "raw NIO wording must not reach the user: \(message)")
        }
    }

    // MARK: - Lifecycle across a stop

    /// The health ladder began under the listener it was checking. A stop lands while its first step is held, so the ladder resumes with no
    /// pool behind it, and its recycle step would cold-start the listener. The ladder must end instead: nothing binds, and it reports no recovery.
    func testAStopDuringTheHealthLadderLeavesNoListenerAndEndsTheLadder() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        let service = HeldLadderService(server: harness.server, holding: .closeStalledConnections)
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink())

        let ladder = Task { await recovery.recover(trigger: .unreachable(detail: "gated")) }
        for _ in 0..<5_000 where !service.isEntered {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(service.isEntered, "the ladder is held inside its first step")

        await harness.server.stop()
        service.release()
        let recovered = await ladder.value
        withExtendedLifetime(service) {}

        XCTAssertFalse(recovered, "a ladder the stop overtook reports no recovery")
        XCTAssertEqual(service.refusedSteps, [.closeStalledConnections], "the held step was refused at the server")
        XCTAssertNil(harness.server.listeningPort, "the ladder's recycle must not re-listen after the stop")
        XCTAssertFalse(canConnect(to: port), "nothing answers on the configured port")
    }

    /// The ladder's own cold-start fallback moves the lifecycle it began under, and must not refuse itself: the stamp the fallback publishes under
    /// carries forward. A server that never started has no pool, so its recycle takes the fallback.
    func testTheLaddersOwnColdStartFallbackIsNotRefusedByItsStamp() async throws {
        let harness = makeHarness()
        let port = try await reserveFreePort()
        harness.portBox.withLockedValue { $0 = port }
        addTeardownBlock { await harness.server.stop() }

        let service = HeldLadderService(server: harness.server, holding: nil)
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink())
        let recovered = await recovery.recover(trigger: .unreachable(detail: "gated"))
        withExtendedLifetime(service) {}

        XCTAssertFalse(recovered, "the health check still fails after the fallback, so the ladder is exhausted")
        XCTAssertEqual(harness.server.listeningPort, port, "the fallback bound the configured port under the ladder's own stamp")
    }

    /// A recycle admitted under a lifecycle a stop has since moved on binds nothing, and reports the cancellation.
    func testARecycleAdmittedBeforeAStopIsRefusedWithoutBinding() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        let admitted = harness.server.listenerStamp
        await harness.server.stop()

        do {
            try await harness.server.recycleListener(expecting: admitted)
            XCTFail("a recycle under a stopped lifecycle must be refused")
        } catch is CancellationError {
            // Expected: the stop moved the lifecycle on.
        }
        XCTAssertNil(harness.server.listeningPort, "a refused recycle leaves no listener")
        XCTAssertFalse(canConnect(to: port))
    }

    /// A ladder admitted under one lifecycle is held inside its upstream switch, after its own check passed and before the server acts. A
    /// stop and a newer start replace the server's pool meanwhile. Released, the step is refused at the server: the newer pool's upstream
    /// is not switched, and the newer listener keeps serving.
    func testALadderHeldAcrossAStopAndANewerStartNeverReachesTheNewerPool() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        let service = HeldLadderService(server: harness.server, holding: .switchUpstream)
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink())

        let ladder = Task { await recovery.recover(trigger: .unreachable(detail: "gated")) }
        for _ in 0..<5_000 where !service.isEntered {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(service.isEntered, "the ladder is held inside its upstream switch")

        await harness.server.stop()
        try await harness.server.start()
        let selected = harness.server.activeUpstream()
        service.release()
        let recovered = await ladder.value
        withExtendedLifetime(service) {}

        XCTAssertFalse(recovered, "a ladder a newer start overtook reports no recovery")
        XCTAssertEqual(service.refusedSteps, [.switchUpstream], "the held step was refused at the server")
        XCTAssertEqual(harness.server.activeUpstream(), selected, "the newer pool's upstream was not switched")
        XCTAssertEqual(harness.server.listeningPort, port, "the newer listener is untouched")
        XCTAssertTrue(canConnect(to: port))
        await harness.server.stop()
    }

    /// A step's stamp names one server. A stamp read from another server authorizes nothing here, even at the same epoch.
    func testAStampFromAnotherServerAuthorizesNothing() async throws {
        let harness = makeHarness()
        let port = try await startOnPinnedPort(harness)
        let other = makeHarness()
        _ = try await startOnPinnedPort(other)
        let foreign = other.server.listenerStamp
        await other.server.stop()
        let selected = harness.server.activeUpstream()

        for step in RecoveryStep.allCases {
            do {
                switch step {
                case .closeStalledConnections: _ = try await harness.server.closeStalledConnections(expecting: foreign)
                case .reauthenticate: try await harness.server.reauthenticate(expecting: foreign)
                case .switchUpstream: _ = try await harness.server.switchToNextUpstream(expecting: foreign)
                case .recycleListener: _ = try await harness.server.recycleListener(expecting: foreign)
                }
                XCTFail("\(step) ran under another server's stamp")
            } catch is CancellationError {
                // Expected: the stamp is not this server's.
            }
        }
        do {
            _ = try await harness.server.performHealthCheck(expecting: foreign)
            XCTFail("a health check ran under another server's stamp")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(harness.server.activeUpstream(), selected)
        XCTAssertEqual(harness.server.listeningPort, port)
        await harness.server.stop()
    }

    // MARK: - Helpers

    /// A recovery service that forwards every step to a real server, under the stamp the ladder passes. Its health check always fails, so
    /// the ladder keeps going, and one step can be held after the ladder's own check and before the server acts, so a test can move the
    /// server's lifecycle in exactly that window. It records the steps the server refused.
    private final class HeldLadderService: RecoverableProxyService, @unchecked Sendable {
        private let server: LocalProxyServer
        private let lock = NSLock()
        private var holding: RecoveryStep?
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var refused: [RecoveryStep] = []

        init(server: LocalProxyServer, holding step: RecoveryStep?) {
            self.server = server
            self.holding = step
        }

        var isEntered: Bool { lock.withLock { entered } }
        var refusedSteps: [RecoveryStep] { lock.withLock { refused } }

        func release() {
            let resumed = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                holding = nil
                defer { waiter = nil }
                return waiter
            }
            resumed?.resume()
        }

        var listenerStamp: ListenerStamp { server.listenerStamp }

        func closeStalledConnections(expecting stamp: ListenerStamp) async throws -> Int {
            try await forward(.closeStalledConnections) { try await self.server.closeStalledConnections(expecting: stamp) }
        }

        func reauthenticate(expecting stamp: ListenerStamp) async throws {
            try await forward(.reauthenticate) { try await self.server.reauthenticate(expecting: stamp) }
        }

        func switchToNextUpstream(expecting stamp: ListenerStamp) async throws -> String? {
            try await forward(.switchUpstream) { try await self.server.switchToNextUpstream(expecting: stamp) }
        }

        func performHealthCheck(expecting stamp: ListenerStamp) async throws -> HealthCheckResult {
            .unhealthy(.unreachable(detail: "gated"), responseTimeMS: 0)
        }

        func recycleListener(expecting stamp: ListenerStamp) async throws -> ListenerStamp {
            try await forward(.recycleListener) { try await self.server.recycleListener(expecting: stamp) }
        }

        private func forward<T>(_ step: RecoveryStep, _ body: () async throws -> T) async throws -> T {
            await hold(step)
            do {
                return try await body()
            } catch is CancellationError {
                lock.withLock { refused.append(step) }
                throw CancellationError()
            }
        }

        private func hold(_ step: RecoveryStep) async {
            await withCheckedContinuation { continuation in
                let proceed = lock.withLock { () -> Bool in
                    guard holding == step else { return true }
                    entered = true
                    waiter = continuation
                    return false
                }
                if proceed { continuation.resume() }
            }
        }
    }

    /// Binds and listens on `port` (0 for an OS-assigned one) so the server
    /// cannot have it.
    private func squat(on port: Int) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port)
            .get()
    }
}

// MARK: - Classification

final class ListenerBindErrorTests: XCTestCase {

    func testClassifiesErrnoOntoActionableCases() {
        let inUse = ListenerBindError.classify(
            IOError(errnoCode: EADDRINUSE, reason: "bind"),
            listener: "Local proxy", host: "127.0.0.1", port: 3128
        )
        XCTAssertEqual(inUse, .addressInUse(listener: "Local proxy", host: "127.0.0.1", port: 3128, holder: nil))

        let unavailable = ListenerBindError.classify(
            IOError(errnoCode: EADDRNOTAVAIL, reason: "bind"),
            listener: "Transparent proxy", host: "127.44.3.0", port: 10443
        )
        XCTAssertEqual(unavailable, .addressUnavailable(listener: "Transparent proxy", host: "127.44.3.0", port: 10443))
    }

    /// Retry policy is what the start path spends wall-clock on. Only the two
    /// classes that a wait can plausibly resolve are retriable; everything else
    /// fails fast instead of stalling the start for the whole budget.
    func testOnlyWaitableFailuresAreRetriable() {
        XCTAssertTrue(ListenerBindError.addressInUse(listener: "l", host: "h", port: 1, holder: nil).isRetriable)
        XCTAssertTrue(ListenerBindError.addressUnavailable(listener: "l", host: "h", port: 1).isRetriable)
        XCTAssertFalse(ListenerBindError.bindFailed(listener: "l", host: "h", port: 1, reason: "denied").isRetriable)

        let denied = ListenerBindError.classify(
            IOError(errnoCode: EACCES, reason: "bind"),
            listener: "Local proxy", host: "127.0.0.1", port: 80
        )
        XCTAssertFalse(denied.isRetriable, "a permissions failure must not be retried")
    }

    func testNonIOErrorKeepsItsOwnDescription() {
        struct Odd: Error, LocalizedError { var errorDescription: String? { "something odd" } }
        let classified = ListenerBindError.classify(Odd(), listener: "Local proxy", host: "127.0.0.1", port: 3128)
        XCTAssertEqual(classified, .bindFailed(listener: "Local proxy", host: "127.0.0.1", port: 3128, reason: "something odd"))
    }
}

// MARK: - Stubs

private final class RecycleNoOpAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "NoOp" }
    func initialToken(for host: String) throws -> String { "NoOp none" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}
