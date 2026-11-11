// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The detected split-DNS set on the control snapshot (decision 0044): its caps are the policy's, the largest set
/// the policy can build fits the snapshot bound, and the codec refuses a set past a cap.
final class ControlDetectedSplitDNSTests: XCTestCase {
    func testTheCapsAreThePolicys() {
        let limits = SplitDNSLimits.standard
        XCTAssertEqual(ControlDetectedSplitDNS.maxRows, limits.maxDetectedResolvers)
        XCTAssertEqual(ControlDetectedSplitDNS.maxDomains, limits.maxDetectedDomains)
        XCTAssertEqual(ControlDetectedSplitDNS.maxServersPerRow, limits.maxServersPerDomain)
    }

    /// 17 resolvers on 17 tunnels, each with one 253-byte domain and nine IPv6 servers: one past every cap.
    private func overfullReading() -> PushedResolverReading {
        let resolvers = (0..<17).map { index -> PushedResolver in
            let label = String(repeating: Character(UnicodeScalar(UInt8(97 + index))), count: 63)
            let domain = "\(label).\(label).\(label).\(String(repeating: "x", count: 61))"
            XCTAssertEqual(domain.utf8.count, DomainNameSyntax.maxLength)
            let servers = (0..<9).map { "2001:db8:ffff:ffff:ffff:ffff:\(String(format: "%04x", index)):ff0\($0)" }
            return PushedResolver(
                serviceID: "service-\(String(format: "%02d", index))", searchOrder: index,
                interface: "utun\(10_000_000_000 + index)", domains: [domain], servers: servers
            )
        }
        return PushedResolverReading(resolvers: resolvers)
    }

    private func display(_ state: VPNObservedState) -> DetectedSplitDNSDisplay {
        let reading = overfullReading()
        var gate = SplitDNSVPNGate()
        _ = gate.update(state)
        var policy = LiveSplitDNSPolicy(limits: .standard)
        _ = policy.update(gate: gate, liveInterfaces: Set(reading.resolvers.map(\.interface)), reading: reading)
        return policy.display
    }

    @RuntimeActor func testTheLargestPolicyOutputRoundTripsAndFitsTheSnapshotBound() async throws {
        let stamp = ControlRuntimeStamp(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: 9)),
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 2)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 5))
        )
        let cases: [(VPNObservedState, ControlDetectedSplitDNSState)] = [
            (.connected, .inUse), (.disconnected(reason: .userInitiated), .idle),
        ]
        for (vpn, expected) in cases {
            var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
            let empty = try RuntimeSnapshotControlProjection.snapshot(
                kernel, stamp: stamp, profileName: "Work", collectionRevisions: ControlCollectionRevisions()
            )
            let emptyWire = String(decoding: try RuntimeWireSize.encode(empty), as: UTF8.self)
            XCTAssertFalse(emptyWire.contains("detectedSplitDNS"), "a set that is none is absent on the wire")
            kernel.detectedSplitDNS = display(vpn)
            let full = try RuntimeSnapshotControlProjection.snapshot(
                kernel, stamp: stamp, profileName: "Work", collectionRevisions: ControlCollectionRevisions()
            )

            let detected = full.detectedSplitDNS
            XCTAssertEqual(detected.state, expected)
            XCTAssertEqual(detected.rows.count, 16)
            XCTAssertEqual(detected.rows.reduce(0) { $0 + $1.domains.count }, 16)
            XCTAssertTrue(detected.rows.allSatisfy { $0.servers.count == 8 && $0.interface.utf8.count == 15 })
            let encoded = try RuntimeWireSize.encode(full)
            XCTAssertEqual(try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeSnapshot.self, from: encoded), full)
            let cost = encoded.count - (try RuntimeWireSize.bytes(of: empty))
            print("DETECTED-SPLIT-DNS-SIZING state=\(expected.rawValue) snapshotPayloadBytes=\(encoded.count) detectedBytes=\(cost)")
            XCTAssertLessThan(cost, RuntimeServiceProfile.latestSnapshotBytes / 4, "the largest set leaves the snapshot bound room")

            var budget = ControlFrameBudget(limit: cost)
            XCTAssertNoThrow(try detected.measure(into: &budget), "the measure is a lower bound on the encoded size")
            var tight = ControlFrameBudget(limit: 16 * (15 + 253 + 8 * 39) - 1)
            XCTAssertThrowsError(try detected.measure(into: &tight), "every interface, domain and server is counted")
        }
    }

    func testAHeldSetRoundTripsAndProjects() throws {
        let row = ControlDetectedSplitDNSRow(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])
        let held = ControlDetectedSplitDNS(state: .held, rows: [row])
        let encoded = try JSONEncoder().encode(held)
        XCTAssertEqual(try JSONDecoder().decode(ControlDetectedSplitDNS.self, from: encoded), held)
        XCTAssertEqual(
            RuntimeSnapshotControlProjection.detectedSplitDNS(
                DetectedSplitDNSDisplay(state: .held, rows: [.init(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])])
            ),
            held
        )
    }

    func testTheCodecRefusesASetPastACap() throws {
        func row(domains: Int = 1, servers: Int = 1, tag: Int = 0) -> ControlDetectedSplitDNSRow {
            ControlDetectedSplitDNSRow(
                interface: "utun6", domains: (0..<domains).map { "d\(tag)-\($0).example" },
                servers: (0..<servers).map { "192.0.2.\($0)" }
            )
        }
        let atCaps = ControlDetectedSplitDNS(state: .inUse, rows: (0..<16).map { row(servers: 8, tag: $0) })
        let pastCaps = [
            ControlDetectedSplitDNS(state: .inUse, rows: (0..<17).map { row(domains: 0, tag: $0) }),
            ControlDetectedSplitDNS(state: .inUse, rows: [row(domains: 9, tag: 0), row(domains: 8, tag: 1)]),
            ControlDetectedSplitDNS(state: .idle, rows: [row(servers: 9)]),
        ]

        XCTAssertNoThrow(try JSONEncoder().encode(atCaps))
        for value in pastCaps {
            XCTAssertThrowsError(try JSONEncoder().encode(value))
            let wire = try JSONSerialization.data(withJSONObject: [
                "state": value.state.rawValue,
                "rows": value.rows.map { ["interface": $0.interface, "domains": $0.domains, "servers": $0.servers] },
            ])
            XCTAssertThrowsError(try JSONDecoder().decode(ControlDetectedSplitDNS.self, from: wire))
        }
    }
}
