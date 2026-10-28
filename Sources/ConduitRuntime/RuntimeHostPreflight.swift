// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel

/// The host's preflight state: the helper verdict it holds for display and its refresh generation. The held verdict is what a `busy` read keeps
/// (`HelperToolPrivilegeClient.Status.updated(by:)`). A helper replacement marks it stale and advances `generation`, so a pass that began
/// before it changes and repairs nothing. At most two passes exist: the one running, and the one pending that every request launched
/// meanwhile joins. No waiter list is kept: each launched operation's effect awaits its pass, and the service's ordinary capacity bounds them.
struct RuntimeHostPreflightState {
    var heldHelperStatus: HelperToolPrivilegeClient.Status = .notInstalled
    /// Set when the helper was replaced: the held verdict was about the old one, so a `busy` read must not keep it. Cleared by the first
    /// conclusive read.
    var verdictStale = false
    var generation = 0
    var running: Task<ControlOperationOutcome, Never>?
    var pending: Task<ControlOperationOutcome, Never>?
}

extension RuntimeHost {
    /// The fence half of a preflight request, in its admission turn: it starts no pass. With `helperReplaced` the held verdict is stale and
    /// the generation advances at once, so a pass already reading is dropped whenever this request launches. The request is pending work
    /// from here until its effect has its pass's answer (`preflightPass`).
    func admitPreflight(helperReplaced: Bool) {
        if helperReplaced {
            preflight.verdictStale = true
            preflight.generation += 1
        }
        pendingAdmissions += 1
    }

    /// The pass an admitted request's effect joins at launch: the pending one, which has not begun, or a new one that begins once the
    /// running pass has ended. A request never joins the running pass, so every reading it gets was taken after its admission and launch.
    func preflightPass() -> Task<ControlOperationOutcome, Never> {
        if let pending = preflight.pending { return pending }
        let previous = preflight.running
        let pass = Task { @MainActor [weak self] () -> ControlOperationOutcome in
            _ = await previous?.value
            guard let self else { return .failed(.internalFailure) }
            // This pass begins, and it is the pending one: only its own start clears that slot. A request from here on makes the next pass.
            precondition(self.preflight.running == nil && self.preflight.pending != nil, "one preflight pass runs at a time")
            self.preflight.running = self.preflight.pending
            self.preflight.pending = nil
            defer { self.preflight.running = nil }
            return await self.runPreflightPass()
        }
        preflight.pending = pass
        return pass
    }

    /// One pass, as the app's preflight refresh asks for it. After launch recovery it captures, in one owner turn, the stamp, the requested pair,
    /// the run state, the VPN gate and the held verdict; the helper read and the evaluation run on a global queue, never on `platformWork`, so
    /// no teardown queues behind a slow ping. A pass that begins after the quit latched reads nothing, and one whose generation moved or that
    /// ends after the latch fails `staleRevision`: its reading may describe a replaced helper, so it updates no verdict and repairs nothing.
    /// With no helper source the reading is `notObserved`. Every request that joined it is still pending work while it runs, so a settle sees
    /// a pass whose repairs may still follow.
    private func runPreflightPass() async -> ControlOperationOutcome {
        await awaitLaunchRecovery()
        guard !workflow.isTerminal else { return .failed(.staleRevision) }
        guard let stamp = snapshot()?.stamp else { return .failed(.internalFailure) }
        guard let helper = helperStatusSource else { return preflightCompleted(stamp, reading: .unavailable(.notObserved)) }
        let generation = preflight.generation
        let state = orchestrator.snapshot.runtimeStatus.state
        let isRunning = state == .running || state == .degraded || state == .recovering
        let config = reconciler.requestedConfig
        let platform = reconciler.requestedPlatformConfig
        let systemProxy = systemConduit
        let resolvers = dnsManager
        let vpnConnected = splitDNSGate.entriesWanted
        // `notInstalled` holds no verdict, so a `busy` read after a replacement stands on its own.
        let held: HelperToolPrivilegeClient.Status = preflight.verdictStale ? .notInstalled : preflight.heldHelperStatus
        let (reading, evaluated): (HelperToolPrivilegeClient.Status, ActivationPreflight) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let reading = helper.status
                let evaluated = ActivationPreflightEvaluator.evaluate(
                    config: config, platformConfig: platform, isRunning: isRunning, helperStatus: held.updated(by: reading),
                    systemConduit: systemProxy, dnsManager: resolvers, vpnConnected: vpnConnected
                )
                continuation.resume(returning: (reading, evaluated))
            }
        }
        guard generation == preflight.generation, !workflow.isTerminal else { return .failed(.staleRevision) }
        let verdict = held.updated(by: reading)
        let becameAvailable = verdict == .installed && preflight.heldHelperStatus != .installed
        preflight.heldHelperStatus = verdict
        if reading != .busy { preflight.verdictStale = false }
        if becameAvailable {
            deliveries.deliver { [weak self] in await self?.reconcileSystemProxyIfRunning() }
        }
        // The raw read, not the held verdict: `busy` keeps `installed` on display, but is no evidence the helper takes writes (#210).
        observeHelperForSplitDNS(available: reading == .installed, trigger: "helper_available")
        return preflightCompleted(stamp, reading: .observed(RuntimePreflightProjection.items(evaluated, helper: verdict, readBusy: reading == .busy)))
    }

    private func preflightCompleted(_ stamp: ControlRuntimeStamp, reading: ControlPreflightReading) -> ControlOperationOutcome {
        let observedAt: ControlTimestamp
        do {
            observedAt = try ControlTimestamp(Date().timeIntervalSince1970)
        } catch {
            preconditionFailure("the wall clock reads a finite time")
        }
        return completed(.refreshPreflight, result: .preflight(ControlPreflightObservation(stamp: stamp, observedAt: observedAt, reading: reading)))
    }
}

/// The preflight's PlatformMac values on the control wire. The bridge does not import PlatformMac, so the mapping lives with the host. Each
/// switch is exhaustive, so a new case fails to compile here. The helper's own refusal text is not carried.
enum RuntimePreflightProjection {
    /// `helper` is the verdict `updated(by:)` held after the read, so the pair is always one a pass produces.
    static func items(
        _ preflight: ActivationPreflight,
        helper: HelperToolPrivilegeClient.Status,
        readBusy: Bool
    ) -> ControlPreflightItems {
        do {
            return try ControlPreflightItems(
                systemProxy: status(preflight.systemProxy),
                environmentVariables: status(preflight.environmentVariables),
                splitDNS: status(preflight.splitDNS),
                helper: self.helper(helper),
                helperReadBusy: readBusy
            )
        } catch {
            preconditionFailure("a held verdict is consistent with the read it was updated by")
        }
    }

    static func status(_ status: IntegrationStatus) -> ControlIntegrationStatus {
        let level: ControlPrivilegeLevel = switch status.privilegeLevel {
        case .none: .none
        case .mayRequireAdmin: .mayRequireAdmin
        case .requiresAdmin: .requiresAdmin
        }
        return ControlIntegrationStatus(enabled: status.enabled, alreadyApplied: status.alreadyApplied, privilegeLevel: level)
    }

    static func helper(_ status: HelperToolPrivilegeClient.Status) -> ControlHelperStatus {
        switch status {
        case .installed: .installed
        case .outdated: .outdated
        case .notInstalled: .notInstalled
        case .notResponding: .notResponding
        case .busy: .busy
        case .waitingForConsoleUser: .waitingForConsoleUser
        case .unauthorized: .unauthorized
        case .callerNotAccepted: .callerNotAccepted
        }
    }
}
