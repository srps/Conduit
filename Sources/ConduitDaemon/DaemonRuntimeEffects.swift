// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyAuth
import ProxyKernel
import ProxyPAC
import ConduitRuntime

extension RuntimeHostEffects {
    /// The production adapters, selected here at the daemon's entry boundary (decision 0033). The helper, the
    /// login Keychain, system Kerberos, the live network observers, CFNetwork PAC, the `libproc` port-holder probe,
    /// the loopback listener probe, and the `networksetup` and `launchctl` runner are the real ones; the resolver directory is `/etc/resolver`.
    ///
    /// Built after the state root is taken (and after the help and worker early exits), and used for both the host
    /// and the config-less recovery, so the two paths share one selection. `RuntimeHost` never names these
    /// adapters itself.
    static func production(homeDirectory: URL) -> RuntimeHostEffects {
        RuntimeHostEffects(
            // One helper client, built over the caller's event sink and used as both the client and the status source.
            privilege: { eventSink in
                let helper = HelperToolPrivilegeClient(eventSink: eventSink)
                return RuntimePrivilegeAdapters(client: helper, helperStatus: helper)
            },
            credentials: KeychainStore(),
            kerberosTicketRecovery: SystemKerberosTicketRecovery(),
            // `.system`: the factory's own GSS construction, over the host's Kerberos recovery and event sink.
            gss: .system,
            pacEvaluator: CFPACEvaluator(),
            portHolderProbe: PortHolderProbe(),
            loopbackPortProbe: { LoopbackPortProbe.isServed(port: $0) },
            commandRunner: CommandRunner.host,
            dnsResponds: { SystemDNSManager.dnsResponds(onPort: $0) },
            networkPath: NetworkMonitor(debounceInterval: NetworkMonitor.defaultDebounceInterval),
            networkLocation: NetworkLocationMonitor(),
            networkLocationStoreFactory: { SystemNetworkLocationStore(privilegeClient: $0) },
            vpnStatusMonitor: { graceSeconds, minVisibleSeconds in
                VPNStatusMonitor(graceSecondsProvider: graceSeconds, minVisibleSecondsProvider: minVisibleSeconds)
            },
            // The daemon has no workspace session, so it hears no wake; the app composition will name the workspace adapter.
            wake: InertSystemWakeObserver(),
            homeDirectory: homeDirectory,
            resolverDirectory: "/etc/resolver",
            // The configuration files' byte access, the OS adapter over the resolved state root (decision 0033).
            stateFiles: StateFileAccess.operatingSystem()
        )
    }
}
