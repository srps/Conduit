// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class SplitDNSTableTests: XCTestCase {
    private let entries = [
        DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.10", "192.0.2.11"]),
        DomainDNSEntry(domain: "eu.corp.example", servers: ["192.0.2.20"]),
        DomainDNSEntry(domain: "Lab.Example.", servers: ["192.0.2.30"]),
        DomainDNSEntry(domain: "off.example", servers: ["192.0.2.40"], enabled: false),
    ]

    func testLongestSuffixWinsOverConfigurationOrder() {
        let table = SplitDNSTable(manual: entries, detected: [])
        XCTAssertEqual(table.rule(matching: "host.eu.corp.example")?.servers, ["192.0.2.20"])
        XCTAssertEqual(table.rule(matching: "host.corp.example")?.servers, ["192.0.2.10", "192.0.2.11"])
        XCTAssertEqual(table.rule(matching: "eu.corp.example")?.domain, "eu.corp.example")
    }

    func testMatchStopsAtLabelBoundariesAndIgnoresCase() {
        let table = SplitDNSTable(manual: entries, detected: [])
        XCTAssertNil(table.rule(matching: "notcorp.example"))
        XCTAssertNil(table.rule(matching: "example"))
        XCTAssertEqual(table.rule(matching: "Host.LAB.example")?.domain, "lab.example")
        XCTAssertEqual(table.rule(matching: "host.lab.example.")?.domain, "lab.example")
    }

    func testDisabledEntriesAreLeftOut() {
        let table = SplitDNSTable(manual: entries, detected: [])
        XCTAssertNil(table.rule(matching: "host.off.example"))
        XCTAssertEqual(table.rules.map(\.domain), ["corp.example", "eu.corp.example", "lab.example"])
    }

    func testEntriesForOneDomainMergeTheirServersOnce() {
        let table = SplitDNSTable(manual: [
            DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.10"]),
            DomainDNSEntry(domain: "CORP.example", servers: ["192.0.2.11", "192.0.2.10"]),
        ], detected: [])
        XCTAssertEqual(table.rules.count, 1)
        XCTAssertEqual(table.rule(matching: "a.corp.example")?.servers, ["192.0.2.10", "192.0.2.11"])
    }

    func testAnEntryWithoutServersStillClaimsItsNames() {
        let table = SplitDNSTable(manual: [DomainDNSEntry(domain: "corp.example", servers: [])], detected: [])
        XCTAssertEqual(table.rule(matching: "a.corp.example")?.servers, [])
        XCTAssertEqual(table.firstServers, [])
    }

    func testEntriesMarkEveryServerManual() {
        let table = SplitDNSTable(manual: [
            DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.10", "192.0.2.11"]),
            DomainDNSEntry(domain: "lab.example", servers: []),
        ], detected: [])
        XCTAssertEqual(table.rules.map(\.origins), [[.manual, .manual], [.manual]],
                       "one origin per server; a serverless manual rule is [.manual]")
    }

    private func pushed(_ domain: String, _ servers: [String], on interface: String = "utun6") -> SplitDNSRule {
        SplitDNSRule(
            domain: domain, servers: servers,
            origins: Array(repeating: .detected(interface: interface), count: servers.count)
        )
    }

    func testWithNothingDetectedTheTableIsTheEntriesRuleForRuleAllManual() {
        XCTAssertEqual(SplitDNSTable(manual: entries, detected: []).rules, [
            SplitDNSRule(domain: "corp.example", servers: ["192.0.2.10", "192.0.2.11"], origins: [.manual, .manual]),
            SplitDNSRule(domain: "eu.corp.example", servers: ["192.0.2.20"], origins: [.manual]),
            SplitDNSRule(domain: "lab.example", servers: ["192.0.2.30"], origins: [.manual]),
        ])
        XCTAssertEqual(SplitDNSTable(manual: [], detected: []), .empty)
    }

    func testSharedDomainAsksDetectedServersFirstAndAServerBothNameIsDetected() {
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "Corp.Example", servers: ["192.0.2.10", "192.0.2.53"])],
            detected: [pushed("corp.example", ["192.0.2.53", "198.51.100.53"])]
        )
        XCTAssertEqual(table.rules, [
            SplitDNSRule(
                domain: "corp.example",
                servers: ["192.0.2.53", "198.51.100.53", "192.0.2.10"],
                origins: [.detected(interface: "utun6"), .detected(interface: "utun6"), .manual]
            ),
        ])
    }

    func testManualRulesComeFirstThenDetectedOnlyDomainsInTheGivenOrder() {
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "lan.example", servers: ["203.0.113.5"])],
            detected: [pushed("b.example", ["192.0.2.2"]), pushed("a.example", ["192.0.2.1"]), pushed("b.example", ["192.0.2.9"])]
        )
        XCTAssertEqual(table.rules.map(\.domain), ["lan.example", "b.example", "a.example"], "a repeated domain keeps its first rule")
        XCTAssertEqual(table.firstServers, ["203.0.113.5"], "configuration keeps the first server")
        XCTAssertEqual(table.rule(matching: "x.b.example")?.servers, ["192.0.2.2"])
    }

    func testEightDetectedServersAndTwoManualKeepAllTenManualLast() {
        let detected = (1...8).map { "192.0.2.\($0)" }
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "corp.example", servers: ["203.0.113.1", "203.0.113.2"])],
            detected: [pushed("corp.example", detected)]
        )
        XCTAssertEqual(table.rules.first?.servers, detected + ["203.0.113.1", "203.0.113.2"])
        XCTAssertEqual(table.rules.first?.origins.suffix(2), [.manual, .manual])
    }

    func testLongestSuffixWinsBetweenDetectedAndManual() {
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.10"])],
            detected: [pushed("eu.corp.example", ["192.0.2.20"])]
        )
        XCTAssertEqual(table.rule(matching: "host.eu.corp.example")?.servers, ["192.0.2.20"])
        XCTAssertEqual(table.rule(matching: "host.corp.example")?.servers, ["192.0.2.10"])
    }

    func testFirstServersAreTheFirstRules() {
        XCTAssertEqual(SplitDNSTable(manual: entries, detected: []).firstServers, ["192.0.2.10", "192.0.2.11"])
        XCTAssertEqual(SplitDNSTable.empty.firstServers, [])
        XCTAssertNil(SplitDNSTable.empty.rule(matching: "anything.example"))
        let leadingEmpty = [DomainDNSEntry(domain: "corp.example", servers: [])] + entries
        XCTAssertEqual(SplitDNSTable(manual: leadingEmpty, detected: []).firstServers, ["192.0.2.10", "192.0.2.11"],
                       "an entry without servers must not hide the next entry's servers")
    }
}
