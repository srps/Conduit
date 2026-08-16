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
    /// Records what each service's proxy configuration was before we changed
    /// it, so `clear` restores rather than blanket-disabling. Optional: without
    /// one, teardown keeps its previous unconditional behaviour rather than
    /// refusing to clean up — see `PlatformStateJournal` on why "unknown"
    /// must never mean "leave it".
    private let journal: PlatformStateJournal?

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        journal: PlatformStateJournal? = nil,
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        }
    ) {
        self.privilegeClient = privilegeClient
        self.journal = journal
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

        // Capture before overwriting. `recordPrior` is first-write-wins, so
        // the repeat applies a session performs (config reload, restart, VPN
        // transition) cannot replace the user's original setting with ours.
        if let journal {
            for service in services {
                journal.recordPrior(
                    surface: .systemProxy,
                    scope: service,
                    value: capturePriorState(service: service)
                )
            }
            journal.markApplied(surface: .systemProxy)
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

    /// Puts each service back the way it was before `apply`, falling back to
    /// disabling every proxy on services the journal has no record for.
    ///
    /// The fallback is the important half. A machine can reach teardown with no
    /// record at all — the journal was never wired in, it was wiped, or the
    /// process that wrote it was `SIGKILL`ed — and refusing to act then would
    /// leave the system pointing at a proxy port nothing serves, which breaks
    /// networking for every client on the machine. Over-clearing costs the user
    /// a visible setting they can restore; stranding does not announce itself.
    package func clear(logger: (any LogSink)?) throws {
        // A teardown that already ran must not run its fallback again. `clear`
        // restores the recorded prior state and then forgets it, so a second
        // call finds `.notRecorded` — and the unconditional fallback would
        // blanket-disable the very settings the first call just restored. Both
        // hosts do call it twice: once on stop, once on quit.
        //
        // Only a journal that positively knows the surface is idle may skip;
        // an unreadable one answers `false` and we clear as before, because a
        // stranded proxy setting is worse than an unnecessary one.
        if let journal, journal.knowsSurfaceIsIdle(.systemProxy) {
            logger?.log(
                .debug,
                "System proxy teardown skipped: nothing recorded as applied.",
                category: .system
            )
            return
        }

        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()

        var script = ""
        var restored: [String] = []
        var reset: [String] = []

        for service in services {
            switch journal?.prior(surface: .systemProxy, scope: service) ?? .notRecorded {
            case .wasPresent(let prior):
                script += Self.restoreScript(service: service, prior: prior)
                restored.append(service)
            case .wasAbsent, .notRecorded:
                let s = service.shellQuoted
                script += "/usr/sbin/networksetup -setwebproxystate \(s) off 2>/dev/null || true\n"
                script += "/usr/sbin/networksetup -setsecurewebproxystate \(s) off 2>/dev/null || true\n"
                script += "/usr/sbin/networksetup -setautoproxystate \(s) off 2>/dev/null || true\n"
                reset.append(service)
            }
        }

        guard !script.isEmpty else { return }

        let result = try runUnprivileged(script)
        var restoreSucceeded = result.exitCode == 0
        if result.exitCode != 0 {
            let output = [result.standardError, result.standardOutput].filter { !$0.isEmpty }.joined(separator: " | ")
            if output.contains("requires admin") || result.exitCode == 14 {
                // The helper contract has no "restore arbitrary proxy state"
                // operation and adding one is a versioned-surface change
                // (AGENTS.md). Degrade to the clear it does have rather than
                // leaving the settings in place.
                if !restored.isEmpty {
                    logger?.log(
                        .warning,
                        "Could not restore the previous proxy settings without admin rights; disabling proxies on \(restored.count) service(s) instead.",
                        category: .system
                    )
                }
                for service in services {
                    try? privilegeClient.execute(.clearSystemProxy, values: [service])
                }
                restoreSucceeded = false
            }
        }

        // Only forget once the prior value is actually back on the machine. A
        // record dropped after a failed restore is a setting we changed with
        // nothing left saying so.
        //
        // The whole surface goes, not just the services we just handled. A
        // service can vanish between apply and clear — a VPN interface, an
        // unplugged adapter — and forgetting only what is currently present
        // would leave its record behind for good. Worse, if it came back in a
        // later session, first-write-wins would keep that stale record in
        // preference to capturing the state the service actually has now.
        // Teardown means done: nothing about this surface is ours any more.
        if restoreSucceeded {
            journal?.forgetAll(surface: .systemProxy)
        }

        if restored.isEmpty {
            logger?.log(.notice, "Cleared macOS proxy settings.", category: .system)
        } else {
            logger?.log(
                .notice,
                "Restored the previous macOS proxy settings on \(restored.count) service(s); cleared \(reset.count) with no recorded prior state.",
                category: .system
            )
        }
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

    /// Single reader for `-getautoproxyurl`. It used to be parsed twice, by
    /// `readAutoproxyEnabled` and `autoproxyMatches`, each shelling out
    /// separately and pulling one field out of the same output.
    private func readAutoproxy(service: String) -> (enabled: Bool, url: String) {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getautoproxyurl", service]),
              result.exitCode == 0 else { return (false, "") }

        var url = ""
        var enabled = false
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("URL:") {
                url = String(trimmed.dropFirst("URL:".count).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.dropFirst("Enabled:".count).trimmingCharacters(in: .whitespacesAndNewlines) == "Yes"
            }
        }
        return (enabled, url)
    }

    private func readAutoproxyEnabled(service: String) -> Bool {
        readAutoproxy(service: service).enabled
    }

    private func autoproxyMatches(service: String, url: String) -> Bool {
        let current = readAutoproxy(service: service)
        return current.enabled && current.url == url
    }

    // MARK: - Prior-state capture and restore

    /// Everything about a service's proxy configuration that `apply` overwrites.
    ///
    /// Captured whether or not anything is currently *enabled*: `networksetup`
    /// keeps a host and port on a disabled proxy, and manual mode also replaces
    /// the bypass-domain list. Recording only the enabled endpoints would leave
    /// Conduit's host, port and bypass list sitting in the user's disabled
    /// fields for good, which restore is supposed to undo.
    private func capturePriorState(service: String) -> [String: String] {
        let web = readProxyState(service: service, type: "webproxy")
        let secure = readProxyState(service: service, type: "securewebproxy")
        let auto = readAutoproxy(service: service)

        return [
            "webEnabled": String(web.enabled),
            "webHost": web.host,
            "webPort": web.port,
            "secureEnabled": String(secure.enabled),
            "secureHost": secure.host,
            "securePort": secure.port,
            "autoEnabled": String(auto.enabled),
            "autoURL": auto.url,
            "bypassDomains": readBypassDomains(service: service).joined(separator: ","),
        ]
    }

    /// Bypass domains currently configured for a service. `apply` overwrites
    /// these in manual mode via `-setproxybypassdomains`.
    private func readBypassDomains(service: String) -> [String] {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getproxybypassdomains", service]),
              result.exitCode == 0 else { return [] }
        return result.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("There aren't any") }
    }

    /// Rebuilds the `networksetup` calls that put `prior` back on `service`.
    private static func restoreScript(service: String, prior: [String: String]) -> String {
        let s = service.shellQuoted
        var script = ""

        if prior["autoEnabled"] == "true", let url = prior["autoURL"], !url.isEmpty {
            script += "/usr/sbin/networksetup -setautoproxyurl \(s) \(url.shellQuoted)\n"
            script += "/usr/sbin/networksetup -setautoproxystate \(s) on\n"
        } else {
            script += "/usr/sbin/networksetup -setautoproxystate \(s) off 2>/dev/null || true\n"
        }

        for (key, setter, stateSetter) in [
            ("web", "-setwebproxy", "-setwebproxystate"),
            ("secure", "-setsecurewebproxy", "-setsecurewebproxystate"),
        ] {
            let enabled = prior["\(key)Enabled"] == "true"
            let host = prior["\(key)Host"] ?? ""
            let port = prior["\(key)Port"] ?? ""
            // Put the endpoint back even when it was disabled: networksetup
            // retains host/port on a disabled proxy, and leaving ours there
            // would quietly hand the user our address if they re-enable it.
            if !host.isEmpty, !port.isEmpty {
                script += "/usr/sbin/networksetup \(setter) \(s) \(host.shellQuoted) \(port.shellQuoted)\n"
            }
            script += "/usr/sbin/networksetup \(stateSetter) \(s) \(enabled ? "on" : "off") 2>/dev/null || true\n"
        }

        // "Empty" is networksetup's own spelling for clearing the list.
        let bypass = (prior["bypassDomains"] ?? "").split(separator: ",").map(String.init)
        let bypassArgument = bypass.isEmpty ? "Empty" : bypass.map(\.shellQuoted).joined(separator: " ")
        script += "/usr/sbin/networksetup -setproxybypassdomains \(s) \(bypassArgument)\n"

        return script
    }
}
