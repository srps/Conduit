// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// The two-step resolver reconcile that follows a DNS-affecting config change,
/// with the second step independent of how the first ended.
///
/// Both hosts (`AppState.reconcileRuntimeConfig`, `DaemonRuntimeHost`
/// `.reconcilePlatformSideEffects`) used to wrap `DNSManager.reconcile` and
/// their own `refreshInterceptFiles` in one `do` block. That was safe only
/// while a throwing `reconcile` meant nothing had been applied — and it stopped
/// meaning that when `reconcile` learned to finish the migration even after
/// part of the stale-file sweep failed, rethrowing the aggregate at the end.
/// From then on a throw could arrive *after* a successful apply, skipping the
/// intercept refresh.
///
/// What that skip costs is not a stale file. `applyConfigChange` runs just
/// before this and may have restarted the DNS forwarder on a different
/// `dnsForwarderPort`; the refresh is what re-points `/etc/resolver/<domain>`
/// at the port that came back. Skipped, the entry files are written and the
/// intercept files are left naming a port nothing serves — which blackholes
/// those domains for every process on the machine and outlives the process that
/// wrote them (see `DNSManager.getInterceptDomains`).
///
/// So the refresh runs regardless, and the two failures are reported
/// separately: one is "the config edit did not fully take", the other is "some
/// domains may now resolve nowhere", and collapsing them into a single line
/// loses the one that matters more.
package enum DNSResolverReconciliation {
    /// - Parameters:
    ///   - context: what the reconcile is following, phrased to complete
    ///     "after \(context)" — e.g. `"config change"`, `"config reload"`.
    package static func run(
        after context: String,
        logger: (any LogSink)?,
        reconcile: () throws -> Void,
        refreshInterceptFiles: () throws -> Void
    ) {
        do {
            try reconcile()
        } catch {
            logger?.log(
                .warning,
                "Could not reconcile DNS resolver files after \(context): \(error.localizedDescription)",
                category: .system
            )
        }

        do {
            try refreshInterceptFiles()
        } catch {
            logger?.log(
                .warning,
                "Could not refresh intercept resolver files after \(context): \(error.localizedDescription). "
                    + "Intercepted domains may be pointing at a DNS forwarder port that is no longer served.",
                category: .system
            )
        }
    }
}
