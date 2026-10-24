// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyKernel

/// The file gate through its real adapters: `loadMigrating(from:)`, `loadAllMigrating(in:)` and `decode`. Each case writes
/// a runtime file and asserts what the gate accepts or refuses, with the fixed reason where one is named. The cursor's own
/// primitives are tested elsewhere; these tests show what a file does at the boundary.
final class ConfigurationFileGateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-file-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private let suffix = Data(#""}"#.utf8)

    /// Writes `bytes` as the runtime file of a fresh environment and loads it through the runtime-only gate.
    private func gate(_ bytes: Data, _ name: String) throws -> Result<ProxyConfig, Error> {
        let url = directory.appendingPathComponent("\(name).json")
        try bytes.write(to: url)
        do {
            return .success(try ProxyConfigPersistence.loadMigrating(from: url, saveMigrated: false).config)
        } catch {
            return .failure(error)
        }
    }

    private func reason(_ result: Result<ProxyConfig, Error>) -> String? {
        if case .failure(let error) = result {
            return (error as? ConfigurationLoadError)?.reason
        }
        return nil
    }

    private func profile(_ result: Result<ProxyConfig, Error>) -> String? {
        if case .success(let config) = result {
            return config.profileName
        }
        return nil
    }

    /// The fixed reason the gate uses for a violation. Its text is the typed check's own description.
    private func refusal(for violation: DomainResourceViolation) -> String {
        "The configuration exceeds a resource limit. \(violation.description)."
    }

    // MARK: - Malformed ignored and later duplicate values

    func testMalformedIgnoredValuesAreRefusedAndValidOnesAreKept() throws {
        let prefix = Data(#"{"profileName":"P","junk":""#.utf8)
        let refused: [(String, Data)] = [
            ("raw-control", prefix + Data([0x01]) + suffix),
            ("invalid-utf8", prefix + Data([0xFF]) + suffix),
            ("overlong-utf8", prefix + Data([0xC0, 0x80]) + suffix),
            ("lone-surrogate", Data(#"{"profileName":"P","junk":"\ud800"}"#.utf8)),
            ("unpaired-pair", Data(#"{"profileName":"P","junk":"\uD800A"}"#.utf8)),
            ("bad-escape", Data(#"{"profileName":"P","junk":"\x"}"#.utf8)),
            ("later-raw-control", Data(#"{"profileName":"P","profileName":""#.utf8) + Data([0x01]) + suffix),
            ("later-invalid-utf8", Data(#"{"profileName":"P","profileName":""#.utf8) + Data([0xFF]) + suffix),
            ("later-lone-surrogate", Data(#"{"profileName":"P","profileName":"\udc00"}"#.utf8)),
        ]
        for (name, bytes) in refused {
            let result = try gate(bytes, name)
            XCTAssertNotNil(reason(result), "\(name) must be refused")
        }
        XCTAssertEqual(profile(try gate(Data(#"{"profileName":"P","junk":"\uD83D\uDE00 \u00e9"}"#.utf8), "valid")), "P",
                       "a valid escape pair and a valid multibyte scalar in an ignored value are accepted")
    }

    // MARK: - Escaped known keys and discarded duplicates

    func testEscapedRootAndNestedDuplicatesKeepTheFirstValueAndDiscardTheRest() throws {
        // The first spelling of profileName and of host is escaped. Every later duplicate is over its limit, so each one
        // would fail if it were charged to the first value's budget.
        let longHost = String(repeating: "x", count: 300)
        let fortyUpstreams = Array(repeating: "{}", count: 40).joined(separator: ",")
        let longName = String(repeating: "y", count: 2_000)
        let text = #"""
        {"\u0070rofileName":"first","profileName":"second","upstreams":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"A","\u0068ost":"first.example.test","host":"second.example.test","port":8080,"enabled":true,"priority":0,"host":"\#(longHost)"}],"upstreams":[\#(fortyUpstreams)],"profileName":"\#(longName)"}
        """#
        XCTAssertTrue(text.utf8.contains(0x5c), "the runtime fixture must contain literal JSON escapes")
        let result = try gate(Data(text.utf8), "duplicates")
        XCTAssertEqual(profile(result), "first", "the first escaped spelling of profileName wins")
        if case .success(let config) = result {
            XCTAssertEqual(config.upstreams.count, 1, "a later over-limit list is skipped, not charged")
            XCTAssertEqual(config.upstreams.first?.host, "first.example.test", "the first escaped host wins over a later over-limit one")
        }
    }

    func testAnOverLimitLaterDuplicateStringIsNotChargedToTheFirstValue() throws {
        let text = #"{"profileName":"ok","profileName":""# + String(repeating: "z", count: 5_000) + #""}"#
        XCTAssertEqual(profile(try gate(Data(text.utf8), "later-string")), "ok")
    }

    // MARK: - Resource parity with the typed check

    /// Every single violation is refused by the file gate with the same field and limit the typed check reports on the same
    /// value. Each config is encoded with the canonical encoder, so the file holds exactly the value the typed check saw.
    func testSingleViolationsAreRefusedWithTheTypedChecksFieldAndLimit() throws {
        var cases: [(String, ProxyConfig)] = []

        var profileName = ProxyConfig()
        profileName.profileName = String(repeating: "a", count: 1_025)
        cases.append(("profileName", profileName))

        var username = ProxyConfig()
        username.auth.username = String(repeating: "u", count: 1_025)
        cases.append(("username", username))

        var upstreamCount = ProxyConfig()
        upstreamCount.upstreams = Array(repeating: UpstreamProxy(name: "A", host: "a.example.test", port: 8_080, priority: 0), count: 33)
        cases.append(("upstreams", upstreamCount))

        var upstreamName = ProxyConfig()
        upstreamName.upstreams = [UpstreamProxy(name: String(repeating: "n", count: 1_025), host: "h.example.test", port: 8_080, priority: 0)]
        cases.append(("upstreamName", upstreamName))

        var servers = ProxyConfig()
        servers.dns.entries = [DomainDNSEntry(domain: "d.example.test", servers: Array(repeating: "10.0.0.1", count: 9))]
        cases.append(("dnsServers", servers))

        var pattern = ProxyConfig()
        pattern.dns.interceptRules = [DNSInterceptRule(pattern: "*." + String(repeating: "a", count: 254), interceptIP: "127.0.0.2")]
        cases.append(("interceptPattern", pattern))

        var bypassCount = ProxyConfig()
        bypassCount.routing.noProxyHosts = Array(repeating: "x", count: 257)
        cases.append(("noProxyHosts", bypassCount))

        var bypassWidth = ProxyConfig()
        bypassWidth.routing.noProxyHosts = Array(repeating: String(repeating: "h", count: 253), count: 256)
        cases.append(("noProxyList", bypassWidth))

        var clients = ProxyConfig()
        clients.proxy.allowedClients = Array(repeating: "10.0.0.1", count: 257)
        cases.append(("allowedClients", clients))

        var providers = ProxyConfig()
        providers.dns.dohProviders = Array(repeating: "https://dns.example.test/q", count: 9)
        cases.append(("dohProviders", providers))

        var checkURL = ProxyConfig()
        checkURL.health.checkURL = "https://" + String(repeating: "a", count: 16_390)
        cases.append(("checkURL", checkURL))

        var tunnels = ProxyConfig()
        tunnels.tunnels.definitions = Array(repeating: TunnelDefinition(localPort: 1, remoteHost: "r.example.test", remotePort: 2), count: 129)
        cases.append(("tunnelDefinitions", tunnels))

        var auditPath = ProxyConfig()
        auditPath.logging.auditLogPath = "/" + String(repeating: "a", count: 1_023)
        cases.append(("auditLogPath", auditPath))

        for (name, config) in cases {
            let violation = try XCTUnwrap(config.resourceViolation(), name)
            let bytes = try CanonicalJSON.encoder().encode(config)
            let result = try gate(bytes, "parity-\(name)")
            XCTAssertEqual(reason(result), refusal(for: violation), name)
        }
    }

    func testAnEscapedSpellingIsChargedByItsDecodedBytes() throws {
        let accepted = Data(#"{"profileName":""#.utf8) + Data(String(repeating: #"\u00e9"#, count: 512).utf8) + suffix
        XCTAssertEqual(profile(try gate(accepted, "escaped-exact")), String(repeating: "é", count: 512), "1024 decoded bytes")
        let refused = Data(#"{"profileName":""#.utf8) + Data(String(repeating: #"\u00e9"#, count: 513).utf8) + suffix
        XCTAssertEqual(reason(try gate(refused, "escaped-over")), refusal(for: DomainResourceViolation(.profileName, 1_024)))
    }

    // MARK: - Physical budget

    func testAFileOfExactlyTheBudgetIsAcceptedAndOneByteOverIsRefusedUnchanged() throws {
        let cap = RuntimeConfigurationFileReader.maximumBytes
        let prefix = Data(#"{"profileName":"P","pad":""#.utf8)
        let padding = cap - prefix.count - suffix.count
        let exact = prefix + Data(repeating: 0x20, count: padding) + suffix
        XCTAssertEqual(exact.count, cap)
        XCTAssertEqual(profile(try gate(exact, "exact-budget")), "P")

        let env = RuntimeEnvironment(configDirectory: directory.appendingPathComponent("over-budget", isDirectory: true))
        try FileManager.default.createDirectory(at: env.configDirectory, withIntermediateDirectories: true)
        let over = prefix + Data(repeating: 0x20, count: padding + 1) + suffix
        try over.write(to: env.configFile)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadAllMigrating(in: env)) { error in
            XCTAssertTrue((error as? ConfigurationLoadError)?.reason.contains("size limit") == true)
        }
        XCTAssertEqual(try Data(contentsOf: env.configFile), over, "the rejected file keeps its original bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.platformConfigFile.path), "no sidecar is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.preferencesFile.path), "no sidecar is written")
    }

    func testALargeUnknownArrayUnderTheBudgetIsSkippedWithoutTypedExpansion() throws {
        let items = Array(repeating: "0", count: 500_000).joined(separator: ",")
        let data = Data(#"{"profileName":"P","junk":["#.utf8) + Data(items.utf8) + Data("]}".utf8)
        XCTAssertLessThan(data.count, RuntimeConfigurationFileReader.maximumBytes)
        XCTAssertEqual(profile(try gate(data, "large-unknown")), "P")

        let filtered = try data.withUnsafeBytes { raw in
            try RuntimeFileFilter.filter(
                UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count),
                root: RuntimeFileSchema.root(.runtimeOnly)
            )
        }
        XCTAssertEqual(String(decoding: filtered.bytes, as: UTF8.self), #"{"profileName":"P"}"#, "no element of the array is retained")
    }

    // MARK: - Adapter failures keep their facts

    func testAFifoRuntimeFileIsRefusedWithItsStepNamed() throws {
        let pipe = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadMigrating(from: pipe, saveMigrated: false)) { error in
            XCTAssertEqual((error as? ConfigurationLoadError)?.reason, "The configuration file could not be read: not a regular file.")
        }
    }

    func testAMissingFileIsDefaultsWhenAllowedAndNamedWhenNot() throws {
        let absent = directory.appendingPathComponent("absent.json")
        XCTAssertEqual(try ProxyConfigPersistence.loadMigrating(from: absent, saveMigrated: false).config.profileName, GenericDefaults.shared.makeConfig().profileName)
        XCTAssertThrowsError(try ProxyConfigPersistence.loadMigrating(from: absent, saveMigrated: false, allowMissing: false)) { error in
            XCTAssertEqual((error as? ConfigurationLoadError)?.reason, "The configuration file could not be read: the file does not exist.")
        }
    }

    func testEachReadFailureSummaryKeepsItsStepErrnoAndACloseFailureThatFollowedIt() {
        XCTAssertEqual(RuntimeConfigurationFileError.unreadable(.notRegularFile, closeErrno: nil).summary, "not a regular file")
        let both = RuntimeConfigurationFileError.unreadable(.tooLarge(limit: 4), closeErrno: EIO).summary
        XCTAssertTrue(both.contains("exceeds the runtime file size limit of 4 bytes"), both)
        XCTAssertTrue(both.contains("close also failed"), both)
        XCTAssertTrue(both.contains("errno \(EIO)"), both)
        XCTAssertTrue(RuntimeConfigurationFileError.unreadable(.readFailed(EIO), closeErrno: nil).summary.hasPrefix("read failed"))
        XCTAssertTrue(RuntimeConfigurationFileError.closeFailed(EIO).summary.hasPrefix("close failed"))
    }
}
