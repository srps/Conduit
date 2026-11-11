// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// What a host gives the DNS forwarder so DoH can reach a provider through an
/// upstream proxy whatever the client routing rules say (decision 0045).
package struct DoHUpstreamRouteSource: Sendable {
    let pool: ConnectionPool
    let coordinator: CONNECTCoordinator
    let offered: @Sendable () -> Bool

    /// - Parameters:
    ///   - pool: the route's own, shared with no other traffic: what DoH
    ///     learns about an upstream must not move anything else, and the
    ///     route closes the pool's connections when it stops.
    ///   - coordinator: dials the upstream through `pool`, answers its 407
    ///     with Conduit's own authenticator and fails over.
    ///   - offered: false while the host has decided upstreams are out of
    ///     play and dials none, so lookups do not dial one either.
    package init(pool: ConnectionPool, coordinator: CONNECTCoordinator, offered: @escaping @Sendable () -> Bool = { true }) {
        self.pool = pool
        self.coordinator = coordinator
        self.offered = offered
    }
}

/// The DoH upstream route: a loopback SOCKS listener on an ephemeral port that
/// the DoH sessions name as their proxy.
///
/// The client listener applies PAC, bypass entries and direct mode, so when
/// those say DIRECT for a provider its tunnel goes direct, and under a
/// full-tunnel VPN that drops direct 443 every DoH route is then a black hole.
/// This listener has no such rules. It tunnels through an upstream or fails.
///
/// SOCKS, not an HTTP proxy: CFNetwork offers a SOCKS proxy no credentials
/// and gets no HTTP response from it, so this hop cannot hand macOS a proxy
/// challenge, and it carries a provider of either scheme.
///
/// It admits a connection only to a configured provider's host and port. The
/// client listener already tunnels anywhere for a local process, but through
/// the routing rules; this one skips them, so it is kept to DoH.
final class DoHUpstreamRoute: Sendable {
    /// Connections the listener holds at once. A lookup opens at most a few
    /// per provider and the forwarder admits 64 lookups, most of which share
    /// kept-alive connections.
    static let maximumConnections = 64

    private let source: DoHUpstreamRouteSource
    private let logger: any LogSink
    private let server: SOCKS5Server
    private let boundPort = NIOLockedValueBox<Int?>(nil)

    init(
        source: DoHUpstreamRouteSource,
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        // Exposed only so a test can move the clock its events are limited by.
        eventGate: RuntimeEventRepeatGate = RuntimeEventRepeatGate()
    ) {
        self.source = source
        self.logger = logger
        nonisolated(unsafe) let configProvider = configProvider
        // At most one of each event a minute for each key: a failing upstream would otherwise report on every lookup.
        let report: @Sendable (String, String, String, LogLevel) -> Void = { name, key, detail, level in
            guard let suppressed = eventGate.admit(host: key, reason: name) else { return }
            let event = RuntimeEvent(kind: .routing, event: name, detail: "\(detail) suppressed=\(suppressed)")
            eventSink?(event)
            logger.log(level, "DNS: \(event.event) \(event.detail ?? "")", category: .network)
        }
        self.server = SOCKS5Server(
            group: group,
            connectCoordinator: source.coordinator,
            logger: logger,
            directModeProvider: { (false, .none) },
            pacRoutingEngine: nil,
            configProvider: configProvider,
            gatewayMode: false,
            inboundBudget: InboundConnectionBudget(fixedLimit: Self.maximumConnections),
            routing: .upstreamOnly(SOCKS5UpstreamOnlyRoute(
                authority: { host, port in
                    DoHSessionFactory.providerAuthority(host: host, port: port, config: configProvider())
                },
                // Every refusal shares one key. Keyed by target, a process that asks for a new name each time would get an
                // event for each and push the gate's other entries out. The target is whatever a local process sent.
                refused: { target in
                    report("dns.doh_upstream_route_refused", "", "target=\(target) reason=not_a_doh_provider", .warning)
                },
                // These targets are the providers' own authorities from the config, never a client's spelling, so they are few.
                opened: { target, upstream in
                    report("dns.doh_upstream_route_used", target, "target=\(target) upstream=\(upstream)", .info)
                },
                failed: { target, error in
                    report("dns.doh_upstream_route_failed", target, "target=\(target) error=\(error.displayDescription)", .info)
                }
            )),
            eventSink: eventSink
        )
    }

    func start() async throws {
        try await server.start(host: "127.0.0.1", port: 0)
        boundPort.withLockedValue { $0 = server.listeningPort }
    }

    /// Closes the listener, every connection it accepted, and what is left
    /// in the route's pool: a tunnel still in its CONNECT handshake has no
    /// client to go back to.
    func stop() async {
        boundPort.withLockedValue { $0 = nil }
        let accepted = await server.stop()
        let pooled = source.pool.closeAll()
        logger.log(
            .info,
            "DoH upstream route stopped: closed \(accepted) accepted connection(s) and \(pooled) upstream connection(s) its pool still held.",
            category: .network
        )
    }

    var listeningPort: Int? { boundPort.withLockedValue { $0 } }

    /// The port lookups may dial now: nil while unbound, and while the host
    /// is not offering the route.
    var offeredPort: Int? { source.offered() ? listeningPort : nil }
}
