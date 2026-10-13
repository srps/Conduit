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
            let chain = adapter.routeChain(for: entries, limit: limit)
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
        let rejected = adapter.routeChain(for: ["SOCKS s:1", "PROXY bad:99999"], limit: 1)
        XCTAssertEqual(PACDecision(chain: rejected), .noUsableAnswer(.unsupported, rejected: rejected.rejected))
    }

    func testThousandsOfUsableAndRejectedEntriesAndConstructionCeiling() {
        let entries = (0..<2_000).flatMap { ["PROXY p\($0).example:8080", "SOCKS s:1"] } + ["DIRECT"]
        let chain = adapter.routeChain(for: entries, limit: 32)
        XCTAssertEqual(chain.routes, (0..<32).map { .proxy(host: "p\($0).example", port: 8080) })
        XCTAssertEqual(chain.droppedRouteCount, 1_969)
        XCTAssertEqual(chain.rejected.total, 2_000)
        XCTAssertEqual(chain.rejected.count, PACRejections.retainedLimit)
        XCTAssertFalse(chain.routes.contains(.direct))
        let constructed = PACChain(routes: Array(repeating: .direct, count: 2_000))
        XCTAssertEqual(constructed.routes.count, ProxyConfig.maximumPACUsableRouteLimit)
        XCTAssertEqual(constructed.limited(to: 1).droppedRouteCount, 1_999)
    }

    func testNativeAnswerUsesTheSameConfigurableBound() throws {
        let directives = Array(repeating: "PROXY corp.example:8080", count: 2_000) + ["DIRECT"]
        let script = "function FindProxyForURL(url, host) { return '\(directives.joined(separator: ";"))'; }"
        let evaluator = try adapter.makeEvaluator(pacScript: script)
        let entries = try evaluator.resolveProxyChain(for: URL(string: "https://target.example/")!)
        XCTAssertEqual(entries.count, 2_001)
        for limit in [1, 32, 128] {
            let chain = adapter.routeChain(for: entries, limit: limit)
            XCTAssertEqual(chain.routes.count, limit)
            XCTAssertEqual(chain.droppedRouteCount, 2_001 - limit)
            XCTAssertFalse(chain.routes.contains(.direct))
        }
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

    func testCachePolicyChangesAndBoundedDiagnosticsAcrossAsyncAndSyncPaths() async throws {
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
        let first = try await engine.decisionFuture(for: "https://target.example/1", host: "target.example", on: loop).get()
        XCTAssertEqual(first.routes.count, 2)
        let cached = try await engine.decisionFuture(for: "https://target.example/1", host: "target.example", on: loop).get()
        XCTAssertEqual(cached, first)
        XCTAssertEqual(pac.evaluations.withLockedValue { $0 }, 1, "cache hit must use the bounded chain")
        XCTAssertEqual(engine.decision(for: "https://target.example/2", host: "target.example").routes.count, 2)
        config.withLockedValue { $0.pacUsableRouteLimit = 100 }
        XCTAssertEqual(engine.decision(for: "https://target.example/1", host: "target.example").routes.count, 100)
        clock.withLockedValue { $0 += 60 }
        config.withLockedValue { $0.pacUsableRouteLimit = 1 }
        let last = try await engine.decisionFuture(for: "https://target.example/1", host: "target.example", on: loop).get()
        XCTAssertEqual(last.routes.count, 1)
        XCTAssertEqual(pac.evaluations.withLockedValue { $0 }, 4, "raising and lowering the policy must reevaluate cached answers")
        let reports = events.events.filter { $0.event == "pac.routes_truncated" }
        XCTAssertEqual(reports.map(\.detail), [
            "retained=2 dropped=1999 limit=2 suppressed=0",
            "retained=1 dropped=2000 limit=1 suppressed=2",
        ])
    }

    func testLimitChangeSupersedesAnEvaluationAlreadyInFlight() async throws {
        var initial = ProxyConfig()
        initial.pacRoutingEnabled = true; initial.pacURL = "https://pac.example/script"
        initial.pacUsableRouteLimit = 2
        let config = NIOLockedValueBox(initial)
        let pac = LargePAC()
        let engine = PACRoutingEngine(configProvider: { config.withLockedValue { $0 } }, resolver: pac)
        try await engine.refresh(force: true)
        pac.holdNext.withLockedValue { $0 = true }
        defer { pac.release.signal() }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let old = engine.decisionFuture(for: "https://target.example/", host: "target.example", on: loop)
        let deadline = ContinuousClock.now + .seconds(3)
        while pac.evaluations.withLockedValue({ $0 }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(pac.evaluations.withLockedValue { $0 }, 1)
        config.withLockedValue { $0.pacUsableRouteLimit = 100 }
        let fresh = engine.decisionFuture(for: "https://target.example/", host: "target.example", on: loop)
        pac.release.signal()
        let superseded = try await old.get()
        XCTAssertEqual(superseded, .noUsableAnswer(.superseded, rejected: []))
        let accepted = try await fresh.get()
        XCTAssertEqual(accepted.routes.count, 100)
        XCTAssertEqual(pac.evaluations.withLockedValue { $0 }, 2, "a new-policy request cannot join the old-policy evaluation")
    }

    private final class LargePAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        let evaluations = NIOLockedValueBox(0)
        let holdNext = NIOLockedValueBox(false)
        let release = DispatchSemaphore(value: 0)
        func fetchPAC(from _: String) async throws -> String { "fixture" }
        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for _: URL) throws -> [String] {
            evaluations.withLockedValue { $0 += 1 }
            let hold = holdNext.withLockedValue { value in defer { value = false }; return value }
            if hold, release.wait(timeout: .now() + 5) == .timedOut {
                throw PACResolverError.evaluationFailed("fixture gate timed out")
            }
            return Array(repeating: "PROXY secret-fixture.example:8080", count: 2_000) + ["DIRECT"]
        }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }
}
