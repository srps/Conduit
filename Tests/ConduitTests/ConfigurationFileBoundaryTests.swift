// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyKernel

/// The runtime configuration file boundary (decisions 0021, 0022 and 0024), through the real readers and loaders. The filter
/// and the typed decoder are compared on the same bytes, so a difference in what they accept is a failure, not a guess.
final class ConfigurationFileBoundaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-file-boundary-\(UUID().uuidString)", isDirectory: true)
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

    /// The text of a runtime file with `depth` unknown nested arrays inside the root object.
    private func nestedUnknown(_ depth: Int) -> Data {
        Data(#"{"profileName":"P","unknown":"#.utf8)
            + Data(String(repeating: "[", count: depth).utf8)
            + Data(String(repeating: "]", count: depth).utf8)
            + Data("}".utf8)
    }

    private func typedAccepts(_ data: Data) -> Bool {
        (try? CanonicalJSON.decoder().decode(ProxyConfig.self, from: data)) != nil
    }

    private func gateAccepts(_ data: Data) -> Bool {
        (try? ProxyConfigPersistence.decode(data, source: "test")) != nil
    }

    // MARK: - Depth

    func testFilterDepthIsTheDepthTheTypedDecoderReads() {
        XCTAssertTrue(typedAccepts(nestedUnknown(1)))
        XCTAssertFalse(typedAccepts(nestedUnknown(5_000)))
        // Find the deepest nesting the typed decoder reads, by search rather than by assumption.
        var accepted = 1
        var refused = 5_000
        while refused - accepted > 1 {
            let middle = (accepted + refused) / 2
            if typedAccepts(nestedUnknown(middle)) {
                accepted = middle
            } else {
                refused = middle
            }
        }
        // The root object is the first container, so the deepest accepted total is `accepted + 1`.
        XCTAssertEqual(accepted + 1, RuntimeFileFilter.maximumDepth, "the filter's depth limit is the typed decoder's")
        XCTAssertEqual(gateAccepts(nestedUnknown(accepted)), typedAccepts(nestedUnknown(accepted)))
        XCTAssertEqual(gateAccepts(nestedUnknown(accepted + 1)), typedAccepts(nestedUnknown(accepted + 1)))
        XCTAssertTrue(gateAccepts(nestedUnknown(accepted)))
        XCTAssertFalse(gateAccepts(nestedUnknown(accepted + 1)))
    }

    // MARK: - Filter bounds and keys

    func testFilteredOutputIsNeverLongerThanTheInput() throws {
        let text = #"{ "profileName" : "P" , "junk" : [ 1 , 2 , 3 ] , "profileName" : "later" }"#
        let data = Data(text.utf8)
        let filtered = try data.withUnsafeBytes { raw in
            try RuntimeFileFilter.filter(
                UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count),
                root: RuntimeFileSchema.root(.runtimeOnly)
            )
        }
        XCTAssertLessThanOrEqual(filtered.bytes.count, data.count)
        XCTAssertEqual(String(decoding: filtered.bytes, as: UTF8.self), #"{"profileName":"P"}"#)
    }

    func testNestedFirstKnownKeyWinsIncludingAnEscapedSpelling() throws {
        let env = try environment("nested")
        let text = #"{"upstreams":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"A","\u0068ost":"first.example.test","host":"second.example.test","port":8080,"enabled":true,"priority":0,"junk":{"x":[1]}}]}"#
        XCTAssertTrue(text.contains(#""\u0068ost":"first.example.test""#), "the first spelling of host is the escaped one")
        try Data(text.utf8).write(to: env.configFile)
        let config = try ProxyConfigPersistence.load(from: env.configFile, allowMissing: false)
        XCTAssertEqual(config.upstreams.first?.host, "first.example.test")
    }

    func testAnUnknownExponentBeyondDoubleRangeIsAcceptedWithoutConversion() throws {
        let data = Data(#"{"profileName":"P","unknownExponent":1e400}"#.utf8)
        XCTAssertTrue(gateAccepts(data))
        XCTAssertEqual(try ProxyConfigPersistence.decode(data, source: "test").profileName, "P")
    }

    // MARK: - Legacy components and frozen reads

    func testAPresentSidecarIgnoresItsLegacyKeysEvenWhenTheyHaveTheWrongKind() throws {
        let env = try environment("sidecar-present")
        try Data(#"{"profileName":"P","manageSystemProxy":[1,2]}"#.utf8).write(to: env.configFile)
        try Data(#"{"manageSystemProxy":true}"#.utf8).write(to: env.platformConfigFile)
        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: env)
        XCTAssertTrue(loaded.platformConfig.manageSystemProxy)
        XCTAssertFalse(loaded.warnings.contains { $0.contains("Legacy platform") })
        XCTAssertEqual(loaded.config.profileName, "P")
    }

    func testAMissingSidecarWithAWrongKindLegacyValueFallsBackWithAWarning() throws {
        let env = try environment("sidecar-missing")
        try Data(#"{"profileName":"P","manageSystemProxy":[1,2]}"#.utf8).write(to: env.configFile)
        let loaded = try ProxyConfigPersistence.loadAllMigrating(in: env)
        XCTAssertFalse(loaded.platformConfig.manageSystemProxy)
        XCTAssertTrue(loaded.warnings.contains { $0.contains("Legacy platform") })
        XCTAssertEqual(loaded.config.profileName, "P")
    }

    func testAPresentSidecarNeverChecksItsLegacyPreferenceLimit() throws {
        let env = try environment("prefs-present")
        let oversized = String(repeating: "a", count: 16_385)
        try (Data(#"{"profileName":"P","preferredBrowserTestURL":""#.utf8) + Data(oversized.utf8) + Data(#""}"#.utf8))
            .write(to: env.configFile)
        try Data(#"{"showMenuBarIcon":true}"#.utf8).write(to: env.preferencesFile)
        XCTAssertEqual(try ProxyConfigPersistence.loadAllMigrating(in: env).config.profileName, "P")
    }

    func testAMissingSidecarOverLimitLegacyPreferenceIsRefused() throws {
        let env = try environment("prefs-missing")
        let oversized = String(repeating: "a", count: 16_385)
        try (Data(#"{"profileName":"P","preferredBrowserTestURL":""#.utf8) + Data(oversized.utf8) + Data(#""}"#.utf8))
            .write(to: env.configFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadAllMigrating(in: env)) { error in
            XCTAssertTrue((error as? ConfigurationLoadError)?.reason.contains("resource limit") == true)
        }
    }

    func testLegacyComponentsComeFromTheBytesReadOnceEvenAfterTheFileIsRemoved() throws {
        let env = try environment("frozen")
        try Data(#"{"profileName":"P","manageSystemProxy":true}"#.utf8).write(to: env.configFile)
        let bytes = try RuntimeConfigurationFileReader.read(at: env.configFile)
        try FileManager.default.removeItem(at: env.configFile)
        let document = try RuntimeFileDocument.decode(
            bytes, requirements: RuntimeFileRequirements(platform: true, preferences: false), source: "frozen"
        )
        guard case .decoded(let platform) = document.platform else {
            return XCTFail("the platform component was not decoded from the frozen read")
        }
        XCTAssertTrue(platform.manageSystemProxy)
    }

    // MARK: - Version

    func testAMissingOriginalVersionIsZeroAndAnAbsentConfigIsCurrent() throws {
        let document = try RuntimeFileDocument.decode(
            Data(#"{"profileName":"P"}"#.utf8), requirements: .runtimeOnly, source: "version"
        )
        XCTAssertEqual(document.originalSchemaVersion, 0)
        XCTAssertEqual(document.config.schemaVersion, ProxyConfig.currentSchemaVersion)
    }

    func testAnIntegralVersionFollowsTheTypedDecoder() throws {
        let data = Data(#"{"schemaVersion":2.0,"profileName":"P"}"#.utf8)
        XCTAssertEqual(gateAccepts(data), typedAccepts(data))
    }

    func testANewerVersionIsRefusedAtTheGate() {
        XCTAssertThrowsError(try ProxyConfigPersistence.decode(Data(#"{"schemaVersion":3}"#.utf8), source: "newer")) { error in
            XCTAssertTrue((error as? ConfigurationLoadError)?.reason.contains("newer") == true)
        }
    }

    // MARK: - Writer and import

    func testAnImportRefusedByTheGateLeavesTheSourceUnchanged() throws {
        let env = try environment("import")
        let bytes = Data(#"{"schemaVersion":3}"#.utf8)
        try bytes.write(to: env.configFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadImport(from: env.configFile))
        XCTAssertEqual(try Data(contentsOf: env.configFile), bytes)
    }

    func testAStandaloneLoadWithAPresentSidecarNeverReadsTheRuntimePath() throws {
        let env = try environment("standalone-present")
        // The runtime path is a directory: any read of it would be a refusal, so a returned sidecar proves it was not read.
        try FileManager.default.createDirectory(at: env.configFile, withIntermediateDirectories: true)
        try Data(#"{"manageSystemProxy":true}"#.utf8).write(to: env.platformConfigFile)
        try Data(#"{"showMenuBarIcon":false}"#.utf8).write(to: env.preferencesFile)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: env).manageSystemProxy)
        XCTAssertFalse(try AppPreferencesPersistence.load(in: env).showMenuBarIcon)
    }

    func testAStandaloneLoadMigratesAndWritesEachMissingSidecar() throws {
        let env = try environment("standalone-missing")
        try Data(#"{"profileName":"P","manageSystemProxy":true,"showMenuBarIcon":false}"#.utf8).write(to: env.configFile)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: env).manageSystemProxy)
        XCTAssertFalse(try AppPreferencesPersistence.load(in: env).showMenuBarIcon)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.platformConfigFile.path), "the platform migration is written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.preferencesFile.path), "the preferences migration is written")
    }

    func testAnOverLimitSaveCreatesNoDirectory() throws {
        let nested = directory.appendingPathComponent("never-made", isDirectory: true)
        var config = ProxyConfig.testFixture()
        config.upstreams = Array(repeating: UpstreamProxy(name: "A", host: "a.example.test", port: 8_080, priority: 0), count: 33)
        XCTAssertThrowsError(try ProxyConfigPersistence.save(config, to: nested.appendingPathComponent("config.json"))) { error in
            XCTAssertTrue(error is ConfigurationResourceRefusal)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
    }
}
