// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct ConfigDiff: Sendable {
    package let proxyChanged: Bool
    package let authChanged: Bool
    package let upstreamsChanged: Bool
    package let routingChanged: Bool
    package let dnsChanged: Bool
    package let tunnelsChanged: Bool
    package let healthChanged: Bool
    package let loggingChanged: Bool
    /// Local listener replacement rebuilds its PAC at startup. Other local
    /// PAC policy changes can update the existing endpoint once after reload.
    package let proxyListenerChanged: Bool
    package let localPACChanged: Bool

    package var hasChanges: Bool {
        proxyChanged || authChanged || upstreamsChanged || routingChanged
            || dnsChanged || tunnelsChanged || healthChanged || loggingChanged
    }

    package init(old: ProxyConfig, new: ProxyConfig) {
        proxyChanged = old.proxy != new.proxy
        authChanged = old.auth != new.auth
        upstreamsChanged = old.upstreams != new.upstreams
        routingChanged = old.routing != new.routing
        dnsChanged = old.dns != new.dns
        tunnelsChanged = old.tunnels != new.tunnels
        healthChanged = old.health != new.health
        loggingChanged = old.logging != new.logging
        proxyListenerChanged = old.proxy.host != new.proxy.host
            || old.proxy.port != new.proxy.port
            || old.proxy.gatewayMode != new.proxy.gatewayMode
            || old.proxy.socksEnabled != new.proxy.socksEnabled
            || old.proxy.socksPort != new.proxy.socksPort
        localPACChanged = routingChanged
            || old.proxy.strictMode != new.proxy.strictMode
            || old.enabledUpstreams.isEmpty != new.enabledUpstreams.isEmpty
    }
}
