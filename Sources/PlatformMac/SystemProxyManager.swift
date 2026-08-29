// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

enum SystemProxyManagerError: Error, LocalizedError {
    case noNetworkServices
    case priorStateUnreadable(services: [String])
    case commandFailed(String)

    package var errorDescription: String? {
        switch self {
        case .noNetworkServices:
            return "No active macOS network services were found."
        case .priorStateUnreadable(let services):
            return "Could not read the current proxy settings on \(services.joined(separator: ", ")); nothing was changed."
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

    /// Journal value recorded for a service `apply` did not touch because its
    /// state could not be read. Teardown skips such a service instead of
    /// clearing it. Prefixed with a control character like the applied
    /// marker's scope, so it can never collide with a real field.
    static let untouchedMarkerKey = "\u{0}untouched"

    package func apply(config: ProxyConfig, mode: SystemProxyMode, logger: (any LogSink)?, localPACURL: String? = nil) throws {
        let candidates = try connectedNetworkServices(logger: logger)
        guard !candidates.isEmpty else {
            throw SystemProxyManagerError.noNetworkServices
        }

        // Capture before overwriting. `recordPrior` is first-write-wins, so
        // the repeat applies a session performs (config reload, restart, VPN
        // transition) cannot replace the user's original setting with ours.
        //
        // That guard only covers a single session. Across sessions the machine
        // itself is the input, and it can already be carrying our leftovers: a
        // teardown that only switched autoproxy *off* leaves our URL in the
        // field, and the next cold start reads it as the user's own setting.
        // Observed in the wild — a journal recording
        // `http://127.0.0.1:<localPACPort>/proxy.pac` as the value to restore,
        // with the corporate PAC URL it had replaced gone for good. So
        // anything pointing at our own local listener is discarded at capture.
        let ours = LocalListenerFingerprint(config: config)
        var services: [String] = []
        for service in candidates {
            guard let prior = capturePriorState(service: service, ours: ours) else {
                // Nothing written to a service we cannot read — and the
                // journal says so. Without the marker, teardown would find a
                // connected service with no record and clear it, which is the
                // erase this guard exists to prevent.
                journal.recordPrior(surface: .systemProxy, scope: service, value: [Self.untouchedMarkerKey: "unreadable"])
                logger?.log(
                    .warning,
                    "Could not read the current proxy settings on \(service); leaving that service untouched.",
                    category: .system
                )
                continue
            }
            journal.recordPrior(surface: .systemProxy, scope: service, value: prior)
            services.append(service)
        }
        guard !services.isEmpty else {
            // Nothing applied at all: the markers have nothing to guard.
            for service in candidates {
                journal.forget(surface: .systemProxy, scope: service)
            }
            throw SystemProxyManagerError.priorStateUnreadable(services: candidates)
        }
        journal.markApplied(surface: .systemProxy)

        let pacURL = Self.effectivePACURL(config: config, localPACURL: localPACURL)
        var script = ""
        for service in services {
            let s = service.shellQuoted
            let h = config.localHost.shellQuoted
            let p = String(config.localPort)
            // Through the shared renderer, which spells an empty list `Empty`.
            // Interpolating the joined list directly emitted a bare
            // `-setproxybypassdomains <service>` with no domains when the user
            // had cleared their bypass list — `networksetup` answers that with
            // its usage text and a non-zero exit, and `apply` then threw
            // instead of turning the proxy on.
            let bypassCommands = ProxyWriteStep.bypass(config.noProxyHosts).shellCommands(service: service)

            switch mode {
            case .manual:
                script += "/usr/sbin/networksetup -setautoproxystate \(s) off\n"
                script += "/usr/sbin/networksetup -setwebproxy \(s) \(h) \(p)\n"
                script += "/usr/sbin/networksetup -setsecurewebproxy \(s) \(h) \(p)\n"
                script += bypassCommands.joined(separator: "\n") + "\n"
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

        // Connected services get the unconditional treatment (residue with no
        // record is still cleared). A recorded service that is merely
        // disconnected — a VPN link down, an adapter unplugged — is still
        // listed, and `networksetup` writes to it regardless, so it is
        // restored now rather than left pointing at a dead proxy for when it
        // comes back. Only a service that no longer exists is skipped, and
        // its record goes with the surface below.
        //
        // "Listed" includes disabled services (the starred entries): they take
        // writes too, and a disabled service is the one most likely to be
        // re-enabled later with our settings still on it.
        let listed = try? listNetworkServices(includingDisabled: true)
        let connected = (try? connectedNetworkServices(logger: nil)) ?? listed ?? []
        let recorded = Set(journal.scopes(for: .systemProxy))
        var services = connected
        for service in listed ?? [] where recorded.contains(service) && !services.contains(service) {
            services.append(service)
        }
        guard !services.isEmpty else { return }
        // Without a listing we cannot tell "gone for good" from "not
        // enumerated this time", so records we did not restore are kept.
        let canForgetUnhandled = listed != nil

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
        var untouched: [String] = []
        for service in services {
            let steps: [ProxyWriteStep]
            let isRestore: Bool
            switch journal.prior(surface: .systemProxy, scope: service) {
            case .wasPresent(let prior) where prior[Self.untouchedMarkerKey] != nil:
                // apply never wrote here; there is nothing of ours to remove.
                untouched.append(service)
                continue
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

        if canForgetUnhandled {
            journal.forgetAll(surface: .systemProxy)
            journal.markReleased(surface: .systemProxy)
        } else {
            for service in restored + reset + untouched {
                journal.forget(surface: .systemProxy, scope: service)
            }
            let outstanding = journal.scopes(for: .systemProxy)
            if outstanding.isEmpty {
                journal.markReleased(surface: .systemProxy)
            } else {
                logger?.log(
                    .warning,
                    "Could not list network services during the proxy teardown; keeping the recorded settings for \(outstanding.count) service(s) so a later teardown can restore them.",
                    category: .system
                )
            }
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
                // Rendered rather than assembled inline: `setProxyBypass` needs
                // the `Empty` sentinel for a list with no domains, and a caller
                // that hand-built `[service] + noProxyHosts` sent a single
                // value instead — which the contract rejects, so a user who had
                // cleared their bypass list could not turn the proxy on at all
                // on an admin-required machine. `ProxyWriteStep` already knows
                // that spelling; teardown has been using it all along.
                try privilegeClient.execute(batch: [ProxyWriteStep.bypass(config.noProxyHosts).privilegedStep(service: service)])
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

    /// `includingDisabled` keeps the starred entries (with the asterisk
    /// stripped): services `networksetup` still holds settings for and still
    /// writes to, just not routing right now.
    private func listNetworkServices(includingDisabled: Bool = false) throws -> [String] {
        let result = try commandRunner("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard result.exitCode == 0 else {
            throw SystemProxyManagerError.commandFailed("networksetup -listallnetworkservices failed (exit \(result.exitCode))")
        }
        return result.standardOutput
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line in
                if line.isEmpty || line.hasPrefix("An asterisk") { return nil }
                if line.hasPrefix("*") {
                    return includingDisabled ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : nil
                }
                return line
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
        readProxyStateStrict(service: service, type: type) ?? ProxyState()
    }

    /// `nil` when the read itself failed — as opposed to "read fine, proxy
    /// off". Capture must tell the two apart: recording defaults for a
    /// service whose state could not be read turns teardown into an erase.
    private func readProxyStateStrict(service: String, type: String) -> ProxyState? {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-get\(type)", service]),
              result.exitCode == 0 else { return nil }

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
        readAutoproxyStrict(service: service) ?? (false, "")
    }

    private func readAutoproxyStrict(service: String) -> (enabled: Bool, url: String)? {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getautoproxyurl", service]),
              result.exitCode == 0 else { return nil }

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
    /// `nil` unless every field `apply` is about to overwrite — both proxies,
    /// the PAC URL and the bypass list — was read successfully. A read that
    /// failed used to become the empty default, which teardown then "restored"
    /// by erasing whatever the user had.
    private func capturePriorState(service: String, ours: LocalListenerFingerprint) -> [String: String]? {
        guard var web = readProxyStateStrict(service: service, type: "webproxy"),
              var secure = readProxyStateStrict(service: service, type: "securewebproxy"),
              var auto = readAutoproxyStrict(service: service),
              let bypassDomains = readBypassDomainsStrict(service: service) else {
            return nil
        }

        // A setting that points at our own listener is residue, not a prior.
        // Recording it would make teardown "restore" a dead local port and
        // would overwrite the last copy of what the user actually had.
        if ours.matchesEndpoint(host: web.host, port: web.port) {
            web = ProxyState()
        }
        if ours.matchesEndpoint(host: secure.host, port: secure.port) {
            secure = ProxyState()
        }
        if ours.matchesPACURL(auto.url) {
            auto = (enabled: false, url: "")
        }

        return ProxyServiceState(
            webHost: web.host,
            webPort: web.port,
            webEnabled: web.enabled,
            secureHost: secure.host,
            securePort: secure.port,
            secureEnabled: secure.enabled,
            autoURL: auto.url,
            autoEnabled: auto.enabled,
            bypassDomains: bypassDomains
        ).journalValues
    }

    /// Identifies settings that point at Conduit's own local listeners.
    ///
    /// Deliberately *not* "does this equal the value we are about to write".
    /// That test looks equivalent and is not: with `localPACEnabled` off,
    /// `apply` writes the user's own configured PAC URL to the system, so
    /// matching on it would discard the very setting teardown exists to
    /// restore. Ownership is about the address, not about the write.
    ///
    /// Equally not "is this loopback" — someone running their own local proxy
    /// is entitled to have it restored.
    struct LocalListenerFingerprint {
        let host: String
        let port: String
        let pacPort: String

        init(config: ProxyConfig) {
            host = config.localHost
            port = String(config.localPort)
            pacPort = String(config.localPACPort)
        }

        func matchesEndpoint(host candidateHost: String, port candidatePort: String) -> Bool {
            candidateHost == host && candidatePort == port
        }

        /// Matched on the port *or* the path, because the local PAC port can
        /// change between sessions while the path cannot — and a stale URL on
        /// a port we no longer use is exactly the residue worth discarding.
        func matchesPACURL(_ url: String) -> Bool {
            guard !url.isEmpty, let parsed = URL(string: url) else { return false }
            guard SystemProxyManager.isLoopbackHost(parsed.host ?? "") else { return false }
            if let parsedPort = parsed.port, String(parsedPort) == pacPort { return true }
            return parsed.path == LocalPACServer.pacPath
        }
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
        readBypassDomainsStrict(service: service) ?? []
    }

    private func readBypassDomainsStrict(service: String) -> [String]? {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getproxybypassdomains", service]),
              result.exitCode == 0 else { return nil }
        return result.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("There aren't any") }
    }

}
