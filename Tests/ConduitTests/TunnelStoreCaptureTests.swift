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
    private static let vpnService = "7B2F5D3C-1E4A-4F9B-8C6D-2A3B4C5D6E7F"

    private var connected: [String: Any] { [
        "State:/Network/Interface/utun0/IPv6": ["Addresses": ["fe80::aaaa:bbbb"], "PrefixLength": [64]] as [String: Any],
        "State:/Network/Interface/utun6/IPv4": [
            "Addresses": ["203.0.113.77"], "DestAddresses": ["203.0.113.77"], "SubnetMasks": ["255.255.255.0"],
        ] as [String: Any],
        "State:/Network/Interface/utun6/IPv6": [
            "Addresses": ["fe80::cccc:dddd%utun6", "2001:db8:ffff::77"], "Flags": [0, 1024],
        ] as [String: Any],
        "State:/Network/Service/com.cisco.anyconnect/IPv4": [
            "InterfaceName": "utun6", "Addresses": ["203.0.113.77"], "Router": "203.0.113.99",
            "OverridePrimary": 1, "ServerAddress": "vpn.corp.example",
            "AdditionalRoutes": [["DestinationAddress": "198.51.100.200", "SubnetMask": "255.255.255.255"]],
        ] as [String: Any],
        "State:/Network/Service/\(Self.wifiService)/IPv4": [
            "InterfaceName": "en0", "Addresses": ["198.51.100.200"], "Router": "198.51.100.1",
            "NetworkSignature": "IPv4.Router=198.51.100.1",
        ] as [String: Any],
    ] }

    private func capture(_ keys: [String: Any], mask: inout TunnelStoreMask) -> TunnelStoreCapture {
        TunnelStoreCapture(reading: .success(keys), offset: 0, elapsed: 0, mask: &mask)
    }

    private func fields(_ fields: [String: Any], of key: String = "State:/Network/Interface/utun6/IPv6") -> MaskedStoreValue? {
        var mask = TunnelStoreMask()
        return capture([key: fields], mask: &mask).keys?[key]
    }

    func testNoAddressHostNameOrServiceUUIDSurvivesMasking() throws {
        var mask = TunnelStoreMask()
        let line = try capture(connected, mask: &mask).line()

        for secret in [
            "203.0.113.77", "203.0.113.99", "198.51.100.200", "198.51.100.1", "aaaa:bbbb", "cccc:dddd", "2001:db8:ffff",
            "vpn.corp.example", "corp", Self.wifiService, "en0", "NetworkSignature",
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

        let real = TunnelSnapshot.parse(store: connected)
        XCTAssertEqual(masked.tunnels?.map(\.interface), real.tunnels.map(\.interface))
        XCTAssertEqual(masked.tunnels?.map(\.ipv4Addresses.count), real.tunnels.map(\.ipv4Addresses.count))
        XCTAssertEqual(masked.tunnels?.map(\.hasRoutableIPv6), real.tunnels.map(\.hasRoutableIPv6))
        XCTAssertEqual(masked.tunnels?.map(\.overridesPrimary), real.tunnels.map(\.overridesPrimary))
    }

    func testEachKnownFieldIsMaskedByItsKind() {
        var mask = TunnelStoreMask()
        let keys = capture(connected, mask: &mask).keys

        XCTAssertEqual(keys?["State:/Network/Interface/utun6/IPv6"], .dictionary([
            "Addresses": .array([.string("fe80::2"), .string("2001:db8::1")]),
            "Flags": .array([.integer(0), .integer(1024)]),
        ]), "link-local stays link-local, routable stays routable, numbers are kept")
        XCTAssertEqual(keys?["State:/Network/Service/com.cisco.anyconnect/IPv4"], .dictionary([
            "InterfaceName": .string("utun6"),
            "Addresses": .array([.string("192.0.2.1")]),
            "Router": .string("192.0.2.3"),
            "OverridePrimary": .integer(1),
            "ServerAddress": .string("<masked>"),
            "AdditionalRoutes": .array([.dictionary([
                "DestinationAddress": .string("192.0.2.2"), "SubnetMask": .string("255.255.255.255"),
            ])]),
        ]), "the router is an address like any other, and the same address gets the same placeholder everywhere")
    }

    func testAServiceThatIsNotOnATunnelIsLeftOut() throws {
        var mask = TunnelStoreMask()
        let masked = capture(connected, mask: &mask)

        XCTAssertEqual(masked.keys?.keys.sorted(), [
            "State:/Network/Interface/utun0/IPv6",
            "State:/Network/Interface/utun6/IPv4",
            "State:/Network/Interface/utun6/IPv6",
            "State:/Network/Service/com.cisco.anyconnect/IPv4",
        ])
        XCTAssertEqual(masked.omittedKeys, 1, "the Wi-Fi service")
        XCTAssertFalse(try masked.line().contains("service-"), "and it took no placeholder")
    }

    func testAKeyThatIsNotATunnelsIsLeftOutAndCounted() {
        var mask = TunnelStoreMask()
        let masked = capture([
            "State:/Network/Interface/en0/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any],
            "State:/Network/Global/DNS": ["ServerAddresses": ["203.0.113.53"]] as [String: Any],
            "State:/Network/Service/\(Self.wifiService)/IPv6": ["Addresses": ["2001:db8:ffff::77"]] as [String: Any],
            "State:/Network/Interface/utun7/IPv4": "203.0.113.77",
            "State:/Network/Interface/utun6/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any],
        ], mask: &mask)

        XCTAssertEqual(masked.keys?.keys.sorted(), ["State:/Network/Interface/utun6/IPv4"])
        XCTAssertEqual(masked.omittedKeys, 4)
    }

    func testAServiceIDIsNumberedNotDerivedAndAKnownVendorIDIsKept() {
        var mask = TunnelStoreMask()
        let first = mask.mask(serviceID: Self.vpnService)

        XCTAssertEqual(first, "service-1")
        XCTAssertEqual(mask.mask(serviceID: Self.wifiService), "service-2")
        XCTAssertEqual(mask.mask(serviceID: Self.vpnService), first, "the same ID keeps its number within one mask")
        XCTAssertEqual(mask.mask(serviceID: "com.cisco.anyconnect"), "com.cisco.anyconnect")

        var other = TunnelStoreMask()
        XCTAssertEqual(other.mask(serviceID: Self.wifiService), "service-1",
                       "the number is the order of arrival, so guessing an ID confirms nothing")
    }

    func testATunnelServiceWithAnUnknownIDIsKeptUnderItsNumber() {
        var mask = TunnelStoreMask()
        let masked = capture([
            "State:/Network/Service/\(Self.vpnService)/IPv4": ["InterfaceName": "utun6", "OverridePrimary": 1] as [String: Any],
            "State:/Network/Service/\(Self.vpnService)/IPv6": ["InterfaceName": "utun6"] as [String: Any],
        ], mask: &mask)

        XCTAssertEqual(masked.keys?.keys.sorted(), [
            "State:/Network/Service/service-1/IPv4", "State:/Network/Service/service-1/IPv6",
        ])
        XCTAssertEqual(masked.tunnels?.first?.serviceID, "service-1")
    }

    func testServicesPastTheNumberedOnesAreLeftOut() {
        var mask = TunnelStoreMask()
        var keys: [String: Any] = [:]
        for index in 0..<257 {
            keys["State:/Network/Service/id-\(String(format: "%03d", index))/IPv4"] = ["InterfaceName": "utun6"]
        }

        let masked = capture(keys, mask: &mask)

        XCTAssertEqual(masked.keys?.count, 256)
        XCTAssertEqual(masked.omittedKeys, 1)
    }

    func testAFieldTheSchemaDoesNotNameLosesItsNameAndItsValue() {
        XCTAssertEqual(fields([
            "vpn.corp.example": "named by a host name",
            Self.wifiService: ["InterfaceName": "utun6"],
            "203.0.113.77": "named by an address",
            "fe80::aaaa:bbbb": 7,
            "Addresses": ["2001:db8:ffff::77"],
        ]), .dictionary([
            "<unknown-1>": .string("<masked>"), "<unknown-2>": .string("<masked>"),
            "<unknown-3>": .string("<masked>"), "<unknown-4>": .string("<masked>"),
            "Addresses": .array([.string("2001:db8::1")]),
        ]))
    }

    func testEveryIPv6LiteralIsReplacedWhateverItsKind() throws {
        var mask = TunnelStoreMask()
        let masked = capture(["State:/Network/Interface/utun6/IPv6": ["Addresses": [
            "ff02::1%utun6", "ff02::fb", "::1", "::1%lo0", "::", "fe80::aaaa:bbbb%utun6", "2001:db8:ffff::77%utun6",
        ]] as [String: Any]], mask: &mask)

        XCTAssertEqual(masked.keys?["State:/Network/Interface/utun6/IPv6"], .dictionary(["Addresses": .array([
            .string("ff00::1"), .string("ff00::2"), .string("ff00::3"), .string("ff00::4"), .string("ff00::5"),
            .string("fe80::1"), .string("2001:db8::1"),
        ])]))
        let line = try masked.line()
        for original in ["ff02", "::1%", "%utun6", "%lo0", "\"::1\"", "\"::\"", "aaaa:bbbb", "db8:ffff"] {
            XCTAssertFalse(line.contains(original), "\(original) is in \(line)")
        }
        XCTAssertEqual(masked.tunnels?.first?.hasRoutableIPv6, true)
    }

    func testAMulticastOrLoopbackPlaceholderStillReadsAsNeitherLinkLocalNorRoutable() {
        var mask = TunnelStoreMask()
        let masked = capture(
            ["State:/Network/Interface/utun6/IPv6": ["Addresses": ["ff02::1%utun6", "::1"]] as [String: Any]], mask: &mask
        )

        XCTAssertEqual(masked.tunnels?.first?.hasRoutableIPv6, false)
        XCTAssertEqual(TunnelSnapshot.ipv6Kind("ff00::1"), .other)
    }

    func testAnAddressFieldHoldsOnlyPlaceholders() {
        XCTAssertEqual(fields([
            "Router": "fe80::aaaa:bbbb%utun6",
            "ServerAddress": "203.0.113.77",
            "DestAddresses": ["vpn.corp.example", "203.0.113.77", 7] as [Any],
            "Gateway": ["nested": "203.0.113.77"],
        ]), .dictionary([
            "Router": .string("fe80::1"),
            "ServerAddress": .string("192.0.2.1"),
            "DestAddresses": .array([.string("<masked>"), .string("192.0.2.1"), .opaque]),
            "Gateway": .opaque,
        ]), "a value that is not a string stays one, so a list that was not all strings still is not")
    }

    func testAKnownFieldHoldingTheWrongKindOfValueIsMasked() {
        XCTAssertEqual(fields([
            "SubnetMasks": ["255.255.255.0", "203.0.113.77", "255.0.255.0"],
            "InterfaceName": "en0",
            "ConfirmedInterfaceName": "utun6",
            "OverridePrimary": "203.0.113.77",
            "Flags": [true, 0.5, Double.infinity] as [Any],
            "PrefixLength": Data([1, 2, 3]),
            "NetworkSignature": "IPv4.Router=203.0.113.77",
            "AdditionalRoutes": ["203.0.113.77", ["Gateway": "203.0.113.77", "vpn.corp.example": 1]] as [Any],
        ]), .dictionary([
            "SubnetMasks": .array([.string("255.255.255.0"), .string("<masked>"), .string("<masked>")]),
            "InterfaceName": .string("<masked>"),
            "ConfirmedInterfaceName": .string("utun6"),
            "OverridePrimary": .opaque,
            "Flags": .array([.bool(true), .number(0.5), .bool(NSNumber(value: Double.infinity).boolValue)]),
            "PrefixLength": .opaque,
            "NetworkSignature": .string("<masked>"),
            "AdditionalRoutes": .array([
                .string("<masked>"),
                .dictionary(["Gateway": .string("192.0.2.1"), "<unknown-1>": .string("<masked>")]),
            ]),
        ]))
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

    func testAddressesPastTheDocumentationBlocksShareOnePlaceholder() {
        var mask = TunnelStoreMask()
        let many = (0..<763).map { "10.\($0 / 256).\($0 % 256).1" }

        let masked = capture(
            ["State:/Network/Interface/utun6/IPv4": ["Addresses": many] as [String: Any]], mask: &mask
        ).tunnels?.first?.ipv4Addresses

        XCTAssertEqual(masked?.first, "192.0.2.1")
        XCTAssertEqual(masked?[761], "203.0.113.254")
        XCTAssertEqual(masked?[762], "192.0.2.255", "still an IPv4 address, so the tunnel still counts")
    }

    func testAFailedReadingIsALineThatNamesTheFailureAndItsCode() throws {
        var mask = TunnelStoreMask()
        let failed = TunnelStoreCapture(
            reading: .failure(.init(.storeRead, code: 1001)), offset: 2.5, elapsed: 2.5, mask: &mask
        )

        XCTAssertEqual(try failed.line(), #"{"elapsed":2.5,"failure":"store_read","failureCode":1001,"offset":2.5}"#)
    }

    func testALineHoldsOffsetsFromTheStartAndNoDate() throws {
        var mask = TunnelStoreMask()
        let line = try TunnelStoreCapture(
            reading: .success(["State:/Network/Interface/utun6/IPv4": ["Addresses": ["203.0.113.77"]] as [String: Any]]),
            offset: 125.25049, elapsed: 5.5, mask: &mask
        ).line()

        XCTAssertFalse(line.contains("\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["offset"] as? Double, 125.25, "whole milliseconds since the capture began")
        XCTAssertEqual(object["elapsed"] as? Double, 5.5, "less than the offset by the time spent asleep")
        XCTAssertEqual(object["up"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), ["offset", "elapsed", "keys", "tunnels", "up", "omittedKeys"],
                       "no field holds a wall-clock time")
    }
}
