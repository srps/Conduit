// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// A material network-path change drops the cached PAC answers (#34, after
/// #101 made path changes rare enough to act on).
final class PACNetworkChangeInvalidationTests: XCTestCase {
    private static func wifi(gateway: String) -> NetworkPathState {
        NetworkPathState(
            status: .satisfied,
            interfaces: [.init(name: "en0", type: "wifi")],
            gateways: [gateway],
            supportsIPv4: true, supportsIPv6: true, supportsDNS: true
        )
    }

    /// Counts its fetches; `holdNext()` holds the next fetch until `release()`.
    private final class StaticPAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        private let fetchCount = NIOLockedValueBox(0)
        private let holding = NIOLockedValueBox(false)
        private let gate = DispatchSemaphore(value: 0)
        var fetches: Int { fetchCount.withLockedValue { $0 } }
        func holdNext() { holding.withLockedValue { $0 = true } }
        func release() { gate.signal() }
        func fetchPAC(from _: String) async throws -> String {
            fetchCount.withLockedValue { $0 += 1 }
            if holding.withLockedValue({ held in defer { held = false }; return held }) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { self.gate.wait(); continuation.resume() }
                }
            }
            return "script"
        }
        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for _: URL) throws -> [String] { ["PROXY corp.example:8080"] }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }

    @RuntimeActor func testAMaterialPathChangeInvalidatesTheRoutesAndTheFirstPathDoesNot() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let pac = StaticPAC()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @RuntimeActor in await orchestrator.stopProxy() } }
        let cutoff = Date()
        func invalidations() -> [String] {
            orchestrator.eventLog.events
                .filter { $0.event == "pac.routes_invalidated" && $0.timestamp >= cutoff }
                .compactMap(\.detail)
        }

        await orchestrator.handleNetworkPath(Self.wifi(gateway: "192.168.1.1"))
        XCTAssertEqual(invalidations(), [], "the first path has nothing to compare with")
        await orchestrator.handleNetworkPath(Self.wifi(gateway: "192.168.1.1"))
        XCTAssertEqual(invalidations(), [], "an update that changed nothing material drops nothing")

        let fetchesBefore = pac.fetches
        await orchestrator.handleNetworkPath(Self.wifi(gateway: "10.0.0.1"))
        XCTAssertEqual(invalidations().count, 1)
        XCTAssertTrue(invalidations().first?.hasPrefix("reason=network_changed ") == true, "\(invalidations())")
        XCTAssertTrue(invalidations().first?.contains("script=kept") == true, "\(invalidations())")
        XCTAssertEqual(pac.fetches, fetchesBefore + 1, "the PAC is fetched again")
    }

    /// #198: the updates of a burst drop the answers as each one arrives, before the burst settles; only the
    /// settled report refetches, once, and drops nothing more.
    @RuntimeActor func testEachUpdateOfABurstInvalidatesAndOnlyTheSettledReportRefetches() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let pac = StaticPAC()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @RuntimeActor in await orchestrator.stopProxy() } }
        await orchestrator.handleNetworkPath(Self.wifi(gateway: "192.168.1.1"))
        let cutoff = Date()
        func count(_ name: String) -> Int {
            orchestrator.eventLog.events.filter { $0.event == name && $0.timestamp >= cutoff }.count
        }
        let fetchesBefore = pac.fetches

        XCTAssertTrue(orchestrator.invalidateNetworkPath(Self.wifi(gateway: "10.0.0.1")))
        XCTAssertEqual(count("pac.routes_invalidated"), 1, "the first change drops the answers at once")
        let invalidation = orchestrator.eventLog.events.last { $0.event == "network.path_invalidated" }
        XCTAssertEqual(invalidation?.detail?.hasPrefix("dns=idle pac_routes=dropped changed=gateways gateways=192.168.1.1->10.0.0.1 "), true,
                       "\(String(describing: invalidation?.detail))")
        XCTAssertFalse(orchestrator.invalidateNetworkPath(Self.wifi(gateway: "10.0.0.1")), "a repeat drops nothing")
        XCTAssertTrue(orchestrator.invalidateNetworkPath(Self.wifi(gateway: "10.0.0.2")))
        XCTAssertEqual(count("pac.routes_invalidated"), 2, "a later change in the burst drops what the path before it produced")
        XCTAssertEqual(count("network.path_invalidated"), 2)
        XCTAssertEqual(count("network.path_changed"), 0, "nothing refreshes before the burst settles")
        XCTAssertEqual(pac.fetches, fetchesBefore)

        let refreshed = await orchestrator.handleNetworkPath(Self.wifi(gateway: "10.0.0.2"))
        XCTAssertTrue(refreshed)
        XCTAssertEqual(count("network.path_changed"), 1)
        XCTAssertEqual(count("pac.routes_invalidated"), 2, "the settled report drops nothing the burst already dropped")
        XCTAssertEqual(pac.fetches, fetchesBefore + 1, "one refetch for the burst")
    }

    /// #198 review: a PAC fetch running when a burst of path changes begins installs nothing and does not fetch again on its own, however
    /// many changes the burst has; the refresh on the settled path fetches, once.
    @RuntimeActor func testAFetchHeldAcrossAPathBurstRefetchesOnceAfterTheSettle() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let pac = StaticPAC()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @RuntimeActor in await orchestrator.stopProxy() } }
        await orchestrator.handleNetworkPath(Self.wifi(gateway: "192.168.1.1"))
        let cutoff = Date()
        func count(_ name: String) -> Int {
            orchestrator.eventLog.events.filter { $0.event == name && $0.timestamp >= cutoff }.count
        }

        // A refresh whose fetch is held, as on a wake: the path moves on while it runs.
        let fetchesBefore = pac.fetches
        pac.holdNext()
        let refresh = Task { @RuntimeActor in await orchestrator.refreshPACRouting(force: true) }
        let deadline = ContinuousClock.now + .seconds(5)
        while pac.fetches == fetchesBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(pac.fetches, fetchesBefore + 1, "the fetch started and is held")
        for gateway in ["10.0.0.1", "10.0.0.2", "10.0.0.3"] {
            XCTAssertTrue(orchestrator.invalidateNetworkPath(Self.wifi(gateway: gateway)))
        }
        pac.release()
        await refresh.value
        XCTAssertEqual(pac.fetches, fetchesBefore + 1, "the superseded fetch does not refetch before the settle")
        XCTAssertEqual(count("pac.refresh_deferred"), 1)
        XCTAssertEqual(count("pac.refreshed"), 0, "the superseded fetch installed nothing")

        let settled = await orchestrator.handleNetworkPath(Self.wifi(gateway: "10.0.0.3"))
        XCTAssertTrue(settled)
        XCTAssertEqual(pac.fetches, fetchesBefore + 2, "one refetch, after the settle")
        XCTAssertEqual(count("pac.refreshed"), 1)
    }

    /// #198 review: the path settles while a fetch from before its change is still held, so the settled refresh joins that fetch. The
    /// fetch is then done again on the settled path, once, rather than ending with nothing fetched on it.
    @RuntimeActor func testASettleThatJoinsAFetchFromBeforeTheChangeStillFetchesOnTheSettledPath() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let pac = StaticPAC()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @RuntimeActor in await orchestrator.stopProxy() } }
        await orchestrator.handleNetworkPath(Self.wifi(gateway: "192.168.1.1"))
        let engine = try XCTUnwrap(orchestrator.pacRoutingEngine)
        let cutoff = Date()
        func count(_ name: String) -> Int {
            orchestrator.eventLog.events.filter { $0.event == name && $0.timestamp >= cutoff }.count
        }

        let fetchesBefore = pac.fetches
        pac.holdNext()
        let early = Task { @RuntimeActor in await orchestrator.refreshPACRouting(force: true) }
        let deadline = ContinuousClock.now + .seconds(5)
        while pac.fetches == fetchesBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(orchestrator.invalidateNetworkPath(Self.wifi(gateway: "10.0.0.1")))
        let settle = Task { @RuntimeActor in await orchestrator.handleNetworkPath(Self.wifi(gateway: "10.0.0.1")) }
        while engine.refreshWaiterCount() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(engine.refreshWaiterCount(), 2, "the settled refresh joined the held fetch")
        pac.release()
        await early.value
        let settled = await settle.value
        XCTAssertTrue(settled)
        XCTAssertEqual(pac.fetches, fetchesBefore + 2, "the held fetch, then one on the settled path")
        XCTAssertEqual(count("pac.refreshed"), 1, "the settled path's script is installed")
        XCTAssertEqual(count("pac.refresh_deferred"), 0)
    }
}
