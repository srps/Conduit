// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import PlatformMac

private let service = "com.cisco.anyconnect"

final class PushedResolverOwnKeyTests: XCTestCase {
    private func store(servers: [String], id: String = service) -> [String: Any] { [
        "State:/Network/Service/\(id)/DNS": [
            "DomainName": "corp.example",
            "ServerAddresses": servers,
        ] as [String: Any],
        "State:/Network/Service/\(id)/IPv4": ["InterfaceName": "utun6", "OverridePrimary": 1] as [String: Any],
    ] }

    private var ownKey: [String: Any] { [
        "State:/Network/Service/\(HelperConstants.vpnDNSOverrideServiceID)/DNS": [
            "ServerAddresses": ["127.0.0.1"],
            "ServerPort": HelperConstants.vpnDNSOverrideRelayPort,
            "SupplementalMatchDomains": [""],
            "SupplementalMatchOrders": [0],
        ] as [String: Any],
    ] }

    func testTheHelpersOwnKeyIsIgnored() {
        let without = PushedResolverReading.parse(store: store(servers: ["192.0.2.53"]))
        let with = PushedResolverReading.parse(store: store(servers: ["192.0.2.53"]).merging(ownKey) { $1 })
        XCTAssertEqual(with, without)
        XCTAssertEqual(with.resolvers.map(\.servers), [["192.0.2.53"]])
        XCTAssertFalse(with.rejections.contains { $0.serviceID == HelperConstants.vpnDNSOverrideServiceID })
    }

    func testTheOwnKeyAloneReadsAsNoResolver() {
        let reading = PushedResolverReading.parse(store: ownKey)
        XCTAssertEqual(reading.resolvers, [])
        XCTAssertEqual(reading.rejections, [])
    }

    func testLoopbackAndUnspecifiedAreNeverTunnelServers() {
        for address in ["127.0.0.1", "127.8.9.10", "::1", "::ffff:127.0.0.1", "0.0.0.0", "::"] {
            let mixed = PushedResolverReading.parse(store: store(servers: [address, "192.0.2.53"]))
            XCTAssertEqual(mixed.resolvers.map(\.servers), [["192.0.2.53"]], address)
            XCTAssertEqual(
                mixed.rejections,
                [.init(serviceID: service, interface: "utun6", value: address, reason: .selfReferential)],
                address
            )
        }
    }

    func testAKeyLeftWithNoServerIsSelfReferential() {
        let reading = PushedResolverReading.parse(store: store(servers: ["127.0.0.1", "::1"]))
        XCTAssertEqual(reading.resolvers, [])
        XCTAssertEqual(Set(reading.rejections.map(\.reason)), [.selfReferential])
        XCTAssertTrue(reading.rejections.contains(.init(serviceID: service, interface: "utun6", reason: .selfReferential)))
    }
}
