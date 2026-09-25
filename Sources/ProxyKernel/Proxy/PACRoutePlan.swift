// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What a PAC decision means for one request, shared by the HTTP, CONNECT and
/// SOCKS5 listeners so they cannot drift apart (#50).
///
/// | PAC answer                                  | Plan                                   |
/// |---------------------------------------------|----------------------------------------|
/// | not consulted (PAC off, forced, direct mode)| `.noOpinion`: the listener's own rules |
/// | first usable entry `DIRECT`, as written     | `.direct`                              |
/// | usable `PROXY` entries                      | `.proxies`; a later `DIRECT` is a      |
/// |                                             | fallback only where fallback is allowed|
/// | `DIRECT` promoted by removing rejected ones | `.direct` if fallback is allowed, else |
/// |                                             | the rest of the chain without it       |
/// | no usable answer                            | `.upstreamsOnly`: configured upstreams,|
/// |                                             | no reachability shortcut, no fallback  |
package enum PACRoutePlan: Equatable {
    /// PAC has no say. The listener applies its own rules, including (outside
    /// strict mode) the HTTP listener's direct-reachability shortcut.
    case noOpinion
    /// Route DIRECT.
    case direct
    /// Route through these PAC proxies in order. `directFallback`: a later
    /// `DIRECT` in the chain may be used after they fail.
    case proxies([UpstreamProxy], directFallback: Bool)
    /// PAC is in force but gave nothing to route by: the configured upstream
    /// pool only. Never DIRECT, never the reachability shortcut.
    case upstreamsOnly(PACNoUsableReason, rejected: [PACRejectedEntry])

    /// - Parameter directFallbackAllowed: `HTTPProxyHandler.directFallbackAllowed`
    ///   for the current mode: outside strict mode, or in an unconditional
    ///   direct state.
    package init(decision: PACDecision, config: ProxyConfig, directFallbackAllowed: Bool) {
        switch decision {
        case .notConsulted:
            self = .noOpinion
        case .noUsableAnswer(let reason, let rejected):
            self = .upstreamsOnly(reason, rejected: rejected)
        case .routes(let chain):
            if chain.routes.first == .direct {
                if !chain.leadingDirectPromoted || directFallbackAllowed {
                    self = .direct
                    return
                }
                // A promoted DIRECT is a suppressed fallback here. Whatever
                // follows it is still the script's chain, minus its DIRECTs.
                let proxies = Self.proxyChain(from: chain.routes, config: config)
                self = proxies.isEmpty
                    ? .upstreamsOnly(PACNoUsableReason.forRejected(chain.rejected), rejected: chain.rejected)
                    : .proxies(proxies, directFallback: false)
                return
            }
            self = .proxies(
                Self.proxyChain(from: chain.routes, config: config),
                directFallback: directFallbackAllowed && chain.routes.contains(.direct)
            )
        }
    }

    /// The PAC proxies to try first, in order; empty unless `.proxies`.
    package var proxyChain: [UpstreamProxy] {
        if case .proxies(let chain, _) = self { return chain }
        return []
    }

    package var hasDirectFallback: Bool {
        if case .proxies(_, let fallback) = self { return fallback }
        return false
    }

    /// Whether the HTTP listener's direct-reachability shortcut may route
    /// this request DIRECT: only when PAC has no say and strict mode is off
    /// (#87). Never for a PAC answer, usable or not (#50).
    package func allowsReachabilityShortcut(strictMode: Bool) -> Bool {
        self == .noOpinion && !strictMode
    }

    /// PAC `PROXY` entries as upstreams. An entry that names a configured
    /// upstream is that upstream (its credentials and settings); any other is
    /// a dynamic, credential-less upstream. Only `.proxy` routes are used.
    package static func proxyChain(from routes: [PACRoute], config: ProxyConfig) -> [UpstreamProxy] {
        routes.enumerated().compactMap { index, route in
            guard case .proxy(let host, let port) = route else { return nil }
            if let configured = config.enabledUpstreams.first(where: {
                $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
            }) {
                return configured
            }
            return UpstreamProxy(
                name: "PAC \(host):\(port)",
                host: host,
                port: port,
                priority: index
            )
        }
    }
}
