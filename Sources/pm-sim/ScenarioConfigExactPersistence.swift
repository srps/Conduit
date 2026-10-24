// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Exact saves for durations (decision 0023), headless. The real
/// `ProxyConfigPersistence` writes into a scratch directory; nothing under the
/// user's configuration is read or changed. Whole-millisecond and whole-minute
/// values round-trip. An inexact value is refused by field before any byte is
/// written or any parent directory is created, and the previous file stays
/// byte-identical.
enum ConfigExactPersistenceScenario {
    private struct Failure: Error { let message: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-pm-sim-config-exact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Scratch cleanup only: every outcome is already recorded in the assertions below.
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("config.json")

        // A whole-millisecond timeout and a whole-minute TTL are stored and read back exactly.
        var whole = ProxyConfig.testFixture()
        whole.connectionCheckTimeoutMS = 1001
        whole.directConnectTTLMinutes = 10
        try ProxyConfigPersistence.save(whole, to: url)
        let reloaded = try ProxyConfigPersistence.load(from: url)
        let wholeRoundTrip = reloaded.health.connectionCheckTimeout == whole.health.connectionCheckTimeout
            && reloaded.health.directConnectTTL == whole.health.directConnectTTL
            && reloaded.connectionCheckTimeoutMS == 1001

        // Each inexact value is refused by its field, and the saved bytes do not change.
        let before = try Data(contentsOf: url)
        var ttl = whole
        ttl.health.directConnectTTL = 90.5
        var subMillisecond = whole
        subMillisecond.health.connectionCheckTimeout = 0.0015
        var nonFinite = whole
        nonFinite.health.checkInterval = .nan
        let ttlRefused = refusedField { try ProxyConfigPersistence.save(ttl, to: url) } == "health.directConnectTTL"
        let subMillisecondRefused = refusedField { try ProxyConfigPersistence.save(subMillisecond, to: url) }
            == "health.connectionCheckTimeout"
        let nonFiniteRefused = refusedField { try ProxyConfigPersistence.save(nonFinite, to: url) } == "health.checkInterval"
        let bytesUnchanged = try Data(contentsOf: url) == before

        // A refused save under a missing parent creates neither the parent nor a file.
        let parent = scratch.appendingPathComponent("missing", isDirectory: true)
        let nested = parent.appendingPathComponent("config.json")
        let nestedRefused = refusedField { try ProxyConfigPersistence.save(ttl, to: nested) } == "health.directConnectTTL"
        let parentAbsent = !FileManager.default.fileExists(atPath: parent.path)

        // Validation keeps the domain value: 90.5 seconds is a valid runtime duration,
        // so the refusal stays at the save. A NaN is not a runtime duration at all.
        let domainKeepsSeconds = !ttl.validate().contains(where: isUnrepresentable)
        let validationRefusesNonFinite = nonFinite.validate().contains(where: isUnrepresentable)

        let checks: [ScenarioAssertion] = [
            .init("a whole-millisecond timeout and a whole-minute TTL round-trip exactly", wholeRoundTrip),
            .init("a 90.5-second TTL is refused by field before any write", ttlRefused),
            .init("a sub-millisecond timeout is refused by field before any write", subMillisecondRefused),
            .init("a NaN interval is refused by field before any write", nonFiniteRefused),
            .init("the previous file is byte-identical after every refusal", bytesUnchanged),
            .init("a refused save creates no missing parent directory", nestedRefused && parentAbsent),
            .init("validation keeps the 90.5-second domain value; the refusal stays at the save", domainKeepsSeconds),
            .init("validation refuses a NaN interval as an unrepresentable duration", validationRefusesNonFinite),
        ]
        let passed = checks.allSatisfy(\.passed)
        guard passed else {
            throw Failure(message: "config exact persistence assertions failed: \(checks.filter { !$0.passed }.map(\.name))")
        }
        return ScenarioResult(
            name: "config-exact-persistence", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: before.count, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: whole-millisecond and whole-minute values round-trip through scratch saves; inexact values are refused by field before any write, leaving the previous bytes and any missing parent untouched"]
        )
    }

    /// The field of the representability refusal that `body` throws, or nil when it
    /// succeeds or throws anything else.
    private static func refusedField(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as ConfigFileRepresentabilityError {
            return error.field
        } catch {
            return nil
        }
    }

    private static func isUnrepresentable(_ error: ConfigValidationError) -> Bool {
        if case .unrepresentableDuration = error { return true }
        return false
    }
}
