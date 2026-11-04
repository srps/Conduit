// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Where clients must reach this runtime: the endpoints the system proxy, the
/// shell profiles and the launchd environment advertise (#251).
///
/// Not the stored configuration. `ProxyConfig.localPort` is intent, and `0`
/// there means "choose a port": the listener binds an ephemeral one, and a
/// client pointed at port 0 reaches nothing. The writers take this value
/// beside the configuration and read the advertised endpoint only from it, so
/// stored intent and the endpoint clients use cannot be confused, and a host
/// builds it in one place (`applied(config:bindings:)`) for every writer:
/// Start, config reapply, repair and location reconciliation alike.
package struct ClientEndpoints: Sendable, Equatable {
    /// The host clients connect to. The configured client host, never the
    /// listener's: a gateway listener binds a wildcard no client can dial.
    package var proxyHost: String
    package var proxyPort: Int
    /// The local PAC server's URL while it is serving; nil otherwise.
    package var localPACURL: String?

    package init(proxyHost: String, proxyPort: Int, localPACURL: String? = nil) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.localPACURL = localPACURL
    }

    /// The endpoints a running proxy advertises: the configured client host,
    /// the port the listener actually holds, and the local PAC server's URL.
    /// With no proxy listener bound it falls back to the configured port,
    /// which is what every surface wrote before #251; the hosts write these
    /// surfaces only while the proxy is up.
    package static func applied(config: ProxyConfig, bindings: ProxyOrchestratorBindings) -> ClientEndpoints {
        ClientEndpoints(
            proxyHost: config.effectiveClientHost,
            proxyPort: bindings.proxyPort ?? config.localPort,
            localPACURL: bindings.localPACURL
        )
    }

    /// The configured endpoints, with no listener to resolve them against:
    /// the activation preflight's question, and a fixture's.
    package static func configured(_ config: ProxyConfig, localPACURL: String? = nil) -> ClientEndpoints {
        ClientEndpoints(proxyHost: config.effectiveClientHost, proxyPort: config.localPort, localPACURL: localPACURL)
    }

    /// `host:port`, bracketing an IPv6 literal.
    package var proxyAuthority: String {
        let host = proxyHost.contains(":") && !proxyHost.hasPrefix("[") ? "[\(proxyHost)]" : proxyHost
        return "\(host):\(proxyPort)"
    }

    /// The `HTTP(S)_PROXY` value.
    package var proxyURL: String { "http://\(proxyAuthority)" }
}
