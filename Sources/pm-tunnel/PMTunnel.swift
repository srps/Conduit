// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyAuth
import ProxyKernel
import NIOPosix

@main
enum PMTunnel {
    @MainActor
    private static var retainedSources: [AnyObject] = []

    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            pm-tunnel - standalone TCP tunnel forwarder from ProxyKernel

            USAGE: pm-tunnel [OPTIONS]

            OPTIONS:
              --config <path>       Path to Conduit config.json
              --state-dir <path>    Directory for config.json and saved runtime state
              --verbose             Enable verbose logging
              --help, -h            Show this help

            EXAMPLES:
              pm-tunnel --config ~/proxy-config.json
              pm-tunnel --state-dir /tmp/pm-test --verbose

            Starts all enabled tunnel definitions from the config. Each tunnel
            binds a local port and forwards TCP connections either directly or
            through an upstream corporate proxy via HTTP CONNECT with auth.

            Does not start the HTTP proxy, SOCKS5, or DNS forwarder — only tunnels.
            Does not apply system proxy, DNS, or environment changes.
            """)
            return
        }

        Task { @MainActor in
            let environment = runtimeEnvironment(from: args)
            let config = ProxyConfigPersistence.load(in: environment)

            // See pm-proxy for the AppLogStore → ConsoleLogSink rationale.
            let verbose = args.contains("--verbose")
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .notice)

            // Mirrors pm-proxy — `pm-tunnel` uses the kernel-side
            // `InMemoryCredentialProvider` so the binary doesn't link
            // `PlatformMac`. `.ntlmv2` upstreams will raise
            // `CredentialManagerError.missingCredentials`; Kerberos upstreams
            // are unaffected. A future `--credentials-file` CLI flag can
            // populate the provider.
            let credentialProvider: any CredentialProvider = InMemoryCredentialProvider()
            let group = MultiThreadedEventLoopGroup.singleton

            // pm-tunnel routes through the same
            // `credentialBasedAuthenticatorProvider` factory that pm-proxy
            // and AppState use (see `Sources/ProxyAuth/AuthenticatorFactory.swift`).
            // pm-tunnel has no hot-reload path, so the configProvider
            // returns a fixed snapshot — the factory's live-read contract
            // is trivially satisfied.
            let authProvider = credentialBasedAuthenticatorProvider(
                configProvider: { config },
                credentialProvider: credentialProvider
            )

            let pool = ConnectionPool(
                group: group,
                logger: logger,
                configProvider: { config },
                authenticatorProvider: authProvider
            )

            let coordinator = CONNECTCoordinator(
                pool: pool,
                authenticatorProvider: authProvider,
                logger: logger
            )

            let forwarder = TunnelForwarder(
                group: group,
                connectCoordinator: coordinator,
                connectionPool: pool,
                logger: logger
            )

            let activeTunnels = config.tunnelDefinitions.filter(\.enabled)
            guard !activeTunnels.isEmpty else {
                logger.log(.error, "No enabled tunnel definitions in config.", category: .tunnel)
                exit(1)
            }

            forwarder.updateLimits(
                maxGlobal: config.maxTunnelSessions,
                maxPerTunnel: config.maxSessionsPerTunnel
            )

            let result = await forwarder.start(
                tunnels: activeTunnels,
                listenHost: config.effectiveTunnelListenHost
            )

            guard result.started > 0 else {
                logger.log(.error, "All tunnel listeners failed to bind.", category: .tunnel)
                exit(1)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result.bindings) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }

            logger.log(.notice, "pm-tunnel running: \(result.started) tunnel(s) active. Press Ctrl-C to stop.", category: .tunnel)

            for (sig, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    logger.log(.notice, "Received \(name), stopping...", category: .general)
                    Task { @MainActor in
                        await forwarder.stop()
                        pool.closeAll()
                        exit(0)
                    }
                }
                source.resume()
                retainedSources.append(source)
            }
        }

        dispatchMain()
    }

    private static func runtimeEnvironment(from args: [String]) -> RuntimeEnvironment {
        let configFile = parseStringArg("--config", from: args).map { URL(fileURLWithPath: $0) }
        if let dir = parseStringArg("--state-dir", from: args) {
            let stateDir = URL(fileURLWithPath: dir, isDirectory: true)
            if let cf = configFile {
                return RuntimeEnvironment(configDirectory: stateDir, configFile: cf)
            }
            return .isolated(stateDirectory: stateDir)
        }
        if let cf = configFile {
            return .explicit(configFile: cf)
        }
        return .userDefault()
    }

    private static func parseStringArg(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
