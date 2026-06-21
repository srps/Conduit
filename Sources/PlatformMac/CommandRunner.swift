// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package struct CommandResult: Sendable {
    package let exitCode: Int32
    package let standardOutput: String
    package let standardError: String
}

package enum CommandRunnerError: Error, LocalizedError {
    case executionFailed(String)

    package var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}

package enum CommandRunner {
    @discardableResult
    package static func run(
        launchPath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    package static func runShellScript(_ script: String) throws -> CommandResult {
        try run(launchPath: "/bin/zsh", arguments: ["-lc", script])
    }

    @discardableResult
    package static func runPrivilegedShellScript(_ script: String) throws -> CommandResult {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-\(UUID().uuidString).sh")
        try script.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let appleScript = "do shell script \"/bin/sh " + tempFile.path.shellQuoted + "\" with administrator privileges"
        return try run(launchPath: "/usr/bin/osascript", arguments: ["-e", appleScript])
    }
}

extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
