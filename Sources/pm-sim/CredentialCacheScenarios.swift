// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyAuth
import ProxyKernel
import Security

/// Issue #98. Kerberos cannot get a service ticket, so every handshake
/// falls back to NTLM, and a burst of them arrives while the saved password
/// is still being read (as it is behind a Keychain access prompt). The
/// store must be read once for the whole burst, and a store that fails must
/// be reported once, as `auth.credentials_unavailable`, without taking the
/// proxy down.
enum CredentialCacheScenarios {

    /// Answers every initial leg the way macOS does for a TGT with no service
    /// ticket: a failure that permits the NTLM fallback at once.
    private final class NoServiceTicket: GSSTokenProvider, @unchecked Sendable {
        func generateToken(host: String, inputToken: Data?) throws -> Data? {
            throw KerberosAuthError.serviceTicketUnavailable(host: host, major: 0, minor: 0)
        }

        func resetContext() {}
    }

    /// A minimal NTLM type-2 message: no target name, no target info.
    private static var type2Challenge: String {
        var message = Data("NTLMSSP\0".utf8)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { message.append(contentsOf: $0) } }
        append(2)
        message.append(NTLMAuth.securityBuffer(length: 0, offset: 48))
        append(NTLMAuth.negotiateFlags)
        message.append(contentsOf: [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        message.append(Data(count: 8))
        message.append(NTLMAuth.securityBuffer(length: 0, offset: 48))
        return message.base64EncodedString()
    }

    @MainActor
    static func burstReadsOnce(verbose: Bool) async throws -> ScenarioResult {
        let name = "ntlm-credential-cache"
        let start = Date()
        let burst = 16

        let configBox = NIOLockedValueBox(ProxyConfig())
        let store = InMemorySecretStore()
        let manager = CredentialManager(
            identityProvider: {
                let c = configBox.withLockedValue { $0 }
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            },
            store: store
        )
        let events = RuntimeEventLog(capacity: 256)
        let factory = credentialBasedAuthenticatorProvider(
            configProvider: { configBox.withLockedValue { $0 } },
            credentialProvider: manager,
            eventSink: { events.append($0) },
            kerberosTokenProvider: { NoServiceTicket() }
        )

        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(originBehavior: .echo, upstreamChallenge: "NTLM \(type2Challenge)", authenticatorProvider: factory)
        guard let upstreamPort = harness.upstream?.port else {
            throw ScenarioExecutionError(message: "upstream did not start")
        }
        var config = ProxyConfig()
        config.username = "synthetic"
        config.domain = "TEST"
        config.authMode = .systemNegotiated
        config.upstreams = [UpstreamProxy(name: "SimUpstream", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        configBox.withLockedValue { $0 = config }
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)

        func runBurst(_ label: String) async throws -> Int {
            let clients = (0..<burst).map { i in
                FakeClient(
                    id: i, group: harness.group,
                    localProxyHost: harness.localProxyHost, localProxyPort: harness.localProxyPort,
                    target: "\(label)-\(i).example:443",
                    behavior: .sendOnceThenListen(requestBytes: 16)
                )
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for client in clients { group.addTask { try await client.run() } }
                try await group.waitForAll()
            }
            await withTaskGroup(of: Void.self) { group in
                for client in clients { group.addTask { await client.waitForClose(timeout: 1.0) } }
            }
            let opened = clients.filter { $0.metrics.connectEstablishedAt != nil }.count
            await withTaskGroup(of: Void.self) { group in
                for client in clients { group.addTask { await client.close() } }
            }
            return opened
        }

        // A burst behind a slow read, as behind a Keychain prompt.
        store.loadDelay = 0.3
        let openedHealthy = try await runBurst("healthy")
        let healthyReads = store.loads

        // The store starts failing; a save invalidates what was cached.
        store.loadDelay = 0
        store.loadFailure = KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed)
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        let openedFailing = try await runBurst("failing")
        let failingReads = store.loads - healthyReads
        let unavailable = events.events.filter { $0.event == "auth.credentials_unavailable" }

        // And recovers once the user acts.
        store.loadFailure = nil
        try manager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: config)
        let openedRecovered = try await runBurst("recovered")

        return ScenarioResult(
            name: name, clientCount: burst * 3, clientsOpened: openedHealthy + openedFailing + openedRecovered,
            clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every handshake of the burst fell back to NTLM and opened", openedHealthy == burst),
                .init("the burst read the store once", healthyReads == 1),
                .init("a failing store is read once for the burst", failingReads == 1),
                .init("a failing store is reported once, with its reason",
                      unavailable.count == 1 && unavailable.first?.detail?.contains("reason=interaction_not_allowed") == true),
                .init("a failing store fails the handshakes, not the proxy", openedFailing == 0),
                .init("a save after the failure is read and used", openedRecovered == burst && store.loads == healthyReads + failingReads + 1),
            ],
            notes: [
                "burst=\(burst)", "healthyReads=\(healthyReads)", "failingReads=\(failingReads)",
                "opened=\(openedHealthy)/\(openedFailing)/\(openedRecovered)", "unavailableEvents=\(unavailable.count)",
            ]
        )
    }
}
