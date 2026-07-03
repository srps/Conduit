// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package final class EnvironmentManager {
    package init() {}
    private let blockStart = "# >>> Conduit >>>"
    private let blockEnd = "# <<< Conduit <<<"

    private var targetFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
        var failures = 0
        for name in launchdVariableNames {
            guard let value = values[name] else { continue }
            let result = try? CommandRunner.run(launchPath: "/bin/launchctl", arguments: ["setenv", name, value])
            if result?.exitCode != 0 { failures += 1 }
        }
        if failures > 0 {
            logger?.log(.warning, "launchctl setenv failed for \(failures) proxy variable(s); GUI apps may not see the proxy.", category: .system)
        } else {
            logger?.log(.notice, "Published proxy variables to the user launchd domain (GUI apps pick them up on next launch).", category: .system)
        }
    }

    private func clearLaunchdEnvironment(logger: (any LogSink)?) {
        for name in launchdVariableNames {
            _ = try? CommandRunner.run(launchPath: "/bin/launchctl", arguments: ["unsetenv", name])
        }
        logger?.log(.notice, "Cleared proxy variables from the user launchd domain.", category: .system)
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
