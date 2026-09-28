// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// A material network-path change drops the cached PAC answers (#34, after
/// #101 made path changes rare enough to act on).
@MainActor
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

    func testAMaterialPathChangeInvalidatesTheRoutesAndTheFirstPathDoesNot() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let pac = StaticPAC()
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
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
}
