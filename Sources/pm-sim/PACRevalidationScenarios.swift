// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel
import ProxyPAC

/// `pm-sim pac-slow-host` (#34). Outlook asks for the same EWS URL all day,
/// and the corporate PAC takes about 0.9 s to answer for it. Thirty
/// simulated minutes of a request every 15 s, with one material network
/// change halfway: only the first request and the first after the change may
/// wait for the script; every other one is answered from the cache while the
/// answer is re-evaluated in the background, at most once a minute. The slow
/// evaluation warning is reported at most once per host per ten minutes.
enum PACRevalidationScenarios {
    private final class Clock: @unchecked Sendable {
        private let box = NIOLockedValueBox(Date(timeIntervalSinceReferenceDate: 800_000_000))
        var now: Date { box.withLockedValue { $0 } }
        func advance(_ seconds: TimeInterval) { box.withLockedValue { $0 += seconds } }
    }

    /// Every evaluation waits on an explicit gate. Simulated work costs 0.9 s;
    /// no wall-clock measurement decides whether a request used the cache.
    private final class SlowPAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        static let simulatedSeconds: TimeInterval = 0.9
        private let clock: Clock
        private let count = NIOLockedValueBox(0)
        let release = DispatchSemaphore(value: 0)
        init(clock: Clock) { self.clock = clock }

        var evaluations: Int { count.withLockedValue { $0 } }
        func fetchPAC(from _: String) async throws -> String { "slow script" }
        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for _: URL) throws -> [String] {
            let evaluation = count.withLockedValue { $0 += 1; return $0 }
            guard release.wait(timeout: .now() + 10) == .success else {
                throw ScenarioExecutionError(message: "PAC evaluator gate was never released")
            }
            clock.advance(Self.simulatedSeconds)
            return ["PROXY corp.example:\(10_000 + evaluation)"]
        }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }

    private static func requireCompletion(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard condition() else { throw ScenarioExecutionError(message: message) }
    }

    static func slowHost(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let clock = Clock()
        let pac = SlowPAC(clock: clock)
        defer { pac.release.signal() }
        let events = RuntimeEventLog(capacity: 256)
        var config = GenericDefaults.shared.makeConfig()
        config.pacRoutingEnabled = true
        config.pacURL = "https://pac.example.test/proxy.pac"
        let fixed = config
        let engine = PACRoutingEngine(
            configProvider: { fixed }, resolver: pac,
            logger: ConsoleLogSink(minLevel: verbose ? .debug : .error),
            refreshInterval: 3600,
            evalTimeoutSeconds: 10,
            eventSink: { events.append($0) },
            now: { clock.now }
        )
        try await engine.refresh(force: true)

        let url = "https://ews-emea.example.test/EWS/Exchange.asmx"
        let host = "ews-emea.example.test"
        let interval: TimeInterval = 15
        let duration: TimeInterval = 30 * 60
        let steps = Int(duration / interval)
        var waited: [Int] = []
        var unrouted = 0
        var background = 0
        var correctVersions = true
        var peakPending = 0
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        for step in 0..<steps {
            if step == steps / 2 {
                engine.invalidateRoutes(reason: .networkChanged)
            }
            let before = pac.evaluations
            let completed = NIOLockedValueBox(false)
            let future = engine.decisionFuture(for: url, host: host, on: loop)
            future.whenComplete { _ in completed.withLockedValue { $0 = true } }
            // The marker runs after an already-completed future's callback.
            // A miss cannot complete here: its evaluator gate is still held.
            let cacheHit = try await loop.submit { completed.withLockedValue { $0 } }.get()
            if !cacheHit { waited.append(step) }
            let pending = engine.pendingEvaluationCount()
            peakPending = max(peakPending, pending)
            if pending > 0 {
                try await requireCompletion({ pac.evaluations == before + 1 }, "PAC evaluation did not reach its gate")
                if cacheHit { background += 1 }
                pac.release.signal()
            }
            let decision = try await future.get()
            if decision.routes.isEmpty { unrouted += 1 }
            let expected = before + (cacheHit ? 0 : 1)
            correctVersions = correctVersions && decision.routes == [.proxy(host: "corp.example", port: 10_000 + expected)]
            // Pending is removed only after caching the completed answer.
            // A deadline bounds a hang; expiry throws and cannot pass.
            try await requireCompletion({ engine.pendingEvaluationCount() == 0 }, "PAC background result was not published")
            clock.advance(interval)
        }

        let slow = events.events.filter { $0.event == "pac.evaluation_slow" }
        let suppressed = slow.compactMap { event in
            event.detail?.split(separator: " ").first { $0.hasPrefix("suppressed=") }
                .flatMap { Int($0.dropFirst("suppressed=".count)) }
        }
        let evaluations = pac.evaluations
        // One to answer, then at most one per revalidation age, plus one
        // to answer again after the invalidation.
        let evaluationBound = 2 + Int((duration / PACRoutingEngine.routeRevalidationAge).rounded(.up))
        let reportBound = 1 + Int((duration / PACRoutingEngine.slowEvaluationReportInterval).rounded(.up))
        let notes = [
            "requests=\(steps) foreground_steps=\(waited) evaluations=\(evaluations) background=\(background) bound=\(evaluationBound)",
            "pac.evaluation_slow=\(slow.count) suppressed=\(suppressed) unrouted=\(unrouted)",
        ]

        return ScenarioResult(
            name: "pac-slow-host", clientCount: steps, clientsOpened: steps, clientsWithFirstByte: steps - unrouted,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every request was routed by the PAC", unrouted == 0),
                .init("only the first request and the first after the network change waited",
                      waited == [0, steps / 2]),
                .init("evaluations bounded by one per revalidation age", evaluations <= evaluationBound),
                .init("the answer in use was re-evaluated in the background", evaluations > 2),
                .init("cache hits complete while the evaluator is gated and use the published answer", correctVersions && background == evaluations - 2),
                .init("one evaluation is pending and all background results are joined before clock advance", peakPending == 1 && engine.pendingEvaluationCount() == 0),
                .init("slow evaluations reported at most once per host per ten minutes",
                      !slow.isEmpty && slow.count <= reportBound),
                .init("each report counts the slow evaluations it held back",
                      slow.count + suppressed.reduce(0, +) <= evaluations && suppressed.dropFirst().allSatisfy { $0 > 0 }),
            ],
            notes: notes
        )
    }
}
