// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitShared
import ProxyKernel

/// The platform and preferences file boundary (decision 0026), headless. It drives the bounded sidecar read, the strict filter,
/// the staged save and the combined migration against scratch files under a temporary directory, one fresh environment per
/// case. It opens no socket, changes no system state and writes only inside its own scratch directory.
enum ConfigSidecarBoundaryScenario {
    static func run() throws -> ScenarioResult {
        let started = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-config-sidecar-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleaned = false
        defer {
            if !cleaned {
                do { try FileManager.default.removeItem(at: root) }
                catch { fputs("config-sidecar-boundary cleanup failed: " + error.localizedDescription + "\n", stderr) }
            }
        }
        var checks: [ScenarioAssertion] = []
        var caseCount = 0
        func fresh() throws -> RuntimeEnvironment {
            caseCount += 1
            return try environment(in: root.appendingPathComponent("case-\(caseCount)", isDirectory: true))
        }
        let limit = DomainResourceLimits.sidecarFileBytes
        let suffix = Data(#""}"#.utf8)

        checks.append(.init("each sidecar's budget is 131072 bytes", limit == 131_072))

        // Physical budget: exact and one byte over, on the same padded platform file.
        let padPrefix = Data(#"{"manageSystemProxy":true,"pad":""#.utf8)
        let padding = limit - padPrefix.count - suffix.count
        let exactBytes = padPrefix + Data(repeating: 0x20, count: padding) + suffix
        let exactEnv = try fresh()
        try exactBytes.write(to: exactEnv.platformConfigFile)
        checks.append(.init("a platform sidecar of exactly the budget loads",
                            (try? PlatformConfigPersistence.load(in: exactEnv))?.manageSystemProxy == true))

        let overEnv = try fresh()
        let overBytes = padPrefix + Data(repeating: 0x20, count: padding + 1) + suffix
        try overBytes.write(to: overEnv.platformConfigFile)
        checks.append(.init("a platform sidecar one byte over the budget is refused standalone and combined, and keeps its bytes",
                            isRefused { _ = try PlatformConfigPersistence.load(in: overEnv) }
                                && isRefused { _ = try ProxyConfigPersistence.loadAllMigrating(in: overEnv) }
                                && kept(overEnv.platformConfigFile, overBytes)))

        // Raw browser URL: 16384 bytes, counted before the blank fallback and before any escape is expanded.
        let urlEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: "a", count: 16_384).utf8) + suffix)
            .write(to: urlEnv.preferencesFile)
        checks.append(.init("a raw browser URL of exactly 16384 bytes loads",
                            (try? AppPreferencesPersistence.load(in: urlEnv))?.preferredBrowserTestURL.utf8.count == 16_384))

        let overURLEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: "a", count: 16_385).utf8) + suffix)
            .write(to: overURLEnv.preferencesFile)
        checks.append(.init("a raw browser URL one byte over 16384 is refused by the sidecar read",
                            isRefused { _ = try AppPreferencesPersistence.load(in: overURLEnv) }))

        let blankEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: " ", count: 16_384).utf8) + suffix)
            .write(to: blankEnv.preferencesFile)
        checks.append(.init("16384 bytes of whitespace are counted, then read as the default URL",
                            (try? AppPreferencesPersistence.load(in: blankEnv))?.preferredBrowserTestURL == AppPreferences.defaultBrowserTestURL))

        let blankOverEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: " ", count: 16_385).utf8) + suffix)
            .write(to: blankOverEnv.preferencesFile)
        checks.append(.init("16385 bytes of whitespace are refused before the blank fallback can apply",
                            isRefused { _ = try AppPreferencesPersistence.load(in: blankOverEnv) }))

        let escapedUnit = String(decoding: [UInt8(92), 117, 48, 48, 54, 49], as: UTF8.self)
        let escapedEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: escapedUnit, count: 16_384).utf8) + suffix)
            .write(to: escapedEnv.preferencesFile)
        checks.append(.init("16384 escaped characters count by their decoded bytes and load",
                            escapedUnit.utf8.count == 6 && (try? AppPreferencesPersistence.load(in: escapedEnv))?.preferredBrowserTestURL == String(repeating: "a", count: 16_384)))

        let escapedOverEnv = try fresh()
        try (Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(String(repeating: escapedUnit, count: 16_385).utf8) + suffix)
            .write(to: escapedOverEnv.preferencesFile)
        checks.append(.init("16385 escaped characters are refused by their decoded count",
                            isRefused { _ = try AppPreferencesPersistence.load(in: escapedOverEnv) }))

        // Worst approved save: every URL byte is a control character, which the canonical encoder writes as six bytes.
        let worstEnv = try fresh()
        var worst = AppPreferences()
        worst.preferredBrowserTestURL = String(repeating: "\u{01}", count: 16_384)
        let baseline = try AppPreferencesPersistence.stagedData(for: AppPreferences(preferredBrowserTestURL: ""))
        let worstBytes = try AppPreferencesPersistence.stagedData(for: worst)
        checks.append(.init("the worst approved URL, every byte escaped, stages under the budget at exactly 98304 extra bytes",
                            worstBytes.count <= limit && worstBytes.count - baseline.count == 98_304))
        try AppPreferencesPersistence.save(worst, in: worstEnv)
        checks.append(.init("the worst saved URL reads back unchanged",
                            (try? AppPreferencesPersistence.load(in: worstEnv))?.preferredBrowserTestURL == worst.preferredBrowserTestURL))

        // Strict grammar in ignored values and later duplicates.
        let rawControl = Data(#"{"manageSystemProxy":true,"junk":""#.utf8) + Data([0x01]) + suffix
        checks.append(.init("a raw control character in an ignored value refuses the platform sidecar",
                            try loadPlatform(rawControl, in: fresh()) == nil))
        let invalidUTF8 = Data(#"{"manageSystemProxy":true,"junk":""#.utf8) + Data([0xFF]) + suffix
        checks.append(.init("invalid UTF-8 in an ignored value refuses the platform sidecar",
                            try loadPlatform(invalidUTF8, in: fresh()) == nil))
        let loneSurrogate = Data(#"{"manageSystemProxy":true,"junk":"\ud800"}"#.utf8)
        checks.append(.init("a lone surrogate in an ignored value refuses the platform sidecar",
                            try loadPlatform(loneSurrogate, in: fresh()) == nil))
        let laterBadEscape = Data(#"{"manageSystemProxy":true,"manageSystemProxy":"\x"}"#.utf8)
        checks.append(.init("a later duplicate with an invalid escape refuses the platform sidecar",
                            try loadPlatform(laterBadEscape, in: fresh()) == nil))
        let escapedFirst = Data([UInt8(123), 34, 92, 117, 48, 48, 54, 100]) + Data(#"anageSystemProxy":true,"manageSystemProxy":false}"#.utf8)
        checks.append(.init("an escaped spelling of the first known key wins over a later one",
                            try loadPlatform(escapedFirst, in: fresh())?.manageSystemProxy == true))
        let ignoredExponent = Data(#"{"manageSystemProxy":true,"unknownExponent":1e400}"#.utf8)
        checks.append(.init("an ignored exponent beyond Double range is accepted without conversion",
                            try loadPlatform(ignoredExponent, in: fresh())?.manageSystemProxy == true))
        let retired = Data(#"{"autoEnableOnVPN":[1,{"a":null}],"autoDisableOffVPN":true,"launchAtLogin":true}"#.utf8)
        checks.append(.init("retired platform fields are ignored whatever their valid value",
                            try loadPlatform(retired, in: fresh())?.launchAtLogin == true))
        let denseItems = Array(repeating: "0", count: 60_000).joined(separator: ",")
        let dense = Data(#"{"manageSystemProxy":true,"junk":["#.utf8) + Data(denseItems.utf8) + Data("]}".utf8)
        let denseLoaded = try loadPlatform(dense, in: fresh())
        checks.append(.init("a large unknown array under the budget is discarded without expansion",
                            dense.count <= limit && denseLoaded?.manageSystemProxy == true))

        // Wrong kinds refuse, and no key falls back to the runtime file.
        var everyKeyRefused = true
        for key in PlatformIntegrationConfig.CodingKeys.allCases {
            if try loadPlatform(Data("{\"\(key.stringValue)\":[1]}".utf8), in: fresh()) != nil {
                everyKeyRefused = false
            }
        }
        for key in AppPreferences.CodingKeys.allCases {
            if try loadPreferences(Data("{\"\(key.stringValue)\":[1]}".utf8), in: fresh()) != nil {
                everyKeyRefused = false
            }
        }
        checks.append(.init("every known platform and preferences key refuses a wrong-kind value", everyKeyRefused))

        let wrongKindEnv = try fresh()
        try Data(#"{"profileName":"P","manageSystemProxy":true}"#.utf8).write(to: wrongKindEnv.configFile)
        try Data(#"{"manageSystemProxy":"yes"}"#.utf8).write(to: wrongKindEnv.platformConfigFile)
        checks.append(.init("a wrong-kind platform sidecar refuses the combined load and does not fall back to the runtime file",
                            isRefused { _ = try ProxyConfigPersistence.loadAllMigrating(in: wrongKindEnv) }))

        // Migration writes nothing until every candidate has staged.
        let stageEnv = try fresh()
        let runtimeWithOverLimitURL = Data(#"{"profileName":"P","manageSystemProxy":true,"preferredBrowserTestURL":""#.utf8)
            + Data(String(repeating: "a", count: 16_385).utf8) + suffix
        try runtimeWithOverLimitURL.write(to: stageEnv.configFile)
        checks.append(.init("an over-limit legacy preference refuses the combined load",
                            isRefused { _ = try ProxyConfigPersistence.loadAllMigrating(in: stageEnv) }))
        checks.append(.init("no migration sidecar is written and the runtime file keeps its bytes",
                            !FileManager.default.fileExists(atPath: stageEnv.platformConfigFile.path)
                                && !FileManager.default.fileExists(atPath: stageEnv.preferencesFile.path)
                                && kept(stageEnv.configFile, runtimeWithOverLimitURL)))

        let migrateEnv = try fresh()
        try Data(#"{"profileName":"P","manageSystemProxy":true,"showMenuBarIcon":false}"#.utf8).write(to: migrateEnv.configFile)
        let migrated = try ProxyConfigPersistence.loadAllMigrating(in: migrateEnv)
        let platformStaged = try PlatformConfigPersistence.stagedData(for: migrated.platformConfig)
        let preferencesStaged = try AppPreferencesPersistence.stagedData(for: migrated.appPreferences)
        checks.append(.init("a valid legacy migration writes each sidecar as the bytes its staging produced",
                            kept(migrateEnv.platformConfigFile, platformStaged) && kept(migrateEnv.preferencesFile, preferencesStaged)))

        // Saves: a refusal creates no directory and changes no byte.
        let neverDirectory = root.appendingPathComponent("never-made", isDirectory: true)
        var longPrefs = AppPreferences()
        longPrefs.preferredBrowserTestURL = String(repeating: "b", count: 16_385)
        let neverRefusal = saveRefusal { try AppPreferencesPersistence.save(longPrefs, in: RuntimeEnvironment(configDirectory: neverDirectory)) }
        checks.append(.init("an over-limit preferences save is refused by its field before its directory is created",
                            isBrowserURLRefusal(neverRefusal) && !FileManager.default.fileExists(atPath: neverDirectory.path)))

        let keepEnv = try fresh()
        try AppPreferencesPersistence.save(AppPreferences(), in: keepEnv)
        let keptBytes = try Data(contentsOf: keepEnv.preferencesFile)
        let keepRefusal = saveRefusal { try AppPreferencesPersistence.save(longPrefs, in: keepEnv) }
        checks.append(.init("a refused preferences save keeps the previous file bytes",
                            keepRefusal != nil && kept(keepEnv.preferencesFile, keptBytes)))

        // The staged bytes are the bytes a save writes.
        let defaults = AppPreferences()
        let stagedEnv = try fresh()
        try AppPreferencesPersistence.save(defaults, in: stagedEnv)
        checks.append(.init("a save writes exactly the bytes its staging produced",
                            kept(stagedEnv.preferencesFile, try AppPreferencesPersistence.stagedData(for: defaults))))

        // One candidate that cannot stage stops every migration write (decision 0026).
        let unstageableEnv = try fresh()
        let unstageable = Data(#"{"profileName":"P","manageSystemProxy":true,"healthCheckIntervalSeconds":1e300}"#.utf8)
        try unstageable.write(to: unstageableEnv.configFile)
        let unstageableLoad = try ProxyConfigPersistence.loadAllMigrating(in: unstageableEnv)
        let stagingReported = unstageableLoad.warnings.contains { $0.contains("could not be written") }
        checks.append(.init("a migration with an unstageable candidate writes no sidecar, keeps the runtime file and reports the stage",
                            !FileManager.default.fileExists(atPath: unstageableEnv.platformConfigFile.path)
                                && !FileManager.default.fileExists(atPath: unstageableEnv.preferencesFile.path)
                                && kept(unstageableEnv.configFile, unstageable)
                                && stagingReported))

        // A named pipe is refused without blocking.
        let pipeEnv = try fresh()
        guard mkfifo(pipeEnv.platformConfigFile.path, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        checks.append(.init("a named pipe sidecar is refused without blocking",
                            isRefused { _ = try PlatformConfigPersistence.load(in: pipeEnv) }))

        try FileManager.default.removeItem(at: root)
        cleaned = true
        return ScenarioResult(
            name: "config-sidecar-boundary", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["Scratch files only: the sidecar gate, the strict filter, the staged saves and the combined migration run under a temporary directory"]
        )
    }

    // MARK: - Helpers

    private static func environment(in directory: URL) throws -> RuntimeEnvironment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RuntimeEnvironment(configDirectory: directory)
    }

    /// Writes `data` as the platform sidecar and loads it standalone: the value, or nil for the boundary's refusal. Any other
    /// error is the scenario's own failure and is thrown.
    private static func loadPlatform(_ data: Data, in environment: RuntimeEnvironment) throws -> PlatformIntegrationConfig? {
        try data.write(to: environment.platformConfigFile)
        do {
            return try PlatformConfigPersistence.load(in: environment)
        } catch is ConfigurationLoadError {
            return nil
        }
    }

    /// Writes `data` as the preferences sidecar and loads it standalone, with the same nil-for-refusal rule.
    private static func loadPreferences(_ data: Data, in environment: RuntimeEnvironment) throws -> AppPreferences? {
        try data.write(to: environment.preferencesFile)
        do {
            return try AppPreferencesPersistence.load(in: environment)
        } catch is ConfigurationLoadError {
            return nil
        }
    }

    /// Whether `body` raised the load boundary's refusal. Any other error is not a refusal.
    private static func isRefused(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch is ConfigurationLoadError {
            return true
        } catch {
            fputs("config-sidecar-boundary unexpected load error: " + error.localizedDescription + "\n", stderr)
            return false
        }
    }

    /// The save refusal `body` raised, or nil.
    private static func saveRefusal(_ body: () throws -> Void) -> ConfigurationSidecarSaveRefusal? {
        do {
            try body()
            return nil
        } catch let refusal as ConfigurationSidecarSaveRefusal {
            return refusal
        } catch {
            fputs("config-sidecar-boundary unexpected save error: " + error.localizedDescription + "\n", stderr)
            return nil
        }
    }

    private static func isBrowserURLRefusal(_ refusal: ConfigurationSidecarSaveRefusal?) -> Bool {
        guard let refusal, refusal.file == .preferences, case .resourceLimit(let violation) = refusal.cause else {
            return false
        }
        return violation.field == .browserTestURL
    }

    /// Whether the file at `url` holds exactly `expected`.
    private static func kept(_ url: URL, _ expected: Data) -> Bool {
        do { return try Data(contentsOf: url) == expected }
        catch {
            fputs("config-sidecar-boundary verification read failed: " + error.localizedDescription + "\n", stderr)
            return false
        }
    }
}
