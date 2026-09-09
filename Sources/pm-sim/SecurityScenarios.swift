// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyAuth
import ProxyKernel

/// CLT-compatible security regressions. All credentials and endpoints are synthetic.
enum SecurityScenarios {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private final class CountingCredentials: CredentialProvider, Sendable {
        let reads = NIOLockedValueBox(0)
        func credentials(for upstream: UpstreamProxy) throws -> ProxyCredentials? {
            reads.withLockedValue { $0 += 1 }
            // Deliberately profile-wide, like CredentialManager: the factory
            // must deny untrusted endpoints before this store is reached.
            return ProxyCredentials(username: "synthetic", domain: "TEST", workstation: "SIM",
                                    ntHash: .repeating(0, count: 16))
        }
        func setCredentials(_ credentials: ProxyCredentials, for upstream: UpstreamProxy) throws {}
    }

    @MainActor
    static func boundaries(verbose: Bool) async throws -> ScenarioResult {
        let start = Date()
        let trusted = UpstreamProxy(name: "trusted", host: "proxy.example.test", port: 8080, priority: 0)
        var disabled = UpstreamProxy(name: "disabled", host: "disabled.example.test", port: 8080, priority: 1)
        disabled.enabled = false
        var config = GenericDefaults.shared.makeConfig()
        config.upstreams = [trusted, disabled]
        let configBox = NIOLockedValueBox(config)
        let credentials = CountingCredentials()
        let events = RuntimeEventLog(capacity: 32)
        let factory = credentialBasedAuthenticatorProvider(
            configProvider: { configBox.withLockedValue { $0 } }, credentialProvider: credentials,
            eventSink: { events.append($0) }
        )
        let denied = [
            UpstreamProxy(name: "PAC", host: "unknown.example.test", port: 8080, priority: 0),
            UpstreamProxy(name: "other port", host: trusted.host, port: 8081, priority: 0),
            disabled,
        ]
        for mode in [AuthenticationMode.systemNegotiated, .ntlmv2] {
            configBox.withLockedValue { $0.authMode = mode }
            for destination in denied {
                do {
                    _ = try factory(destination)
                    throw Failure(message: "Untrusted endpoint received an authenticator: \(destination.endpoint)")
                } catch is UpstreamAuthenticationDenied {}
            }
        }
        try require(credentials.reads.withLockedValue { $0 } == 0, "Denied endpoints accessed credentials")
        try require(events.events.count == 6, "Auth denials must emit structured events")
        var caseVariant = trusted
        caseVariant.host = trusted.host.uppercased()
        _ = try factory(caseVariant)
        try require(credentials.reads.withLockedValue { $0 } == 1, "Trusted NTLM endpoint did not read credentials")
        configBox.withLockedValue { $0.authMode = .systemNegotiated }
        _ = try factory(trusted) // Do not invoke GSS or access a real ticket cache.
        try require(credentials.reads.withLockedValue { $0 } == 1, "Kerberos construction eagerly read NTLM credentials")
        configBox.withLockedValue { $0.upstreams = [] }
        do {
            _ = try factory(trusted)
            throw Failure(message: "Removed upstream retained credential authority")
        } catch is UpstreamAuthenticationDenied {}

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = RuntimeEnvironment.isolated(stateDirectory: directory)
        _ = try ProxyConfigPersistence.load(in: environment) // Genuine first run remains supported.
        do {
            _ = try ProxyConfigPersistence.load(in: environment, allowMissing: false)
            throw Failure(message: "Explicit missing config silently defaulted")
        } catch is ConfigurationLoadError {}
        for bytes in [Data("{".utf8), Data("{\"localPort\":\"broken\"}".utf8), Data("{\"schemaVersion\":999999}".utf8)] {
            try bytes.write(to: environment.configFile)
            do {
                _ = try ProxyConfigPersistence.loadAllMigrating(in: environment)
                throw Failure(message: "Invalid config silently defaulted")
            } catch is ConfigurationLoadError {}
            try require(try Data(contentsOf: environment.configFile) == bytes, "Rejected config was overwritten")
            try require(!FileManager.default.fileExists(atPath: environment.platformConfigFile.path), "Rejected config migrated sidecars")
        }
        try FileManager.default.removeItem(at: environment.configFile)
        try FileManager.default.createDirectory(at: environment.configFile, withIntermediateDirectories: false)
        do {
            _ = try ProxyConfigPersistence.load(in: environment)
            throw Failure(message: "Unreadable config silently defaulted")
        } catch is ConfigurationLoadError {}
        try FileManager.default.removeItem(at: environment.configFile)
        try ProxyConfigPersistence.save(config, in: environment)
        let loaded = try ProxyConfigPersistence.load(in: environment, allowMissing: false)
        try require(loaded.upstreams == config.upstreams, "Valid config lost its upstreams")
        try validateSidecarStaging(in: environment)

        config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        let externalHosts = ["0.0.0.0", "::", "[::]", "192.0.2.1", "10.0.0.1", "fe80::1", "host.example.test", "127.0.0.1.example.test"]
        for host in externalHosts {
            config.localHost = host
            try require(config.validate().contains(where: \.blocksProxyStart), "Non-gateway bind accepted \(host)")
            let snapshot = config
            let forwarder = LocalDNSForwarder(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), configProvider: { snapshot })
            do {
                try await forwarder.start(host: host, port: 0)
                await forwarder.stop()
                throw Failure(message: "DNS accepted a non-loopback bind")
            } catch is ConfigValidationError {}
        }
        for host in ["127.0.0.1", "127.2.3.4", "::1", "[::1]", "0:0:0:0:0:0:0:1", "localhost", "LOCALHOST"] {
            config.localHost = host
            try require(!config.validate().contains(where: \.blocksProxyStart), "Loopback bind rejected \(host)")
        }
        config.localHost = "localhost"
        try require(config.effectiveClientHost == "127.0.0.1", "Client settings left localhost unpinned")
        try require(config.localProxyURL == "http://127.0.0.1:0", "Environment proxy URL left localhost unpinned")
        try require(PACScriptEmitter.script(for: config).contains("PROXY 127.0.0.1:0"), "PAC advertised an unpinned proxy")
        config.localHost = "[::1]"
        try require(config.localProxyURL == "http://[::1]:0", "IPv6 proxy URL lost its authority brackets")
        config.localHost = "192.0.2.1"
        config.gatewayMode = true
        try require(!config.validate().contains(where: \.blocksProxyStart), "Gateway opt-in rejected")
        config.dnsForwarderEnabled = true
        try require(config.validate().contains(where: \.blocksProxyStart), "Gateway opt-in exposed unfiltered DNS")
        let dnsConfig = GenericDefaults.shared.makeConfig()
        let forwarder = LocalDNSForwarder(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), configProvider: { dnsConfig })
        try await forwarder.start(host: "localhost", port: 0)
        let listeningHost = forwarder.listeningHost
        let dnsPort = forwarder.listeningPort
        let tcpPort = forwarder.tcpListeningPort
        await forwarder.stop()
        try require(listeningHost == "127.0.0.1" && dnsPort != nil && dnsPort == tcpPort, "DNS did not pin localhost for both transports")

        // Exercise both production auth callsites: they must preserve the port
        // of the actual connection, not collapse its identity to a hostname.
        let destinations = NIOLockedValueBox<(count: Int, last: UpstreamProxy?)>((0, nil))
        let harness = SimHarness(verbose: verbose)
        try await harness.start(originBehavior: .silent,
                                upstreamPlainHTTPResponse: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
                                authenticatorProvider: { destination in
            destinations.withLockedValue { $0.count += 1; $0.last = destination }
            return MockAuthenticator()
        })
        do {
            for request in [
                "CONNECT origin.example.test:443 HTTP/1.1\r\nHost: origin.example.test:443\r\n\r\n",
                "GET http://origin.example.test/ HTTP/1.1\r\nHost: origin.example.test\r\nConnection: close\r\n\r\n",
            ] {
                let before = destinations.withLockedValue { $0.count }
                let response = try await RawHTTPAuditClient.request(group: harness.group, host: harness.localProxyHost, port: harness.localProxyPort, request: request)
                let captured = destinations.withLockedValue { $0 }
                try require(response.hasPrefix("HTTP/1.1 200"), "Synthetic authenticated request failed")
                try require(captured.count > before && captured.last?.port == harness.upstream?.port && captured.last?.host == "127.0.0.1", "Auth callsite lost upstream host/port")
            }
            await harness.stop()
        } catch {
            await harness.stop()
            throw error
        }
        let deniedHarness = SimHarness(verbose: verbose)
        try await deniedHarness.start(originBehavior: .silent, authenticatorProvider: factory)
        do {
            for request in [
                "CONNECT origin.example.test:443 HTTP/1.1\r\nHost: origin.example.test:443\r\n\r\n",
                "GET http://origin.example.test/ HTTP/1.1\r\nHost: origin.example.test\r\nConnection: close\r\n\r\n",
            ] {
                let count = events.totalCount
                let response = try await RawHTTPAuditClient.request(group: deniedHarness.group, host: deniedHarness.localProxyHost,
                                                                   port: deniedHarness.localProxyPort, request: request)
                try require(!response.hasPrefix("HTTP/1.1 200"), "Untrusted upstream authenticated successfully")
                try require(events.totalCount > count, "Untrusted network challenge bypassed the auth boundary")
                try require(credentials.reads.withLockedValue { $0 } == 1, "Network challenge accessed profile credentials")
            }
            await deniedHarness.stop()
        } catch {
            await deniedHarness.stop()
            throw error
        }
        return ScenarioResult(name: "security-boundaries", clientCount: 2, clientsOpened: 2, clientsWithFirstByte: 2,
                              clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(start),
                              aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
                              notes: ["PASS: credential destination isolation, lazy NTLM, rejected config persistence, loopback-only listeners, HTTP and CONNECT endpoint propagation"])
    }

    private static func validateSidecarStaging(in environment: RuntimeEnvironment) throws {
        let legacy = Data("{\"localPort\":0,\"manageSystemProxy\":true,\"showMenuBarIcon\":false}".utf8)
        try legacy.write(to: environment.configFile)
        for (broken, other) in [(environment.platformConfigFile, environment.preferencesFile),
                                (environment.preferencesFile, environment.platformConfigFile)] {
            let corrupt = Data("{".utf8)
            try corrupt.write(to: broken)
            do {
                _ = try ProxyConfigPersistence.loadAllMigrating(in: environment)
                throw Failure(message: "Malformed sidecar silently defaulted")
            } catch is ConfigurationLoadError {}
            try require(try Data(contentsOf: broken) == corrupt, "Malformed sidecar was overwritten")
            try require(try Data(contentsOf: environment.configFile) == legacy, "Runtime migrated before all sidecars validated")
            try require(!FileManager.default.fileExists(atPath: other.path), "Another sidecar migrated before rejection")
            try FileManager.default.removeItem(at: broken)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
            do {
                _ = try ProxyConfigPersistence.loadAllMigrating(in: environment)
                throw Failure(message: "Unreadable sidecar silently defaulted")
            } catch is ConfigurationLoadError {}
            try require(!FileManager.default.fileExists(atPath: other.path), "Unreadable sidecar allowed another migration")
            try FileManager.default.removeItem(at: broken)
        }
        let invalidLegacy = Data("{\"localPort\":-1,\"manageSystemProxy\":true,\"showMenuBarIcon\":false}".utf8)
        try invalidLegacy.write(to: environment.configFile)
        do {
            _ = try ProxyConfigPersistence.loadAllMigrating(in: environment) { candidate in
                if let problem = candidate.validate().first(where: \.blocksProxyStart) { throw problem }
            }
            throw Failure(message: "Invalid legacy config was accepted")
        } catch is ConfigValidationError {}
        try require(try Data(contentsOf: environment.configFile) == invalidLegacy, "Rejected semantic validation rewrote runtime config")
        try require(!FileManager.default.fileExists(atPath: environment.platformConfigFile.path)
                    && !FileManager.default.fileExists(atPath: environment.preferencesFile.path),
                    "Rejected semantic validation migrated sidecars")
        try legacy.write(to: environment.configFile)
        let migrated = try ProxyConfigPersistence.loadAllMigrating(in: environment)
        try require(migrated.platformConfig.manageSystemProxy && !migrated.appPreferences.showMenuBarIcon,
                    "Missing sidecars did not preserve legacy settings")
        try require(FileManager.default.fileExists(atPath: environment.platformConfigFile.path)
                    && FileManager.default.fileExists(atPath: environment.preferencesFile.path),
                    "Valid legacy sidecar migration was not saved")
        try FileManager.default.removeItem(at: environment.configFile)
        do {
            _ = try ProxyConfigPersistence.loadAllMigrating(in: environment)
            throw Failure(message: "Deleted established configuration became first-run defaults")
        } catch is ConfigurationLoadError {}
    }
}
