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
        let table = SplitDNSTable(entries: entries)
        XCTAssertEqual(table.rule(matching: "host.eu.corp.example")?.servers, ["192.0.2.20"])
        XCTAssertEqual(table.rule(matching: "host.corp.example")?.servers, ["192.0.2.10", "192.0.2.11"])
        XCTAssertEqual(table.rule(matching: "eu.corp.example")?.domain, "eu.corp.example")
    }

    func testMatchStopsAtLabelBoundariesAndIgnoresCase() {
        let table = SplitDNSTable(entries: entries)
        XCTAssertNil(table.rule(matching: "notcorp.example"))
        XCTAssertNil(table.rule(matching: "example"))
        XCTAssertEqual(table.rule(matching: "Host.LAB.example")?.domain, "lab.example")
        XCTAssertEqual(table.rule(matching: "host.lab.example.")?.domain, "lab.example")
    }

    func testDisabledEntriesAreLeftOut() {
        let table = SplitDNSTable(entries: entries)
        XCTAssertNil(table.rule(matching: "host.off.example"))
        XCTAssertEqual(table.rules.map(\.domain), ["corp.example", "eu.corp.example", "lab.example"])
    }

    func testEntriesForOneDomainMergeTheirServersOnce() {
        let table = SplitDNSTable(entries: [
            DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.10"]),
            DomainDNSEntry(domain: "CORP.example", servers: ["192.0.2.11", "192.0.2.10"]),
        ])
        XCTAssertEqual(table.rules.count, 1)
        XCTAssertEqual(table.rule(matching: "a.corp.example")?.servers, ["192.0.2.10", "192.0.2.11"])
    }

    func testAnEntryWithoutServersStillClaimsItsNames() {
        let table = SplitDNSTable(entries: [DomainDNSEntry(domain: "corp.example", servers: [])])
        XCTAssertEqual(table.rule(matching: "a.corp.example")?.servers, [])
        XCTAssertEqual(table.firstServers, [])
    }

    func testFirstServersAreTheFirstRules() {
        XCTAssertEqual(SplitDNSTable(entries: entries).firstServers, ["192.0.2.10", "192.0.2.11"])
        XCTAssertEqual(SplitDNSTable.empty.firstServers, [])
        XCTAssertNil(SplitDNSTable.empty.rule(matching: "anything.example"))
        let leadingEmpty = [DomainDNSEntry(domain: "corp.example", servers: [])] + entries
        XCTAssertEqual(SplitDNSTable(entries: leadingEmpty).firstServers, ["192.0.2.10", "192.0.2.11"],
                       "an entry without servers must not hide the next entry's servers")
    }
}
