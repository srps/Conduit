// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

package final class TunnelResolverManager: TunnelResolverApplying, @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    private let logger: any LogSink
    /// The directory `cleanupStale` enumerates. Required, so a host or simulator names the directory it owns and never
    /// reads the machine's `/etc/resolver` by default. Production passes `/etc/resolver`.
    private let resolverDirectory: String
    /// The host's platform queue. Each of the three operations runs there whole, so its helper round trips hold that queue, in order
    /// with the host's other platform work, and never a concurrency-pool thread.
    private let work: PlatformWork

    /// Port carried in every `/etc/resolver/*` file this manager writes.
    /// Kernel-side constant — the listener that consumes the resolver files
    /// (`TunnelDNSResponder`) is kernel-bound and needs the same value, so the
    /// source of truth lives in `ConduitCore/Models/TunnelResolverPort.swift`.
    /// Exposed here as a re-export so older callers (`Self.resolverPort`) keep
    /// compiling; newer code reads `TunnelResolverPort.port` directly.
    package static let resolverPort = TunnelResolverPort.port

    package init(privilegeClient: PrivilegeClient, logger: any LogSink, resolverDirectory: String, work: PlatformWork) {
        self.privilegeClient = privilegeClient
        self.logger = logger
        self.resolverDirectory = resolverDirectory
        self.work = work
    }

    package func apply(hostname: String, listenIP: String) throws {
        try privilegeClient.execute(
            .applyDNS,
            values: [hostname, listenIP, String(Self.resolverPort)]
        )
        logger.log(.info, "Tunnel DNS: created /etc/resolver/\(hostname) → \(listenIP):\(Self.resolverPort).", category: .tunnel)
    }

    package func remove(hostname: String) throws {
        try privilegeClient.execute(.removeDNS, values: [hostname])
        logger.log(.info, "Tunnel DNS: removed /etc/resolver/\(hostname).", category: .tunnel)
    }

    package func applyAll(hostnames: [String], listenIP: String) async -> (succeeded: [String], failed: [String]) {
        await work.run { [self] in applyAllNow(hostnames: hostnames, listenIP: listenIP) }
    }

    package func removeAll(hostnames: [String]) async {
        await work.run { [self] in removeAllNow(hostnames: hostnames) }
    }

    package func cleanupStale(activeHostnames: Set<String>) async {
        await work.run { [self] in cleanupStaleNow(activeHostnames: activeHostnames) }
    }

    private func applyAllNow(hostnames: [String], listenIP: String) -> (succeeded: [String], failed: [String]) {
        var succeeded: [String] = []
        var failed: [String] = []
        for hostname in hostnames {
            do {
                try apply(hostname: hostname, listenIP: listenIP)
                succeeded.append(hostname)
            } catch {
                logger.log(.warning, "Tunnel DNS: failed to create resolver for \(hostname): \(error.localizedDescription)", category: .tunnel)
                failed.append(hostname)
            }
        }
        return (succeeded, failed)
    }

    private func removeAllNow(hostnames: [String]) {
        for hostname in hostnames {
            do {
                try remove(hostname: hostname)
            } catch {
                logger.log(.warning, "Tunnel DNS: failed to remove resolver for \(hostname): \(error.localizedDescription)", category: .tunnel)
            }
        }
    }

    private func cleanupStaleNow(activeHostnames: Set<String>) {
        let resolverDir = resolverDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resolverDir) else { return }

        for entry in entries {
            guard !activeHostnames.contains(entry) else { continue }
            let path = "\(resolverDir)/\(entry)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            guard content.contains("port \(Self.resolverPort)") else { continue }
            do {
                try remove(hostname: entry)
                logger.log(.notice, "Tunnel DNS: cleaned up stale resolver file for \(entry).", category: .tunnel)
            } catch {
                logger.log(.warning, "Tunnel DNS: failed to clean up stale resolver for \(entry): \(error.localizedDescription)", category: .tunnel)
            }
        }
    }
}
