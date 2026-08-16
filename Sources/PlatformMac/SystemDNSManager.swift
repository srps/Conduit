// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package final class SystemDNSManager: @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    /// Prior per-service DNS servers. Shared with every other platform surface
    /// so there is one answer to "what was here before us" rather than the
    /// bespoke snapshot this manager used to keep for itself.
    private let journal: PlatformStateJournal

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        journal: PlatformStateJournal
    ) {
        self.privilegeClient = privilegeClient
        self.journal = journal
    }

    // MARK: - Saved state

    /// Per-service DNS servers as they were before the relay was pointed at
    /// 127.0.0.1. Read straight from the journal — there is no second model.
    private func savedInterfaces() -> [String: [String]] {
        var interfaces: [String: [String]] = [:]
        for record in journal.records(for: .systemDNS) {
            let servers = record.priorValue?["servers"] ?? ""
            interfaces[record.scope] = servers.isEmpty
                ? []
                : servers.split(separator: ",").map(String.init)
        }
        return interfaces
    }

    /// Whether the journal holds anything for this surface — either captured
    /// servers or the applied marker that says we ran with nothing to capture.
    private func hasSavedInterfaces() -> Bool {
        journal.isMarkedApplied(surface: .systemDNS) || journal.hasRecords(for: .systemDNS)
    }

    // MARK: - Apply / Clear

    package func apply(forwarderPort: Int, logger: (any LogSink)?) throws {
        let services = try connectedNetworkServices(logger: logger)
        guard !services.isEmpty else { return }

        try startRelay(forwarderPort: forwarderPort, logger: logger)

        for service in services {
            try privilegeClient.execute(.setDNSServers, values: [service, "127.0.0.1"])
        }

        logger?.log(.notice, "Set system DNS to 127.0.0.1 via relay :53 -> :\(forwarderPort) on \(services.count) interface(s).", category: .system)
    }

    package func clear(logger: (any LogSink)?) throws {
        guard hasSavedInterfaces() else {
            // An empty journal used to mean "reset every connected service to
            // DHCP", which erases resolvers the app may never have touched —
            // the mirror image of the system-proxy surface, where the same
            // state meant "do nothing". Ask the machine instead: reset only
            // what still points at our own forwarder.
            if loopbackResidueExists() {
                logger?.log(
                    .notice,
                    "No saved DNS state, but some interfaces still point at 127.0.0.1 — resetting those to DHCP defaults.",
                    category: .system
                )
                resetToDefaults(logger: logger)
            } else {
                // Still stop the relay: it is ours whether or not any interface
                // is pointed at it.
                stopRelay(logger: logger)
                logger?.log(
                    .debug,
                    "System DNS teardown skipped: nothing recorded and no interface points at the local forwarder.",
                    category: .system
                )
            }
            return
        }

        let savedInterfaces = savedInterfaces()
        guard !savedInterfaces.isEmpty else {
            // Applied, but there was nothing to capture: no DNS servers to put
            // back. The relay still has to go — this was the one teardown path
            // that left it running.
            stopRelay(logger: logger)
            deleteSavedState()
            return
        }

        stopRelay(logger: logger)

        let currentServices = Set((try? connectedNetworkServices(logger: nil)) ?? [])
        var restored = 0
        var skipped = 0
        var lastError: Error?

        for (service, servers) in savedInterfaces {
            guard currentServices.contains(service) else {
                skipped += 1
                logger?.log(.debug, "Skipping DNS restore for vanished interface: \(service)", category: .system)
                continue
            }
            do {
                if servers.isEmpty {
                    try privilegeClient.execute(.setDNSServers, values: [service, "empty"])
                } else {
                    try privilegeClient.execute(.setDNSServers, values: [service] + servers)
                }
                restored += 1
            } catch {
                lastError = error
                logger?.log(.warning, "Failed to restore DNS for \(service): \(error.localizedDescription)", category: .system)
            }
        }

        // Only drop the records once every interface we could reach is back.
        // Forgetting after a partial failure destroys the only copy of the
        // remaining interfaces' real servers while leaving them pinned at
        // 127.0.0.1 — the rule the proxy and launchd surfaces already follow.
        if lastError == nil {
            deleteSavedState()
        } else {
            logger?.log(
                .warning,
                "Restored system DNS for \(restored) interface(s) but some failed; keeping the recorded servers so a later teardown can retry.",
                category: .system
            )
        }
        logger?.log(.notice, "Restored system DNS for \(restored) interface(s)\(skipped > 0 ? ", skipped \(skipped) vanished" : "").", category: .system)

        if let lastError, restored == 0 {
            throw lastError
        }
    }

    // MARK: - Save / Restore

    package func saveCurrentDNS(logger: (any LogSink)?) throws {
        let services = try connectedNetworkServices(logger: logger)
        for service in services {
            let servers = readDNSServers(service: service)
            // First-write-wins in the journal: a second `saveCurrentDNS` in the
            // same session reads 127.0.0.1 (our own relay) as the current
            // value, and recording that would make restore a no-op.
            journal.recordPrior(
                surface: .systemDNS,
                scope: service,
                value: ["servers": servers.joined(separator: ",")]
            )
        }
        // Mark even when there were no services: teardown must be able to tell
        // "nothing to restore" from "we do not know what we changed".
        journal.markApplied(surface: .systemDNS)
        logger?.log(.debug, "Saved current DNS state for \(services.count) interface(s).", category: .system)
    }

    package func restoreIfNeeded(logger: (any LogSink)?) {
        guard hasSavedInterfaces(), let savedAt = journal.oldestRecordDate(for: .systemDNS) else { return }

        let stalenessThreshold: TimeInterval = 7 * 24 * 3600
        let isStale = Date().timeIntervalSince(savedAt) > stalenessThreshold

        if isStale {
            logger?.log(.warning, "DNS saved state is older than 7 days. Forcing restore.", category: .system)
            performRestore(logger: logger)
            return
        }

        let dnsIsRedirected = isApplied()

        if isPort53InUse() {
            if dnsIsRedirected {
                logger?.log(.debug, "DNS saved state exists, port 53 active, DNS is 127.0.0.1 — relay likely still running.", category: .system)
            } else {
                logger?.log(.notice, "DNS saved state exists but DNS is no longer 127.0.0.1. Cleaning up stale state.", category: .system)
                deleteSavedState()
            }
            return
        }

        logger?.log(.warning, "Found orphaned DNS saved state (likely crashed). Restoring original DNS...", category: .system)
        performRestore(logger: logger)
    }

    private func performRestore(logger: (any LogSink)?) {
        do {
            try clear(logger: logger)
        } catch {
            logger?.log(.error, "Failed to restore DNS after crash: \(error.localizedDescription)", category: .system)
        }
    }

    // MARK: - State Detection

    package func isApplied() -> Bool {
        guard let services = try? connectedNetworkServices(logger: nil), !services.isEmpty else { return false }
        return services.allSatisfy { service in
            let servers = readDNSServers(service: service)
            return servers == ["127.0.0.1"]
        }
    }

    /// Whether any connected service still points at our local forwarder.
    ///
    /// Deliberately *any*, not `isApplied()`'s *all*: a single interface left
    /// on 127.0.0.1 after a crash is exactly the residue worth cleaning, and
    /// requiring every service to match would step straight past it.
    private func loopbackResidueExists() -> Bool {
        guard let services = try? connectedNetworkServices(logger: nil) else { return false }
        return services.contains { readDNSServers(service: $0) == ["127.0.0.1"] }
    }

    package func hasSavedState() -> Bool {
        hasSavedInterfaces()
    }

    // MARK: - Private

    private func deleteSavedState() {
        journal.forgetAll(surface: .systemDNS)
    }

    private func resetToDefaults(logger: (any LogSink)?) {
        stopRelay(logger: logger)
        guard let services = try? connectedNetworkServices(logger: nil) else { return }
        for service in services {
            try? privilegeClient.execute(.setDNSServers, values: [service, "empty"])
        }
        deleteSavedState()
        logger?.log(.notice, "Reset system DNS to DHCP defaults.", category: .system)
    }

    // MARK: - DNS relay via helper

    package func startRelay(forwarderPort: Int, logger: (any LogSink)?) throws {
        do {
            try privilegeClient.execute(.startDNSRelay, values: [String(forwarderPort)])
            logger?.log(.notice, "DNS relay started on :53 -> :\(forwarderPort) via helper.", category: .system)
        } catch {
            logger?.log(.warning, "Failed to start DNS relay via helper: \(error.displayDescription)", category: .system)
            throw error
        }
    }

    package func stopRelay(logger: (any LogSink)?) {
        try? privilegeClient.execute(.stopDNSRelay, values: [])
        logger?.log(.notice, "DNS relay on :53 stopped.", category: .system)
    }

    package func readDNSServers(service: String) -> [String] {
        guard let result = try? CommandRunner.run(
            launchPath: "/usr/sbin/networksetup",
            arguments: ["-getdnsservers", service]
        ), result.exitCode == 0 else { return [] }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("any DNS Servers set") || output.isEmpty {
            return []
        }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    package func connectedNetworkServices(logger: (any LogSink)? = nil) throws -> [String] {
        let result = try CommandRunner.run(
            launchPath: "/usr/sbin/networksetup",
            arguments: ["-listallnetworkservices"]
        )
        let all = result.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return false }
                if trimmed.hasPrefix("An asterisk") { return false }
                if trimmed.hasPrefix("*") { return false }
                return true
            }

        var connected: [String] = []
        for service in all {
            if hasIPAddress(service: service) {
                connected.append(service)
            }
        }
        if connected.isEmpty {
            return all
        }
        return connected
    }

    private func hasIPAddress(service: String) -> Bool {
        guard let result = try? CommandRunner.run(
            launchPath: "/usr/sbin/networksetup",
            arguments: ["-getinfo", service]
        ), result.exitCode == 0 else { return false }

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

    // MARK: - Reconcile (VPN transitions)

    package func reconcile(logger: (any LogSink)?) {
        guard hasSavedInterfaces() else { return }
        guard let currentServices = try? connectedNetworkServices(logger: nil) else { return }

        let currentSet = Set(currentServices)
        let savedSet = Set(savedInterfaces().keys)

        let newInterfaces = currentSet.subtracting(savedSet)
        let goneInterfaces = savedSet.subtracting(currentSet)

        // Re-pin drifted interfaces we already manage. VPN clients (Cisco
        // Secure Client in particular) rewrite service DNS when the tunnel
        // re-establishes after sleep or a flap, silently replacing our
        // 127.0.0.1 override. The saved entry keeps the ORIGINAL pre-override
        // servers — deliberately not updated here, so disable/quit still
        // restores what the user had before Conduit touched anything.
        for iface in savedSet.intersection(currentSet) {
            let servers = readDNSServers(service: iface)
            guard servers != ["127.0.0.1"] else { continue }
            try? privilegeClient.execute(.setDNSServers, values: [iface, "127.0.0.1"])
            logger?.log(
                .notice,
                "DNS reconcile: re-pinned \(iface) to 127.0.0.1 (was rewritten to: \(servers.isEmpty ? "DHCP default" : servers.joined(separator: ", "))).",
                category: .system
            )
        }

        if newInterfaces.isEmpty && goneInterfaces.isEmpty { return }

        for iface in newInterfaces {
            let servers = readDNSServers(service: iface)
            if servers == ["127.0.0.1"] { continue }
            journal.recordPrior(
                surface: .systemDNS,
                scope: iface,
                value: ["servers": servers.joined(separator: ",")]
            )
            try? privilegeClient.execute(.setDNSServers, values: [iface, "127.0.0.1"])
            logger?.log(.notice, "DNS reconcile: redirected new interface \(iface) to 127.0.0.1.", category: .system)
        }

        for iface in goneInterfaces {
            journal.forget(surface: .systemDNS, scope: iface)
            logger?.log(.debug, "DNS reconcile: removed vanished interface \(iface) from saved state.", category: .system)
        }

        // Refresh liveness only: a session that keeps reconciling is not the
        // orphaned residue `restoreIfNeeded` looks for. Interfaces we already
        // manage keep their recorded values untouched on purpose (see the
        // re-pin loop above) — by now the machine reports our own 127.0.0.1
        // override, and re-recording that would make restore put our override
        // back instead of the user's resolvers.
        journal.touch(surface: .systemDNS)
    }

    // MARK: - Liveness probe

    package func probeLiveness(port: Int = 53) -> Bool {
        let query = DNSWireFormat.buildQuery(domain: "one.one.one.one", txID: 0xFACE)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sent = query.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(fd, buf.baseAddress, buf.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return false }

        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 2000)
        guard ready > 0, pollFD.revents & Int16(POLLIN) != 0 else { return false }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        return n >= 12
    }

    // MARK: - Internal helpers

    /// First existing absolute path for `lsof`, or `nil` if the tool is gone —
    /// in which case the caller treats the port as free, which is the same
    /// answer the broken hardcoded path gave, but now a deliberate one.
    private static let lsofPath: String? = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func isPort53InUse() -> Bool {
        // The path is resolved, not hardcoded: `lsof` moved to `/usr/sbin` on
        // macOS 26 and this probe named `/usr/bin/lsof`, so it threw and
        // answered "port free" on every modern machine — which made
        // `restoreIfNeeded` treat a *running* relay's saved state as orphaned
        // and force a restore at launch.
        //
        // Candidates are absolute and known-good rather than a `PATH` lookup:
        // resolving a tool from the inherited environment is how a process that
        // may elevate ends up running someone else's binary.
        //
        // Unlike the proxy surface, this one cannot be done with a socket. The
        // relay listens on port 53 as root; an unprivileged `bind` there fails
        // with `EACCES` whether or not anything holds it, and UDP has no
        // connect handshake to test instead.
        guard let lsof = Self.lsofPath else { return false }
        let result = try? CommandRunner.run(
            launchPath: lsof,
            arguments: ["-i", "UDP:53", "-P", "-n"]
        )
        return result?.exitCode == 0 && !(result?.standardOutput.isEmpty ?? true)
    }
}

