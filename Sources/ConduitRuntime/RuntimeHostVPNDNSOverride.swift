// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// The disarm goes ahead of both clears of system DNS (`.clearSystemDNS` and the DNS teardown).
extension RuntimeHost {
    /// Asks for a pass in its own delivery, so a caller in a synchronous turn never waits on the helper.
    func requestVPNDNSOverrideRun(pollStatus: Bool) {
        deliveries.deliver { [weak self] in await self?.runVPNDNSOverride(pollStatus: pollStatus) }
    }

    /// One pass at a time; a held set whose disarm fails twice waits for the next request, so a failing helper never spins.
    func runVPNDNSOverride(pollStatus: Bool) async {
        vpnDNSOverrideWanted = true
        vpnDNSOverridePoll = vpnDNSOverridePoll || pollStatus
        guard !vpnDNSOverrideRunning else { return }
        vpnDNSOverrideRunning = true
        defer { vpnDNSOverrideRunning = false }
        var heldBack: LiveSplitDNSDetection.DetectedSet?
        while vpnDNSOverrideWanted {
            let poll = vpnDNSOverridePoll
            vpnDNSOverrideWanted = false
            vpnDNSOverridePoll = false
            await vpnDNSOverride.pass({ [unowned self] in self.vpnDNSOverrideInputs() }, pollStatus: poll)
            if let held = vpnDNSOverrideHeldSet {
                if vpnDNSOverrideReleases(before: held) {
                    guard heldBack != held else { break }
                    heldBack = held
                    vpnDNSOverrideWanted = true
                    continue
                }
                heldBack = nil
                vpnDNSOverrideHeldSet = nil
                applyDetectedSet(held)
                vpnDNSOverrideWanted = true
            }
        }
    }

    func vpnDNSOverrideInputs() -> VPNResolverOverrideController.Inputs {
        var inUse = Set(orchestrator.detectedSplitDNSRules.flatMap(\.servers))
        if let held = vpnDNSOverrideHeldSet {
            inUse.formIntersection(held.rules.flatMap(\.servers))
        }
        return VPNResolverOverrideController.Inputs(
            manageSystemDNS: platformConfig.manageSystemDNS,
            relayServing: vpnDNSOverrideRelayServing,
            // Only the Stop and the Manage-system-DNS-off clear stop the timer; both disarm right after. A Stop that kept DNS serving
            // rearms the timer for the services already on the relay, and its fence holds until the next DNS Start.
            dnsStopping: dnsHealthTimer == nil || workflow.dnsIntent.fenced,
            entriesWanted: splitDNSGate.entriesWanted,
            reading: splitDNSDetection.lastReading,
            serversInUse: inUse
        )
    }

    func vpnDNSOverrideReleases(before set: LiveSplitDNSDetection.DetectedSet) -> Bool {
        guard vpnDNSOverride.mayArm else { return false }
        var inputs = vpnDNSOverrideInputs()
        inputs.serversInUse = Set(set.rules.flatMap(\.servers))
        if case .disarm = vpnDNSOverride.decide(inputs) { return true }
        return false
    }
}
