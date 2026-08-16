// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package final class EnvironmentManager {
    /// Prior values of the launchd variables we publish, so teardown restores
    /// rather than unsetting whatever was there.
    ///
    /// The shell-profile half of this class needs no journal: its marker block
    /// already delimits our region inside a file we do not own, which answers
    /// a different question — *which part of this is ours* — and does it
    /// without copying a user's `.zshrc` into our state directory.
    private let journal: PlatformStateJournal
    /// Home directory whose shell profiles we edit, and the launchctl runner.
    ///
    /// Both are injectable because this class edits a user's dotfiles and their
    /// launchd domain — real, visible, outside-the-sandbox side effects. Without
    /// a seam the only honest amount of test coverage was none, which is what it
    /// had. Mirrors `SystemProxyManager`'s injected `commandRunner`.
    private let homeDirectory: URL
    private let commandRunner: @Sendable (String, [String]) throws -> CommandResult

    package init(
        journal: PlatformStateJournal,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        }
    ) {
        self.journal = journal
        self.homeDirectory = homeDirectory
        self.commandRunner = commandRunner
    }

    private let blockStart = "# >>> Conduit >>>"
    private let blockEnd = "# <<< Conduit <<<"

    package var targetFiles: [URL] {
        let home = homeDirectory
        return [
            home.appendingPathComponent(".zshrc"),
            home.appendingPathComponent(".zprofile"),
            home.appendingPathComponent(".config/environment.d/proxy-manager.conf")
        ]
    }

    package func apply(config: ProxyConfig, logger: (any LogSink)?) throws {
        let block = renderBlock(config: config)
        for file in targetFiles {
            try ensureParentDirectory(for: file)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let cleaned = stripManagedBlock(from: existing)
            let next = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalContent = next.isEmpty ? block : next + "\n\n" + block + "\n"
            try finalContent.write(to: file, atomically: true, encoding: .utf8)
        }
        applyLaunchdEnvironment(config: config, logger: logger)
        logger?.log(.notice, "Updated shell environment proxy variables.", category: .system)
    }

    package func clear(logger: (any LogSink)?) throws {
        for file in targetFiles where FileManager.default.fileExists(atPath: file.path) {
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let cleaned = stripManagedBlock(from: existing)
            try cleaned.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n").write(to: file, atomically: true, encoding: .utf8)
        }
        clearLaunchdEnvironment(logger: logger)
        logger?.log(.notice, "Removed managed shell proxy variables.", category: .system)
    }

    // MARK: - Launchd (GUI app) environment

    /// GUI apps launched from Dock/Finder/Spotlight never read shell profiles,
    /// so the `.zshrc`/`.zprofile` blocks above are invisible to them. Several
    /// of them also ignore the system proxy/PAC settings and only honor
    /// `HTTP(S)_PROXY` env vars — the Codex desktop app (Rust/reqwest core)
    /// and Cursor's agent sidecar are the motivating cases. `launchctl setenv`
    /// publishes the vars to the per-user launchd domain, which is the parent
    /// of every GUI app; apps pick them up on their next launch. No privilege
    /// needed. Best-effort: a launchctl failure must not fail proxy startup.
    private var launchdVariableNames: [String] {
        ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy"]
    }

    private func applyLaunchdEnvironment(config: ProxyConfig, logger: (any LogSink)?) {
        let proxyURL = config.localProxyURL
        let noProxy = config.noProxyHosts.joined(separator: ",")
        let values: [String: String] = [
            "HTTP_PROXY": proxyURL, "http_proxy": proxyURL,
            "HTTPS_PROXY": proxyURL, "https_proxy": proxyURL,
            "NO_PROXY": noProxy, "no_proxy": noProxy,
        ]
        // Capture before overwriting. A developer with HTTP_PROXY already
        // exported into their launchd domain would otherwise have it silently
        // unset by our teardown, with nothing recording that it existed.
        for name in launchdVariableNames {
            journal.recordPrior(
                surface: .launchdEnvironment,
                scope: name,
                value: readLaunchdValue(name).map { ["value": $0] }
            )
        }
        journal.markApplied(surface: .launchdEnvironment)

        var failures = 0
        for name in launchdVariableNames {
            guard let value = values[name] else { continue }
            let result = try? commandRunner("/bin/launchctl", ["setenv", name, value])
            if result?.exitCode != 0 { failures += 1 }
        }
        if failures > 0 {
            logger?.log(.warning, "launchctl setenv failed for \(failures) proxy variable(s); GUI apps may not see the proxy.", category: .system)
        } else {
            logger?.log(.notice, "Published proxy variables to the user launchd domain (GUI apps pick them up on next launch).", category: .system)
        }
    }

    private func clearLaunchdEnvironment(logger: (any LogSink)?) {
        // Same reason as `SystemProxyManager.clear`: a second teardown finding
        // no records would `unsetenv` the pre-existing values the first one
        // restored. Both hosts clear on stop and again on quit.
        if journal.knowsSurfaceIsIdle(.launchdEnvironment) {
            logger?.log(.debug, "launchd environment teardown skipped: nothing recorded as applied.", category: .system)
            return
        }

        var restored = 0
        var failed: [String] = []
        for name in launchdVariableNames {
            let result: CommandResult?
            switch journal.prior(surface: .launchdEnvironment, scope: name) {
            case .wasPresent(let prior):
                result = try? commandRunner("/bin/launchctl", ["setenv", name, prior["value"] ?? ""])
                if result?.exitCode == 0 { restored += 1 }
            case .wasAbsent, .notRecorded:
                // Unknown falls back to unsetting: leaving our proxy URL in the
                // launchd domain would point every GUI app launched afterwards
                // at a proxy that is no longer running.
                result = try? commandRunner("/bin/launchctl", ["unsetenv", name])
            }
            if result?.exitCode != 0 { failed.append(name) }
        }

        // Keep the records if anything failed. Forgetting on a partial restore
        // destroys the only copy of the user's original values while leaving
        // some of ours in place, and a later teardown could otherwise never
        // retry.
        if failed.isEmpty {
            journal.forgetAll(surface: .launchdEnvironment)
        } else {
            logger?.log(
                .warning,
                "launchctl failed for \(failed.joined(separator: ", ")); keeping the recorded values so the next teardown can retry.",
                category: .system
            )
        }

        if restored > 0 {
            logger?.log(.notice, "Restored \(restored) pre-existing launchd proxy variable(s), cleared the rest.", category: .system)
        } else if failed.isEmpty {
            logger?.log(.notice, "Cleared proxy variables from the user launchd domain.", category: .system)
        }
    }

    /// Current value of a launchd variable, or nil when it is not set.
    private func readLaunchdValue(_ name: String) -> String? {
        guard let result = try? commandRunner("/bin/launchctl", ["getenv", name]),
              result.exitCode == 0
        else { return nil }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func renderBlock(config: ProxyConfig) -> String {
        let noProxy = config.noProxyHosts.joined(separator: ",")
        let proxyURL = config.localProxyURL.shellQuoted
        return [
            blockStart,
            "export HTTP_PROXY=\(proxyURL)",
            "export HTTPS_PROXY=\(proxyURL)",
            "export http_proxy=\(proxyURL)",
            "export https_proxy=\(proxyURL)",
            "export NO_PROXY=\(noProxy.shellQuoted)",
            "export no_proxy=\(noProxy.shellQuoted)",
            blockEnd
        ].joined(separator: "\n")
    }

    private func stripManagedBlock(from content: String) -> String {
        guard
            let start = content.range(of: blockStart),
            let end = content.range(of: blockEnd)
        else {
            return content
        }

        let removalRange = start.lowerBound ..< end.upperBound
        var updated = content
        updated.removeSubrange(removalRange)
        return updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func ensureParentDirectory(for file: URL) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
    }
}
