// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// Split DNS follows the resolvers a connected VPN pushes (decision 0044, `docs/design-live-vpn-split-dns.md`).
///
/// The host owns the two inputs, the VPN gate and the pushed-resolver observer, and `LiveSplitDNSDetection`
/// decides from them with `LiveSplitDNSPolicy`. The host pushes only the detected rules; the orchestrator merges
/// them with the manual entries of its own config, so manual split DNS never depends on anything here.
extension RuntimeHost {
    /// Starts or stops the observer so that it runs exactly while the DNS forwarder is up or coming up and
    /// `dns.followVPNResolvers` is on. Idempotent. A restart of the forwarder keeps it running. Stopping it pushes
    /// an empty detected set, so the table holds the manual entries alone.
    func reconcileSplitDNSDetection() {
        let forwarder = orchestrator.snapshot.dnsRunState
        let wanted = orchestrator.config.dns.followVPNResolvers && forwarder != .stopped && forwarder != .failed
        guard wanted != splitDNSDetectionRunning else { return }
        splitDNSDetectionRunning = wanted
        if wanted {
            splitDNSDetection.start()
            pushedResolverObserver.start()
        } else {
            pushedResolverObserver.stop()
            splitDNSDetection.stop()
            applyPendingSplitDNSDetection()
        }
    }

    /// Applies the newest detected set and reports what the policy rejected or could not read, events first. The
    /// events describe the step from the set the orchestrator holds to this one, so a set that a burst of
    /// readings passed through and left is not reported. Idempotent: with nothing pending it does nothing.
    func applyPendingSplitDNSDetection() {
        guard let pending = splitDNSDetection.take() else { return }
        if let failure = pending.failure {
            record(
                RuntimeEvent(kind: .health, event: "dns.split_detection_failed", detail: "reason=\(failure.rawValue)"),
                level: .warning
            )
        }
        reportIgnoredResolvers(pending.ignored)
        guard let set = pending.set else { return }
        reportDetectedSplitDNS(before: orchestrator.snapshot.detectedSplitDNS, after: set.display)
        orchestrator.applyDetectedSplitDNSRules(set.rules, display: set.display, reason: set.reason)
    }

    /// One `dns.split_detected` per resolver that entered or left the set in use, and one per resolver in it when
    /// the set went from in use to held or back. Idle rows are not in use, so a change among them reports nothing.
    private func reportDetectedSplitDNS(before: DetectedSplitDNSDisplay, after: DetectedSplitDNSDisplay) {
        func inUse(_ display: DetectedSplitDNSDisplay) -> [DetectedSplitDNSDisplay.Row] {
            display.state == .idle ? [] : display.rows
        }
        let was = inUse(before), now = inUse(after)
        let restated = before.state != after.state && before.state != .idle
        for row in was where !now.contains(row) {
            recordDetected(row, outcome: "cleared")
        }
        for row in now where restated || !was.contains(row) {
            recordDetected(row, outcome: after.state == .held ? "held" : "applied")
        }
    }

    private func recordDetected(_ row: DetectedSplitDNSDisplay.Row, outcome: String) {
        let domains = row.domains.joined(separator: ",")
        let detail = "interface=\(row.interface) domains=\(domains) servers=\(row.servers.count) outcome=\(outcome)"
        record(RuntimeEvent(kind: .health, event: "dns.split_detected", detail: detail), level: .notice)
    }

    /// In a fixed order, since a set has none. The dropped value is left out: an invalid domain is whatever text
    /// the store held.
    private func reportIgnoredResolvers(_ rejections: Set<PushedResolverRejection>) {
        let details = rejections.map {
            "service=\($0.serviceID) interface=\($0.interface ?? "none") reason=\($0.reason.rawValue)"
        }
        for detail in details.sorted() {
            record(RuntimeEvent(kind: .health, event: "dns.split_resolver_ignored", detail: detail), level: .info)
        }
    }

    private func record(_ event: RuntimeEvent, level: LogLevel) {
        orchestrator.eventLog.append(event)
        logger.log(level, "Split DNS: \(event.event) \(event.detail ?? "")", category: .network)
    }
}
