// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

/// The material-path fingerprint and the tracker behind
/// `ProxyOrchestrator.admitNetworkPath` (#101). Pure values: `NWPath` cannot
/// be built in a test, so `NetworkMonitor` maps it into `NetworkPathState`.
final class NetworkPathStateTests: XCTestCase {

    private func path(
        status: NetworkPathState.Status = .satisfied,
        interfaces: [(String, String)] = [("en0", "wifi")],
        gateways: [String] = ["192.168.1.1", "fe80::1%en0"],
        ipv4: Bool = true, ipv6: Bool = true, dns: Bool = true,
        expensive: Bool = false, constrained: Bool = false
    ) -> NetworkPathState {
        NetworkPathState(
            status: status,
            interfaces: interfaces.map { .init(name: $0.0, type: $0.1) },
            gateways: gateways,
            supportsIPv4: ipv4, supportsIPv6: ipv6, supportsDNS: dns,
            isExpensive: expensive, isConstrained: constrained
        )
    }

    // MARK: - Fingerprint

    func testIdenticalPathsHaveNoChangedFields() {
        XCTAssertEqual(path().changedFields(from: path()), [])
    }

    func testGatewayOrderIsNotAChange() {
        XCTAssertEqual(path(gateways: ["fe80::1%en0", "192.168.1.1"]).changedFields(from: path()), [])
    }

    /// Cost hints alone change no route, resolver or gateway.
    func testExpensiveAndConstrainedAreNotMaterial() {
        XCTAssertEqual(path(expensive: true, constrained: true).changedFields(from: path()), [])
    }

    func testEachMaterialFieldIsReported() {
        let base = path()
        XCTAssertEqual(path(status: .unsatisfied).changedFields(from: base), [.status])
        XCTAssertEqual(path(interfaces: [("en0", "wifi"), ("utun4", "other")]).changedFields(from: base), [.interfaces])
        XCTAssertEqual(path(interfaces: [("en0", "wired")]).changedFields(from: base), [.interfaces], "type is part of it")
        XCTAssertEqual(path(gateways: ["192.168.1.254", "fe80::1%en0"]).changedFields(from: base), [.gateways])
        XCTAssertEqual(path(ipv4: false).changedFields(from: base), [.supportsIPv4])
        XCTAssertEqual(path(ipv6: false).changedFields(from: base), [.supportsIPv6])
        XCTAssertEqual(path(dns: false).changedFields(from: base), [.supportsDNS])
        XCTAssertEqual(path(gateways: [], ipv6: false).changedFields(from: base), [.gateways, .supportsIPv6])
    }

    /// Ethernet plugged in under Wi-Fi moves the route even with the same set.
    func testInterfaceOrderIsAChange() {
        let wifiFirst = path(interfaces: [("en0", "wifi"), ("en7", "wired")])
        let wiredFirst = path(interfaces: [("en7", "wired"), ("en0", "wifi")])
        XCTAssertEqual(wiredFirst.changedFields(from: wifiFirst), [.interfaces])
    }

    /// Field keys become event tokens beside `satisfied=`, `dns=`, `pac=` and
    /// `path=`; a collision would make a token parser read the wrong value.
    func testFieldKeysDoNotCollideWithTheEventKeys() {
        let keys = Set(NetworkPathState.Field.allCases.map(\.rawValue))
        XCTAssertTrue(keys.isDisjoint(with: ["satisfied", "dns", "pac", "path", "changed", "unchanged_before", "count"]))
        for field in NetworkPathState.Field.allCases {
            XCTAssertFalse(path(interfaces: [], gateways: []).render(field).contains(" "), "\(field)")
            XCTAssertFalse(path().render(field).contains(" "), "\(field)")
        }
        XCTAssertFalse(path(expensive: true).description.contains("="), "path= is free text with no nested keys")
    }

    func testDescriptionNamesEveryField() {
        XCTAssertEqual(
            path(ipv6: false, expensive: true).description,
            "satisfied; interfaces en0/wifi; gateways 192.168.1.1,fe80::1%en0; supports ipv4,dns; expensive"
        )
        XCTAssertEqual(
            path(status: .unsatisfied, interfaces: [], gateways: [], ipv4: false, ipv6: false, dns: false).description,
            "unsatisfied; interfaces none; gateways none; supports none"
        )
    }

    // MARK: - Tracker

    func testFirstPathIsAChangeWithNoDiff() throws {
        var tracker = NetworkPathTracker()
        guard case .changed(let change) = tracker.admit(path()) else { return XCTFail("first path must act") }
        XCTAssertNil(change.previous)
        XCTAssertEqual(change.changedToken, "initial")
        XCTAssertEqual(change.diffTokens, [])
    }

    func testUnchangedUpdatesAreCountedAndCoalesced() {
        var tracker = NetworkPathTracker()
        _ = tracker.admit(path())
        var emittedAt: [Int] = []
        for _ in 0..<200 {
            guard case .unchanged(let count, let emit) = tracker.admit(path()) else { return XCTFail("nothing changed") }
            if emit { emittedAt.append(count) }
        }
        XCTAssertEqual(emittedAt, [1, 2, 4, 8, 16, 32, 64, 128, 192])
    }

    func testChangeCarriesTheUnchangedCountAndResetsIt() {
        var tracker = NetworkPathTracker()
        _ = tracker.admit(path())
        for _ in 0..<5 { _ = tracker.admit(path()) }
        guard case .changed(let roam) = tracker.admit(path(gateways: ["10.0.0.1"])) else { return XCTFail("roam must act") }
        XCTAssertEqual(roam.unchangedBefore, 5)
        XCTAssertEqual(roam.changedFields, [.gateways])
        XCTAssertEqual(roam.diffTokens, ["gateways=192.168.1.1,fe80::1%en0->10.0.0.1"])
        XCTAssertEqual(tracker.admit(path(gateways: ["10.0.0.1"])), .unchanged(count: 1, emit: true))
    }

    /// A cost-hint flip is not acted on, but the newest report is kept, so
    /// the next change's `path=` shows the path as it is.
    func testNonMaterialFieldsFollowTheNewestReport() {
        var tracker = NetworkPathTracker()
        _ = tracker.admit(path())
        XCTAssertEqual(tracker.admit(path(expensive: true)), .unchanged(count: 1, emit: true))
        XCTAssertEqual(tracker.current?.isExpensive, true)
    }
}
