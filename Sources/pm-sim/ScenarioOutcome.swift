// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Verdicts are data. Notes, byte counters and expected early closes are never
/// interpreted by the runner to decide whether a scenario passed.
struct ScenarioAssertion: Sendable {
    let name: String
    let passed: Bool

    init(_ name: String, _ passed: Bool) {
        self.name = name
        self.passed = passed
    }
}

struct ScenarioExecutionError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

extension ScenarioResult {
    func injectingFailedAssertion() -> ScenarioResult {
        var result = self
        if let first = result.assertions.first {
            result.assertions[0] = .init(first.name, false)
        }
        result.notes.append("test-only assertion fault injection")
        return result
    }

    static func failure(name: String, error: Error) -> ScenarioResult {
        ScenarioResult(
            name: name, clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: 0,
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [.init("scenario completed without throwing", false)],
            notes: [String(describing: error)]
        )
    }

    /// Only selected by --self-test-outcomes, for subprocess exit/output tests.
    static func reportingFixture(name: String) -> ScenarioResult {
        ScenarioResult(
            name: name, clientCount: 2, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 2, totalBytes: 0, durationSeconds: 0,
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: name == "fixture-missing" ? [] : [.init("deliberate invariant", name == "fixture-pass")],
            notes: [name == "fixture-pass" ? "FAIL and BUG are informational words; early closes are expected" : "PASS is informational too"]
        )
    }
}

/// Async defers are registered by each scenario and awaited by the runner
/// before the next scenario starts (including after a thrown error).
@MainActor
final class ScenarioCleanup {
    @TaskLocal static var current: ScenarioCleanup?
    private var actions: [@MainActor () async -> Void] = []

    static func register(_ action: @escaping @MainActor () async -> Void) {
        guard let current else { preconditionFailure("scenario must run inside cleanup scope") }
        precondition(current.actions.count < 64, "bounded scenario cleanup list")
        current.actions.append(action)
    }

    func drain() async {
        while let action = actions.popLast() { await action() }
    }
}
