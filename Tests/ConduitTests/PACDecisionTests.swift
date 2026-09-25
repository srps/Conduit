// SPDX-License-Identifier: Apache-2.0
// The PAC decision → routing plan table (#50), the rate limit on
// `pac.no_usable_route`, and the strict-mode hint's cooldown (#87).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class PACDecisionTests: XCTestCase {

    private let socks = PACRejectedEntry(type: "SOCKS", reason: .unsupported)
    private let badPort = PACRejectedEntry(type: "PROXY", reason: .invalid)

    private func config() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "Corp", host: "corp.example", port: 8080, priority: 0)]
        return config
    }

    private func plan(_ decision: PACDecision, fallback: Bool) -> PACRoutePlan {
        PACRoutePlan(decision: decision, config: config(), directFallbackAllowed: fallback)
    }

    // MARK: - Decision from a chain

    func testChainWithoutUsableRoutesIsNoUsableAnswer() {
        XCTAssertEqual(PACDecision(chain: PACChain(routes: [])), .noUsableAnswer(.empty, rejected: []))
        XCTAssertEqual(PACDecision(chain: PACChain(routes: [], rejected: [socks])),
                       .noUsableAnswer(.unsupported, rejected: [socks]))
        XCTAssertEqual(PACDecision(chain: PACChain(routes: [], rejected: [badPort])),
                       .noUsableAnswer(.invalid, rejected: [badPort]))
        XCTAssertEqual(PACDecision(chain: PACChain(routes: [], rejected: [badPort, socks])),
                       .noUsableAnswer(.unsupported, rejected: [badPort, socks]))
    }

    func testClassifyMarksOnlyADirectAfterRejectedEntriesAsPromoted() {
        let parse: (String) -> PACRoute? = { entry in
            switch entry {
            case "DIRECT": .direct
            case "PROXY": .proxy(host: "p.example", port: 1)
            case "SOCKS": .socks(host: "s.example", port: 1)
            default: nil
            }
        }
        XCTAssertFalse(PACChain.classify(["DIRECT", "SOCKS"], parse: parse).leadingDirectPromoted)
        XCTAssertTrue(PACChain.classify(["SOCKS", "DIRECT"], parse: parse).leadingDirectPromoted)
        XCTAssertTrue(PACChain.classify(["BOGUS x:1", "DIRECT"], parse: parse).leadingDirectPromoted)
        XCTAssertFalse(PACChain.classify(["SOCKS", "PROXY", "DIRECT"], parse: parse).leadingDirectPromoted)
    }

    // MARK: - Plan

    func testExplicitDirectRoutesDirectInEveryMode() {
        for fallback in [true, false] {
            XCTAssertEqual(plan(.routes(PACChain(routes: [.direct, .proxy(host: "corp.example", port: 8080)])),
                                fallback: fallback), .direct)
        }
    }

    func testPromotedDirectIsUsedOnlyWhereDirectFallbackIsAllowed() {
        let promoted = PACChain(routes: [.direct], rejected: [socks], leadingDirectPromoted: true)
        XCTAssertEqual(plan(.routes(promoted), fallback: true), .direct)
        XCTAssertEqual(plan(.routes(promoted), fallback: false), .upstreamsOnly(.unsupported, rejected: [socks]))

        // Without fallback a promoted DIRECT is dropped and the rest of the
        // chain still counts.
        let promotedThenProxy = PACChain(
            routes: [.direct, .proxy(host: "other.example", port: 3128)],
            rejected: [badPort], leadingDirectPromoted: true
        )
        let strict = plan(.routes(promotedThenProxy), fallback: false)
        XCTAssertEqual(strict.proxyChain.map(\.endpoint), ["other.example:3128"])
        XCTAssertFalse(strict.hasDirectFallback)
        XCTAssertEqual(plan(.routes(promotedThenProxy), fallback: true), .direct)
    }

    func testProxyChainKeepsOrderAndALaterDirectIsAFallbackOnlyWhenAllowed() {
        let chain = PACChain(routes: [.proxy(host: "corp.example", port: 8080), .proxy(host: "b.example", port: 1), .direct])
        let relaxed = plan(.routes(chain), fallback: true)
        XCTAssertEqual(relaxed.proxyChain.map(\.endpoint), ["corp.example:8080", "b.example:1"])
        XCTAssertEqual(relaxed.proxyChain.first?.name, "Corp", "a configured upstream keeps its identity")
        XCTAssertTrue(relaxed.hasDirectFallback)
        XCTAssertFalse(plan(.routes(chain), fallback: false).hasDirectFallback)
        XCTAssertFalse(plan(.routes(PACChain(routes: [.proxy(host: "a.example", port: 1)])), fallback: true).hasDirectFallback)
    }

    func testNoUsableAnswerIsUpstreamsOnlyWithoutShortcutOrFallback() {
        for reason in PACNoUsableReason.allCases {
            for fallback in [true, false] {
                let result = plan(.noUsableAnswer(reason, rejected: []), fallback: fallback)
                XCTAssertEqual(result, .upstreamsOnly(reason, rejected: []))
                XCTAssertEqual(result.proxyChain, [])
                XCTAssertFalse(result.hasDirectFallback)
                for strictMode in [true, false] {
                    XCTAssertFalse(result.allowsReachabilityShortcut(strictMode: strictMode), "\(reason)")
                }
            }
        }
    }

    func testReachabilityShortcutOnlyWithoutPACOpinionOutsideStrictMode() {
        XCTAssertTrue(PACRoutePlan.noOpinion.allowsReachabilityShortcut(strictMode: false))
        XCTAssertFalse(PACRoutePlan.noOpinion.allowsReachabilityShortcut(strictMode: true))
        XCTAssertFalse(PACRoutePlan.direct.allowsReachabilityShortcut(strictMode: false))
        XCTAssertFalse(PACRoutePlan.proxies([], directFallback: true).allowsReachabilityShortcut(strictMode: false))
        XCTAssertEqual(plan(.notConsulted, fallback: true), .noOpinion)
    }

    // MARK: - pac.no_usable_route rate limit

    func testNoUsableRouteIsRateLimitedPerReasonAndCountsSuppressed() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let reporter = PACNoUsableRouteReporter(
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            logger: nil,
            now: { clock.withLockedValue { $0 } }
        )
        XCTAssertTrue(reporter.report(.unsupported, rejected: [socks], host: "a.example"))
        for _ in 0..<5 {
            XCTAssertFalse(reporter.report(.unsupported, rejected: [socks], host: "b.example"))
        }
        // Another reason has its own slot.
        XCTAssertTrue(reporter.report(.timeout, rejected: [], host: "c.example"))
        clock.withLockedValue { $0 += PACNoUsableRouteReporter.window - 1 }
        XCTAssertFalse(reporter.report(.unsupported, rejected: [], host: "d.example"))
        clock.withLockedValue { $0 += 1 }
        XCTAssertTrue(reporter.report(.unsupported, rejected: [socks, badPort, socks], host: "e.example"))

        let details = events.withLockedValue { $0 }.map { "\($0.event) \($0.detail ?? "")" }
        XCTAssertEqual(details, [
            "pac.no_usable_route reason=unsupported host=a.example rejected=SOCKS suppressed=0",
            "pac.no_usable_route reason=timeout host=c.example suppressed=0",
            "pac.no_usable_route reason=unsupported host=e.example rejected=SOCKS,PROXY suppressed=6",
        ])
    }

    /// A PAC answer is untrusted and chains are cached per URL: thousands of
    /// rejected entries keep only `retainedLimit` of them, while the counts
    /// keep classification and the event correct.
    func testThousandsOfRejectedEntriesAreBoundedAndStillClassified() {
        let parse: (String) -> PACRoute? = { $0.hasPrefix("SOCKS") ? .socks(host: "s.example", port: 1) : nil }
        // 4,999 invalid entries, then one unsupported one past the retained few.
        let entries = Array(repeating: "PROXY bogus.example:99999", count: 4_999) + ["SOCKS s.example:1"]
        let chain = PACChain.classify(entries, parse: parse)
        XCTAssertEqual(chain.rejected.count, PACRejections.retainedLimit)
        XCTAssertEqual(chain.rejected.total, 5_000)
        XCTAssertEqual(chain.rejected.unsupported, 1)
        XCTAssertTrue(chain.rejected.truncated)

        let decision = PACDecision(chain: chain)
        guard case .noUsableAnswer(let reason, let rejected) = decision else {
            return XCTFail("expected no usable answer, got \(decision)")
        }
        XCTAssertEqual(reason, .unsupported, "the unsupported entry past the retained ones still counts")

        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let reporter = PACNoUsableRouteReporter(
            eventSink: { event in events.withLockedValue { $0.append(event) } }, logger: nil
        )
        reporter.report(reason, rejected: rejected, host: "a.example")
        XCTAssertEqual(events.withLockedValue { $0 }.map(\.detail),
                       ["reason=unsupported host=a.example rejected=PROXY rejectedTotal=5000 suppressed=0"])
    }

    func testRejectedTypesInAnEventAreBounded() {
        var many = PACRejections()
        for index in 0..<40 { many.append(PACRejectedEntry(type: "T\(index)", reason: .unsupported)) }
        XCTAssertEqual(PACNoUsableRouteReporter.rejectedTypes(many).count, PACNoUsableRouteReporter.maxRejectedTypes)
    }

    func testEngineReportsEveryNoUsableReasonItReturns() async throws {
        var config = ProxyConfig.testFixture()
        config.pacRoutingEnabled = true
        config.pacURL = "https://pac.example/proxy.pac"
        let fixed = config
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let engine = PACRoutingEngine(
            configProvider: { fixed },
            resolver: FixedPAC(entries: ["SOCKS s.example:1080"]),
            refreshInterval: 300,
            pacLoader: { _ in throw PACResolverError.fetchFailed("not yet") },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        // Not loaded yet.
        XCTAssertEqual(engine.decision(for: "https://a.example/", host: "a.example"), .noUsableAnswer(.notLoaded, rejected: []))
        let reasons = events.withLockedValue { $0 }.filter { $0.event == "pac.no_usable_route" }.map(\.detail)
        XCTAssertEqual(reasons, ["reason=not_loaded host=a.example suppressed=0"])
    }

    // MARK: - Strict-mode hint probe (#87)

    private func hintDetector(
        clock: NIOLockedValueBox<Date> = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000)),
        resolver: ProbeResolver
    ) -> DirectConnectDetector {
        DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            now: { clock.withLockedValue { $0 } },
            resolver: { host, port, loop in resolver.resolve(host: host, port: port, on: loop) }
        )
    }

    /// Waits for running hint probes to finish. Bounded; counts, not time.
    private func drain(_ detector: DirectConnectDetector) async throws {
        for _ in 0..<500 where detector.strictHintInFlightCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(detector.strictHintInFlightCount, 0, "hint probes never finished")
    }

    func testStrictHintProbesOncePerHostPerCooldown() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let resolver = ProbeResolver(.held)
        let detector = hintDetector(clock: clock, resolver: resolver)
        XCTAssertEqual(detector.probeForStrictModeHint(host: "App.Invalid", port: 9, gatewayMode: false) {}, .started)
        XCTAssertEqual(detector.probeForStrictModeHint(host: "app.invalid", port: 9, gatewayMode: false) {}, .coolingDown,
                       "same host, any case")
        XCTAssertEqual(detector.probeForStrictModeHint(host: "app.invalid", port: 443, gatewayMode: false) {}, .coolingDown,
                       "per host, not per port")
        XCTAssertEqual(detector.probeForStrictModeHint(host: "other.invalid", port: 9, gatewayMode: false) {}, .started)
        clock.withLockedValue { $0 += DirectConnectDetector.strictHintCooldown - 1 }
        XCTAssertEqual(detector.probeForStrictModeHint(host: "app.invalid", port: 9, gatewayMode: false) {}, .coolingDown)
        clock.withLockedValue { $0 += 1 }
        XCTAssertEqual(detector.probeForStrictModeHint(host: "app.invalid", port: 9, gatewayMode: false) {}, .started)
        XCTAssertEqual(detector.probeCount, 3)
        resolver.release()
    }

    func testStrictHintTableIsBounded() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let detector = hintDetector(clock: clock, resolver: ProbeResolver(.noAddresses))
        for index in 0..<(DirectConnectDetector.strictHintCapacity + 10) {
            clock.withLockedValue { $0 += 1 }
            XCTAssertEqual(detector.probeForStrictModeHint(host: "h\(index).invalid", port: 9, gatewayMode: false) {}, .started)
            try await drain(detector)
        }
        XCTAssertEqual(detector.strictHintTableCount, DirectConnectDetector.strictHintCapacity)
        // The oldest were evicted; the newest are still cooling down.
        XCTAssertEqual(detector.probeForStrictModeHint(host: "h0.invalid", port: 9, gatewayMode: false) {}, .started)
        XCTAssertEqual(detector.probeForStrictModeHint(
            host: "h\(DirectConnectDetector.strictHintCapacity + 9).invalid", port: 9, gatewayMode: false) {}, .coolingDown)
        try await drain(detector)
    }

    /// Many distinct hosts failing at once start at most
    /// `strictHintMaxInFlight` probes; the rest are skipped and counted.
    func testStrictHintProbesInFlightAreBounded() async throws {
        let resolver = ProbeResolver(.held)
        let detector = hintDetector(resolver: resolver)
        let hosts = 10 + DirectConnectDetector.strictHintMaxInFlight
        let results = (0..<hosts).map {
            detector.probeForStrictModeHint(host: "burst\($0).invalid", port: 443, gatewayMode: false) {}
        }
        let cap = DirectConnectDetector.strictHintMaxInFlight
        XCTAssertEqual(results.filter { $0 == .started }.count, cap)
        XCTAssertEqual(results.filter { $0 == .busy }.count, hosts - cap)
        XCTAssertEqual(detector.strictHintInFlightCount, cap)
        XCTAssertEqual(detector.strictHintSkippedCount, hosts - cap)
        XCTAssertEqual(resolver.lookups, cap, "a skipped hint must not resolve or connect")

        // A skipped host was not put on cooldown; once probes finish it can run.
        resolver.release()
        try await drain(detector)
        XCTAssertEqual(detector.probeForStrictModeHint(host: "burst\(hosts - 1).invalid", port: 443, gatewayMode: false) {},
                       .started)
        resolver.release()
        try await drain(detector)
    }

    /// Gateway mode: a hint never connects to a metadata/loopback target,
    /// whether it is named directly or only resolves to one.
    func testStrictHintNeverConnectsToABlockedAddressInGatewayMode() async throws {
        let listener = try await CountingListener.start()
        defer { listener.stop() }
        let blocked = try SocketAddress(ipAddress: "127.0.0.1", port: listener.port)

        // Named directly: refused before anything is resolved.
        let direct = hintDetector(resolver: ProbeResolver(.addresses([blocked])))
        XCTAssertEqual(direct.probeForStrictModeHint(host: "169.254.169.254", port: 80, gatewayMode: true) {}, .blocked)
        XCTAssertEqual(direct.probeForStrictModeHint(host: "metadata.google.internal", port: 80, gatewayMode: true) {}, .blocked)
        XCTAssertEqual(direct.probeCount, 0)

        // A name that resolves to loopback: resolved, then never connected.
        let hinted = NIOLockedValueBox(0)
        let rebinding = hintDetector(resolver: ProbeResolver(.addresses([blocked])))
        XCTAssertEqual(rebinding.probeForStrictModeHint(host: "rebind.example", port: listener.port, gatewayMode: true) {
            hinted.withLockedValue { $0 += 1 }
        }, .started)
        try await drain(rebinding)
        XCTAssertEqual(listener.accepted, 0, "the hint probe connected to a blocked address")
        XCTAssertEqual(hinted.withLockedValue { $0 }, 0, "a blocked address counted as reachable")

        // Control: the same target outside gateway mode is probed and hinted,
        // so the counts above would have seen a connection.
        let open = hintDetector(resolver: ProbeResolver(.addresses([blocked])))
        XCTAssertEqual(open.probeForStrictModeHint(host: "rebind.example", port: listener.port, gatewayMode: false) {
            hinted.withLockedValue { $0 += 1 }
        }, .started)
        try await drain(open)
        XCTAssertEqual(hinted.withLockedValue { $0 }, 1)
        for _ in 0..<500 where listener.accepted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(listener.accepted, 1)
    }
}

private struct FixedPAC: PacEvaluator, PacScriptEvaluating {
    let entries: [String]
    func fetchPAC(from _: String) async throws -> String { "" }
    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
    func resolveProxyChain(for _: URL) throws -> [String] { entries }
    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { entry in
            entry.hasPrefix("SOCKS") ? .socks(host: "s.example", port: 1080) : nil
        }
    }
}
