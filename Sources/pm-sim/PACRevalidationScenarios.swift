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

    /// Takes `wallSeconds` of real time, so a request that waits for it shows,
    /// and `simulatedSeconds` of the engine's clock, so it counts as slow.
    private final class SlowPAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        static let wallSeconds: TimeInterval = 0.2
        static let simulatedSeconds: TimeInterval = 0.9
        private let clock: Clock
        private let count = NIOLockedValueBox(0)
        init(clock: Clock) { self.clock = clock }

        var evaluations: Int { count.withLockedValue { $0 } }
        func fetchPAC(from _: String) async throws -> String { "slow script" }
        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for _: URL) throws -> [String] {
            count.withLockedValue { $0 += 1 }
            Thread.sleep(forTimeInterval: Self.wallSeconds)
            clock.advance(Self.simulatedSeconds)
            return ["PROXY corp.example:8080"]
        }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }

    static func slowHost(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let clock = Clock()
        let pac = SlowPAC(clock: clock)
        let events = RuntimeEventLog(capacity: 256)
        var config = GenericDefaults.shared.makeConfig()
        config.pacRoutingEnabled = true
        config.pacURL = "https://pac.example.test/proxy.pac"
        let fixed = config
        let engine = PACRoutingEngine(
            configProvider: { fixed }, resolver: pac,
            logger: ConsoleLogSink(minLevel: verbose ? .debug : .error),
            refreshInterval: 3600,
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
        for step in 0..<steps {
            if step == steps / 2 {
                engine.invalidateRoutes(reason: .networkChanged)
            }
            let requestStarted = Date()
            let decision = try await engine.decisionFuture(
                for: url, host: host, on: MultiThreadedEventLoopGroup.singleton.next()
            ).get()
            // A cache hit returns in microseconds; a request that ran the
            // script took at least its 200 ms.
            if Date().timeIntervalSince(requestStarted) >= SlowPAC.wallSeconds / 2 { waited.append(step) }
            if decision.routes.isEmpty { unrouted += 1 }
            // Let a background re-evaluation land before simulated time moves.
            for _ in 0..<200 where engine.pendingEvaluationCount() > 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
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
            "requests=\(steps) waited_steps=\(waited) evaluations=\(evaluations) bound=\(evaluationBound)",
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
                .init("slow evaluations reported at most once per host per ten minutes",
                      !slow.isEmpty && slow.count <= reportBound),
                .init("each report counts the slow evaluations it held back",
                      slow.count + suppressed.reduce(0, +) <= evaluations && suppressed.dropFirst().allSatisfy { $0 > 0 }),
            ],
            notes: notes
        )
    }
}
