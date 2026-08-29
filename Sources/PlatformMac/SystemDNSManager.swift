// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package final class SystemDNSManager: @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    /// Prior per-service DNS servers. Shared with every other platform surface
    /// so there is one answer to "what was here before us" rather than the
    /// bespoke snapshot this manager used to keep for itself.
    private let journal: PlatformStateJournal

    /// How `networksetup` is read. Injectable for the same reason
    /// `SystemProxyManager` takes one: the launch-time recovery decision reads
    /// per-service DNS off the machine, and a test that cannot say what the
    /// machine holds cannot pin that decision.
    private let commandRunner: @Sendable (String, [String]) throws -> CommandResult

    /// Whether a local resolver is actually answering on the DNS port.
    /// Injectable so `restoreIfNeeded` is testable without a live relay,
    /// mirroring `SystemProxyManager`'s `portProbe`.
    private let relayIsLive: @Sendable () -> Bool
    /// 0.1.x snapshot, imported into the journal on first launch. See
    /// `PlatformStateJournal.importLegacyDNSSnapshot`. Comes from the same
    /// `RuntimeEnvironment` as the journal — never `userDefault()` — so an
    /// isolated state directory (`PM_CONFIG_DIR`, tests) cannot read or
    /// delete the real user's file.
    private let legacySnapshotFile: URL?

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        journal: PlatformStateJournal,
        legacySnapshotFile: URL? = nil,
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult = { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        },
        relayIsLive: @escaping @Sendable () -> Bool = { SystemDNSManager.dnsResponds(onPort: 53) }
    ) {
        self.privilegeClient = privilegeClient
        self.journal = journal
        self.commandRunner = commandRunner
        self.relayIsLive = relayIsLive
        self.legacySnapshotFile = legacySnapshotFile
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
        // The daemon's first act is this save; without the import first it
        // would record a stranded 127.0.0.1 as the prior value and make the
        // snapshot unimportable for good.
        importLegacySnapshotIfPresent(logger: logger)
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

    private func importLegacySnapshotIfPresent(logger: (any LogSink)?) {
        if let legacySnapshotFile {
            journal.importLegacyDNSSnapshot(at: legacySnapshotFile, logger: logger)
        }
    }

    package func restoreIfNeeded(logger: (any LogSink)?) {
        importLegacySnapshotIfPresent(logger: logger)
        guard hasSavedInterfaces(), let savedAt = journal.oldestRecordDate(for: .systemDNS) else { return }

        let stalenessThreshold: TimeInterval = 7 * 24 * 3600
        let isStale = Date().timeIntervalSince(savedAt) > stalenessThreshold

        if isStale {
            logger?.log(.warning, "DNS saved state is older than 7 days. Forcing restore.", category: .system)
            performRestore(logger: logger)
            return
        }

        // "Is anything holding port 53?" was the wrong question, and repairing
        // the `lsof` path that made it always answer "no" is what exposed that.
        // The relay does not run in the app: it runs inside the privileged
        // LaunchDaemon, which is `KeepAlive` and outlives us. A `SIGKILL`
        // therefore leaves it listening on 53 and forwarding to a forwarder
        // port nothing serves any more — so the port is held in precisely the
        // crash this function exists to repair, and gating on "held" switched
        // launch-time recovery off at the moment it was needed.
        //
        // Liveness answers what is actually being asked. A resolver that still
        // answers belongs to a session serving this machine, and taking its DNS
        // away would break every client on it. One that answers nothing is
        // residue, whoever is holding the socket.
        if relayIsLive() {
            // Any interface, not `isApplied()`'s every interface. A machine
            // where only some services still point at 127.0.0.1 — a VPN
            // interface that came back with its own resolvers, a service added
            // since — reads as "not applied", and deleting on that basis throws
            // away the recorded servers for the interfaces that are still
            // pinned. That branch was unreachable while the probe always said
            // "port free"; it is not any more.
            if loopbackResidueExists() {
                logger?.log(
                    .debug,
                    "DNS saved state exists, a local resolver is answering on :53 and interfaces still point at it — a live session is serving this machine.",
                    category: .system
                )
            } else {
                logger?.log(.notice, "DNS saved state exists but no interface points at 127.0.0.1 any more. Cleaning up stale state.", category: .system)
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

    /// Whether any connected service still points at our local forwarder.
    ///
    /// Deliberately *any*. There used to be an all-interfaces `isApplied()`
    /// alongside this, and `restoreIfNeeded` reached for it before deleting
    /// saved state — so a machine where one interface had come back with its
    /// own resolvers read as "not applied" and the records for the interfaces
    /// still pinned at 127.0.0.1 went with it. It had no other caller, so it is
    /// gone rather than left as the obvious thing to reach for next time.
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
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getdnsservers", service]),
              result.exitCode == 0 else { return [] }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("any DNS Servers set") || output.isEmpty {
            return []
        }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    package func connectedNetworkServices(logger: (any LogSink)? = nil) throws -> [String] {
        let result = try commandRunner("/usr/sbin/networksetup", ["-listallnetworkservices"])
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
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getinfo", service]),
              result.exitCode == 0 else { return false }

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
        Self.dnsResponds(onPort: port)
    }

    /// Whether a resolver on `127.0.0.1:port` answers a query at all.
    ///
    /// Static because it is also the default for `relayIsLive`, which has to be
    /// supplied before `self` exists. The generous timeout is deliberate on
    /// that path: reading a live-but-slow relay as dead makes launch-time
    /// recovery tear the DNS out from under a session that is serving the
    /// machine, which is worse than the second it costs to be sure.
    static func dnsResponds(onPort port: Int, timeoutMilliseconds: Int32 = 2_000) -> Bool {
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
        let ready = poll(&pollFD, 1, timeoutMilliseconds)
        guard ready > 0, pollFD.revents & Int16(POLLIN) != 0 else { return false }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        return n >= 12
    }

}

