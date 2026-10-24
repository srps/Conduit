// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyKernel

/// The one typed resource traversal (`DomainResourceCheck.configuration(_:)`), exercised through a spy source. The spy
/// records each element accessor call, so a test sees exactly which elements the traversal read, in what order.
final class ConfigurationResourceTraversalTests: XCTestCase {
    // MARK: - Count before element access

    /// A list over its count is refused before any element is read, so an oversized list costs no element reads.
    func testOversizedListsAreRefusedByCountBeforeAnyElementIsRead() {
        assertCountRefusal({ $0.upstreams = $1 }, field: .upstreams, limit: 32)
        assertCountRefusal({ $0.dohProviders = $1 }, field: .dohProviders, limit: 8)
        assertCountRefusal({ $0.dnsEntries = $1 }, field: .dnsEntries, limit: 256)
        assertCountRefusal({ $0.interceptRules = $1 }, field: .interceptRules, limit: 256)
        assertCountRefusal({ $0.tunnelDefinitions = $1 }, field: .tunnelDefinitions, limit: 128)
    }

    /// Elements inside the count are read in order, and the first refused element stops the reads. Each upstream reads
    /// its name, then its host only when the name passes. The third upstream is never read.
    func testOnlyTheElementsUpToTheFirstRefusalAreRead() {
        let log = ReadLog()
        var source = SpySource()
        source.upstreams = [
            record(log, "a"),
            record(log, longText(1_025)),
            record(log, "c"),
        ]
        XCTAssertEqual(DomainResourceCheck.configuration(source), DomainResourceViolation(.upstreamName, 1_024))
        XCTAssertEqual(log.reads, ["upstreamName", "upstreamHost", "upstreamName"])
    }

    // MARK: - One shared order

    /// Two violations in one configuration report the earlier place in wire order. The order does not depend on which
    /// violation is larger, or on which list appears first in the source.
    func testTwoViolationsReportTheEarlierPlaceInTheSharedOrder() {
        var profileAndTransparent = SpySource()
        profileAndTransparent.profileName = longText(1_025)
        profileAndTransparent.transparentProxyIP = longText(300)
        XCTAssertEqual(
            DomainResourceCheck.configuration(profileAndTransparent),
            DomainResourceViolation(.profileName, 1_024)
        )

        let log = ReadLog()
        var upstreamAndTransparent = SpySource()
        upstreamAndTransparent.upstreams = [record(log, longText(1_025))]
        upstreamAndTransparent.transparentProxyIP = longText(300)
        XCTAssertEqual(
            DomainResourceCheck.configuration(upstreamAndTransparent),
            DomainResourceViolation(.upstreamName, 1_024)
        )

        var dohAndTunnel = SpySource()
        dohAndTunnel.dohProviders = [record(log, longText(16_385))]
        dohAndTunnel.tunnelDefinitions = [record(log, longText(300))]
        XCTAssertEqual(
            DomainResourceCheck.configuration(dohAndTunnel),
            DomainResourceViolation(.dohProvider, 16_384)
        )

        var checkAndAudit = SpySource()
        checkAndAudit.checkURLByteCount = 16_385
        checkAndAudit.auditLogPath = longText(1_024)
        XCTAssertEqual(
            DomainResourceCheck.configuration(checkAndAudit),
            DomainResourceViolation(.checkURL, 16_384)
        )
    }

    /// A count refusal is an earlier place than a long item in the same list, so no element is read for it.
    func testCountRefusalIsReportedBeforeAnItemInTheSameList() {
        let log = ReadLog()
        var source = SpySource()
        source.upstreams = Array(repeating: record(log, longText(1_025)), count: 33)
        XCTAssertEqual(DomainResourceCheck.configuration(source), DomainResourceViolation(.upstreams, 32))
        XCTAssertEqual(log.reads, [])
    }

    /// The kernel and the private adapters both read the shared traversal, so the same two violations give the same
    /// first place on both sides.
    func testKernelAndPrivateAdaptersReportTheSameFirstPlace() throws {
        var config = ProxyConfig.testFixture()
        config.profileName = longText(1_025)
        config.dns.transparentProxyIP = longText(300)
        XCTAssertEqual(config.resourceViolation(), DomainResourceViolation(.profileName, 1_024))

        var request = try PrivateConfigSamples.request()
        request.runtime.profileName = longText(1_025)
        request.runtime.dns.transparentProxyIP = longText(300)
        XCTAssertEqual(request.resourceViolation(), DomainResourceViolation(.profileName, 1_024))

        var kernelCheck = ProxyConfig.testFixture()
        kernelCheck.health.checkURL = "https://" + longText(16_400)
        kernelCheck.logging.auditLogPath = longText(1_024)
        XCTAssertEqual(kernelCheck.resourceViolation(), DomainResourceViolation(.checkURL, 16_384))

        var privateCheck = try PrivateConfigSamples.request()
        privateCheck.runtime.health.checkURL = PrivateURLValue("https://" + longText(16_400))
        privateCheck.runtime.logging.auditLogPath = longText(1_024)
        XCTAssertEqual(privateCheck.resourceViolation(), DomainResourceViolation(.checkURL, 16_384))
    }

    // MARK: - Fixtures

    /// Records each element accessor call, in order. Every element read goes through one of the spy's accessors.
    private final class ReadLog {
        private(set) var reads: [String] = []

        func record(_ read: String) {
            reads.append(read)
        }
    }

    private struct SpyRecord {
        let log: ReadLog
        let text: String
    }

    /// A source whose values are plain strings, counts and spy records, so a test controls which elements exist.
    private struct SpySource: ConfigurationResourceSource {
        typealias Upstream = SpyRecord
        typealias Provider = SpyRecord
        typealias DNSEntry = SpyRecord
        typealias InterceptRule = SpyRecord
        typealias Tunnel = SpyRecord

        var profileName = "profile"
        var proxyHost = "proxy.example.test"
        var allowedClients: [String] = []
        var authUsername = ""
        var authDomain = ""
        var authWorkstation = ""
        var upstreams: [SpyRecord] = []
        var pacURLByteCount = 0
        var noProxyHosts: [String] = []
        var forceProxyHosts: [String] = []
        var dohProviders: [SpyRecord] = []
        var dnsEntries: [SpyRecord] = []
        var interceptRules: [SpyRecord] = []
        var transparentProxyIP = ""
        var tunnelDefinitions: [SpyRecord] = []
        var checkURLByteCount = 0
        var auditLogPath: String?

        static func upstreamName(_ record: SpyRecord) -> String {
            record.log.record("upstreamName")
            return record.text
        }

        static func upstreamHost(_ record: SpyRecord) -> String {
            record.log.record("upstreamHost")
            return record.text
        }

        static func providerByteCount(_ record: SpyRecord) -> Int {
            record.log.record("providerByteCount")
            return record.text.utf8.count
        }

        static func entryDomain(_ record: SpyRecord) -> String {
            record.log.record("entryDomain")
            return record.text
        }

        static func entryServers(_ record: SpyRecord) -> [String] {
            record.log.record("entryServers")
            return [record.text]
        }

        static func interceptPattern(_ record: SpyRecord) -> String {
            record.log.record("interceptPattern")
            return record.text
        }

        static func interceptAddress(_ record: SpyRecord) -> String {
            record.log.record("interceptAddress")
            return record.text
        }

        static func tunnelRemoteHost(_ record: SpyRecord) -> String {
            record.log.record("tunnelRemoteHost")
            return record.text
        }

        static func tunnelLabel(_ record: SpyRecord) -> String {
            record.log.record("tunnelLabel")
            return record.text
        }
    }

    private func record(_ log: ReadLog, _ text: String) -> SpyRecord {
        SpyRecord(log: log, text: text)
    }

    private func longText(_ count: Int) -> String {
        String(repeating: "x", count: count)
    }

    /// A list one over its count, with every element long enough to fail if it were read, must be refused by count
    /// with no element read.
    private func assertCountRefusal(
        _ place: (inout SpySource, [SpyRecord]) -> Void,
        field: DomainResourceField,
        limit: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let log = ReadLog()
        var source = SpySource()
        place(&source, (0...limit).map { _ in record(log, longText(1_025)) })
        XCTAssertEqual(
            DomainResourceCheck.configuration(source), DomainResourceViolation(field, limit),
            file: file, line: line
        )
        XCTAssertEqual(log.reads, [], file: file, line: line)
    }
}
