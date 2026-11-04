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

    private final class StaticPAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        private let fetchCount = NIOLockedValueBox(0)
        var fetches: Int { fetchCount.withLockedValue { $0 } }
        func fetchPAC(from _: String) async throws -> String {
            fetchCount.withLockedValue { $0 += 1 }
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
}
