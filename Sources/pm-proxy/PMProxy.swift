// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ConduitShared
import ProxyPAC

@main
enum PMProxy {
    @MainActor
    private static var retainedSources: [AnyObject] = []

    static func main() {
        signal(SIGPIPE, SIG_IGN)

        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            pm-proxy - headless Conduit runtime for isolated testing

            USAGE: pm-proxy [OPTIONS]

            OPTIONS:
              --config <path>       Path to Conduit config.json
              --config-json <json>  Inline JSON config (overrides file-based config)
              --state-dir <path>    Directory for config.json and saved runtime state
              --port <port>         HTTP proxy port override (use 0 for ephemeral)
              --socks-port <port>   SOCKS5 port override and enable SOCKS5
              --dns-port <port>     DNS forwarder port override and enable DNS
              --host <host>         Host to bind proxy and DNS listeners to
              --status-interval <s> Emit changed status at most every N seconds (min 0.1)
              --assert-ready-under-ms <ms>
                                    Exit non-zero if startup-to-ready exceeds this budget
              --exit-after-ready    Stop immediately after writing the ready event/files
              --minimal             Start with vendor-neutral config (no upstreams, direct-only)
              --verbose             Enable verbose stderr logging
              --help, -h            Show this help

            ENVIRONMENT:
              PM_CONFIG_DIR         Default state directory when --state-dir is omitted

            EXAMPLES:
              pm-proxy --port 0
              pm-proxy --state-dir /tmp/pm-test --port 0 --dns-port 0
              pm-proxy --minimal --port 0 --status-interval 2
              pm-proxy --minimal --port 0 --exit-after-ready --assert-ready-under-ms 200
              pm-proxy --config-json '{"localPort":0}'

            The CLI starts the HTTP proxy and optionally starts SOCKS5, DNS, and protocol tunnels
            from the supplied config. It never applies system proxy settings, shell environment
            changes, DNS resolver changes, login items, or privileged helper actions.
            """)
            return
        }

        let processStartedAt = Date()

        Task { @MainActor in
            let environment = runtimeEnvironment(from: args)
            var config: ProxyConfig
            do {
                config = try loadConfig(from: args, environment: environment)
            } catch {
                let failure = error as? ConfigurationLoadError ?? ConfigurationLoadError(source: environment.configFile.path, reason: error.localizedDescription)
                let failureLogger = ConsoleLogSink(minLevel: .notice)
                failure.report(to: failureLogger)
                failureLogger.flush()
                exit(1)
            }
            applyCLIOverrides(to: &config, from: args)

            // Headless daemon uses bounded asynchronous stderr output. The Combine-backed
            // `AppLogStore` it used to construct lives in the SwiftUI app
            // target and is not linkable from `pm-proxy`.
            let verbose = args.contains("--verbose")
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .notice)

            // pm-proxy uses the kernel-side `InMemoryCredentialProvider`
            // instead of the Keychain-backed `CredentialManager`, which
            // lives in `PlatformMac` and is not linkable from a headless
            // daemon. Auth calls against `.ntlmv2` upstreams will raise
            // `CredentialManagerError.missingCredentials`; `.systemNegotiated`
            // upstreams keep working via Kerberos (no credential lookup). A
            // future `--credentials-file` flag can populate the in-memory
            // store.
            let credentialProvider = InMemoryCredentialProvider()
            // pm-proxy constructs its own PAC evaluator for the same
            // reason as `AppState` — the kernel no longer builds the
            // concrete PAC evaluator. When a config omits
            // `pacURL`, `PACRoutingEngine` short-circuits and never
            // evaluates anything; constructing the evaluator here has
            // negligible cost.
            //
            // CFNetwork is the only PAC evaluator. Headless
            // daemons get the same throwing default for plaintext PAC URLs as
            // before — no insecureFetcher injected (would require shelling out
            // to curl).
            let pacEvaluator: any PacEvaluator = CFPACEvaluator()
            logger.log(.notice, "PAC: using CFNetwork evaluator.", category: .pac)
            // Construct orchestrator first; capture its
            // `configSnapshotProvider` for the auth factory. Single source of
            // truth for the live config — no second NIOLockedValueBox in
            // pm-proxy.
            let auditSink = makeAuditSink(for: config, environment: environment, logger: logger)
            let orchestrator = ProxyOrchestrator(
                config: config,
                logger: logger,
                authenticatorProvider: nil,  // Wired below via setAuthenticatorProvider.
                pacEvaluator: pacEvaluator,
                auditSink: auditSink
            )
            let eventFileWriter = RuntimeEventFileWriter(
                fileURL: environment.eventsFile,
                logger: logger
            )
            writerStatistics = {
                ["events": eventFileWriter.statistics, "audit": auditSink.statistics, "console": logger.statistics]
            }
            orchestrator.eventLog.setSink { event in
                eventFileWriter.record(event)
            }
            let authenticatorProvider = credentialBasedAuthenticatorProvider(
                configProvider: orchestrator.configSnapshotProvider,
                credentialProvider: credentialProvider,
                outcomeHandler: { [weak orchestrator] outcome, host, reason in
                    orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason)
                },
                eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }
            )
            orchestrator.setAuthenticatorProvider(authenticatorProvider)
            let statusInterval = parseDoubleArg("--status-interval", from: args)
            let readyBudgetMS = parseIntArg("--assert-ready-under-ms", from: args)
            let exitAfterReady = args.contains("--exit-after-ready")
            var configGeneration = 0
            let daemonMetadata = ControlDaemonMetadata(
                processID: Int(ProcessInfo.processInfo.processIdentifier),
                executableName: URL(fileURLWithPath: CommandLine.arguments.first ?? "pm-proxy").lastPathComponent,
                startedAt: processStartedAt
            )
            let controlServer = ControlSocketServer(
                socketPath: ControlSocket.path(in: environment.configDirectory),
                logger: logger
            ) { @MainActor in
                var status = ControlDaemonStatus(
                    snapshot: orchestrator.snapshot,
                    config: orchestrator.configSnapshotProvider()
                )
                status.daemon = daemonMetadata
                status.configGeneration = configGeneration
                return status
            } reloadHandler: {
                logger.log(.notice, "Received control reload, reloading config...", category: .general)
                try await reloadConfig(
                    args: args,
                    environment: environment,
                    orchestrator: orchestrator,
                    logger: logger
                )
                configGeneration += 1
            } stopHandler: {
                logger.log(.notice, "Received control stop, stopping...", category: .general)
                await stopRuntime(orchestrator: orchestrator, eventFileWriter: eventFileWriter)
            } upstreamTestHandler: { upstreamName in
                await orchestrator.testUpstream(named: upstreamName)
            }

            for (sig, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    logger.log(.notice, "Received \(name), stopping...", category: .general)
                    Task { @MainActor in
                        controlServer.stop()
                        await stopRuntime(orchestrator: orchestrator, eventFileWriter: eventFileWriter)
                    }
                }
                source.resume()
                retainedSources.append(source)
            }

            signal(SIGHUP, SIG_IGN)
            let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
            hupSource.setEventHandler {
                logger.log(.notice, "Received SIGHUP, reloading config...", category: .general)
                Task { @MainActor in
                    do {
                        try await reloadConfig(
                            args: args,
                            environment: environment,
                            orchestrator: orchestrator,
                            logger: logger
                        )
                        configGeneration += 1
                    } catch {
                        // reloadConfig already emitted the rejection; keep serving
                        // the previous config and leave its generation unchanged.
                    }
                }
            }
            hupSource.resume()
            retainedSources.append(hupSource)

            do {
                try await orchestrator.startProxy()
                if config.dnsForwarderEnabled {
                    await orchestrator.startDNS()
                    guard orchestrator.snapshot.dnsRunState == .running else {
                        let message = orchestrator.snapshot.dnsError ?? "DNS forwarder failed to start."
                        logger.log(.error, message, category: .network)
                        logger.flush()
                        exit(1)
                    }
                }
                if config.tunnelDefinitions.contains(where: \.enabled) {
                    await orchestrator.startTunnels()
                    guard orchestrator.snapshot.tunnelsRunState != .failed else {
                        let message = orchestrator.snapshot.tunnelsError ?? "Protocol tunnels failed to start."
                        logger.log(.error, message, category: .tunnel)
                        logger.flush()
                        exit(1)
                    }
                }

                try controlServer.start()
                retainedSources.append(controlServer)
                let startupMilliseconds = Int(Date().timeIntervalSince(processStartedAt) * 1_000)
                try emitStatusEvent(
                    kind: .ready,
                    snapshot: orchestrator.snapshot,
                    startupMilliseconds: startupMilliseconds
                )
                writeReadyFile(snapshot: orchestrator.snapshot, environment: environment)
                writeSnapshotFile(snapshot: orchestrator.snapshot, environment: environment, logger: logger)
                if let readyBudgetMS, startupMilliseconds > readyBudgetMS {
                    logger.log(
                        .error,
                        "pm-proxy ready took \(startupMilliseconds) ms, exceeding \(readyBudgetMS) ms budget.",
                        category: .general
                    )
                    controlServer.stop()
                    await stopRuntime(orchestrator: orchestrator, eventFileWriter: eventFileWriter, exitCode: 1)
                }
                if exitAfterReady {
                    controlServer.stop()
                    await stopRuntime(orchestrator: orchestrator, eventFileWriter: eventFileWriter)
                }
                if let statusInterval, statusInterval > 0 {
                    startStatusStream(
                        interval: statusInterval,
                        environment: environment,
                        orchestrator: orchestrator,
                        logger: logger
                    )
                }
                logger.log(.notice, "pm-proxy is running. Press Ctrl-C to stop.", category: .general)
            } catch {
                logger.log(.error, "Failed to start pm-proxy: \(error.displayDescription)", category: .general)
                logger.flush()
                exit(1)
            }
        }

        dispatchMain()
    }

    @MainActor
    private static func reloadConfig(
        args: [String],
        environment: RuntimeEnvironment,
        orchestrator: ProxyOrchestrator,
        logger: any LogSink
    ) async throws {
        var newConfig: ProxyConfig
        do {
            newConfig = try loadConfig(from: args, environment: environment, isReload: true)
            applyCLIOverrides(to: &newConfig, from: args)
            if let problem = newConfig.validate().first(where: \.blocksProxyStart) { throw problem }
        } catch {
            let event = RuntimeEvent(kind: .config, event: "config.reload_rejected", detail: error.localizedDescription)
            orchestrator.eventLog.append(event)
            logger.log(.error, event.detail ?? event.event, category: .general)
            throw error
        }
        // applyConfigChange updates the orchestrator's configBox, so the auth
        // factory's snapshotProvider observes the new config on the next 407.
        await orchestrator.applyConfigChange(newConfig)
        writeSnapshotFile(snapshot: orchestrator.snapshot, environment: environment, logger: logger)
        do {
            try emitStatusEvent(kind: .status, snapshot: orchestrator.snapshot)
        } catch {
            logger.log(
                .warning,
                "Failed to emit post-reload status snapshot: \(error.localizedDescription)",
                category: .general
            )
        }
        logger.log(.notice, "Config reload complete.", category: .general)
    }

    @MainActor
    private static func stopRuntime(
        orchestrator: ProxyOrchestrator,
        eventFileWriter: RuntimeEventFileWriter,
        exitCode: Int32 = 0
    ) async {
        await orchestrator.stopTunnels()
        await orchestrator.stopDNS()
        await orchestrator.stopProxy()
        let auditFlushed = orchestrator.auditSink.flush(timeout: 2)
        eventFileWriter.flushReportingTimeout(auditFlushed: auditFlushed, eventLog: orchestrator.eventLog)
        // Shutdown diagnostics use bounded stderr; an unread stdout pipe must
        // not introduce a new unbounded wait after the flush deadline.
        do {
            let data = try CanonicalJSON.encoder().encode(writerStatistics?())
            ConsoleLogSink().log(.notice, "observability.writer_statistics \(String(decoding: data, as: UTF8.self))")
        } catch {
            ConsoleLogSink().log(.warning, "Failed to encode shutdown statistics: \(error.localizedDescription)")
        }
        ConsoleLogSink().flush()
        exit(exitCode)
    }

    // MARK: - Config Loading

    private static func loadConfig(from args: [String], environment: RuntimeEnvironment, isReload: Bool = false) throws -> ProxyConfig {
        if args.contains("--config-json") {
            guard let jsonString = parseStringArg("--config-json", from: args) else {
                throw ConfigurationLoadError(source: "--config-json", reason: "A JSON argument is required.")
            }
            return try ProxyConfigPersistence.decode(Data(jsonString.utf8), source: "--config-json")
        }
        if args.contains("--minimal") {
            return GenericDefaults.shared.makeConfig()
        }
        if args.contains("--config"), parseStringArg("--config", from: args) == nil {
            throw ConfigurationLoadError(source: "--config", reason: "A file path is required.")
        }
        return try ProxyConfigPersistence.load(in: environment, allowMissing: !isReload && !args.contains("--config"))
    }

    /// Resolve the connection audit sink for the headless daemon. Mirrors
    /// `AppState.makeAuditSink` — returns the no-op `DiscardingConnectionAuditSink`
    /// when audit is off (the default; preserves `pm-proxy`'s
    /// "no system side effects" stance), otherwise points a
    /// `FileConnectionAuditSink` at `auditLogPath` (or
    /// `$state-dir/audit.ndjson` if no override). Audit-on with an
    /// explicit `auditLogPath` outside the state-dir is intentionally
    /// allowed — operators using `pm-proxy` for compliance probes
    /// commonly want the audit file shipped to a tamper-evident volume
    /// even when the rest of the state dir is ephemeral.
    private static func makeAuditSink(
        for config: ProxyConfig,
        environment: RuntimeEnvironment,
        logger: any LogSink
    ) -> any ConnectionAuditSink {
        guard config.auditLogEnabled else {
            return DiscardingConnectionAuditSink()
        }
        let url: URL
        if let path = config.auditLogPath, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = environment.configDirectory.appendingPathComponent("audit.ndjson")
        }
        return FileConnectionAuditSink(
            fileURL: url,
            maxBytes: config.auditLogMaxBytes,
            logger: logger
        )
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

    private static func applyCLIOverrides(to config: inout ProxyConfig, from args: [String]) {
        if let port = parseIntArg("--port", from: args) {
            config.localPort = port
        }
        if let socksPort = parseIntArg("--socks-port", from: args) {
            config.socksEnabled = true
            config.socksPort = socksPort
        }
        if let dnsPort = parseIntArg("--dns-port", from: args) {
            config.dnsForwarderEnabled = true
            config.dnsForwarderPort = dnsPort
        }
        if let host = parseStringArg("--host", from: args) {
            config.localHost = host
        }
    }

    // MARK: - Ready File

    private static func writeReadyFile(snapshot: ProxyOrchestratorSnapshot, environment: RuntimeEnvironment) {
        let readyURL = environment.configDirectory.appendingPathComponent("ready.json")
        do {
            let dir = readyURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try readyEncoder.encode(snapshot.bindings)
            try data.write(to: readyURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                "Warning: could not write ready.json: \(error.localizedDescription)\n".data(using: .utf8)!
            )
        }
    }

    private static let readyEncoder: JSONEncoder = CanonicalJSON.encoder(prettyPrinted: true)

    // MARK: - Status Streaming

    private static let statusEncoder: JSONEncoder = CanonicalJSON.encoder()

    @MainActor
    private static var lastEmittedSnapshot: ProxyOrchestratorSnapshot?
    @MainActor
    private static var lastEmittedWriterStatistics: [String: RecordWriterStatistics]?

    @MainActor
    private static func startStatusStream(
        interval: TimeInterval,
        environment: RuntimeEnvironment,
        orchestrator: ProxyOrchestrator,
        logger: any LogSink
    ) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Match the orchestrator's maximum counter publication rate (10 Hz).
        // A tiny CLI interval must not flood the main queue with timer work.
        let boundedInterval = interval.isFinite ? max(interval, 0.1) : 0.1
        timer.schedule(deadline: .now() + boundedInterval, repeating: boundedInterval)
        timer.setEventHandler {
            // This source is explicitly dispatched on .main. Handle its tick
            // directly so slow output cannot accumulate one Task per tick.
            MainActor.assumeIsolated {
                let current = orchestrator.snapshot
                let statistics = writerStatistics?()
                guard current != lastEmittedSnapshot || statistics != lastEmittedWriterStatistics else { return }
                if current != lastEmittedSnapshot {
                    writeSnapshotFile(snapshot: current, environment: environment, logger: logger)
                }
                do {
                    try emitStatusEvent(kind: .status, snapshot: current, observability: statistics)
                } catch {
                    logger.log(.warning, "Failed to emit status snapshot: \(error.localizedDescription)", category: .general)
                }
            }
        }
        timer.resume()
        retainedSources.append(timer)
    }

    @MainActor
    private static var writerStatistics: (() -> [String: RecordWriterStatistics])?

    @MainActor
    private static func emitStatusEvent(
        kind: StatusEventKind,
        snapshot: ProxyOrchestratorSnapshot,
        startupMilliseconds: Int? = nil,
        observability: [String: RecordWriterStatistics]? = nil
    ) throws {
        let statistics = observability ?? writerStatistics?()
        let payload = StatusEvent(kind: kind, snapshot: snapshot, startupMilliseconds: startupMilliseconds, observability: statistics)
        let data = try statusEncoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        lastEmittedSnapshot = snapshot
        lastEmittedWriterStatistics = statistics
    }

    private static let snapshotFileEncoder: JSONEncoder = CanonicalJSON.encoder(prettyPrinted: true)

    private static func writeSnapshotFile(
        snapshot: ProxyOrchestratorSnapshot,
        environment: RuntimeEnvironment,
        logger: any LogSink
    ) {
        do {
            try FileManager.default.createDirectory(
                at: environment.snapshotFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try snapshotFileEncoder.encode(snapshot)
            try data.write(to: environment.snapshotFile, options: .atomic)
        } catch {
            logger.log(
                .warning,
                "Failed to write snapshot.json: \(error.localizedDescription)",
                category: .general
            )
        }
    }

    // MARK: - Argument Parsing

    private static func parseDoubleArg(_ flag: String, from args: [String]) -> TimeInterval? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return TimeInterval(args[idx + 1])
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

private struct StatusEvent: Codable {
    let kind: StatusEventKind
    let snapshot: ProxyOrchestratorSnapshot
    let startupMilliseconds: Int?
    let observability: [String: RecordWriterStatistics]?
}

private enum StatusEventKind: String, Codable {
    case ready
    case status
}
