// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyAuth
import ProxyKernel

/// Where a host's Kerberos token comes from.
///
/// `.system` leaves `credentialBasedAuthenticatorProvider` to build `SystemGSSTokenProvider` itself,
/// over the host's ticket recovery and structured event sink (`KerberosKDCRecovery`, `auth.*`
/// events). Production must use it: a provider built outside that factory loses both.
/// `.injected` replaces the system stack for a test or simulator, so no GSS call is made.
package enum RuntimeGSSSource: Sendable {
    case system
    case injected(@Sendable () -> any GSSTokenProvider)

    /// The override `credentialBasedAuthenticatorProvider` takes. `nil` keeps its own construction.
    var tokenProviderOverride: (@Sendable () -> any GSSTokenProvider)? {
        switch self {
        case .system: nil
        case .injected(let make): make
        }
    }
}

/// The privilege adapters one run uses: the base client every privileged side effect goes through, and the
/// helper status source for split-DNS retries. `helperStatus` `nil` observes nothing, so a run never reaches a
/// helper it was not given.
package struct RuntimePrivilegeAdapters {
    package let client: any PrivilegeClient
    package let helperStatus: (any HelperLifecycleManaging)?

    package init(client: any PrivilegeClient, helperStatus: (any HelperLifecycleManaging)?) {
        self.client = client
        self.helperStatus = helperStatus
    }
}

/// Builds one run's privilege adapters over the sink its structured events go to. The caller passes its own
/// diagnostics log, so the events a client emits from its first call are kept (decision 0033). Production
/// builds the helper client here with that sink, once, and returns it as both the client and the status source.
package typealias RuntimePrivilegeAdaptersFactory = @Sendable (
    _ eventSink: @escaping @Sendable (RuntimeEvent) -> Void
) -> RuntimePrivilegeAdapters

/// Builds the VPN monitor over the host's flap-window timings. The host passes readers of its
/// current, lock-guarded values, so a reload's new timings reach the monitor without a restart.
package typealias RuntimeVPNStatusMonitorFactory = @Sendable (
    _ graceSeconds: @escaping @Sendable () -> TimeInterval,
    _ minVisibleSeconds: @escaping @Sendable () -> TimeInterval
) -> any VPNStatusObserving

/// The machine-facing effects one `RuntimeHost` runs against, and the recovery that runs without
/// one (decision 0033).
///
/// Every field is required. A caller names each adapter, so no production adapter is chosen by
/// omitting an argument. Production selects the real adapters in `ConduitDaemon`. Simulator and
/// test assembly select fakes and owned scratch paths. Pure limits and schedules are not here.
package struct RuntimeHostEffects {
    /// Builds the privilege adapters over the caller's event sink.
    package let privilege: RuntimePrivilegeAdaptersFactory
    /// The saved-password store. Production is the login Keychain.
    package let credentials: any SecretStore
    package let kerberosTicketRecovery: any KerberosTicketRecovering
    package let gss: RuntimeGSSSource
    /// PAC fetch and evaluation (CFNetwork in production).
    package let pacEvaluator: any PacEvaluator
    /// Names the process holding a port that failed to bind (`libproc` in production).
    package let portHolderProbe: any ListenerPortHolderProbing
    /// Whether a listener serves a loopback port. The system proxy's stale-listener check asks it at launch recovery and before a restore;
    /// production connects to the real port (`LoopbackPortProbe`), and a test or simulator answers from its own fake.
    package let loopbackPortProbe: @Sendable (Int) -> Bool
    /// The subprocess runner behind the `networksetup` and `launchctl` managers.
    package let commandRunner: @Sendable (String, [String]) throws -> CommandResult
    /// Whether a resolver answers on a local port: the system DNS liveness check.
    package let dnsResponds: @Sendable (Int) -> Bool
    package let networkPath: any NetworkPathObserving
    package let networkLocation: any NetworkLocationObserving
    package let networkLocationStoreFactory: @Sendable (any PrivilegeClient) -> (any NetworkLocationStoring)?
    package let vpnStatusMonitor: RuntimeVPNStatusMonitorFactory
    /// The system wake source, observed from open until the quit. The daemon names the inert adapter; the app composition names the
    /// workspace adapter, so this target imports no AppKit.
    package let wake: any SystemWakeObserving
    /// The user's home, where the shell profiles are edited. Production is the real home; a
    /// simulator passes a scratch home.
    package let homeDirectory: URL
    /// The resolver directory. Production is `/etc/resolver`; a simulator passes a scratch directory.
    package let resolverDirectory: String
    /// The configuration files' byte access, behind the store that reads and replaces them (decision 0033). Production is the OS
    /// adapter; a test or simulator passes the in-memory fake or the OS adapter over an owned scratch root.
    package let stateFiles: any StateFileAccessing

    /// Every field is mandatory. The memberwise initializer would be internal, so the explicit one exposes it to
    /// `ConduitDaemon` and `pm-sim`, and names each adapter with no default.
    package init(
        privilege: @escaping RuntimePrivilegeAdaptersFactory,
        credentials: any SecretStore,
        kerberosTicketRecovery: any KerberosTicketRecovering,
        gss: RuntimeGSSSource,
        pacEvaluator: any PacEvaluator,
        portHolderProbe: any ListenerPortHolderProbing,
        loopbackPortProbe: @escaping @Sendable (Int) -> Bool,
        commandRunner: @escaping @Sendable (String, [String]) throws -> CommandResult,
        dnsResponds: @escaping @Sendable (Int) -> Bool,
        networkPath: any NetworkPathObserving,
        networkLocation: any NetworkLocationObserving,
        networkLocationStoreFactory: @escaping @Sendable (any PrivilegeClient) -> (any NetworkLocationStoring)?,
        vpnStatusMonitor: @escaping RuntimeVPNStatusMonitorFactory,
        wake: any SystemWakeObserving,
        homeDirectory: URL,
        resolverDirectory: String,
        stateFiles: any StateFileAccessing
    ) {
        self.privilege = privilege
        self.credentials = credentials
        self.kerberosTicketRecovery = kerberosTicketRecovery
        self.gss = gss
        self.pacEvaluator = pacEvaluator
        self.portHolderProbe = portHolderProbe
        self.loopbackPortProbe = loopbackPortProbe
        self.commandRunner = commandRunner
        self.dnsResponds = dnsResponds
        self.networkPath = networkPath
        self.networkLocation = networkLocation
        self.networkLocationStoreFactory = networkLocationStoreFactory
        self.vpnStatusMonitor = vpnStatusMonitor
        self.wake = wake
        self.homeDirectory = homeDirectory
        self.resolverDirectory = resolverDirectory
        self.stateFiles = stateFiles
    }
}
