// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Observation values must lose URL secrets before any sink serializes them.
enum ObservableTargetScenarios {
    private struct Failure: Error { let message: String }

    static func redaction() throws -> ScenarioResult {
        let started = Date()
        let values = [
            "http://example.test/path?sig=s06q#s06f",
            "/path?sig=s06q#s06f", "/path#s06f?sig=s06q",
            "HTTPS://example.test/path#s06f", "http://[invalid/path?sig=s06q",
        ]
        for value in values {
            let observed = SensitiveValueSanitizer.observableTarget(value)
            let info = ActiveConnectionInfo(destination: value, upstream: "DIRECT", method: "GET")
            let event = RuntimeEvent(kind: .routing, event: "routing.test", detail: observed)
            let logs = RecordingLogSink()
            logs.log(.info, "Observed \(observed)", category: .proxy)
            // Exercise the sink backstop independently from call-site filtering.
            logs.log(.error, "Failed URL https://example.test/path?sig=s06q#s06f", category: .proxy)
            let encoder = CanonicalJSON.encoder()
            let outputs = [observed, SensitiveValueSanitizer.auditTarget(value),
                           String(decoding: try encoder.encode(info), as: UTF8.self),
                           String(decoding: try encoder.encode(event), as: UTF8.self)]
                + logs.entries().map(\.message)
            guard outputs.allSatisfy({ !$0.contains("s06q") && !$0.contains("s06f") }),
                  SensitiveValueSanitizer.observableTarget(observed) == observed else {
                throw Failure(message: "An observation retained a URL secret or redaction was not idempotent")
            }
        }
        return ScenarioResult(
            name: "observable-target-redaction", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: observed targets, logs, events, audit targets, and encoded connection records redact query/fragment secrets"]
        )
    }
}
