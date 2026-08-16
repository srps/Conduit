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
    /// it, so `clear` restores rather than blanket-disabling. Required, not
    /// optional: an absent journal used to silently restore the old erasing
    /// teardown. See `PlatformStateJournal` on why "unknown" must never mean
    /// "leave it".
    private let journal: PlatformStateJournal

    /// Whether a loopback port is being served. Injectable so `restoreIfNeeded`
    /// is testable without a real listener.
    private let portProbe: @Sendable (Int) -> Bool

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        journal: PlatformStateJournal,
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        },
        portProbe: @escaping @Sendable (Int) -> Bool = { LoopbackPortProbe.isServed(port: $0) }
    ) {
        self.privilegeClient = privilegeClient
        self.journal = journal
        self.commandRunner = commandRunner
        self.portProbe = portProbe
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
        for service in services {
            journal.recordPrior(
                surface: .systemProxy,
                scope: service,
                value: capturePriorState(service: service)
            )
        }
        journal.markApplied(surface: .systemProxy)

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
                    // No `2>/dev/null || true`: the suffix forces the script's
                    // exit code to 0 and discards the "requires admin" text,
                    // and the privileged fallback keys on both. It was removed
                    // from teardown for exactly that reason; leaving it on the
                    // apply path made a failure to switch manual proxies off
                    // before enabling the PAC silently survivable.
                    script += "/usr/sbin/networksetup -setwebproxystate \(s) off\n"
                    script += "/usr/sbin/networksetup -setsecurewebproxystate \(s) off\n"
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
        // ...but "the journal holds nothing" is two different situations. It is
        // "we never applied" on a clean install, and it is "we applied and lost
        // the record" after a failed journal write or a deleted state
        // directory. Only the machine can tell them apart, so ask it: if any
        // service is still actively routed at this host, the setting is ours
        // and stranded, whatever the journal says.
        if journal.knowsSurfaceIsIdle(.systemProxy) {
            // ...and "we hold nothing" is itself two situations. A teardown
            // that already completed put the user's own settings back, and
            // those may legitimately be a loopback proxy — someone running
            // their own local proxy, or a second tool. Probing for residue then
            // reads the user's restored setting as ours and the next teardown
            // disables it, which is the double-teardown erase in a different
            // costume. Only a surface we never released gets probed.
            if journal.ownership(of: .systemProxy) == .released {
                logger?.log(
                    .debug,
                    "System proxy teardown skipped: a previous teardown already restored this surface.",
                    category: .system
                )
                return
            }
            if !loopbackResidueExists() {
                logger?.log(
                    .debug,
                    "System proxy teardown skipped: nothing recorded as applied and no local-proxy settings on any service.",
                    category: .system
                )
                return
            }
        }

        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()
        guard !services.isEmpty else { return }

        var restored: [String] = []
        var reset: [String] = []
        var failed: [String] = []

        // One unit of work per service, not one script for all of them.
        // Concatenating every service's commands into a single `/bin/sh -c`
        // made the whole teardown's success ride on the *last* command's exit
        // code — `sh` reports only that one — so a service that failed
        // partway through was invisible as long as the final command
        // succeeded, and `forgetAll` then destroyed the records for every
        // service including the one that had not been restored.
        for service in services {
            let steps: [ProxyWriteStep]
            let isRestore: Bool
            switch journal.prior(surface: .systemProxy, scope: service) {
            case .wasPresent(let prior):
                steps = ProxyServiceState(journalValues: prior).writeSteps
                isRestore = true
            case .wasAbsent, .notRecorded:
                steps = ProxyServiceState.disabledEverything()
                isRestore = false
            }

            if write(steps: steps, service: service, logger: logger) {
                if isRestore { restored.append(service) } else { reset.append(service) }
            } else {
                failed.append(service)
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
        guard failed.isEmpty else {
            logger?.log(
                .warning,
                "Could not fully apply the macOS proxy teardown on \(failed.count) of \(services.count) service(s); the recorded previous settings are kept so a later teardown can retry.",
                category: .system
            )
            return
        }

        journal.forgetAll(surface: .systemProxy)
        journal.markReleased(surface: .systemProxy)

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

    /// Puts one service into the state `steps` describe, unprivileged if it
    /// can and via the privileged helper if it must. Returns whether the whole
    /// sequence landed.
    ///
    /// The privileged half is no longer a degradation. It used to be
    /// `clearSystemProxy` per service — the only proxy-writing operation the
    /// helper contract had that teardown could use — which meant that on any
    /// machine where the user cannot write proxy settings without admin rights
    /// the recorded prior state was kept and never applied: the feature bought
    /// "nothing is lost permanently" rather than "your settings come back".
    /// The same steps now render to typed privileged operations, so both paths
    /// reach the same end state.
    private func write(steps: [ProxyWriteStep], service: String, logger: (any LogSink)?) -> Bool {
        // `set -e`, because `sh -c` otherwise reports only the *last* command's
        // status. Without it a restore whose endpoint write failed but whose
        // trailing bypass write succeeded reported success, and the records —
        // the only copy of the user's real settings — were then dropped. Every
        // write here is an absolute set, so aborting early and re-running the
        // whole sequence through the privileged path is safe.
        let script = "set -e\n" + steps.shellScript(service: service)
        let result: CommandResult
        do {
            result = try runUnprivileged(script)
        } catch {
            logger?.log(
                .warning,
                "Could not run the proxy teardown for \(service): \(error.displayDescription)",
                category: .system
            )
            return false
        }

        if result.exitCode == 0 { return true }

        let output = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard Self.requiresAdmin(exitCode: result.exitCode, output: output) else {
            // Every other failure used to fall through reporting nothing, after
            // which the closing notice still announced a successful restore.
            // `apply` throws on this same branch; the asymmetry made a user's
            // "it said it restored my proxy" impossible to falsify.
            logger?.log(
                .warning,
                "networksetup failed during teardown of \(service) (exit \(result.exitCode)): \(output.isEmpty ? "no output" : output). Recorded settings are kept for the next attempt.",
                category: .system
            )
            return false
        }

        do {
            // One batch, so a machine with no helper installed pays a single
            // admin prompt per service rather than one per write.
            try privilegeClient.execute(batch: steps.privilegedBatch(service: service))
            logger?.log(
                .debug,
                "Applied the proxy teardown for \(service) through the privileged helper.",
                category: .system
            )
            return true
        } catch {
            logger?.log(
                .error,
                "Could not restore the proxy settings on \(service) with admin rights (\(error.displayDescription)); the system may still point at a proxy that is not running.",
                category: .system
            )
            return false
        }
    }

    /// `networksetup` refuses unprivileged writes with exit 14 and a
    /// `requires admin` message. Both are checked because neither is a
    /// documented contract.
    private static func requiresAdmin(exitCode: Int32, output: String) -> Bool {
        output.contains("requires admin") || exitCode == 14
    }

    // MARK: - Crash recovery

    /// Restores the recorded prior proxy settings at launch when the run that
    /// recorded them never got to tear down.
    ///
    /// Teardown is not enough on its own. A `SIGKILL`, a panic, or a forced
    /// logout leaves the machine pointing at a proxy port nothing serves and
    /// the journal holding the only copy of what was there before — and launch
    /// is the moment that copy is most likely still the truth. This mirrors
    /// `SystemDNSManager.restoreIfNeeded`, which has covered the DNS surface
    /// the same way for the same reason.
    package func restoreIfNeeded(logger: (any LogSink)?) {
        guard journal.isMarkedApplied(surface: .systemProxy)
                || journal.hasRecords(for: .systemProxy),
              let appliedAt = journal.oldestRecordDate(for: .systemProxy) else { return }

        let stalenessThreshold: TimeInterval = 7 * 24 * 3600
        if Date().timeIntervalSince(appliedAt) > stalenessThreshold {
            logger?.log(
                .warning,
                "Recorded system proxy state is older than 7 days. Restoring the previous settings.",
                category: .system
            )
            performRestore(logger: logger)
            return
        }

        // A live listener on the port the machine is pointed at means another
        // instance is serving it, and taking its settings away would break
        // every client on the machine. Absent one, the settings are orphaned.
        if localProxyListenerExists() {
            logger?.log(
                .debug,
                "Recorded system proxy state exists and a local proxy is still listening; leaving it alone.",
                category: .system
            )
            return
        }

        logger?.log(
            .warning,
            "Found system proxy settings recorded by a run that never tore down (likely a crash). Restoring the previous settings...",
            category: .system
        )
        performRestore(logger: logger)
    }

    private func performRestore(logger: (any LogSink)?) {
        do {
            try clear(logger: logger)
        } catch {
            logger?.log(
                .error,
                "Failed to restore the system proxy after a crash: \(error.displayDescription)",
                category: .system
            )
        }
    }

    /// Whether something is listening on the loopback port the machine's proxy
    /// settings currently point at.
    private func localProxyListenerExists() -> Bool {
        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()
        var ports = Set<String>()
        for service in services {
            for type in ["webproxy", "securewebproxy"] {
                let state = readProxyState(service: service, type: type)
                if state.enabled, Self.isLoopbackHost(state.host), !state.port.isEmpty {
                    ports.insert(state.port)
                }
            }
            let auto = readAutoproxy(service: service)
            if auto.enabled,
               let url = URL(string: auto.url),
               Self.isLoopbackHost(url.host ?? ""),
               let port = url.port {
                ports.insert(String(port))
            }
        }
        return ports.contains { isListening(onPort: $0) }
    }

    private func isListening(onPort port: String) -> Bool {
        guard let port = Int(port) else { return false }
        return portProbe(port)
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

        return ProxyServiceState(
            webHost: web.host,
            webPort: web.port,
            webEnabled: web.enabled,
            secureHost: secure.host,
            securePort: secure.port,
            secureEnabled: secure.enabled,
            autoURL: auto.url,
            autoEnabled: auto.enabled,
            bypassDomains: readBypassDomains(service: service)
        ).journalValues
    }

    /// Whether any service is still actively routed at this machine — the
    /// fingerprint Conduit leaves behind.
    ///
    /// Deliberately a residue check rather than `isApplied(config:mode:)`: a
    /// stale local PAC URL from a crashed run carries a different port than the
    /// current config, so an exact match would miss exactly the case this is
    /// for. Equally deliberately not `isCleared()` — after a successful restore
    /// the machine legitimately holds the user's own proxy, and treating that
    /// as "not idle" would re-introduce the double-teardown erase.
    ///
    /// Only *enabled* settings count. A disabled entry routes nothing, and
    /// blanket-disabling on its account would be pure over-reach.
    private func loopbackResidueExists() -> Bool {
        let services = (try? connectedNetworkServices(logger: nil)) ?? allNetworkServices()
        return services.contains { service in
            let web = readProxyState(service: service, type: "webproxy")
            if web.enabled, Self.isLoopbackHost(web.host) { return true }
            let secure = readProxyState(service: service, type: "securewebproxy")
            if secure.enabled, Self.isLoopbackHost(secure.host) { return true }
            let auto = readAutoproxy(service: service)
            return auto.enabled && Self.isLoopbackHost(URL(string: auto.url)?.host ?? "")
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "localhost" || trimmed == "::1" || trimmed.hasPrefix("127.")
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

}
