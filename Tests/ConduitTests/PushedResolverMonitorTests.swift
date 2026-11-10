// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac

/// The store parser over fixture dictionaries shaped like
/// `SCDynamicStoreCopyMultiple` output, and the fake observer. Domains and
/// servers are masked (`corp.example`, RFC 5737 addresses).
final class PushedResolverMonitorTests: XCTestCase {
    private static let hotspotService = "6A1E4C2B-0D3F-4E8A-9B7C-1F2E3D4C5B6A"

    /// Observed full tunnel: a non-UUID service ID, no
    /// `SupplementalMatchDomains`, `OverridePrimary` on the IPv4 dictionary,
    /// listed beside the physical interface's own resolver.
    static var fullTunnelStore: [String: Any] { [
        "State:/Network/Service/com.cisco.anyconnect/DNS": [
            "DomainName": "corp.example",
            "SearchDomains": ["corp.example"],
            "SearchOrder": 1,
            "ServerAddresses": ["192.0.2.53", "198.51.100.53"],
        ] as [String: Any],
        "State:/Network/Service/com.cisco.anyconnect/IPv4": [
            "InterfaceName": "utun6",
            "Addresses": ["192.0.2.200"],
            "Router": "192.0.2.200",
            "OverridePrimary": 1,
        ] as [String: Any],
        "State:/Network/Service/\(hotspotService)/DNS": [
            "ServerAddresses": ["203.0.113.1"],
        ] as [String: Any],
        "State:/Network/Service/\(hotspotService)/IPv4": [
            "InterfaceName": "en0",
            "Addresses": ["203.0.113.20"],
        ] as [String: Any],
    ] }

    private func service(
        _ id: String,
        _ interface: String,
        dns: [String: Any],
        overridesPrimary: Bool = false,
        family: String = "IPv4"
    ) -> [String: Any] {
        var addressing: [String: Any] = ["InterfaceName": interface]
        if overridesPrimary { addressing["OverridePrimary"] = 1 }
        return [
            "State:/Network/Service/\(id)/DNS": dns,
            "State:/Network/Service/\(id)/\(family)": addressing,
        ]
    }

    func testObservedFullTunnelReadsItsSearchDomainAndSkipsThePhysicalService() {
        let reading = PushedResolverReading.parse(store: Self.fullTunnelStore)

        XCTAssertEqual(reading, PushedResolverReading(resolvers: [
            PushedResolver(
                serviceID: "com.cisco.anyconnect",
                searchOrder: 1,
                interface: "utun6",
                domains: ["corp.example"],
                servers: ["192.0.2.53", "198.51.100.53"],
                overridesPrimary: true
            ),
        ]), "a non-UUID service ID is read; the en0 service is skipped without a rejection")
    }

    func testFullTunnelJoinsDomainNameThenSearchDomainsOnceEachIgnoringCase() {
        let store = service("full", "utun6", dns: [
            "DomainName": "corp.example",
            "SearchDomains": ["eu.corp.example", "Corp.Example."],
            "ServerAddresses": ["192.0.2.53"],
        ], overridesPrimary: true)

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers.map(\.domains), [["corp.example", "eu.corp.example"]])
        XCTAssertEqual(reading.resolvers.map(\.overridesPrimary), [true])
    }

    func testSplitTunnelReadsOnlyItsSupplementalMatchDomains() {
        let store = service("split-vpn", "utun3", dns: [
            "DomainName": "other.example",
            "SearchDomains": ["other.example", "search.example"],
            "SupplementalMatchDomains": ["corp.example", "Lab.Corp.Example.", "corp.example"],
            "ServerAddresses": ["192.0.2.10", "2001:db8::53", "192.0.2.10"],
        ])

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers, [
            PushedResolver(
                serviceID: "split-vpn",
                interface: "utun3",
                domains: ["corp.example", "lab.corp.example"],
                servers: ["192.0.2.10", "2001:db8::53"],
                overridesPrimary: false
            ),
        ], "lowercased, trailing dot removed, each once; DomainName and SearchDomains unused")
        XCTAssertEqual(reading.rejections, [])
    }

    func testNoMatchDomainsAndNoOverridePrimaryIsRejectedWithNoResolver() {
        let store = service("split", "utun3", dns: [
            "DomainName": "corp.example",
            "SearchDomains": ["corp.example"],
            "SupplementalMatchDomains": [String](),
            "ServerAddresses": ["192.0.2.53"],
        ])

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers, [])
        XCTAssertEqual(reading.rejections, [.init(serviceID: "split", interface: "utun3", reason: .noMatchDomains)])
    }

    func testAnInvalidDomainIsRejectedAndTheRestKept() {
        let store = service("full", "utun6", dns: [
            "DomainName": "corp.example",
            "SearchDomains": ["-bad.example", "eu.corp.example"],
            "ServerAddresses": ["192.0.2.53"],
        ], overridesPrimary: true)

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers.map(\.domains), [["corp.example", "eu.corp.example"]])
        XCTAssertEqual(reading.rejections, [
            .init(serviceID: "full", interface: "utun6", value: "-bad.example", reason: .invalidDomain),
        ])
    }

    func testInterfaceFilterIPv6FallbackAndNotTunnel() {
        let dns: [String: Any] = ["SupplementalMatchDomains": ["corp.example"], "ServerAddresses": ["192.0.2.1"]]
        let store = service("v6", "utun8", dns: dns, family: "IPv6")
            .merging(service("wifi", "en0", dns: dns)) { $1 }
            .merging(service("odd", "utunX", dns: dns)) { $1 }
            .merging(service("ipsec", "ipsec0", dns: dns)) { $1 }
            .merging(["State:/Network/Service/bare/DNS": dns]) { $1 }

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers.map(\.interface), ["utun8"], "IPv6 InterfaceName when there is no IPv4 key")
        XCTAssertEqual(reading.rejections, [.init(serviceID: "bare", interface: nil, reason: .notTunnel)],
                       "only a key naming no interface is rejected; non-utun services are skipped")
    }

    func testSystemDomainsAndInvalidServersAreDroppedAndRejected() {
        let store = service("vpn", "utun4", dns: [
            "SupplementalMatchDomains": ["corp.example", "bad..example", "local", "2.0.192.in-addr.arpa", "bücher.example"],
            "ServerAddresses": ["192.0.2.53", "999.1.1.1", "fe80::1%utun4", "dns.corp.example"],
        ])

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers.map(\.domains), [["corp.example"]])
        XCTAssertEqual(reading.resolvers.map(\.servers), [["192.0.2.53"]])
        func rejected(_ value: String, _ reason: PushedResolverRejection.Reason) -> PushedResolverRejection {
            .init(serviceID: "vpn", interface: "utun4", value: value, reason: reason)
        }
        XCTAssertEqual(reading.rejections, [
            rejected("bad..example", .invalidDomain),
            rejected("local", .systemDomain),
            rejected("2.0.192.in-addr.arpa", .systemDomain),
            rejected("bücher.example", .invalidDomain),
            rejected("999.1.1.1", .invalidServer),
            rejected("fe80::1%utun4", .invalidServer),
            rejected("dns.corp.example", .invalidServer),
        ])
    }

    func testMalformedValuesAreRejectedNotSkipped() {
        let store = service("badtypes", "utun2", dns: [
            "SupplementalMatchDomains": ["corp.example", 7],
            "ServerAddresses": "192.0.2.1",
        ])
        .merging(service("noservers", "utun3", dns: ["SupplementalMatchDomains": ["corp.example"]])) { $1 }
        .merging(service("notdict", "utun5", dns: [:])) { $1 }
        .merging(["State:/Network/Service/notdict/DNS": "corp.example"]) { $1 }

        let reading = PushedResolverReading.parse(store: store)

        XCTAssertEqual(reading.resolvers.map(\.serviceID), ["badtypes"])
        XCTAssertEqual(Set(reading.rejections), [
            .init(serviceID: "badtypes", interface: "utun2", value: "7", reason: .invalidDomain),
            .init(serviceID: "noservers", interface: "utun3", reason: .invalidServer),
            .init(serviceID: "notdict", interface: "utun5", reason: .noMatchDomains),
        ])
    }

    func testFakeDeliversPrimedReadingOnStartAndEmitsOnlyWhileStarted() {
        let fake = FakePushedResolverObserver()
        let received = LockedReadings()
        fake.setOnChange { received.append($0) }
        let primed = PushedResolverReading.parse(store: Self.fullTunnelStore)
        fake.primedReading = primed
        let failed = PushedResolverReading(failure: .storeRead)

        fake.emit(PushedResolverReading())
        XCTAssertEqual(received.all, [], "nothing before start")

        fake.start()
        fake.start()
        XCTAssertEqual(received.all, [primed], "primed once per start")

        fake.emit(failed)
        fake.stop()
        fake.emit(PushedResolverReading())
        XCTAssertEqual(received.all, [primed, failed])
        XCTAssertFalse(fake.isObserving)
    }
}

private final class LockedReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [PushedResolverReading] = []
    var all: [PushedResolverReading] { lock.withLock { readings } }
    func append(_ reading: PushedResolverReading) { lock.withLock { readings.append(reading) } }
}
