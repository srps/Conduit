// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// What `pm-vpn-check --snapshot` and `--watch` print. The "real" values here
/// are themselves documentation addresses from a block the mask never hands
/// out first, so a leak shows as that value in the output.
final class TunnelStoreCaptureTests: XCTestCase {
    private static let wifiService = "6A1E4C2B-0D3F-4E8A-9B7C-1F2E3D4C5B6A"

    private var connected: [String: Any] { [
        "State:/Network/Interface/utun0/IPv6": ["Addresses": ["fe80::aaaa:bbbb"], "PrefixLength": [64]] as [String: Any],
        "State:/Network/Interface/utun6/IPv4": [
            "Addresses": ["203.0.113.77"], "DestAddresses": ["203.0.113.77"], "SubnetMasks": ["255.255.255.0"],
        ] as [String: Any],
        "State:/Network/Interface/utun6/IPv6": [
            "Addresses": ["fe80::cccc:dddd%utun6", "2001:db8:ffff::77"], "Flags": [0, 1024],
        ] as [String: Any],
        "State:/Network/Service/com.cisco.anyconnect/IPv4": [
            "InterfaceName": "utun6", "Addresses": ["203.0.113.77"], "Router": "203.0.113.77",
            "OverridePrimary": 1, "ServerAddress": "vpn.corp.example",
            "AdditionalRoutes": [["DestinationAddress": "198.51.100.200", "SubnetMask": "255.255.255.255"]],
        ] as [String: Any],
        "State:/Network/Service/\(Self.wifiService)/IPv4": [
            "InterfaceName": "en0", "Addresses": ["198.51.100.200"], "NetworkSignature": "IPv4.Router=198.51.100.1",
        ] as [String: Any],
    ] }

    private func capture(_ keys: [String: Any], mask: inout TunnelStoreMask) -> TunnelStoreCapture {
        TunnelStoreCapture(reading: .success(keys), at: Date(timeIntervalSince1970: 1_700_000_000), elapsed: 0, mask: &mask)
    }

    func testNoAddressHostNameOrServiceUUIDSurvivesMasking() throws {
        var mask = TunnelStoreMask()
        let line = try capture(connected, mask: &mask).line()

        for secret in [
            "203.0.113.77", "198.51.100.200", "198.51.100.1", "aaaa:bbbb", "cccc:dddd", "2001:db8:ffff",
            "vpn.corp.example", Self.wifiService,
        ] {
            XCTAssertFalse(line.contains(secret), "\(secret) is in \(line)")
        }
        XCTAssertTrue(line.contains("com.cisco.anyconnect"), "a vendor's fixed service ID is kept")
        XCTAssertTrue(line.contains("255.255.255.0"), "a subnet mask is not an address")
    }

    func testTheMaskedKeysKeepWhatDetectionReads() {
        var mask = TunnelStoreMask()
        let masked = capture(connected, mask: &mask)

        XCTAssertEqual(masked.tunnels, [
            .init(
                interface: "utun0", hasInterfaceKey: true, ipv4Addresses: [], hasRoutableIPv6: false,
                serviceID: nil, overridesPrimary: false
            ),
            .init(
                interface: "utun6", hasInterfaceKey: true, ipv4Addresses: ["192.0.2.1"], hasRoutableIPv6: true,
                serviceID: "com.cisco.anyconnect", overridesPrimary: true
            ),
        ])
        XCTAssertEqual(masked.up, true)
        XCTAssertEqual(masked.unrecognizedKeys, 0)

        let real = TunnelSnapshot.parse(store: connected)
        XCTAssertEqual(masked.tunnels?.map(\.interface), real.tunnels.map(\.interface))
        XCTAssertEqual(masked.tunnels?.map(\.ipv4Addresses.count), real.tunnels.map(\.ipv4Addresses.count))
        XCTAssertEqual(masked.tunnels?.map(\.hasRoutableIPv6), real.tunnels.map(\.hasRoutableIPv6))
        XCTAssertEqual(masked.tunnels?.map(\.overridesPrimary), real.tunnels.map(\.overridesPrimary))
    }

    func testEachFieldIsMaskedByItsKind() {
        var mask = TunnelStoreMask()
        let keys = capture(connected, mask: &mask).keys

        XCTAssertEqual(keys?["State:/Network/Interface/utun6/IPv6"], .dictionary([
            "Addresses": .array([.string("fe80::2"), .string("2001:db8::1")]),
            "Flags": .array([.integer(0), .integer(1024)]),
        ]), "link-local stays link-local, routable stays routable, numbers are kept")
        XCTAssertEqual(keys?["State:/Network/Service/com.cisco.anyconnect/IPv4"], .dictionary([
            "InterfaceName": .string("utun6"),
            "Addresses": .array([.string("192.0.2.1")]),
            "Router": .string("192.0.2.1"),
            "OverridePrimary": .integer(1),
            "ServerAddress": .string("<masked>"),
            "AdditionalRoutes": .array([.dictionary([
                "DestinationAddress": .string("192.0.2.2"), "SubnetMask": .string("255.255.255.255"),
            ])]),
        ]), "the same address gets the same placeholder wherever it appears")

        let wifi = "State:/Network/Service/\(TunnelStoreMask.mask(serviceID: Self.wifiService))/IPv4"
        XCTAssertEqual(keys?[wifi], .dictionary([
            "InterfaceName": .string("en0"),
            "Addresses": .array([.string("192.0.2.2")]),
            "NetworkSignature": .string("<masked>"),
        ]))
    }

    func testAServiceIDHashesTheSameEveryTimeAndAKnownVendorIDIsKept() {
        let hashed = TunnelStoreMask.mask(serviceID: Self.wifiService)

        XCTAssertEqual(hashed, TunnelStoreMask.mask(serviceID: Self.wifiService))
        XCTAssertNotEqual(hashed, TunnelStoreMask.mask(serviceID: "7B2F5D3C-1E4A-4F9B-8C6D-2A3B4C5D6E7F"))
        XCTAssertTrue(hashed.hasPrefix("service-") && hashed.count == "service-".count + 8, hashed)
        XCTAssertEqual(TunnelStoreMask.mask(serviceID: "com.cisco.anyconnect"), "com.cisco.anyconnect")
    }

    func testOneMaskKeepsAnAddressOnItsPlaceholderAcrossCaptures() {
        var mask = TunnelStoreMask()
        func addresses(_ list: [String]) -> [String]? {
            capture(["State:/Network/Interface/utun6/IPv4": ["Addresses": list] as [String: Any]], mask: &mask)
                .tunnels?.first?.ipv4Addresses
        }

        XCTAssertEqual(addresses(["203.0.113.77"]), ["192.0.2.1"])
        XCTAssertEqual(addresses(["203.0.113.78"]), ["192.0.2.2"], "a new address after a reconnect shows as new")
        XCTAssertEqual(addresses(["203.0.113.77"]), ["192.0.2.1"])
    }

    func testAddressesPastTheDocumentationBlocksAreMaskedWithoutAPlaceholder() {
        var mask = TunnelStoreMask()
        let many = (0..<763).map { "10.\($0 / 256).\($0 % 256).1" }

        let masked = capture(
            ["State:/Network/Interface/utun6/IPv4": ["Addresses": many] as [String: Any]], mask: &mask
        ).tunnels?.first?.ipv4Addresses

        XCTAssertEqual(masked?.first, "192.0.2.1")
        XCTAssertEqual(masked?[761], "203.0.113.254")
        XCTAssertEqual(masked?[762], "<masked>")
    }

    func testAValueThatIsNotTextNumberListOrDictionaryIsMasked() {
        var mask = TunnelStoreMask()
        let keys = capture([
            "State:/Network/Interface/utun6/IPv4": [
                "Blob": Data([1, 2, 3]), "When": Date(), "Flag": true, "Ratio": 0.5,
                "InterfaceName": "not an interface", "203.0.113.77": "named by an address",
            ] as [String: Any],
        ], mask: &mask).keys

        XCTAssertEqual(keys?["State:/Network/Interface/utun6/IPv4"], .dictionary([
            "Blob": .string("<masked>"), "When": .string("<masked>"), "Flag": .bool(true), "Ratio": .number(0.5),
            "InterfaceName": .string("<masked>"), "192.0.2.1": .string("<masked>"),
        ]))
    }

    func testAKeyThatIsNotATunnelOrServiceKeyIsLeftOutAndCounted() {
        var mask = TunnelStoreMask()
        let masked = capture([
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any],
            "State:/Network/Global/DNS": ["ServerAddresses": ["203.0.113.53"]] as [String: Any],
            "State:/Network/Interface/utun6/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any],
        ], mask: &mask)

        XCTAssertEqual(masked.keys?.keys.sorted(), ["State:/Network/Interface/utun6/IPv4"])
        XCTAssertEqual(masked.unrecognizedKeys, 2)
    }

    func testAFailedReadingIsALineThatNamesTheFailure() throws {
        var mask = TunnelStoreMask()
        let failed = TunnelStoreCapture(
            reading: .failure(.init(.storeRead, code: 1001)), at: Date(timeIntervalSince1970: 1_700_000_000), elapsed: 2.5, mask: &mask
        )

        XCTAssertEqual(try failed.line(), #"{"at":1700000000,"elapsed":2.5,"failure":"store_read"}"#)
    }

    func testALineIsOneJSONObjectWithEpochSeconds() throws {
        var mask = TunnelStoreMask()
        let line = try capture(
            ["State:/Network/Interface/utun6/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any]], mask: &mask
        ).line()

        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["at"] as? Double, 1_700_000_000)
        XCTAssertEqual(object["up"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), ["at", "elapsed", "keys", "tunnels", "up", "unrecognizedKeys"])
    }
}
