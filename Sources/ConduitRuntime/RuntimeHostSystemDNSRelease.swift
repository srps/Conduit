// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel
import RuntimeEvents

/// What a teardown's system DNS restore came to.
enum SystemDNSTeardownRestore: Equatable, Sendable {
    case restored
    /// Skipped, superseded, or failed with the relay stopped: the journal keeps whatever is left.
    case notRestored
    case relayKept(reason: String, loopbackServices: Int?)
}

extension RuntimeHost {
    /// The services named one event each, at most; the summary counts the rest.
    static let maximumReportedDNSResidue = ControlSystemDNSRelease.maximumNamedServices

    /// Whether the forwarder answers in this state, so the relay may stay up in front of it.
    static func forwarderServes(_ state: ModuleRunState) -> Bool {
        state == .running || state == .warning
    }

    /// A restore that failed while a service still uses the relay, so the relay and the forwarder keep serving it. Event first.
    func keptServing(operation: String, reason: String, loopbackServices: Int?) {
        let services = loopbackServices.map(String.init) ?? "unknown"
        recordLifecycle(RuntimeEvent(kind: .config, event: "platform.dns_restore_kept_serving",
                                     detail: "operation=\(operation) loopback_services=\(services) reason=\(reason)"),
                        level: .warning)
    }

    /// One read of what Conduit still has in system DNS, under the manager's lock so no restore or apply lands inside it, and whether the
    /// host still applies system DNS. Each service still on the loopback resolver is an event, then the verdict, before any log line.
    func checkSystemDNSRelease() async -> ControlSystemDNSRelease {
        let manager = systemDNSManager
        let reading = await platformWork.run { manager.releaseReading() }
        let applies = systemDNSReconcileIsDue
        let release: ControlSystemDNSRelease
        let detail: String
        switch reading {
        case .released:
            release = Self.release(settingsRead: true, recordsKept: 0, loopbackServices: 0, applies: applies)
            detail = "outcome=released"
        case .remaining(let recordsKept, let residue):
            for service in residue.prefix(Self.maximumReportedDNSResidue) {
                recordLifecycle(RuntimeEvent(kind: .config, event: "platform.dns_release_residue", detail: Self.residueDetail(service)),
                                level: .warning)
            }
            release = Self.release(settingsRead: true, recordsKept: recordsKept, loopbackServices: residue.count, applies: applies)
            let unreported = max(0, residue.count - Self.maximumReportedDNSResidue)
            detail = "outcome=remaining records=\(recordsKept) loopback_services=\(residue.count) unreported=\(unreported)"
        case .unreadable(let reason):
            release = Self.release(settingsRead: false, recordsKept: 0, loopbackServices: 0, applies: applies)
            detail = "outcome=unreadable reason=\(reason)"
        }
        recordLifecycle(RuntimeEvent(kind: .config, event: "platform.dns_release_checked", detail: detail + " applies=\(applies)"),
                        level: release.isReleased ? .notice : .warning)
        return release
    }

    private static func residueDetail(_ service: SystemDNSResidue) -> String {
        var fields: [String] = []
        if let location = service.locationID { fields.append("location=\(location)") }
        if let id = service.serviceID { fields.append("service=\(id)") }
        fields.append("name=\(service.serviceName)")
        fields.append("active=\(service.active)")
        return fields.joined(separator: " ")
    }

    private static func release(settingsRead: Bool, recordsKept: Int, loopbackServices: Int, applies: Bool) -> ControlSystemDNSRelease {
        do {
            return ControlSystemDNSRelease(settingsRead: settingsRead, recordsKept: try ControlCount(recordsKept),
                                           loopbackServices: try ControlCount(loopbackServices), appliesSystemDNS: applies)
        } catch {
            preconditionFailure("a count read off the machine is never negative")
        }
    }
}
