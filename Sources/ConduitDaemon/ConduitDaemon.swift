// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ConduitRuntime
import ConduitShared
import ProxyPAC

/// Production user-session daemon entry point.
///
/// This target is intentionally separate from:
/// - `pm-proxy`, which remains side-effect-free for CI and isolated testing.
/// - `ConduitHelper`, which remains privileged-only and must not own
///   user Keychain / Kerberos / CFNetwork PAC state.
///
/// It owns the process concerns only: arguments, config loading, signals,
/// `--print-status` and the resident wait. The runtime policy is `RuntimeHost`
/// in `ConduitRuntime`. This file is where the process exit and the start time
/// are injected into it.
@main
enum ConduitDaemon {
    @MainActor
    private static var retainedSources: [DispatchSourceSignal] = []

    @MainActor
    static func main() async {
        let startedAt = Date()
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        if let status = KerberosTicketRecoveryWorker.run(arguments: args) {
            exit(status)
        }

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        let logger = ConsoleLogSink(minLevel: args.contains("--verbose") ? .debug : .notice)
        let environment = runtimeEnvironment(from: args)
        // Read before the load, which writes a migrated file back. See
        // `RuntimeHost.init`.
        let configFilePredatesLaunch = FileManager.default.fileExists(atPath: environment.configFile.path)
        let loaded: RuntimeConfigurationLoadResult
        do {
            loaded = try ProxyConfigPersistence.loadAllMigrating(in: environment, allowMissing: !args.contains("--config"))
        } catch {
            let failure = error as? ConfigurationLoadError ?? ConfigurationLoadError(source: environment.configFile.path, reason: error.localizedDescription)
            failure.report(to: logger)
            // The journal restores need no config; see
            // `RuntimeHost.recoverWithoutConfiguration`. The exit status
            // is still the load failure's.
            await RuntimeHost.recoverWithoutConfiguration(environment: environment, logger: logger, commandRunner: CommandRunner.host)
            logger.flush()
            exit(1)
        }
        for warning in loaded.warnings {
            logger.log(.warning, warning, category: .system)
        }
        if loaded.migrated {
            logger.log(.notice, "Configuration files migrated to the current schema.", category: .system)
        }

        let host = RuntimeHost(
            environment: environment,
            logger: logger,
            loadedConfiguration: loaded,
            configFilePredatesLaunch: configFilePredatesLaunch,
            startedAt: startedAt,
            terminalExit: { exit(0) },
            commandRunner: CommandRunner.host,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        if args.contains("--start-runtime") {
            do {
                try await host.startRuntime()
            } catch {
                logger.log(.error, "Daemon runtime start failed: \(error.localizedDescription)", category: .general)
                await host.flushEvents()
                logger.flush()
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

        // Joins launch recovery before it publishes anything; see `markReady`.
        await host.markReady(mode: args.contains("--start-runtime") ? "runtime-started" : "runtime-host")

        if args.contains("--print-status") {
            printStatus(host.status())
        }

        await host.flushEvents()

        if args.contains("--exit-after-ready") {
            if args.contains("--start-runtime") {
                await host.stopRuntime()
                // The non-terminal stop only submits the stopped state. The readiness flush above does not cover it,
                // so the process boundary confirms it here, before the process returns.
                await host.flushEvents()
            }
            logger.flush()
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
            let data = try RuntimeHost.prettyEncoder.encode(status)
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
