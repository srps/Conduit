// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Builds the `URLSession`s that DoH lookups run over, and the set of network
/// routes worth trying for one.
///
/// Shared by `LocalDNSForwarder`'s long-lived `DoHTransports` and
/// `DoHOriginResolver`'s per-lookup sessions. Those two differ in session
/// *lifetime* — deliberately, see their type docs — but not in how a session is
/// configured, and the proxy dictionary in particular is fiddly enough
/// (CFNetwork wants the typed keys *and* the bare `"HTTPSProxy"` strings) that a
/// second copy would drift from the first.
enum DoHSessionFactory {
    static let requestTimeout: TimeInterval = 4

    /// A network route to a DoH provider. `nil` proxy means "dial directly".
    struct Route: Sendable {
        let proxy: (host: String, port: Int)?
    }

    /// The routes to a public resolver, in the order they are worth trying.
    ///
    /// Direct first, because on an unrestricted network it is the fastest and
    /// involves no third party. But direct is also the route that dies first:
    /// under a full-tunnel VPN, outbound 443 to a public resolver is commonly
    /// dropped outright, and on a split-DNS corporate network the provider's
    /// own hostname may not resolve. The proxied routes are what keep DoH
    /// working there — the corporate upstream because it is the sanctioned way
    /// out, and Conduit's own listener because it applies the upstream's
    /// authentication on our behalf.
    ///
    /// Callers race all of these concurrently, so the order is a tiebreak among
    /// simultaneous successes rather than a sequence of fallbacks.
    static func routes(for config: ProxyConfig) -> [Route] {
        var routes = [Route(proxy: nil)]
        if let upstream = config.enabledUpstreams.first {
            routes.append(Route(proxy: (upstream.host, upstream.port)))
        }
        routes.append(Route(proxy: (config.localHost, config.localPort)))
        return routes
    }

    /// - Important: `connectionProxyDictionary` is always set explicitly, never
    ///   left nil. Nil inherits the *system* proxy settings, which on a
    ///   configured machine point at Conduit's own listener — the DoH
    ///   lookup would then be silently proxied through the process trying to
    ///   perform it. `Route(proxy: nil)` means explicitly direct.
    static func session(for route: Route, timeout: TimeInterval = requestTimeout) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.connectionProxyDictionary = route.proxy.map {
            proxyDictionary(host: $0.host, port: $0.port)
        } ?? [:]
        return URLSession(configuration: configuration)
    }

    static func proxyDictionary(host: String, port: Int) -> [String: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFProxyTypeHTTPS as String: true,
            "HTTPSProxy" as String: host,
            "HTTPSPort" as String: port,
        ]
    }
}
