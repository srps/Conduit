// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACRoutingEngineTests: XCTestCase {
    func testShouldBypassWhenPACReturnsDirect() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let script = """
        function FindProxyForURL(url, host) {
            if (host === "login.microsoftonline.com") { return "DIRECT"; }
            return "PROXY corp.example.com:8080";
        }
        """

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in script }
        )

        try await engine.refresh(force: true)

        XCTAssertTrue(
            engine.shouldBypass(
                url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                host: "login.microsoftonline.com"
            )
        )
        XCTAssertFalse(
            engine.shouldBypass(
                url: "https://github.com/",
                host: "github.com"
            )
        )
    }

    func testRouteUsesFirstPACEntryInChain() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let script = """
        function FindProxyForURL(url, host) {
            return "PROXY first.proxy.example.com:8080; DIRECT";
        }
        """

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in script }
        )

        try await engine.refresh(force: true)

        XCTAssertEqual(
            engine.route(for: "https://sourcecode.corp.example.test/", host: "sourcecode.corp.example.test"),
            .proxy(host: "first.proxy.example.com", port: 8080)
        )
        XCTAssertFalse(
            engine.shouldBypass(url: "https://sourcecode.corp.example.test/", host: "sourcecode.corp.example.test")
        )
    }

    func testRefreshIntervalControlsPACReloads() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let loader = ScriptLoader(script: """
        function FindProxyForURL(url, host) {
            return "DIRECT";
        }
        """)

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: CFPACEvaluator(),
            refreshInterval: 0.02,
            pacLoader: { url in
                try await loader.load(url)
            }
        )

        try await engine.refresh(force: true)
        try await engine.refresh()
        let initialCallCount = await loader.callCount()
        XCTAssertEqual(initialCallCount, 1)

        await loader.setScript("""
        function FindProxyForURL(url, host) {
            return "PROXY reloaded.proxy.example.com:8080";
        }
        """)

        try await Task.sleep(for: .milliseconds(40))
        try await engine.refresh()

        let refreshedCallCount = await loader.callCount()
        XCTAssertEqual(refreshedCallCount, 2)
        XCTAssertEqual(
            engine.route(for: "https://example.com/", host: "example.com"),
            .proxy(host: "reloaded.proxy.example.com", port: 8080)
        )
    }

    func testConcurrentPACEvaluationDoesNotCrash() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let script = """
        function FindProxyForURL(url, host) {
            if (dnsDomainIs(host, ".internal.corp")) { return "DIRECT"; }
            return "PROXY corp.example.com:8080";
        }
        """

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in script }
        )

        try await engine.refresh(force: true)

        await withTaskGroup(of: PACRoute?.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let host = i % 2 == 0 ? "app.internal.corp" : "github.com"
                    return engine.route(for: "https://\(host)/", host: host)
                }
            }
            var directCount = 0
            var proxyCount = 0
            for await route in group {
                switch route {
                case .direct: directCount += 1
                case .proxy: proxyCount += 1
                default: break
                }
            }
            XCTAssertEqual(directCount, 25, "Internal hosts should route DIRECT")
            XCTAssertEqual(proxyCount, 25, "External hosts should route via PROXY")
        }
    }

    func testRouteChainFutureDoesNotBlockCallerEventLoopDuringSlowEvaluation() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: StaticPacEvaluator(scriptEvaluator: SlowPacScriptEvaluator(delay: 0.25)),
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL(url, host) { return \"DIRECT\"; }" }
        )
        try await engine.refresh(force: true)

        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let routesPromise = eventLoop.makePromise(of: [PACRoute].self)
        let markerPromise = eventLoop.makePromise(of: TimeInterval.self)
        let start = Date()

        eventLoop.execute {
            engine.routeChainFuture(for: "https://slow.example/resource", host: "slow.example", on: eventLoop)
                .cascade(to: routesPromise)
            eventLoop.execute {
                markerPromise.succeed(Date().timeIntervalSince(start))
            }
        }

        let markerDelay = try await markerPromise.futureResult.get()
        XCTAssertLessThan(markerDelay, 0.1, "Slow PAC evaluation must not block the request event loop")
        let routes = try await routesPromise.futureResult.get()
        XCTAssertEqual(routes, [PACRoute.direct])
    }

    func testRouteChainFutureTimesOutWhenEvaluatorQueueIsBlocked() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: StaticPacEvaluator(scriptEvaluator: SlowPacScriptEvaluator(delay: 2.0)),
            refreshInterval: 300,
            evalTimeoutSeconds: 0.1,
            pacLoader: { _ in "function FindProxyForURL(url, host) { return \"DIRECT\"; }" }
        )
        try await engine.refresh(force: true)

        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let start = Date()
        let routes = try await engine.routeChainFuture(
            for: "https://blocked.example/resource",
            host: "blocked.example",
            on: eventLoop
        ).get()

        XCTAssertEqual(routes, [], "Timed-out PAC evaluations should fail closed to the default route chain")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "Timeout must not wait for the blocked evaluator queue")
    }

    func testRouteCacheSeparatesDifferentPathsOnSameHostAndPort() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let evaluator = CountingPacScriptEvaluator()

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: StaticPacEvaluator(scriptEvaluator: evaluator),
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL(url, host) { return \"DIRECT\"; }" }
        )

        try await engine.refresh(force: true)

        let first = engine.route(for: "https://example.com/path-a", host: "example.com")
        let second = engine.route(for: "https://example.com/path-b", host: "example.com")

        XCTAssertEqual(first, .proxy(host: "cached.proxy.example.com", port: 8080))
        XCTAssertEqual(second, .proxy(host: "cached.proxy.example.com", port: 8080))
        XCTAssertEqual(evaluator.callCount(), 2, "Path-sensitive PAC decisions must not be reused across different URLs.")
    }

    func testRefreshTimesOutOnHangingPACScript() async {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: HangingPacEvaluator(),
            refreshInterval: 300,
            evalTimeoutSeconds: 0.5,
            pacLoader: { _ in "function FindProxyForURL(url, host) { return \"DIRECT\"; }" }
        )

        let start = Date()
        do {
            try await engine.refresh(force: true)
            XCTFail("Expected PAC refresh to time out")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3, "Timeout should fire within ~0.5s, not hang indefinitely")
            XCTAssertTrue(error.localizedDescription.contains("timed out"),
                          "Error should mention timeout, got: \(error.localizedDescription)")
        }
    }

    func testKeepsPreviousPACRulesWhenRefreshFails() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://example.com/proxy.pac"
        config.pacRoutingEnabled = true

        let loader = ScriptLoader(script: """
        function FindProxyForURL(url, host) {
            return "DIRECT";
        }
        """)

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { url in
                try await loader.load(url)
            }
        )

        try await engine.refresh(force: true)
        XCTAssertTrue(engine.shouldBypass(url: "https://login.microsoftonline.com/", host: "login.microsoftonline.com"))

        await loader.setShouldThrow(true)

        do {
            try await engine.refresh(force: true)
            XCTFail("Expected PAC refresh to fail")
        } catch {
            XCTAssertTrue(engine.shouldBypass(url: "https://login.microsoftonline.com/", host: "login.microsoftonline.com"))
        }
    }
}

private actor ScriptLoader {
    private var calls = 0
    private var script: String
    private var shouldThrow = false

    init(script: String) {
        self.script = script
    }

    func load(_ url: String) throws -> String {
        calls += 1
        if shouldThrow {
            throw LoaderError.simulatedFailure
        }
        return script
    }

    func setScript(_ script: String) {
        self.script = script
    }

    func setShouldThrow(_ shouldThrow: Bool) {
        self.shouldThrow = shouldThrow
    }

    func callCount() -> Int {
        calls
    }
}

private enum LoaderError: Error {
    case simulatedFailure
}

private final class StaticPacEvaluator: PacEvaluator, @unchecked Sendable {
    private let scriptEvaluator: any PacScriptEvaluating

    init(scriptEvaluator: any PacScriptEvaluating) {
        self.scriptEvaluator = scriptEvaluator
    }

    func fetchPAC(from _: String) async throws -> String {
        "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
    }

    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating {
        scriptEvaluator
    }

    func routeChain(for entries: [String]) -> [PACRoute] {
        CFPACEvaluator().routeChain(for: entries)
    }
}

private final class CountingPacScriptEvaluator: PacScriptEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func resolveProxyChain(for _: URL) throws -> [String] {
        lock.withLock { calls += 1 }
        return ["PROXY cached.proxy.example.com:8080"]
    }

    func callCount() -> Int {
        lock.withLock { calls }
    }
}

private final class SlowPacScriptEvaluator: PacScriptEvaluating, @unchecked Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func resolveProxyChain(for _: URL) throws -> [String] {
        Thread.sleep(forTimeInterval: delay)
        return ["DIRECT"]
    }
}

private final class HangingPacEvaluator: PacEvaluator, @unchecked Sendable {
    func fetchPAC(from _: String) async throws -> String {
        "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
    }

    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating {
        Thread.sleep(forTimeInterval: 2)
        return DirectPacScriptEvaluator()
    }

    func routeChain(for _: [String]) -> [PACRoute] {
        []
    }
}

private struct DirectPacScriptEvaluator: PacScriptEvaluating {
    func resolveProxyChain(for _: URL) throws -> [String] {
        ["DIRECT"]
    }
}
