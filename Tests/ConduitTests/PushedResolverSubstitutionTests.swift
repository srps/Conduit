// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac

private let service = "com.cisco.anyconnect"
private let tunnelServers = ["192.0.2.53", "198.51.100.53"]

final class PushedResolverSubstitutionTests: XCTestCase {
    private func store(servers: [String], id: String = service) -> [String: Any] { [
        "State:/Network/Service/\(id)/DNS": [
            "DomainName": "corp.example",
            "ServerAddresses": servers,
        ] as [String: Any],
        "State:/Network/Service/\(id)/IPv4": ["InterfaceName": "utun6", "OverridePrimary": 1] as [String: Any],
    ] }

    func testAKeyAtLoopbackReadsAsItsSubstitutionAndIsOverridden() {
        let reading = PushedResolverReading.parse(store: store(servers: ["127.0.0.1"]), substitutions: [service: tunnelServers])

        XCTAssertEqual(reading.resolvers.map(\.servers), [tunnelServers])
        XCTAssertEqual(reading.resolvers.map(\.overridden), [true])
        XCTAssertEqual(reading.rejections, [])
    }

    func testOverriddenIsPartOfTheReadingsEquality() {
        let overridden = PushedResolverReading.parse(store: store(servers: ["127.0.0.1"]), substitutions: [service: tunnelServers])
        let restored = PushedResolverReading.parse(store: store(servers: tunnelServers), substitutions: [service: tunnelServers])

        XCTAssertEqual(overridden.resolvers.map(\.servers), restored.resolvers.map(\.servers))
        XCTAssertNotEqual(overridden, restored, "the helper's restore must pass the monitor's deduplication")
        XCTAssertEqual(restored.resolvers.map(\.overridden), [false])
    }

    func testASubstitutionAppliesOnlyToItsServiceAndOnlyToExactlyLoopback() {
        let other = PushedResolverReading.parse(store: store(servers: ["127.0.0.1"]), substitutions: ["other": tunnelServers])
        XCTAssertEqual(other.resolvers, [])
        XCTAssertEqual(other.rejections.map(\.reason), [.selfReferential, .selfReferential])

        let rewritten = PushedResolverReading.parse(store: store(servers: ["203.0.113.53"]), substitutions: [service: tunnelServers])
        XCTAssertEqual(rewritten.resolvers.map(\.servers), [["203.0.113.53"]], "the client's newer value wins")
        XCTAssertEqual(rewritten.resolvers.map(\.overridden), [false])
    }

    func testLoopbackIsNeverATunnelServer() {
        for loopback in ["127.0.0.1", "127.8.9.10", "::1", "::ffff:127.0.0.1"] {
            let mixed = PushedResolverReading.parse(store: store(servers: [loopback, "192.0.2.53"]))
            XCTAssertEqual(mixed.resolvers.map(\.servers), [["192.0.2.53"]], loopback)
            XCTAssertEqual(
                mixed.rejections,
                [.init(serviceID: service, interface: "utun6", value: loopback, reason: .selfReferential)],
                loopback
            )
        }
    }

    func testAKeyLeftWithNoServerIsSelfReferential() {
        let reading = PushedResolverReading.parse(store: store(servers: ["127.0.0.1", "::1"]))

        XCTAssertEqual(reading.resolvers, [])
        XCTAssertEqual(Set(reading.rejections.map(\.reason)), [.selfReferential])
        XCTAssertTrue(reading.rejections.contains(.init(serviceID: service, interface: "utun6", reason: .selfReferential)))
    }

    func testALoopbackSubstitutionIsDroppedToo() {
        let reading = PushedResolverReading.parse(store: store(servers: ["127.0.0.1"]), substitutions: [service: ["127.0.0.1"]])

        XCTAssertEqual(reading.resolvers, [])
        XCTAssertTrue(reading.rejections.contains(.init(serviceID: service, interface: "utun6", reason: .selfReferential)))
    }

    func testTheMonitorReadsThroughItsSubstitutions() {
        let store = ScriptedPushedResolverStore(keys: store(servers: ["127.0.0.1"]))
        let monitor = PushedResolverMonitor(calls: store.calls, clock: FakeStoreObserverClock().clock)
        let delivered = expectation(description: "a reading")
        let readings = NIOLockedReadings()
        monitor.setSubstitutions { [service: tunnelServers] }
        monitor.setOnChange { reading in
            readings.append(reading)
            delivered.fulfill()
        }
        defer { monitor.stop() }

        monitor.start()

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(readings.all.first?.resolvers.map(\.servers), [tunnelServers])
        XCTAssertEqual(readings.all.first?.resolvers.map(\.overridden), [true])
    }

    func testAReadThatSpansTheBoxChangingReadsThroughEitherSide() {
        for (before, after) in [([String: [String]](), [service: tunnelServers]), ([service: tunnelServers], [:])] {
            let scripted = ScriptedPushedResolverStore(keys: store(servers: ["127.0.0.1"]))
            let box = SubstitutionBox(before)
            var calls = scripted.calls
            let copy = calls.copyMultiple
            calls.copyMultiple = { session, patterns in
                box.value = after
                return copy(session, patterns)
            }
            let monitor = PushedResolverMonitor(calls: calls, clock: FakeStoreObserverClock().clock)
            let delivered = expectation(description: "a reading")
            let readings = NIOLockedReadings()
            monitor.setSubstitutions { box.value }
            monitor.setOnChange { reading in
                readings.append(reading)
                delivered.fulfill()
            }

            monitor.start()
            wait(for: [delivered], timeout: 5)
            monitor.stop()

            XCTAssertEqual(readings.all.first?.resolvers.map(\.servers), [tunnelServers], "\(before) -> \(after)")
            XCTAssertEqual(readings.all.first?.rejections, [], "not self_referential")
        }
    }
}

private final class SubstitutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String: [String]]
    init(_ value: [String: [String]]) { current = value }
    var value: [String: [String]] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private final class NIOLockedReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [PushedResolverReading] = []
    var all: [PushedResolverReading] { lock.withLock { readings } }
    func append(_ reading: PushedResolverReading) { lock.withLock { readings.append(reading) } }
}

