// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import NIOPosix

@main
enum PMDns {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            pm-dns - standalone DoH DNS forwarder from ProxyKernel

            USAGE: pm-dns [OPTIONS]

            OPTIONS:
              --port <port>      UDP port to listen on (default: from config or 5353)
              --host <host>      Host to bind to (default: 127.0.0.1)
              --config <path>    Path to Conduit config.json
              --state-dir <path> Directory for config.json and saved runtime state
              --verbose          Enable verbose logging
              --help, -h         Show this help

            EXAMPLES:
              pm-dns --port 5353
              pm-dns --port 5353 --verbose
              pm-dns --config ~/custom-config.json

            The forwarder tries corporate DNS first for internal domains,
            then falls back to Cloudflare DoH for external names.
            DoH fetches try direct, then upstream proxy, then local proxy.
            """)
            return
        }

        let environment = runtimeEnvironment(from: args)
        let config = ProxyConfigPersistence.load(in: environment)
        let port = parseIntArg("--port", from: args) ?? config.dnsForwarderPort
        let host = parseStringArg("--host", from: args) ?? config.localHost
        let verbose = args.contains("--verbose")

        Task { @MainActor in
            // See pm-proxy for the AppLogStore → ConsoleLogSink rationale.
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .notice)

            if verbose {
                logger.log(.info, "Loaded config from \(environment.configFile.path)", category: .general)
                logger.log(.info, "Internal DNS entries: \(config.dnsEntries.filter(\.enabled).map(\.domain).joined(separator: ", "))", category: .network)
            }

            let group = MultiThreadedEventLoopGroup.singleton
            let forwarder = LocalDNSForwarder(
                group: group,
                logger: logger,
                configProvider: { config }
            )

            signal(SIGINT, SIG_IGN)
            let shutdownSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            shutdownSource.setEventHandler {
                logger.log(.notice, "Received SIGINT, stopping...", category: .general)
                Task {
                    await forwarder.stop()
                    exit(0)
                }
            }
            shutdownSource.resume()

            signal(SIGTERM, SIG_IGN)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termSource.setEventHandler {
                logger.log(.notice, "Received SIGTERM, stopping...", category: .general)
                Task {
                    await forwarder.stop()
                    exit(0)
                }
            }
            termSource.resume()

            do {
                try await forwarder.start(host: host, port: port)
                logger.log(.notice, "pm-dns running on \(host):\(port). Press Ctrl-C to stop.", category: .general)
            } catch {
                logger.log(.error, "Failed to start on \(host):\(port): \(error.displayDescription)", category: .general)
                exit(1)
            }
        }

        dispatchMain()
    }

    private static func runtimeEnvironment(from args: [String]) -> RuntimeEnvironment {
        let configFile = parseStringArg("--config", from: args).map { URL(fileURLWithPath: $0) }
        let stateDirectory = parseStateDirectory(from: args)

        switch (stateDirectory, configFile) {
        case let (stateDirectory?, configFile?):
            return RuntimeEnvironment(
                configDirectory: stateDirectory,
                configFile: configFile
            )
        case let (stateDirectory?, nil):
            return .isolated(stateDirectory: stateDirectory)
        case let (nil, configFile?):
            return .explicit(configFile: configFile)
        case (nil, nil):
            return .userDefault()
        }
    }

    private static func parseStateDirectory(from args: [String]) -> URL? {
        if let value = parseStringArg("--state-dir", from: args) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let value = ProcessInfo.processInfo.environment["PM_CONFIG_DIR"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return nil
    }

    private static func parseIntArg(_ flag: String, from args: [String]) -> Int? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return Int(args[idx + 1])
    }

    private static func parseStringArg(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
