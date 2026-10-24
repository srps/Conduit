// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyKernel

/// The platform and preferences sidecar boundary (decision 0026), through the real sidecar readers, the staged saves and the
/// combined migration. Each case writes scratch files in its own environment, so what a file does at startup, reload and save
/// is what these tests assert. No real configuration is read or changed.
final class ConfigSidecarBoundaryTests: XCTestCase {
    private var directory: URL!
    private let suffix = Data(#""}"#.utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-sidecar-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func environment(_ name: String) throws -> RuntimeEnvironment {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RuntimeEnvironment(configDirectory: url)
    }

    /// Writes `data` as the platform sidecar of a fresh environment and loads it standalone: the value, or nil for the
    /// boundary's refusal. Any other error fails the test.
    private func platform(_ data: Data, _ name: String) throws -> PlatformIntegrationConfig? {
        let env = try environment(name)
        try data.write(to: env.platformConfigFile)
        do {
            return try PlatformConfigPersistence.load(in: env)
        } catch is ConfigurationLoadError {
            return nil
        }
    }

    /// Writes `data` as the preferences sidecar of a fresh environment and loads it standalone, with the same rule.
    private func preferences(_ data: Data, _ name: String) throws -> AppPreferences? {
        let env = try environment(name)
        try data.write(to: env.preferencesFile)
        do {
            return try AppPreferencesPersistence.load(in: env)
        } catch is ConfigurationLoadError {
            return nil
        }
    }

    /// The load refusal `body` raised, or nil. Any other error fails the test through the caller's assertion.
    private func refusal(_ body: () throws -> Void) -> ConfigurationLoadError? {
        do {
            try body()
            return nil
        } catch let error as ConfigurationLoadError {
            return error
        } catch {
            return nil
        }
    }

    /// The text of the filter's output for `data` under `root`, which names only the keys the root keeps.
    private func filtered(_ data: Data, _ root: ConfigurationFileRoot) throws -> String {
        let output = try data.withUnsafeBytes { raw in
            try ConfigurationFileFilter.filter(
                UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count),
                root: root
            )
        }
        return String(decoding: output.bytes, as: UTF8.self)
    }

    // MARK: - Physical budget

    func testEachSidecarBudgetIsOneHundredTwentyEightKiBAndIsTheRootsBudget() {
        XCTAssertEqual(DomainResourceLimits.sidecarFileBytes, 131_072)
        XCTAssertEqual(ConfigurationFileSchema.platformSidecar.maximumBytes, DomainResourceLimits.sidecarFileBytes)
        XCTAssertEqual(ConfigurationFileSchema.preferencesSidecar.maximumBytes, DomainResourceLimits.sidecarFileBytes)
    }

    func testAPlatformSidecarOfExactlyTheBudgetLoadsAndOneByteOverIsRefusedWithItsBytesKept() throws {
        let prefix = Data(#"{"manageSystemProxy":true,"pad":""#.utf8)
        let padding = DomainResourceLimits.sidecarFileBytes - prefix.count - suffix.count
        let exact = prefix + Data(repeating: 0x20, count: padding) + suffix
        XCTAssertEqual(exact.count, DomainResourceLimits.sidecarFileBytes)
        XCTAssertEqual(try platform(exact, "platform-exact")?.manageSystemProxy, true)

        let over = prefix + Data(repeating: 0x20, count: padding + 1) + suffix
        let env = try environment("platform-over")
        try over.write(to: env.platformConfigFile)
        XCTAssertNotNil(refusal { _ = try PlatformConfigPersistence.load(in: env) }, "the standalone read refuses one byte over")
        XCTAssertNotNil(refusal { _ = try ProxyConfigPersistence.loadAllMigrating(in: env) }, "the combined read refuses one byte over")
        XCTAssertEqual(try Data(contentsOf: env.platformConfigFile), over, "the rejected file keeps its original bytes")
    }

    func testAPreferencesSidecarOfExactlyTheBudgetLoadsAndOneByteOverIsRefused() throws {
        let prefix = Data(#"{"showMenuBarIcon":false,"pad":""#.utf8)
        let padding = DomainResourceLimits.sidecarFileBytes - prefix.count - suffix.count
        XCTAssertEqual(try preferences(prefix + Data(repeating: 0x20, count: padding) + suffix, "prefs-exact")?.showMenuBarIcon, false)
        XCTAssertNil(try preferences(prefix + Data(repeating: 0x20, count: padding + 1) + suffix, "prefs-over"))
    }

    // MARK: - Raw browser URL

    func testARawBrowserURLOfExactlyTheLimitLoadsAndOneByteOverIsRefused() throws {
        let limit = DomainResourceLimits.urlText
        let exact = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: "a", count: limit).utf8) + suffix
        XCTAssertEqual(try preferences(exact, "url-exact")?.preferredBrowserTestURL.utf8.count, limit)

        let over = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: "a", count: limit + 1).utf8) + suffix
        XCTAssertNil(try preferences(over, "url-over"))
    }

    func testWhitespaceIsCountedBeforeTheBlankFallbackApplies() throws {
        let limit = DomainResourceLimits.urlText
        let blank = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: " ", count: limit).utf8) + suffix
        XCTAssertEqual(try preferences(blank, "blank-exact")?.preferredBrowserTestURL, AppPreferences.defaultBrowserTestURL)

        let overBlank = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: " ", count: limit + 1).utf8) + suffix
        XCTAssertNil(try preferences(overBlank, "blank-over"), "an over-limit blank value is refused, not defaulted")
    }

    func testEscapedURLCharactersCountByTheirDecodedBytes() throws {
        let limit = DomainResourceLimits.urlText
        let unit = String(decoding: [UInt8(92), 117, 48, 48, 54, 49], as: UTF8.self)
        let escaped = Data(String(repeating: unit, count: limit).utf8)
        XCTAssertEqual(escaped.count, 6 * limit, "the fixture contains JSON escapes, not decoded ASCII")
        let prefix = Data(#"{"preferredBrowserTestURL":""#.utf8)
        let accepted = prefix + escaped + suffix
        XCTAssertEqual(try preferences(accepted, "escaped-exact")?.preferredBrowserTestURL, String(repeating: "a", count: limit))
        let refused = prefix + Data(String(repeating: unit, count: limit + 1).utf8) + suffix
        XCTAssertLessThan(refused.count, DomainResourceLimits.sidecarFileBytes)
        XCTAssertNil(try preferences(refused, "escaped-over"))
    }

    func testMultibyteURLsAreBoundedByUTF8BytesForReadAndSave() throws {
        let limit = DomainResourceLimits.urlText
        let unit = String(decoding: [UInt8(92), 117, 48, 48, 101, 57], as: UTF8.self)
        let expected = String(repeating: "é", count: limit / 2)
        XCTAssertEqual(expected.utf8.count, limit)
        let prefix = Data(#"{"preferredBrowserTestURL":""#.utf8)
        let escaped = Data(String(repeating: unit, count: limit / 2).utf8)
        XCTAssertEqual(escaped.count, 6 * (limit / 2))
        XCTAssertEqual(try preferences(prefix + escaped + suffix, "multibyte-exact")?.preferredBrowserTestURL, expected)
        XCTAssertNil(try preferences(prefix + escaped + Data("a".utf8) + suffix, "multibyte-over"))
        XCTAssertNoThrow(try AppPreferencesPersistence.stagedData(for: AppPreferences(preferredBrowserTestURL: expected)))
        XCTAssertThrowsError(try AppPreferencesPersistence.stagedData(for: AppPreferences(preferredBrowserTestURL: expected + "a")))
    }

    func testTheWorstApprovedURLStagesUnderTheBudgetAndReadsBackUnchanged() throws {
        // A control character is one decoded byte and six encoded bytes, so this is the widest value the URL limit admits.
        var worst = AppPreferences()
        worst.preferredBrowserTestURL = String(repeating: "\u{01}", count: DomainResourceLimits.urlText)
        let baseline = try AppPreferencesPersistence.stagedData(for: AppPreferences(preferredBrowserTestURL: ""))
        let staged = try AppPreferencesPersistence.stagedData(for: worst)
        XCTAssertLessThan(staged.count, DomainResourceLimits.sidecarFileBytes)
        XCTAssertEqual(staged.count - baseline.count, DomainResourceLimits.urlText * 6, "six encoded bytes per decoded control byte")

        let env = try environment("worst-url")
        try AppPreferencesPersistence.save(worst, in: env)
        XCTAssertEqual(try AppPreferencesPersistence.load(in: env).preferredBrowserTestURL, worst.preferredBrowserTestURL)
    }

    // MARK: - Save refusals

    func testAnOverLimitPreferencesSaveIsRefusedByItsFieldBeforeAnyDirectoryOrByte() {
        let nested = directory.appendingPathComponent("never-made", isDirectory: true)
        var prefs = AppPreferences()
        prefs.preferredBrowserTestURL = String(repeating: "b", count: DomainResourceLimits.urlText + 1)
        XCTAssertThrowsError(try AppPreferencesPersistence.save(prefs, in: RuntimeEnvironment(configDirectory: nested))) { error in
            guard let refusal = error as? ConfigurationSidecarSaveRefusal else {
                return XCTFail("the refusal is the sidecar's own: \(error)")
            }
            XCTAssertEqual(refusal.file, .preferences)
            XCTAssertEqual(refusal.cause, .resourceLimit(DomainResourceViolation(.browserTestURL, DomainResourceLimits.urlText)))
            XCTAssertEqual(refusal.event.event, "config.save_rejected")
            XCTAssertFalse(refusal.event.detail?.contains("bbbb") == true, "the event names the field, never the value")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path), "a refused save creates no directory")
    }

    func testARefusedPreferencesSaveKeepsThePreviousFileBytes() throws {
        let env = try environment("keep-previous")
        try AppPreferencesPersistence.save(AppPreferences(), in: env)
        let previous = try Data(contentsOf: env.preferencesFile)
        var prefs = AppPreferences()
        prefs.preferredBrowserTestURL = String(repeating: "b", count: DomainResourceLimits.urlText + 1)
        XCTAssertThrowsError(try AppPreferencesPersistence.save(prefs, in: env))
        XCTAssertEqual(try Data(contentsOf: env.preferencesFile), previous)
    }

    func testASaveWritesExactlyTheBytesItsStagingProduced() throws {
        let env = try environment("staged-save")
        var prefs = AppPreferences()
        prefs.preferredBrowserTestURL = "https://staged.example.test/"
        let staged = try AppPreferencesPersistence.stagedData(for: prefs)
        try AppPreferencesPersistence.save(prefs, in: env)
        XCTAssertEqual(try Data(contentsOf: env.preferencesFile), staged)

        let platformStaged = try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig(manageSystemProxy: true))
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemProxy: true), in: env)
        XCTAssertEqual(try Data(contentsOf: env.platformConfigFile), platformStaged)
    }

    // MARK: - Strict grammar

    func testARawControlInvalidUTF8OrLoneSurrogateInAnIgnoredValueRefusesTheSidecar() throws {
        let prefix = Data(#"{"manageSystemProxy":true,"junk":""#.utf8)
        let refused: [(String, Data)] = [
            ("raw-control", prefix + Data([0x01]) + suffix),
            ("invalid-utf8", prefix + Data([0xFF]) + suffix),
            ("lone-surrogate", Data(#"{"manageSystemProxy":true,"junk":"\ud800"}"#.utf8)),
            ("bad-escape", Data(#"{"manageSystemProxy":true,"junk":"\x"}"#.utf8)),
        ]
        for (name, bytes) in refused {
            XCTAssertNil(try platform(bytes, name), name)
        }
    }

    func testALaterDuplicateIsGrammarCheckedButItsWrongKindIsDiscarded() throws {
        XCTAssertNil(try platform(Data(#"{"manageSystemProxy":true,"manageSystemProxy":"\x"}"#.utf8), "later-bad-escape"),
                     "a later duplicate with an invalid escape refuses the file")
        XCTAssertEqual(try platform(Data(#"{"manageSystemProxy":true,"manageSystemProxy":"yes"}"#.utf8), "later-wrong-kind")?.manageSystemProxy,
                       true, "a later duplicate is discarded before its kind is read, as the first known key wins")
    }

    func testAnEscapedSpellingOfTheFirstKnownKeyWins() throws {
        let prefix = Data([UInt8(123), 34, 92, 117, 48, 48, 54, 100])
        let data = prefix + Data(#"anageSystemProxy":true,"manageSystemProxy":false}"#.utf8)
        XCTAssertEqual(data.count, Data(#"{"manageSystemProxy":true,"manageSystemProxy":false}"#.utf8).count + 5)
        XCTAssertEqual(try platform(data, "escaped-first")?.manageSystemProxy, true)
    }

    func testALaterOverLimitURLIsDiscardedWithoutChargingItsBudget() throws {
        let first = "https://first.example.test/"
        let bytes = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(first.utf8)
            + Data(#"","preferredBrowserTestURL":""#.utf8)
            + Data(String(repeating: "b", count: DomainResourceLimits.urlText + 1).utf8) + suffix
        XCTAssertLessThan(bytes.count, DomainResourceLimits.sidecarFileBytes)
        XCTAssertEqual(try preferences(bytes, "later-overlimit")?.preferredBrowserTestURL, first)
    }

    func testAnIgnoredExponentBeyondDoubleRangeIsAcceptedWithoutConversion() throws {
        let data = Data(#"{"manageSystemProxy":true,"unknownExponent":1e400}"#.utf8)
        XCTAssertEqual(try platform(data, "exponent")?.manageSystemProxy, true)
    }

    func testRetiredPlatformFieldsAreIgnoredWhateverTheirValidValue() throws {
        let data = Data(#"{"autoEnableOnVPN":[1,{"a":null}],"autoDisableOffVPN":true,"launchAtLogin":true}"#.utf8)
        XCTAssertEqual(try platform(data, "retired")?.launchAtLogin, true)
    }

    func testALargeUnknownArrayUnderTheBudgetIsDiscardedWithoutExpansion() throws {
        let items = Array(repeating: "0", count: 60_000).joined(separator: ",")
        let data = Data(#"{"manageSystemProxy":true,"junk":["#.utf8) + Data(items.utf8) + Data("]}".utf8)
        XCTAssertLessThan(data.count, DomainResourceLimits.sidecarFileBytes)
        XCTAssertEqual(try filtered(data, ConfigurationFileSchema.platformSidecar), #"{"manageSystemProxy":true}"#)
        XCTAssertEqual(try platform(data, "dense")?.manageSystemProxy, true)
    }

    func testTheSidecarRootKeepsOnlyItsOwnKeys() throws {
        let data = Data(#"{"profileName":"P","manageSystemProxy":true,"preferredBrowserTestURL":"x"}"#.utf8)
        XCTAssertEqual(try filtered(data, ConfigurationFileSchema.platformSidecar), #"{"manageSystemProxy":true}"#)
        XCTAssertEqual(try filtered(data, ConfigurationFileSchema.preferencesSidecar), #"{"preferredBrowserTestURL":"x"}"#)
    }

    func testAnEmptyNonObjectOrTrailingSidecarIsRefused() throws {
        XCTAssertNil(try platform(Data(), "empty"))
        XCTAssertNil(try platform(Data("[]".utf8), "array"))
        XCTAssertNil(try platform(Data("null".utf8), "null"))
        XCTAssertNil(try platform(Data(#"{"manageSystemProxy":true}x"#.utf8), "trailing"))
    }

    func testANullKnownValueReadsAsTheDefault() throws {
        XCTAssertEqual(try platform(Data(#"{"manageSystemProxy":null,"launchAtLogin":true}"#.utf8), "null-value")?.manageSystemProxy, false)
    }

    // MARK: - Wrong kinds

    func testEveryKnownKeyRefusesAWrongKindValueInItsSidecar() throws {
        for key in PlatformIntegrationConfig.CodingKeys.allCases {
            XCTAssertNil(try platform(Data("{\"\(key.stringValue)\":[1]}".utf8), "platform-\(key.stringValue)"), key.stringValue)
        }
        for key in AppPreferences.CodingKeys.allCases {
            XCTAssertNil(try preferences(Data("{\"\(key.stringValue)\":[1]}".utf8), "prefs-\(key.stringValue)"), key.stringValue)
        }
    }

    func testAWrongKindSidecarNeverFallsBackToTheRuntimeLegacyValue() throws {
        let env = try environment("no-fallback")
        try Data(#"{"profileName":"P","manageSystemProxy":true}"#.utf8).write(to: env.configFile)
        try Data(#"{"manageSystemProxy":"yes"}"#.utf8).write(to: env.platformConfigFile)
        XCTAssertEqual(refusal { _ = try ProxyConfigPersistence.loadAllMigrating(in: env) }?.reason,
                       "The configuration is not valid Conduit JSON.")
        XCTAssertThrowsError(try PlatformConfigPersistence.load(in: env))
        XCTAssertEqual(try Data(contentsOf: env.platformConfigFile), Data(#"{"manageSystemProxy":"yes"}"#.utf8))
    }

    func testAMissingSidecarStillFallsBackForAWrongKindLegacyValue() throws {
        let env = try environment("legacy-fallback")
        try Data(#"{"profileName":"P","manageSystemProxy":[1,2]}"#.utf8).write(to: env.configFile)
        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: env)
        XCTAssertFalse(loaded.platformConfig.manageSystemProxy)
        XCTAssertTrue(loaded.warnings.contains { $0.contains("Legacy platform") })
    }

    // MARK: - Runtime and sidecar parity

    func testTheSidecarAndTheRuntimeLegacyComponentDecodeTheSameAcceptedValues() throws {
        let inputs = [
            #"{"manageSystemProxy":true,"manageSystemProxy":false,"launchAtLogin":true,"unknown":[1,{"x":null}]}"#,
            #"{"manageSystemProxy":true,"launchAtLogin":true}"#,
            #"{"manageSystemProxy":null,"manageDNSResolvers":true}"#,
            #"{"autoEnableOnVPN":true,"manageSystemDNS":true}"#,
        ]
        for text in inputs {
            let data = Data(text.utf8)
            let sidecar = try XCTUnwrap(try platform(data, "parity-sidecar-\(text.hashValue)"), text)
            let document = try RuntimeFileDocument.decode(
                data, requirements: RuntimeFileRequirements(platform: true, preferences: false), source: "parity"
            )
            guard case .decoded(let legacy) = document.platform else {
                return XCTFail("the legacy platform component was not decoded: \(text)")
            }
            XCTAssertEqual(sidecar, legacy, text)
        }
    }

    // MARK: - Migration and staging

    func testAnOverLimitLegacyPreferenceRefusesTheCombinedLoadBeforeAnyMigrationWrite() throws {
        let env = try environment("stage-refused")
        let runtime = Data(#"{"profileName":"P","manageSystemProxy":true,"preferredBrowserTestURL":""#.utf8)
            + Data(String(repeating: "a", count: DomainResourceLimits.urlText + 1).utf8) + suffix
        try runtime.write(to: env.configFile)
        XCTAssertNotNil(refusal { _ = try ProxyConfigPersistence.loadAllMigrating(in: env) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.platformConfigFile.path), "no platform sidecar is staged or written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.preferencesFile.path), "no preferences sidecar is staged or written")
        XCTAssertEqual(try Data(contentsOf: env.configFile), runtime)
    }

    func testOneUnstageableCandidateStartsNoMigrationWriteAndKeepsTheOriginals() throws {
        // A finite duration past the runtime's range (decision 0023) is refused by the runtime rewrite's stage. The platform and
        // preferences candidates stage cleanly, and they are still not written, so no migration is partly applied.
        let env = try environment("unstageable")
        let original = Data(#"{"profileName":"P","manageSystemProxy":true,"healthCheckIntervalSeconds":1e300}"#.utf8)
        try original.write(to: env.configFile)
        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: env)
        XCTAssertTrue(loaded.migrated)
        XCTAssertTrue(loaded.warnings.contains { $0.contains("Config schema migrated in memory but could not be written") },
                      "the staging failure is reported as its own warning")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.platformConfigFile.path), "no platform sidecar is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.preferencesFile.path), "no preferences sidecar is written")
        XCTAssertEqual(try Data(contentsOf: env.configFile), original, "the original runtime file keeps its bytes")
    }

    func testAValidLegacyMigrationWritesEachSidecarAsTheBytesItsStagingProduced() throws {
        let env = try environment("migrate")
        try Data(#"{"profileName":"P","manageSystemProxy":true,"showMenuBarIcon":false}"#.utf8).write(to: env.configFile)
        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: env)
        XCTAssertEqual(try Data(contentsOf: env.platformConfigFile),
                       try PlatformConfigPersistence.stagedData(for: loaded.platformConfig))
        XCTAssertEqual(try Data(contentsOf: env.preferencesFile),
                       try AppPreferencesPersistence.stagedData(for: loaded.appPreferences))
    }

    func testARefusedSidecarKeepsItsBytesThroughEveryLoad() throws {
        let env = try environment("kept")
        let original = Data(#"{"manageSystemProxy":true,"x":"\x"}"#.utf8)
        try original.write(to: env.platformConfigFile)
        XCTAssertNotNil(refusal { _ = try PlatformConfigPersistence.load(in: env) })
        XCTAssertNotNil(refusal { _ = try ProxyConfigPersistence.loadAllMigrating(in: env) })
        XCTAssertEqual(try Data(contentsOf: env.platformConfigFile), original)
    }

    func testANamedPipeSidecarIsRefusedWithoutBlocking() throws {
        let env = try environment("pipe")
        XCTAssertEqual(mkfifo(env.platformConfigFile.path, 0o600), 0)
        XCTAssertThrowsError(try PlatformConfigPersistence.load(in: env)) { error in
            XCTAssertEqual((error as? ConfigurationLoadError)?.reason, "The configuration file could not be read: not a regular file.")
        }
    }
}
