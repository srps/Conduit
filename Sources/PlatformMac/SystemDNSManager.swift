// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum SystemDNSManagerError: Error, LocalizedError, Equatable {
    case listingFailed(exitCode: Int32)
    /// `apply` was asked to redirect interfaces whose servers were never
    /// captured: `saveCurrentDNS` threw, or was not called.
    case priorStateNotCaptured

    package var errorDescription: String? {
        switch self {
        case .listingFailed(let exitCode):
            return "networksetup -listallnetworkservices failed (exit \(exitCode))"
        case .priorStateNotCaptured:
            return "the current DNS servers were not captured, so the interfaces were left alone"
        }
    }
}

package final class SystemDNSManager: @unchecked Sendable {
    /// Journal value for an interface whose servers could not be read at
    /// capture. `apply` and `reconcile` leave such an interface alone, and
    /// teardown skips it. Same shape as `SystemProxyManager.untouchedMarkerKey`.
    static let untouchedMarkerKey = "\u{0}untouched"
    private static let untouchedMarkerValue = [untouchedMarkerKey: "unreadable"]

    private func isUntouched(_ service: String) -> Bool {
        if case .wasPresent(let value) = journal.prior(surface: .systemDNS, scope: service) {
            return value[Self.untouchedMarkerKey] != nil
        }
        return false
    }

    /// One operation at a time. The manager keeps no state of its own, but
    /// each operation reads the journal and then acts on what it read, and
    /// the hosts now run `reconcile` and the relay restart off the main
    /// actor while the start and stop paths still call in from it. Without
    /// this a reconcile that read the journal before a stop's `clear` would
    /// pin an interface to 127.0.0.1 after the clear had restored it, with
    /// no record left to restore it from. Recursive because the operations
    /// call one another (`restoreIfNeeded` ends in `clear`).
    private let operations = NSRecursiveLock()

    /// Runs `body` as one operation, as the other managers' `serialized`: for
    /// a host's platform block that checks whether it has been superseded and
    /// then acts, with nothing landing in between.
    package func serialized<T>(_ body: () throws -> T) rethrows -> T {
        try operations.withLock(body)
    }

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
            if record.priorValue?[Self.untouchedMarkerKey] != nil { continue }
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
        operations.lock()
        defer { operations.unlock() }
        // Nothing captured, nothing redirected. Every host calls
        // `saveCurrentDNS` first and treats its failure as non-fatal, so
        // without this guard a listing that failed once left the interfaces
        // pointed at the relay with no record to restore them from, and the
        // teardown's residue sweep then reset them to DHCP: a user's static
        // resolvers gone for one transient failure. The per-interface
        // `isUntouched` check below is the same rule one interface at a time.
        guard hasSavedInterfaces() else { throw SystemDNSManagerError.priorStateNotCaptured }
        let services = try connectedNetworkServices(logger: logger)
        guard !services.isEmpty else { return }

        try startRelay(forwarderPort: forwarderPort, logger: logger)

        // Only interfaces whose servers were captured are redirected: there
        // is nothing to put back on the others. That excludes an interface
        // whose read failed (recorded as untouched) and one that appeared
        // between the capture and this write, which the hosts leave room for
        // by starting the forwarder in between. The latter is left for the
        // next `reconcile`, which records an interface before redirecting it.
        let captured = savedInterfaces()
        let writable = services.filter { captured[$0] != nil }
        for service in services where captured[service] == nil && !isUntouched(service) {
            logger?.log(.notice, "Not redirecting \(service): it appeared after the DNS servers were captured. The next reconcile records it first.", category: .system)
        }
        for service in writable {
            try privilegeClient.execute(.setDNSServers, values: [service, "127.0.0.1"])
        }

        logger?.log(.notice, "Set system DNS to 127.0.0.1 via relay :53 -> :\(forwarderPort) on \(writable.count) interface(s).", category: .system)
    }

    package func clear(logger: (any LogSink)?) throws {
        operations.lock()
        defer { operations.unlock() }
        guard hasSavedInterfaces() else {
            // A previous teardown restored this surface. Probing the machine
            // now would flag a user's own 127.0.0.1 resolver — just restored —
            // as our residue and reset it.
            if journal.ownership(of: .systemDNS) == .released {
                stopRelay(logger: logger)
                logger?.log(.debug, "System DNS teardown skipped: a previous teardown already restored this surface.", category: .system)
                return
            }
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
            // Applied, but there was nothing to capture — no services, or none
            // readable, in which case nothing was redirected either. The relay
            // still has to go. Released, not merely forgotten: the next
            // teardown must not read a user's own 127.0.0.1 as our residue.
            stopRelay(logger: logger)
            deleteSavedState()
            journal.markReleased(surface: .systemDNS)
            return
        }

        stopRelay(logger: logger)

        // Listed, not connected: a recorded interface that is down right now
        // still takes the write, and restoring it now is what stops it from
        // coming back pointed at a resolver that is gone. Only an interface
        // that no longer exists is skipped.
        // A listing that fails is a failure of the teardown, not an empty
        // machine: nothing gets skipped as "gone", and the records stay.
        let currentServices: Set<String>
        do {
            currentServices = Set(try listedNetworkServices(includingDisabled: true))
        } catch {
            logger?.log(.warning, "Could not list network services during the DNS teardown (\(error.displayDescription)); keeping the recorded servers so a later teardown can retry.", category: .system)
            return
        }
        var restored = 0
        var skipped = 0
        var deferredToNextLaunch = 0
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
            } catch PrivilegeClientError.refused(.noConsoleUser, _) {
                // At the loginwindow the helper admits a reset to DHCP but not
                // the recorded servers. The relay is already stopped, so a
                // service left on 127.0.0.1 has no resolver; reset it now and
                // keep the record for the next launch to restore.
                do {
                    try privilegeClient.execute(.setDNSServers, values: [service, "empty"])
                    deferredToNextLaunch += 1
                    logger?.log(.warning, "Reset DNS on \(service) to DHCP at the loginwindow instead of restoring it; the recorded servers are restored at the next launch.", category: .system)
                } catch {
                    lastError = error
                    logger?.log(.warning, "Failed to reset DNS for \(service) at the loginwindow: \(error.displayDescription)", category: .system)
                }
            } catch {
                lastError = error
                logger?.log(.warning, "Failed to restore DNS for \(service): \(error.displayDescription)", category: .system)
            }
        }

        // Only drop the records once every interface we could reach is back.
        // Forgetting after a partial failure destroys the only copy of the
        // remaining interfaces' real servers while leaving them pinned at
        // 127.0.0.1 — the rule the proxy and launchd surfaces already follow.
        if lastError == nil, deferredToNextLaunch == 0 {
            deleteSavedState()
            journal.markReleased(surface: .systemDNS)
        } else if lastError != nil {
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
        operations.lock()
        defer { operations.unlock() }
        // The daemon's first act is this save; without the import first it
        // would record a stranded 127.0.0.1 as the prior value and make the
        // snapshot unimportable for good.
        importLegacySnapshotIfPresent(logger: logger)
        let services = try connectedNetworkServices(logger: logger)
        for service in services {
            // First-write-wins in the journal: a second `saveCurrentDNS` in the
            // same session reads 127.0.0.1 (our own relay) as the current
            // value, and recording that would make restore a no-op.
            guard let servers = readDNSServersStrict(service: service) else {
                journal.recordPrior(surface: .systemDNS, scope: service, value: Self.untouchedMarkerValue)
                logger?.log(.warning, "Could not read the DNS servers on \(service); leaving that interface untouched.", category: .system)
                continue
            }
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

    /// Launch-time crash recovery for this surface. Decides and acts, but
    /// does not log the decision: it returns it, so the host can emit the
    /// `platform.launch_recovery_*` event first and derive the log line from
    /// that (`LaunchRecovery.report`). The restore's own per-interface lines
    /// are `clear`'s and still log.
    package func restoreIfNeeded(logger: (any LogSink)?) -> LaunchRecoveryOutcome {
        operations.lock()
        defer { operations.unlock() }
        importLegacySnapshotIfPresent(logger: logger)
        guard hasSavedInterfaces(), let savedAt = journal.oldestRecordDate(for: .systemDNS) else {
            return .nothingToDo(.nothingRecorded)
        }

        let stalenessThreshold: TimeInterval = 7 * 24 * 3600
        let isStale = Date().timeIntervalSince(savedAt) > stalenessThreshold

        if isStale {
            return performRestore(stale: true, logger: logger)
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
                return .declinedLiveListener
            }
            deleteSavedState()
            return .discardedStaleRecords
        }

        return performRestore(stale: false, logger: logger)
    }

    /// A restore that throws, or that keeps records because some interface
    /// could not be put back, is a failure of recovery: the records are what
    /// the next launch retries from.
    private func performRestore(stale: Bool, logger: (any LogSink)?) -> LaunchRecoveryOutcome {
        do {
            try clear(logger: logger)
        } catch {
            return .failed(reason: error.displayDescription)
        }
        return hasSavedInterfaces() ? .failed(reason: "records_kept") : .restored(stale: stale)
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

    /// What a health check's relay restart came to.
    package enum RelayRestart: Sendable, Equatable {
        /// Nothing is recorded for this surface, so a stop has released it
        /// since the probe that asked for the restart. Nothing was started.
        case notManaged
        case restarted
        case unresponsive
    }

    /// Restarts the relay for a failed liveness probe and probes again. Meant
    /// to run off the main actor: the restart is a helper round trip and the
    /// probe waits up to two seconds.
    ///
    /// Checked against the journal under the operation lock, because the
    /// probe that asked for this ran a moment ago and a stop may have
    /// finished in between. A relay started after that stop would hold :53
    /// and forward to a port nothing listens on.
    package func restartRelayIfManaged(forwarderPort: Int, logger: (any LogSink)?) -> RelayRestart {
        let started: RelayRestart? = operations.withLock {
            guard hasSavedInterfaces() else {
                logger?.log(.debug, "DNS relay restart skipped: system DNS is no longer managed.", category: .system)
                return .notManaged
            }
            do {
                try startRelay(forwarderPort: forwarderPort, logger: logger)
                return nil
            } catch {
                logger?.log(.warning, "DNS relay restart failed: \(error.localizedDescription)", category: .system)
                return .unresponsive
            }
        }
        if let started { return started }
        // Outside the lock: the probe waits up to two seconds, and a stop on
        // the main actor should not wait that out.
        guard relayIsLive() else {
            // A stop that ran during the probe took the relay down on
            // purpose. That is not a pipeline to report as unresponsive.
            return operations.withLock { hasSavedInterfaces() } ? .unresponsive : .notManaged
        }
        logger?.log(.notice, "DNS relay restarted successfully.", category: .system)
        return .restarted
    }

    package func stopRelay(logger: (any LogSink)?) {
        try? privilegeClient.execute(.stopDNSRelay, values: [])
        logger?.log(.notice, "DNS relay on :53 stopped.", category: .system)
    }

    package func readDNSServers(service: String) -> [String] {
        readDNSServersStrict(service: service) ?? []
    }

    /// `nil` when the read failed — distinct from "read fine, DHCP default".
    /// Capture must tell them apart: recording an empty list for an interface
    /// whose servers were never seen makes teardown reset it to DHCP.
    package func readDNSServersStrict(service: String) -> [String]? {
        guard let result = try? commandRunner("/usr/sbin/networksetup", ["-getdnsservers", service]),
              result.exitCode == 0 else { return nil }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("any DNS Servers set") || output.isEmpty {
            return []
        }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Every service `networksetup` knows, connected or not. With
    /// `includingDisabled`, the starred entries too (asterisk stripped) — they
    /// still hold settings and still take writes.
    package func listedNetworkServices(includingDisabled: Bool = false) throws -> [String] {
        let result = try commandRunner("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard result.exitCode == 0 else {
            throw SystemDNSManagerError.listingFailed(exitCode: result.exitCode)
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

    package func connectedNetworkServices(logger: (any LogSink)? = nil) throws -> [String] {
        let all = try listedNetworkServices()

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
        operations.lock()
        defer { operations.unlock() }
        guard hasSavedInterfaces() else { return }
        guard let currentServices = try? connectedNetworkServices(logger: nil) else { return }

        let currentSet = Set(currentServices)
        let savedSet = Set(savedInterfaces().keys)

        // Untouched interfaces are neither pinned nor re-captured.
        let newInterfaces = currentSet.subtracting(savedSet).filter { !isUntouched($0) }
        // Gone means no longer listed, not merely disconnected: a VPN service
        // mid-flap is down, not vanished, and forgetting its record would
        // leave it pinned at 127.0.0.1 with nothing to restore it from. Without
        // a listing nothing is forgotten.
        let listedSet = Set((try? listedNetworkServices(includingDisabled: true)) ?? Array(savedSet))
        let goneInterfaces = savedSet.subtracting(listedSet)

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
            guard let servers = readDNSServersStrict(service: iface) else {
                journal.recordPrior(surface: .systemDNS, scope: iface, value: Self.untouchedMarkerValue)
                logger?.log(.warning, "DNS reconcile: could not read the DNS servers on \(iface); leaving it untouched.", category: .system)
                continue
            }
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

