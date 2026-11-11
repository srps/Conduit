// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// `TunnelSnapshot.parse` over fixture dictionaries shaped like
/// `SCDynamicStoreCopyMultiple` output. Addresses are masked (RFC 5737,
/// RFC 3849).
final class TunnelSnapshotParseTests: XCTestCase {
    private static let wifiService = "6A1E4C2B-0D3F-4E8A-9B7C-1F2E3D4C5B6A"

    private func interface(_ name: String, _ family: String, _ addresses: [String]) -> [String: Any] {
        ["State:/Network/Interface/\(name)/\(family)": ["Addresses": addresses] as [String: Any]]
    }

    private func service(_ id: String, _ family: String, _ value: [String: Any]) -> [String: Any] {
        ["State:/Network/Service/\(id)/\(family)": value]
    }

    private func store(_ parts: [String: Any]...) -> [String: Any] {
        parts.reduce(into: [:]) { $0.merge($1) { _, new in new } }
    }

    /// Cisco Secure Client connected as a full tunnel, beside the Wi-Fi
    /// service and Apple's service tunnels.
    private var ciscoConnected: [String: Any] {
        store(
            interface("utun0", "IPv6", ["fe80::1"]),
            interface("utun1", "IPv6", ["fe80::2"]),
            interface("utun6", "IPv4", ["192.0.2.200"]),
            interface("utun6", "IPv6", ["fe80::3"]),
            service("com.cisco.anyconnect", "IPv4", [
                "InterfaceName": "utun6", "Addresses": ["192.0.2.200"], "OverridePrimary": 1,
            ]),
            service(Self.wifiService, "IPv4", ["InterfaceName": "en0", "Addresses": ["203.0.113.20"]]),
            ["State:/Network/Interface/en0/IPv4": ["Addresses": ["203.0.113.20"]] as [String: Any]]
        )
    }

    func testAConnectedFullTunnelIsReadBesideTheServiceTunnels() {
        XCTAssertEqual(TunnelSnapshot.parse(store: ciscoConnected), TunnelSnapshot(tunnels: [
            .init(interface: "utun0"),
            .init(interface: "utun1"),
            .init(
                interface: "utun6", ipv4Addresses: ["192.0.2.200"],
                serviceID: "com.cisco.anyconnect", overridesPrimary: true
            ),
        ]), "en0 and its service are not tunnels")
    }

    func testOffVPNOnlyTheServiceTunnelsRemainAndNoneCounts() {
        let snapshot = TunnelSnapshot.parse(store: store(
            interface("utun0", "IPv6", ["fe80::1"]),
            interface("utun1", "IPv6", ["fe80::2"])
        ))

        XCTAssertEqual(snapshot.tunnels.map(\.interface), ["utun0", "utun1"])
        XCTAssertFalse(VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot))
    }

    func testAnEmptyStoreIsAnEmptySnapshot() {
        XCTAssertEqual(TunnelSnapshot.parse(store: [:]), TunnelSnapshot())
    }

    func testAnIPv4KeyWithNoAddressesIsATunnelThatDoesNotCount() {
        let empty = TunnelSnapshot.parse(store: interface("utun6", "IPv4", []))
        let missing = TunnelSnapshot.parse(store: ["State:/Network/Interface/utun6/IPv4": [:] as [String: Any]])

        XCTAssertEqual(empty, TunnelSnapshot(tunnels: [.init(interface: "utun6")]))
        XCTAssertEqual(missing, empty, "a key with no Addresses field reads the same")
        XCTAssertFalse(VPNUpPredicate.anyIPv4Tunnel.holds(for: empty))
    }

    func testATunnelWithOnlyAnIPv4KeyCounts() {
        let snapshot = TunnelSnapshot.parse(store: interface("utun4", "IPv4", ["192.0.2.7", "192.0.2.8"]))

        XCTAssertEqual(snapshot.tunnels, [.init(interface: "utun4", ipv4Addresses: ["192.0.2.7", "192.0.2.8"])])
        XCTAssertTrue(VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot))
    }

    func testRoutableIPv6IsAnyUnicastAddressOutsideLinkLocal() {
        func routable(_ addresses: [String]) -> Bool {
            TunnelSnapshot.parse(store: interface("utun5", "IPv6", addresses)).tunnels[0].hasRoutableIPv6
        }

        XCTAssertFalse(routable(["fe80::1"]))
        XCTAssertFalse(routable(["fe80::1%utun5", "febf::1"]), "all of fe80::/10, with or without a zone")
        XCTAssertFalse(routable(["::1", "::", "ff02::1", "not-an-address"]))
        XCTAssertTrue(routable(["fe80::1", "2001:db8::10"]))
        XCTAssertTrue(routable(["fd00::10"]), "a unique local address routes inside the tunnel")
    }

    func testAnIPv6OnlyTunnelIsReportedAndDoesNotCountToday() {
        let snapshot = TunnelSnapshot.parse(store: interface("utun5", "IPv6", ["2001:db8::10"]))

        XCTAssertEqual(snapshot.tunnels, [.init(interface: "utun5", hasRoutableIPv6: true)])
        XCTAssertFalse(VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot))
        XCTAssertTrue(VPNUpPredicate { $0.hasRoutableIPv6 }.holds(for: snapshot), "a later predicate can admit it")
    }

    func testAServiceNamingATunnelWithNoInterfaceKeyIsReportedAsGone() {
        let snapshot = TunnelSnapshot.parse(store: service("com.cisco.anyconnect", "IPv4", [
            "InterfaceName": "utun6", "Addresses": ["192.0.2.200"],
        ]))

        XCTAssertEqual(snapshot.tunnels, [
            .init(interface: "utun6", hasInterfaceKey: false, serviceID: "com.cisco.anyconnect"),
        ], "addresses are the interface key's; a service key alone does not make the tunnel count")
    }

    func testTheServiceJoinsFromEitherFamilyAndOverridePrimaryOnlyFromIPv4() {
        let snapshot = TunnelSnapshot.parse(store: store(
            interface("utun6", "IPv4", ["192.0.2.200"]),
            interface("utun7", "IPv4", ["192.0.2.201"]),
            service("v6-service", "IPv6", ["InterfaceName": "utun6", "OverridePrimary": 1]),
            service("b-service", "IPv4", ["InterfaceName": "utun7", "OverridePrimary": 0]),
            service("a-service", "IPv6", ["InterfaceName": "utun7"])
        ))

        XCTAssertEqual(snapshot.tunnels.map(\.serviceID), ["v6-service", "a-service"],
                       "the first in order when several name the tunnel")
        XCTAssertEqual(snapshot.tunnels.map(\.overridesPrimary), [false, false])
    }

    func testOnlyUtunFollowedByDigitsIsATunnel() {
        let snapshot = TunnelSnapshot.parse(store: store(
            interface("utun", "IPv4", ["192.0.2.1"]),
            interface("utunX", "IPv4", ["192.0.2.2"]),
            interface("ipsec0", "IPv4", ["192.0.2.3"]),
            interface("utun12", "IPv4", ["192.0.2.4"]),
            ["State:/Network/Interface/utun3/Link": ["Active": true] as [String: Any]],
            ["State:/Network/Interface/utun3/extra/IPv4": ["Addresses": ["192.0.2.5"]] as [String: Any]]
        ))

        XCTAssertEqual(snapshot.tunnels.map(\.interface), ["utun12"])
    }

    func testAValueOfTheWrongTypeReadsAsAbsent() {
        let snapshot = TunnelSnapshot.parse(store: [
            "State:/Network/Interface/utun6/IPv4": "not a dictionary",
            "State:/Network/Interface/utun7/IPv4": ["Addresses": [192, 0, 2, 1]] as [String: Any],
            "State:/Network/Interface/utun8/IPv4": ["Addresses": "192.0.2.1"] as [String: Any],
            "State:/Network/Service/odd/IPv4": ["InterfaceName": 6] as [String: Any],
        ])

        XCTAssertEqual(snapshot, TunnelSnapshot(tunnels: [.init(interface: "utun7"), .init(interface: "utun8")]),
                       "as VPNStatusMonitor reads them: no key, and no addresses")
    }

    func testTunnelsComeInNameOrderWhateverTheDictionaryOrder() {
        let names = ["utun9", "utun10", "utun2", "utun0"]
        let snapshot = TunnelSnapshot.parse(store: names.reduce(into: [:]) {
            $0.merge(interface($1, "IPv6", ["fe80::1"])) { _, new in new }
        })

        XCTAssertEqual(snapshot.tunnels.map(\.interface), ["utun0", "utun10", "utun2", "utun9"],
                       "string order, as VPNStateFuser orders its names")
    }
}
