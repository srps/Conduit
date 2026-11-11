// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// Split DNS follows the resolvers a connected VPN pushes (decision 0044, `docs/design-live-vpn-split-dns.md`).
///
/// The host owns the two inputs, the VPN gate and the pushed-resolver observer, and decides with
/// `LiveSplitDNSPolicy`. It pushes only the detected rules; the orchestrator merges them with the manual entries of
/// its own config, so manual split DNS never depends on anything here.
extension RuntimeHost {
    /// Starts or stops the observer so that it runs exactly while the DNS forwarder is up or coming up and
    /// `dns.followVPNResolvers` is on. Idempotent. A restart of the forwarder keeps it running. Stopping it pushes
    /// an empty detected set, so the table holds the manual entries alone.
    func reconcileSplitDNSDetection() {
        let forwarder = orchestrator.snapshot.dnsRunState
        let wanted = orchestrator.config.dns.followVPNResolvers && forwarder != .stopped && forwarder != .failed
        guard wanted != splitDNSDetectionRunning else { return }
        splitDNSDetectionRunning = wanted
        splitDNSDetectionFailure = nil
        guard !wanted else {
            pushedResolverObserver.start()
            return
        }
        pushedResolverObserver.stop()
        pendingPushedReading.withLockedValue { $0 = nil }
        let before = liveSplitDNS.display
        liveSplitDNS = LiveSplitDNSPolicy(limits: liveSplitDNS.limits)
        reportDetectedSplitDNS(before: before, after: liveSplitDNS.display)
        orchestrator.applyDetectedSplitDNSRules([], display: liveSplitDNS.display, reason: .detectionOff)
    }

    /// Takes the newest reading the observer left. A reading that lands after the observer stopped is dropped: the
    /// next start reads the store again.
    func takePushedResolverReading() {
        let taken = pendingPushedReading.withLockedValue { pending -> PushedResolverReading? in
            defer { pending = nil }
            return pending
        }
        guard let reading = taken, splitDNSDetectionRunning else { return }
        if let failure = reading.failure, failure != splitDNSDetectionFailure {
            record(
                RuntimeEvent(kind: .health, event: "dns.split_detection_failed", detail: "reason=\(failure.rawValue)"),
                level: .warning
            )
        }
        splitDNSDetectionFailure = reading.failure
        updateLiveSplitDNS(reading: reading, reason: .pushed)
    }

    /// A VPN report the gate admitted, with the live tunnels the observer named beside it. The policy gets its
    /// last reading back: a verdict changes which of those resolvers are in use, not what the store holds.
    func applyVPNReportToLiveSplitDNS(_ state: VPNObservedState, liveInterfaces: Set<String>) {
        vpnLiveInterfaces = liveInterfaces
        guard splitDNSDetectionRunning else { return }
        let reason: DetectedSplitDNSChangeReason = switch state {
        case .connected, .unknown: .vpnConnected
        case .disconnected: .vpnDisconnected
        case .reasserting: .flapHeld
        }
        updateLiveSplitDNS(reading: liveSplitDNS.lastReading, reason: reason)
    }

    private func updateLiveSplitDNS(reading: PushedResolverReading, reason: DetectedSplitDNSChangeReason) {
        let ignoredBefore = liveSplitDNS.ignored
        let before = liveSplitDNS.display
        let changed = liveSplitDNS.update(gate: splitDNSGate, liveInterfaces: vpnLiveInterfaces, reading: reading)
        reportIgnoredResolvers(liveSplitDNS.ignored.subtracting(ignoredBefore))
        guard changed else { return }
        reportDetectedSplitDNS(before: before, after: liveSplitDNS.display)
        orchestrator.applyDetectedSplitDNSRules(liveSplitDNS.detectedRules, display: liveSplitDNS.display, reason: reason)
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
