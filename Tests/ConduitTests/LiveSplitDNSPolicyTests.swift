// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class LiveSplitDNSPolicyTests: XCTestCase {
    private let corp = PushedResolver(
        serviceID: "vpn", searchOrder: 1, interface: "utun6",
        domains: ["corp.example"], servers: ["192.0.2.53", "198.51.100.53"], overridesPrimary: true
    )
    private let lab = PushedResolver(serviceID: "vpn", interface: "utun6", domains: ["lab.example"], servers: ["192.0.2.60"])

    private func gate(_ state: VPNObservedState) -> SplitDNSVPNGate {
        var gate = SplitDNSVPNGate()
        _ = gate.update(state)
        return gate
    }

    private func reading(_ resolvers: PushedResolver..., rejections: [PushedResolverRejection] = []) -> PushedResolverReading {
        PushedResolverReading(resolvers: resolvers, rejections: rejections)
    }

    private func policy() -> LiveSplitDNSPolicy { LiveSplitDNSPolicy(limits: .standard) }

    private func table(_ policy: LiveSplitDNSPolicy) -> SplitDNSTable {
        SplitDNSTable(manual: [], detected: policy.detectedRules)
    }

    // MARK: - Gate and reading matrix

    func testConnectedNonEmptyAppliesAndARepeatIsNoChange() {
        var policy = policy()
        XCTAssertTrue(policy.update(gate: gate(.connected), reading: reading(corp)))
        XCTAssertEqual(policy.detectedInUse, [corp])
        XCTAssertFalse(policy.update(gate: gate(.connected), reading: reading(corp)), "same input twice is idempotent")
        XCTAssertTrue(policy.update(gate: gate(.connected), reading: reading(lab)))
        XCTAssertEqual(policy.detectedInUse, [lab])
    }

    func testConnectedEmptyKeepsTheHeldSet() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(corp))
        XCTAssertTrue(policy.update(gate: gate(.connected), reading: reading()), "the display turns held")
        XCTAssertEqual(policy.detectedInUse, [corp])
        XCTAssertEqual(policy.display.state, .held)
    }

    func testReassertingEmptyKeepsAndNonEmptyReplaces() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(corp))

        _ = policy.update(gate: gate(.reasserting), liveInterfaces: [], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corp], "no interface filter under .reasserting")
        XCTAssertEqual(policy.display.state, .held)

        XCTAssertTrue(policy.update(gate: gate(.reasserting), liveInterfaces: [], reading: reading(lab)))
        XCTAssertEqual(policy.detectedInUse, [lab])
        XCTAssertEqual(policy.display.state, .inUse, "a non-empty reading under .reasserting is in use, not held")
    }

    func testAnEmptyReadingBeforeTheReassertingVerdictStillHolds() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(corp))

        _ = policy.update(gate: gate(.connected), reading: reading())
        _ = policy.update(gate: gate(.reasserting), liveInterfaces: [], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corp])
        XCTAssertTrue(policy.update(gate: gate(.connected), reading: reading(corp)), "recovery: held back to in use")
        XCTAssertEqual(policy.detectedRules, table(policy).rules)
    }

    func testDisconnectedClearsWhateverTheReading() {
        for reason: VPNDisconnectReason in [.userInitiated, .networkLost, .unknown] {
            var policy = policy()
            _ = policy.update(gate: gate(.connected), reading: reading(corp))
            XCTAssertTrue(policy.update(gate: gate(.disconnected(reason: reason)), reading: reading(corp)))
            XCTAssertEqual(policy.detectedInUse, [], "\(reason)")
            XCTAssertEqual(policy.detectedRules, [])
            XCTAssertEqual(policy.display.state, .idle)
            XCTAssertEqual(policy.display.rows.map(\.domains), [["corp.example"]], "idle rows are the last reading")
            XCTAssertEqual(policy.lastReading, reading(corp))
        }
    }

    func testUnknownAppliesTheReadingLikeConnected() {
        var policy = policy()
        XCTAssertTrue(policy.update(gate: SplitDNSVPNGate(), liveInterfaces: [], reading: reading(corp)))
        XCTAssertEqual(policy.detectedInUse, [corp])
        _ = policy.update(gate: SplitDNSVPNGate(), liveInterfaces: [], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corp], "no interface filter under .unknown")
    }

    func testAReadingBeforeOrAfterTheConnectedVerdictEndsTheSame() {
        var early = policy()
        _ = early.update(gate: gate(.disconnected(reason: .userInitiated)), reading: reading(corp))
        XCTAssertEqual(early.detectedInUse, [])
        _ = early.update(gate: gate(.connected), reading: early.lastReading)

        var late = policy()
        _ = late.update(gate: gate(.connected), reading: reading())
        _ = late.update(gate: gate(.connected), reading: reading(corp))

        XCTAssertEqual(early.detectedInUse, [corp])
        XCTAssertEqual(early.detectedInUse, late.detectedInUse)
    }

    func testAnEmptyReadingOnEitherSideOfDisconnectedEndsEmpty() {
        var before = policy()
        _ = before.update(gate: gate(.connected), reading: reading(corp))
        _ = before.update(gate: gate(.connected), reading: reading())
        _ = before.update(gate: gate(.disconnected(reason: .networkLost)), reading: before.lastReading)

        var after = policy()
        _ = after.update(gate: gate(.connected), reading: reading(corp))
        _ = after.update(gate: gate(.disconnected(reason: .networkLost)), reading: after.lastReading)
        _ = after.update(gate: gate(.connected), reading: reading())

        XCTAssertEqual(before.detectedInUse, [])
        XCTAssertEqual(after.detectedInUse, [], "disconnect cleared the held set, so nothing comes back")
    }

    private let corporate = PushedResolver(
        serviceID: "corp", interface: "utun7", domains: ["corp.example"], servers: ["192.0.2.1"]
    )

    func testTwoTunnelsTheCorporateOneIsRemovedWhileTheOtherStaysUp() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate))
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corporate])

        XCTAssertTrue(policy.update(gate: gate(.connected), liveInterfaces: ["utun3"], reading: reading()),
                      "utun7 removed; utun3 stays up with no DNS key")
        XCTAssertEqual(policy.detectedInUse, [])
        XCTAssertEqual(policy.detectedRules, [])
    }

    func testATunnelAwaitingRecoveryBesideAConnectedOneKeepsItsHeldSet() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate))

        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corporate], "utun7 is flapping, not gone")
    }

    func testAPureFlapKeepsTheHeldSet() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun7"], reading: reading(corporate))

        _ = policy.update(gate: gate(.reasserting), liveInterfaces: [], reading: reading())
        XCTAssertEqual(policy.detectedInUse, [corporate])
    }

    private let branch = PushedResolver(
        serviceID: "branch", interface: "utun3", domains: ["branch.corp.example"], servers: ["198.51.100.7"]
    )

    func testTwoTunnelsOneWithdrawsItsKeyWhileItsInterfaceStaysLiveAndIsKept() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate, branch))

        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(branch))
        XCTAssertEqual(policy.detectedInUse, [branch, corporate], "utun7 withdrew its key inside a flap")
        XCTAssertEqual(policy.detectedRules.map(\.domain), ["branch.corp.example", "corp.example"])

        _ = policy.update(gate: gate(.reasserting), liveInterfaces: [], reading: reading(branch))
        XCTAssertEqual(policy.detectedInUse, [branch, corporate], "no interface filter under .reasserting")
    }

    func testTwoTunnelsOneWithdrawsItsKeyAndLeavesTheLiveSetAndIsDropped() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate, branch))

        XCTAssertTrue(policy.update(gate: gate(.connected), liveInterfaces: ["utun3"], reading: reading(branch)))
        XCTAssertEqual(policy.detectedInUse, [branch])
    }

    func testARepublishedResolverReplacesItsHeldVersion() {
        let moved = PushedResolver(
            serviceID: "corp", interface: "utun7", domains: ["corp.example"], servers: ["203.0.113.53"]
        )
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate, branch))
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(moved))

        XCTAssertEqual(policy.detectedInUse, [branch, moved], "branch held, corp's old servers replaced")
    }

    func testReplayingTheLastReadingAfterATunnelLeavesTheLiveSetDropsIt() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun7"], reading: reading(corporate, branch))

        XCTAssertTrue(policy.update(gate: gate(.connected), liveInterfaces: ["utun3"], reading: policy.lastReading))
        XCTAssertEqual(policy.detectedInUse, [branch], "the replayed reading still names utun7, which is no longer live")
        XCTAssertEqual(policy.detectedRules.map(\.domain), ["branch.corp.example"])
    }

    func testAReadingThatNamesATunnelBeforeItIsLiveTakesEffectWhenItIsReplayed() {
        let early = PushedResolver(
            serviceID: "late", interface: "utun9", domains: ["late.corp.example"], servers: ["192.0.2.9"]
        )
        var policy = policy()
        _ = policy.update(gate: gate(.connected), liveInterfaces: ["utun3"], reading: reading(early))
        XCTAssertEqual(policy.detectedInUse, [], "utun9 is not live yet")
        XCTAssertEqual(policy.detectedRules, [])

        XCTAssertTrue(policy.update(gate: gate(.connected), liveInterfaces: ["utun3", "utun9"], reading: policy.lastReading))
        XCTAssertEqual(policy.detectedInUse, [early])
    }

    // MARK: - Retained state stays bounded

    func testServiceChurnOnOneTunnelHoldsOnlyItsLatestResolver() {
        for (state, live) in [(VPNObservedState.connected, Set(["utun7"])), (.reasserting, [])] {
            var policy = policy()
            for n in 1...100 {
                _ = policy.update(gate: gate(state), liveInterfaces: live, reading: reading(PushedResolver(
                    serviceID: "svc\(n)", interface: "utun7", domains: ["corp.example"], servers: ["192.0.2.1"]
                )))
            }
            XCTAssertEqual(policy.detectedInUse.map(\.serviceID), ["svc100"], "\(state)")
        }
    }

    func testTheHeldSetStaysWithinTheResolverCapAcrossManyTunnels() {
        let live = Set((1...100).map { "utun\($0)" })
        for (state, interfaces) in [(VPNObservedState.connected, live), (.reasserting, [])] {
            var policy = policy()
            var largest = 0
            for n in 1...100 {
                _ = policy.update(gate: gate(state), liveInterfaces: interfaces, reading: reading(PushedResolver(
                    serviceID: String(format: "s%03d", n), interface: "utun\(n)",
                    domains: ["d\(n).example"], servers: ["192.0.2.1"]
                )))
                largest = max(largest, policy.detectedInUse.count)
            }
            XCTAssertEqual(largest, 16, "\(state)")
            XCTAssertEqual(policy.detectedInUse.last?.serviceID, "s100",
                           "the fresh resolver survives the cut although it sorts last")
            XCTAssertLessThanOrEqual(policy.ignored.count, 64)
        }
    }

    func testTheIgnoredSetStaysBounded() {
        let rejections = (1...200).map {
            PushedResolverRejection(serviceID: "r\($0)", interface: "utun\($0)", reason: .noMatchDomains)
        }
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: PushedResolverReading(resolvers: [corp], rejections: rejections))
        XCTAssertEqual(policy.ignored, Set(rejections.prefix(64)), "the reading's first rejections, up to the cap")

        let resolvers = (1...100).map {
            PushedResolver(serviceID: String(format: "s%03d", $0), interface: "utun\($0)",
                           domains: ["d\($0).example"], servers: ["192.0.2.1"])
        }
        _ = policy.update(gate: gate(.connected), liveInterfaces: Set(resolvers.map(\.interface)),
                          reading: PushedResolverReading(resolvers: resolvers))
        XCTAssertEqual(policy.ignored.count, 64, "84 resolvers over the cap, reported up to the cap")
        XCTAssertTrue(policy.ignored.allSatisfy { $0.reason == .overLimit })
    }

    // MARK: - Detected rules

    func testShuffledResolversBuildTheSameRulesInResolverOrder() {
        let resolvers = [
            PushedResolver(serviceID: "b", searchOrder: 200, interface: "utun4",
                           domains: ["corp.example", "b.example"], servers: ["192.0.2.2", "192.0.2.1"]),
            PushedResolver(serviceID: "a", searchOrder: 100, interface: "utun7",
                           domains: ["corp.example", "a.example"], servers: ["192.0.2.1", "192.0.2.3"]),
            PushedResolver(serviceID: "d", interface: "utun1", domains: ["d.example"], servers: ["192.0.2.9"]),
            PushedResolver(serviceID: "c", interface: "utun2", domains: ["c.example"], servers: ["192.0.2.8"]),
        ]
        func rules(_ order: [PushedResolver]) -> [SplitDNSRule] {
            var policy = policy()
            _ = policy.update(gate: gate(.connected), reading: PushedResolverReading(resolvers: order))
            return policy.detectedRules
        }

        let expected = rules(resolvers)
        for _ in 0..<20 {
            XCTAssertEqual(rules(resolvers.shuffled()), expected)
        }
        XCTAssertEqual(expected.map(\.domain), ["corp.example", "a.example", "b.example", "c.example", "d.example"],
                       "searchOrder ascending, missing last, ties by serviceID")
        XCTAssertEqual(expected.first?.servers, ["192.0.2.1", "192.0.2.3", "192.0.2.2"],
                       "the first resolver's servers, then the second's, each once")
        XCTAssertEqual(expected.first?.origins, [
            .detected(interface: "utun7"), .detected(interface: "utun7"), .detected(interface: "utun4"),
        ])
    }

    func testTheSeventeenthResolverIsDroppedAsOverLimit() {
        let resolvers = (1...17).map {
            PushedResolver(serviceID: String(format: "s%02d", $0), interface: "utun\($0)",
                           domains: ["d\($0).example"], servers: ["192.0.2.\($0)"])
        }
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: PushedResolverReading(resolvers: resolvers))

        XCTAssertEqual(policy.detectedRules.map(\.domain), (1...16).map { "d\($0).example" })
        XCTAssertEqual(policy.display.rows.count, 16)
        XCTAssertEqual(policy.ignored, [.init(serviceID: "s17", interface: "utun17", reason: .overLimit)])
    }

    func testTheSeventeenthDistinctDomainIsDroppedAsOverLimit() {
        let domains = (1...17).map { "d\($0).example" }
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(
            PushedResolver(serviceID: "vpn", interface: "utun6", domains: domains, servers: ["192.0.2.1"])
        ))

        XCTAssertEqual(policy.detectedRules.map(\.domain), Array(domains.prefix(16)))
        XCTAssertEqual(policy.ignored, [
            .init(serviceID: "vpn", interface: "utun6", value: "d17.example", reason: .overLimit),
        ])
    }

    func testAResolverWithNineServersKeepsEight() {
        let servers = (1...9).map { "192.0.2.\($0)" }
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(
            PushedResolver(serviceID: "vpn", interface: "utun6", domains: ["corp.example"], servers: servers)
        ))

        XCTAssertEqual(policy.detectedRules.first?.servers, Array(servers.prefix(8)))
        XCTAssertEqual(policy.display.rows.first?.servers, Array(servers.prefix(8)))
        XCTAssertEqual(policy.ignored, [
            .init(serviceID: "vpn", interface: "utun6", value: "192.0.2.9", reason: .overLimit),
        ])
    }

    func testADomainWhoseTwoResolversNameNineServersKeepsEight() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(
            PushedResolver(serviceID: "a", interface: "utun1", domains: ["corp.example"], servers: (1...5).map { "192.0.2.\($0)" }),
            PushedResolver(serviceID: "b", interface: "utun2", domains: ["corp.example"], servers: (5...9).map { "192.0.2.\($0)" })
        ))

        XCTAssertEqual(policy.detectedRules.first?.servers, (1...8).map { "192.0.2.\($0)" })
        XCTAssertEqual(policy.ignored, [
            .init(serviceID: "b", interface: "utun2", value: "192.0.2.9", reason: .overLimit),
        ])
    }

    func testFullTunnelReadingGivesARulePerDomainAndNoneForPublicNames() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(
            PushedResolver(serviceID: "vpn", interface: "utun6", domains: ["corp.example", "eu.corp.example"],
                           servers: ["192.0.2.53", "198.51.100.53"], overridesPrimary: true)
        ))

        XCTAssertEqual(policy.detectedRules.map(\.domain), ["corp.example", "eu.corp.example"])
        XCTAssertNil(table(policy).rule(matching: "www.example.com"), "a public name has no rule")
    }

    func testFirstServersAreTheTunnelsWhileInUseAndEmptyWhileWithheld() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(corp))
        XCTAssertEqual(table(policy).firstServers, ["192.0.2.53", "198.51.100.53"])

        _ = policy.update(gate: gate(.disconnected(reason: .userInitiated)), reading: reading(corp))
        XCTAssertEqual(table(policy).firstServers, [])
        XCTAssertEqual(table(policy), .empty)
    }

    func testSplitTunnelReadingGivesRulesForItsSupplementalDomainsOnly() {
        let parsed = PushedResolverReading.parse(store: [
            "State:/Network/Service/split/DNS": [
                "DomainName": "other.example",
                "SupplementalMatchDomains": ["corp.example", "lab.corp.example"],
                "ServerAddresses": ["192.0.2.10"],
            ] as [String: Any],
            "State:/Network/Service/split/IPv4": ["InterfaceName": "utun3"] as [String: Any],
        ])
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: parsed)

        XCTAssertEqual(policy.detectedRules.map(\.domain), ["corp.example", "lab.corp.example"])
        XCTAssertNil(table(policy).rule(matching: "host.other.example"))
    }

    // MARK: - Display

    func testDisplayListsADomainOnceAndOmitsAResolverWithNothingLeft() {
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(
            PushedResolver(serviceID: "a", searchOrder: 1, interface: "utun1",
                           domains: ["corp.example", "a.example"], servers: ["192.0.2.1"]),
            PushedResolver(serviceID: "b", searchOrder: 2, interface: "utun2",
                           domains: ["corp.example", "b.example"], servers: ["192.0.2.2"]),
            PushedResolver(serviceID: "c", searchOrder: 3, interface: "utun3",
                           domains: ["a.example"], servers: ["192.0.2.3"])
        ))

        XCTAssertEqual(policy.display, DetectedSplitDNSDisplay(state: .inUse, rows: [
            .init(interface: "utun1", domains: ["corp.example", "a.example"], servers: ["192.0.2.1"]),
            .init(interface: "utun2", domains: ["b.example"], servers: ["192.0.2.2"]),
        ]))
    }

    func testIdleRowsTakeTheSameCapsAndAddNothingToIgnored() {
        var resolvers = (1...17).map {
            PushedResolver(serviceID: String(format: "s%02d", $0), interface: "utun\($0)",
                           domains: ["d\($0).example"], servers: ["192.0.2.\($0)"])
        }
        resolvers[0] = PushedResolver(serviceID: "s01", interface: "utun1", domains: ["d1.example"],
                                      servers: (1...9).map { "198.51.100.\($0)" })
        var policy = policy()
        _ = policy.update(gate: gate(.disconnected(reason: .networkLost)),
                          reading: PushedResolverReading(resolvers: resolvers.shuffled()))

        XCTAssertEqual(policy.display.state, .idle)
        XCTAssertEqual(policy.display.rows.count, 16)
        XCTAssertEqual(policy.display.rows.flatMap(\.domains), (1...16).map { "d\($0).example" })
        XCTAssertEqual(policy.display.rows.map(\.servers.count).max(), 8)
        XCTAssertEqual(policy.ignored, [])
        XCTAssertEqual(policy.detectedRules, [])
    }

    // MARK: - Ignored set

    func testIgnoredHoldsTheReadingsRejectionsAndIsStableForARepeat() {
        let rejected = PushedResolverRejection(serviceID: "split", interface: "utun3", reason: .noMatchDomains)
        var policy = policy()
        _ = policy.update(gate: gate(.connected), reading: reading(corp, rejections: [rejected]))
        XCTAssertEqual(policy.ignored, [rejected])

        _ = policy.update(gate: gate(.connected), reading: reading(corp, rejections: [rejected]))
        XCTAssertEqual(policy.ignored, [rejected], "the host reports only members new to the set")

        _ = policy.update(gate: gate(.connected), reading: reading(corp))
        XCTAssertEqual(policy.ignored, [])
    }

    func testStandardLimitsAreTheOwnerCeilings() {
        XCTAssertEqual(
            SplitDNSLimits.standard,
            SplitDNSLimits(maxDetectedResolvers: 16, maxDetectedDomains: 16, maxServersPerDomain: 8)
        )
        XCTAssertEqual(SplitDNSLimits.standard.maxIgnored, 64)
    }
}

/// Every test tunnel connected, for the cases where `liveInterfaces` is not the point.
private extension LiveSplitDNSPolicy {
    mutating func update(gate: SplitDNSVPNGate, reading: PushedResolverReading) -> Bool {
        update(gate: gate, liveInterfaces: Set((0...20).map { "utun\($0)" }), reading: reading)
    }
}
