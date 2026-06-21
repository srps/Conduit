// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import ProxyKernel

/// Holds the full end-to-end pipeline:
///   FakeClient → LocalProxyServer (code under test) → FakeUpstreamProxy → FakeOrigin.
/// The simulator instantiates one of these per scenario and tears it down after.
@MainActor
final class SimHarness {
    let group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    // pm-sim is a headless harness that doesn't need a UI ring buffer.
    // ConsoleLogSink writes synchronously to stderr (no MainActor hop) which
    // is what scenarios assert on via captured stderr or via embedded
    // RecordingLogSink in tests that care about log content.
    let logger: any LogSink

    private(set) var origin: FakeOrigin?
    private(set) var upstream: FakeUpstreamProxy?
    private(set) var server: LocalProxyServer?
    private(set) var detector: DirectConnectDetector?

    private var configBox: ProxyConfig

    init(verbose: Bool) {
        self.logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        self.configBox = ProxyConfig()
    }

    func start(
        originBehavior: OriginBehavior,
        maxConnections: Int = 128,
        inboundConnectionLimit: Int = 2_048,
        inboundConnectionWarnThreshold: Int = 2_048,
        pendingAuthHandshakeGlobalLimit: Int = 512,
        pendingAuthHandshakesPerSource: Int = 128,
        socksEnabled: Bool = false,
        socksPort: Int = 0,
        directMode: Bool = false,
        directModeCause: DirectModeCause = .none,
        upstreamPlainHTTPResponse: String? = nil,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator = { _ in MockAuthenticator() }
    ) async throws {
        let origin = FakeOrigin(group: group, behavior: originBehavior)
        try await origin.start()
        self.origin = origin

        let upstream = FakeUpstreamProxy(
            group: group,
            originHost: "127.0.0.1",
            originPort: origin.port,
            requireAuth: true,
            plainHTTPResponse: upstreamPlainHTTPResponse
        )
        try await upstream.start()
        self.upstream = upstream

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.socksEnabled = socksEnabled
        config.proxy.socksPort = socksPort
        config.proxy.maxConnections = maxConnections
        config.proxy.inboundConnectionMaxLimit = inboundConnectionLimit
        config.proxy.inboundConnectionWarnThreshold = inboundConnectionWarnThreshold
        config.proxy.stalledConnectionTimeout = 300
        config.proxy.maxBufferedBodyBytes = 1_048_576
        config.auth.mode = .systemNegotiated
        config.auth.pendingHandshakeGlobalLimit = pendingAuthHandshakeGlobalLimit
        config.auth.pendingHandshakesPerSource = pendingAuthHandshakesPerSource
        config.routing.pacRoutingEnabled = false
        config.routing.localPACEnabled = false
        config.routing.noProxyHosts = []
        config.routing.forceProxyHosts = []
        config.upstreams = [
            UpstreamProxy(
                name: "SimUpstream",
                host: "127.0.0.1",
                port: upstream.port,
                priority: 0
            )
        ]
        self.configBox = config

        let detector = DirectConnectDetector(
            group: group,
            logger: logger,
            ttlSeconds: 300,
            baseTimeoutMS: 500
        )
        self.detector = detector

        let capturedConfig = self.configBox
        let server = LocalProxyServer(
            logger: logger,
            configProvider: { capturedConfig },
            directModeProvider: { (directMode, directModeCause) },
            authenticatorProvider: authenticatorProvider,
            directConnectDetector: detector,
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onConnectionActivity: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        self.server = server
    }

    var localProxyHost: String { server?.listeningHost ?? "127.0.0.1" }
    var localProxyPort: Int { server?.listeningPort ?? 0 }

    func stop() async {
        await server?.stop()
        await upstream?.stop()
        await origin?.stop()
    }
}
