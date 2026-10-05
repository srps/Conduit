// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// How both hosts take one debounced path report (#101 review): the DoH
/// transport reset and the PAC refetch only on a material change, the system
/// DNS reconcile on every report. A VPN client (Cisco Secure Client) rewrites
/// service DNS with no material path change, and the reconcile is what
/// re-pins 127.0.0.1.
@MainActor
final class NetworkPathReportsTests: XCTestCase {

    private static func wifi(gateway: String = "192.168.1.1") -> NetworkPathState {
        NetworkPathState(
            status: .satisfied,
            interfaces: [.init(name: "en0", type: "wifi")],
            gateways: [gateway],
            supportsIPv4: true, supportsIPv6: true, supportsDNS: true
        )
    }

    private func makeOrchestrator() -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    func testIdenticalReportsReconcileEveryTimeAndActOnce() async {
        let orchestrator = makeOrchestrator()
        var acted = 0
        var reconciles = 0
        var proxyReconciles = 0

        for _ in 0..<21 {
            await NetworkPathReports.receive(
                Self.wifi(), orchestrator: orchestrator,
                act: { _ in acted += 1 },
                reconcileSystemDNS: { reconciles += 1 },
                reconcileSystemProxy: { proxyReconciles += 1 }
            )
        }

        XCTAssertEqual(acted, 1, "only the first path is material")
        XCTAssertEqual(reconciles, 21, "the reconcile is not deduped")
        XCTAssertEqual(proxyReconciles, 21, "unchanged path reports retry system proxy drift too")
    }

    func testGatewayChangeActsAndReconciles() async throws {
        let orchestrator = makeOrchestrator()
        var changes: [NetworkPathChange] = []
        var reconciles = 0
        for gateway in ["192.168.1.1", "192.168.1.1", "10.0.0.1"] {
            await NetworkPathReports.receive(
                Self.wifi(gateway: gateway), orchestrator: orchestrator,
                act: { changes.append($0) },
                reconcileSystemDNS: { reconciles += 1 }
            )
        }

        XCTAssertEqual(changes.map(\.changedToken), ["initial", "gateways"])
        XCTAssertEqual(reconciles, 3)
    }
}
