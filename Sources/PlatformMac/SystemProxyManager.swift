// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

enum SystemProxyManagerError: Error, LocalizedError {
    case noNetworkServices
    case commandFailed(String)

    package var errorDescription: String? {
        switch self {
        case .noNetworkServices:
            return "No active macOS network services were found."
        case .commandFailed(let message):
            return message
        }
    }
}

package final class SystemProxyManager: @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    private let commandRunner: @Sendable (String, [String]) throws -> CommandResult

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        }
    ) {
        self.privilegeClient = privilegeClient
        self.commandRunner = commandRunner
    }

    // MARK: - State Detection

    package static func effectivePACURL(config: ProxyConfig, localPACURL: String?) -> String {
        if config.localPACEnabled, let localPACURL, !localPACURL.isEmpty {
            return localPACURL
        }
        return config.pacURL
    }

    package func isApplied(config: ProxyConfig, mode: SystemProxyMode, localPACURL: String? = nil) -> Bool {
        guard let services = try? connectedNetworkServices(logger: nil),
              !services.isEmpty else { return false }

        switch mode {
        case .manual:
            return services.allSatisfy { service in
                proxyFieldsMatch(service: service, type: "webproxy", host: config.localHost, port: config.localPort)
                && proxyFieldsMatch(service: service, type: "securewebproxy", host: config.localHost, port: config.localPort)
            }
        case .pac:
            let pacURL = Self.effectivePACURL(config: config, localPACURL: localPACURL)
            guard !pacURL.isEmpty else { return false }
            return services.allSatisfy { service in
                autoproxyMatches(service: service, url: pacURL)
                && !readProxyState(service: service, type: "webproxy").enabled
                && !readProxyState(service: service, type: "securewebproxy").enabled
            }
        }
    }

    package func isCleared() -> Bool {
        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()
        return services.allSatisfy { service in
            !readProxyState(service: service, type: "webproxy").enabled
            && !readProxyState(service: service, type: "securewebproxy").enabled
            && !readAutoproxyEnabled(service: service)
        }
    }

    // MARK: - Apply / Clear

    package func apply(config: ProxyConfig, mode: SystemProxyMode, logger: (any LogSink)?, localPACURL: String? = nil) throws {
        let services = try connectedNetworkServices(logger: logger)
        guard !services.isEmpty else {
            throw SystemProxyManagerError.noNetworkServices
        }

        let pacURL = Self.effectivePACURL(config: config, localPACURL: localPACURL)
        var script = ""
        for service in services {
            let s = service.shellQuoted
            let h = config.localHost.shellQuoted
            let p = String(config.localPort)
            let bypass = config.noProxyHosts.map { $0.shellQuoted }.joined(separator: " ")

            switch mode {
            case .manual:
                script += "/usr/sbin/networksetup -setautoproxystate \(s) off\n"
                script += "/usr/sbin/networksetup -setwebproxy \(s) \(h) \(p)\n"
                script += "/usr/sbin/networksetup -setsecurewebproxy \(s) \(h) \(p)\n"
                script += "/usr/sbin/networksetup -setproxybypassdomains \(s) \(bypass)\n"
                script += "/usr/sbin/networksetup -setwebproxystate \(s) on\n"
                script += "/usr/sbin/networksetup -setsecurewebproxystate \(s) on\n"
            case .pac:
                if !pacURL.isEmpty {
                    script += "/usr/sbin/networksetup -setwebproxystate \(s) off 2>/dev/null || true\n"
                    script += "/usr/sbin/networksetup -setsecurewebproxystate \(s) off 2>/dev/null || true\n"
                    script += "/usr/sbin/networksetup -setautoproxyurl \(s) \(pacURL.shellQuoted)\n"
                    script += "/usr/sbin/networksetup -setautoproxystate \(s) on\n"
                }
            }
        }

        guard !script.isEmpty else { return }

        let result = try runUnprivileged(script)
        if result.exitCode != 0 {
            let output = [result.standardError, result.standardOutput].filter { !$0.isEmpty }.joined(separator: " | ")
            if output.contains("requires admin") || result.exitCode == 14 {
                logger?.log(.info, "networksetup requires admin, prompting...", category: .system)
                try applyViaPrivilegeClient(config: config, mode: mode, services: services, pacURL: pacURL, logger: logger)
            } else {
                throw SystemProxyManagerError.commandFailed("networksetup failed (exit \(result.exitCode)): \(output.isEmpty ? "no output" : output)")
            }
        }

        logger?.log(.notice, "Applied macOS proxy settings to \(services.count) service(s).", category: .system)
    }

    package func clear(logger: (any LogSink)?) throws {
        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()

        var script = ""
        for service in services {
            let s = service.shellQuoted
            script += "/usr/sbin/networksetup -setwebproxystate \(s) off 2>/dev/null || true\n"
            script += "/usr/sbin/networksetup -setsecurewebproxystate \(s) off 2>/dev/null || true\n"
            script += "/usr/sbin/networksetup -setautoproxystate \(s) off 2>/dev/null || true\n"
        }

        guard !script.isEmpty else { return }

        let result = try runUnprivileged(script)
        if result.exitCode != 0 {
            let output = [result.standardError, result.standardOutput].filter { !$0.isEmpty }.joined(separator: " | ")
            if output.contains("requires admin") || result.exitCode == 14 {
                for service in services {
                    try? privilegeClient.execute(.clearSystemProxy, values: [service])
                }
            }
        }

        logger?.log(.notice, "Cleared macOS proxy settings.", category: .system)
    }

    private func applyViaPrivilegeClient(config: ProxyConfig, mode: SystemProxyMode, services: [String], pacURL: String, logger: (any LogSink)?) throws {
        for service in services {
            switch mode {
            case .manual:
                try privilegeClient.execute(.disableAutoproxy, values: [service])
                try privilegeClient.execute(.applySystemProxy, values: [service, config.localHost, String(config.localPort)])
                try privilegeClient.execute(.setProxyBypass, values: [service] + config.noProxyHosts)
            case .pac:
                if !pacURL.isEmpty {
                    // Set PAC first so a failure in clearing manual proxies
                    // does not leave the service with no proxy at all.
                    try privilegeClient.execute(.setAutoproxyURL, values: [service, pacURL])
                    // clearSystemProxy also disables autoproxy; re-arm afterwards.
                    do {
                        try privilegeClient.execute(.clearSystemProxy, values: [service])
                    } catch {
                        logger?.log(.warning, "clearSystemProxy failed for \(service): \(error.localizedDescription); PAC is active, re-arming autoproxy.", category: .system)
                    }
                    try privilegeClient.execute(.setAutoproxyURL, values: [service, pacURL])
                }
            }
        }
    }

    // MARK: - Service Discovery

    package func connectedNetworkServices(logger: (any LogSink)?) throws -> [String] {
        let all = try listNetworkServices()
        var connected: [String] = []
        for service in all {
            if hasIPAddress(service: service) {
                connected.append(service)
            }
        }
        if connected.isEmpty {
            logger?.log(.warning, "No connected services found; falling back to all listed services.", category: .system)
            return all
        }
        return connected
    }

    // MARK: - Private

    private func allNetworkServices() -> [String] {
        (try? listNetworkServices()) ?? []
    }

    private func listNetworkServices() throws -> [String] {
        let result = try commandRunner("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return result.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return false }
                if trimmed.hasPrefix("An asterisk") { return false }
                if trimmed.hasPrefix("*") { return false }
                return true
            }
    }

    private func hasIPAddress(service: String) -> Bool {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getinfo", service]),
              result.exitCode == 0 else {
            return false
        }
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("IP address:") {
                let value = trimmed.dropFirst("IP address:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value != "none" {
                    return true
                }
            }
        }
        return false
    }

    private func runUnprivileged(_ script: String) throws -> CommandResult {
        try commandRunner("/bin/sh", ["-c", script])
    }

    // MARK: - State Reading

    private struct ProxyState {
        var enabled = false
        var host = ""
        var port = "0"
    }

    private func readProxyState(service: String, type: String) -> ProxyState {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-get\(type)", service]),
              result.exitCode == 0 else { return ProxyState() }

        var state = ProxyState()
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Enabled:") {
                state.enabled = trimmed.dropFirst("Enabled:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "Yes"
            } else if trimmed.hasPrefix("Server:") {
                state.host = String(trimmed.dropFirst("Server:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("Port:") {
                state.port = String(trimmed.dropFirst("Port:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return state
    }

    private func proxyFieldsMatch(service: String, type: String, host: String, port: Int) -> Bool {
        let state = readProxyState(service: service, type: type)
        return state.enabled && state.host == host && state.port == String(port)
    }

    private func readAutoproxyEnabled(service: String) -> Bool {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getautoproxyurl", service]),
              result.exitCode == 0 else { return false }
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Enabled:") {
                return trimmed.dropFirst("Enabled:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "Yes"
            }
        }
        return false
    }

    private func autoproxyMatches(service: String, url: String) -> Bool {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getautoproxyurl", service]),
              result.exitCode == 0 else { return false }

        var currentURL = ""
        var enabled = false
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("URL:") {
                currentURL = String(trimmed.dropFirst("URL:".count).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.dropFirst("Enabled:".count).trimmingCharacters(in: .whitespacesAndNewlines) == "Yes"
            }
        }
        return enabled && currentURL == url
    }
}
