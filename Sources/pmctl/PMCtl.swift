// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitShared

@main
enum PMCtl {
    static func main() {
        signal(SIGPIPE, SIG_IGN)

        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            printHelp()
            return
        }

        let commandName = parseCommandName(from: args) ?? "status"
        guard let command = ControlCommand(rawValue: commandName) else {
            let command = commandName
            FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
            printHelp()
            exit(2)
        }

        do {
            switch command {
            case .diag:
                let bundleURL = try createDiagnosticsBundle(from: args)
                print("Wrote diagnostics bundle: \(bundleURL.path)")
            case .events:
                try printEvents(from: args)
            case .reload:
                try reloadDaemon(from: args)
                print("Reloaded Conduit daemon.")
            case .setProfile:
                let profileName = try profileName(from: args)
                try setDaemonProfile(profileName, from: args)
                print("Switched Conduit daemon profile to \(profileName).")
            case .start:
                try startDaemon(from: args)
                print("Started Conduit daemon.")
            case .status:
                let status = try fetchStatus(from: args)
                if args.contains("--json") {
                    try printJSON(status)
                } else {
                    printHuman(status)
                }
            case .stop:
                try stopDaemon(from: args)
                print("Stopping Conduit daemon.")
            case .testUpstream:
                let result = try testUpstream(from: args)
                if args.contains("--json") {
                    try writeJSON(result, to: nil)
                } else {
                    printUpstreamTest(result)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("pmctl \(command.rawValue) failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printHelp() {
        print("""
        pmctl - Conduit daemon control CLI

        USAGE:
          pmctl diag [--state-dir <path>] [--socket <path>] [--output <path>]
          pmctl events [--state-dir <path>] [--events-file <path>] [--json] [--follow]
          pmctl reload [--state-dir <path>] [--socket <path>]
          pmctl set-profile <name> [--state-dir <path>] [--socket <path>]
          pmctl start [--state-dir <path>] [--socket <path>]
          pmctl status [--state-dir <path>] [--socket <path>] [--json]
          pmctl stop [--state-dir <path>] [--socket <path>]
          pmctl test <upstream> [--state-dir <path>] [--socket <path>] [--json]

        OPTIONS:
          --events-file <path> Explicit events.ndjson path
          --follow             Keep streaming new events
          --output <path>      Diagnostics bundle directory
          --state-dir <path>  Directory containing control.sock
          --socket <path>     Explicit control socket path
          --json              Print the status payload as JSON
          --help, -h          Show this help

        ENVIRONMENT:
          PM_CONFIG_DIR       Default state directory when --state-dir is omitted
        """)
    }

    private static func fetchStatus(from args: [String]) throws -> ControlDaemonStatus {
        try client(from: args).status()
    }

    private static func createDiagnosticsBundle(from args: [String]) throws -> URL {
        let stateDirectory = stateDirectoryURL(from: args)
        let bundleURL = diagnosticsBundleURL(from: args)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var includedFiles: [String] = []
        if let status = try? fetchStatus(from: args) {
            let destinationName = redactedDiagnosticFileName(for: "status.json")
            try writeSanitizedJSON(
                status,
                to: bundleURL.appendingPathComponent(destinationName),
                fileKind: .status
            )
            includedFiles.append(destinationName)
        } else {
            let message = "Daemon status unavailable; control socket may not be running.\n"
            try Data(message.utf8).write(to: bundleURL.appendingPathComponent("status-error.txt"), options: .atomic)
            includedFiles.append("status-error.txt")
        }

        let diagnosticJSONFiles: [(fileName: String, kind: ControlDiagnosticFileKind)] = [
            ("snapshot.json", .snapshot),
            ("ready.json", .ready),
            ("config.json", .config),
            ("platform.json", .platform),
            ("preferences.json", .preferences),
        ]
        for (fileName, kind) in diagnosticJSONFiles {
            let source = stateDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destinationName = redactedDiagnosticFileName(for: fileName)
            try copySanitizedJSON(
                from: source,
                to: bundleURL.appendingPathComponent(destinationName),
                fileKind: kind
            )
            includedFiles.append(destinationName)
        }

        let events = stateDirectory.appendingPathComponent(ControlEventLog.fileName)
        if FileManager.default.fileExists(atPath: events.path) {
            let destinationName = redactedDiagnosticFileName(for: ControlEventLog.fileName)
            try copySanitizedNDJSON(
                from: events,
                to: bundleURL.appendingPathComponent(destinationName),
                fileKind: .events
            )
            includedFiles.append(destinationName)
        }

        // Recent crash reports, sanitized. Crash evidence otherwise sits
        // unnoticed in DiagnosticReports; a diag bundle that omits it cannot
        // answer "did the daemon crash last week?".
        for report in CrashReportCollector.recentReports(in: CrashReportCollector.defaultDirectory()) {
            guard let raw = try? String(contentsOf: report.url, encoding: .utf8) else { continue }
            let destinationName = redactedDiagnosticFileName(for: report.url.lastPathComponent)
            let sanitized = CrashReportCollector.sanitize(raw)
            try Data(sanitized.utf8).write(
                to: bundleURL.appendingPathComponent(destinationName),
                options: .atomic
            )
            includedFiles.append(destinationName)
        }

        try writeManifest(
            stateDirectory: stateDirectory,
            includedFiles: includedFiles.sorted(),
            to: bundleURL.appendingPathComponent("manifest.json")
        )
        return bundleURL
    }

    private static func redactedDiagnosticFileName(for fileName: String) -> String {
        if fileName.hasSuffix(".ndjson") {
            return "\(fileName.dropLast(".ndjson".count)).redacted.ndjson"
        }
        if fileName.hasSuffix(".json") {
            return "\(fileName.dropLast(".json".count)).redacted.json"
        }
        return "\(fileName).redacted"
    }

    private static func printEvents(from args: [String]) throws {
        let fileURL = eventsFileURL(from: args)
        let asJSON = args.contains("--json")
        let follow = args.contains("--follow")
        var readState = EventReadState()
        try printAvailableEvents(from: fileURL, state: &readState, asJSON: asJSON)

        guard follow else { return }
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            try printAvailableEvents(from: fileURL, state: &readState, asJSON: asJSON)
        }
    }

    private static func stopDaemon(from args: [String]) throws {
        try client(from: args).stop()
    }

    private static func reloadDaemon(from args: [String]) throws {
        try client(from: args).reload()
    }

    private static func startDaemon(from args: [String]) throws {
        try client(from: args).start()
    }

    private static func setDaemonProfile(_ profileName: String, from args: [String]) throws {
        try client(from: args).setProfile(profileName)
    }

    private static func testUpstream(from args: [String]) throws -> ControlUpstreamTestResult {
        try client(from: args).testUpstream(named: try upstreamName(from: args))
    }

    private static func client(from args: [String]) -> DaemonClient {
        DaemonClient(socketPath: controlSocketPath(from: args))
    }

    private static func printJSON(_ status: ControlDaemonStatus) throws {
        try writeJSON(status, to: nil)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to destination: URL?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let destination {
            try data.write(to: destination, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private static func writeSanitizedJSON<T: Encodable>(
        _ value: T,
        to destination: URL,
        fileKind: ControlDiagnosticFileKind
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: data, fileKind: fileKind)
        try sanitized.write(to: destination, options: .atomic)
    }

    private static func printHuman(_ status: ControlDaemonStatus) {
        let proxy = endpoint(host: status.bindings.proxyHost, port: status.bindings.proxyPort)
        let socks = endpoint(host: status.bindings.socksHost, port: status.bindings.socksPort)
        let dns = endpoint(host: status.bindings.dnsHost, port: status.bindings.dnsPort)

        print("Conduit daemon")
        print("  profile       : \(status.profileName)")
        print("  generation    : \(status.configGeneration)")
        if let daemon = status.daemon {
            print("  daemon        : \(daemon.executableName) pid=\(daemon.processID)")
        }
        print("  state         : \(status.state)")
        print("  health        : \(status.healthSummary)")
        print("  upstream      : \(status.activeUpstream ?? "-")")
        print("  direct mode   : \(status.isDirectMode ? "yes" : "no") (\(status.directModeCause))")
        print("  proxy         : \(proxy)")
        print("  socks         : \(socks)")
        print("  dns           : \(status.dnsRunState) \(dns)")
        print("  tunnels       : \(status.tunnelsRunState) active=\(status.tunnelActiveCount) sessions=\(status.tunnelSessionCount)")
        print("  connections   : open=\(status.metrics.openConnections) inbound=\(status.metrics.inboundConnections)")
        print("  requests      : handled=\(status.metrics.requestsHandled) failed=\(status.metrics.failedRequests)")
    }

    private static func printUpstreamTest(_ result: ControlUpstreamTestResult) {
        let status = result.reachable ? "reachable" : "unreachable"
        print("\(result.name) (\(result.endpoint)): \(status), latency=\(result.latencyMS)ms")
    }

    private static func printAvailableEvents(
        from fileURL: URL,
        state: inout EventReadState,
        asJSON: Bool
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state.lastData = Data()
            return
        }
        let data = try Data(contentsOf: fileURL)
        let chunk: Data
        if !state.lastData.isEmpty, data.starts(with: state.lastData) {
            chunk = Data(data.dropFirst(state.lastData.count))
        } else {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            let startIndex: Int
            if let lastPrintedLine = state.lastPrintedLine,
               let matchIndex = lines.lastIndex(of: Substring(lastPrintedLine)) {
                startIndex = lines.index(after: matchIndex)
            } else {
                startIndex = lines.startIndex
            }
            let newLines = lines[startIndex...]
            chunk = Data((newLines.joined(separator: "\n") + (newLines.isEmpty ? "" : "\n")).utf8)
        }
        state.lastData = data
        guard !chunk.isEmpty else { return }

        let text = String(decoding: chunk, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let line = String(line)
            try printEventLine(line, asJSON: asJSON)
            state.lastPrintedLine = line
        }
    }

    private static func printEventLine(_ line: String, asJSON: Bool) throws {
        if asJSON {
            print(line)
            fflush(stdout)
            return
        }

        let event = try eventDecoder.decode(ControlRuntimeEvent.self, from: Data(line.utf8))
        print(event.humanDescription)
        fflush(stdout)
    }

    /// Decoder for `events.ndjson` lines produced by `RuntimeEventFileWriter`.
    /// Pinned to `.secondsSince1970` to match the canonical encoder used on
    /// the daemon side (`ProxyKernel/Support/CanonicalJSON.swift`). Without
    /// this override, plain `JSONDecoder()` interprets the file's `timestamp`
    /// fields as Apple reference-date Doubles, shifting every event by ~31
    /// years in `pmctl events --follow` (Unix epoch is 978307200 s after
    /// Apple's reference). pmctl can't import `ProxyKernel` (cross-target),
    /// so the strategy is configured inline; a single-line wrinkle is
    /// cheaper than a new dependency.
    private static let eventDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func endpoint(host: String?, port: Int?) -> String {
        guard let host, let port else { return "-" }
        return "\(host):\(port)"
    }

    private static func controlSocketPath(from args: [String]) -> String {
        if let value = parseStringArg("--socket", from: args) {
            return value
        }
        return ControlSocket.path(in: stateDirectoryURL(from: args))
    }

    private static func eventsFileURL(from args: [String]) -> URL {
        if let value = parseStringArg("--events-file", from: args) {
            return URL(fileURLWithPath: value)
        }
        return stateDirectoryURL(from: args).appendingPathComponent(ControlEventLog.fileName)
    }

    private static func stateDirectoryURL(from args: [String]) -> URL {
        if let value = parseStringArg("--state-dir", from: args) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let value = ProcessInfo.processInfo.environment["PM_CONFIG_DIR"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Conduit", isDirectory: true)
    }

    private static func diagnosticsBundleURL(from args: [String]) -> URL {
        if let value = parseStringArg("--output", from: args) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(ControlDiagnostics.defaultBundlePrefix)-\(formatter.string(from: Date()))"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func parseStringArg(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func parseCommandName(from args: [String]) -> String? {
        guard let first = positionalArguments(from: args).first else { return nil }
        if first == "test" {
            return ControlCommand.testUpstream.rawValue
        }
        return first
    }

    private static func profileName(from args: [String]) throws -> String {
        let name = positionalArguments(from: args).dropFirst().joined(separator: " ")
        guard !name.isEmpty else {
            throw PMCtlError.daemon("Missing profile name.")
        }
        return name
    }

    private static func upstreamName(from args: [String]) throws -> String {
        let name = positionalArguments(from: args).dropFirst().joined(separator: " ")
        guard !name.isEmpty else {
            throw PMCtlError.daemon("Missing upstream name.")
        }
        return name
    }

    private static func positionalArguments(from args: [String]) -> [String] {
        let flagsWithValues: Set<String> = ["--events-file", "--output", "--state-dir", "--socket"]
        var skipNext = false
        var values: [String] = []
        for arg in args.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }
            if flagsWithValues.contains(arg) {
                skipNext = true
                continue
            }
            if arg.hasPrefix("--") {
                continue
            }
            values.append(arg)
        }
        return values
    }

    private static func copySanitizedJSON(
        from source: URL,
        to destination: URL,
        fileKind: ControlDiagnosticFileKind
    ) throws {
        let data = try Data(contentsOf: source)
        do {
            let sanitized = try ControlDiagnostics.sanitizedJSONData(from: data, fileKind: fileKind)
            try sanitized.write(to: destination, options: .atomic)
        } catch {
            let sanitized = ControlDiagnostics.sanitizeString(String(decoding: data, as: UTF8.self))
            try Data(sanitized.utf8).write(to: destination, options: .atomic)
        }
    }

    private static func copySanitizedNDJSON(
        from source: URL,
        to destination: URL,
        fileKind: ControlDiagnosticFileKind
    ) throws {
        let text = String(decoding: try Data(contentsOf: source), as: UTF8.self)
        let lines = try text.split(separator: "\n", omittingEmptySubsequences: true).map { line -> String in
            let data = Data(line.utf8)
            if let object = try? JSONSerialization.jsonObject(with: data) {
                let sanitized = ControlDiagnostics.sanitizedJSONObject(object, fileKind: fileKind)
                let sanitizedData = try JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
                return String(decoding: sanitizedData, as: UTF8.self)
            }
            return ControlDiagnostics.sanitizeString(String(line))
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: destination, options: .atomic)
    }

    private static func writeManifest(
        stateDirectory: URL,
        includedFiles: [String],
        to destination: URL
    ) throws {
        let manifest: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "stateDirectory": "<redacted>",
            "stateDirectoryRedacted": true,
            "includedFiles": includedFiles,
            "tool": "pmctl diag",
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
    }

}

private enum PMCtlError: LocalizedError {
    case daemon(String)

    var errorDescription: String? {
        switch self {
        case .daemon(let message):
            return message
        }
    }
}

private struct EventReadState {
    var lastData = Data()
    var lastPrintedLine: String?
}
