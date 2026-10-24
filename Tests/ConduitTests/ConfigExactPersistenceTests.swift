// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import XCTest
@testable import ProxyKernel

/// Save-before-apply for durations (decision 0023). Every save runs against a
/// scratch directory; no test reads or writes a real configuration.
final class ConfigExactPersistenceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-config-exact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Round trips

    /// The reproduced loss: a 1001 ms probe timeout was saved as 1000 ms, which
    /// truncated 1.001 * 1000 to 1000. This test failed before the conversion fix.
    func testWholeMillisecondTimeoutSurvivesSaveAndLoad() throws {
        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 1001
        let url = scratch.appendingPathComponent("config.json")

        try ProxyConfigPersistence.save(config, to: url)
        let loaded = try ProxyConfigPersistence.load(from: url)

        XCTAssertEqual(loaded.health.connectionCheckTimeout, 1.001)
        XCTAssertEqual(loaded.connectionCheckTimeoutMS, 1001)
        XCTAssertEqual(try legacyNumber("connectionCheckTimeoutMS", in: url), 1001)
    }

    func testWholeMinuteTTLSurvivesSaveAndLoad() throws {
        var config = ProxyConfig.testFixture()
        config.directConnectTTLMinutes = 10
        let url = scratch.appendingPathComponent("config.json")

        try ProxyConfigPersistence.save(config, to: url)
        let loaded = try ProxyConfigPersistence.load(from: url)

        XCTAssertEqual(loaded.health.directConnectTTL, 600)
        XCTAssertEqual(try legacyNumber("directConnectTTLMinutes", in: url), 10)
    }

    func testStagedBytesDecodeBackToTheFrozenInput() throws {
        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 1001
        config.directConnectTTLMinutes = 5
        config.health.checkInterval = 0.1 + 0.2

        let data = try ProxyConfigPersistence.stagedFileData(for: config)

        XCTAssertEqual(try JSONDecoder().decode(ProxyConfig.self, from: data), config)
    }

    // MARK: - Refusals before any write

    /// A 90.5-second TTL is not whole minutes. The save is refused by field, and
    /// the file that was there keeps its exact bytes.
    func testInexactTTLIsRefusedAndLeavesTheExistingFileBytes() throws {
        let url = scratch.appendingPathComponent("config.json")
        let existing = ProxyConfig.testFixture()
        try ProxyConfigPersistence.save(existing, to: url)
        let before = try Data(contentsOf: url)

        var candidate = existing
        candidate.health.directConnectTTL = 90.5
        let error = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(candidate, to: url) })

        XCTAssertEqual(error.field, "health.directConnectTTL")
        XCTAssertEqual(error.requirement, .wholeMinutes)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInexactTimeoutsAreRefusedByField() throws {
        let url = scratch.appendingPathComponent("config.json")
        try ProxyConfigPersistence.save(ProxyConfig.testFixture(), to: url)
        let before = try Data(contentsOf: url)

        var subMillisecond = ProxyConfig.testFixture()
        subMillisecond.health.connectionCheckTimeout = 0.0015
        var halfMillisecond = ProxyConfig.testFixture()
        halfMillisecond.health.connectionCheckTimeout = 1.0005
        let oneMillisecond: TimeInterval = 1.001
        var neighbour = ProxyConfig.testFixture()
        neighbour.health.connectionCheckTimeout = oneMillisecond.nextUp

        for candidate in [subMillisecond, halfMillisecond, neighbour] {
            let error = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(candidate, to: url) })
            XCTAssertEqual(error.field, "health.connectionCheckTimeout")
            XCTAssertEqual(error.requirement, .wholeMilliseconds)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNonFiniteAndHugeDurationsAreRefusedByFieldBeforeEncoding() throws {
        let url = scratch.appendingPathComponent("config.json")
        var nonFinite = ProxyConfig.testFixture()
        nonFinite.health.checkInterval = .nan
        var infinite = ProxyConfig.testFixture()
        infinite.proxy.stalledConnectionTimeout = .infinity
        var huge = ProxyConfig.testFixture()
        huge.health.directConnectTTL = 1e300

        let nanError = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(nonFinite, to: url) })
        XCTAssertEqual(nanError.field, "health.checkInterval")
        XCTAssertEqual(nanError.requirement, .finiteNumber)
        let infinityError = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(infinite, to: url) })
        XCTAssertEqual(infinityError.field, "proxy.stalledConnectionTimeout")
        let hugeError = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(huge, to: url) })
        XCTAssertEqual(hugeError.field, "health.directConnectTTL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The refusal creates no parent directory: a save into a missing folder
    /// changes nothing on disk.
    func testRefusedSaveCreatesNoMissingParent() throws {
        var candidate = ProxyConfig.testFixture()
        candidate.health.directConnectTTL = 90.5
        let parent = scratch.appendingPathComponent("missing", isDirectory: true)
        let url = parent.appendingPathComponent("config.json")

        let error = refusal { try ProxyConfigPersistence.save(candidate, to: url) }

        XCTAssertEqual(error?.field, "health.directConnectTTL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    /// The field codes name a config path and a fixed requirement only. The value,
    /// which can be a secret-adjacent number in a future field, is never echoed.
    func testRefusalDescriptionNamesTheFieldAndNotTheValue() throws {
        var candidate = ProxyConfig.testFixture()
        candidate.health.directConnectTTL = 90.5
        let error = try XCTUnwrap(refusal { try ProxyConfigPersistence.stagedFileData(for: candidate) })

        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains("health.directConnectTTL"))
        XCTAssertFalse(description.contains("90.5"))
    }

    /// 1e10 seconds is finite and round-trips as a JSON number, but it is past the
    /// runtime's nanosecond range. The save refuses it by field, before any write,
    /// so the file never holds a value the boundary would refuse at start.
    func testFiniteDurationPastTheRuntimeRangeIsRefusedBeforeWrite() throws {
        let url = scratch.appendingPathComponent("config.json")
        try ProxyConfigPersistence.save(ProxyConfig.testFixture(), to: url)
        let before = try Data(contentsOf: url)

        var candidate = ProxyConfig.testFixture()
        candidate.health.upstreamResponseTimeout = 1e10
        let error = try XCTUnwrap(refusal { try ProxyConfigPersistence.save(candidate, to: url) })

        XCTAssertEqual(error.field, "health.upstreamResponseTimeout")
        XCTAssertEqual(error.requirement, .runtimeRange)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// The encoder itself refuses an inexact value, so no other encode path can
    /// write a silently truncated number.
    func testEncoderRefusesAnInexactValueInsteadOfTruncating() throws {
        var candidate = ProxyConfig.testFixture()
        candidate.health.connectionCheckTimeout = 1.0005

        let error = try XCTUnwrap(refusal { _ = try JSONEncoder().encode(candidate) })

        XCTAssertEqual(error.field, "health.connectionCheckTimeout")
    }

    // MARK: - Reading the legacy units

    func testLegacyReadingsAreNearestNotTruncated() {
        var config = ProxyConfig.testFixture()
        config.health.connectionCheckTimeout = 1.001
        config.health.directConnectTTL = 300
        XCTAssertEqual(config.connectionCheckTimeoutMS, 1001)
        XCTAssertEqual(config.directConnectTTLMinutes, 5)
    }

    // MARK: - Runtime consumers keep the canonical value

    func testDataPathConnectTimeoutKeepsTheWholeMillisecond() {
        XCTAssertEqual(ConnectionPool.dataPathConnectTimeout(configured: 1.001, minimum: 0.5), .nanoseconds(1_001_000_000))
        XCTAssertEqual(ConnectionPool.dataPathConnectTimeout(configured: 0.5005, minimum: 0.5), .nanoseconds(500_500_000))
    }

    // MARK: - Validation

    /// Non-finite and unrepresentable durations are refused by field at validation,
    /// which is the runtime boundary, not only at the save.
    func testValidationRefusesUnrepresentableDurationsByField() {
        var config = ProxyConfig.testFixture()
        config.health.checkInterval = .nan
        config.health.circuitBreakerWindowSeconds = 1e300
        config.health.vpnFlapGraceSeconds = .infinity

        XCTAssertEqual(
            fields(in: config.validate()) { error in
                if case .unrepresentableDuration(let field) = error { return field }
                return nil
            },
            ["health.checkInterval", "health.circuitBreakerWindowSeconds", "health.vpnFlapGraceSeconds"]
        )
    }

    /// The domain keeps canonical seconds. 90.5 seconds is a valid runtime duration;
    /// the file-only refusal happens at the save, not in validation.
    func testValidationKeepsTheDomainValueOfNinetyPointFiveSeconds() {
        var config = ProxyConfig.testFixture()
        config.health.directConnectTTL = 90.5

        XCTAssertTrue(unrepresentable(config.validate()).isEmpty)
    }

    /// `vpnFlapMinVisibleSeconds` documents 0...30, and it had no check before.
    func testVpnFlapMinimumVisibleIsBoundedAsDocumented() {
        var config = ProxyConfig.testFixture()
        config.health.vpnFlapMinVisibleSeconds = 31
        XCTAssertEqual(
            fields(in: config.validate()) { error in
                if case .invalidDuration(let field, _) = error { return field }
                return nil
            },
            ["health.vpnFlapMinVisibleSeconds"]
        )
        config.health.vpnFlapMinVisibleSeconds = 30
        XCTAssertFalse(config.validate().contains { error in
            if case .invalidDuration(let field, _) = error { return field == "health.vpnFlapMinVisibleSeconds" }
            return false
        })
    }

    func testUpstreamPortsAreValidated() {
        var config = ProxyConfig.testFixture()
        config.upstreams[1].port = 70_000

        XCTAssertEqual(
            fields(in: config.validate()) { error in
                if case .invalidPort(let field, _) = error { return field }
                return nil
            },
            ["upstreams[1].port"]
        )
    }

    // MARK: - Helpers

    /// The refusal `body` throws, or nil when it succeeds or throws anything else.
    private func refusal<Result>(_ body: () throws -> Result) -> ConfigFileRepresentabilityError? {
        do {
            _ = try body()
            return nil
        } catch let error as ConfigFileRepresentabilityError {
            return error
        } catch {
            return nil
        }
    }

    private func legacyNumber(_ key: String, in url: URL) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (object as? [String: Any])?[key] as? Int
    }

    private func fields(in errors: [ConfigValidationError], _ match: (ConfigValidationError) -> String?) -> [String] {
        errors.compactMap(match)
    }

    private func unrepresentable(_ errors: [ConfigValidationError]) -> [String] {
        fields(in: errors) { error in
            if case .unrepresentableDuration(let field) = error { return field }
            return nil
        }
    }
}
