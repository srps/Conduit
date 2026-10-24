// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import ProxyKernel

/// The runtime configuration file boundary (decisions 0021, 0022 and 0024), headless. It drives the bounded reader, the strict
/// filter, the typed decode, the in-memory migration, the import gate and the writer against scratch files under a temporary
/// directory. It opens no socket, changes no system state, and writes only inside its own scratch directory.
enum ConfigFileBoundaryScenario {
    static func run() throws -> ScenarioResult {
        let started = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-config-file-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [ScenarioAssertion] = []

        let runtime = try environment(in: root.appendingPathComponent("runtime", isDirectory: true))
        let loadRuntime = { (text: String) in try load(text, at: runtime.configFile) }

        let big = runtime.configFile
        try Data(repeating: 0x20, count: 8_388_609).write(to: big)
        let oversize = refusal { _ = try ProxyConfigPersistence.loadMigrating(from: big, saveMigrated: false) }
        checks.append(.init("one byte over the 8 MiB file cap is refused before any decode", oversize?.reason.contains("size limit") == true))

        checks.append(.init("the first known key wins, including an escaped spelling of it",
                            profile(try loadRuntime(#"{"profileName":"first","profileName":"second"}"#)) == "first"))
        checks.append(.init("an unknown value with an invalid escape is refused, not skipped",
                            isRefused(try loadRuntime(#"{"profileName":"P","junk":"\x"}"#))))
        checks.append(.init("a later duplicate with an invalid escape is refused",
                            isRefused(try loadRuntime(#"{"profileName":"P","profileName":"\x"}"#))))
        let laterUpstreams = Array(repeating: "{}", count: 33).joined(separator: ",")
        checks.append(.init("a later duplicate list is grammar-checked but not charged to the first value's budget",
                            upstreamCount(try loadRuntime(#"{"upstreams":[],"upstreams":["# + laterUpstreams + "]}")) == 0))
        checks.append(.init("a valid unknown exponent beyond Double range is accepted without conversion",
                            profile(try loadRuntime(#"{"profileName":"P","unknownExponent":1e400}"#)) == "P"))
        checks.append(.init("a wrong-kind runtime value is refused before the typed decode",
                            isRefused(try loadRuntime(#"{"profileName":"P","localPort":"8080"}"#))))

        let legacy = try environment(in: root.appendingPathComponent("legacy", isDirectory: true))
        try Data(#"{"profileName":"P","manageSystemProxy":[1,2]}"#.utf8).write(to: legacy.configFile)
        let fallback = try ProxyConfigPersistence.loadAllMigrating(in: legacy)
        checks.append(.init("a wrong-kind legacy platform value falls back to defaults with a warning, and keeps the runtime",
                            fallback.platformConfig.manageSystemProxy == false
                                && fallback.warnings.contains { $0.contains("Legacy platform") }
                                && fallback.config.profileName == "P"))

        let overLegacy = try environment(in: root.appendingPathComponent("over-legacy", isDirectory: true))
        let longURL = String(repeating: "a", count: 16_385)
        try oversizedPreferenceFile(longURL).write(to: overLegacy.configFile)
        let overRefusal = refusal { _ = try ProxyConfigPersistence.loadAllMigrating(in: overLegacy) }
        checks.append(.init("an over-limit required legacy value is refused by its resource ceiling",
                            overRefusal?.reason.contains("resource limit") == true))

        let runtimeOnly = try ProxyConfigPersistence.decode(oversizedPreferenceFile(longURL), source: "scenario")
        checks.append(.init("the runtime-only gate reads no legacy component, so its over-limit value is not charged",
                            runtimeOnly.profileName == "P"))

        // Headless, this proves the import gate only. That the editor is not assigned is proven by the AppState harness test
        // `testAnImportOfANewerFileLeavesTheEditorUnchanged`, which drives `AppState.importConfiguration`.
        let newerURL = runtime.configFile
        let newerRefusal = refusal {
            try Data(#"{"schemaVersion":3,"profileName":"P"}"#.utf8).write(to: newerURL)
            _ = try ProxyConfigPersistence.loadImport(from: newerURL)
        }
        checks.append(.init("the import gate refuses a newer schema (gate only; editor assignment is proven by AppStateHarnessTests)",
                            newerRefusal?.reason.contains("newer") == true))

        let importBytes = Data(#"{"schemaVersion":3,"profileName":"P"}"#.utf8)
        let importURL = runtime.configFile
        try importBytes.write(to: importURL)
        let importRefusal = refusal { _ = try ProxyConfigPersistence.loadImport(from: importURL) }
        let importUnchanged = try Data(contentsOf: importURL) == importBytes
        checks.append(.init("an import refused by the gate leaves the source file's bytes unchanged",
                            importRefusal != nil && importUnchanged))

        let nested = root.appendingPathComponent("unmade", isDirectory: true)
        var overLimit = ProxyConfig.testFixture()
        overLimit.upstreams = Array(repeating: UpstreamProxy(name: "A", host: "a.example.test", port: 8_080, priority: 0), count: 33)
        let writerRefused = resourceRefusal { try ProxyConfigPersistence.save(overLimit, to: nested.appendingPathComponent("config.json")) }
        checks.append(.init("an over-limit config is refused by the writer before its directory is created",
                            writerRefused?.violation.field == .upstreams && !FileManager.default.fileExists(atPath: nested.path)))

        try FileManager.default.removeItem(at: root)
        return ScenarioResult(
            name: "config-file-boundary", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: the file gate, the strict filter and the legacy fallback run on scratch files; the writer refuses before creating a directory"]
        )
    }

    // MARK: - Helpers

    private static func environment(in directory: URL) throws -> RuntimeEnvironment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RuntimeEnvironment(configDirectory: directory)
    }

    private static func load(_ text: String, at url: URL) throws -> Result<ProxyConfig, Error> {
        try Data(text.utf8).write(to: url)
        do {
            return .success(try ProxyConfigPersistence.loadMigrating(from: url, saveMigrated: false).config)
        } catch {
            return .failure(error)
        }
    }

    private static func profile(_ result: Result<ProxyConfig, Error>) -> String? {
        if case .success(let config) = result {
            return config.profileName
        }
        return nil
    }

    private static func upstreamCount(_ result: Result<ProxyConfig, Error>) -> Int? {
        if case .success(let config) = result {
            return config.upstreams.count
        }
        return nil
    }

    private static func isRefused(_ result: Result<ProxyConfig, Error>) -> Bool {
        if case .failure(let error) = result {
            return error is ConfigurationLoadError
        }
        return false
    }

    /// The gate's own refusal, or nil. Any other error is not the file boundary's refusal and is reported as nil.
    private static func refusal(_ body: () throws -> Void) -> ConfigurationLoadError? {
        do {
            try body()
            return nil
        } catch let error as ConfigurationLoadError {
            return error
        } catch {
            return nil
        }
    }

    /// The writer's resource refusal, or nil.
    private static func resourceRefusal(_ body: () throws -> Void) -> ConfigurationResourceRefusal? {
        do {
            try body()
            return nil
        } catch let error as ConfigurationResourceRefusal {
            return error
        } catch {
            return nil
        }
    }

    /// A runtime file whose only legacy value is a preference URL of the given text, which the runtime-only gate ignores.
    private static func oversizedPreferenceFile(_ url: String) -> Data {
        Data(#"{"profileName":"P","preferredBrowserTestURL":""#.utf8) + Data(url.utf8) + Data(#""}"#.utf8)
    }
}
