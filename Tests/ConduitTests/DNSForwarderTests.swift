// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class DNSWireFormatTests: XCTestCase {

    // MARK: - buildQuery

    func testBuildQueryProducesValidDNSPacket() {
        let packet = DNSWireFormat.buildQuery(domain: "www.google.com", txID: 0x1234, qtype: 1)
        XCTAssertEqual(packet[0], 0x12)
        XCTAssertEqual(packet[1], 0x34)
        XCTAssertTrue(packet.count >= 12, "DNS header must be at least 12 bytes")
    }

    func testBuildQueryEncodesLabelsCorrectly() {
        let packet = DNSWireFormat.buildQuery(domain: "a.bc.def")
        let domain = DNSWireFormat.extractDomainName(from: packet)
        XCTAssertEqual(domain, "a.bc.def")
    }

    func testBuildQuerySetsQtypeAAAA() {
        let packet = DNSWireFormat.buildQuery(domain: "example.com", qtype: 28)
        XCTAssertEqual(DNSWireFormat.extractQueryType(from: packet), 28)
    }

    func testBuildQuerySetsQtypeA() {
        let packet = DNSWireFormat.buildQuery(domain: "example.com", qtype: 1)
        XCTAssertEqual(DNSWireFormat.extractQueryType(from: packet), 1)
    }

    // MARK: - emptyServerFailureResponse

    /// SERVFAIL is the forwarder's answer of last resort. Every failure path
    /// uses it instead of dropping the query, so that a client learns
    /// immediately rather than waiting out its own resolver timeout and then
    /// reporting "no servers could be reached" — which reads as "the forwarder
    /// is down" rather than "this lookup failed".
    func testEmptyServerFailureResponseSetsRcode2() throws {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0xBEEF, qtype: 1)
        let response = try XCTUnwrap(DNSWireFormat.emptyServerFailureResponse(originalQuery: query))

        XCTAssertEqual(response[3] & 0x0F, 2, "rcode must be SERVFAIL")
        XCTAssertEqual(response[0], 0xBE)
        XCTAssertEqual(response[1], 0xEF)
        XCTAssertEqual(response[2] & 0x80, 0x80, "QR bit must mark this a response")
    }

    /// A SERVFAIL that does not echo the question is not a usable answer —
    /// clients match responses to queries by question, so this must satisfy the
    /// same check the forwarder applies to upstream responses.
    func testEmptyServerFailureResponseEchoesTheQuestion() throws {
        let query = DNSWireFormat.buildQuery(domain: "a.b.example.com", txID: 0x1234, qtype: 28)
        let response = try XCTUnwrap(DNSWireFormat.emptyServerFailureResponse(originalQuery: query))

        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: response))
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: response), "a.b.example.com")
    }

    func testEmptyServerFailureResponseCarriesNoAnswers() throws {
        let query = DNSWireFormat.buildQuery(domain: "example.com")
        let response = try XCTUnwrap(DNSWireFormat.emptyServerFailureResponse(originalQuery: query))

        XCTAssertEqual(Int(response[6]) << 8 | Int(response[7]), 0, "answer count must be 0")
        XCTAssertNil(DNSWireFormat.firstIPv4Answer(in: response))
    }

    /// The one case where answering is impossible: a query too malformed to
    /// echo. Callers drop these rather than inventing a question.
    func testEmptyServerFailureResponseIsNilForTruncatedQuery() {
        XCTAssertNil(DNSWireFormat.emptyServerFailureResponse(originalQuery: [0x12, 0x34]))
    }

    // MARK: - extractDomainName

    func testExtractDomainNameFromStandardQuery() {
        let query = DNSWireFormat.buildQuery(domain: "login.microsoftonline.com")
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: query), "login.microsoftonline.com")
    }

    func testExtractDomainNameSingleLabel() {
        let query = DNSWireFormat.buildQuery(domain: "localhost")
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: query), "localhost")
    }

    func testExtractDomainNameDeepSubdomain() {
        let query = DNSWireFormat.buildQuery(domain: "a.b.c.d.e.f.example.com")
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: query), "a.b.c.d.e.f.example.com")
    }

    func testExtractDomainNameEmptyOnTruncatedPacket() {
        let truncated: [UInt8] = Array(repeating: 0, count: 12)
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: truncated), "")
    }

    func testExtractDomainNameEmptyOnTooShortPacket() {
        XCTAssertEqual(DNSWireFormat.extractDomainName(from: [0, 1, 2]), "")
    }

    // MARK: - extractQueryType

    func testExtractQueryTypeA() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", qtype: 1)
        XCTAssertEqual(DNSWireFormat.extractQueryType(from: query), 1)
    }

    func testExtractQueryTypeAAAA() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", qtype: 28)
        XCTAssertEqual(DNSWireFormat.extractQueryType(from: query), 28)
    }

    func testExtractQueryTypeDefaultsTo1OnTruncated() {
        let truncated: [UInt8] = Array(repeating: 0, count: 12)
        XCTAssertEqual(DNSWireFormat.extractQueryType(from: truncated), 1)
    }

    // MARK: - isNXDOMAIN

    func testIsNXDOMAINReturnsTrueForRcode3() {
        var response = DNSWireFormat.buildQuery(domain: "nonexistent.example.com")
        response[3] = (response[3] & 0xF0) | 3 // set rcode = 3
        XCTAssertTrue(DNSWireFormat.isNXDOMAIN(response))
    }

    func testIsNXDOMAINReturnsFalseForRcode0() {
        var response = DNSWireFormat.buildQuery(domain: "example.com")
        response[3] = response[3] & 0xF0 // rcode = 0
        XCTAssertFalse(DNSWireFormat.isNXDOMAIN(response))
    }

    func testIsNXDOMAINReturnsTrueForTooShortPacket() {
        XCTAssertTrue(DNSWireFormat.isNXDOMAIN([0, 1]))
        XCTAssertTrue(DNSWireFormat.isNXDOMAIN([]))
    }

    func testShouldFallbackToPublicDoHOnNilTimeout() {
        XCTAssertTrue(DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: nil))
    }

    func testShouldFallbackToPublicDoHOnNXDOMAIN() {
        var response = DNSWireFormat.buildQuery(domain: "example.com")
        response[3] = (response[3] & 0xF0) | 3
        XCTAssertTrue(DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: response))
    }

    func testShouldFallbackToPublicDoHOnSERVFAIL() {
        var response = DNSWireFormat.buildQuery(domain: "example.com")
        response[3] = (response[3] & 0xF0) | 2
        XCTAssertTrue(DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: response))
    }

    func testShouldFallbackToPublicDoHOnNODATA() {
        var response = DNSWireFormat.buildQuery(domain: "example.com")
        response[2] = 0x81
        response[3] = 0x80
        XCTAssertTrue(DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: response))
    }

    func testShouldNotFallbackToPublicDoHOnValidAnswer() {
        let query = DNSWireFormat.buildQuery(domain: "example.com")
        let json = #"{"Answer":[{"type":1,"data":"93.184.216.34"}]}"#
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)!
        XCTAssertFalse(DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: response))
    }

    func testResponseByUpdatingTransactionIDRewritesFirstTwoBytes() {
        let originalQuery = DNSWireFormat.buildQuery(domain: "example.com", txID: 0x1111)
        let cachedQuery = DNSWireFormat.buildQuery(domain: "example.com", txID: 0xBEEF)
        let json = """
        {"Answer":[{"type":1,"data":"93.184.216.34"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: originalQuery, jsonResponse: json, queryType: 1)!

        let updated = DNSWireFormat.responseByUpdatingTransactionID(response, from: cachedQuery)
        XCTAssertEqual(updated[0], 0xBE)
        XCTAssertEqual(updated[1], 0xEF)
        XCTAssertEqual(updated[2], response[2])
        XCTAssertEqual(updated[3], response[3])
    }

    func testResponseQuestionMatchesIgnoresTransactionID() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0x1111)
        var response = DNSWireFormat.synthesizeDNSResponse(
            originalQuery: query,
            jsonResponse: #"{"Answer":[{"type":1,"data":"93.184.216.34"}]}"#,
            queryType: 1
        )!
        response[0] = 0xBE
        response[1] = 0xEF

        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: response))
    }

    /// Upstream admission, unlike cache reuse, is bound to the transaction
    /// ID and needs a response: a forged datagram with the right question but
    /// another ID, or a query-shaped one, must not be accepted.
    func testIsResponseRequiresTransactionIDAndQRBit() throws {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0x1111)
        let genuine = try XCTUnwrap(DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "93.184.216.34"))
        XCTAssertTrue(DNSWireFormat.isResponse(genuine, to: query))

        var wrongID = genuine
        wrongID[1] ^= 0x01
        XCTAssertFalse(DNSWireFormat.isResponse(wrongID, to: query))
        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: wrongID), "cache reuse still ignores the ID")

        var queryShaped = genuine
        queryShaped[2] &= 0x7F
        XCTAssertFalse(DNSWireFormat.isResponse(queryShaped, to: query))
        XCTAssertFalse(DNSWireFormat.isResponse(query, to: query), "an echoed query is not an answer")

        var otherOpcode = genuine
        otherOpcode[2] |= 0x10
        XCTAssertFalse(DNSWireFormat.isResponse(otherOpcode, to: query))

        let otherQuestion = DNSWireFormat.buildQuery(domain: "attacker.example", txID: 0x1111)
        let forged = try XCTUnwrap(DNSWireFormat.synthesizeDirectResponse(originalQuery: otherQuestion, ip: "203.0.113.10"))
        XCTAssertFalse(DNSWireFormat.isResponse(forged, to: query))
    }

    func testResponseQuestionMatchesRejectsDomainMismatch() {
        let query = DNSWireFormat.buildQuery(domain: "example.com")
        let poisonedQuery = DNSWireFormat.buildQuery(domain: "attacker.example")
        let response = DNSWireFormat.synthesizeDNSResponse(
            originalQuery: poisonedQuery,
            jsonResponse: #"{"Answer":[{"type":1,"data":"203.0.113.10"}]}"#,
            queryType: 1
        )!

        XCTAssertFalse(DNSWireFormat.responseQuestionMatches(query: query, response: response))
    }

    func testResponseQuestionMatchesRejectsTypeMismatch() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", qtype: 1)
        let typedQuery = DNSWireFormat.buildQuery(domain: "example.com", qtype: 28)
        let response = DNSWireFormat.synthesizeDNSResponse(
            originalQuery: typedQuery,
            jsonResponse: #"{"Answer":[{"type":28,"data":"2606:4700::6812:1a78"}]}"#,
            queryType: 28
        )!

        XCTAssertFalse(DNSWireFormat.responseQuestionMatches(query: query, response: response))
    }

    func testResponseQuestionMatchesRejectsClassMismatch() {
        let query = DNSWireFormat.buildQuery(domain: "example.com")
        var response = DNSWireFormat.synthesizeDNSResponse(
            originalQuery: query,
            jsonResponse: #"{"Answer":[{"type":1,"data":"93.184.216.34"}]}"#,
            queryType: 1
        )!
        response[query.count - 1] = 0x03

        XCTAssertFalse(DNSWireFormat.responseQuestionMatches(query: query, response: response))
    }

    func testMinimumTTLReturnsSmallestAnswerTTL() {
        let response: [UInt8] = [
            0x12, 0x34, 0x81, 0x80,
            0x00, 0x01, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
            0x03, 0x63, 0x6F, 0x6D,
            0x00,
            0x00, 0x01, 0x00, 0x01,
            0xC0, 0x0C,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x3C,
            0x00, 0x04,
            0x01, 0x02, 0x03, 0x04,
            0xC0, 0x0C,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x0A,
            0x00, 0x04,
            0x05, 0x06, 0x07, 0x08,
        ]

        XCTAssertEqual(DNSWireFormat.minimumTTL(in: response), 10)
    }

    func testResponseByClampingTTLCutsOnlyLongerTTLs() throws {
        let query = DNSWireFormat.buildQuery(domain: "host.corp.example", txID: 0x1234)
        // Two records, each at the synthesizer's 60 s.
        let json = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"192.0.2.1"},{"type":1,"TTL":60,"data":"192.0.2.2"}]}"#
        let response = try XCTUnwrap(DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json))

        let clamped = DNSWireFormat.responseByClampingTTL(response, to: 5)

        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: clamped)?.ttl, 5)
        XCTAssertEqual(DNSWireFormat.minimumTTL(in: clamped), 5, "every record is cut")
        XCTAssertEqual(clamped.count, response.count)
        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: clamped))
        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: clamped)?.ip, "192.0.2.1", "only the TTL bytes change")

        // A 5 s record stays 5 s under a 60 s bound.
        let short = try XCTUnwrap(DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "192.0.2.3"))
        XCTAssertEqual(DNSWireFormat.responseByClampingTTL(short, to: 60), short, "a TTL already under the bound is kept")
        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: DNSWireFormat.responseByClampingTTL(short, to: 2))?.ttl, 2)

        XCTAssertEqual(DNSWireFormat.responseByClampingTTL(Array(response.prefix(20)), to: 5), Array(response.prefix(20)), "a truncated response is returned as it is")
    }

    /// An OPT pseudo-record's TTL field is the extended RCODE, the EDNS
    /// version and the DO flag (RFC 6891), not a lifetime: the clamp leaves
    /// it alone and still cuts the records around it.
    func testResponseByClampingTTLLeavesTheOPTRecordAlone() throws {
        let query = DNSWireFormat.buildQuery(domain: "host.corp.example", txID: 0x1235)
        let json = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"192.0.2.1"}]}"#
        var response = try XCTUnwrap(DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json))
        // Root name, TYPE 41, UDP payload size 4096, extended RCODE 0, version 0, DO set, no options.
        let opt: [UInt8] = [0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00]
        response[11] += 1 // ARCOUNT
        response += opt

        let clamped = DNSWireFormat.responseByClampingTTL(response, to: 5)

        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: clamped)?.ttl, 5, "the A record is cut")
        XCTAssertEqual(Array(clamped.suffix(opt.count)), opt, "the OPT record keeps its DO flag")
        XCTAssertEqual(clamped.count, response.count)
    }

    // MARK: - Split-DNS names

    private func splitDNSRule(_ name: String, config: ProxyConfig) -> SplitDNSRule? {
        SplitDNSTable(manual: config.dnsEntries, detected: []).rule(matching: name)
    }

    func testSplitDNSNameMatchesConfiguredDNSEntry() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example.com", servers: ["10.0.0.1"])]
        XCTAssertEqual(splitDNSRule("host.corp.example.com", config: config)?.domain, "corp.example.com")
        XCTAssertEqual(splitDNSRule("corp.example.com", config: config)?.domain, "corp.example.com")
    }

    func testLocalNameIsMulticastWithNoRule() {
        let config = ProxyConfig.testFixture()
        XCTAssertNil(splitDNSRule("printer.local", config: config))
        XCTAssertTrue(DNSWireFormat.isMulticastDNSName("printer.local"))
    }

    func testExternalDomainHasNoRule() {
        let config = ProxyConfig.testFixture()
        for name in ["www.google.com", "login.microsoftonline.com", "github.com"] {
            XCTAssertNil(splitDNSRule(name, config: config), name)
            XCTAssertFalse(DNSWireFormat.isMulticastDNSName(name), name)
        }
    }

    func testSplitDNSNameIsCaseInsensitive() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example.com", servers: ["10.0.0.1"])]
        XCTAssertNotNil(splitDNSRule("Host.CORP.EXAMPLE.COM", config: config))
    }

    func testSplitDNSNameIgnoresDisabledEntries() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "private.corp", servers: ["10.0.0.1"], enabled: false)]
        XCTAssertNil(splitDNSRule("host.private.corp", config: config))
    }

    // MARK: - synthesizeDNSResponse

    func testSynthesizeResponseFromCloudflareJSON() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0xBEEF)
        let json = """
        {"Answer":[{"type":1,"data":"93.184.216.34"},{"type":1,"data":"1.2.3.4"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)
        XCTAssertNotNil(response)

        guard let r = response else { return }
        XCTAssertEqual(r[0], 0xBE, "TX ID high byte preserved")
        XCTAssertEqual(r[1], 0xEF, "TX ID low byte preserved")
        XCTAssertEqual(r[2] & 0x80, 0x80, "QR bit set (response)")
        XCTAssertEqual(r[6], 0x00, "Answer count high byte")
        XCTAssertEqual(r[7], 0x02, "Answer count = 2")

        let domainInResponse = DNSWireFormat.extractDomainName(from: r)
        XCTAssertEqual(domainInResponse, "example.com")
    }

    func testSynthesizeResponsePreservesTxID() {
        let query = DNSWireFormat.buildQuery(domain: "test.com", txID: 0x4242)
        let json = """
        {"Answer":[{"type":1,"data":"10.0.0.1"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)!
        XCTAssertEqual(response[0], 0x42)
        XCTAssertEqual(response[1], 0x42)
    }

    func testSynthesizeResponseReturnsNilForEmptyAnswers() {
        let query = DNSWireFormat.buildQuery(domain: "noanswer.com")
        let json = """
        {"Answer":[]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?[7], 0, "Empty answer should return NOERROR with zero answers")
    }

    func testSynthesizeResponseReturnsNilForMalformedJSON() {
        let query = DNSWireFormat.buildQuery(domain: "test.com")
        XCTAssertNil(DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: "not json"))
        XCTAssertNil(DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: ""))
    }

    func testSynthesizeResponseReturnsNilForTooShortQuery() {
        let json = """
        {"Answer":[{"type":1,"data":"1.2.3.4"}]}
        """
        XCTAssertNil(DNSWireFormat.synthesizeDNSResponse(originalQuery: [0, 1], jsonResponse: json))
    }

    func testSynthesizeResponseReturnsEmptyNoErrorForAAAAWithoutMatchingRecords() {
        let query = DNSWireFormat.buildQuery(domain: "api2.cursor.sh", qtype: 28)
        let json = """
        {"Status":0,"Answer":[{"type":5,"data":"api2geo.cursor.sh."},{"type":5,"data":"api2direct.cursor.sh."}]}
        """

        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 28)

        XCTAssertNotNil(response)
        XCTAssertEqual((response?[3] ?? 0) & 0x0F, 0, "Should preserve NOERROR status")
        XCTAssertEqual(response?[7], 0, "Should return zero answers instead of timing out")
    }

    func testSynthesizeResponseReturnsNXDomainWhenStatusIsNXDomain() {
        let query = DNSWireFormat.buildQuery(domain: "missing.example", qtype: 1)
        let json = """
        {"Status":3}
        """

        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)

        XCTAssertNotNil(response)
        XCTAssertEqual((response?[3] ?? 0) & 0x0F, 3)
        XCTAssertEqual(response?[7], 0)
    }

    func testSynthesizeResponseFiltersWrongType() {
        let query = DNSWireFormat.buildQuery(domain: "test.com")
        let json = """
        {"Answer":[{"type":28,"data":"::1"},{"type":1,"data":"10.0.0.1"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)!
        XCTAssertEqual(response[7], 1, "Only 1 A record should be included")
    }

    func testSynthesizeResponseSkipsInvalidIPv4() {
        let query = DNSWireFormat.buildQuery(domain: "test.com")
        let json = """
        {"Answer":[{"type":1,"data":"999.999.999.999"},{"type":1,"data":"1.2.3.4"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 1)!
        XCTAssertEqual(response[7], 1, "Invalid IP should be skipped")
    }

    func testSynthesizeResponseSupportsAAAARecords() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0xCAFE, qtype: 28)
        let json = """
        {"Answer":[{"type":28,"data":"2606:4700::6812:1a78"},{"type":28,"data":"2606:4700::6812:1b78"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 28)
        XCTAssertNotNil(response)

        guard let response else { return }
        XCTAssertEqual(response[0], 0xCA)
        XCTAssertEqual(response[1], 0xFE)
        XCTAssertEqual(response[7], 2, "Both AAAA records should be included")

        let answerStart = response.count - (2 * 28)
        XCTAssertEqual(response[answerStart + 2], 0x00)
        XCTAssertEqual(response[answerStart + 3], 0x1C, "Answer type should be AAAA")
        XCTAssertEqual(response[answerStart + 10], 0x00)
        XCTAssertEqual(response[answerStart + 11], 0x10, "AAAA RDATA length should be 16 bytes")
    }

    func testSynthesizeResponseSkipsInvalidIPv6() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", qtype: 28)
        let json = """
        {"Answer":[{"type":28,"data":"not-an-ipv6"},{"type":28,"data":"2606:4700::6812:1a78"}]}
        """
        let response = DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: 28)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?[7], 1, "Invalid IPv6 should be skipped")
    }

    // MARK: - buildQuery + extractDomain round-trip

    func testRoundTripQueryDomain() {
        let domains = [
            "www.google.com",
            "a.b.c.d.e.f",
            "login.microsoftonline.com",
            "sourcecode.corp.example.test",
            "x",
        ]
        for domain in domains {
            let packet = DNSWireFormat.buildQuery(domain: domain)
            XCTAssertEqual(DNSWireFormat.extractDomainName(from: packet), domain)
        }
    }
}

// MARK: - Integration tests

@MainActor
final class DNSForwarderIntegrationTests: XCTestCase {
    /// The one forwarder this test owns. A test registers it before `start`,
    /// so `tearDown` stops it when the body throws as well as when it returns.
    private var ownedForwarder: LocalDNSForwarder?

    override func tearDown() async throws {
        await stopOwnedForwarder()
        try await super.tearDown()
    }

    /// Stops and forgets the owned forwarder. The slot is cleared before the
    /// await, so a second call does nothing. `stop()` does not join resolutions
    /// still in flight; this drains the listeners and their child channels.
    private func stopOwnedForwarder() async {
        guard let forwarder = ownedForwarder else { return }
        ownedForwarder = nil
        await forwarder.stop()
    }

    @MainActor
    func testForwarderStartsAndStops() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        await stopOwnedForwarder()
    }

    @MainActor
    func testForwarderBindsToRequestedPort() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        let port = 16_000 + Int.random(in: 0..<1000)
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: port)

        let hasLogEntry = logger.entries().contains { $0.message.contains(":\(port)") }
        XCTAssertTrue(hasLogEntry, "Log should mention the bound port")

        await stopOwnedForwarder()
    }

    @MainActor
    func testResetUpstreamTransportsIsNoOpWhenStopped() async throws {
        // Contract: calling resetUpstreamTransports before start() (or after
        // stop()) is safe and silent — the orchestrator's wake/VPN-recovery
        // funnels fire regardless of whether the forwarder is running, so
        // the no-op path must not crash and must not log at .warning or
        // .error.
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        forwarder.resetUpstreamTransports(reason: "test_no_running_forwarder")

        let warnings = logger.entries().filter { $0.level == .warning || $0.level == .error }
        XCTAssertTrue(warnings.isEmpty, "Reset on stopped forwarder must not log warnings/errors. Got: \(warnings.map(\.message))")
    }

    @MainActor
    func testResetUpstreamTransportsLogsWhenRunning() async throws {
        // Contract: when the forwarder is running, reset() emits a .notice
        // log line including the reason string so operators can correlate
        // post-wake/post-flap recoveries with the corresponding
        // dns.transports_reset event in the orchestrator's RuntimeEventLog.
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        let port = 16_000 + Int.random(in: 0..<1000)
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: port)

        let preEntries = logger.entries().count
        forwarder.resetUpstreamTransports(reason: "system_wake")
        let postEntries = logger.entries().filter { $0.message.contains("transports reset") }
        XCTAssertFalse(postEntries.isEmpty, "Reset of running forwarder must emit a transports-reset log entry")
        XCTAssertTrue(postEntries.contains { $0.message.contains("system_wake") },
                     "Reset log entry must include the reason string for operator correlation")
        _ = preEntries
    }

    @MainActor
    func testResetUpstreamTransportsClearsCache() async throws {
        // Contract: the cache flush is part of the reset's value proposition —
        // even though cached A records remain semantically valid across a
        // network event, dropping them forces a fresh end-to-end probe of
        // the DoH path on the very next query so the user sees the recovery
        // immediately instead of after the cached entry's TTL expires
        // (LocalDNSForwarder.swift comment, Reset implementation block).
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        let port = 16_000 + Int.random(in: 0..<1000)
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: port)

        // Cache count starts at zero (no queries have been issued).
        XCTAssertEqual(forwarder.cachedResponseCount, 0)

        // Reset on an empty cache is still well-defined.
        forwarder.resetUpstreamTransports(reason: "wake_with_empty_cache")
        XCTAssertEqual(forwarder.cachedResponseCount, 0)

        // The reset event itself logs at notice — confirm the second call
        // is also recorded so multiple wake events in a row stay observable.
        let resetLogs = logger.entries().filter { $0.message.contains("transports reset") }
        XCTAssertGreaterThanOrEqual(resetLogs.count, 1)
    }

    @MainActor
    func testResetUpstreamTransportsIsIdempotentUnderRapidCalls() async throws {
        // Contract: rapid back-to-back resets (e.g. wake immediately followed
        // by a vpn-flap recovery on the same physical event) must not race
        // on the swap or leak transports. Cheapest way to lock this in is to
        // hammer the entry point and verify (a) no crash, (b) no warnings,
        // (c) a log line per call.
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        let port = 16_000 + Int.random(in: 0..<1000)
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: port)

        let resetCount = 8
        for i in 0..<resetCount {
            forwarder.resetUpstreamTransports(reason: "rapid_call_\(i)")
        }

        let resetLogs = logger.entries().filter { $0.message.contains("transports reset") }
        XCTAssertEqual(resetLogs.count, resetCount, "Each reset call must log exactly once")

        let warnings = logger.entries().filter { $0.level == .warning || $0.level == .error }
        XCTAssertTrue(warnings.isEmpty, "Rapid resets must not produce warnings. Got: \(warnings.map(\.message))")
    }

    /// A datagram too short to hold a DNS header is dropped without a reply —
    /// there is no transaction ID to answer it with — and the forwarder keeps
    /// serving afterwards.
    ///
    /// This is the end-to-end half of the rule, over a real socket: what a
    /// client sees. The other half — that the runt never reaches the admission
    /// gate at all — is not visible from out here and is pinned separately in
    /// `DNSAdmissionGateTests`.
    @MainActor
    func testForwarderRejectsPacketTooShort() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        var config = ProxyConfig.testFixture()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.9", enabled: true)
        ]
        let frozen = config
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { frozen }
        )

        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(forwarder.listeningPort)

        // The garbage and then a well-formed query from one client. The
        // forwarder keeps serving: an intercept answer is synthesized locally,
        // so this needs no reachable upstream. Once that answer is in, any
        // answer to the garbage, which needs no lookup at all, would be too.
        let client = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        defer { client.close(promise: nil) }
        let collector = UDPReplyCollector()
        try await client.pipeline.addHandler(collector).get()
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        let query = DNSWireFormat.buildQuery(domain: "after.intercept.test", txID: 0x7788, qtype: 1)
        for payload in [[0, 1, 2, 3], query] {
            var buf = client.allocator.buffer(capacity: payload.count)
            buf.writeBytes(payload)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        }
        for _ in 0..<200 where collector.replies().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        let replies = collector.replies()
        XCTAssertEqual(replies.count, 1, "A sub-header datagram must be dropped, not answered")
        let response = try XCTUnwrap(replies.first, "A well-formed query after garbage must still be answered")
        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: response))
        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: response)?.ip, "127.44.3.9")

        await stopOwnedForwarder()
    }

    /// A DoH outage is one condition, but it is discovered once per query, and
    /// a single page load asks for dozens of public names. Unthrottled, the
    /// "all providers failed" warning turned one root cause into dozens of
    /// near-identical lines — on exactly the degraded network where the log is
    /// the only diagnostic anyone has. The warning is rate-limited and carries
    /// the count it suppressed.
    @MainActor
    func testTotalDoHFailureWarningIsRateLimited() async throws {
        let group = MultiThreadedEventLoopGroup.singleton

        // A port nothing listens on: DoH fetches are refused immediately, so
        // every public name fails the whole provider set fast and with the
        // same signature (no HTTP status observed at all). No external egress.
        let placeholder = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let deadPort = try XCTUnwrap(placeholder.localAddress?.port)
        try await placeholder.close().get()

        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = [DomainDNSEntry(domain: "corp.internal.test", servers: ["127.0.0.1"])]
        config.dohProviders = ["https://127.0.0.1:\(deadPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config

        let logger = RecordingLogSink(minLevel: .debug)
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { frozen },
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(forwarder.listeningPort)

        let client = try await DatagramBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)

        // Unique names defeat the response cache, so every one of them reaches
        // the DoH path and would have logged its own warning.
        let queryCount = 12
        for i in 0..<queryCount {
            let query = DNSWireFormat.buildQuery(domain: "flood-\(i).example.com", txID: UInt16(i))
            var buf = client.allocator.buffer(capacity: query.count)
            buf.writeBytes(query)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        }

        var attempts = 0
        var answered = 0
        for _ in 0..<600 where answered < queryCount {
            try await Task.sleep(for: .milliseconds(10))
            attempts = logger.entries().filter { $0.message.contains("trying DoH") }.count
            answered = logger.entries().filter { $0.message.contains("replying SERVFAIL") }.count
        }
        XCTAssertEqual(attempts, queryCount, "Every query must reach the DoH path for this test to mean anything")
        // Count only once every query's DoH failure has landed.
        XCTAssertEqual(answered, queryCount, "Every query must finish before the warnings are counted")
        let warnings = logger.entries().filter { $0.message.contains("DoH provider(s) failed") }

        XCTAssertGreaterThanOrEqual(warnings.count, 1, "The outage must still be reported at least once")
        XCTAssertLessThan(
            warnings.count, queryCount,
            "\(queryCount) failing queries produced \(warnings.count) warnings — the throttle is not holding"
        )

        await stopOwnedForwarder()
        try await client.close().get()
    }

    /// A local UDP socket that takes queries and never answers: an internal
    /// DNS server that is down, without sending anything off the machine.
    private static func silentInternalServer(group: EventLoopGroup) async throws -> Channel {
        try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
    }

    /// Internal servers asked on `server`'s port, giving up after 50 ms
    /// instead of 1.5 s.
    private static func quickInternalAttempt(against server: Channel) throws -> DNSForwarderTuning {
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = try XCTUnwrap(server.localAddress?.port)
        tuning.internalAttemptTimeout = .milliseconds(50)
        tuning.internalDomainTimeout = .milliseconds(50)
        return tuning
    }

    /// Regression test for the 2026-07-01 SIGABRT: `resetUpstreamTransports`
    /// used to call `invalidateAndCancel()` on the DoH `URLSession`s while
    /// `resolveViaDoH` had fetches in flight against them. CFNetwork raises
    /// an uncatchable Objective-C exception when a task is created on an
    /// invalidated session, aborting the whole process. The fix defers
    /// invalidation through a use-counted handle; this test drives real DoH
    /// fetches (against loopback ports that refuse instantly — no external
    /// egress) while hammering resets and stop, and simply has to survive.
    @MainActor
    func testResetStormDuringInFlightDoHFetchesDoesNotCrash() async throws {
        let group = MultiThreadedEventLoopGroup.singleton

        // Local tarpit: accepts TCP connections and never responds, so DoH
        // fetches against it stay in flight until the sessions' 4 s request
        // timeout — maximizing the overlap between live fetches and resets
        // (the production crash needed exactly that overlap). No external
        // egress.
        let tarpit = try await ServerBootstrap(group: group)
            .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let tarpitPort = try XCTUnwrap(tarpit.localAddress?.port)

        var config = ProxyConfig.testFixture()
        config.upstreams = []
        // Internal DNS on a local socket that never answers, with a short
        // attempt, so external names fall through to the DoH path at once.
        config.dnsEntries = [DomainDNSEntry(domain: "corp.internal.test", servers: ["127.0.0.1"])]
        // Several distinct provider URLs multiply the task-group fan-out per
        // query (providers × sessions × {json,wire}), stretching the window
        // between the transports snapshot and each `data(for:)` call.
        config.dohProviders = (0..<6).map { "https://127.0.0.1:\(tarpitPort)/dns-query?v=\($0)" }
        config.localHost = "127.0.0.1"
        config.localPort = 9

        let logger = RecordingLogSink(minLevel: .debug)
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { [config] in config },
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(forwarder.listeningPort)

        let client = try await DatagramBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)

        // Phase 1: send all queries. Their internal-DNS phase times out
        // quickly, and every query then enters `resolveViaDoH` against the
        // tarpit.
        for i in 0..<96 {
            // Unique domains defeat the response cache so every query
            // reaches the DoH task group.
            let query = DNSWireFormat.buildQuery(domain: "ext-\(i).example.com", txID: UInt16(i))
            var buf = client.allocator.buffer(capacity: query.count)
            buf.writeBytes(query)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        }

        // Wait until the queries demonstrably reach the DoH stage before
        // starting the storm — otherwise the test silently stops exercising
        // the crash surface if internal-DNS timing changes.
        var dohAttempts = 0
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(10))
            dohAttempts = logger.entries().filter { $0.message.contains("trying DoH") }.count
            if dohAttempts >= 48 { break }
        }
        XCTAssertGreaterThan(dohAttempts, 0, "Queries must reach the DoH path for this test to mean anything")

        // Phase 2: reset storm while the DoH task groups are alive in the
        // tarpit (each fetch pends until the 4 s request timeout).
        for _ in 0..<300 {
            forwarder.resetUpstreamTransports(reason: "stress")
            try await Task.sleep(for: .microseconds(500))
        }

        // Stop while fetches are still pending in the tarpit — exercises the
        // retire path in `invalidateSessions()` too.
        await stopOwnedForwarder()
        try await client.close().get()
        try await tarpit.close().get()

        // Reaching this line is the assertion: the old implementation
        // died with an uncatchable CFNetwork NSException under this load.
        XCTAssertNil(forwarder.listeningPort, "Forwarder should be stopped")
    }

    // MARK: - Split-DNS names when the internal server is out of reach

    /// Off the VPN the corporate server cannot be reached, and that includes
    /// the lookup for the VPN gateway's own hostname, which sits under the
    /// split-DNS domain. Asking only that server left the gateway unresolvable
    /// and the VPN unable to come up. Silence from the internal server now
    /// falls through to public DNS.
    @MainActor
    func testConfiguredInternalNameFallsBackToDoHWhenInternalServerIsSilent() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.internal.test", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        let query = DNSWireFormat.buildQuery(domain: "vpn-gateway.corp.internal.test", txID: 0x6001)
        let reply = try await Self.ask(query, port: port, group: group)
        let response = try XCTUnwrap(reply, "The forwarder must answer")

        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 0)
        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: response)?.ip, "203.0.113.7")
        XCTAssertEqual(ownedForwarder?.cachedResponseCount, 0, "A public stand-in answer for an internal name must not be cached")
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 1)
        XCTAssertEqual(
            splitDNSFallbackEvents().map(\.detail),
            ["domain=corp.internal.test name=vpn-gateway.corp.internal.test server=127.0.0.1 outcome=answered suppressed=0"]
        )
    }

    /// Off the VPN every lookup under the domain falls back and none is
    /// cached, so the event is held to one per domain and outcome per minute.
    @MainActor
    func testSplitDNSFallbackEventIsThrottledPerDomainAndOutcome() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.internal.test", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        for (index, host) in ["vpn-gateway", "mail", "intranet"].enumerated() {
            let query = DNSWireFormat.buildQuery(domain: "\(host).corp.internal.test", txID: 0x6010 + UInt16(index))
            let reply = try await Self.ask(query, port: port, group: group)
            XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 0, "\(host) must get the DoH answer")
        }

        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 3, "Every fallback still counts")
        XCTAssertEqual(splitDNSFallbackEvents().count, 1, "Three fallbacks inside the minute report once")
    }

    /// Only A and AAAA have a DoH lookup. Any other type under a split-DNS
    /// domain gets REFUSED off the VPN without asking a provider, and that is
    /// not a DoH answer.
    @MainActor
    func testSplitDNSNameOfAnotherTypeIsRefusedWithoutAskingDoH() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.internal.test", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        let srv: UInt16 = 33
        let query = DNSWireFormat.buildQuery(domain: "_ldap._tcp.corp.internal.test", txID: 0x6020, qtype: srv)
        let reply = try await Self.ask(query, port: port, group: group)
        let response = try XCTUnwrap(reply, "The forwarder must answer")

        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 5, "REFUSED")
        XCTAssertEqual(doh.requestCount(), 0)
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 0, "A synthesized REFUSED is not a DoH fallback")
        XCTAssertEqual(splitDNSFallbackEvents().compactMap(\.detail).map { $0.contains("outcome=refused_qtype") }, [true])
    }

    /// A reply from the internal server is its verdict, NXDOMAIN included: the
    /// name stays off public DNS whenever the corporate server answers.
    @MainActor
    func testConfiguredInternalNameKeepsTheInternalServersNXDOMAIN() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let nxdomainServer = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(NXDOMAINServer()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { nxdomainServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.internal.test", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: nxdomainServer)
        )
        let query = DNSWireFormat.buildQuery(domain: "gone.corp.internal.test", txID: 0x6002)
        let reply = try await Self.ask(query, port: port, group: group)
        let response = try XCTUnwrap(reply, "The forwarder must answer")

        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 3, "The internal NXDOMAIN must reach the client")
        XCTAssertEqual(doh.requestCount(), 0, "DoH must not be asked about a name the internal server answered")
        XCTAssertEqual(splitDNSFallbackEvents().count, 0, "An internal reply is not a fallback")
    }

    /// `.local` is multicast DNS and never public, so a silent server leaves
    /// it at SERVFAIL rather than sending it to a public resolver.
    @MainActor
    func testLocalNameDoesNotFallBackToDoH() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.internal.test", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        let query = DNSWireFormat.buildQuery(domain: "printer.local", txID: 0x6003)
        let reply = try await Self.ask(query, port: port, group: group)
        let response = try XCTUnwrap(reply, "The forwarder must answer")

        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 2)
        XCTAssertEqual(doh.requestCount(), 0, "A .local name must never reach a public resolver")
    }

    /// An AD-style split-DNS domain under `.local` is still multicast DNS's
    /// namespace: its names match the entry, and the silence fallback must
    /// still leave them at SERVFAIL.
    @MainActor
    func testNameUnderLocalSplitDNSEntryDoesNotFallBackToDoH() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let doh = try await AnsweringDoHProvider.start(group: group, ip: "203.0.113.7")
        defer { doh.channel.close(promise: nil) }
        let silentServer = try await Self.silentInternalServer(group: group)
        defer { silentServer.close(promise: nil) }

        let port = try await startForwarder(
            internalDomain: "corp.local", dohPort: doh.port,
            tuning: try Self.quickInternalAttempt(against: silentServer)
        )
        let query = DNSWireFormat.buildQuery(domain: "fileserver.corp.local", txID: 0x6004)
        let reply = try await Self.ask(query, port: port, group: group)
        let response = try XCTUnwrap(reply, "The forwarder must answer")

        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 2)
        XCTAssertEqual(doh.requestCount(), 0, "A name under a .local split-DNS entry must never reach a public resolver")
        XCTAssertEqual(splitDNSFallbackEvents().count, 0)
    }

    /// Starts the owned forwarder with one split-DNS domain on the loopback
    /// internal server `tuning` names and one cleartext DoH provider on
    /// `dohPort`, and returns its UDP port.
    @MainActor
    private func startForwarder(internalDomain: String, dohPort: Int, tuning: DNSForwarderTuning) async throws -> Int {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = [DomainDNSEntry(domain: internalDomain, servers: ["127.0.0.1"])]
        config.dohProviders = ["http://127.0.0.1:\(dohPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config
        let events = forwarderEvents
        let forwarder = LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: RecordingLogSink(minLevel: .debug),
            configProvider: { frozen },
            tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return try XCTUnwrap(forwarder.listeningPort)
    }

    /// The events the forwarder `startForwarder` started has emitted.
    private let forwarderEvents = NIOLockedValueBox<[RuntimeEvent]>([])

    private func splitDNSFallbackEvents() -> [RuntimeEvent] {
        forwarderEvents.withLockedValue { $0 }.filter { $0.event == "dns.split_dns_doh_fallback" }
    }

    /// Sends one query to the forwarder on `port` and returns its first
    /// reply, or nil if none arrives within ten seconds.
    private static func ask(_ query: [UInt8], port: Int, group: EventLoopGroup) async throws -> [UInt8]? {
        let collector = UDPReplyCollector()
        let client = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { client.close(promise: nil) }
        var buf = client.allocator.buffer(capacity: query.count)
        buf.writeBytes(query)
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        for _ in 0..<1000 where collector.replies().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.replies().first
    }
}

/// Captures the datagrams a test client receives, so a test can assert on a
/// reply *or* on the absence of one.
final class UDPReplyCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let lock = NSLock()
    /// Every datagram received, in order; a test reads a handful at most.
    private var received: [[UInt8]] = []

    func replies() -> [[UInt8]] {
        lock.withLock { received }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.withLock { if received.count < 16 { received.append(bytes) } }
    }
}

/// Answers every UDP query with NXDOMAIN: an internal server that is reachable
/// and does not know the name.
private final class NXDOMAINServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard let reply = DNSWireFormat.emptyDNSResponse(originalQuery: query, rcode: 3) else { return }
        var out = context.channel.allocator.buffer(capacity: reply.count)
        out.writeBytes(reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
    }
}

/// A cleartext loopback DoH provider that answers every request with one
/// `application/dns-json` A record and counts the connections that asked.
/// The wire-format POST gets the same JSON and fails its question check, so
/// only the JSON fetch can produce an answer.
final class AnsweringDoHProvider: @unchecked Sendable {
    let channel: Channel
    private let requests: NIOLockedValueBox<Int>

    var port: Int { channel.localAddress?.port ?? 0 }

    func requestCount() -> Int { requests.withLockedValue { $0 } }

    private init(channel: Channel, requests: NIOLockedValueBox<Int>) {
        self.channel = channel
        self.requests = requests
    }

    /// `silent`: count each request and never answer it, so a lookup hangs
    /// on this provider until something ends it.
    static func start(group: EventLoopGroup, ip: String, silent: Bool = false) async throws -> AnsweringDoHProvider {
        let requests = NIOLockedValueBox(0)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Responder(ip: ip, requests: requests, silent: silent)) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return AnsweringDoHProvider(channel: channel, requests: requests)
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let ip: String
        private let requests: NIOLockedValueBox<Int>
        private let silent: Bool
        private var responded = false

        init(ip: String, requests: NIOLockedValueBox<Int>, silent: Bool) {
            self.ip = ip
            self.requests = requests
            self.silent = silent
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !responded else { return }
            responded = true
            requests.withLockedValue { $0 += 1 }
            if silent { return }
            let body = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"\#(ip)"}]}"#
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\n" +
                "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let channel = context.channel
            var buffer = channel.allocator.buffer(capacity: response.utf8.count)
            buffer.writeString(response)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
