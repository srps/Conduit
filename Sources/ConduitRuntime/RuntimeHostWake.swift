// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac

/// The repairs a system wake asks for: the system proxy reconcile (guarded by its switch and a running
/// proxy), the kernel's wake path (PAC refresh and connectivity probe), and the system DNS reconcile (guarded by its switch and a running
/// forwarder).
enum SystemWakeRepair {
    case systemProxy
    case kernel
    case systemDNS
}

/// One coalescer per repair, so a burst of wakes is bounded before any task is created: each repair has at most one tracked delivery
/// running and one pass pending, whatever arrives meanwhile. The three stay independent, so a DNS repair never waits behind a held PAC
/// fetch or probe on the kernel's path.
struct SystemWakeDeliveries: Sendable {
    let systemProxy = CoalescedObserverDelivery()
    let kernel = CoalescedObserverDelivery()
    let systemDNS = CoalescedObserverDelivery()
}

/// System wake. The host observes wake from open until the quit: a module Stop, even one that leaves every module down, keeps
/// observing, and only the quit's fence stops it (`admitQuit`). The app names the workspace adapter; the daemon names the inert one. A
/// wake adds no event of its own and schedules no retry; each repair it asks for keeps its own guard.
extension RuntimeHost {
    /// Called once, from `init`. The callback runs on the source's thread and only hands each repair to its coalescer, which hops onto the
    /// main actor through `deliveries`, in order with the other observers.
    func startWakeObserver() {
        systemWakeObserver.start(onWake: { [weak self, deliveries, wakeDeliveries] in
            wakeDeliveries.systemProxy.deliver(using: deliveries) { await self?.repairAfterWake(.systemProxy) }
            wakeDeliveries.kernel.deliver(using: deliveries) { await self?.repairAfterWake(.kernel) }
            wakeDeliveries.systemDNS.deliver(using: deliveries) { await self?.repairAfterWake(.systemDNS) }
        })
    }

    /// Called once, in the quit's admission turn, so no wake is heard after the latch.
    func stopWakeObserver() {
        systemWakeObserver.stop()
    }

    /// One coalesced pass of `repair`. A pass that runs after the quit's admission, running or pending when it was admitted, does nothing.
    /// The host always holds an adopted configuration (it is never built from a failed load), so no unavailable-configuration guard is
    /// needed here.
    func repairAfterWake(_ repair: SystemWakeRepair) async {
        guard quit == nil, !workflow.isTerminal else { return }
        switch repair {
        case .systemProxy: await reconcileSystemProxyIfRunning()
        case .kernel: await orchestrator.handleSystemWake()
        case .systemDNS: await reconcileSystemDNSIfRunning()
        }
    }
}
