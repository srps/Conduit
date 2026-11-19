// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac

final class NetworkResolverParseTests: XCTestCase {
    private let wifi = "8F3E0C1A-WIFI"
    private let ethernet = "1B2C3D4E-ETHERNET"
    private let tunnel = "com.cisco.anyconnect"

    private func service(_ id: String, interface: String, servers: Any) -> [String: Any] { [
        "State:/Network/Service/\(id)/DNS": ["ServerAddresses": servers] as [String: Any],
        "State:/Network/Service/\(id)/IPv4": ["InterfaceName": interface] as [String: Any],
    ] }

    private func primary(_ id: String, interface: String? = nil) -> [String: Any] {
        var global: [String: Any] = ["PrimaryService": id]
        if let interface { global["PrimaryInterface"] = interface }
        return [PushedResolverReading.globalIPv4Key: global]
    }

    private func store(_ parts: [String: Any]...) -> [String: Any] {
        parts.reduce(into: [:]) { $0.merge($1) { _, new in new } }
    }

    func testThePrimaryServicesServersAreTheNetworks() {
        let reading = PushedResolverReading.parse(store: store(
            service(wifi, interface: "en0", servers: ["192.0.2.1", "192.0.2.2"]), primary(wifi)
        ))

        XCTAssertEqual(reading.network, NetworkResolver(serviceID: wifi, interface: "en0", servers: ["192.0.2.1", "192.0.2.2"]))
        XCTAssertEqual(reading.resolvers, [], "a physical service is never a pushed resolver")
        XCTAssertEqual(reading.rejections, [])
    }

    func testOnlyThePrimaryServiceCounts() {
        let both = store(
            service(wifi, interface: "en0", servers: ["192.0.2.1"]),
            service(ethernet, interface: "en7", servers: ["198.51.100.1"])
        )

        XCTAssertEqual(PushedResolverReading.parse(store: store(both, primary(ethernet))).network?.servers, ["198.51.100.1"])
        XCTAssertEqual(PushedResolverReading.parse(store: store(both, primary(wifi))).network?.servers, ["192.0.2.1"])
        XCTAssertNil(PushedResolverReading.parse(store: both).network, "no Global/IPv4, no primary service")
        XCTAssertNil(
            PushedResolverReading.parse(store: store(both, primary("absent", interface: "en0"))).network,
            "a primary service with no DNS key"
        )
    }

    func testATunnelAsThePrimaryServiceGivesNoNetworkServer() {
        var full = service(tunnel, interface: "utun4", servers: ["10.0.0.53"])
        full["State:/Network/Service/\(tunnel)/DNS"] = ["ServerAddresses": ["10.0.0.53"], "DomainName": "corp.example"]
        full["State:/Network/Service/\(tunnel)/IPv4"] = ["InterfaceName": "utun4", "OverridePrimary": 1]
        let reading = PushedResolverReading.parse(store: store(
            full, service(wifi, interface: "en0", servers: ["192.0.2.1"]), primary(tunnel)
        ))

        XCTAssertNil(reading.network, "a full tunnel's servers are pushed ones, never the network's")
        XCTAssertEqual(reading.resolvers.map(\.servers), [["10.0.0.53"]])
    }

    func testTheInterfaceFallsBackToTheGlobalPrimaryInterfaceAndATunnelThereIsExcluded() {
        let dnsOnly: [String: Any] = ["State:/Network/Service/\(wifi)/DNS": ["ServerAddresses": ["192.0.2.1"]]]

        XCTAssertEqual(PushedResolverReading.parse(store: store(dnsOnly, primary(wifi, interface: "en0"))).network?.interface, "en0")
        XCTAssertNil(PushedResolverReading.parse(store: store(dnsOnly, primary(wifi, interface: "utun3"))).network)
        XCTAssertNil(PushedResolverReading.parse(store: store(dnsOnly, primary(wifi))).network, "an unknown interface")
    }

    func testLoopbackNonLiteralsAndRepeatsAreSkipped() {
        let listed: [Any] = ["127.0.0.1", "192.0.2.1", "::1", "127.53.0.1", "::ffff:127.0.0.1", "dns.example", 53, "192.0.2.1", "2001:db8::53"]
        let reading = PushedResolverReading.parse(store: store(service(wifi, interface: "en0", servers: listed), primary(wifi)))

        XCTAssertEqual(reading.network?.servers, ["192.0.2.1", "2001:db8::53"])
        XCTAssertEqual(reading.network?.skipped, 7)
    }

    func testOnlyLoopbackLeavesTheNetworkWithNoServer() {
        let reading = PushedResolverReading.parse(store: store(
            service(wifi, interface: "en0", servers: ["127.0.0.1"]), primary(wifi)
        ))

        XCTAssertEqual(reading.network?.servers, [], "Conduit's own relay is never the network's server")
        XCTAssertEqual(reading.network?.skipped, 1)
    }

    func testTheServersAreCapped() {
        let listed = (1...9).map { "192.0.2.\($0)" }
        let reading = PushedResolverReading.parse(store: store(service(wifi, interface: "en0", servers: listed), primary(wifi)))

        XCTAssertEqual(reading.network?.servers, Array(listed.prefix(PushedResolverReading.networkServerLimit)))
        XCTAssertEqual(reading.network?.skipped, listed.count - PushedResolverReading.networkServerLimit)
    }

    func testAFailedReadingCarriesNoNetworkServer() {
        let failed = PushedResolverReading(
            failure: .storeRead, network: NetworkResolver(serviceID: wifi, interface: "en0", servers: ["192.0.2.1"])
        )
        XCTAssertNil(failed.network)
    }

    func testTheNetworkIsPartOfTheReadingsEquality() {
        let before = PushedResolverReading.parse(store: store(service(wifi, interface: "en0", servers: ["192.0.2.1"]), primary(wifi)))
        let after = PushedResolverReading.parse(store: store(service(wifi, interface: "en0", servers: ["192.0.2.9"]), primary(wifi)))
        XCTAssertNotEqual(before, after, "a DHCP change must pass the monitor's deduplication")
    }
}
