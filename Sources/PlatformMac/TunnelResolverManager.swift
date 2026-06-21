// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

package final class TunnelResolverManager: TunnelResolverApplying, @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    private let logger: any LogSink

    /// Port carried in every `/etc/resolver/*` file this manager writes.
    /// Kernel-side constant — the listener that consumes the resolver files
    /// (`TunnelDNSResponder`) is kernel-bound and needs the same value, so the
    /// source of truth lives in `ConduitCore/Models/TunnelResolverPort.swift`.
    /// Exposed here as a re-export so older callers (`Self.resolverPort`) keep
    /// compiling; newer code reads `TunnelResolverPort.port` directly.
    package static let resolverPort = TunnelResolverPort.port

    package init(privilegeClient: PrivilegeClient, logger: any LogSink) {
        self.privilegeClient = privilegeClient
        self.logger = logger
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

    package func applyAll(hostnames: [String], listenIP: String) -> (succeeded: [String], failed: [String]) {
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

    package func removeAll(hostnames: [String]) {
        for hostname in hostnames {
            do {
                try remove(hostname: hostname)
            } catch {
                logger.log(.warning, "Tunnel DNS: failed to remove resolver for \(hostname): \(error.localizedDescription)", category: .tunnel)
            }
        }
    }

    package func cleanupStale(activeHostnames: Set<String>) {
        let resolverDir = "/etc/resolver"
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
