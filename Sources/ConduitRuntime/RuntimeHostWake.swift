// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac

/// System wake, the twin of `AppState`'s observer and `AppState.handleSystemWake`. The host observes wake from open until the quit, as
/// the app does from init until termination: a module Stop, even one that leaves every module down, keeps observing, and only the quit's
/// fence stops it (`admitQuit`). A wake adds no event of its own and schedules no retry; each repair it asks for keeps its own guard.
extension RuntimeHost {
    /// Called once, from `init`. The callback only hops: every wake is one delivery onto the main actor, in order with the other observers.
    func startWakeObserver() {
        systemWakeObserver.start(onWake: { [weak self, deliveries] in
            deliveries.deliver { self?.handleSystemWake() }
        })
    }

    /// Called once, in the quit's admission turn, so no wake is heard after the latch.
    func stopWakeObserver() {
        systemWakeObserver.stop()
    }

    /// Whether a wake still acts: not once the quit is admitted. The host always holds an adopted configuration (it is never built from a
    /// failed load), so `AppState`'s unavailable-configuration guard has no state to read here.
    private var wakeActs: Bool { quit == nil && !workflow.isTerminal }

    /// Each repair is its own delivery, as in `AppState`: the system proxy reconcile (guarded by its switch and a running proxy), the
    /// kernel's wake path (PAC refresh and connectivity probe), and the coalesced system DNS reconcile (guarded by its switch and a running
    /// forwarder). A delivery that lands after the quit's admission does nothing.
    func handleSystemWake() {
        guard wakeActs else { return }
        deliveries.deliver { [weak self] in
            guard let self, self.wakeActs else { return }
            await self.reconcileSystemProxyIfRunning()
        }
        deliveries.deliver { [weak self] in
            guard let self, self.wakeActs else { return }
            await self.orchestrator.handleSystemWake()
        }
        deliveries.deliver { [weak self] in
            guard let self, self.wakeActs else { return }
            await self.reconcileSystemDNSIfRunning()
        }
    }
}
