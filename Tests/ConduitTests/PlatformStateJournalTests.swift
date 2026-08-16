// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Pins the journal's contract, and in particular the two rules that decide
/// whether it makes the machine safer or more dangerous: first-write-wins, and
/// "no record" meaning *unknown* rather than *nothing to do*.
final class PlatformStateJournalTests: XCTestCase {

    private func makeJournal() throws -> (PlatformStateJournal, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journal-\(UUID().uuidString)")
            .appendingPathComponent("platform-state.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return (PlatformStateJournal(fileURL: url), url)
    }

    func testRecordsAndReadsBackAPriorValue() throws {
        let (journal, _) = try makeJournal()
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["autoURL": "http://corp/p.pac"])

        XCTAssertEqual(
            journal.prior(surface: .systemProxy, scope: "Wi-Fi"),
            .wasPresent(["autoURL": "http://corp/p.pac"])
        )
    }

    /// "Nothing was there" and "we never looked" must not collapse into each
    /// other: the first means teardown removes ours, the second means teardown
    /// cannot know and has to fall back to clearing unconditionally.
    func testAbsentIsDistinctFromUnrecorded() throws {
        let (journal, _) = try makeJournal()
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: nil)

        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .wasAbsent)
        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Ethernet"), .notRecorded)
    }

    /// The rule that decides whether restore works at all. Apply runs many
    /// times per session — config reload, restart, VPN transition — and every
    /// run after the first reads *our own* value as the current state. If a
    /// later record overwrote the first, the user's original setting would be
    /// replaced by ours and restore would put back what we installed.
    func testFirstRecordWinsSoOurOwnValueNeverBecomesThePrior() throws {
        let (journal, _) = try makeJournal()
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["autoURL": "http://corp/p.pac"])
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["autoURL": "http://127.0.0.1:63145/proxy.pac"])

        XCTAssertEqual(
            journal.prior(surface: .systemProxy, scope: "Wi-Fi"),
            .wasPresent(["autoURL": "http://corp/p.pac"]),
            "a second apply must not overwrite the user's original setting with ours"
        )
    }

    func testSurfacesAreIndependent() throws {
        let (journal, _) = try makeJournal()
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["autoURL": "a"])
        journal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: ["servers": "8.8.8.8"])

        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .wasPresent(["autoURL": "a"]))
        XCTAssertEqual(journal.prior(surface: .systemDNS, scope: "Wi-Fi"), .wasPresent(["servers": "8.8.8.8"]))

        journal.forgetAll(surface: .systemProxy)
        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .notRecorded)
        XCTAssertEqual(journal.prior(surface: .systemDNS, scope: "Wi-Fi"), .wasPresent(["servers": "8.8.8.8"]))
    }

    func testSurvivesAProcessRestart() throws {
        let (journal, url) = try makeJournal()
        journal.recordPrior(surface: .resolverFile, scope: "corp.example", value: ["contents": "nameserver 10.0.0.1"])

        let reopened = PlatformStateJournal(fileURL: url)
        XCTAssertEqual(
            reopened.prior(surface: .resolverFile, scope: "corp.example"),
            .wasPresent(["contents": "nameserver 10.0.0.1"]),
            "the journal is only useful across the crash it exists to survive"
        )
    }

    /// A corrupt journal must read as "we do not know" so callers fall back to
    /// an unconditional teardown, not as an error that aborts cleanup and
    /// strands the settings.
    func testCorruptJournalReadsAsUnrecordedRatherThanFailing() throws {
        let (_, url) = try makeJournal()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json at all".utf8).write(to: url)

        let journal = PlatformStateJournal(fileURL: url)
        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .notRecorded)
        XCTAssertTrue(journal.isEmpty)
    }

    func testForgetLeavesOtherScopesIntact() throws {
        let (journal, _) = try makeJournal()
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: nil)
        journal.recordPrior(surface: .systemProxy, scope: "Ethernet", value: ["autoURL": "b"])

        journal.forget(surface: .systemProxy, scope: "Wi-Fi")

        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .notRecorded)
        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Ethernet"), .wasPresent(["autoURL": "b"]))
        XCTAssertEqual(journal.scopes(for: .systemProxy), ["Ethernet"])
    }

    func testOldestRecordDateTracksTheEarliestEntry() throws {
        let (journal, _) = try makeJournal()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        journal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: nil, now: new)
        journal.recordPrior(surface: .systemDNS, scope: "Ethernet", value: nil, now: old)

        XCTAssertEqual(journal.oldestRecordDate(for: .systemDNS), old)
        XCTAssertNil(journal.oldestRecordDate(for: .systemProxy))
    }
}
