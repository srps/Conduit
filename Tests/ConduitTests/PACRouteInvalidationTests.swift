// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// `PACRoutingEngine.invalidateRoutes(reason:)` (#96): nothing computed
/// before the call is served after it, and a fetch running across it is
/// done again.
final class PACRouteInvalidationTests: XCTestCase {
    private static let offScript = #"function FindProxyForURL(url, host) { return "PROXY policy-detection.example:80"; }"#
    private static let onScript = #"function FindProxyForURL(url, host) { return "PROXY corp.example:8080"; }"#
    private static let off = PACRoute.proxy(host: "policy-detection.example", port: 80)
    private static let on = PACRoute.proxy(host: "corp.example", port: 8080)

    /// The scripts a PAC server hands out off and on the VPN. A fetch may be
    /// held on a gate, and may fail.
    private final class Server: @unchecked Sendable {
        private let state = NIOLockedValueBox((onVPN: false, failing: false, fetches: 0))
        let gate = DispatchSemaphore(value: 0)
        let holdNext = NIOLockedValueBox(false)

        var fetches: Int { state.withLockedValue { $0.fetches } }
        func setOnVPN(_ value: Bool) { state.withLockedValue { $0.onVPN = value } }
        func setFailing(_ value: Bool) { state.withLockedValue { $0.failing = value } }

        /// Reads the network when the fetch starts, as a real request would.
        func load() async throws -> String {
            let (onVPN, failing) = state.withLockedValue { state -> (Bool, Bool) in
                state.fetches += 1
                return (state.onVPN, state.failing)
            }
            if holdNext.withLockedValue({ held in defer { held = false }; return held }) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { self.gate.wait(); continuation.resume() }
                }
            }
            if failing { throw PACResolverError.fetchFailed("PAC host unreachable") }
            return onVPN ? PACRouteInvalidationTests.onScript : PACRouteInvalidationTests.offScript
        }
    }

    private func makeConfig(pacRoutingEnabled: Bool = true) -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://pac.example.com/proxy.pac"
        config.pacRoutingEnabled = pacRoutingEnabled
        return config
    }

    private func makeEngine(
        server: Server, events: RuntimeEventLog, config: ProxyConfig? = nil
    ) -> PACRoutingEngine {
        let fixed = config ?? makeConfig()
        return PACRoutingEngine(
            configProvider: { fixed },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in try await server.load() },
            eventSink: { events.append($0) }
        )
    }

    private func named(_ name: String, in events: RuntimeEventLog) -> [RuntimeEvent] {
        events.events.filter { $0.event == name }
    }

    func testACachedRouteFromBeforeTheInvalidationIsNotServed() async throws {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)
        try await engine.refresh(force: true)
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.off, "cached off the VPN")

        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .vpnConnected)

        XCTAssertEqual(engine.decision(for: "https://github.com/", host: "github.com"),
                       .noUsableAnswer(.notLoaded, rejected: []),
                       "neither the cached answer nor the off-VPN script routes while the refetch runs")
        // That request kicked the background refresh; this one may find it running.
        try await engine.refresh(force: true)
        for _ in 0..<100 where engine.route(for: "https://github.com/", host: "github.com") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
        XCTAssertEqual(server.fetches, 2)

        let invalidated = named("pac.routes_invalidated", in: events)
        XCTAssertEqual(invalidated.map(\.detail), ["reason=vpn_connected routes=1 script=dropped fetch=idle"])
        XCTAssertEqual(invalidated.first?.kind, .routing)
    }

    func testTheInvalidationIgnoresTheFailureBackoffOnlyWhenTheCallerDoes() async throws {
        let server = Server()
        server.setFailing(true)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)
        do {
            try await engine.refresh(force: true)
            XCTFail("expected the fetch to fail")
        } catch {}
        XCTAssertNotNil(engine.backoffRemaining())

        server.setFailing(false)
        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .vpnConnected)
        XCTAssertNotNil(engine.backoffRemaining(), "the invalidation alone leaves the backoff to the caller")
        try await engine.refresh(force: true)
        XCTAssertEqual(server.fetches, 2)
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
    }

    /// A fetch that started off the VPN and finishes after the invalidation
    /// installs nothing; the refresh fetches again on the new network.
    func testAFetchRunningAcrossTheInvalidationIsDoneAgain() async throws {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        server.holdNext.withLockedValue { $0 = true }
        let refresh = Task { try await engine.refresh(force: true) }
        for _ in 0..<100 where server.fetches == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.fetches, 1)

        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .vpnConnected)
        let transition = Task { try await engine.refresh(force: true) }  // joins the running one
        server.gate.signal()
        try await refresh.value
        try await transition.value

        XCTAssertEqual(server.fetches, 2, "the off-VPN script was discarded and the PAC fetched again")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
        XCTAssertEqual(named("pac.refreshed", in: events).count, 1, "only the on-VPN script was installed")
        XCTAssertEqual(named("pac.routes_invalidated", in: events).first?.detail,
                       "reason=vpn_connected routes=0 script=none fetch=restarted")
    }

    /// A fetch that failed on the old network is recorded, is not counted
    /// towards the backoff, and is retried on the new one.
    func testAFetchFailingAcrossTheInvalidationIsRetriedNotCounted() async throws {
        let server = Server()
        server.setFailing(true)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        server.holdNext.withLockedValue { $0 = true }
        let refresh = Task { try await engine.refresh(force: true) }
        for _ in 0..<100 where server.fetches == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        engine.invalidateRoutes(reason: .vpnConnected)
        server.setFailing(false)
        server.setOnVPN(true)
        server.gate.signal()
        try await refresh.value

        XCTAssertEqual(server.fetches, 2)
        XCTAssertNil(engine.backoffRemaining(), "the pre-transition failure does not start a backoff")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
        let failed = named("pac.refresh_failed", in: events)
        XCTAssertEqual(failed.count, 1)
        XCTAssertTrue(failed.first?.detail?.hasSuffix("superseded=refetching") ?? false,
                      "detail: \(failed.first?.detail ?? "nil")")
    }

    /// Starts a forced refresh whose fetch the server holds, and waits, bounded, until the fetch has started.
    private func heldRefresh(_ engine: PACRoutingEngine, server: Server) async throws -> Task<Void, any Error> {
        let before = server.fetches
        server.holdNext.withLockedValue { $0 = true }
        let refresh = Task { try await engine.refresh(force: true) }
        for _ in 0..<100 where server.fetches == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.fetches, before + 1)
        return refresh
    }

    /// #198: a fetch that path changes alone supersede, however many, installs nothing and does not fetch again at once: the refresh
    /// on the settled path does, once. The script loaded before stays in place meanwhile, and the install reports the path change.
    func testAFetchPathChangesSupersedeEndsAndTheSettledRefreshFetchesOnce() async throws {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)
        try await engine.refresh(force: true)
        XCTAssertEqual(server.fetches, 1)

        let refresh = try await heldRefresh(engine, server: server)
        server.setOnVPN(true)
        for _ in 0..<3 { engine.invalidateRoutes(reason: .networkChanged) }
        server.gate.signal()
        try await refresh.value

        XCTAssertEqual(server.fetches, 2, "no refetch before the path settles")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.off,
                       "the script loaded before the changes stays, evaluating afresh")
        XCTAssertEqual(named("pac.refreshed", in: events).count, 1, "the superseded fetch installed nothing")
        XCTAssertEqual(named("pac.refresh_deferred", in: events).map(\.detail), ["reason=network_changed fetch=succeeded"])
        XCTAssertEqual(named("pac.routes_invalidated", in: events).map(\.detail).last, "reason=network_changed routes=0 script=kept fetch=deferred")

        // The path settles: its forced refresh fetches, once, and installs the new network's script.
        try await engine.refresh(force: true, honorBackoff: true)
        XCTAssertEqual(server.fetches, 3)
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
        XCTAssertEqual(named("pac.refreshed", in: events).last?.detail?.contains("after=network_changed"), true)
    }

    /// #198: a fetch that failed on the network before a path change neither counts towards the backoff nor fetches again at once;
    /// the settled refresh, which honours the backoff, finds none in force and fetches once.
    func testAFailedFetchPathChangesSupersedeIsNotCountedAndWaitsForTheSettle() async throws {
        let server = Server()
        server.setFailing(true)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        let refresh = try await heldRefresh(engine, server: server)
        engine.invalidateRoutes(reason: .networkChanged)
        engine.invalidateRoutes(reason: .networkChanged)
        server.setFailing(false)
        server.gate.signal()
        try await refresh.value

        XCTAssertEqual(server.fetches, 1, "no refetch before the path settles")
        XCTAssertNil(engine.backoffRemaining(), "the failure from before the change does not start a backoff")
        XCTAssertEqual(named("pac.refresh_failed", in: events).count, 0)
        XCTAssertEqual(named("pac.refresh_deferred", in: events).first?.detail?.hasPrefix("reason=network_changed fetch=failed error="), true,
                       "\(named("pac.refresh_deferred", in: events).map(\.detail))")

        try await engine.refresh(force: true, honorBackoff: true)
        XCTAssertEqual(server.fetches, 2)
        XCTAssertEqual(named("pac.refresh_backoff", in: events).count, 0)
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.off)
    }

    /// A VPN transition during a fetch still has it done again at once, path changes alongside it or not.
    func testAVPNTransitionAmongPathChangesStillRefetchesAtOnce() async throws {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        let refresh = try await heldRefresh(engine, server: server)
        engine.invalidateRoutes(reason: .networkChanged)
        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .vpnConnected)
        engine.invalidateRoutes(reason: .networkChanged)
        server.gate.signal()
        try await refresh.value

        XCTAssertEqual(server.fetches, 2, "fetched again at once for the VPN")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on)
        XCTAssertEqual(named("pac.refresh_deferred", in: events).count, 0)
        XCTAssertEqual(named("pac.routes_invalidated", in: events).compactMap(\.detail).map { $0.components(separatedBy: " ").last },
                       ["fetch=deferred", "fetch=restarted", "fetch=restarted"])
    }

    /// #198 review: a refresh asked for after a path change (the settled path's) that finds the fetch from before the change still
    /// running joins it, and that fetch, once superseded, is done again on the current path instead of ending: the late caller never
    /// returns on a fetch from before the change. One fetch on the settled path, and the new network's script routes.
    func testARefreshJoiningAFetchAPathChangeSupersededGetsAFetchOnTheSettledPath() async throws {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)
        try await engine.refresh(force: true)
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.off)

        // A fetch on the old path (a wake's, say) is held; the path changes; the settle's refresh joins the held fetch.
        let early = try await heldRefresh(engine, server: server)
        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .networkChanged)
        let settle = Task { try await engine.refresh(force: true, honorBackoff: true) }
        for _ in 0..<500 where engine.refreshWaiterCount() < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(engine.refreshWaiterCount(), 2, "the settle's refresh joined the held fetch")
        server.gate.signal()
        try await early.value
        try await settle.value

        XCTAssertEqual(server.fetches, 3, "one fetch on the settled path")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on, "routing on the new script")
        XCTAssertEqual(named("pac.refresh_deferred", in: events).count, 0, "a caller asked after the change, so nothing was deferred")
        XCTAssertEqual(named("pac.refreshed", in: events).last?.detail?.contains("after=network_changed"), true)
    }

    /// An evaluation of the old script still running at the invalidation:
    /// its answer is neither cached nor handed to the requests waiting on it.
    func testAnEvaluationRunningAcrossTheInvalidationIsDiscarded() async throws {
        final class GatedEvaluator: PacScriptEvaluating, @unchecked Sendable {
            let gate = DispatchSemaphore(value: 0)
            func resolveProxyChain(for url: URL) throws -> [String] {
                gate.wait()
                return ["PROXY policy-detection.example:80"]
            }
        }
        struct OnVPNEvaluator: PacScriptEvaluating {
            func resolveProxyChain(for url: URL) throws -> [String] { ["PROXY corp.example:8080"] }
        }
        /// The first script evaluates behind a gate; any later one answers at once.
        final class Resolver: PacEvaluator, @unchecked Sendable {
            let gated = GatedEvaluator()
            private let made = NIOLockedValueBox(0)
            private let classifier = CFPACEvaluator()
            func fetchPAC(from urlString: String) async throws -> String { "" }
            func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
                let count = made.withLockedValue { $0 += 1; return $0 }
                return count == 1 ? gated : OnVPNEvaluator()
            }
            func routeChain(for entries: [String]) -> PACChain { classifier.routeChain(for: entries) }
        }

        let resolver = Resolver()
        let config = makeConfig()
        let engine = PACRoutingEngine(
            configProvider: { config }, resolver: resolver, refreshInterval: 300, pacLoader: { _ in "" }
        )
        try await engine.refresh(force: true)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let leader = engine.decisionFuture(for: "https://github.com/", host: "github.com", on: loop)
        let waiter = engine.decisionFuture(for: "https://github.com/", host: "github.com", on: loop)
        try await Task.sleep(for: .milliseconds(100))

        engine.invalidateRoutes(reason: .vpnConnected)
        resolver.gated.gate.signal()
        let leaderDecision = try await leader.get()
        let waiterDecision = try await waiter.get()
        XCTAssertEqual(leaderDecision, .noUsableAnswer(.superseded, rejected: []),
                       "the pre-transition answer does not reach the request that ran it")
        XCTAssertEqual(waiterDecision, .noUsableAnswer(.superseded, rejected: []),
                       "nor the request waiting on it")

        try await engine.refresh(force: true)
        let after = try await engine.decisionFuture(for: "https://github.com/", host: "github.com", on: loop).get()
        XCTAssertEqual(after.routes, [Self.on], "the old answer was not cached")
    }

    func testWithPACRoutingOffTheInvalidationIsANoOp() {
        let server = Server()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events, config: makeConfig(pacRoutingEnabled: false))
        engine.invalidateRoutes(reason: .vpnDisconnected)
        XCTAssertTrue(named("pac.routes_invalidated", in: events).isEmpty)
    }
}
