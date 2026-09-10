// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import NIOPosix

@main
enum PMDns {
    // The startup task finishes once the listeners bind. These process-owned
    // slots keep both sources alive until terminal shutdown (exactly two).
    @MainActor private static var signalSources: (interrupt: DispatchSourceSignal, terminate: DispatchSourceSignal)?
    @MainActor private static var shutdownTask: Task<Void, Never>?

    static func main() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            pm-dns - standalone DoH DNS forwarder from ProxyKernel

            USAGE: pm-dns [OPTIONS]

            OPTIONS:
              --port <port>      UDP port to listen on (default: from config or 5353)
              --host <host>      Host to bind to (default: 127.0.0.1)
              --config <path>    Path to Conduit config.json (required unless --minimal)
              --state-dir <path> Directory for config.json and saved runtime state
              --minimal         Use generic defaults without reading saved configuration
              --verbose          Enable verbose logging
              --help, -h         Show this help

            EXAMPLES:
              pm-dns --minimal --port 5353
              pm-dns --minimal --port 5353 --verbose
              pm-dns --config ~/custom-config.json

            The forwarder tries corporate DNS first for internal domains,
            then falls back to Cloudflare DoH for external names.
            DoH fetches try direct, then upstream proxy, then local proxy.
            """)
            return
        }

        let environment = runtimeEnvironment(from: args)
        let config: ProxyConfig
        do {
            if args.contains("--minimal") {
                guard !args.contains("--config") else {
                    throw ConfigurationLoadError(source: "command line", reason: "--minimal and --config cannot be combined")
                }
                config = GenericDefaults.shared.makeConfig()
            } else {
                // This standalone host writes no state markers, so it cannot
                // distinguish a first run from a deleted policy. Defaults must
                // be an explicit choice on every invocation.
                config = try ProxyConfigPersistence.load(in: environment, allowMissing: false)
            }
        } catch {
            let failure = error as? ConfigurationLoadError ?? ConfigurationLoadError(source: environment.configFile.path, reason: error.localizedDescription)
            let failureLogger = ConsoleLogSink(minLevel: .notice)
            failure.report(to: failureLogger)
            failureLogger.flush()
            exit(1)
        }
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

            do {
                try await forwarder.start(host: host, port: port)
                // Install only after startup completes so stop cannot race a
                // suspended bind and leave a newly-created listener behind.
                installSignalSources(forwarder: forwarder, logger: logger)
                let boundPort = forwarder.listeningPort ?? port
                logger.log(.notice, "pm-dns running on \(host):\(boundPort). Press Ctrl-C to stop.", category: .general)
            } catch {
                logger.log(.error, "Failed to start on \(host):\(port): \(error.displayDescription)", category: .general)
                logger.flush()
                exit(1)
            }
        }

        dispatchMain()
    }

    @MainActor
    private static func installSignalSources(forwarder: LocalDNSForwarder, logger: ConsoleLogSink) {
        func makeSource(_ number: Int32, name: String) -> DispatchSourceSignal {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // Both sources run on main; repeated or mixed signals share
                // one shutdown task while it awaits channel closure.
                guard shutdownTask == nil else { return }
                logger.log(.notice, "Received \(name), stopping...", category: .general)
                shutdownTask = Task { @MainActor in
                    await forwarder.stop()
                    signalSources?.interrupt.cancel()
                    signalSources?.terminate.cancel()
                    signalSources = nil
                    logger.flush()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        signalSources = (makeSource(SIGINT, name: "SIGINT"), makeSource(SIGTERM, name: "SIGTERM"))
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
