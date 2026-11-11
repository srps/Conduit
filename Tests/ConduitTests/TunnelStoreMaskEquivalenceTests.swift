// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// A masked capture must read the way the store it came from reads, or a
/// fixture built from it tests something the Mac never showed. Every store
/// here, and every malformed variant of it, parses to the same detection
/// through the mask as without it.
final class TunnelStoreMaskEquivalenceTests: XCTestCase {
    /// What detection takes from a tunnel. Addresses and service IDs are
    /// renamed by the mask, so only their count and presence are compared.
    private struct Read: Equatable {
        let interface: String
        let hasInterfaceKey: Bool
        let ipv4Addresses: Int
        let hasRoutableIPv6: Bool
        let hasService: Bool
        let overridesPrimary: Bool

        init(_ tunnel: TunnelSnapshot.Tunnel) {
            interface = tunnel.interface
            hasInterfaceKey = tunnel.hasInterfaceKey
            ipv4Addresses = tunnel.ipv4Addresses.count
            hasRoutableIPv6 = tunnel.hasRoutableIPv6
            hasService = tunnel.serviceID != nil
            overridesPrimary = tunnel.overridesPrimary
        }
    }

    private static func interface(_ name: String, _ family: String, _ fields: [String: Any]) -> [String: Any] {
        ["State:/Network/Interface/\(name)/\(family)": fields]
    }

    private static func service(_ id: String, _ family: String, _ fields: [String: Any]) -> [String: Any] {
        ["State:/Network/Service/\(id)/\(family)": fields]
    }

    private static func store(_ parts: [String: Any]...) -> [String: Any] {
        parts.reduce(into: [:]) { $0.merge($1) { _, new in new } }
    }

    /// The stores of `TunnelSnapshotParseTests` and `TunnelStoreCaptureTests`,
    /// with their extra fields.
    private static var fixtures: [String: [String: Any]] { [
        "cisco connected": store(
            interface("utun0", "IPv6", ["Addresses": ["fe80::1"], "PrefixLength": [64]]),
            interface("utun1", "IPv6", ["Addresses": ["fe80::2"]]),
            interface("utun6", "IPv4", [
                "Addresses": ["192.0.2.200"], "DestAddresses": ["192.0.2.200"], "SubnetMasks": ["255.255.255.0"],
            ]),
            interface("utun6", "IPv6", ["Addresses": ["fe80::3%utun6", "2001:db8:ffff::77"], "Flags": [0, 1024]]),
            service("com.cisco.anyconnect", "IPv4", [
                "InterfaceName": "utun6", "Addresses": ["192.0.2.200"], "OverridePrimary": 1,
                "Router": "192.0.2.99", "ServerAddress": "vpn.corp.example",
                "AdditionalRoutes": [["DestinationAddress": "198.51.100.200", "SubnetMask": "255.255.255.255"]],
            ]),
            service("6A1E4C2B-0D3F-4E8A-9B7C-1F2E3D4C5B6A", "IPv4", [
                "InterfaceName": "en0", "Addresses": ["203.0.113.20"], "NetworkSignature": "IPv4.Router=203.0.113.1",
            ]),
            interface("en0", "IPv4", ["Addresses": ["203.0.113.20"]])
        ),
        "off VPN": store(
            interface("utun0", "IPv6", ["Addresses": ["fe80::1"]]),
            interface("utun1", "IPv6", ["Addresses": ["fe80::2"]])
        ),
        "empty": [:],
        "IPv4 key with no addresses": interface("utun6", "IPv4", ["Addresses": [String]()]),
        "IPv4 key with no Addresses field": interface("utun6", "IPv4", [:]),
        "IPv4 only": interface("utun4", "IPv4", ["Addresses": ["192.0.2.7", "192.0.2.8"]]),
        "IPv6 kinds": interface("utun5", "IPv6", [
            "Addresses": ["fe80::1%utun5", "febf::1", "::1", "::", "ff02::1", "not-an-address", "fd00::10"],
        ]),
        "IPv6 only": interface("utun5", "IPv6", ["Addresses": ["2001:db8::10"]]),
        "service only": service("com.cisco.anyconnect", "IPv4", ["InterfaceName": "utun6", "Addresses": ["192.0.2.200"]]),
        "several services": store(
            interface("utun6", "IPv4", ["Addresses": ["192.0.2.200"]]),
            interface("utun7", "IPv4", ["Addresses": ["192.0.2.201"]]),
            service("v6-service", "IPv6", ["InterfaceName": "utun6", "OverridePrimary": 1]),
            service("b-service", "IPv4", ["InterfaceName": "utun7", "OverridePrimary": 0]),
            service("a-service", "IPv6", ["InterfaceName": "utun7"])
        ),
        "interface names": store(
            interface("utun", "IPv4", ["Addresses": ["192.0.2.1"]]),
            interface("utunX", "IPv4", ["Addresses": ["192.0.2.2"]]),
            interface("ipsec0", "IPv4", ["Addresses": ["192.0.2.3"]]),
            interface("utun12", "IPv4", ["Addresses": ["192.0.2.4"]]),
            ["State:/Network/Interface/utun3/Link": ["Active": true]],
            ["State:/Network/Interface/utun3/extra/IPv4": ["Addresses": ["192.0.2.5"]]]
        ),
        "wrong types": [
            "State:/Network/Interface/utun6/IPv4": "not a dictionary",
            "State:/Network/Interface/utun7/IPv4": ["Addresses": [192, 0, 2, 1]],
            "State:/Network/Interface/utun8/IPv4": ["Addresses": "192.0.2.1"],
            "State:/Network/Service/odd/IPv4": ["InterfaceName": 6],
        ],
    ] }

    /// Values of the wrong type, or of the right type and odd content, for a
    /// field detection reads.
    private static var oddValues: [Any] { [
        [192, 0, 2, 1], ["192.0.2.1", 7] as [Any], [["192.0.2.1"]], [NSNull()], [Data([1])],
        "192.0.2.1", "utun6", "en0", "1", "", 1, 0, true, false, 0.5, Double.nan, Double.infinity, -Double.infinity,
        NSNull(), ["Addresses": ["192.0.2.1"]], Data([1]), Date(timeIntervalSince1970: 0),
        [String](), ["not-an-address"], ["2001:db8::1", "fe80::1%utun6", "::1"], ["fe80::1"], ["192.0.2.1", "192.0.2.1"],
    ] }

    private static let readFields = ["Addresses", "InterfaceName", "OverridePrimary"]

    /// Each fixture, then each with one key's value replaced, or one field
    /// detection reads replaced by an odd value or removed.
    private static func variants() -> [(name: String, store: [String: Any])] {
        var out: [(String, [String: Any])] = []
        for (name, fixture) in fixtures.sorted(by: { $0.key < $1.key }) {
            out.append((name, fixture))
            for key in fixture.keys.sorted() {
                for (index, odd) in ([NSNull(), "not a dictionary", [["Addresses": ["192.0.2.1"]]]] as [Any]).enumerated() {
                    var store = fixture
                    store[key] = odd
                    out.append(("\(name) / \(key) is odd value \(index)", store))
                }
                guard let fields = fixture[key] as? [String: Any] else { continue }
                for field in readFields {
                    var removed = fields
                    removed[field] = nil
                    var store = fixture
                    store[key] = removed
                    out.append(("\(name) / \(key) without \(field)", store))
                    for (index, odd) in oddValues.enumerated() {
                        var changed = fields
                        changed[field] = odd
                        store[key] = changed
                        out.append(("\(name) / \(key) / \(field) is odd value \(index)", store))
                    }
                }
            }
        }
        return out
    }

    func testEveryFixtureAndMalformedVariantReadsTheSameMaskedAsRaw() throws {
        let variants = Self.variants()
        var compared = 0
        for (name, raw) in variants {
            let real = TunnelSnapshot.parse(store: raw)
            var mask = TunnelStoreMask()
            let capture = TunnelStoreCapture(reading: .success(raw), offset: 0, elapsed: 0, mask: &mask)
            let masked = TunnelSnapshot.parse(store: try XCTUnwrap(capture.keys).mapValues(\.storeValue))

            XCTAssertEqual(
                VPNUpPredicate.anyIPv4Tunnel.holds(for: masked), VPNUpPredicate.anyIPv4Tunnel.holds(for: real),
                "up differs for \(name)"
            )
            XCTAssertEqual(masked.tunnels.map(Read.init), real.tunnels.map(Read.init), "the tunnels differ for \(name)")
            XCTAssertEqual(capture.up, VPNUpPredicate.anyIPv4Tunnel.holds(for: real), "the line's up differs for \(name)")
            compared += 1
        }
        XCTAssertEqual(compared, 2538, "12 fixtures, 3 odd values for each of 30 keys, and 84 field variants for each of 29 dictionaries")
    }

    func testThePlaceholderPastEachTableStillReadsAsItsKind() {
        var mask = TunnelStoreMask()
        let ipv4 = (0..<763).map { "10.\($0 / 256).\($0 % 256).1" }
        let routable = (0..<0x10000).map { "2001:db8:ffff::\(String($0, radix: 16))" }
        let raw: [String: Any] = [
            "State:/Network/Interface/utun6/IPv4": ["Addresses": ipv4],
            "State:/Network/Interface/utun6/IPv6": ["Addresses": routable],
            "State:/Network/Interface/utun7/IPv6": ["Addresses": ["2001:db8:ffff::1:0"]],
        ]

        let capture = TunnelStoreCapture(reading: .success(raw), offset: 0, elapsed: 0, mask: &mask)

        XCTAssertEqual(capture.tunnels?.map(\.hasRoutableIPv6), [true, true],
                       "the 65,537th routable address is still routable")
        XCTAssertEqual(capture.tunnels?.first?.ipv4Addresses.count, 763)
    }
}
