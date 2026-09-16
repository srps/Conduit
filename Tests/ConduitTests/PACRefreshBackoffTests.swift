// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACRefreshBackoffTests: XCTestCase {
    private static let script = """
    function FindProxyForURL(url, host) { return "PROXY corp.example.com:8080"; }
    """

    private final class Loader: @unchecked Sendable {
        private let lock = NIOLock()
        private var calls = 0
        var failing: Bool
        init(failing: Bool) { self.failing = failing }
        var callCount: Int { lock.withLock { calls } }
        func load() throws -> String {
            lock.withLock { calls += 1 }
            if lock.withLock({ failing }) {
                throw PACResolverError.fetchFailed("PAC host unreachable")
            }
            return PACRefreshBackoffTests.script
        }
        func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    }

    private final class ConfigBox: @unchecked Sendable {
        private let lock = NIOLock()
        private var config: ProxyConfig
        init(_ config: ProxyConfig) { self.config = config }
        var current: ProxyConfig { lock.withLock { config } }
        func setPACURL(_ url: String) { lock.withLock { config.pacURL = url } }
    }

    private func makeEngine(loader: Loader, config: ConfigBox) -> PACRoutingEngine {
        PACRoutingEngine(
            configProvider: { config.current },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in try loader.load() }
        )
    }

    private func makeConfig() -> ConfigBox {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://pac.example.com/proxy.pac"
        config.pacRoutingEnabled = true
        return ConfigBox(config)
    }

    func testFailedFetchStartsBackoffThatOnlyBackoffHonouringCallersObserve() async throws {
        let loader = Loader(failing: true)
        let engine = makeEngine(loader: loader, config: makeConfig())

        await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
        XCTAssertEqual(loader.callCount, 1)
        let remaining = try XCTUnwrap(engine.backoffRemaining())
        XCTAssertEqual(remaining, PACRoutingEngine.backoffBase, accuracy: 1)

        // A network-path update inside the window: skipped, and not an error.
        try await engine.refresh(force: true, honorBackoff: true)
        XCTAssertEqual(loader.callCount, 1, "a backoff-honouring refresh does not fetch inside the window")

        // Wake / VPN reconnect / user: fetches regardless.
        await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
        XCTAssertEqual(loader.callCount, 2)
    }

    func testBackoffDoublesPerFailureAndCaps() async throws {
        let loader = Loader(failing: true)
        let engine = makeEngine(loader: loader, config: makeConfig())

        var expected = PACRoutingEngine.backoffBase
        for failure in 1...7 {
            await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
            let remaining = try XCTUnwrap(engine.backoffRemaining(), "failure \(failure)")
            XCTAssertEqual(remaining, min(expected, PACRoutingEngine.backoffCap), accuracy: 1, "failure \(failure)")
            expected *= 2
        }
        XCTAssertEqual(try XCTUnwrap(engine.backoffRemaining()), PACRoutingEngine.backoffCap, accuracy: 1)
    }

    func testBackoffElapsesOnItsOwn() async throws {
        let loader = Loader(failing: true)
        let engine = makeEngine(loader: loader, config: makeConfig())

        await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
        let later = Date().addingTimeInterval(PACRoutingEngine.backoffBase + 1)
        XCTAssertNil(engine.backoffRemaining(now: later))
    }

    func testSuccessfulFetchClearsBackoff() async throws {
        let loader = Loader(failing: true)
        let engine = makeEngine(loader: loader, config: makeConfig())

        await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
        loader.setFailing(false)
        try await engine.refresh(force: true)

        XCTAssertNil(engine.backoffRemaining())
        try await engine.refresh(force: true, honorBackoff: true)
        XCTAssertEqual(loader.callCount, 3, "with the backoff cleared, a backoff-honouring refresh fetches")
        XCTAssertNotNil(engine.route(for: "https://github.com/", host: "github.com"))
    }

    func testChangedPACURLFetchesDespiteBackoff() async throws {
        let loader = Loader(failing: true)
        let config = makeConfig()
        let engine = makeEngine(loader: loader, config: config)

        await XCTAssertThrowsErrorAsync(try await engine.refresh(force: true))
        config.setPACURL("http://pac.example.com/other.pac")
        loader.setFailing(false)

        try await engine.refresh(honorBackoff: true)
        XCTAssertEqual(loader.callCount, 2, "a new URL is a new PAC; the old one's backoff does not apply")
    }

    func testConcurrentForcedRefreshesShareOneFetch() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = NIOLockedValueBox(0)
        let config = makeConfig()
        let engine = PACRoutingEngine(
            configProvider: { config.current },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in
                calls.withLockedValue { $0 += 1 }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        gate.wait()
                        continuation.resume()
                    }
                }
                return PACRefreshBackoffTests.script
            }
        )

        let first = Task { try await engine.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(100))
        let second = Task { try await engine.refresh(force: true) }
        let third = Task { try await engine.refresh(force: true, honorBackoff: true) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(calls.withLockedValue { $0 }, 1, "the second and third refresh return at once")
        gate.signal()
        try await first.value
        try await second.value
        try await third.value
        XCTAssertEqual(calls.withLockedValue { $0 }, 1)
        XCTAssertNotNil(engine.route(for: "https://github.com/", host: "github.com"))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected the call to throw", file: file, line: line)
    } catch {
        // expected
    }
}
