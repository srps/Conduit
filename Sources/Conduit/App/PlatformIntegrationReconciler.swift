// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// What a change to `PlatformIntegrationConfig` has to do to the machine.
///
/// Each `manage*` flag gates a side effect that is applied when its runtime
/// starts and cleared when it stops. Until this table existed the flag was
/// never read when it *changed*: flipping "Manage macOS proxy settings" off
/// while the proxy ran changed a stored value and nothing else, and because
/// teardown gated on the same flag, quitting then left the system proxy
/// pointing at a listener that was gone (#13).
///
/// Pure so the rules can be tested as a table. `AppState` runs it from
/// `saveConfig()` beside the `ProxyConfig` reconcile and executes each action
/// through the same manager calls the start and stop paths use.
///
/// Two asymmetries are deliberate:
///
/// - A clear is unconditional on runtime state. Every manager's `clear` is
///   idempotent against the prior-state journal, and "flag off while the
///   runtime is down" is exactly the case where gating would strand a surface
///   a crashed or failed start left applied.
/// - An apply requires the runtime that owns the surface to be up. With it
///   down the start path applies the surface later, and applying now would
///   point the machine at a listener that is not there.
struct PlatformIntegrationReconciler {
    enum Action: Equatable {
        case applySystemProxy
        case clearSystemProxy
        case applyEnvironment
        case clearEnvironment
        /// Static split-DNS entry files. Owned by the proxy lifecycle.
        case applyResolverEntries
        /// Intercept-rule resolver files, written only while the forwarder
        /// and transparent proxy are both listening. Owned by the DNS
        /// lifecycle; "refresh" because the executor decides from the live
        /// bindings whether the files may exist at all.
        case refreshInterceptFiles
        /// Entry files and intercept files together.
        case clearResolvers
        case applySystemDNS
        case clearSystemDNS
        case setLaunchAtLogin(Bool)
    }

    /// `proxyIsUp` and `dnsIsUp` come from the orchestrator snapshot, never
    /// the presentation mirror, for the reason every lifecycle comment in
    /// `AppState` gives: the mirror is an async hop behind.
    static func actions(
        old: PlatformIntegrationConfig,
        new: PlatformIntegrationConfig,
        proxyIsUp: Bool,
        dnsIsUp: Bool
    ) -> [Action] {
        var actions: [Action] = []

        switch (old.manageSystemProxy, new.manageSystemProxy) {
        case (true, false):
            actions.append(.clearSystemProxy)
        case (false, true) where proxyIsUp:
            actions.append(.applySystemProxy)
        case (true, true) where proxyIsUp && old.systemProxyMode != new.systemProxyMode:
            // Same flag, different shape: PAC and manual write different
            // fields, and `apply` rewrites the service from scratch.
            actions.append(.applySystemProxy)
        default:
            break
        }

        switch (old.manageEnvironmentVariables, new.manageEnvironmentVariables) {
        case (true, false):
            actions.append(.clearEnvironment)
        case (false, true) where proxyIsUp:
            actions.append(.applyEnvironment)
        default:
            break
        }

        switch (old.manageDNSResolvers, new.manageDNSResolvers) {
        case (true, false):
            actions.append(.clearResolvers)
        case (false, true):
            // The two file sets follow different runtimes, so each is
            // applied only when its own runtime is up — the same split the
            // start paths make (`startProxy` writes entries, `startDNS`
            // writes intercepts).
            if proxyIsUp { actions.append(.applyResolverEntries) }
            if dnsIsUp { actions.append(.refreshInterceptFiles) }
        default:
            break
        }

        switch (old.manageSystemDNS, new.manageSystemDNS) {
        case (true, false):
            actions.append(.clearSystemDNS)
        case (false, true) where dnsIsUp:
            actions.append(.applySystemDNS)
        default:
            break
        }

        return actions
    }

    /// Actions that depend on no runtime state and must not wait for the
    /// reconcile pass: the pass is queued behind `applyConfigChange`, and a
    /// quit right after the save would lose it. The other surfaces survive
    /// that — termination cleanup clears whatever is journaled as ours — but
    /// a login item has no teardown, so a persisted "off" with the
    /// registration still in place would launch Conduit indefinitely.
    static func immediateActions(
        old: PlatformIntegrationConfig,
        new: PlatformIntegrationConfig
    ) -> [Action] {
        guard old.launchAtLogin != new.launchAtLogin else { return [] }
        return [.setLaunchAtLogin(new.launchAtLogin)]
    }
}
