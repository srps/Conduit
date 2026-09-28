// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// A `refresh` that finds one running waits for it to finish (#39), and a
/// refresh running across `invalidateRoutes(reason:)` never leaves the
/// engine without the new network's PAC once its callers return (#96).
/// Every fetch blocks until the test releases it; no test sleeps.
final class PACRefreshJoinTests: XCTestCase {
    private static let offScript = #"function FindProxyForURL(url, host) { return "PROXY policy-detection.example:80"; }"#
    private static let onScript = #"function FindProxyForURL(url, host) { return "PROXY corp.example:8080"; }"#
    private static let off = PACRoute.proxy(host: "policy-detection.example", port: 80)
    private static let on = PACRoute.proxy(host: "corp.example", port: 8080)

    /// A PAC server whose every fetch waits for `release()`. The script is
    /// the one for the network at the moment the fetch starts.
    private final class GatedServer: @unchecked Sendable {
        private let lock = NIOLock()
        private var onVPN = false
        private var started = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        /// Called with the fetch count as each fetch starts, outside the lock.
        var onStart: (@Sendable (Int) -> Void)?

        func setOnVPN(_ value: Bool) { lock.withLock { onVPN = value } }
        var fetches: Int { lock.withLock { started } }

        func load() async -> String {
            var script = ""
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (ready, count, hook) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], Int, (@Sendable (Int) -> Void)?) in
                    started += 1
                    script = onVPN ? PACRefreshJoinTests.onScript : PACRefreshJoinTests.offScript
                    held.append(continuation)
                    let ready = startWaiters.filter { $0.count <= started }.map(\.continuation)
                    startWaiters.removeAll { $0.count <= started }
                    return (ready, started, onStart)
                }
                hook?(count)
                ready.forEach { $0.resume() }
            }
            return script
        }

        /// Returns once `count` fetches have started.
        func waitForFetch(_ count: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if started >= count { return true }
                    startWaiters.append((count, continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        }

        /// Lets the oldest held fetch return.
        func release() {
            let next = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
            next?.resume()
        }
    }

    private final class EngineBox: @unchecked Sendable {
        var engine: PACRoutingEngine?
    }

    private func makeEngine(
        server: GatedServer, events: RuntimeEventLog,
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void = { _ in }
    ) -> PACRoutingEngine {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://pac.example.com/proxy.pac"
        config.pacRoutingEnabled = true
        let fixed = config
        return PACRoutingEngine(
            configProvider: { fixed },
            resolver: CFPACEvaluator(),
            refreshInterval: 300,
            pacLoader: { _ in await server.load() },
            eventSink: { event in
                events.append(event)
                onEvent(event)
            }
        )
    }

    /// #39: the second caller returns only once the evaluator it waited
    /// for is installed.
    func testASecondRefreshWaitsForTheRunningOneToInstall() async throws {
        let server = GatedServer()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        let first = Task { try await engine.refresh(force: true) }
        await server.waitForFetch(1)
        let secondDone = NIOLockedValueBox(false)
        let second = Task {
            try await engine.refresh(force: true)
            secondDone.withLockedValue { $0 = true }
            return engine.route(for: "https://github.com/", host: "github.com")
        }
        server.release()
        try await first.value
        let routeSeenBySecond = try await second.value

        XCTAssertEqual(routeSeenBySecond, Self.off, "the second caller returned with the evaluator installed")
        XCTAssertEqual(server.fetches, 1, "the two callers shared one fetch")
    }

    /// Codex P1 on #103: an invalidation while a fetch runs. The transition's
    /// forced refresh waits until the refetch on the new network installs.
    func testARefreshAfterAnInvalidationWaitsForTheRefetch() async throws {
        let server = GatedServer()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        let running = Task { try await engine.refresh(force: true) }
        await server.waitForFetch(1)

        server.setOnVPN(true)
        engine.invalidateRoutes(reason: .vpnConnected)
        let transitionDone = NIOLockedValueBox(false)
        let transition = Task {
            try await engine.refresh(force: true)
            transitionDone.withLockedValue { $0 = true }
            return engine.route(for: "https://github.com/", host: "github.com")
        }

        server.release()             // the off-VPN fetch returns, is discarded
        await server.waitForFetch(2) // and the on-VPN one starts
        XCTAssertFalse(transitionDone.withLockedValue { $0 }, "the transition is still waiting for the refetch")
        server.release()

        let routeSeenByTransition = try await transition.value
        try await running.value
        XCTAssertEqual(routeSeenByTransition, Self.on)
        XCTAssertEqual(server.fetches, 2)
        XCTAssertEqual(events.events.filter { $0.event == "pac.refreshed" }.count, 1)
    }

    /// Codex P2 on #103: an invalidation, and the transition's forced
    /// refresh, landing after a fetch installed its script but before that
    /// refresh finished. The forced refresh must fetch again rather than
    /// treat the finished one as still running. The event sink runs inside
    /// that window; it holds the refresh there until the forced refresh has
    /// either returned or started its own fetch.
    func testAnInvalidationRightAfterAnInstallIsFollowedByAFreshFetch() async throws {
        final class Window: @unchecked Sendable {
            let settled = DispatchSemaphore(value: 0)
            let transition = NIOLockedValueBox<Task<Void, any Error>?>(nil)
            let opened = NIOLockedValueBox(false)
        }
        let server = GatedServer()
        let events = RuntimeEventLog(capacity: 64)
        let box = EngineBox()
        let window = Window()
        server.onStart = { count in if count == 2 { window.settled.signal() } }
        let engine = makeEngine(server: server, events: events) { event in
            guard event.event == "pac.refreshed",
                  window.opened.withLockedValue({ opened in defer { opened = true }; return !opened }),
                  let engine = box.engine else { return }
            server.setOnVPN(true)
            engine.invalidateRoutes(reason: .vpnConnected)
            window.transition.withLockedValue {
                $0 = Task {
                    defer { window.settled.signal() }
                    try await engine.refresh(force: true)
                }
            }
            XCTAssertEqual(window.settled.wait(timeout: .now() + 5), .success)
        }
        box.engine = engine

        let running = Task { try await engine.refresh(force: true) }
        await server.waitForFetch(1)
        server.release()
        try await running.value

        let transition = try XCTUnwrap(window.transition.withLockedValue { $0 })
        if server.fetches >= 2 { server.release() }
        try await transition.value

        XCTAssertEqual(server.fetches, 2, "the forced refresh after the invalidation fetched again")
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.on,
                       "and loaded the new network's PAC before it returned")
    }

    /// A waiting caller that is cancelled stops waiting; the refresh it
    /// joined still installs for everyone else.
    func testACancelledWaiterStopsWaitingWithoutCancellingTheRefresh() async throws {
        let server = GatedServer()
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(server: server, events: events)

        let first = Task { try await engine.refresh(force: true) }
        await server.waitForFetch(1)
        let waiter = Task { try await engine.refresh(force: true) }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }

        server.release()
        try await first.value
        XCTAssertEqual(engine.route(for: "https://github.com/", host: "github.com"), Self.off)
    }
}
