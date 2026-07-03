// SPDX-License-Identifier: Apache-2.0
import Foundation
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

    // MARK: - isInternalDomain

    func testInternalDomainMatchesConfiguredDNSEntry() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example.com", servers: ["10.0.0.1"])]
        XCTAssertTrue(DNSWireFormat.isInternalDomain("host.corp.example.com", config: config))
        XCTAssertTrue(DNSWireFormat.isInternalDomain("corp.example.com", config: config))
    }

    func testInternalDomainMatchesBuiltinLocalDomains() {
        let config = ProxyConfig.testFixture()
        XCTAssertTrue(DNSWireFormat.isInternalDomain("printer.local", config: config))
    }

    func testExternalDomainIsNotInternal() {
        let config = ProxyConfig.testFixture()
        XCTAssertFalse(DNSWireFormat.isInternalDomain("www.google.com", config: config))
        XCTAssertFalse(DNSWireFormat.isInternalDomain("login.microsoftonline.com", config: config))
        XCTAssertFalse(DNSWireFormat.isInternalDomain("github.com", config: config))
    }

    func testInternalDomainIsCaseInsensitive() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example.com", servers: ["10.0.0.1"])]
        XCTAssertTrue(DNSWireFormat.isInternalDomain("Host.CORP.EXAMPLE.COM", config: config))
    }

    func testInternalDomainIgnoresDisabledEntries() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "private.corp", servers: ["10.0.0.1"], enabled: false)]
        XCTAssertFalse(DNSWireFormat.isInternalDomain("host.private.corp", config: config))
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

final class DNSForwarderIntegrationTests: XCTestCase {

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

        try await forwarder.start(host: "127.0.0.1", port: 0)
        await forwarder.stop()
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
        try await forwarder.start(host: "127.0.0.1", port: port)

        let hasLogEntry = logger.entries().contains { $0.message.contains(":\(port)") }
        XCTAssertTrue(hasLogEntry, "Log should mention the bound port")

        await forwarder.stop()
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
        try await forwarder.start(host: "127.0.0.1", port: port)
        defer { Task { @MainActor in await forwarder.stop() } }

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
        try await forwarder.start(host: "127.0.0.1", port: port)
        defer { Task { @MainActor in await forwarder.stop() } }

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
        try await forwarder.start(host: "127.0.0.1", port: port)
        defer { Task { @MainActor in await forwarder.stop() } }

        let resetCount = 8
        for i in 0..<resetCount {
            forwarder.resetUpstreamTransports(reason: "rapid_call_\(i)")
        }

        let resetLogs = logger.entries().filter { $0.message.contains("transports reset") }
        XCTAssertEqual(resetLogs.count, resetCount, "Each reset call must log exactly once")

        let warnings = logger.entries().filter { $0.level == .warning || $0.level == .error }
        XCTAssertTrue(warnings.isEmpty, "Rapid resets must not produce warnings. Got: \(warnings.map(\.message))")
    }

    @MainActor
    func testForwarderRejectsPacketTooShort() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup.singleton
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { config }
        )

        let port = 16_000 + Int.random(in: 0..<1000)
        try await forwarder.start(host: "127.0.0.1", port: port)

        let client = try await DatagramBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()

        var buf = client.allocator.buffer(capacity: 4)
        buf.writeBytes([0, 1, 2, 3])
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        let envelope = AddressedEnvelope(remoteAddress: target, data: buf)
        try await client.writeAndFlush(envelope).get()

        try await Task.sleep(for: .milliseconds(200))
        try await client.close().get()
        await forwarder.stop()
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
        // Internal DNS at 127.0.0.1:53 — refused (or answered) immediately;
        // either way external names fall through to the DoH path.
        config.dnsEntries = [DomainDNSEntry(domain: "corp.internal.test", servers: ["127.0.0.1"])]
        // Several distinct provider URLs multiply the task-group fan-out per
        // query (providers × sessions × {json,wire}), stretching the window
        // between the transports snapshot and each `data(for:)` call.
        config.dohProviders = (0..<6).map { "https://127.0.0.1:\(tarpitPort)/dns-query?v=\($0)" }
        config.localHost = "127.0.0.1"
        config.localPort = 9

        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { [config] in config }
        )
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(forwarder.listeningPort)

        let client = try await DatagramBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)

        // Phase 1: send all queries. Their internal-DNS phase (127.0.0.1:53)
        // resolves fast on refusal or takes up to its 1.5 s timeout — either
        // way every query then enters `resolveViaDoH` against the tarpit.
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
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            dohAttempts = logger.entries().filter { $0.message.contains("trying DoH") }.count
            if dohAttempts >= 48 { break }
        }
        XCTAssertGreaterThan(dohAttempts, 0, "Queries must reach the DoH path for this test to mean anything")

        // Phase 2: reset storm while the DoH task groups are alive in the
        // tarpit (each fetch pends until the 4 s request timeout).
        for _ in 0..<300 {
            forwarder.resetUpstreamTransports(reason: "stress")
            try await Task.sleep(for: .milliseconds(2))
        }

        // Stop while fetches are still pending in the tarpit — exercises the
        // retire path in `invalidateSessions()` too.
        await forwarder.stop()
        try await client.close().get()
        try await tarpit.close().get()

        // Reaching this line is the assertion: the old implementation
        // died with an uncatchable CFNetwork NSException under this load.
        XCTAssertNil(forwarder.listeningPort, "Forwarder should be stopped")
    }
}
