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
    }
}
