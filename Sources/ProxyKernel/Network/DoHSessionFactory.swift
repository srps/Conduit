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

    /// A network route to a DoH provider.
    enum Route: Sendable, Equatable {
        /// Dial the provider directly.
        case direct
        /// Conduit's client listener, an HTTP proxy. It applies the client
        /// routing rules, so it may itself go direct.
        case clientListener(host: String, port: Int)
        /// The forwarder's upstream route, a loopback SOCKS listener that only
        /// ever tunnels through an upstream proxy (decision 0045).
        case upstream(port: Int)
    }

    /// The routes to a public resolver, in the order they are worth trying.
    ///
    /// Direct first, because on an unrestricted network it is the fastest and
    /// involves no third party. But direct is also the route that dies first:
    /// under a full-tunnel VPN, outbound 443 to a public resolver is commonly
    /// dropped outright, and on a split-DNS corporate network the provider's
    /// own hostname may not resolve. The client listener goes direct too when
    /// its rules say so, which is why the upstream route exists.
    ///
    /// Callers race all of these concurrently, so the order is a tiebreak among
    /// simultaneous successes rather than a sequence of fallbacks.
    static func routes(for config: ProxyConfig, localProxyPort: Int?, upstreamRoutePort: Int?) -> [Route] {
        var routes = [Route.direct]
        if let local = localProxyRoute(config: config, boundPort: localProxyPort) {
            routes.append(local)
        }
        if let upstream = upstreamRoute(config: config, boundPort: upstreamRoutePort) {
            routes.append(upstream)
        }
        return routes
    }

    static func localProxyRoute(config: ProxyConfig, boundPort: Int?) -> Route? {
        let port = config.clientProxyPort(bound: boundPort)
        guard port != 0 else { return nil }
        return .clientListener(host: config.effectiveClientHost, port: port)
    }

    /// Nil without a bound listener, and nil when no upstream is enabled: the
    /// listener would have nothing to tunnel through.
    static func upstreamRoute(config: ProxyConfig, boundPort: Int?) -> Route? {
        guard let boundPort, !config.enabledUpstreams.isEmpty else { return nil }
        return .upstream(port: boundPort)
    }

    /// The upstream route carries a connection only to a configured provider's
    /// own host and port. Anything else a local process asks it for is refused,
    /// so the route lends Conduit's proxy identity to DoH and nothing else.
    static func isProviderEndpoint(host: String, port: Int, config: ProxyConfig) -> Bool {
        let providers = config.dohProviders.isEmpty ? DNSSection.defaultDoHProviders : config.dohProviders
        return providers.contains { provider in
            guard let endpoint = upstreamRouteEndpoint(of: provider) else { return false }
            return endpoint.port == port && endpoint.host == canonicalHost(host)
        }
    }

    /// Whether a lookup races the upstream route for `provider`. Not for a
    /// provider on this machine: an upstream asked for a loopback address
    /// would dial its own.
    static func upstreamRouteCarries(provider: String) -> Bool {
        upstreamRouteEndpoint(of: provider) != nil
    }

    private static func upstreamRouteEndpoint(of provider: String) -> (host: String, port: Int)? {
        guard let url = URL(string: provider), let providerHost = url.host,
              let scheme = url.scheme?.lowercased(),
              let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) else { return nil }
        let host = canonicalHost(providerHost)
        guard host != "localhost", host != "::1", !host.hasPrefix("127.") else { return nil }
        return (host, port)
    }

    /// One spelling per host, so an IPv6 literal the listener read off the
    /// wire matches the same address written compressed in a provider URL.
    private static func canonicalHost(_ host: String) -> String {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        guard inet_pton(AF_INET6, bare, &address) == 1 else { return bare.lowercased() }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return bare.lowercased() }
        return String(cString: text)
    }

    /// - Important: `connectionProxyDictionary` is always set explicitly, never
    ///   left nil. Nil inherits the *system* proxy settings, which on a
    ///   configured machine point at Conduit's own listener — the DoH
    ///   lookup would then be silently proxied through the process trying to
    ///   perform it. `.direct` means explicitly direct.
    static func session(
        for route: Route,
        delegate: ProxyChallengeRefusingDelegate,
        timeout: TimeInterval = requestTimeout
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.connectionProxyDictionary = switch route {
        case .direct: [:]
        case .clientListener(let host, let port): proxyDictionary(host: host, port: port)
        case .upstream(let port): socksProxyDictionary(port: port)
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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

    /// CFNetwork speaks SOCKS5 with no authentication to this proxy and sends
    /// it the provider's hostname unresolved, so the route has no HTTP
    /// response a 407 could arrive in.
    static func socksProxyDictionary(port: Int) -> [String: Any] {
        [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port,
        ]
    }
}
