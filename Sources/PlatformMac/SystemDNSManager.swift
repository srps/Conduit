// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package struct SavedDNSState: Codable {
    package var savedAt: Date
    package var interfaces: [String: [String]]

    package init(savedAt: Date = .now, interfaces: [String: [String]] = [:]) {
        self.savedAt = savedAt
        self.interfaces = interfaces
    }
}

package final class SystemDNSManager: @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    package let savedDNSFile: URL

    package init(
        savedDNSFile: URL = RuntimeEnvironment.userDefault().savedDNSFile,
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient()
    ) {
        self.savedDNSFile = savedDNSFile
        self.privilegeClient = privilegeClient
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
        guard let saved = loadSavedState() else {
            resetToDefaults(logger: logger)
            return
        }

        let savedInterfaces = saved.interfaces
        guard !savedInterfaces.isEmpty else {
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

        deleteSavedState()
        logger?.log(.notice, "Restored system DNS for \(restored) interface(s)\(skipped > 0 ? ", skipped \(skipped) vanished" : "").", category: .system)

        if let lastError, restored == 0 {
            throw lastError
        }
    }

    // MARK: - Save / Restore

    package func saveCurrentDNS(logger: (any LogSink)?) throws {
        let services = try connectedNetworkServices(logger: logger)
        var state = SavedDNSState()

        for service in services {
            let servers = readDNSServers(service: service)
            state.interfaces[service] = servers
        }

        let data = try JSONEncoder.prettyEncoder.encode(state)
        try FileManager.default.createDirectory(
            at: savedDNSFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: savedDNSFile, options: .atomic)
        logger?.log(.debug, "Saved current DNS state for \(services.count) interface(s).", category: .system)
    }

    package func restoreIfNeeded(logger: (any LogSink)?) {
        guard let saved = loadSavedState() else { return }

        let stalenessThreshold: TimeInterval = 7 * 24 * 3600
        let isStale = Date().timeIntervalSince(saved.savedAt) > stalenessThreshold

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

    package func hasSavedState() -> Bool {
        FileManager.default.fileExists(atPath: savedDNSFile.path)
    }

    // MARK: - Private

    private func loadSavedState() -> SavedDNSState? {
        guard let data = try? Data(contentsOf: savedDNSFile) else { return nil }
        return try? JSONDecoder().decode(SavedDNSState.self, from: data)
    }

    private func deleteSavedState() {
        try? FileManager.default.removeItem(at: savedDNSFile)
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
        guard var saved = loadSavedState() else { return }
        guard let currentServices = try? connectedNetworkServices(logger: nil) else { return }

        let currentSet = Set(currentServices)
        let savedSet = Set(saved.interfaces.keys)

        let newInterfaces = currentSet.subtracting(savedSet)
        let goneInterfaces = savedSet.subtracting(currentSet)

        if newInterfaces.isEmpty && goneInterfaces.isEmpty { return }

        for iface in newInterfaces {
            let servers = readDNSServers(service: iface)
            if servers == ["127.0.0.1"] { continue }
            saved.interfaces[iface] = servers
            try? privilegeClient.execute(.setDNSServers, values: [iface, "127.0.0.1"])
            logger?.log(.notice, "DNS reconcile: redirected new interface \(iface) to 127.0.0.1.", category: .system)
        }

        for iface in goneInterfaces {
            saved.interfaces.removeValue(forKey: iface)
            logger?.log(.debug, "DNS reconcile: removed vanished interface \(iface) from saved state.", category: .system)
        }

        saved.savedAt = .now
        if let data = try? JSONEncoder.prettyEncoder.encode(saved) {
            try? data.write(to: savedDNSFile, options: .atomic)
        }
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

    private func isPort53InUse() -> Bool {
        let result = try? CommandRunner.run(
            launchPath: "/usr/bin/lsof",
            arguments: ["-i", "UDP:53", "-P", "-n"]
        )
        return result?.exitCode == 0 && !(result?.standardOutput.isEmpty ?? true)
    }
}

private extension JSONEncoder {
    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
