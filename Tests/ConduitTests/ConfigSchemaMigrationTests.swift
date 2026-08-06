// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// `ProxyConfigPersistence.migrate` rewrites *stale defaults* on load, never
/// user choices. The test for "did the user touch this?" is whether the
/// persisted value still equals the default it shipped with — so every
/// transform needs both halves asserted: the untouched default moves, and a
/// customized value does not.
final class ConfigSchemaMigrationTests: XCTestCase {

    // MARK: - v2: DoH providers by IP literal

    /// The v1 default named its DoH providers by hostname, which cannot be
    /// resolved on exactly the networks where the DoH path is needed, and which
    /// filtering proxies block by URL category. An install carrying the
    /// untouched v1 list gets the IP-literal list.
    func testMigratesUntouchedLegacyDoHProviders() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = DNSSection.legacyHostnameDoHProviders

        let migrated = ProxyConfigPersistence.migrate(config, from: 1)

        XCTAssertEqual(migrated.dohProviders, DNSSection.defaultDoHProviders)
    }

    func testDoesNotTouchCustomDoHProviders() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = ["https://doh.corp.example/dns-query"]

        let migrated = ProxyConfigPersistence.migrate(config, from: 1)

        XCTAssertEqual(migrated.dohProviders, ["https://doh.corp.example/dns-query"])
    }

    /// A partially-edited list is a user choice too: the user removed a
    /// provider they did not want, and re-adding the full default would undo
    /// that.
    func testDoesNotTouchPartiallyEditedLegacyList() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = Array(DNSSection.legacyHostnameDoHProviders.dropLast())

        let migrated = ProxyConfigPersistence.migrate(config, from: 1)

        XCTAssertEqual(migrated.dohProviders, Array(DNSSection.legacyHostnameDoHProviders.dropLast()))
    }

    /// Already-current configs must be left alone, so that a user who
    /// deliberately went back to hostname providers after migrating keeps them.
    func testDoesNotReapplyTransformAtCurrentVersion() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = DNSSection.legacyHostnameDoHProviders

        let migrated = ProxyConfigPersistence.migrate(config, from: ProxyConfig.currentSchemaVersion)

        XCTAssertEqual(migrated.dohProviders, DNSSection.legacyHostnameDoHProviders)
    }

    /// An unversioned file decodes as version 0 and must still pick up every
    /// transform.
    func testMigratesFromUnversionedConfig() {
        var config = ProxyConfig.testFixture()
        config.dohProviders = DNSSection.legacyHostnameDoHProviders

        let migrated = ProxyConfigPersistence.migrate(config, from: 0)

        XCTAssertEqual(migrated.dohProviders, DNSSection.defaultDoHProviders)
    }

    // MARK: - Headless / non-rewriting loads

    /// Migration is not optional for a reader. The headless CLIs load through
    /// `load(from:)`, and if that skipped transforms they would run against a
    /// config the current code has already disowned — here, provider hostnames
    /// that cannot be reached on the very networks the transform exists for.
    func testNonRewritingLoadStillAppliesMigrations() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("config.json")
        var config = ProxyConfig.testFixture()
        config.schemaVersion = 1
        config.dohProviders = DNSSection.legacyHostnameDoHProviders
        try ProxyConfigPersistence.save(config, to: file)
        let before = try Data(contentsOf: file)

        let loaded = ProxyConfigPersistence.load(from: file)

        XCTAssertEqual(loaded.dohProviders, DNSSection.defaultDoHProviders)

        // ...and it must not write. `pm-proxy`'s contract is that it touches
        // nothing on the host; a migrating load that rewrote the user's config
        // would break that.
        XCTAssertEqual(try Data(contentsOf: file), before, "load(from:) must not rewrite the file")
    }

    // MARK: - End-to-end through loadMigrating

    func testLoadMigratingRewritesFileAndStampsVersion() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("config.json")
        var config = ProxyConfig.testFixture()
        config.schemaVersion = 1
        config.dohProviders = DNSSection.legacyHostnameDoHProviders
        try ProxyConfigPersistence.save(config, to: file)

        let result = ProxyConfigPersistence.loadMigrating(from: file)

        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.config.dohProviders, DNSSection.defaultDoHProviders)
        XCTAssertEqual(result.config.schemaVersion, ProxyConfig.currentSchemaVersion)

        // The rewrite must be persisted, not just applied in memory, or every
        // launch would migrate again.
        let reloaded = ProxyConfigPersistence.loadMigrating(from: file)
        XCTAssertFalse(reloaded.migrated)
        XCTAssertEqual(reloaded.config.dohProviders, DNSSection.defaultDoHProviders)
    }
}
