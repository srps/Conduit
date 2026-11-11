// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The forwarder reads its split-DNS table from the provider it was given, not from config (decision 0044), and a
/// public name keeps its one attempt on the table's first server before DoH (decision 9).
final class DNSForwarderSplitDNSProviderTests: XCTestCase {
    private let corpIP = "198.51.100.10"
    private let publicIP = "203.0.113.7"
    private let detected = SplitDNSTable(manual: [], detected: [
        SplitDNSRule(domain: "corp.example", servers: ["192.0.2.53"], origins: [.detected(interface: "utun6")]),
    ])

    private struct Running {
        let table: NIOLockedValueBox<SplitDNSTable>
        let corp: FakeSplitDNSServer
        let doh: AnsweringDoHProvider
        let port: Int
    }

    /// A forwarder whose config has no split-DNS entry. `provided` false builds it with `configProvider` only.
    /// The corp server answers names under `corpAnswers` and NXDOMAIN for the rest.
    private func start(
        table initial: SplitDNSTable = .empty, provided: Bool = true, corpAnswers: String = "corp.example",
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) async throws -> Running {
        let group = MultiThreadedEventLoopGroup.singleton
        let corp = try await FakeSplitDNSServer.start(domain: corpAnswers, ip: corpIP)
        let doh = try await AnsweringDoHProvider.start(group: group, ip: publicIP)
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = []
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        configure(&config)
        let frozen = config
        let table = NIOLockedValueBox(initial)
        let read: @Sendable () -> SplitDNSTable = { table.withLockedValue { $0 } }
        let provider = provided ? read : nil
        let forwarder = LocalDNSForwarder(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            splitDNSProvider: provider,
            tuning: SplitDNSProbe.tuning(["192.0.2.53": corp.port])
        )
        try await forwarder.start(host: "127.0.0.1", port: 0)
        addTeardownBlock {
            await forwarder.stop()
            await corp.stop()
            try? await doh.channel.close()
        }
        return Running(table: table, corp: corp, doh: doh, port: try XCTUnwrap(forwarder.listeningPort))
    }

    func testATablePushedWithNoConfigChangeRoutesTheNextQuery() async throws {
        let running = try await start()
        let before = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(before, publicIP)
        XCTAssertEqual(running.corp.totalQueries, 0, "an empty table asks no split-DNS server")
        let publicRequests = running.doh.requestCount()
        XCTAssertGreaterThan(publicRequests, 0)

        running.table.withLockedValue { $0 = detected }
        let after = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(after, corpIP, "the public answer cached before the swap is not served after it")
        XCTAssertEqual(running.corp.queryCount("host.corp.example"), 1)
        XCTAssertEqual(running.doh.requestCount(), publicRequests, "the lookup after the swap did not reach DoH")
    }

    func testWithoutAProviderAManualEntryRoutesToItsServer() async throws {
        let running = try await start(provided: false) {
            $0.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.53"])]
        }

        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(answer, corpIP)
        XCTAssertEqual(running.doh.requestCount(), 0)
    }

    func testAPublicNameGetsOneAttemptOnTheDetectedFirstServerThenDoH() async throws {
        let running = try await start(table: detected)

        let answer = try await SplitDNSProbe.resolve("www.example.com", port: running.port)

        XCTAssertEqual(answer, publicIP, "the server's NXDOMAIN sends the name to DoH")
        XCTAssertEqual(running.corp.queryCount("www.example.com"), 1)
        XCTAssertGreaterThan(running.doh.requestCount(), 0)
    }

    func testAPublicNameTheDetectedFirstServerAnswersSkipsDoH() async throws {
        let running = try await start(table: detected, corpAnswers: "example.com")

        let answer = try await SplitDNSProbe.resolve("www.example.com", port: running.port)

        XCTAssertEqual(answer, corpIP)
        XCTAssertEqual(running.doh.requestCount(), 0)
    }

    func testACachedAnswerAndAnInterceptRuleWinBeforeTheAttempt() async throws {
        let running = try await start(table: detected) {
            $0.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercept.example", interceptIP: "127.44.3.9")]
        }

        let first = try await SplitDNSProbe.resolve("www.example.com", port: running.port)
        let second = try await SplitDNSProbe.resolve("www.example.com", port: running.port)
        let intercepted = try await SplitDNSProbe.resolve("app.intercept.example", port: running.port)

        XCTAssertEqual([first, second], [publicIP, publicIP])
        XCTAssertEqual(running.corp.queryCount("www.example.com"), 1, "the cached answer is served without a second attempt")
        XCTAssertEqual(intercepted, "127.44.3.9")
        XCTAssertEqual(running.corp.queryCount("app.intercept.example"), 0)
    }
}
