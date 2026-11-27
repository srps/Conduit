// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel
import RuntimeEvents

extension RuntimeHost {
    /// The services named one event each, at most; the summary counts the rest.
    static let maximumReportedDNSResidue = ControlSystemDNSRelease.maximumNamedServices

    /// One read of what Conduit still has in system DNS, under the manager's lock so no restore or apply lands inside it. Each service
    /// still on the loopback resolver is an event, then the verdict, before any log line.
    func checkSystemDNSRelease() async -> ControlSystemDNSRelease {
        let manager = systemDNSManager
        let reading = await platformWork.run { manager.releaseReading() }
        let release: ControlSystemDNSRelease
        let detail: String
        switch reading {
        case .released:
            release = Self.release(settingsRead: true, recordsKept: 0, loopbackServices: 0)
            detail = "outcome=released"
        case .remaining(let recordsKept, let residue):
            for service in residue.prefix(Self.maximumReportedDNSResidue) {
                recordLifecycle(RuntimeEvent(kind: .config, event: "platform.dns_release_residue", detail: Self.residueDetail(service)),
                                level: .warning)
            }
            release = Self.release(settingsRead: true, recordsKept: recordsKept, loopbackServices: residue.count)
            let unreported = max(0, residue.count - Self.maximumReportedDNSResidue)
            detail = "outcome=remaining records=\(recordsKept) loopback_services=\(residue.count) unreported=\(unreported)"
        case .unreadable(let reason):
            release = Self.release(settingsRead: false, recordsKept: 0, loopbackServices: 0)
            detail = "outcome=unreadable reason=\(reason)"
        }
        recordLifecycle(RuntimeEvent(kind: .config, event: "platform.dns_release_checked", detail: detail),
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

    private static func release(settingsRead: Bool, recordsKept: Int, loopbackServices: Int) -> ControlSystemDNSRelease {
        do {
            return ControlSystemDNSRelease(settingsRead: settingsRead, recordsKept: try ControlCount(recordsKept),
                                           loopbackServices: try ControlCount(loopbackServices))
        } catch {
            preconditionFailure("a count read off the machine is never negative")
        }
    }
}
