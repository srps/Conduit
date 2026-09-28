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
        try await engine.refresh(force: true)  // returns at once: one is running
        server.gate.signal()
        try await refresh.value

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
