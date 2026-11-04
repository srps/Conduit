@testable import ConduitRuntime
import ProxyKernel
import XCTest

final class PendingNetworkPathsTests: XCTestCase {
    private static func path(_ gateway: String?) -> NetworkPathState {
        guard let gateway else {
            return NetworkPathState(status: .unsatisfied, interfaces: [], gateways: [],
                                    supportsIPv4: false, supportsIPv6: false, supportsDNS: false)
        }
        return NetworkPathState(status: .satisfied, interfaces: [.init(name: "en0", type: "wifi")], gateways: [gateway],
                                supportsIPv4: true, supportsIPv6: false, supportsDNS: true)
    }

    private static func batch(_ gateways: [String?]) -> [NetworkPathState] {
        var pending = PendingNetworkPaths()
        for gateway in gateways { pending.append(path(gateway)) }
        return pending.take()
    }

    func testAnEmptySlotTakesNothing() {
        var pending = PendingNetworkPaths()
        XCTAssertEqual(pending.take(), [])
    }

    func testAnExcursionAndBackKeepsTheChange() {
        XCTAssertEqual(Self.batch([nil, "192.0.2.1"]), [Self.path(nil), Self.path("192.0.2.1")])
        XCTAssertEqual(Self.batch(["192.0.2.1", nil, "192.0.2.1"]),
                       [Self.path("192.0.2.1"), Self.path(nil), Self.path("192.0.2.1")])
    }

    func testABurstIsBoundedToFirstFirstChangeAndNewest() {
        let gateways: [String?] = (0...50).map { "192.0.2.\($0 % 3)" }
        XCTAssertEqual(Self.batch(gateways), [Self.path("192.0.2.0"), Self.path("192.0.2.1"), Self.path("192.0.2.2")])
    }

    func testACostHintChangeDoesNotHideALaterExcursion() {
        let settled = Self.path("192.0.2.1")
        let constrained = NetworkPathState(status: .satisfied, interfaces: [.init(name: "en0", type: "wifi")],
                                           gateways: ["192.0.2.1"], supportsIPv4: true, supportsIPv6: false,
                                           supportsDNS: true, isConstrained: true)
        var pending = PendingNetworkPaths()
        for path in [settled, constrained, Self.path(nil), settled] { pending.append(path) }
        XCTAssertEqual(pending.take(), [settled, Self.path(nil), settled])
    }

    func testRepeatsCollapse() {
        XCTAssertEqual(Self.batch(["192.0.2.1", "192.0.2.1", "192.0.2.1"]), [Self.path("192.0.2.1")])
        XCTAssertEqual(Self.batch(["192.0.2.1", "192.0.2.2", "192.0.2.2"]), [Self.path("192.0.2.1"), Self.path("192.0.2.2")])
    }

    func testTakeEmptiesTheSlot() {
        var pending = PendingNetworkPaths()
        pending.append(Self.path("192.0.2.1"))
        _ = pending.take()
        XCTAssertEqual(pending.take(), [])
    }
}
