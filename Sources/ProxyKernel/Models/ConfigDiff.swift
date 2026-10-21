// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct ConfigDiff: Sendable {
    package let proxyChanged: Bool
    package let authChanged: Bool
    package let upstreamsChanged: Bool
    /// Routing inputs other than `pacUsableRouteLimit`, which is applied
    /// when each PAC answer is handed out and needs no PAC refresh.
    package let routingChanged: Bool
    package let pacRouteLimitChanged: Bool
    package let dnsChanged: Bool
    package let tunnelsChanged: Bool
    package let healthChanged: Bool
    package let loggingChanged: Bool
    /// Local listener replacement rebuilds its PAC at startup. Other local
    /// PAC policy changes can update the existing endpoint once after reload.
    package let proxyListenerChanged: Bool
    package let localPACChanged: Bool
    /// The bypass list, which the managed shell environment (`NO_PROXY`)
    /// and manual-mode system proxy (`ExceptionsList`) advertise to other
    /// programs. Part of `routingChanged`; this names the surfaces it
    /// reaches beyond the kernel (#175).
    package let advertisedBypassChanged: Bool
    /// The served browser PAC endpoint starts, stops or moves.
    package let localPACEndpointChanged: Bool
    /// A tunnel listener starts, stops or is replaced; see
    /// `TunnelDefinition.listenersDiffer`.
    package let tunnelListenersChanged: Bool

    /// Whether applying this diff would start, stop or replace a bound
    /// endpoint: the HTTP/SOCKS listener, the DNS forwarder and transparent
    /// proxy (restarted for any DNS section change), the local PAC server
    /// or a tunnel. The Settings editor holds
    /// such an edit until it is committed, so a half-typed port is never
    /// bound. Read from the same fields the runtime acts on, so a field
    /// the runtime starts rebinding for is held without a second list.
    package var replacesListeners: Bool {
        proxyListenerChanged || dnsChanged || localPACEndpointChanged || tunnelListenersChanged
    }

    package var hasChanges: Bool {
        proxyChanged || authChanged || upstreamsChanged || routingChanged || pacRouteLimitChanged
            || dnsChanged || tunnelsChanged || healthChanged || loggingChanged
    }

    package init(old: ProxyConfig, new: ProxyConfig) {
        proxyChanged = old.proxy != new.proxy
        authChanged = old.auth != new.auth
        upstreamsChanged = old.upstreams != new.upstreams
        var oldRouting = old.routing
        oldRouting.pacUsableRouteLimit = new.routing.pacUsableRouteLimit
        routingChanged = oldRouting != new.routing
        pacRouteLimitChanged = old.routing.pacUsableRouteLimit != new.routing.pacUsableRouteLimit
        dnsChanged = old.dns != new.dns
        tunnelsChanged = old.tunnels != new.tunnels
        healthChanged = old.health != new.health
        loggingChanged = old.logging != new.logging
        proxyListenerChanged = old.proxy.host != new.proxy.host
            || old.proxy.port != new.proxy.port
            || old.proxy.gatewayMode != new.proxy.gatewayMode
            || old.proxy.socksEnabled != new.proxy.socksEnabled
            || old.proxy.socksPort != new.proxy.socksPort
        advertisedBypassChanged = old.routing.noProxyHosts != new.routing.noProxyHosts
        localPACEndpointChanged = old.routing.localPACEnabled != new.routing.localPACEnabled
            || old.routing.localPACPort != new.routing.localPACPort
        tunnelListenersChanged = TunnelDefinition.listenersDiffer(old.tunnels.definitions, new.tunnels.definitions)
        localPACChanged = routingChanged
            || old.proxy.strictMode != new.proxy.strictMode
            || old.enabledUpstreams.isEmpty != new.enabledUpstreams.isEmpty
    }
}
