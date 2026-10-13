// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACRouteBoundsTests: XCTestCase {
    private let adapter = CFPACEvaluator()

    func testDirectBoundaryOrderAndRejectedEntries() {
        let limit = 3
        let proxies = (1...5).map { "PROXY p\($0).example:8080" }
        let cases: [([String], [PACRoute], Int, Bool)] = [
            (["DIRECT"] + proxies, [.direct, .proxy(host: "p1.example", port: 8080), .proxy(host: "p2.example", port: 8080)], 3, false),
            (Array(proxies.prefix(2)) + ["DIRECT"], [.proxy(host: "p1.example", port: 8080), .proxy(host: "p2.example", port: 8080), .direct], 0, false),
            (Array(proxies.prefix(3)) + ["DIRECT"], (1...3).map { .proxy(host: "p\($0).example", port: 8080) }, 1, false),
            (["SOCKS s.example:1080", "PROXY bad:99999", "DIRECT"] + proxies, [.direct, .proxy(host: "p1.example", port: 8080), .proxy(host: "p2.example", port: 8080)], 3, true),
        ]
        for (entries, routes, dropped, promoted) in cases {
            let chain = adapter.routeChain(for: entries).limited(to: limit)
            XCTAssertEqual(chain.routes, routes)
            XCTAssertEqual(chain.droppedRouteCount, dropped)
            XCTAssertEqual(chain.leadingDirectPromoted, promoted)
            let strict = PACRoutePlan(decision: PACDecision(chain: chain), config: ProxyConfig(), directFallbackAllowed: false)
            XCTAssertFalse(strict.hasDirectFallback)
            let relaxed = PACRoutePlan(decision: PACDecision(chain: chain), config: ProxyConfig(), directFallbackAllowed: true)
            if routes.first == .direct {
                XCTAssertEqual(relaxed, .direct)
                if promoted {
                    XCTAssertEqual(strict.proxyChain.count, 2, "strict mode must suppress promoted DIRECT while retaining the proxies")
                } else {
                    XCTAssertEqual(strict, .direct, "an explicit leading DIRECT keeps its existing precedence")
                }
            } else {
                XCTAssertEqual(relaxed.hasDirectFallback, routes.contains(.direct))
            }
            XCTAssertLessThanOrEqual(strict.proxyChain.count, limit)
        }
        let rejected = adapter.routeChain(for: ["SOCKS s:1", "PROXY bad:99999"]).limited(to: 1)
        XCTAssertEqual(PACDecision(chain: rejected), .noUsableAnswer(.unsupported, rejected: rejected.rejected))
    }

    func testThousandsOfUsableAndRejectedEntriesAndConstructionCeiling() {
        let entries = (0..<2_000).flatMap { ["PROXY p\($0).example:8080", "SOCKS s:1"] } + ["DIRECT"]
        let chain = adapter.routeChain(for: entries).limited(to: 32)
        XCTAssertEqual(chain.routes, (0..<32).map { .proxy(host: "p\($0).example", port: 8080) })
        XCTAssertEqual(chain.droppedRouteCount, 1_969)
        XCTAssertEqual(chain.rejected.total, 2_000)
        XCTAssertEqual(chain.rejected.count, PACRejections.retainedLimit)
        XCTAssertFalse(chain.routes.contains(.direct))
        let constructed = PACChain(routes: Array(repeating: .direct, count: 2_000))
        XCTAssertEqual(constructed.routes.count, ProxyConfig.maximumPACUsableRouteLimit)
        XCTAssertEqual(constructed.limited(to: 1).droppedRouteCount, 1_999)
    }

    func testConfigDefaultRoundTripAndValidation() throws {
        let old = try CanonicalJSON.decoder().decode(ProxyConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old.pacUsableRouteLimit, 32)
        var config = old
        for limit in [1, 77, 128] {
            config.pacUsableRouteLimit = limit
            XCTAssertFalse(config.validate().contains { $0.localizedDescription.contains("pacUsableRouteLimit") })
            let decoded = try CanonicalJSON.decoder().decode(ProxyConfig.self, from: CanonicalJSON.encoder().encode(config))
            XCTAssertEqual(decoded.pacUsableRouteLimit, limit)
        }
        for limit in [0, 129] {
            config.pacUsableRouteLimit = limit
            XCTAssertTrue(config.validate().contains { $0.blocksProxyStart && $0.localizedDescription.contains("pacUsableRouteLimit") })
        }
    }

    func testLimitAppliesOnReadWithoutReevaluatingOrInvalidating() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        var initial = ProxyConfig()
        initial.pacRoutingEnabled = true; initial.pacURL = "https://pac.example/script"
        initial.pacUsableRouteLimit = 2
        let config = NIOLockedValueBox(initial)
        let events = RuntimeEventLog(capacity: 32)
        let pac = LargePAC()
        let engine = PACRoutingEngine(configProvider: { config.withLockedValue { $0 } }, resolver: pac,
            eventSink: { events.append($0) }, now: { clock.withLockedValue { $0 } })
        try await engine.refresh(force: true)
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let url = "https://target.example/1"
        let first = try await engine.decisionFuture(for: url, host: "target.example", on: loop).get()
        XCTAssertEqual(first.routes.count, 2)
        config.withLockedValue { $0.pacUsableRouteLimit = 100 }
        let raised = try await engine.decisionFuture(for: url, host: "target.example", on: loop).get()
        XCTAssertEqual(raised.routes.count, 100)
        config.withLockedValue { $0.pacUsableRouteLimit = 1 }
        XCTAssertEqual(engine.decision(for: url, host: "target.example").routes.count, 1)
        XCTAssertEqual(pac.evaluations.withLockedValue { $0 }, 1, "a limit change trims the cached answer")
        XCTAssertFalse(events.events.contains { $0.event == "pac.routes_invalidated" })

        // Truncation is reported per evaluation, coalesced to one a minute.
        _ = engine.decision(for: "https://target.example/2", host: "target.example")
        clock.withLockedValue { $0 += 60 }
        _ = engine.decision(for: "https://target.example/3", host: "target.example")
        XCTAssertEqual(events.events.filter { $0.event == "pac.routes_truncated" }.map(\.detail), [
            "retained=2 dropped=1999 limit=2 suppressed=0",
            "retained=1 dropped=2000 limit=1 suppressed=1",
        ])
    }

    private final class LargePAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        let evaluations = NIOLockedValueBox(0)
        func fetchPAC(from _: String) async throws -> String { "fixture" }
        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for _: URL) throws -> [String] {
            evaluations.withLockedValue { $0 += 1 }
            return Array(repeating: "PROXY secret-fixture.example:8080", count: 2_000) + ["DIRECT"]
        }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }
}
