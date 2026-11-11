// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// `start(host:port:)` was asked for any port and could not find one that was
/// free on both UDP and TCP.
package enum DNSForwarderStartError: Error, LocalizedError, Equatable {
    case noEphemeralPortPair(host: String, attempts: Int)

    package var errorDescription: String? {
        switch self {
        case .noEphemeralPortPair(let host, let attempts):
            return "DNS forwarder could not find a port on \(host) that was free on both UDP and TCP in \(attempts) attempts."
        }
    }
}

/// The forwarder's timing and the internal resolver's port. Production uses
/// the defaults; tests shorten the waits so a slow-lookup or idle-connection
/// rule is checked in milliseconds, and point the internal resolver at a
/// local socket instead of port 53.
package struct DNSForwarderTuning: Sendable {
    /// The port internal (split-DNS) servers are asked on.
    package var internalServerPort = 53
    /// Where a configured internal server is reached instead of itself on
    /// `internalServerPort`. macOS has one loopback address, so a test that
    /// needs two distinct servers maps each configured address onto its own
    /// loopback port here. Production leaves it nil.
    package var internalServerEndpoint: (@Sendable (_ server: String) -> (host: String, port: Int))?
    /// How long an internal server may take for a name under a managed
    /// domain. Its reply is the answer; only its silence goes on to DoH.
    package var internalDomainTimeout: TimeAmount = .milliseconds(2000)
    /// How long the internal attempt for any other name may take before the
    /// DoH stage begins.
    package var internalAttemptTimeout: TimeAmount = .milliseconds(1500)
    /// The most one lookup spends on its internal servers in all, however
    /// many its entry names: half the helper relay's pending window
    /// (`UDPRelay.staleTimeoutSeconds`), so the DoH race that follows
    /// silence keeps the other half, more than its request timeout. A server
    /// is asked only while a whole attempt fits what is left, and one left
    /// unasked records no silence. Each attempt keeps its own timeout.
    package var internalStageBudget: TimeAmount = .milliseconds(Int64(UDPRelay.staleTimeoutSeconds * 1000) / 2)
    /// How long a DNS-over-TCP connection with nothing outstanding may stay
    /// silent (see `DNSTCPHandler`).
    package var tcpIdleTimeout: TimeAmount = .seconds(10)

    package init() {}
}

package final class LocalDNSForwarder: @unchecked Sendable {
    /// How many ephemeral ports `start` tries before giving up. A collision
    /// needs another process to hold, on TCP, the one number the kernel just
    /// picked for UDP, so a second in a row is already unlikely.
    package static let ephemeralPairAttempts = 8

    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let splitDNSProvider: (@Sendable () -> SplitDNSTable)?
    private let preferProxyPathForDoH: @Sendable () -> Bool
    private let localProxyPort: @Sendable () -> Int?
    /// Nil where the host has no upstream pool to lend; DoH then has no upstream route.
    private let upstreamRouteSource: DoHUpstreamRouteSource?
    /// Bound by `start`, closed by `stop`. Read by lookups on other threads.
    private let upstreamRoute = NIOLockedValueBox<DoHUpstreamRoute?>(nil)
    private let onMetrics: (@Sendable () -> Void)?
    private let tuning: DNSForwarderTuning
    private let tcpMaximumConnections: Int
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let willBindTCP: @Sendable (Int) async -> Void
    private var channel: Channel?
    private var tcpChannel: Channel?
    private var tcpConnections: DNSTCPConnectionRegistry?
    /// The running resolution core. `start` and `stop` swap it while other threads read it, so the reference is behind a lock.
    private let currentCore = NIOLockedValueBox<DNSResolutionCore?>(nil)
    /// Whether the network path is satisfied, as the orchestrator last reported it (`updateNetworkPath`). Held here, not in the
    /// core, so a forwarder started while the path is down starts refusing. Satisfied until told otherwise: a host without a
    /// path observer, `pm-proxy` for one, resolves as before.
    private let pathSatisfied = NIOLockedValueBox(true)
    private var core: DNSResolutionCore? {
        get { currentCore.withLockedValue { $0 } }
        set { currentCore.withLockedValue { $0 = newValue } }
    }

    package var listeningHost: String? {
        channel?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        channel?.localAddress?.port
    }

    /// The TCP listener's port, or nil when only UDP is bound. Always equal to
    /// `listeningPort` when present — see `start(host:port:)`.
    package var tcpListeningPort: Int? {
        tcpChannel?.localAddress?.port
    }

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        // The split-DNS table each query consults. Nil reads the manual entries from `configProvider`.
        splitDNSProvider: (@Sendable () -> SplitDNSTable)? = nil,
        preferProxyPathForDoH: @escaping @Sendable () -> Bool = { false },
        localProxyPort: @escaping @Sendable () -> Int? = { nil },
        upstreamRoute: DoHUpstreamRouteSource? = nil,
        onMetrics: (@Sendable () -> Void)? = nil,
        // Exposed only so tests can drive the slow-lookup and idle rules
        // without waiting out the production timeouts.
        tuning: DNSForwarderTuning = DNSForwarderTuning(),
        // Exposed only so tests can reach the cap without opening 64 sockets.
        tcpMaximumConnections: Int = DNSTCPConnectionRegistry.defaultMaximumConnections,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil,
        // Runs between the UDP bind and the TCP bind with the port UDP got, so
        // a test can take that TCP port first and meet a real `EADDRINUSE`.
        willBindTCP: @escaping @Sendable (Int) async -> Void = { _ in }
    ) {
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.splitDNSProvider = splitDNSProvider
        self.preferProxyPathForDoH = preferProxyPathForDoH
        self.localProxyPort = localProxyPort
        self.upstreamRouteSource = upstreamRoute
        self.onMetrics = onMetrics
        self.tuning = tuning
        self.tcpMaximumConnections = tcpMaximumConnections
        self.eventSink = eventSink
        self.willBindTCP = willBindTCP
    }

    /// A UDP handler wired to a fresh resolution core, plus readers for that
    /// core's admission counters.
    ///
    /// Exposed only so a test can pin the rule that a datagram too short to be
    /// a query costs no admission slot. That rule is about work *not* done, and
    /// is invisible from outside: the handler drops the runt silently either
    /// way, and the in-flight gauge cannot show it, because a resolution
    /// admitted for a runt does nothing and returns its slot before any
    /// assertion can run. `admissionDecisionCount` is monotonic and so records
    /// the admission that a correct implementation never attempts.
    package static func makeUDPHandlerForTesting(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig
    ) -> (
        handler: any ChannelHandler & Sendable,
        inFlightQueryCount: @Sendable () -> Int,
        admissionDecisionCount: @Sendable () -> Int
    ) {
        let core = DNSResolutionCore(
            group: group,
            logger: logger,
            configProvider: configProvider,
            preferProxyPathForDoH: { false },
            localProxyPort: { nil },
            upstreamRoute: { nil },
            pathSatisfied: { true },
            onMetrics: nil,
            tuning: DNSForwarderTuning()
        )
        return (DNSUDPHandler(core: core), { core.inFlightQueryCount }, { core.admissionDecisionCount })
    }

    /// Binds UDP and TCP on the same port.
    ///
    /// Order matters: UDP binds first and TCP follows on whatever port UDP
    /// actually got. With `port: 0` — used by `pm-proxy --dns-port 0` and by
    /// the tests — binding both to 0 would land the two listeners on different
    /// ephemeral ports, and a resolver client that retried over TCP would find
    /// nothing there.
    ///
    /// An ephemeral UDP port does not reserve the TCP port of the same number,
    /// so with `port: 0` another process may already hold it. The pair is then
    /// bound again on a fresh port, up to `ephemeralPairAttempts` times, and
    /// `start` throws if none was free on both: a caller that asked for any
    /// port has no reason to settle for half a listener, and `tcpListeningPort`
    /// used to come back nil about once in a few hundred starts. A UDP port
    /// that cannot be released ends the start too, with the channel kept for
    /// `stop()`, rather than binding a second resolver beside it.
    ///
    /// On a configured port a TCP bind failure is not fatal. UDP-only is what
    /// this forwarder shipped as, and a resolver serving UDP is far more useful
    /// than one that refused to start; the failure is an event and a warning
    /// rather than thrown.
    package func start(host: String, port: Int) async throws {
        guard let host = ProxyConfig.loopbackBindHost(host) else {
            throw ConfigValidationError.conflict(description: "DNS requires a loopback bind address because it has no client allowlist.")
        }
        await startUpstreamRoute()
        let core = DNSResolutionCore(
            group: group,
            logger: logger,
            configProvider: configProvider,
            splitDNSProvider: splitDNSProvider,
            preferProxyPathForDoH: preferProxyPathForDoH,
            localProxyPort: localProxyPort,
            upstreamRoute: { [upstreamRoute] in upstreamRoute.withLockedValue { $0 } },
            pathSatisfied: { [pathSatisfied] in pathSatisfied.withLockedValue { $0 } },
            onMetrics: onMetrics,
            tuning: tuning,
            eventSink: eventSink
        )
        self.core = core

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(DNSUDPHandler(core: core))
            }
        let log = logger
        let idleTimeout = tuning.tcpIdleTimeout
        let connections = DNSTCPConnectionRegistry(
            maximumConnections: tcpMaximumConnections,
            logger: logger
        )
        tcpConnections = connections
        let tcpBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpNoDelay, value: 1)
            .childChannelInitializer { channel in
                guard connections.admit(channel) else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                channel.closeFuture.whenComplete { _ in connections.release(channel) }
                return channel.pipeline.addHandler(
                    DNSTCPHandler(core: core, logger: log, idleTimeout: idleTimeout)
                )
            }
        let attempts = port == 0 ? Self.ephemeralPairAttempts : 1
        for attempt in 1...attempts {
            let udp: Channel
            do {
                udp = try await bootstrap.bind(host: host, port: port).get()
            } catch {
                await stopUpstreamRoute()
                throw error
            }
            let actualHost = udp.localAddress?.ipAddress ?? host
            let actualPort = udp.localAddress?.port ?? port
            await willBindTCP(actualPort)
            do {
                tcpChannel = try await tcpBootstrap.bind(host: host, port: actualPort).get()
                channel = udp
                logger.log(.notice, "DNS forwarder listening on \(actualHost):\(actualPort) (UDP and TCP).", category: .network)
                return
            } catch {
                let inUse = (error as? IOError)?.errnoCode == EADDRINUSE
                guard port == 0, inUse else {
                    // A configured port, or a failure another port would not
                    // cure: serve UDP.
                    eventSink?(RuntimeEvent(
                        kind: .health,
                        event: "dns.tcp_listener_unavailable",
                        detail: "port=\(actualPort) outcome=udp_only error=\(error.displayDescription)"
                    ))
                    logger.log(
                        .warning,
                        "DNS forwarder listening on \(actualHost):\(actualPort) (UDP only) — TCP bind failed: \(error.displayDescription). Clients that retry over TCP after a truncated answer will not reach it.",
                        category: .network
                    )
                    channel = udp
                    tcpConnections = nil
                    return
                }
                do {
                    try await udp.close().get()
                } catch ChannelError.alreadyClosed {
                    // Closed under us; the port is released either way.
                } catch let closeError {
                    // The port may still be bound and answering, and a second
                    // pair beside it would be two resolvers with two caches.
                    // `stop()` keeps the channel and closes it again.
                    channel = udp
                    eventSink?(RuntimeEvent(
                        kind: .health,
                        event: "dns.listener_port_release_failed",
                        detail: "port=\(actualPort) attempt=\(attempt) error=\(closeError.displayDescription)"
                    ))
                    logger.log(
                        .error,
                        "DNS forwarder could not release UDP port \(actualPort) after its TCP port turned out to be held: \(closeError.displayDescription). Not binding another pair beside it.",
                        category: .network
                    )
                    await stopUpstreamRoute()
                    throw closeError
                }
                let last = attempt == attempts
                eventSink?(RuntimeEvent(
                    kind: .health,
                    event: last ? "dns.tcp_listener_unavailable" : "dns.listener_port_retry",
                    detail: last
                        ? "port=\(actualPort) outcome=start_failed attempts=\(attempts)"
                        : "port=\(actualPort) attempt=\(attempt) of=\(attempts) reason=tcp_port_in_use"
                ))
                logger.log(
                    last ? .error : .info,
                    "DNS forwarder got UDP port \(actualPort) but its TCP port is held by another socket (attempt \(attempt) of \(attempts)).",
                    category: .network
                )
            }
        }
        tcpConnections = nil
        self.core = nil
        core.invalidateSessions()
        await stopUpstreamRoute()
        throw DNSForwarderStartError.noEphemeralPortPair(host: host, attempts: attempts)
    }

    /// Binds the DoH upstream route before the core is built, so the first
    /// lookup already has it. A bind failure leaves the forwarder running on
    /// its other routes.
    private func startUpstreamRoute() async {
        guard let upstreamRouteSource, upstreamRoute.withLockedValue({ $0 }) == nil else { return }
        let route = DoHUpstreamRoute(
            source: upstreamRouteSource, group: group, logger: logger,
            configProvider: configProvider, eventSink: eventSink
        )
        do {
            try await route.start()
            upstreamRoute.withLockedValue { $0 = route }
        } catch {
            eventSink?(RuntimeEvent(
                kind: .health,
                event: "dns.doh_upstream_route_unavailable",
                detail: "error=\(error.displayDescription)"
            ))
            logger.log(
                .warning,
                "DNS: the DoH upstream route could not bind a loopback port (\(error.displayDescription)). Lookups use the direct and client-listener routes only.",
                category: .network
            )
        }
    }

    private func stopUpstreamRoute() async {
        let route = upstreamRoute.withLockedValue { current -> DoHUpstreamRoute? in
            defer { current = nil }
            return current
        }
        await route?.stop()
    }

    /// The port the DoH upstream route is offered on now. Nil while stopped,
    /// with no upstream enabled, and while the host is not offering it.
    package var doHUpstreamRoutePort: Int? {
        let port = upstreamRoute.withLockedValue { $0 }?.offeredPort
        return DoHSessionFactory.upstreamRoute(config: configProvider(), boundPort: port) == nil ? nil : port
    }

    package func stop() async {
        if let channel {
            _ = try? await channel.close().get()
        }
        if let tcpChannel {
            _ = try? await tcpChannel.close().get()
        }
        channel = nil
        tcpChannel = nil
        // Closing a `ServerBootstrap` channel only stops accepting; the child
        // channels it already accepted survive it, and each one holds the core
        // — so a stopped forwarder would keep answering those clients from the
        // cache, from internal DNS and from intercept rules until their idle
        // window elapsed, and a restart would briefly run two resolvers with
        // separate caches and metrics.
        if let tcpConnections {
            await tcpConnections.closeAll()
        }
        tcpConnections = nil
        core?.invalidateSessions()
        core = nil
        await stopUpstreamRoute()
        logger.log(.notice, "DNS forwarder stopped.", category: .network)
    }

    /// Discard the current DoH `URLSession`s, build fresh ones, and flush the
    /// per-domain response cache. Called from `ProxyOrchestrator.handleSystemWake()`
    /// and the VPN-recovery branches of `handleVPNStateChange()` because
    /// `URLSession`'s connection pool and per-host TCP keep-alive state survive
    /// system sleep — and in the VPN-while-asleep case those connections become
    /// pinned to a now-defunct utun route. Without this, the next DoH lookup
    /// reuses the dead socket, hits `timeoutIntervalForRequest`, returns nil
    /// for every internet hostname, and the user sees `ERR_NAME_NOT_RESOLVED`
    /// in the browser. See `docs/design-vpn-flap-resilience.md` for the
    /// broader recovery model — these `URLSession`s are NOT covered by the
    /// "Never close active upstream channels" rule (which protects user
    /// streams in `ConnectionPool`); they carry rapid-fire DNS-lookup HTTP
    /// requests where recycling is exactly what we want.
    ///
    /// No-op when the forwarder is stopped (handler is nil). Safe to call
    /// from any actor context.
    /// The port the DoH local-proxy route dials now, nil without a route or while stopped.
    var doHLocalProxyPort: Int? { core?.doHLocalProxyPort }

    /// Every DoH session the running forwarder holds; empty while stopped.
    var doHSessions: [URLSession] { core?.doHSessions ?? [] }

    package func resetUpstreamTransports(reason: String) {
        guard let core else {
            logger.log(.debug, "DNS forwarder transports reset skipped (forwarder not running). reason=\(reason)", category: .network)
            return
        }
        let cancelled = core.resetUpstreamTransports()
        logger.log(
            .notice,
            "DNS forwarder transports reset (reason=\(reason)); \(cancelled) lookup(s) in flight cancelled, internal-server circuits closed.",
            category: .network
        )
    }

    /// Records whether the network path is satisfied. While it is not, every lookup that neither an intercept rule nor the cache
    /// answers gets SERVFAIL at once instead of an internal or DoH attempt that cannot succeed and would hold its slot for the
    /// whole attempt (#292). The orchestrator calls this for every material path change it sees, running or not; the lookups
    /// already in flight are cancelled by the transports reset that follows the same change.
    package func updateNetworkPath(satisfied: Bool) {
        pathSatisfied.withLockedValue { $0 = satisfied }
    }

    /// The last path report (`updateNetworkPath`), satisfied until one arrives.
    package var networkPathSatisfied: Bool {
        pathSatisfied.withLockedValue { $0 }
    }

    /// Admitted lookups that have not released their slot. Test-only accessor, like `cachedResponseCount`.
    package var inFlightQueryCount: Int {
        core?.inFlightQueryCount ?? 0
    }

    /// Drops every cached response and keeps the transports. A network-path change resets the transports and the cache as it
    /// arrives; a query that started before it can still finish on the old transports and store its answer. Clearing again once the
    /// path has settled keeps such an answer from outliving the settle (#198); fencing the store itself is #200. Returns the entries
    /// dropped, or nil when the forwarder is not running.
    package func clearResponseCache(reason: String) -> Int? {
        guard let core else { return nil }
        let dropped = core.clearResponseCache()
        logger.log(.info, "DNS forwarder response cache cleared (reason=\(reason), entries=\(dropped)).", category: .network)
        return dropped
    }

    /// Number of cached DNS response entries. Test-only accessor — production
    /// code must not depend on the absolute count (the cache is allowed to
    /// evict opportunistically). Used to verify `resetUpstreamTransports`
    /// flushes the cache.
    package var cachedResponseCount: Int {
        core?.cachedResponseCount ?? 0
    }

    /// The running core's counters, or nil while stopped. Each start builds a new core, so these are this run's.
    var metricCounts: DNSMetricCounts? {
        core?.metricCounts
    }
}

/// One reading of a resolution core's counters.
struct DNSMetricCounts: Equatable {
    var queries: Int
    var dohFallbacks: Int
    var cacheHits: Int
}

/// Container for the DoH-fetch `URLSession` pair. Held inside a lock so we
/// can atomically swap it on `resetUpstreamTransports()` without racing with
/// in-flight DoH requests reading the sessions in `resolveViaDoH`.
private struct DoHTransports: @unchecked Sendable {
    // NEVER call `invalidate()` while a DoH fetch may still be using these
    // sessions: `URLSession.data(for:)` on an invalidated session raises an
    // Objective-C `NSInvalidArgumentException` from CFNetwork
    // (`taskForClassInfo:`) that Swift cannot catch — the process aborts
    // (observed as the 2026-07-01 SIGABRT). All invalidation goes through
    // `DoHTransportsHandle`, which defers it until in-flight uses drain.
    let direct: URLSession
    let localProxy: URLSession?
    let localProxyPort: Int?
    /// Built whenever the upstream route's listener is bound. Whether a
    /// lookup may use it is decided per lookup, in `sessions`.
    let upstream: URLSession?

    init(config: ProxyConfig, boundPort: Int?, upstreamRoutePort: Int?, delegate: ProxyChallengeRefusingDelegate) {
        self.direct = DoHSessionFactory.session(for: .direct, delegate: delegate)
        let localRoute = DoHSessionFactory.localProxyRoute(config: config, boundPort: boundPort)
        if case .clientListener(_, let port) = localRoute { self.localProxyPort = port } else { self.localProxyPort = nil }
        self.localProxy = localRoute.map { DoHSessionFactory.session(for: $0, delegate: delegate) }
        self.upstream = upstreamRoutePort.map { DoHSessionFactory.session(for: .upstream(port: $0), delegate: delegate) }
    }

    var all: [URLSession] { [direct, localProxy, upstream].compactMap { $0 } }

    func invalidate() {
        for session in all { session.invalidateAndCancel() }
    }

    /// On VPN, direct HTTPS to public DoH resolvers is often black-holed, so
    /// the proxied routes come first. The order only breaks ties: every
    /// session returned is raced.
    func sessions(preferProxyPath: Bool, upstreamOffered: Bool) -> [URLSession] {
        let proxied = [upstreamOffered ? upstream : nil, localProxy].compactMap { $0 }
        return preferProxyPath ? proxied + [direct] : [direct] + proxied.reversed()
    }
}

/// Why every provider failed, as far as one lookup could see. The warning
/// repeats at once when this changes and at most every 5 s while it holds.
struct DoHFailureSignature: Equatable {
    let statuses: [Int]
    /// A proxy on one of the routes asked for authentication and the session
    /// cancelled the request (`auth.proxy_challenge_refused`).
    let proxyChallengeRefused: Bool

    var explanation: String {
        let refusal = "a proxy on the route asked for authentication and Conduit refused the challenge instead of asking macOS for a credential (auth.proxy_challenge_refused names the proxy)"
        let advice = "Public names cannot be resolved until a reachable provider is configured (IP-literal endpoints avoid both failure modes)."
        switch (statuses.isEmpty, proxyChallengeRefused) {
        case (true, true):
            return "\(refusal), and no other route got an HTTP response. Public names cannot be resolved until a route to a provider works without that proxy."
        case (true, false):
            return "no HTTP response at all — the providers were unreachable, timed out, or their hostnames did not resolve. \(advice)"
        case (false, let refused):
            let answered = "every attempt that got a response answered HTTP \(statuses.map(String.init).joined(separator: "/")) instead of a DNS payload, which is what a DoH-blocking proxy looks like"
            return refused ? "\(answered); also, \(refusal). \(advice)" : "\(answered). \(advice)"
        }
    }
}

/// Reference-counted lifecycle guard around a `DoHTransports` value.
///
/// Invariant: `transports.invalidate()` runs exactly once, and only when the
/// handle is retired AND no `beginUse()`/`endUse()` window is open. This is
/// what makes `resetUpstreamTransports()` safe to call concurrently with
/// in-flight DoH queries — the old sessions stay valid until the last query
/// that snapshotted them finishes (bounded by the sessions' own 4 s request /
/// 8 s resource timeouts), then get invalidated by whichever side closes the
/// window last. Fresh queries never see a retired handle's sessions because
/// `beginUse()` refuses once retired.
private final class DoHTransportsHandle: @unchecked Sendable {
    let transports: DoHTransports
    private let lock = NSLock()
    private var activeUses = 0
    private var retired = false

    init(transports: DoHTransports) {
        self.transports = transports
    }

    /// Opens a use window. Returns false when the handle has been retired —
    /// the caller must re-read the current handle (or give up) instead of
    /// touching `transports`.
    func beginUse() -> Bool {
        lock.withLock {
            guard !retired else { return false }
            activeUses += 1
            return true
        }
    }

    /// Closes a use window. Runs the deferred invalidation if this was the
    /// last open window on a retired handle.
    func endUse() {
        let invalidateNow: Bool = lock.withLock {
            activeUses -= 1
            return retired && activeUses == 0
        }
        if invalidateNow {
            transports.invalidate()
        }
    }

    /// Marks the handle retired. Invalidates immediately when idle; otherwise
    /// the last `endUse()` performs the invalidation. Idempotent.
    func retire() {
        let invalidateNow: Bool = lock.withLock {
            guard !retired else { return false }
            retired = true
            return activeUses == 0
        }
        if invalidateNow {
            transports.invalidate()
        }
    }
}

/// The query→response engine, independent of how the query arrived.
///
/// UDP and TCP are two framings of the same protocol, and everything that makes
/// an answer — intercept rules, the response cache, the internal-then-DoH
/// ladder, the DoH transports and their reset contract, the metrics counters —
/// must be *one* instance shared by both. Splitting that state per transport
/// would give a TCP retry a cold cache and its own `URLSession` pool, and would
/// make `resetUpstreamTransports` reset only half the forwarder.
///
/// `resolve(query:)` always answers when it possibly can: it returns SERVFAIL
/// rather than nil for lookups that failed, and returns nil only for a query so
/// malformed that no well-formed response can echo its question.
private final class DNSResolutionCore: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let splitDNSProvider: (@Sendable () -> SplitDNSTable)?
    private let preferProxyPathForDoH: @Sendable () -> Bool
    private let localProxyPort: @Sendable () -> Int?
    private let upstreamRoute: @Sendable () -> DoHUpstreamRoute?
    private let pathSatisfied: @Sendable () -> Bool
    private let onMetrics: (@Sendable () -> Void)?
    private let tuning: DNSForwarderTuning
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    /// Holds `dns.split_dns_doh_fallback` to one event per split-DNS domain
    /// and outcome per minute. Off the VPN every lookup under the domain
    /// falls back, and nothing caches the answer, so the event would
    /// otherwise fire on every query.
    private let splitDNSFallbackGate = RuntimeEventRepeatGate()
    /// Holds `dns.internal_server_circuit_opened` and `_closed` to one per
    /// server and direction per minute.
    private let circuitEventGate = RuntimeEventRepeatGate()
    /// Holds `dns.unsatisfied_path_servfail` to one per 5 s: a wake with no
    /// network brings a burst of lookups, and every one of them is refused.
    private let unsatisfiedPathGate = RuntimeEventRepeatGate(repeatInterval: 5)
    private let serverHealth = InternalServerHealth()
    /// A split-DNS name's DoH fallback answer is a public stand-in for an
    /// internal answer, so its TTL is cut to what the intercept path uses:
    /// once the VPN is up, the OS and browser caches let the internal answer
    /// through within seconds (decision 0043, #290).
    static let splitDNSFallbackTTL: UInt32 = 5
    private let lock = NSLock()
    private var queryCount = 0
    private var dohCount = 0
    private var cacheHitCount = 0
    /// Caps concurrent in-flight resolutions.
    ///
    /// A plain counter behind a lock, not a `DispatchSemaphore`: acquisition is
    /// a non-blocking try (an over-limit query is answered SERVFAIL, never
    /// queued), so the semaphore bought nothing, and `DispatchSemaphore.wait`
    /// is unavailable from async contexts under Swift 6 — blocking a
    /// cooperative-pool thread is exactly what it would do.
    private static let maximumInFlightQueries = 64
    private let admission = NIOLockedValueBox(AdmissionState())

    private struct AdmissionState {
        /// Admitted resolutions that have not yet released their slot, by
        /// ticket, with the task running each once `attach` has it. Bounded
        /// by `maximumInFlightQueries`.
        var inFlight: [Int: Task<Void, Never>?] = [:]
        var nextTicket = 0
        /// Advanced by every `cancelInFlightQueries`. A ticket admitted under
        /// an older generation whose task attaches afterwards is cancelled at
        /// once, so a reset between admission and attach misses nothing.
        var generation = 0
        /// Every admission decision ever taken, granted or refused. Monotonic,
        /// and that is the point: `inFlight` is a gauge, so a resolution that
        /// finishes returns it to zero and nothing downstream can tell "never
        /// admitted" from "admitted and already done". This distinguishes them.
        var decisions = 0
    }

    /// One admitted lookup's slot, from `admitQuery()` to `releaseQuery(_:)`.
    struct QueryTicket: Sendable {
        fileprivate let id: Int
        fileprivate let generation: Int
    }
    /// A DoH outage is not per-query, but the warning that reports it is: one
    /// browser page load asks for dozens of public names, and every one of them
    /// would emit its own near-identical "all providers failed" line for a
    /// single root cause. Report at most once per this interval, carrying the
    /// count suppressed since the last report — the same shape as
    /// `DNSTCPConnectionRegistry.refusalCountToReport()`.
    private static let dohFailureReportInterval: TimeInterval = 5
    private let dohFailureLock = NSLock()
    private var dohFailuresSinceLastReport = 0
    private var lastDoHFailureReport: Date?
    private var lastDoHFailureSignature: DoHFailureSignature?
    /// Swappable on `resetUpstreamTransports`. Reads via `currentHandle()`
    /// take the lock briefly, copy the reference out, release the lock —
    /// keeping the rest of the DoH path lock-free. Session invalidation is
    /// deferred through the handle's use-count (see `DoHTransportsHandle`).
    private let transportsBox: NIOLockedValueBox<DoHTransportsHandle>
    private let proxyChallengeDelegate: ProxyChallengeRefusingDelegate
    private let responseCache = DNSResponseCache()

    init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        splitDNSProvider: (@Sendable () -> SplitDNSTable)? = nil,
        preferProxyPathForDoH: @escaping @Sendable () -> Bool,
        localProxyPort: @escaping @Sendable () -> Int?,
        upstreamRoute: @escaping @Sendable () -> DoHUpstreamRoute?,
        pathSatisfied: @escaping @Sendable () -> Bool,
        onMetrics: (@Sendable () -> Void)? = nil,
        tuning: DNSForwarderTuning,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.tuning = tuning
        self.eventSink = eventSink
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.splitDNSProvider = splitDNSProvider
        self.preferProxyPathForDoH = preferProxyPathForDoH
        self.localProxyPort = localProxyPort
        self.upstreamRoute = upstreamRoute
        self.pathSatisfied = pathSatisfied
        self.onMetrics = onMetrics
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in
            eventSink?(event)
            logger.log(
                .warning,
                "DNS: refused a proxy-authentication challenge on a DoH lookup (\(event.detail ?? "")). Conduit never asks macOS for proxy credentials.",
                category: .network
            )
        }
        self.proxyChallengeDelegate = delegate
        self.transportsBox = NIOLockedValueBox(
            DoHTransportsHandle(transports: DoHTransports(
                config: configProvider(), boundPort: localProxyPort(),
                upstreamRoutePort: upstreamRoute()?.listeningPort, delegate: delegate
            ))
        )
    }

    private func currentHandle() -> DoHTransportsHandle {
        transportsBox.withLockedValue { $0 }
    }

    var doHLocalProxyPort: Int? { currentHandle().transports.localProxyPort }

    /// Every DoH session of the current transports, so a test can check each
    /// one's challenge handling before it lets a proxy answer 407.
    var doHSessions: [URLSession] { currentHandle().transports.all }

    func invalidateSessions() {
        // Retire, don't invalidate directly: a `resolveViaDoH` call that
        // snapshotted this handle may still have fetches in flight, and
        // `data(for:)` on an invalidated session aborts the process (see
        // `DoHTransports`). The handle invalidates once those drain.
        transportsBox.withLockedValue { $0 }.retire()
    }

    /// Tear down the in-flight DoH `URLSession`s, swap in fresh ones built
    /// against the latest config, and flush the response cache. The fresh
    /// sessions start with an empty TCP connection pool and an empty
    /// host-resolution cache, which is exactly what we need after a wake or
    /// VPN-route change has invalidated the old sockets. Cache flush is the
    /// belt: even though cached A records remain semantically valid across a
    /// network event, dropping them forces a fresh end-to-end probe of the
    /// DoH path on the very next query, so the user sees the recovery
    /// immediately instead of after the cached entry's TTL expires.
    ///
    /// The lookups in flight are cancelled too (#292): what they were waiting
    /// on belongs to the path that just went away, and each one held a slot
    /// for up to the internal timeout plus the DoH resource timeout. A
    /// cancelled lookup answers SERVFAIL, so the client retries on the new
    /// path. The internal-server circuits close as well: silence on the old
    /// path says nothing about the new one. Returns the lookups cancelled.
    @discardableResult
    func resetUpstreamTransports() -> Int {
        let fresh = DoHTransportsHandle(transports: DoHTransports(
            config: configProvider(), boundPort: localProxyPort(),
            upstreamRoutePort: upstreamRoute()?.listeningPort, delegate: proxyChallengeDelegate
        ))
        let old = transportsBox.withLockedValue { current -> DoHTransportsHandle in
            let captured = current
            current = fresh
            return captured
        }
        // Retire (deferred invalidate), never invalidate directly — in-flight
        // DoH fetches that snapshotted `old` finish against still-valid
        // sessions (bounded by their 4 s/8 s timeouts) and the last one out
        // invalidates. Direct invalidation here raced those fetches and
        // crashed the process with an uncatchable CFNetwork NSException.
        // Cancelling the lookups only makes those fetches finish sooner: the
        // use window closes when `resolveViaDoH` returns, as before.
        old.retire()
        responseCache.clear()
        serverHealth.reset()
        return cancelInFlightQueries()
    }

    /// Cancels every admitted lookup's task. Each one answers SERVFAIL as
    /// soon as its current attempt notices and releases its slot.
    private func cancelInFlightQueries() -> Int {
        let tasks = admission.withLockedValue { state -> [Task<Void, Never>] in
            state.generation += 1
            return state.inFlight.values.compactMap { $0 }
        }
        for task in tasks { task.cancel() }
        return tasks.count
    }

    var cachedResponseCount: Int {
        responseCache.entryCount
    }

    /// Drops every cached response; returns how many there were.
    func clearResponseCache() -> Int {
        let dropped = responseCache.entryCount
        responseCache.clear()
        return dropped
    }

    /// Non-blocking admission check. **Call this on the event loop, before
    /// spawning a resolution task**, and pair every `true` with exactly one
    /// `releaseQuery()`.
    ///
    /// The gate has to sit in front of task creation, not inside `resolve`.
    /// Under a flood, checking inside means every datagram still allocates a
    /// `Task` and captures its query buffer before being turned away, so the
    /// queue of pending rejections grows without any configured bound — the
    /// cap stops bounding the work and only bounds the concurrency of work
    /// already committed to. Gating first is what the `DispatchSemaphore` this
    /// replaced did from `channelRead`.
    func admitQuery() -> QueryTicket? {
        admission.withLockedValue { state in
            state.decisions += 1
            guard state.inFlight.count < Self.maximumInFlightQueries else { return nil }
            state.nextTicket &+= 1
            // The slot counts from here; `attach` brings the task. A reset in
            // between has nothing to cancel yet, and `attach` makes up for
            // it through the generation.
            state.inFlight.updateValue(nil, forKey: state.nextTicket)
            return QueryTicket(id: state.nextTicket, generation: state.generation)
        }
    }

    /// Registers the task resolving `ticket`'s query, so a transports reset
    /// can cancel it. A ticket already released (the task finished first) is
    /// left alone; one admitted before a reset is cancelled now.
    func attach(_ task: Task<Void, Never>, to ticket: QueryTicket) {
        let cancelNow = admission.withLockedValue { state -> Bool in
            guard state.inFlight.index(forKey: ticket.id) != nil else { return false }
            state.inFlight[ticket.id] = task
            return state.generation != ticket.generation
        }
        if cancelNow { task.cancel() }
    }

    func releaseQuery(_ ticket: QueryTicket) {
        admission.withLockedValue { _ = $0.inFlight.removeValue(forKey: ticket.id) }
    }

    /// Admitted resolutions that have not yet released their slot.
    var inFlightQueryCount: Int {
        admission.withLockedValue { $0.inFlight.count }
    }

    /// Admission decisions taken since this core was built — see
    /// `AdmissionState.decisions`.
    var admissionDecisionCount: Int {
        admission.withLockedValue { $0.decisions }
    }

    /// The answer for a query turned away by `admitQuery()`. Logs once and
    /// hands back SERVFAIL so an overloaded forwarder still answers rather
    /// than going silent — the failure mode this PR exists to remove.
    func overLimitResponse(for query: [UInt8]) -> [UInt8]? {
        let domain = DNSWireFormat.extractDomainName(from: query)
        logger.log(.warning, "DNS: query limit reached, replying SERVFAIL for \(domain).", category: .network)
        recordQuery(doh: false, cacheHit: false)
        return DNSWireFormat.emptyServerFailureResponse(originalQuery: query)
    }

    /// Total-DoH-failure count since the last report (including this one), or
    /// nil while the warning is still throttled.
    ///
    /// The observed-status set is part of the throttle key, not just the
    /// message: "nothing was reachable" and "everything answered HTTP 403" are
    /// different diagnoses, and a transition between them is exactly the moment
    /// the log has to speak. A changed signature reports immediately; an
    /// unchanged one waits out the interval.
    private func doHFailureCountToReport(signature: DoHFailureSignature) -> Int? {
        dohFailureLock.withLock {
            dohFailuresSinceLastReport += 1
            let now = Date.now
            if signature == lastDoHFailureSignature,
               let lastDoHFailureReport,
               now.timeIntervalSince(lastDoHFailureReport) < Self.dohFailureReportInterval {
                return nil
            }
            lastDoHFailureReport = now
            lastDoHFailureSignature = signature
            let failures = dohFailuresSinceLastReport
            dohFailuresSinceLastReport = 0
            return failures
        }
    }

    /// This core's counters, read together under their lock.
    var metricCounts: DNSMetricCounts {
        lock.withLock { DNSMetricCounts(queries: queryCount, dohFallbacks: dohCount, cacheHits: cacheHitCount) }
    }

    /// Counts the query, then signals that the counters moved. The signal carries no values: its reader takes the current counters
    /// when it runs, so a late signal cannot publish an older count.
    private func recordQuery(doh: Bool, cacheHit: Bool) {
        lock.withLock {
            queryCount += 1
            if doh { dohCount += 1 }
            if cacheHit { cacheHitCount += 1 }
        }
        onMetrics?()
    }

    /// Resolves one query. Never throws, and answers whenever a well-formed
    /// answer is possible — see the type doc for why nil is so narrow.
    ///
    /// The ladder, after an intercept rule and the cache: an unsatisfied
    /// network path answers SERVFAIL at once (#292); a split-DNS name asks its
    /// entry's servers in order, skipping open circuits and stopping when
    /// the next attempt would not fit `tuning.internalStageBudget`, and
    /// falls back to DoH on silence (decision 0043); any other name asks the
    /// first internal server whose circuit is closed, if there is one
    /// (#296), then DoH. A
    /// cancelled lookup (`resetUpstreamTransports`) answers SERVFAIL as soon
    /// as its attempt returns and starts no further one.
    ///
    /// - Precondition: the caller holds a slot from `admitQuery()` and releases
    ///   it with `releaseQuery(_:)` once this returns.
    func resolve(query queryBytes: [UInt8]) async -> [UInt8]? {
        guard queryBytes.count >= 12 else { return nil }

        let domain = DNSWireFormat.extractDomainName(from: queryBytes)
        let config = configProvider()
        let table = splitDNSProvider?() ?? SplitDNSTable(manual: config.dnsEntries, detected: [])
        let rule = table.rule(matching: domain)
        let isInternal = rule != nil || DNSWireFormat.isMulticastDNSName(domain)
        let queryType = DNSWireFormat.extractQueryType(from: queryBytes)
        let cacheKey = DNSCacheKey(domain: domain.lowercased(), queryType: queryType)

        if let interceptIP = matchingInterceptIP(for: domain, config: config) {
            recordQuery(doh: false, cacheHit: false)
            if let synth = DNSWireFormat.synthesizeDirectResponse(originalQuery: queryBytes, ip: interceptIP) {
                logger.log(.debug, "DNS intercept: \(domain) → \(interceptIP)", category: .network)
                return synth
            }
            // Synthesis rejects queries it cannot echo faithfully (multi-question
            // packets, malformed questions). Answering SERVFAIL beats the silent
            // drop this used to be: the client learns immediately instead of
            // waiting out its resolver timeout on a domain we deliberately own.
            logger.log(
                .warning,
                "DNS: could not synthesize an intercept answer for \(domain); replying SERVFAIL.",
                category: .network
            )
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        if !isInternal, let cachedResponse = responseCache.lookup(for: cacheKey, query: queryBytes) {
            recordQuery(doh: false, cacheHit: true)
            return cachedResponse
        }

        guard pathSatisfied() else {
            reportUnsatisfiedPath(name: domain)
            recordQuery(doh: false, cacheHit: false)
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        var response: [UInt8]?
        var usedDoH = false

        if isInternal {
            // A `.local` name under no entry is asked of the first servers,
            // as it always was; it never falls back.
            let servers = rule?.servers ?? table.firstServers
            let attempt = await askInternalServers(servers, query: queryBytes, timeout: tuning.internalDomainTimeout)
            response = attempt.response
            // Off the VPN the internal server cannot be reached, and the VPN
            // gateway's own hostname is often under a split-DNS domain: asking
            // only that server would keep the VPN from ever coming up. So
            // silence, and only silence, falls through to public DNS. Any reply
            // from the internal server, NXDOMAIN included, stays its verdict.
            // The answer is not cached (internal names never are) and its TTL
            // is clamped, so the internal server's answer wins again soon
            // after it is reachable.
            if response == nil, !Task.isCancelled,
               let rule,
               !DNSWireFormat.isMulticastDNSName(domain) {
                let doh = await resolveViaDoH(query: queryBytes, config: config)
                response = doh.response.map { DNSWireFormat.responseByClampingTTL($0, to: Self.splitDNSFallbackTTL) }
                usedDoH = doh.isProviderAnswer
                reportSplitDNSFallback(entryDomain: rule.domain, name: domain, servers: attempt.asked, outcome: doh)
            }
        } else {
            // One internal attempt for a public name, on the first server
            // whose circuit is closed. With no enabled entry there is no
            // server, and nothing to wait on (#296).
            let internalResponse = await askInternalServers(
                table.firstServers, query: queryBytes, timeout: tuning.internalAttemptTimeout, askingAtMost: 1
            ).response
            if Task.isCancelled {
                response = nil
            } else if DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: internalResponse) {
                logger.log(.debug, "DNS: \(domain) not resolved internally, trying DoH.", category: .network)
                switch await resolveViaDoH(query: queryBytes, config: config) {
                case .answered(let dohResponse):
                    // DoH found an answer. Prefer it: the corporate
                    // server's NXDOMAIN was just "I don't know about
                    // this name", not authoritative.
                    response = dohResponse
                    usedDoH = true
                case .notAsked(let refusal):
                    response = refusal ?? internalResponse
                case .cancelled:
                    response = nil
                case .unanswered:
                    // DoH failed (no providers reachable, all timed
                    // out, blocked by a filtering proxy, or the upstream
                    // proxy is down). Fall back to whatever the corporate
                    // DNS gave us — even an NXDOMAIN is a definitive
                    // answer the client can act on. Without this, the
                    // client gets no reply at all and the browser
                    // surfaces a misleading ERR_NAME_NOT_RESOLVED /
                    // DNS-timeout. The wake/VPN-recovery
                    // `resetUpstreamTransports` path exists precisely so
                    // the *next* DoH lookup succeeds; this fallback keeps
                    // the current one useful in the meantime.
                    response = internalResponse
                }
            } else {
                response = internalResponse
            }
        }

        recordQuery(doh: usedDoH, cacheHit: false)

        if Task.isCancelled {
            logger.log(.debug, "DNS: lookup for \(domain) cancelled by a transports reset; replying SERVFAIL.", category: .network)
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        guard let responseBytes = response, !responseBytes.isEmpty else {
            logger.log(.warning, "DNS: failed to resolve \(domain); replying SERVFAIL.", category: .network)
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        guard DNSWireFormat.responseQuestionMatches(query: queryBytes, response: responseBytes) else {
            // Keep this visible: a response whose question does not match the
            // query is a possible spoof, not just a failure.
            logger.log(
                .warning,
                "DNS: discarded mismatched response for \(domain); replying SERVFAIL.",
                category: .network
            )
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        if !isInternal {
            cacheResponse(responseBytes, for: cacheKey, matching: queryBytes)
        }

        return responseBytes
    }

    /// What asking the internal servers produced: the first reply, and the
    /// servers actually asked (an open circuit is skipped, not asked).
    private struct InternalAttempt {
        var response: [UInt8]?
        var asked: [String] = []
    }

    /// Asks `servers` in order until one replies, or `askingAtMost` have
    /// been asked, or the next attempt would not fit what is left of
    /// `tuning.internalStageBudget`. A server whose circuit is open is
    /// skipped, and the first lookup to skip it sends the query as a
    /// detached probe; its reply closes the circuit. Each silence counts
    /// towards the server's circuit, each reply resets it; a server the
    /// budget left unasked records nothing. Stops at a cancellation.
    private func askInternalServers(
        _ servers: [String], query: [UInt8], timeout: TimeAmount, askingAtMost: Int = .max
    ) async -> InternalAttempt {
        var attempt = InternalAttempt()
        var remaining = tuning.internalStageBudget
        var unasked: [String] = []
        for server in servers where !Task.isCancelled && attempt.asked.count < askingAtMost {
            if serverHealth.isOpen(server) {
                if let generation = serverHealth.beginProbe(server) {
                    probe(server: server, query: query, timeout: timeout, startedIn: generation)
                }
                continue
            }
            guard timeout <= remaining else {
                unasked.append(server)
                continue
            }
            attempt.asked.append(server)
            let began = NIODeadline.now()
            let response = await forwardUDP(query: query, server: server, timeout: timeout)
            remaining = remaining - (NIODeadline.now() - began)
            guard !Task.isCancelled else { return attempt }
            report(serverHealth.record(replied: response != nil, from: server), server: server)
            if let response {
                attempt.response = response
                return attempt
            }
        }
        if !unasked.isEmpty {
            logger.log(
                .debug,
                "DNS: the \(tuning.internalStageBudget.nanoseconds / 1_000_000) ms internal budget for " +
                    "\(DNSWireFormat.extractDomainName(from: query)) left no room for \(unasked.joined(separator: ",")); " +
                    "not asked, no silence counted.",
                category: .network
            )
        }
        return attempt
    }

    /// Sends `query` to a server whose circuit is open, outside the lookup
    /// that skipped it, so the lookup does not wait on it. At most one probe
    /// per server is in flight; the UDP timeout bounds it.
    private func probe(server: String, query: [UInt8], timeout: TimeAmount, startedIn generation: Int) {
        Task.detached { [self] in
            let response = await forwardUDP(query: query, server: server, timeout: timeout)
            report(serverHealth.endProbe(server, startedIn: generation, replied: response != nil), server: server)
        }
    }

    private func report(_ transition: InternalServerHealth.Transition?, server: String) {
        switch transition {
        case .opened(let silences):
            reportCircuit(server: server, event: "dns.internal_server_circuit_opened", extra: " silences=\(silences)")
        case .closed:
            reportCircuit(server: server, event: "dns.internal_server_circuit_closed", extra: "")
        case nil:
            break
        }
    }

    private func reportCircuit(server: String, event: String, extra: String) {
        let opened = event.hasSuffix("opened")
        let what = opened
            ? "DNS: internal server \(server) gave no reply \(InternalServerHealth.openAfterConsecutiveSilences) times in a row; lookups skip it until a probe is answered."
            : "DNS: internal server \(server) answered a probe; lookups ask it again."
        guard let suppressed = circuitEventGate.admit(host: server, reason: opened ? "opened" : "closed") else {
            logger.log(.debug, what, category: .network)
            return
        }
        eventSink?(RuntimeEvent(kind: .health, event: event, detail: "server=\(server)\(extra) suppressed=\(suppressed)"))
        logger.log(opened ? .warning : .notice, what, category: .network)
    }

    /// Emits `dns.unsatisfied_path_servfail` unless `unsatisfiedPathGate`
    /// holds it back, then logs the line derived from it.
    private func reportUnsatisfiedPath(name: String) {
        guard let suppressed = unsatisfiedPathGate.admit(host: "path", reason: "unsatisfied") else {
            logger.log(.debug, "DNS: no network path; replying SERVFAIL for \(name) without an attempt.", category: .network)
            return
        }
        eventSink?(RuntimeEvent(kind: .routing, event: "dns.unsatisfied_path_servfail", detail: "name=\(name) suppressed=\(suppressed)"))
        let held = suppressed > 0 ? " \(suppressed) more were refused since the last line." : ""
        logger.log(
            .info,
            "DNS: no network path; replying SERVFAIL for \(name) without an internal or DoH attempt.\(held)",
            category: .network
        )
    }

    /// Sends `query` under a fresh random transaction ID and accepts only a
    /// datagram that answers it (`DNSWireFormat.isResponse`); the reply goes
    /// back under the client's own ID. The client's ID is not ours to rely
    /// on: a predictable one would shrink what a spoofer has to guess to the
    /// ephemeral port. Datagrams that do not answer are dropped and the wait
    /// goes on, so a forgery arriving first cannot crowd out the real reply.
    ///
    /// A cancelled task gets nil at once: the socket is closed and the wait
    /// ends, so a lookup cancelled by a transports reset frees its slot
    /// without waiting out `timeout`.
    private func forwardUDP(query clientQuery: [UInt8], server: String, timeout: TimeAmount) async -> [UInt8]? {
        guard clientQuery.count >= 12, !Task.isCancelled else { return nil }
        let (host, port) = tuning.internalServerEndpoint?(server) ?? (server, tuning.internalServerPort)
        var query = clientQuery
        let wireID = UInt16.random(in: .min ... .max)
        query[0] = UInt8(wireID >> 8)
        query[1] = UInt8(wireID & 0xFF)
        let wireQuery = query
        let collector = NIOLockedValueBox<UDPResponseCollector?>(nil)
        defer {
            let discarded = collector.withLockedValue { $0?.discardedCount } ?? 0
            if discarded > 0 {
                logger.log(
                    .warning,
                    "DNS: discarded \(discarded) datagram(s) from \(server):\(port) that did not answer the query for " +
                        "\(DNSWireFormat.extractDomainName(from: clientQuery)) (possible spoof).",
                    category: .network
                )
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                    let handler = UDPResponseCollector(continuation: continuation) { DNSWireFormat.isResponse($0, to: wireQuery) }
                    collector.withLockedValue { $0 = handler }
                    // A cancellation that landed before the collector existed
                    // found nothing to cancel; it ends here instead.
                    if Task.isCancelled {
                        handler.cancel()
                        return
                    }
                    DatagramBootstrap(group: group)
                        .channelInitializer { channel in
                            channel.pipeline.addHandler(handler)
                        }
                        .connect(host: host, port: port)
                        .whenComplete { result in
                            switch result {
                            case .success(let channel):
                                var buf = channel.allocator.buffer(capacity: wireQuery.count)
                                buf.writeBytes(wireQuery)
                                if let addr = try? SocketAddress(ipAddress: host, port: port) {
                                    let envelope = AddressedEnvelope(remoteAddress: addr, data: buf)
                                    channel.writeAndFlush(envelope, promise: nil)
                                }

                                channel.eventLoop.scheduleTask(in: timeout) {
                                    handler.timeout()
                                    channel.close(promise: nil)
                                }
                            case .failure(let error):
                                // Through the collector, never the continuation
                                // itself: a cancel that landed while the connect
                                // was pending has already resumed it.
                                handler.fail(with: error)
                            }
                        }
                }
            } onCancel: {
                collector.withLockedValue { $0 }?.cancel()
            }
            return DNSWireFormat.responseByUpdatingTransactionID(response, from: clientQuery)
        } catch {
            return nil
        }
    }

    /// What the DoH stage produced for one query.
    private enum DoHOutcome {
        /// A provider answered.
        case answered([UInt8])
        /// The query type has no DoH lookup here (only A and AAAA do), so no
        /// provider was asked; `refusal` is the REFUSED reply, nil when the
        /// query cannot be echoed.
        case notAsked(refusal: [UInt8]?)
        /// Providers were asked and none answered.
        case unanswered
        /// The lookup was cancelled (a transports reset) while the providers
        /// were being asked. Not a provider failure: nothing is reported.
        case cancelled

        var response: [UInt8]? {
            switch self {
            case .answered(let response): response
            case .notAsked(let refusal): refusal
            case .unanswered, .cancelled: nil
            }
        }

        var isProviderAnswer: Bool {
            if case .answered = self { return true }
            return false
        }

        /// The `outcome=` value of `dns.split_dns_doh_fallback`; nil for a
        /// cancelled lookup, which is no fallback outcome.
        var eventOutcome: String? {
            switch self {
            case .answered: "answered"
            case .notAsked: "refused_qtype"
            case .unanswered: "unanswered"
            case .cancelled: nil
            }
        }
    }

    /// Emits `dns.split_dns_doh_fallback` unless `splitDNSFallbackGate` holds
    /// it back, then logs the line derived from it. A held-back fallback logs
    /// at debug only.
    private func reportSplitDNSFallback(entryDomain: String, name: String, servers: [String], outcome: DoHOutcome) {
        guard let outcome = outcome.eventOutcome else { return }
        let server = servers.isEmpty ? "none" : servers.joined(separator: ",")
        let silence = servers.isEmpty
            ? "no internal server was asked (every circuit open, or the entry names none)"
            : "internal server \(server) did not answer"
        guard let suppressed = splitDNSFallbackGate.admit(host: entryDomain, reason: outcome) else {
            logger.log(
                .debug,
                "DNS: \(silence) for \(name); DoH fallback outcome=\(outcome).",
                category: .network
            )
            return
        }
        eventSink?(RuntimeEvent(
            kind: .routing,
            event: "dns.split_dns_doh_fallback",
            detail: "domain=\(entryDomain) name=\(name) server=\(server) outcome=\(outcome) suppressed=\(suppressed)"
        ))
        let held = suppressed > 0 ? " \(suppressed) more for this domain and outcome were not logged since the last line." : ""
        logger.log(
            .info,
            "DNS: \(silence) for \(name) (split-DNS domain \(entryDomain)); DoH fallback outcome=\(outcome).\(held)",
            category: .network
        )
    }

    private func resolveViaDoH(query: [UInt8], config: ProxyConfig) async -> DoHOutcome {
        let qtype = DNSWireFormat.extractQueryType(from: query)
        let typeName: String
        switch qtype {
        case 1: typeName = "A"
        case 28: typeName = "AAAA"
        default:
            return .notAsked(refusal: DNSWireFormat.emptyRefusedResponse(originalQuery: query))
        }

        // The empty-list fallback must be the shipped default, not a literal:
        // a hardcoded hostname here is unreachable on exactly the networks
        // this fallback exists for. See `DNSSection.defaultDoHProviders`.
        let providers = config.dohProviders.isEmpty
            ? DNSSection.defaultDoHProviders
            : config.dohProviders

        let domain = DNSWireFormat.extractDomainName(from: query)
        let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain

        // Every DoH attempt that reaches a server records its HTTP status here.
        // When they all fail this is the only evidence of *why* — and the
        // distinction matters enormously: an empty set means nothing was
        // reachable, while a uniform 404/403/200-not-a-DNS-answer across every
        // provider means something answered on their behalf, i.e. a filtering
        // proxy is intercepting DoH. Without this the failure is 18 silent nils
        // and an NXDOMAIN the user cannot account for.
        let observedStatuses = NIOLockedValueBox<Set<Int>>([])

        // Snapshot the current transport handle and hold a use window open for
        // the duration of this query. A concurrent `resetUpstreamTransports`/
        // `invalidateSessions` retires the handle but must not invalidate the
        // sessions while our fetches are in flight — `data(for:)` on an
        // invalidated session aborts the process (uncatchable CFNetwork
        // NSException). The use window guarantees invalidation is deferred
        // until the task group below has fully drained. If the handle was
        // retired before we could open the window, re-read once (a reset just
        // swapped in a fresh handle); if that one is retired too, the
        // forwarder is stopping — answer nil.
        var handle = currentHandle()
        if !handle.beginUse() {
            handle = currentHandle()
            guard handle.beginUse() else { return .unanswered }
        }
        defer { handle.endUse() }
        let upstreamOffered = DoHSessionFactory.upstreamRoute(config: config, boundPort: upstreamRoute()?.offeredPort) != nil
        let transports = handle.transports
        let preferProxyPath = preferProxyPathForDoH()

        let refusalsBefore = proxyChallengeDelegate.refusalCount

        // `withTaskGroup` awaits all children before returning (including
        // after the early-exit `cancelAll`), so no fetch outlives the use
        // window closed by the `defer` above.
        let answer: [UInt8]? = await withTaskGroup(of: [UInt8]?.self) { group -> [UInt8]? in
            for provider in providers {
                let dohURL = "\(provider)?name=\(encodedDomain)&type=\(typeName)"
                let sessions = transports.sessions(
                    preferProxyPath: preferProxyPath,
                    upstreamOffered: upstreamOffered && DoHSessionFactory.upstreamRouteCarries(provider: provider)
                )
                for session in sessions {
                    group.addTask {
                        await Self.tryDoHJSONFetch(
                            dohURL: dohURL, session: session, query: query,
                            queryType: qtype, statuses: observedStatuses
                        )
                    }
                    group.addTask {
                        await Self.tryDoHWireFetch(
                            provider: provider, session: session, query: query,
                            statuses: observedStatuses
                        )
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        if let answer { return .answered(answer) }

        // A cancelled fetch throws too, and `try?` makes that nil: not a
        // provider failure, so neither the warning nor its counter.
        if Task.isCancelled {
            logger.log(.debug, "DNS: DoH lookup for \(domain) cancelled by a transports reset.", category: .network)
            return .cancelled
        }

        let statuses = observedStatuses.withLockedValue { $0 }.sorted()
        // Refusals are counted across lookups, so a concurrent lookup's
        // refusal can be named here too. The warning is shared between
        // lookups already, and its cause is the same proxy either way.
        let refused = proxyChallengeDelegate.refusalCount > refusalsBefore
        let signature = DoHFailureSignature(statuses: statuses, proxyChallengeRefused: refused)
        if let failures = doHFailureCountToReport(signature: signature) {
            let alsoFailed = failures > 1
                ? " (and \(failures - 1) other name(s) since the last such warning)"
                : ""
            logger.log(
                .warning,
                "DNS: all \(providers.count) DoH provider(s) failed for \(domain)\(alsoFailed) — \(signature.explanation)",
                category: .network
            )
        }

        return .unanswered
    }

    private static func tryDoHJSONFetch(
        dohURL: String,
        session: URLSession,
        query: [UInt8],
        queryType: UInt16,
        statuses: NIOLockedValueBox<Set<Int>>
    ) async -> [UInt8]? {
        guard let url = URL(string: dohURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        statuses.withLockedValue { _ = $0.insert(httpResponse.statusCode) }

        guard httpResponse.statusCode == 200, !data.isEmpty else {
            return nil
        }

        let json = String(decoding: data, as: UTF8.self)
        return DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: queryType)
    }

    /// RFC 8484 wire-format DoH (POST `application/dns-message`). Some VPN /
    /// proxy paths block dns-json GET but still tunnel binary DoH through the
    /// corporate HTTP proxy.
    private static func tryDoHWireFetch(
        provider: String,
        session: URLSession,
        query: [UInt8],
        statuses: NIOLockedValueBox<Set<Int>>
    ) async -> [UInt8]? {
        guard let url = URL(string: provider) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(query)

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        statuses.withLockedValue { _ = $0.insert(httpResponse.statusCode) }

        guard httpResponse.statusCode == 200, data.count >= 12 else {
            return nil
        }

        let bytes = [UInt8](data)
        guard DNSWireFormat.responseQuestionMatches(query: query, response: bytes) else {
            return nil
        }
        return bytes
    }

    private func matchingInterceptIP(for domain: String, config: ProxyConfig) -> String? {
        let rules = config.enabledInterceptRules
        guard !rules.isEmpty else { return nil }
        for rule in rules where rule.matches(domain) {
            return rule.interceptIP
        }
        return nil
    }

    private func cacheResponse(_ response: [UInt8], for key: DNSCacheKey, matching query: [UInt8]) {
        guard DNSWireFormat.responseQuestionMatches(query: query, response: response) else { return }

        let ttl: TimeInterval?
        if DNSWireFormat.isNXDOMAIN(response) {
            ttl = DNSResponseCache.negativeCacheTTL
        } else if let parsedTTL = DNSWireFormat.minimumTTL(in: response), parsedTTL > 0 {
            ttl = min(TimeInterval(parsedTTL), DNSResponseCache.maximumCacheTTL)
        } else {
            ttl = nil
        }

        guard let ttl else { return }
        responseCache.store(response, for: key, ttl: ttl)
    }
}

/// UDP framing: one datagram in, one datagram out.
private final class DNSUDPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let core: DNSResolutionCore

    init(core: DNSResolutionCore) {
        self.core = core
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let clientAddress = envelope.remoteAddress
        var queryBuffer = envelope.data
        let queryBytes = queryBuffer.readBytes(length: queryBuffer.readableBytes) ?? []
        let eventLoop = context.eventLoop
        let channel = context.channel
        let core = self.core

        // Too short to carry a DNS header, so there is nothing to answer and no
        // ID to answer it with. Reject before admission, not inside `resolve`:
        // a garbage datagram must not cost an admission slot and a task spawn,
        // or a flood of them fills all 64 slots with no-op tasks and real
        // queries start getting SERVFAIL'd. TCP needs no equivalent — its
        // length-prefix framing rejects malformed input earlier still.
        guard queryBytes.count >= 12 else { return }

        // Admission first, on the event loop: a flood must be turned away
        // before it can allocate a task each. See `admitQuery()`.
        guard let ticket = core.admitQuery() else {
            if let servfail = core.overLimitResponse(for: queryBytes) {
                write(servfail, to: clientAddress, on: channel)
            }
            return
        }

        let task = Task { @Sendable in
            let response = await core.resolve(query: queryBytes)
            core.releaseQuery(ticket)
            guard let response else { return }
            eventLoop.execute {
                Self.write(response, to: clientAddress, on: channel)
            }
        }
        core.attach(task, to: ticket)
    }

    private func write(_ response: [UInt8], to address: SocketAddress, on channel: Channel) {
        Self.write(response, to: address, on: channel)
    }

    private static func write(_ response: [UInt8], to address: SocketAddress, on channel: Channel) {
        var buf = channel.allocator.buffer(capacity: response.count)
        buf.writeBytes(response)
        channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buf), promise: nil)
    }
}

/// The set of accepted DNS-over-TCP connections, bounded and closable.
///
/// It exists for two reasons a `ServerBootstrap` channel alone cannot cover:
///
/// - **A cap.** Every accepted connection costs an accumulation buffer (up to
///   `DNSTCPHandler.maximumMessageBytes`), a scheduled timer and a descriptor,
///   held for the whole idle window even if the client never sends a byte. UDP
///   has no equivalent exposure because a datagram leaves no per-peer state.
///   The in-flight resolution cap bounds concurrent *lookups*, not sockets.
/// - **Shutdown reach.** Closing the listener stops accepts; it does not close
///   the children, and each child keeps the resolution core alive.
private final class DNSTCPConnectionRegistry: @unchecked Sendable {
    /// A resolver client opens a connection, asks, and goes away, so the steady
    /// state is a handful. This is generous for legitimate use and still bounds
    /// what an abusive local client can pin.
    static let defaultMaximumConnections = 64

    /// A connection flood must not become a log flood: refusals are reported at
    /// most this often, and the message carries the count since the last one.
    private static let rejectionReportInterval: TimeInterval = 5

    private let maximumConnections: Int
    private let logger: any LogSink
    private let lock = NSLock()
    private var openChannels: [ObjectIdentifier: Channel] = [:]
    private var shuttingDown = false
    private var refusedSinceLastReport = 0
    private var lastRejectionReport: Date?

    init(maximumConnections: Int, logger: any LogSink) {
        self.maximumConnections = maximumConnections
        self.logger = logger
    }

    /// Records an accepted connection. Returns false when the cap is reached or
    /// the forwarder is shutting down — the caller must close the channel.
    func admit(_ channel: Channel) -> Bool {
        let decision: (admitted: Bool, refused: Int?, shuttingDown: Bool) = lock.withLock {
            guard !shuttingDown, openChannels.count < maximumConnections else {
                refusedSinceLastReport += 1
                return (false, refusalCountToReport(), shuttingDown)
            }
            openChannels[ObjectIdentifier(channel)] = channel
            return (true, nil, false)
        }

        if decision.admitted { return true }
        if let refused = decision.refused {
            if decision.shuttingDown {
                logger.log(
                    .debug,
                    "DNS TCP: refused \(refused) connection(s) — the forwarder is shutting down.",
                    category: .network
                )
            } else {
                logger.log(
                    .warning,
                    "DNS TCP: refused \(refused) connection(s); the \(maximumConnections)-connection cap is already reached. A client holding sockets open without querying can cause this.",
                    category: .network
                )
            }
        }
        return false
    }

    /// Refusals accumulated since the last report, or nil while still inside the
    /// reporting interval. Caller holds the lock.
    private func refusalCountToReport() -> Int? {
        let now = Date.now
        if let lastRejectionReport, now.timeIntervalSince(lastRejectionReport) < Self.rejectionReportInterval {
            return nil
        }
        lastRejectionReport = now
        let refused = refusedSinceLastReport
        refusedSinceLastReport = 0
        return refused
    }

    func release(_ channel: Channel) {
        lock.withLock { _ = openChannels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// Closes every accepted connection and refuses later ones. Called from
    /// `LocalDNSForwarder.stop()` after the listener is down.
    func closeAll() async {
        let open: [Channel] = lock.withLock {
            shuttingDown = true
            let values = Array(openChannels.values)
            openChannels.removeAll()
            return values
        }
        for channel in open {
            _ = try? await channel.close().get()
        }
    }
}

/// TCP framing per RFC 1035 §4.2.2: every message, in both directions, is
/// preceded by its length as a 2-byte big-endian integer. One connection may
/// carry several queries back to back, so reads are accumulated and drained
/// message by message rather than assumed to arrive one per `channelRead`.
private final class DNSTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// The length prefix permits 64 KiB, but a query is one question plus a few
    /// EDNS options and never approaches that. The cap is what stops a client
    /// from making us buffer 64 KiB per connection by announcing a length it
    /// then dribbles out or never sends.
    static let maximumMessageBytes = 4096

    /// A resolver client sends its query immediately on connect. A connection
    /// still silent after this — with nothing outstanding — has gone away or is
    /// holding a socket for no reason.
    ///
    /// Enforced by our own timer rather than `IdleStateHandler` for two
    /// reasons: that type's `Sendable` conformance is unavailable, so adding it
    /// to a pipeline from a `@Sendable` initializer warns; and it measures only
    /// inbound silence, which for DNS-over-TCP is indistinguishable between "the
    /// client is gone" and "the client asked a question and is waiting". Only
    /// the handler knows which, so the handler owns the timer. The window is
    /// `DNSForwarderTuning.tcpIdleTimeout`, 10 s in production.
    private let core: DNSResolutionCore
    private let logger: any LogSink
    private let idleTimeout: TimeAmount
    private var pending: ByteBuffer?

    /// Lookups spawned from this connection that have not written yet.
    /// Event-loop confined: incremented in `respond` (reached from
    /// `channelRead`) and decremented in the write hop, both on the loop.
    private var outstandingQueries = 0
    private var idleTask: Scheduled<Void>?

    init(core: DNSResolutionCore, logger: any LogSink, idleTimeout: TimeAmount) {
        self.core = core
        self.logger = logger
        self.idleTimeout = idleTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        armIdleTimer(on: context.eventLoop, channel: context.channel)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        idleTask?.cancel()
        idleTask = nil
    }

    /// (Re)starts the silence countdown. Rearmed on every read and every
    /// answer written, so the window measures time since the last thing that
    /// happened on this connection.
    private func armIdleTimer(on loop: EventLoop, channel: Channel) {
        idleTask?.cancel()
        idleTask = loop.scheduleTask(in: idleTimeout) { [weak self] in
            guard let self else { return }
            // A client waiting on an answer is legitimately silent. A worst-case
            // resolution (1.5 s internal attempt, then a DoH race bounded by the
            // 4 s / 8 s session timeouts) runs right up against this window, so
            // closing here would discard the answer mid-flight and hand the
            // client the exact silence this forwarder exists to avoid.
            guard self.outstandingQueries == 0 else {
                self.armIdleTimer(on: loop, channel: channel)
                return
            }
            channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        armIdleTimer(on: context.eventLoop, channel: context.channel)
        var incoming = unwrapInboundIn(data)
        if pending == nil {
            pending = incoming
        } else {
            pending?.writeBuffer(&incoming)
        }
        drain(context: context)
    }

    /// Peels off every complete message currently buffered. Returns as soon as
    /// the buffer holds only a partial one — the next read resumes here.
    private func drain(context: ChannelHandlerContext) {
        while var buffer = pending {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self) else { return }

            guard Int(length) <= Self.maximumMessageBytes else {
                logger.log(
                    .warning,
                    "DNS TCP: announced message length \(length) exceeds the \(Self.maximumMessageBytes)-byte cap; closing the connection.",
                    category: .network
                )
                pending = nil
                context.close(promise: nil)
                return
            }

            guard buffer.readableBytes >= 2 + Int(length) else { return }
            buffer.moveReaderIndex(forwardBy: 2)
            let queryBytes = buffer.readBytes(length: Int(length)) ?? []
            pending = buffer.readableBytes > 0 ? buffer : nil
            respond(to: queryBytes, context: context)
        }
    }

    private func respond(to queryBytes: [UInt8], context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        let channel = context.channel
        let core = self.core
        let logger = self.logger

        // Admission first, on the event loop. See `DNSResolutionCore.admitQuery()`.
        guard let ticket = core.admitQuery() else {
            if let servfail = core.overLimitResponse(for: queryBytes) {
                Self.write(servfail, on: channel, logger: logger)
            }
            return
        }

        outstandingQueries += 1
        let task = Task { @Sendable [weak self] in
            let response = await core.resolve(query: queryBytes)
            core.releaseQuery(ticket)
            eventLoop.execute { [weak self] in
                self?.outstandingQueries -= 1
                self?.armIdleTimer(on: eventLoop, channel: channel)
                guard let response else { return }
                Self.write(response, on: channel, logger: logger)
            }
        }
        core.attach(task, to: ticket)
    }

    private static func write(_ response: [UInt8], on channel: Channel, logger: any LogSink) {
        guard response.count <= Int(UInt16.max) else {
            logger.log(
                .warning,
                "DNS TCP: response of \(response.count) bytes exceeds the wire framing limit; dropping it.",
                category: .network
            )
            return
        }
        var out = channel.allocator.buffer(capacity: response.count + 2)
        out.writeInteger(UInt16(response.count))
        out.writeBytes(response)
        channel.writeAndFlush(out, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Never close silently: this is the only trace an operator gets when a
        // DNS-over-TCP connection fails (AGENTS.md, "never swallow an error").
        logger.log(
            .warning,
            "DNS TCP: connection error, closing: \(error.displayDescription)",
            category: .network
        )
        context.close(promise: nil)
    }
}

private struct DNSCacheKey: Hashable {
    let domain: String
    let queryType: UInt16
}

private struct DNSCacheEntry {
    let response: [UInt8]
    let expiresAt: Date
    var lastAccess: Date
}

private final class DNSResponseCache: @unchecked Sendable {
    static let maximumEntries = 2_048
    static let maximumCacheTTL: TimeInterval = 300
    static let negativeCacheTTL: TimeInterval = 30

    private let lock = NSLock()
    private var entries: [DNSCacheKey: DNSCacheEntry] = [:]

    func lookup(for key: DNSCacheKey, query: [UInt8]) -> [UInt8]? {
        lock.withLock {
            let now = Date.now
            purgeExpiredEntries(now: now)
            guard var entry = entries[key], entry.expiresAt > now else {
                entries.removeValue(forKey: key)
                return nil
            }
            entry.lastAccess = now
            entries[key] = entry
            return DNSWireFormat.responseByUpdatingTransactionID(entry.response, from: query)
        }
    }

    func store(_ response: [UInt8], for key: DNSCacheKey, ttl: TimeInterval) {
        guard ttl > 0 else { return }
        let now = Date()
        let expiresAt = now.addingTimeInterval(ttl)
        lock.withLock {
            entries[key] = DNSCacheEntry(response: response, expiresAt: expiresAt, lastAccess: now)
            evictIfNeeded(now: now)
        }
    }

    func clear() {
        lock.withLock { entries.removeAll(keepingCapacity: false) }
    }

    var entryCount: Int {
        lock.withLock { entries.count }
    }

    private func purgeExpiredEntries(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func evictIfNeeded(now: Date) {
        purgeExpiredEntries(now: now)
        while entries.count > Self.maximumEntries {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
}

private final class UDPResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private var continuation: CheckedContinuation<[UInt8], Error>?
    private let lock = NSLock()
    private let accepts: @Sendable ([UInt8]) -> Bool
    private var discarded = 0
    private var channel: Channel?
    private var cancelled = false

    init(continuation: CheckedContinuation<[UInt8], Error>, accepts: @escaping @Sendable ([UInt8]) -> Bool) {
        self.continuation = continuation
        self.accepts = accepts
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let closeNow: Bool = lock.withLock {
            channel = context.channel
            return cancelled
        }
        if closeNow { context.close(promise: nil) }
    }

    /// Ends the wait with `DNSForwarderError.cancelled` and closes the socket,
    /// now or as soon as it exists. Callable from any thread.
    func cancel() {
        let channel: Channel? = lock.withLock {
            cancelled = true
            return self.channel
        }
        fail(with: DNSForwarderError.cancelled)
        channel?.close(promise: nil)
    }

    /// Datagrams dropped for not answering the query. Bounded by what
    /// arrives before the timeout closes the channel.
    var discardedCount: Int {
        lock.withLock { discarded }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buf = envelope.data
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        guard accepts(bytes) else {
            lock.withLock { discarded += 1 }
            return
        }
        complete(with: bytes)
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: error)
        context.close(promise: nil)
    }

    func timeout() {
        fail(with: DNSForwarderError.timeout)
    }

    private func complete(with bytes: [UInt8]) {
        lock.withLock {
            continuation?.resume(returning: bytes)
            continuation = nil
        }
    }

    /// Ends the wait with `error`, unless something already ended it. The
    /// one path to the continuation's failure, from any thread.
    func fail(with error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

private enum DNSForwarderError: Error {
    case timeout
    case cancelled
}

/// One circuit per internal (split-DNS) server (#290). A server that gave no
/// reply `openAfterConsecutiveSilences` times in a row is open: lookups skip
/// it and go to their fallback at once instead of waiting out its timeout,
/// and the first lookup to skip it sends its query as a probe; a reply to the
/// probe, or to a lookup that was already waiting, closes the circuit. Every
/// transports reset closes every circuit: silence on the old path says
/// nothing about the new one.
///
/// Bounded: at most `maximumTrackedServers` servers are tracked, the least
/// recently touched making room. The configuration allows more (256 entries
/// of 8 servers), but only servers a lookup has reached are tracked, and a
/// server dropped from the table is merely closed again.
private final class InternalServerHealth: @unchecked Sendable {
    static let openAfterConsecutiveSilences = 3
    static let maximumTrackedServers = 64

    enum Circuit: Equatable {
        case closed(silences: Int)
        case open(probing: Bool)
    }

    enum Transition: Equatable {
        case opened(silences: Int)
        case closed
    }

    private struct Entry {
        var circuit: Circuit
        var touched: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var touches = 0
    /// Advanced by every `reset()`; a probe records its result only in the
    /// generation it began in.
    private var resets = 0

    func isOpen(_ server: String) -> Bool {
        lock.withLock {
            if case .open = entries[server]?.circuit { return true }
            return false
        }
    }

    /// Claims the one probe slot of an open circuit and returns the reset
    /// generation the probe starts in. Nil when the circuit is closed or a
    /// probe is already in flight.
    func beginProbe(_ server: String) -> Int? {
        lock.withLock {
            guard case .open(probing: false) = entries[server]?.circuit else { return nil }
            update(server) { $0 = .open(probing: true) }
            return resets
        }
    }

    /// Frees the probe slot and records the probe's result in one step. A
    /// reset since `generation` closed every circuit and dropped the slot
    /// already, and the probe says nothing about the new path: nothing is
    /// recorded.
    func endProbe(_ server: String, startedIn generation: Int, replied: Bool) -> Transition? {
        lock.withLock {
            guard resets == generation else { return nil }
            if case .open = entries[server]?.circuit {
                update(server) { $0 = .open(probing: false) }
            }
            return recordLocked(replied: replied, from: server)
        }
    }

    /// Counts a lookup's reply or silence from `server`.
    func record(replied: Bool, from server: String) -> Transition? {
        lock.withLock { recordLocked(replied: replied, from: server) }
    }

    /// Caller holds the lock.
    private func recordLocked(replied: Bool, from server: String) -> Transition? {
        let circuit = entries[server]?.circuit ?? .closed(silences: 0)
        if replied {
            update(server) { $0 = .closed(silences: 0) }
            if case .open = circuit { return .closed }
            return nil
        }
        switch circuit {
        case .open:
            return nil
        case .closed(let silences):
            let now = silences + 1
            if now >= Self.openAfterConsecutiveSilences {
                update(server) { $0 = .open(probing: false) }
                return .opened(silences: now)
            }
            update(server) { $0 = .closed(silences: now) }
            return nil
        }
    }

    /// Closes every circuit and forgets every probe.
    func reset() {
        lock.withLock {
            entries.removeAll()
            resets += 1
        }
    }

    /// Caller holds the lock. Touches `server` for the eviction order and
    /// evicts the least recently touched entry when a new one would exceed
    /// the bound.
    private func update(_ server: String, _ change: (inout Circuit) -> Void) {
        touches += 1
        var circuit = entries[server]?.circuit ?? .closed(silences: 0)
        change(&circuit)
        if entries[server] == nil, entries.count >= Self.maximumTrackedServers,
           let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[server] = Entry(circuit: circuit, touched: touches)
    }
}
