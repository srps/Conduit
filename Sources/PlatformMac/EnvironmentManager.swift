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
        logger?.log(.notice, "Updated shell environment proxy variables.", category: .system)
    }

    package func clear(logger: (any LogSink)?) throws {
        for file in targetFiles where FileManager.default.fileExists(atPath: file.path) {
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let cleaned = stripManagedBlock(from: existing)
            try cleaned.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n").write(to: file, atomically: true, encoding: .utf8)
        }
        logger?.log(.notice, "Removed managed shell proxy variables.", category: .system)
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
