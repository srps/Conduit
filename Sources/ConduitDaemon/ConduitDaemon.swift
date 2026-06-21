// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ConduitShared
import ProxyPAC

/// Production user-session daemon entry point.
///
/// This target is intentionally separate from:
/// - `pm-proxy`, which remains side-effect-free for CI and isolated testing.
/// - `ConduitHelper`, which remains privileged-only and must not own
///   user Keychain / Kerberos / CFNetwork PAC state.
@main
enum ConduitDaemon {
    static let startedAt = Date()
    @MainActor
    private static var retainedSources: [DispatchSourceSignal] = []

    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        let logger = ConsoleLogSink(minLevel: args.contains("--verbose") ? .debug : .notice)
        let environment = runtimeEnvironment(from: args)
        let loaded = ProxyConfigPersistence.loadAllMigrating(in: environment)
        for warning in loaded.warnings {
            logger.log(.warning, warning, category: .system)
        }
        if loaded.migrated {
            logger.log(.notice, "Configuration files migrated to the current schema.", category: .system)
        }

        let host = DaemonRuntimeHost(
            environment: environment,
            logger: logger,
            loadedConfiguration: loaded
        )

        if args.contains("--start-runtime") {
            do {
                try await host.startRuntime()
            } catch {
                logger.log(.error, "Daemon runtime start failed: \(error.localizedDescription)", category: .general)
                host.flushEvents()
                exit(1)
            }
        }

        for (sig, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                logger.log(.notice, "Received \(name), stopping daemon runtime...", category: .general)
                Task { @MainActor in
                    await host.stopRuntime(exitAfterStop: true)
                }
            }
            source.resume()
            retainedSources.append(source)
        }

        host.markReady(mode: args.contains("--start-runtime") ? "runtime-started" : "runtime-host")

        if args.contains("--print-status") {
            printStatus(host.status())
        }

        host.flushEvents()

        if args.contains("--exit-after-ready") {
            if args.contains("--start-runtime") {
                await host.stopRuntime()
            }
            return
        }

        logger.log(.notice, "ConduitDaemon ready (runtime host mode).", category: .general)
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
            // Intentionally never resumed. The daemon has no control socket yet; the
            // LaunchAgent-shaped skeleton remains resident until the process
            // receives SIGTERM / launchd stops it.
        }
    }

    private static func printStatus(_ status: ControlDaemonStatus) {
        do {
            let data = try DaemonRuntimeHost.prettyEncoder.encode(status)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("Failed to encode daemon status: \(error)\n".utf8))
        }
    }

    private static func runtimeEnvironment(from args: [String]) -> RuntimeEnvironment {
        let configFile = parseStringArg("--config", from: args).map { URL(fileURLWithPath: $0) }
        let stateDirectory = parseStateDirectory(from: args)

        switch (stateDirectory, configFile) {
        case let (stateDirectory?, configFile?):
            return RuntimeEnvironment(configDirectory: stateDirectory, configFile: configFile)
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

    private static func parseStringArg(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func printUsage() {
        print("""
        ConduitDaemon - user-session production daemon skeleton

        USAGE:
          ConduitDaemon [--state-dir PATH] [--config PATH] [--print-status] [--exit-after-ready] [--verbose]

        NOTES:
          Runtime-host mode: loads config, owns ProxyOrchestrator and
          platform coordinators, writes daemon-ready.json + snapshot.json,
          emits daemon.ready, and stays resident unless --exit-after-ready is
          supplied. It starts no listeners by default; pass --start-runtime for
          an explicit smoke/dev run that starts the owned runtime.
        """)
    }
}
