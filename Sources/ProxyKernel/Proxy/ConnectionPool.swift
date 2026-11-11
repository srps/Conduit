// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// Scope of a `ConnectionPool.closeAll` operation.
///
/// Designed to support the VPN-flap-resilience design (`docs/design-vpn-flap-resilience.md`):
/// control-plane transitions (direct-mode flips, listener recycling) must NOT close active
/// upstream channels, because macOS preserves their TCP state across VPN flaps and the kernel
/// will resume delivery once the path returns. Only explicit shutdown and a confirmed VPN
/// disconnect that routes DIRECT (#148: the channels left with the VPN) call `.all`.
package enum CloseScope: Sendable, Equatable {
    /// Close only idle pooled connections (those not currently in use). Preserves
    /// every connection that is mid-exchange or marked as a dedicated CONNECT tunnel.
    /// Use when recycling control-plane state without disturbing active streams.
    case idleOnly

    /// Close all pooled connections except dedicated CONNECT tunnels. Use for
    /// proxy-config restart paths where the listener identity changes but in-flight
    /// tunnels (HTTPS streams owned by the client side) should ride out the change.
    case allButDedicated

    /// Close every connection in the pool, including dedicated CONNECT tunnels.
    /// Use only for final shutdown / process termination paths, and for a
    /// confirmed VPN disconnect that routes DIRECT (#148).
    case all
}

package enum ConnectionPoolError: Error, LocalizedError, Equatable {
    case noUpstreamsConfigured
    case authenticationUnavailable
    case authenticationRejected
    case invalidResponse
    case poolExhausted
    case bodyTooLargeForReplay
    case authHandshakeLimitExceeded
    case streamingResponseInterrupted
    /// The upstream delivered the whole response, but the client had closed
    /// before its end could be written. A client hang-up, not an upstream
    /// failure.
    case clientClosedDuringResponse
    case upstreamResponseTimedOut
    /// A health check got no answer on a connection that had sat idle. The socket may have died
    /// without a word, so this says nothing about the upstream; the check retries on a fresh one.
    case idleConnectionSilent
    case upstreamReturnedStatus(Int, target: String)
    /// A confirmed VPN transition swept the pool while this connection was
    /// being dialed or used, and closed it (#148). Local: the upstream did
    /// nothing wrong, and the exchange is not retried on a fresh upstream
    /// connection, since routing may have left the upstream.
    case vpnTransitionDuringConnect
    /// The runtime's transition registry is full, so the connection could
    /// not be tracked for VPN migration and was closed (#156). Local.
    case connectionTrackingFull
    /// The tunnel's target holds a space, a control or a non-ASCII byte, so it
    /// was not written into a CONNECT (`TunnelAuthority.isWritable`). Local:
    /// no upstream was dialled.
    case malformedTunnelTarget
    /// The tunnel's caller gave it up while it was being dialled, such as
    /// the DoH upstream route stopping: nothing is dialled, retried or
    /// pooled for it after that. Local: the upstream did nothing wrong.
    case tunnelAbandoned

    package var errorDescription: String? {
        switch self {
        case .noUpstreamsConfigured:
            return "No upstream proxy servers are enabled."
        case .authenticationUnavailable:
            return "Proxy credentials are unavailable."
        case .authenticationRejected:
            return "The upstream proxy rejected authentication."
        case .invalidResponse:
            return "The upstream proxy returned an invalid response."
        case .poolExhausted:
            return "Maximum upstream connections reached."
        case .bodyTooLargeForReplay:
            return "Request body too large to replay for proxy authentication."
        case .authHandshakeLimitExceeded:
            return "Too many proxy authentication handshakes are already pending."
        case .streamingResponseInterrupted:
            return "The upstream response stream ended after client response forwarding began."
        case .clientClosedDuringResponse:
            return "The client closed its connection before the response was complete."
        case .upstreamResponseTimedOut:
            return "Timed out waiting for the upstream proxy to respond."
        case .idleConnectionSilent:
            return "Timed out waiting for the upstream proxy to respond on an idle connection."
        case .upstreamReturnedStatus(let statusCode, let target):
            return "The upstream proxy returned HTTP \(statusCode) for \(SensitiveValueSanitizer.observableTarget(target))."
        case .vpnTransitionDuringConnect:
            return "A VPN transition closed the upstream connection; retry the request."
        case .connectionTrackingFull:
            return OutboundSocketRegistry.fullMessage
        case .malformedTunnelTarget:
            return "The tunnel's target holds a space, a control character or a non-ASCII byte."
        case .tunnelAbandoned:
            return "The tunnel was given up before it opened."
        }
    }

    package static func isAuthHandshakeLimitExceeded(_ error: Error) -> Bool {
        if case ConnectionPoolError.authHandshakeLimitExceeded = error {
            return true
        }
        return false
    }

    package static func isPoolExhausted(_ error: Error) -> Bool {
        if case ConnectionPoolError.poolExhausted = error {
            return true
        }
        return false
    }

    package static func isLocalNonUpstreamFailure(_ error: Error) -> Bool {
        isAuthHandshakeLimitExceeded(error) || isPoolExhausted(error) || isVPNTransitionDuringConnect(error)
            || isConnectionTrackingFull(error) || isIdleConnectionSilent(error) || error as? ConnectionPoolError == .malformedTunnelTarget
            || error as? ConnectionPoolError == .tunnelAbandoned
    }

    /// A dial that failed on this machine, before any upstream could answer or not: out of descriptors, buffers or
    /// memory (`EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`), no local address to send from (`EADDRNOTAVAIL`), or no route to
    /// the upstream's network at all (`ENETUNREACH`, `ENETDOWN`), as while a VPN takes its routes down. It says nothing
    /// about the upstream, so it is not charged to its breaker: a flap's routing gap would otherwise open every
    /// healthy upstream's.
    ///
    /// A refused connect, a connect timeout and `EHOSTUNREACH` still count. `EHOSTUNREACH` is reported for one
    /// destination, from a router's host-unreachable or a failed neighbour lookup, with a route to its network in
    /// place, so another upstream on the same path may still connect; and the breakers a flap opens that way are
    /// closed when the VPN comes back (`resetCircuitsAfterFlap`).
    ///
    /// NIO reports a `connect(host:port:)` failure as `NIOConnectionError`, one `SingleConnectionFailure` per address
    /// tried, each holding the `IOError`; a dial to one address reports the `IOError` itself. The dial is local only
    /// when every address failed locally. A lookup of the upstream's name that found no address tried none, so it
    /// still counts.
    package static func isLocalDialFailure(_ error: Error) -> Bool {
        localDialFailureCodes(error) != nil
    }

    /// The errno names of a local dial failure, comma-separated, for the events that report one; nil for any other error.
    package static func localDialFailureCodes(_ error: Error) -> String? {
        switch error {
        case let io as IOError:
            return localDialErrnoNames[io.errnoCode]
        case let connection as NIOConnectionError:
            let codes = connection.connectionErrors.map { localDialFailureCodes($0.error) }
            guard !codes.isEmpty, codes.allSatisfy({ $0 != nil }) else { return nil }
            return Set(codes.compactMap { $0 }).sorted().joined(separator: ",")
        default:
            return nil
        }
    }

    private static let localDialErrnoNames: [Int32: String] = [
        EMFILE: "EMFILE", ENFILE: "ENFILE", ENOBUFS: "ENOBUFS", ENOMEM: "ENOMEM",
        EADDRNOTAVAIL: "EADDRNOTAVAIL", ENETUNREACH: "ENETUNREACH", ENETDOWN: "ENETDOWN",
    ]

    package static func isUpstreamResponseTimedOut(_ error: Error) -> Bool {
        if case ConnectionPoolError.upstreamResponseTimedOut = error {
            return true
        }
        return false
    }

    /// The upstream answered, with a status or with bytes that did not frame: whatever else it says, it is not silence.
    package static func isUpstreamAnswer(_ error: Error) -> Bool {
        switch error as? ConnectionPoolError {
        case .upstreamReturnedStatus, .authenticationRejected, .invalidResponse: return true
        default: return false
        }
    }

    package static func isIdleConnectionSilent(_ error: Error) -> Bool {
        if case ConnectionPoolError.idleConnectionSilent = error {
            return true
        }
        return false
    }

    package static func isConnectionTrackingFull(_ error: Error) -> Bool {
        if case ConnectionPoolError.connectionTrackingFull = error {
            return true
        }
        return false
    }

    package static func isVPNTransitionDuringConnect(_ error: Error) -> Bool {
        if case ConnectionPoolError.vpnTransitionDuringConnect = error {
            return true
        }
        return false
    }

    package static func isClientClosedDuringResponse(_ error: Error) -> Bool {
        if case ConnectionPoolError.clientClosedDuringResponse = error {
            return true
        }
        return false
    }

    package static func isStreamingResponseInterrupted(_ error: Error) -> Bool {
        if case ConnectionPoolError.streamingResponseInterrupted = error {
            return true
        }
        return false
    }
}

package struct UpstreamExchangeResponse {
    package var head: HTTPResponseHead
    package var body: ByteBuffer
    package var upstream: UpstreamProxy
    package var authMethod: String?

    package init(
        head: HTTPResponseHead,
        body: ByteBuffer,
        upstream: UpstreamProxy,
        authMethod: String? = nil
    ) {
        self.head = head
        self.body = body
        self.upstream = upstream
        self.authMethod = authMethod
    }
}

/// One attempt's pick of an upstream. A pick that took the upstream's
/// half-open probe slot holds it here, and the attempt settles it once:
/// with a verdict on the upstream (`recordSuccess`, `recordExchangeError`),
/// or, when it ends with none, by giving back only this claim
/// (`releaseProbe(of:)`).
package struct UpstreamSelection: Sendable {
    package let proxy: UpstreamProxy
    let probe: UpstreamCircuitBreaker.ProbeClaim?

    /// An upstream the caller chose, such as a PAC chain's: it holds no probe slot.
    package static func forced(_ proxy: UpstreamProxy) -> UpstreamSelection {
        UpstreamSelection(proxy: proxy, probe: nil)
    }
}

package struct StreamingExchangeResult {
    package var upstream: UpstreamProxy
    package var keepAlive: Bool
    package var authMethod: String?

    package init(upstream: UpstreamProxy, keepAlive: Bool, authMethod: String? = nil) {
        self.upstream = upstream
        self.keepAlive = keepAlive
        self.authMethod = authMethod
    }
}

/// An exchange in flight and the upstream it was given; `nil` only when no
/// upstream is enabled, and then `result` fails with `noUpstreamsConfigured`.
/// An exchange whose dial failed on this machine moves to another upstream
/// (`ConnectionPool.localDialFailover`), so read `upstream` once `result`
/// has completed to name the one that failed.
package struct StreamingExchangeAttempt {
    fileprivate let dialled: NIOLockedValueBox<UpstreamProxy?>
    package let result: EventLoopFuture<StreamingExchangeResult>

    package var upstream: UpstreamProxy? { dialled.withLockedValue { $0 } }
}

/// A failure to get a connection to the upstream, before any byte of the
/// request was written. Only the pool's exchange paths see it, and they
/// unwrap it before the caller does.
private struct AcquisitionFailure: Error {
    let cause: Error
}

/// An upstream connection and the pool's bookkeeping for it.
///
/// Its mutable fields are read and written from the pool's callers, the
/// channel's loop and `CONNECTHandler`, so they live together behind one
/// lock: a reader sees one consistent `Metadata`, never a field from before
/// and another from after a change. That lock is a leaf: it is taken alone
/// or with the pool lock already held (pool, then connection, never the
/// reverse), and nothing runs under it but the field access. What the pool
/// decides from these fields (whether an idle connection may be handed out
/// or retired) is decided under the pool lock, which every `inUse` change
/// the pool makes also holds.
package final class PooledUpstreamConnection: @unchecked Sendable {
    fileprivate struct Metadata {
        var authenticated = false
        /// Bumped by each `ConnectionPool.resetAuthentication`, so an
        /// exchange that began before a reset cannot mark the connection
        /// authenticated again when it ends.
        var authGeneration: UInt64 = 0
        var authMethod: String?
        var inUse = false
        var lastUsedAt = Date()
        var isDedicatedTunnel = false
        var hasIdled = false
    }

    package let id = UUID()
    package let proxy: UpstreamProxy
    package let channel: Channel
    package let createdAt = Date()
    private let metadata = NIOLockedValueBox(Metadata())
    package fileprivate(set) var authenticated: Bool {
        get { metadata.withLockedValue { $0.authenticated } }
        set { metadata.withLockedValue { $0.authenticated = newValue } }
    }
    package var authMethod: String? { metadata.withLockedValue { $0.authMethod } }
    package fileprivate(set) var inUse: Bool {
        get { metadata.withLockedValue { $0.inUse } }
        set { metadata.withLockedValue { $0.inUse = newValue } }
    }
    package var lastUsedAt: Date {
        get { metadata.withLockedValue { $0.lastUsedAt } }
        set { metadata.withLockedValue { $0.lastUsedAt = newValue } }
    }
    /// Whether it sat idle in the pool before this use; an idle socket can die without a word.
    package var hasIdled: Bool { metadata.withLockedValue { $0.hasIdled } }
    /// Set by the pool before it publishes a dedicated tunnel, never after.
    /// Package-settable so tests can build synthetic states for the pure
    /// filters.
    package var isDedicatedTunnel: Bool {
        get { metadata.withLockedValue { $0.isDedicatedTunnel } }
        set { metadata.withLockedValue { $0.isDedicatedTunnel = newValue } }
    }
    /// The runtime transition registry's record of it, set before the pool
    /// publishes it (#156), and never again. Retired once a
    /// confirmed-VPN-transition sweep closed it: whatever its exchange then
    /// fails with is the sweep's doing, not the upstream's.
    package fileprivate(set) var transitionTicket: TransitionTicket?

    /// Whether a VPN-transition sweep closed it.
    package var wasRetiredByVPNTransition: Bool { transitionTicket?.isRetired ?? false }

    package init(proxy: UpstreamProxy, channel: Channel) {
        self.proxy = proxy
        self.channel = channel
    }

    package func markAuthenticated(authMethod: String?) {
        metadata.withLockedValue { state in
            state.authenticated = true
            if let authMethod {
                state.authMethod = authMethod
            }
        }
    }

    /// One consistent copy of the fields, for a decision that reads several.
    fileprivate var snapshot: Metadata { metadata.withLockedValue { $0 } }

    fileprivate func update<T>(_ body: (inout Metadata) -> T) -> T {
        metadata.withLockedValue(body)
    }

    /// Whether it is authenticated, and the reset generation that answer
    /// belongs to; hand the generation back to `markAuthenticated(since:)`.
    fileprivate func authenticationState() -> (authenticated: Bool, generation: UInt64) {
        metadata.withLockedValue { ($0.authenticated, $0.authGeneration) }
    }

    /// An exchange that began at `generation` succeeded. It marks the
    /// connection authenticated only if no reset came in between; the auth
    /// method it used is recorded either way, since that is what it used.
    fileprivate func markAuthenticated(since generation: UInt64, authMethod: String?) {
        metadata.withLockedValue { state in
            if state.authGeneration == generation {
                state.authenticated = true
            }
            if let authMethod {
                state.authMethod = authMethod
            }
        }
    }

    fileprivate func resetAuthentication() {
        metadata.withLockedValue { state in
            state.authenticated = false
            state.authGeneration &+= 1
        }
    }

    /// Test-only factory that constructs a connection in an arbitrary state.
    ///
    /// Production code MUST NOT use this — `inUse` and `authenticated` are
    /// `fileprivate(set)` because they're invariants of the pool's
    /// acquire/release/auth lifecycle. This factory exists so unit tests can
    /// exercise filter/policy code (e.g. `connectionIDsToClose(from:scope:)`)
    /// against synthetic states without standing up a live pool.
    package static func makeForTesting(
        proxy: UpstreamProxy,
        channel: Channel,
        inUse: Bool = false,
        isDedicatedTunnel: Bool = false,
        authenticated: Bool = false
    ) -> PooledUpstreamConnection {
        let conn = PooledUpstreamConnection(proxy: proxy, channel: channel)
        conn.inUse = inUse
        conn.isDedicatedTunnel = isDedicatedTunnel
        conn.authenticated = authenticated
        return conn
    }
}

/// What a status the upstream answered with says about the upstream's health.
package enum AnsweredStatusAccounting: Sendable {
    /// Every answered status counts as a failure of the upstream.
    case everyStatus
    /// A 4xx is the upstream's policy on the target and counts nothing; a 5xx counts.
    /// For a pool that only ever asks for a few fixed targets, where a policy
    /// block would otherwise open every breaker on a healthy upstream.
    case serverErrorsOnly

    func counts(_ status: Int) -> Bool {
        switch self {
        case .everyStatus: true
        case .serverErrorsOnly: !(400..<500).contains(status)
        }
    }
}

package final class ConnectionPool: @unchecked Sendable {
    /// Default circuit-breaker thresholds. Used when `HealthSection` doesn't
    /// override them. The names mirror `UpstreamCircuitBreaker` for grep-ability;
    /// the breaker itself is configuration-free and takes these as arguments.
    fileprivate static let defaultCircuitFailureThreshold = 5
    fileprivate static let defaultCircuitBaseOpenInterval: TimeInterval = 30
    fileprivate static let defaultCircuitMaxOpenInterval: TimeInterval = 300
    private static let maxConnectionAgeSeconds: TimeInterval = 300
    /// The data-path connect budget never drops below this, whatever the
    /// config says: a shorter dial gives up on a slow but healthy upstream.
    package static let defaultMinimumConnectTimeout: TimeInterval = 0.5

    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let authenticatorProvider: (UpstreamProxy) throws -> ProxyAuthenticator
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let minimumConnectTimeout: TimeInterval
    private let answeredStatusAccounting: AnsweredStatusAccounting
    /// ` pool=<label>` on this pool's `upstream.*` events, or empty for the client listener's pool.
    private let poolTag: String
    private let lock = NIOLock()
    private var idleConnections: [UUID: [PooledUpstreamConnection]] = [:]
    private var allConnections: [UUID: PooledUpstreamConnection] = [:]
    private var connectionIDsByChannel: [ObjectIdentifier: UUID] = [:]
    private var breakers: [UUID: UpstreamCircuitBreaker] = [:]
    private var silences: [UUID: UpstreamSilences] = [:]
    /// When each upstream last failed a dial on this machine
    /// (`isLocalDialFailure`), which its breaker does not count. Selection
    /// passes it over while another upstream may be asked, until its next
    /// success, a flap reset, or the breaker's base open interval later, when
    /// it is asked again. At most one entry per enabled upstream.
    private var locallyUnreachableSince: [UUID: Date] = [:]
    /// `upstream.failure_uncharged`, at most once a minute per upstream and reason.
    private let unchargedFailureGate = RuntimeEventRepeatGate()
    /// Cached `(name, endpoint)` for each upstream we've seen, used so the
    /// transition-event emission can carry human-readable upstream identity
    /// without re-querying `configProvider().enabledUpstreams` on every fire
    /// (the config could have changed by the time we emit, and we want the
    /// event tagged with the upstream that actually transitioned).
    private var upstreamIdentities: [UUID: (name: String, endpoint: String)] = [:]
    private var pendingConnectionCount = 0
    /// Tracks every connection this pool dials for VPN migration; shared by
    /// the whole runtime, so it outlives this pool (#156).
    private let sockets: OutboundSocketRegistry
    private var preferredProxyIndex = 0
    private var selectionCounter = 0
    private var lastSelectedUpstreamID: UUID?

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        authenticatorProvider: @escaping (UpstreamProxy) throws -> ProxyAuthenticator,
        authHandshakeLimiter: AuthHandshakeLimiter = AuthHandshakeLimiter(),
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil,
        sockets: OutboundSocketRegistry = .standalone(),
        answeredStatusAccounting: AnsweredStatusAccounting = .everyStatus,
        label: String? = nil,
        // Exposed only so failover tests can dial dead upstreams without
        // waiting out the production floor once per upstream.
        minimumConnectTimeout: TimeInterval = ConnectionPool.defaultMinimumConnectTimeout
    ) {
        self.minimumConnectTimeout = minimumConnectTimeout
        self.answeredStatusAccounting = answeredStatusAccounting
        self.poolTag = label.map { " pool=\($0)" } ?? ""
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.authenticatorProvider = authenticatorProvider
        self.authHandshakeLimiter = authHandshakeLimiter
        self.eventSink = eventSink
        self.sockets = sockets
    }

    package func exchange(head: HTTPRequestHead, body: ByteBuffer?) -> EventLoopFuture<UpstreamExchangeResponse> {
        bufferedExchange(head: head, requestBody: body.map(HTTPRequestBody.memory), selection: nil, allowRetry: true,
                         preferFreshConnection: false, authSource: nil, tried: [])
    }

    package func exchange(head: HTTPRequestHead, requestBody: HTTPRequestBody?) -> EventLoopFuture<UpstreamExchangeResponse> {
        bufferedExchange(head: head, requestBody: requestBody, selection: nil, allowRetry: true,
                         preferFreshConnection: false, authSource: nil, tried: [])
    }

    package func streamingExchange(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        clientChannel: Channel,
        authSource: String? = nil,
        forcedProxy: UpstreamProxy? = nil
    ) -> EventLoopFuture<StreamingExchangeResult> {
        streamingExchange(
            head: head,
            requestBody: body.map(HTTPRequestBody.memory),
            clientChannel: clientChannel,
            authSource: authSource,
            forcedProxy: forcedProxy
        )
    }

    package func streamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        authSource: String? = nil,
        forcedProxy: UpstreamProxy? = nil
    ) -> EventLoopFuture<StreamingExchangeResult> {
        startStreamingExchange(
            head: head,
            requestBody: requestBody,
            clientChannel: clientChannel,
            authSource: authSource,
            forcedProxy: forcedProxy
        ).result
    }

    /// Starts an exchange and says which upstream it dials. A caller that
    /// reports the failure names `upstream`: `activeUpstream()` is the
    /// pool-wide last selection, which a concurrent request can move.
    package func startStreamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        authSource: String? = nil,
        forcedProxy: UpstreamProxy? = nil
    ) -> StreamingExchangeAttempt {
        let config = configProvider()
        let forced = forcedProxy.map(UpstreamSelection.forced)
        guard let selection = forced ?? selectProxy(from: config) else {
            return StreamingExchangeAttempt(
                dialled: NIOLockedValueBox(nil), result: group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
            )
        }

        let dialled = NIOLockedValueBox<UpstreamProxy?>(selection.proxy)
        return StreamingExchangeAttempt(dialled: dialled, result: streamingExchange(
            head: head,
            requestBody: requestBody,
            clientChannel: clientChannel,
            authSource: authSource,
            selection: selection,
            tried: forced == nil ? [] : nil,
            dialled: dialled
        ))
    }

    /// - Parameter tried: the upstreams this request already dialled, for a
    ///   failover after a local dial failure; nil when the caller chose the
    ///   upstream and the exchange stays on it.
    private func streamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        authSource: String?,
        selection: UpstreamSelection,
        tried: Set<UUID>?,
        dialled: NIOLockedValueBox<UpstreamProxy?>
    ) -> EventLoopFuture<StreamingExchangeResult> {
        let proxy = selection.proxy
        let start = Date()
        // A probe's verdict is its response head: a long download would
        // otherwise hold the half-open slot until its last byte, and every
        // other request would pass the upstream over until then.
        let settledAtHead = NIOLockedValueBox(false)
        let settleAtHead: @Sendable () -> Void = { [weak self] in
            settledAtHead.withLockedValue { $0 = true }
            self?.recordSuccess(for: proxy, latencyMS: Int(Date().timeIntervalSince(start) * 1_000))
        }
        let onStreamedHead = selection.probe == nil ? nil : settleAtHead
        let recordSuccessUnlessSettled: @Sendable () -> Void = { [weak self] in
            guard !settledAtHead.withLockedValue({ $0 }) else { return }
            self?.recordSuccess(for: proxy, latencyMS: Int(Date().timeIntervalSince(start) * 1_000))
        }
        let attempt: EventLoopFuture<StreamingExchangeResult> = acquireConnection(
            for: proxy,
            target: head.uri,
            preferFreshConnection: false
        ).flatMapErrorThrowing { throw AcquisitionFailure(cause: $0) }
        .flatMap { [weak self] connection in
            guard let self else {
                return connection.channel.eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
            }
            return self.attributingRetirement(self.performStreamingExchange(
                head: head,
                requestBody: requestBody,
                clientChannel: clientChannel,
                connection: connection,
                proxy: proxy,
                authSource: authSource,
                onStreamedHead: onStreamedHead
            ), connection: connection).flatMap { result in
                recordSuccessUnlessSettled()
                return connection.channel.eventLoop.makeSucceededFuture(result)
            }
        }
        // Mirror the buffered path: acquire-time failures (e.g. immediate
        // connect-refused on a dead upstream) are upstream health signals and
        // must feed the breaker. Local capacity signals are not upstream
        // failures and are excluded below.
        // A client that hung up after the upstream answered in full is a
        // success for the upstream, not a breaker signal.
        return attempt.flatMapError { [weak self] (error: Error) -> EventLoopFuture<StreamingExchangeResult> in
            let acquisitionFailed = error is AcquisitionFailure
            let cause = (error as? AcquisitionFailure)?.cause ?? error
            guard let self else { return attempt.eventLoop.makeFailedFuture(cause) }
            if ConnectionPoolError.isClientClosedDuringResponse(cause) {
                recordSuccessUnlessSettled()
            } else {
                self.recordExchangeError(cause, for: selection, origin: ExchangeOrigin(head))
            }
            if acquisitionFailed, let next = self.localDialFailover(after: cause, from: proxy, tried: tried) {
                dialled.withLockedValue { $0 = next.selection.proxy }
                return self.streamingExchange(
                    head: head, requestBody: requestBody, clientChannel: clientChannel, authSource: authSource,
                    selection: next.selection, tried: next.tried, dialled: dialled
                )
            }
            return self.group.next().makeFailedFuture(cause)
        }
    }

    /// The next upstream for an exchange whose dial failed on this machine.
    /// No byte of the request reached any upstream, so the same request may
    /// go to another one, chosen as a failover is: among the untried
    /// upstreams the pool may ask now. Nil for any other failure, for an
    /// exchange whose caller chose its upstream (`tried` nil), and when no
    /// untried upstream may be asked.
    private func localDialFailover(
        after error: Error, from proxy: UpstreamProxy, tried: Set<UUID>?
    ) -> (selection: UpstreamSelection, tried: Set<UUID>)? {
        guard let tried, ConnectionPoolError.isLocalDialFailure(error) else { return nil }
        let nowTried = tried.union([proxy.id])
        return selectProxy(from: configProvider(), excluding: nowTried).map { ($0, nowTried) }
    }

    /// Dials `selection` (by default, a fresh selection) for a tunnel. Until
    /// it hands the connection over, this settles the selection on every
    /// exit: a refused or failed dial is charged as any exchange's would be,
    /// and one its caller gave up gives back the probe slot it claimed.
    /// From the handshake on, the caller settles it.
    ///
    /// - Parameter isWanted: false once the caller has given the tunnel up.
    ///   Read before the dial and again, under the pool's lock, when the
    ///   connection would join the pool: one that is no longer wanted is
    ///   closed there and the attempt fails with `tunnelAbandoned`. A caller
    ///   whose stop makes it false and then calls `closeAll` therefore closes
    ///   every connection dialled for it.
    package func makeDedicatedTunnelConnection(
        _ selection: UpstreamSelection? = nil, target: String? = nil, isWanted: @escaping @Sendable () -> Bool = { true }
    ) -> EventLoopFuture<(PooledUpstreamConnection, ProxyConfig)> {
        let config = configProvider()
        guard let selection = selection ?? selectProxy(from: config) else {
            return group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
        }
        let target = target ?? selection.proxy.endpoint
        guard isWanted() else {
            releaseProbe(of: selection)
            return group.next().makeFailedFuture(ConnectionPoolError.tunnelAbandoned)
        }
        return acquireDedicatedTunnelConnection(for: selection.proxy, target: target, config: config, isWanted: isWanted)
            .flatMapErrorThrowing { [weak self] error in
                guard isWanted() else {
                    self?.releaseProbe(of: selection)
                    throw ConnectionPoolError.tunnelAbandoned
                }
                self?.recordExchangeError(error, for: selection, origin: .connect(target))
                throw error
            }
    }

    private func authHandshakeLimits() -> AuthHandshakeLimiter.Limits {
        let config = configProvider()
        return AuthHandshakeLimiter.Limits(
            total: config.pendingAuthHandshakeGlobalLimit,
            perSource: config.pendingAuthHandshakesPerSource
        )
    }

    package func recordDedicatedTunnelSuccess(for proxy: UpstreamProxy, latencyMS: Int) {
        recordSuccess(for: proxy, latencyMS: latencyMS)
    }

    package func removeDedicatedTunnel(_ connection: PooledUpstreamConnection) {
        lock.withLockVoid {
            removeConnectionLocked(id: connection.id)
        }
    }

    package func removeDedicatedTunnelByChannel(_ channel: Channel) {
        lock.withLockVoid {
            let channelID = ObjectIdentifier(channel)
            if let key = connectionIDsByChannel[channelID],
               allConnections[key]?.isDedicatedTunnel == true {
                removeConnectionLocked(id: key)
            }
        }
    }

    package func healthCheck(urlString: String) async -> HealthCheckResult {
        // The explicit check runs whether or not the proxy was started, so it cannot rely on
        // the start's validation. A persisted duration past the runtime's range is refused
        // here, with its field, before any conversion or connect.
        if let field = Self.firstUnrepresentableExchangeDuration(in: configProvider()) {
            let refusal = RuntimeDurationRefusal(scope: .healthCheck, field: field)
            eventSink?(refusal.event)
            logger.log(.error, refusal.event.detail ?? refusal.event.event, category: .network)
            return .unhealthy(.configurationRefused(detail: refusal.errorDescription ?? ""), responseTimeMS: 0)
        }
        let start = Date()
        var head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: urlString)
        head.headers.add(name: "Host", value: URL(string: urlString)?.host ?? "example.com")
        // The probe timeout bounds a connect made for this check; a pooled
        // connection is reused as is.
        // Canonical seconds, not the whole-millisecond legacy reading: a 1.001-second
        // probe keeps its millisecond, and the floor is still one millisecond.
        let probeTimeout = TimeAmount.nanoseconds(max(DurationUnits.runtimeNanoseconds(configProvider().health.connectionCheckTimeout), 1_000_000))
        do {
            guard let selection = selectProxy(from: configProvider()) else { throw ConnectionPoolError.noUpstreamsConfigured }
            let proxy = selection.proxy
            let response: UpstreamExchangeResponse
            do {
                response = try await bufferedExchange(
                    head: head, requestBody: nil, selection: selection, allowRetry: true,
                    preferFreshConnection: false, authSource: nil, tried: nil, connectTimeout: probeTimeout, isHealthCheck: true
                ).get()
            } catch let error as ConnectionPoolError where error == .idleConnectionSilent {
                let event = RuntimeEvent(
                    kind: .health, event: "health.idle_connection_silent",
                    detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) retry=fresh_connection"
                )
                eventSink?(event)
                logger.log(.info, "Health check got no answer from \(proxy.endpoint) on an idle connection; asking a fresh one.", category: .network)
                response = try await bufferedExchange(
                    head: head, requestBody: nil, selection: selection, allowRetry: false,
                    preferFreshConnection: true, authSource: nil, tried: nil, connectTimeout: probeTimeout, isHealthCheck: true
                ).get()
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
            let code = Int(response.head.status.code)
            let upstream = response.upstream.endpoint
            if (200..<500).contains(code) {
                return .healthy(summary: "Healthy via \(upstream)", activeUpstream: upstream, responseTimeMS: elapsed)
            }
            return .unhealthy(.upstreamStatus(code: code, upstream: upstream), activeUpstream: upstream, responseTimeMS: elapsed)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
            let detail = error.displayDescription
            return .unhealthy(Self.healthFailure(for: error, detail: detail), responseTimeMS: elapsed)
        }
    }

    /// The durations an exchange converts: the probe budget, the response wait, and the
    /// connect budget. Every entry that can run an exchange (the explicit health check,
    /// tunnel start, `pm-tunnel`) asks `firstUnrepresentableExchangeDuration` before it
    /// converts anything, and refuses by field. Proxy start is validated already.
    package static let exchangeDurations: [RuntimeDurationField] = [
        .connectionCheckTimeout, .upstreamResponseTimeout, .upstreamConnectTimeout,
    ]

    /// The first exchange duration the runtime cannot hold, or nil. Only the field is
    /// returned, never the value.
    package static func firstUnrepresentableExchangeDuration(in config: ProxyConfig) -> RuntimeDurationField? {
        config.firstUnrepresentableDuration(among: exchangeDurations)
    }

    /// Recovery branches on this: only `.unreachable` skips re-authentication,
    /// so an upstream that answered with a final 407 must not land there.
    static func healthFailure(for error: Error, detail: String) -> HealthCheckFailure {
        if error.isCredentialUnavailable { return .credentialUnavailable(detail: detail) }
        if case ConnectionPoolError.authenticationRejected? = error as? ConnectionPoolError {
            return .authenticationRejected(detail: detail)
        }
        return .unreachable(detail: detail)
    }

    package func upstreamStatuses() -> [UpstreamRuntimeStatus] {
        let proxies = configProvider().enabledUpstreams
        return lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            return proxies.map { proxy in
                let breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
                return UpstreamRuntimeStatus(
                    id: proxy.id,
                    name: proxy.name,
                    endpoint: proxy.endpoint,
                    circuitState: breaker.state,
                    ewmaLatencyMS: breaker.ewmaLatencyMS,
                    consecutiveFailures: breaker.consecutiveFailures,
                    openUntil: breaker.state == .open ? breaker.openUntil : nil
                )
            }
        }
    }

    package func prewarmConnections(perUpstream: Int = 1) async {
        let proxies = lock.withLock {
            let current = configProvider().enabledUpstreams
            syncUpstreamStatesLocked(with: current)
            return current
        }
        guard !proxies.isEmpty, perUpstream > 0 else { return }

        await withTaskGroup(of: Void.self) { group in
            for proxy in proxies {
                for _ in 0..<perUpstream {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            // Through acquisition, so a prewarm dial holds a
                            // pool slot and is tracked for VPN migration.
                            // Not a selection: every upstream is prewarmed at
                            // once, and the last dial to land would otherwise
                            // become the active upstream (#164).
                            let connection = try await self.acquireConnection(
                                for: proxy, target: "prewarm", preferFreshConnection: true, selects: false
                            ).get()
                            self.release(connection, keepAlive: true)
                            self.logger.log(.debug, "Prewarmed upstream connection for \(proxy.endpoint).", category: .proxy)
                        } catch {
                            if let codes = ConnectionPoolError.localDialFailureCodes(error) {
                                self.recordLocalDialFailure(codes: codes, for: .forced(proxy))
                            } else if !ConnectionPoolError.isLocalNonUpstreamFailure(error) {
                                self.recordFailure(for: .forced(proxy))
                            }
                            self.logger.log(.debug, "Prewarm failed for \(proxy.endpoint): \(error.displayDescription)", category: .proxy)
                        }
                    }
                }
            }
        }
    }

    /// Pure filter: returns the IDs of connections that should be reaped as stalled.
    /// Dedicated tunnel connections are always exempt.
    package static func stalledConnectionIDs(
        from connections: some Collection<PooledUpstreamConnection>,
        olderThan timeout: TimeInterval
    ) -> Set<UUID> {
        let cutoff = Date().addingTimeInterval(-timeout)
        return Set(connections.filter {
            let state = $0.snapshot
            return !state.inUse && !state.isDedicatedTunnel && state.lastUsedAt < cutoff
        }.map(\.id))
    }

    /// Chooses and removes the stalled connections in one hold of the pool
    /// lock, so an acquisition can never hand one out after it was chosen;
    /// the channels close, and the log lines go out, after the lock is
    /// released.
    @discardableResult
    package func closeStalledConnections(olderThan timeout: TimeInterval) -> Int {
        let stale = lock.withLock {
            retireConnectionsLocked(ids: Self.stalledConnectionIDs(from: allConnections.values, olderThan: timeout))
        }
        for connection in stale {
            connection.channel.close(mode: .all, promise: nil)
            logger.log(.warning, "Closed stalled upstream connection to \(connection.proxy.endpoint).", category: .proxy)
        }
        return stale.count
    }

    // MARK: - Pool management

    /// Every connection in the pool authenticates again on its next
    /// exchange, including one whose exchange is in flight now: when that
    /// exchange ends it does not mark the connection authenticated again.
    package func resetAuthentication() {
        lock.withLockVoid {
            for connection in allConnections.values {
                connection.resetAuthentication()
            }
        }
    }

    package func switchToNextUpstream() -> String? {
        let proxies = configProvider().enabledUpstreams
        guard !proxies.isEmpty else { return nil }
        let nextIndex = lock.withLock { () -> Int in
            syncUpstreamStatesLocked(with: proxies)
            preferredProxyIndex = (preferredProxyIndex + 1) % proxies.count
            lastSelectedUpstreamID = proxies[preferredProxyIndex].id
            return preferredProxyIndex
        }
        return proxies[nextIndex].endpoint
    }

    package func activeUpstream() -> String? {
        let proxies = configProvider().enabledUpstreams
        guard !proxies.isEmpty else { return nil }
        return lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            if let lastSelectedUpstreamID,
               let proxy = proxies.first(where: { $0.id == lastSelectedUpstreamID }) {
                return proxy.endpoint
            }
            let index = min(preferredProxyIndex, max(0, proxies.count - 1))
            return proxies[index].endpoint
        }
    }

    package var enabledUpstreamCount: Int {
        configProvider().enabledUpstreams.count
    }

    package var eventLoop: EventLoop {
        group.next()
    }

    package var upstreamResponseTimeout: TimeAmount {
        let seconds = max(configProvider().upstreamResponseTimeoutSeconds, 0.1)
        return .nanoseconds(DurationUnits.runtimeNanoseconds(seconds))
    }

    package var allConnectionSnapshot: [PooledUpstreamConnection] {
        lock.withLock { Array(allConnections.values) }
    }

    /// Close pooled upstream connections according to `scope`.
    ///
    /// Default `scope: .all` preserves the historical behavior so existing call sites
    /// that genuinely want a full nuke (process shutdown, CLI cleanup) compile unchanged.
    ///
    /// New control-plane callers (listener recycle, proxy-config restart) should pass
    /// `.allButDedicated` or `.idleOnly` to avoid tearing down active client-owned tunnels.
    /// See `docs/design-vpn-flap-resilience.md` for the policy.
    ///
    /// The connections are chosen and removed in one hold of the pool lock,
    /// so a concurrent acquisition either took an idle connection first (it
    /// is then in use, and `.idleOnly` keeps it) or can no longer find it.
    /// The channels close after the lock is released.
    @discardableResult
    package func closeAll(scope: CloseScope = .all) -> Int {
        let closing = lock.withLock {
            retireConnectionsLocked(ids: Self.connectionIDsToClose(from: allConnections.values, scope: scope))
        }
        for connection in closing {
            connection.channel.close(mode: .all, promise: nil)
        }
        return closing.count
    }

    /// The runtime's outbound socket registry, for a caller dialing DIRECT
    /// beside this pool.
    package var socketRegistry: OutboundSocketRegistry { sockets }

    /// Pure filter exposed for unit testing: returns the IDs of connections that
    /// should be closed for a given `scope`. Mirrors the `stalledConnectionIDs`
    /// pattern so the policy can be tested without standing up a live pool.
    package static func connectionIDsToClose(
        from connections: some Collection<PooledUpstreamConnection>,
        scope: CloseScope
    ) -> Set<UUID> {
        switch scope {
        case .all:
            return Set(connections.map(\.id))
        case .allButDedicated:
            return Set(connections.lazy.filter { !$0.isDedicatedTunnel }.map(\.id))
        case .idleOnly:
            return Set(connections.lazy.filter {
                let state = $0.snapshot
                return !state.inUse && !state.isDedicatedTunnel
            }.map(\.id))
        }
    }

    private enum AcquireResult {
        case idle(PooledUpstreamConnection)
        case needsNew
        case exhausted
    }

    /// `connectTimeout` overrides the data-path budget for a new connection;
    /// the health check passes the probe timeout. An idle pooled connection
    /// is reused without connecting.
    /// `selects`: whether the connection makes `proxy` the active upstream.
    private func acquireConnection(
        for proxy: UpstreamProxy,
        target: String,
        preferFreshConnection: Bool,
        connectTimeout: TimeAmount? = nil,
        selects: Bool = true
    ) -> EventLoopFuture<PooledUpstreamConnection> {
        let config = configProvider()
        let maxConns = config.maxConnections
        var retired: [PooledUpstreamConnection] = []
        let result: AcquireResult = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            retired = pruneExpiredIdleConnectionsLocked(now: .now)
            if !preferFreshConnection {
                while let existing = idleConnections[proxy.id]?.popLast() {
                    guard allConnections[existing.id] != nil else { continue }
                    if isConnectionExpired(existing, now: .now) || !existing.channel.isActive || existing.wasRetiredByVPNTransition
                        || !namesCurrentEndpointLocked(existing.proxy) {
                        retired.append(contentsOf: retireConnectionsLocked(ids: [existing.id]))
                        continue
                    }
                    existing.update { state in
                        state.inUse = true
                        state.lastUsedAt = .now
                    }
                    if selects { lastSelectedUpstreamID = proxy.id }
                    return .idle(existing)
                }
            }
            if allConnections.count + pendingConnectionCount >= maxConns {
                return .exhausted
            }
            pendingConnectionCount += 1
            if selects { lastSelectedUpstreamID = proxy.id }
            preconditionCapacityLocked(maxConnections: maxConns)
            return .needsNew
        }
        for connection in retired {
            connection.channel.close(mode: .all, promise: nil)
        }

        switch result {
        case .idle(let conn):
            return conn.channel.eventLoop.makeSucceededFuture(conn)
        case .exhausted:
            return group.next().makeFailedFuture(ConnectionPoolError.poolExhausted)
        case .needsNew:
            return makeConnection(to: proxy, target: target, connectTimeout: connectTimeout, selects: selects).always { [weak self] _ in
                self?.lock.withLockVoid {
                    self?.pendingConnectionCount -= 1
                    self?.preconditionCapacityLocked(maxConnections: maxConns)
                }
            }
        }
    }

    private func acquireDedicatedTunnelConnection(
        for proxy: UpstreamProxy,
        target: String,
        config: ProxyConfig,
        isWanted: @escaping @Sendable () -> Bool
    ) -> EventLoopFuture<(PooledUpstreamConnection, ProxyConfig)> {
        let maxConns = config.maxConnections
        var retired: [PooledUpstreamConnection] = []
        let result: AcquireResult = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            retired = pruneExpiredIdleConnectionsLocked(now: .now)
            guard allConnections.count + pendingConnectionCount < maxConns else {
                return .exhausted
            }
            pendingConnectionCount += 1
            lastSelectedUpstreamID = proxy.id
            preconditionCapacityLocked(maxConnections: maxConns)
            return .needsNew
        }
        for connection in retired {
            connection.channel.close(mode: .all, promise: nil)
        }

        switch result {
        case .idle:
            preconditionFailure("Dedicated tunnels never reuse pooled idle connections")
        case .exhausted:
            return group.next().makeFailedFuture(ConnectionPoolError.poolExhausted)
        case .needsNew:
            return makeRawConnection(to: proxy, target: target, isWanted: isWanted).map { conn in
                (conn, config)
            }.always { [weak self] _ in
                self?.lock.withLockVoid {
                    self?.pendingConnectionCount -= 1
                    self?.preconditionCapacityLocked(maxConnections: maxConns)
                }
            }
        }
    }

    private func release(_ connection: PooledUpstreamConnection, keepAlive: Bool) {
        guard keepAlive, connection.channel.isActive, !isConnectionExpired(connection, now: .now) else {
            connection.channel.close(mode: .all, promise: nil)
            lock.withLockVoid {
                connection.update { state in
                    state.lastUsedAt = .now
                    state.inUse = false
                }
                self.removeConnectionLocked(id: connection.id)
            }
            return
        }

        let pooled: Bool = lock.withLock {
            connection.update { state in
                state.lastUsedAt = .now
                state.inUse = false
                state.hasIdled = true
            }
            // A connection retired while it was in use (`closeAll`, a close
            // that already landed) stays out: idle means a pool member.
            guard self.allConnections[connection.id] != nil else { return false }
            self.idleConnections[connection.proxy.id, default: []].append(connection)
            return true
        }
        if !pooled {
            // Whatever retired it closes it; this only makes sure nothing
            // outside the pool is left open.
            connection.channel.close(mode: .all, promise: nil)
        }
    }

    private func makeRawConnection(
        to proxy: UpstreamProxy, target: String, isWanted: @escaping @Sendable () -> Bool
    ) -> EventLoopFuture<PooledUpstreamConnection> {
        return connectToUpstreamProxy(proxy)
            .flatMapThrowing { [weak self] channel in
                // Only dedicated CONNECT tunnels dial raw; classified before
                // the pool publishes it, so no `closeAll(scope:
                // .allButDedicated)` can take it for a pooled connection.
                let connection = try Self.insert(channel, proxy: proxy, target: target, into: self, dedicatedTunnel: true, isWanted: isWanted)
                self?.logger.log(.info, "Connected to upstream proxy \(proxy.endpoint) (raw).", category: .proxy)
                return connection
            }
    }

    /// Hand a freshly dialed channel to `pool`. A pool released while the
    /// dial was in flight (shutdown, a config restart) closes the channel
    /// and fails the dial: nothing else would ever track or close it (#159).
    static func insert(
        _ channel: Channel, proxy: UpstreamProxy, target: String, into pool: ConnectionPool?, selects: Bool = true,
        dedicatedTunnel: Bool = false, isWanted: () -> Bool = { true }
    ) throws -> PooledUpstreamConnection {
        guard let pool else {
            channel.close(mode: .all, promise: nil)
            throw ChannelError.ioOnClosedChannel
        }
        let connection = PooledUpstreamConnection(proxy: proxy, channel: channel)
        if dedicatedTunnel {
            connection.isDedicatedTunnel = true
        }
        try pool.insertDialedConnection(connection, target: target, selects: selects, isWanted: isWanted)
        return connection
    }

    /// An exchange on a connection a VPN-transition sweep closed failed
    /// because of the sweep: report it as `vpnTransitionDuringConnect`, a
    /// local failure, so it is neither retried on a fresh upstream
    /// connection (routing may have gone DIRECT) nor fed to the breaker
    /// (#148). A client hang-up and a stream interrupted after the response
    /// began keep their own meaning.
    private func attributingRetirement<T>(_ exchange: EventLoopFuture<T>, connection: PooledUpstreamConnection) -> EventLoopFuture<T> {
        exchange.flatMapErrorThrowing { [weak self] error in
            guard let self,
                  !ConnectionPoolError.isClientClosedDuringResponse(error),
                  !ConnectionPoolError.isStreamingResponseInterrupted(error),
                  connection.wasRetiredByVPNTransition
            else { throw error }
            self.logger.log(.info, "Upstream exchange via \(connection.proxy.endpoint) ended by a VPN-transition sweep: \(error.displayDescription)", category: .proxy)
            throw ConnectionPoolError.vpnTransitionDuringConnect
        }
    }

    /// Insert a freshly dialed connection once the runtime's socket registry
    /// tracks it. A path a VPN transition removed while it connected (or a
    /// full registry) closes it instead, reports it, and fails the
    /// acquisition locally (#156). `target` is what the request asked for,
    /// sanitized here. A dedicated tunnel arrives already marked: once the
    /// lock below is released, any caller can see it.
    ///
    /// `isWanted` is read under that lock, the one `closeAll` takes: a
    /// connection is either in the pool before a `closeAll` that follows its
    /// caller's stop, which closes it, or refused here with
    /// `tunnelAbandoned`.
    func insertDialedConnection(
        _ connection: PooledUpstreamConnection, target: String, selects: Bool = true, isWanted: () -> Bool = { true }
    ) throws {
        connection.transitionTicket = try sockets.register(
            connection.channel, route: .upstream,
            target: SensitiveValueSanitizer.observableTarget(target), upstream: connection.proxy.endpoint
        )
        let admitted = lock.withLock {
            guard isWanted() else { return false }
            connection.inUse = true
            insertConnectionLocked(connection)
            if selects { lastSelectedUpstreamID = connection.proxy.id }
            return true
        }
        guard admitted else {
            connection.channel.close(mode: .all, promise: nil)
            throw ConnectionPoolError.tunnelAbandoned
        }
        // A connection that closes (a sweep, the upstream, a timeout) leaves
        // the pool at once instead of holding a slot until it is next picked.
        let id = connection.id
        connection.channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLockVoid { self.removeConnectionLocked(id: id) }
        }
    }

    private func makeConnection(
        to proxy: UpstreamProxy, target: String, connectTimeout: TimeAmount? = nil, selects: Bool = true
    ) -> EventLoopFuture<PooledUpstreamConnection> {
        return connectToUpstreamProxy(proxy, connectTimeout: connectTimeout) { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder(), name: ProxyPipelineNames.upstreamEncoder)
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)), name: ProxyPipelineNames.upstreamDecoder)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
            .flatMapThrowing { [weak self] channel in
                let connection = try Self.insert(channel, proxy: proxy, target: target, into: self, selects: selects)
                self?.logger.log(.info, "Connected to upstream proxy \(proxy.endpoint).", category: .proxy)
                return connection
            }
    }

    /// The data-path connect budget.
    private var dataPathConnectTimeout: TimeAmount {
        Self.dataPathConnectTimeout(
            configured: configProvider().upstreamConnectTimeoutSeconds, minimum: minimumConnectTimeout
        )
    }

    /// `configured`, clamped to `minimum ... maximumUpstreamConnectTimeout`,
    /// kept to the nanosecond: a whole-millisecond truncation here would turn a
    /// configured 1.001 seconds into 1 second. The clamp keeps the documented
    /// minimum and maximum; the value itself was admitted by validation, so the
    /// nanosecond conversion's precondition holds.
    static func dataPathConnectTimeout(configured: TimeInterval, minimum: TimeInterval) -> TimeAmount {
        let seconds = min(max(configured, minimum), HealthSection.maximumUpstreamConnectTimeout)
        return .nanoseconds(DurationUnits.runtimeNanoseconds(seconds))
    }

    private func upstreamProxyBootstrap(
        connectTimeout: TimeAmount? = nil,
        channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
    ) -> ClientBootstrap {
        let keepalive = TCPKeepaliveConfig.default
        let bootstrap = ClientBootstrap(group: group)
            .resolver(AddressFamilyAwareResolver(group: group))
            .connectTimeout(connectTimeout ?? dataPathConnectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.tcpNoDelay, value: 1)
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle), value: CInt(keepalive.keepIdleSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval), value: CInt(keepalive.keepIntervalSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount), value: CInt(keepalive.keepCountProbes))

        if let channelInitializer {
            return bootstrap.channelInitializer(channelInitializer)
        }
        return bootstrap
    }

    private func connectToUpstreamProxy(
        _ proxy: UpstreamProxy,
        connectTimeout: TimeAmount? = nil,
        channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
    ) -> EventLoopFuture<Channel> {
        let makeBootstrap: @Sendable () -> ClientBootstrap = { [weak self] in
            guard let self else {
                return ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            }
            return self.upstreamProxyBootstrap(connectTimeout: connectTimeout, channelInitializer: channelInitializer)
        }

        return makeBootstrap()
            .connect(host: proxy.host, port: proxy.port)
            .flatMap { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                if channel.remoteAddress == nil {
                    self.logger.log(.warning, "Half-open upstream proxy channel detected for \(proxy.endpoint) (remoteAddress nil, localAddress \(String(describing: channel.localAddress))); falling back to explicit IPv4 connect", category: .proxy)
                }
                return Self.applyHalfOpenUpstreamFallback(
                    upstreamChannel: channel,
                    proxy: proxy,
                    on: channel.eventLoop,
                    ipv4Reconnect: { address in
                        self.logger.log(.info, "Half-open upstream fallback: reconnecting to \(proxy.endpoint) via IPv4 \(address)", category: .proxy)
                        return makeBootstrap()
                            .connect(to: address)
                            .hop(to: channel.eventLoop)
                    }
                )
            }
    }

    package static func applyHalfOpenUpstreamFallback(
        upstreamChannel: Channel,
        proxy: UpstreamProxy,
        on eventLoop: EventLoop,
        ipv4Reconnect: @escaping @Sendable (SocketAddress) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        HalfOpenChannelFallback.apply(
            upstreamChannel: upstreamChannel,
            host: proxy.host,
            port: proxy.port,
            on: eventLoop,
            ipv4Reconnect: ipv4Reconnect
        )
    }

    /// The upstream the next attempt of a tunnel dials, chosen as any
    /// selection is but among the enabled upstreams not in `tried`: one call
    /// asks each upstream at most once, whatever their latency scores say.
    /// Nil once every enabled upstream has been tried, and for a failover
    /// (`tried` not empty) when no untried upstream may be asked now.
    package func selectTunnelUpstream(excluding tried: Set<UUID>) -> UpstreamSelection? {
        selectProxy(from: configProvider(), excluding: tried)
    }

    /// Picks among the upstreams whose breaker is closed or may probe now,
    /// taking the probe slot of one that may. The first pick of a request
    /// (`tried` empty) has a last resort when none may be asked: the
    /// longest-open breaker is forced half-open, or with none open the
    /// preferred upstream is dialled, so a request is not failed while every
    /// upstream is in backoff. A failover has none: an upstream in backoff,
    /// or one whose probe another attempt holds, is not asked, and the
    /// failure that led to the failover stands.
    ///
    /// Among those, an upstream whose last dial failed on this machine is
    /// passed over while any other may be asked (`locallyUnreachableSince`).
    private func selectProxy(from config: ProxyConfig, excluding tried: Set<UUID> = []) -> UpstreamSelection? {
        let proxies = config.enabledUpstreams
        let untried = proxies.filter { !tried.contains($0.id) }
        guard !untried.isEmpty else { return nil }
        let recheckInterval = breakerThresholds(from: config).baseOpenInterval
        let result: (selection: UpstreamSelection?, pending: PendingTransitionEmission?) = lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            let now = Date.now
            let candidates = untried.filter { proxy in
                let breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
                return breaker.state == .closed || breaker.mayProbe(now: now)
            }
            guard !candidates.isEmpty else {
                guard tried.isEmpty else { return (nil, nil) }
                return lastResortLocked(among: proxies)
            }
            let reachable = candidates.filter { !isLocallyUnreachableLocked($0.id, now: now, recheckInterval: recheckInterval) }
            let selected = chooseProxyLocked(from: reachable.isEmpty ? candidates : reachable)
            var breaker = breakers[selected.id] ?? UpstreamCircuitBreaker()
            let claimed = breaker.claimProbe(now: now)
            breakers[selected.id] = breaker
            lastSelectedUpstreamID = selected.id
            if let selectedIndex = proxies.firstIndex(where: { $0.id == selected.id }) {
                preferredProxyIndex = selectedIndex
            }
            return (
                UpstreamSelection(proxy: selected, probe: claimed?.claim),
                claimed?.transition.map { PendingTransitionEmission(transition: $0, name: selected.name, endpoint: selected.endpoint) }
            )
        }
        if let pending = result.pending {
            publishEmission(pending)
        }
        return result.selection
    }

    /// No upstream may be asked now. The longest-open breaker is forced into
    /// half-open, mirroring the pre-extraction behaviour; with none open
    /// (each half-open with its probe in flight) the preferred upstream is
    /// dialled with no probe slot.
    private func lastResortLocked(among proxies: [UpstreamProxy]) -> (selection: UpstreamSelection?, pending: PendingTransitionEmission?) {
        let longestOpen = proxies
            .filter { breakers[$0.id]?.state == .open }
            .min { (breakers[$0.id]?.lastOpenedAt ?? .distantFuture) < (breakers[$1.id]?.lastOpenedAt ?? .distantFuture) }
        if let fallback = longestOpen, var breaker = breakers[fallback.id], let forced = breaker.forceHalfOpen() {
            breakers[fallback.id] = breaker
            lastSelectedUpstreamID = fallback.id
            if let index = proxies.firstIndex(where: { $0.id == fallback.id }) { preferredProxyIndex = index }
            return (
                UpstreamSelection(proxy: fallback, probe: forced.claim),
                PendingTransitionEmission(transition: forced.transition, name: fallback.name, endpoint: fallback.endpoint)
            )
        }
        return (.forced(proxies[min(preferredProxyIndex, max(0, proxies.count - 1))]), nil)
    }

    /// - Parameter tried: as for a streaming exchange, the upstreams this
    ///   request already dialled, or nil to keep it on `selection`, as the
    ///   health check does: it asks about the upstream it selected.
    private func bufferedExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        selection: UpstreamSelection?,
        allowRetry: Bool,
        preferFreshConnection: Bool,
        authSource: String?,
        tried: Set<UUID>?,
        connectTimeout: TimeAmount? = nil,
        isHealthCheck: Bool = false
    ) -> EventLoopFuture<UpstreamExchangeResponse> {
        let config = configProvider()
        guard let selection = selection ?? selectProxy(from: config) else {
            return group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
        }
        let proxy = selection.proxy

        let start = Date()
        let attempt: EventLoopFuture<UpstreamExchangeResponse> = acquireConnection(
            for: proxy,
            target: head.uri,
            preferFreshConnection: preferFreshConnection,
            connectTimeout: connectTimeout
        ).flatMapErrorThrowing { throw AcquisitionFailure(cause: $0) }
        .flatMap { [weak self] connection in
            guard let self else {
                return connection.channel.eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
            }
            return self.attributingRetirement(
                self.performBufferedExchange(head: head, requestBody: requestBody, connection: connection, proxy: proxy, authSource: authSource),
                connection: connection
            )
                .flatMapErrorThrowing { error in
                    if isHealthCheck, connection.hasIdled, ConnectionPoolError.isUpstreamResponseTimedOut(error) {
                        throw ConnectionPoolError.idleConnectionSilent
                    }
                    throw error
                }
                .flatMap { response in
                    self.recordSuccess(for: response.upstream, latencyMS: Int(Date().timeIntervalSince(start) * 1_000))
                    return connection.channel.eventLoop.makeSucceededFuture(response)
                }
        }
        // Note: this `.flatMapError` is on the outer chain (`acquireConnection +
        // performBufferedExchange`), not just on `performBufferedExchange`'s
        // result. That's deliberate: connect-refused failures from
        // `acquireConnection` (e.g. upstream-down case in `pm-sim
        // upstream-flap`) must also feed `recordFailure` so the breaker can
        // trip. Pre-extraction the chain was nested and connect failures
        // bypassed the breaker entirely — a real-world bug, not just a
        // scenario quirk.
        return attempt.flatMapError { [weak self] (error: Error) -> EventLoopFuture<UpstreamExchangeResponse> in
            let acquisitionFailed = error is AcquisitionFailure
            let cause = (error as? AcquisitionFailure)?.cause ?? error
            guard let self else { return attempt.eventLoop.makeFailedFuture(cause) }
            let shouldRetry = allowRetry
                && Self.isIdempotentMethod(head.method)
                && Self.isRetryableConnectionError(cause)
            if shouldRetry {
                self.logger.log(.debug, "Retrying idempotent request via fresh connection after upstream reset (\(proxy.endpoint)).", category: .proxy)
                return self.bufferedExchange(
                    head: head,
                    requestBody: requestBody,
                    selection: selection,
                    allowRetry: false,
                    preferFreshConnection: true,
                    authSource: authSource,
                    tried: tried,
                    connectTimeout: connectTimeout,
                    isHealthCheck: isHealthCheck
                )
            }
            // Only a health check meets an idle socket's silence, and it asks a fresh connection with this same
            // selection next. That attempt settles it, so the probe slot stays claimed across the retry.
            if !ConnectionPoolError.isIdleConnectionSilent(cause) {
                self.recordExchangeError(cause, for: selection, origin: ExchangeOrigin(head))
            }
            if acquisitionFailed, let next = self.localDialFailover(after: cause, from: proxy, tried: tried) {
                return self.bufferedExchange(
                    head: head,
                    requestBody: requestBody,
                    selection: next.selection,
                    allowRetry: allowRetry,
                    preferFreshConnection: preferFreshConnection,
                    authSource: authSource,
                    tried: next.tried,
                    connectTimeout: connectTimeout,
                    isHealthCheck: isHealthCheck
                )
            }
            return self.group.next().makeFailedFuture(cause)
        }
    }

    private func performBufferedExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        connection: PooledUpstreamConnection,
        proxy: UpstreamProxy,
        authSource: String?
    ) -> EventLoopFuture<UpstreamExchangeResponse> {
        let auth = connection.authenticationState()
        let promise = connection.channel.eventLoop.makePromise(of: UpstreamExchangeResponse.self)
        let handler = HTTPExchangeHandler(
            connection: connection,
            authenticatorProvider: self.authenticatorProvider,
            originalHead: head,
            body: requestBody,
            isAuthenticated: auth.authenticated,
            authSource: authSource,
            authHandshakeLimiter: authHandshakeLimiter,
            authLimitProvider: authHandshakeLimits,
            eventSink: eventSink,
            responseTimeout: upstreamResponseTimeout,
            responsePromise: promise
        )

        return connection.channel.pipeline.addHandler(handler).flatMap {
            handler.start()
            return promise.futureResult
        }.flatMapError { error in
            promise.fail(error)
            self.logger.log(.warning, "Exchange via \(proxy.endpoint) failed: \(error.displayDescription)", category: .proxy)
            connection.channel.close(mode: .all, promise: nil)
            self.lock.withLockVoid {
                self.removeConnectionLocked(id: connection.id)
            }
            return connection.channel.eventLoop.makeFailedFuture(error)
        }.flatMap { response in
            connection.markAuthenticated(since: auth.generation, authMethod: response.authMethod)
            self.release(connection, keepAlive: response.head.isKeepAlive)
            return connection.channel.eventLoop.makeSucceededFuture(response)
        }
    }

    private func performStreamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        connection: PooledUpstreamConnection,
        proxy: UpstreamProxy,
        authSource: String?,
        onStreamedHead: (@Sendable () -> Void)?
    ) -> EventLoopFuture<StreamingExchangeResult> {
        let auth = connection.authenticationState()
        let promise = connection.channel.eventLoop.makePromise(of: StreamingExchangeResult.self)
        let handler = HTTPExchangeHandler(
            connection: connection,
            authenticatorProvider: self.authenticatorProvider,
            originalHead: head,
            body: requestBody,
            isAuthenticated: auth.authenticated,
            authSource: authSource,
            authHandshakeLimiter: authHandshakeLimiter,
            authLimitProvider: authHandshakeLimits,
            eventSink: eventSink,
            clientChannel: clientChannel,
            responseTimeout: upstreamResponseTimeout,
            streamingPromise: promise,
            onStreamedHead: onStreamedHead
        )

        return connection.channel.pipeline.addHandler(handler).flatMap {
            handler.start()
            return promise.futureResult
        }.flatMapError { error in
            promise.fail(error)
            // The caller reports every failure once: `HTTPProxyHandler`
            // emits `upstream.exchange_failed` (or `request.client_closed`
            // for a hang-up) and derives its log line from the event.
            connection.channel.close(mode: .all, promise: nil)
            self.lock.withLockVoid {
                self.removeConnectionLocked(id: connection.id)
            }
            return connection.channel.eventLoop.makeFailedFuture(error)
        }.flatMap { result in
            connection.markAuthenticated(since: auth.generation, authMethod: result.authMethod)
            self.release(connection, keepAlive: result.keepAlive)
            return connection.channel.eventLoop.makeSucceededFuture(result)
        }
    }

    private func recordSuccess(for proxy: UpstreamProxy, latencyMS: Int) {
        var emittedTransition: UpstreamCircuitBreaker.Transition?
        var reachableAgain = false
        lock.withLockVoid {
            syncUpstreamStatesLocked(with: configProvider().enabledUpstreams)
            var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
            emittedTransition = breaker.recordSuccess(latencyMS: latencyMS)
            breakers[proxy.id] = breaker
            if namesCurrentEndpointLocked(proxy) {
                silences[proxy.id] = nil
                reachableAgain = locallyUnreachableSince.removeValue(forKey: proxy.id) != nil
            }
            lastSelectedUpstreamID = proxy.id
        }
        if reachableAgain {
            emitLocallyReachable(name: proxy.name, endpoint: proxy.endpoint, reason: "success")
        }
        if let emittedTransition {
            emitTransition(emittedTransition, for: proxy)
        }
    }

    /// Feeds the breaker from a failed exchange or tunnel (#197). A response timeout is a silence on
    /// `origin`, which counts only across origins. A status the upstream answered with is an answer, so
    /// it clears the pending silences and then counts as the failure it was before. A local refusal counts nothing
    /// and gives back the probe slot the selection held, as does a dial that failed on this machine (`isLocalDialFailure`).
    package func recordExchangeError(_ error: Error, for selection: UpstreamSelection, origin: ExchangeOrigin) {
        if ConnectionPoolError.isUpstreamResponseTimedOut(error) {
            recordSilence(for: selection, origin: origin)
        } else if case .upstreamReturnedStatus(let status, _)? = error as? ConnectionPoolError,
                  !answeredStatusAccounting.counts(status) {
            recordUncountedAnswer(status: status, for: selection, origin: origin)
        } else if ConnectionPoolError.isUpstreamAnswer(error) {
            recordFailure(for: selection, answered: true)
        } else if ConnectionPoolError.isLocalNonUpstreamFailure(error) {
            releaseProbe(of: selection)
        } else if let codes = ConnectionPoolError.localDialFailureCodes(error) {
            recordLocalDialFailure(codes: codes, for: selection)
        } else {
            recordFailure(for: selection)
        }
    }

    /// A dial that failed on this machine: nothing is charged and the probe
    /// slot the selection held is given back, but the upstream is passed over
    /// while another may be asked (`locallyUnreachableSince`), so one that
    /// can never be dialled from here, such as an IPv6-only upstream on an
    /// IPv4-only network, is not picked on every request for its latency.
    private func recordLocalDialFailure(codes: String, for selection: UpstreamSelection) {
        let proxy = selection.proxy
        let config = configProvider()
        let recheckInterval = breakerThresholds(from: config).baseOpenInterval
        let demoted: Bool = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            if let claim = selection.probe, var breaker = breakers[proxy.id], breaker.releaseProbe(claim) {
                breakers[proxy.id] = breaker
            }
            guard namesCurrentEndpointLocked(proxy) else { return false }
            let now = Date()
            let wasPassedOver = isLocallyUnreachableLocked(proxy.id, now: now, recheckInterval: recheckInterval)
            locallyUnreachableSince[proxy.id] = now
            return !wasPassedOver
        }
        reportUncharged(proxy, reason: "local_dial", extra: " errno=\(codes)")
        guard demoted else { return }
        let event = RuntimeEvent(
            kind: .health, event: "upstream.locally_unreachable",
            detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) errno=\(codes) recheckAfter=\(Int(recheckInterval))s\(poolTag)"
        )
        eventSink?(event)
        logger.log(.notice, "Upstream \(proxy.name) could not be dialled from this machine (\(codes)); passing it over while another upstream may be asked, for \(Int(recheckInterval))s. (\(event.event))", category: .network)
    }

    /// Whether `id` is passed over for a local dial failure less than `recheckInterval` ago.
    private func isLocallyUnreachableLocked(_ id: UUID, now: Date, recheckInterval: TimeInterval) -> Bool {
        guard let since = locallyUnreachableSince[id] else { return false }
        return now.timeIntervalSince(since) < recheckInterval
    }

    /// A failure the pool did not charge to the upstream's breaker: it failed on this machine (`local_dial`), or
    /// another attempt holds the half-open probe that gives the breaker its verdict (`probe_held`). Either can
    /// repeat on every request, so it is reported once a minute per upstream and reason.
    private func reportUncharged(_ proxy: UpstreamProxy, reason: String, extra: String = "") {
        guard let suppressed = unchargedFailureGate.admit(host: proxy.endpoint, reason: reason) else { return }
        let event = RuntimeEvent(
            kind: .health, event: "upstream.failure_uncharged",
            detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) reason=\(reason)\(extra) suppressed=\(suppressed)\(poolTag)"
        )
        eventSink?(event)
        logger.log(.info, "Upstream \(proxy.name)'s failure was not counted against its breaker (\(reason)). (\(event.event))", category: .network)
    }

    private func emitLocallyReachable(name: String, endpoint: String, reason: String) {
        let event = RuntimeEvent(
            kind: .health, event: "upstream.locally_reachable",
            detail: "upstream=\(name) endpoint=\(endpoint) reason=\(reason)\(poolTag)"
        )
        eventSink?(event)
        logger.log(.notice, "Upstream \(name) is selectable again (\(reason)). (\(event.event))", category: .network)
    }

    /// An attempt that ends with no verdict on its upstream, such as one its
    /// caller gave up, gives back the probe slot its selection claimed, so
    /// the next request can probe. A slot another attempt holds stays held.
    package func releaseProbe(of selection: UpstreamSelection) {
        guard let claim = selection.probe else { return }
        lock.withLockVoid {
            guard var breaker = breakers[selection.proxy.id], breaker.releaseProbe(claim) else { return }
            breakers[selection.proxy.id] = breaker
        }
    }

    /// An answer this pool does not count: it clears the pending silences, as any answer does, and frees the half-open probe slot the selection held.
    private func recordUncountedAnswer(status: Int, for selection: UpstreamSelection, origin: ExchangeOrigin) {
        let proxy = selection.proxy
        let probeReleased = lock.withLock {
            syncUpstreamStatesLocked(with: configProvider().enabledUpstreams)
            if namesCurrentEndpointLocked(proxy) { silences[proxy.id] = nil }
            guard let claim = selection.probe, var breaker = breakers[proxy.id], breaker.releaseProbe(claim) else { return false }
            breakers[proxy.id] = breaker
            return true
        }
        guard probeReleased else { return }
        eventSink?(RuntimeEvent(
            kind: .health, event: "upstream.probe_released",
            detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) origin=\(origin) answered=\(status)\(poolTag)"
        ))
        logger.log(.info, "Upstream \(proxy.name)'s half-open probe got HTTP \(status) for \(origin), which this pool does not count; the next request probes again.", category: .network)
    }

    /// A completion about an endpoint this id no longer names says nothing about the current one.
    private func namesCurrentEndpointLocked(_ proxy: UpstreamProxy) -> Bool {
        upstreamIdentities[proxy.id]?.endpoint == proxy.endpoint
    }

    private func recordSilence(for selection: UpstreamSelection, origin: ExchangeOrigin) {
        let proxy = selection.proxy
        let config = configProvider()
        let thresholds = breakerThresholds(from: config)
        enum Outcome {
            case probeHeldElsewhere
            case probeReleased
            case counted(origins: [ExchangeOrigin], transition: UpstreamCircuitBreaker.Transition?)
        }
        let outcome: Outcome? = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            // Another attempt's probe gives this breaker its verdict (`recordFailureLocked`).
            if breakers[proxy.id]?.probeIsHeld(byOtherThan: selection.probe) == true { return .probeHeldElsewhere }
            var counts = false
            var pending: [ExchangeOrigin] = []
            if namesCurrentEndpointLocked(proxy) {
                var ledger = silences[proxy.id] ?? UpstreamSilences()
                counts = ledger.recordSilence(origin: origin)
                pending = ledger.origins
                silences[proxy.id] = ledger
            }
            var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
            guard counts else {
                guard let claim = selection.probe, breaker.releaseProbe(claim) else { return nil }
                breakers[proxy.id] = breaker
                return .probeReleased
            }
            guard breaker.state != .open else { return nil }
            guard case let .counted(transition) = recordFailureLocked(for: selection, thresholds: thresholds) else { return .probeHeldElsewhere }
            return .counted(origins: pending, transition: transition)
        }
        switch outcome {
        case nil:
            return
        case .probeHeldElsewhere:
            reportUncharged(proxy, reason: "probe_held")
        case .probeReleased:
            eventSink?(RuntimeEvent(
                kind: .health, event: "upstream.probe_released",
                detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) origin=\(origin)\(poolTag)"
            ))
            logger.log(.info, "Upstream \(proxy.name)'s half-open probe met only a silence from \(origin); the next request probes again.", category: .network)
        case let .counted(counted, transition):
            let origins = counted.map(\.description)
            eventSink?(RuntimeEvent(
                kind: .health, event: "upstream.silence_counted",
                detail: "upstream=\(proxy.name) endpoint=\(proxy.endpoint) origin=\(origin) origins=\(origins.joined(separator: ","))\(poolTag)"
            ))
            logger.log(.notice, "Upstream \(proxy.name) answered nothing for \(origins.count) origins (\(origins.joined(separator: ", "))); counting the silence as a failure.", category: .network)
            if let transition {
                emitTransition(transition, for: proxy)
            }
        }
    }

    private func recordFailure(for selection: UpstreamSelection, answered: Bool = false) {
        let proxy = selection.proxy
        let config = configProvider()
        let thresholds = breakerThresholds(from: config)
        let verdict: FailureVerdict = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            if answered, namesCurrentEndpointLocked(proxy) { silences[proxy.id] = nil }
            return recordFailureLocked(for: selection, thresholds: thresholds)
        }
        switch verdict {
        case .probeHeldElsewhere:
            reportUncharged(proxy, reason: "probe_held")
        case .counted(let transition?):
            emitTransition(transition, for: proxy)
        case .counted(nil):
            break
        }
    }

    private enum FailureVerdict {
        /// A half-open breaker whose probe another attempt holds ignored it.
        case probeHeldElsewhere
        case counted(UpstreamCircuitBreaker.Transition?)
    }

    /// A half-open breaker whose probe slot an attempt holds takes its verdict from that attempt alone. Another
    /// attempt's failure, such as a request the first pick's last resort dialled with no claim while every probe was
    /// taken, leaves it as it is: counting it would reopen the breaker under the probe. Its success still closes it.
    private func recordFailureLocked(for selection: UpstreamSelection, thresholds: BreakerThresholds) -> FailureVerdict {
        let proxy = selection.proxy
        var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
        if breaker.probeIsHeld(byOtherThan: selection.probe) { return .probeHeldElsewhere }
        let transition = breaker.recordFailure(
            now: Date(),
            threshold: thresholds.failureThreshold,
            windowSeconds: thresholds.windowSeconds,
            baseOpenInterval: thresholds.baseOpenInterval,
            maxOpenInterval: thresholds.maxOpenInterval
        )
        breakers[proxy.id] = breaker
        return .counted(transition)
    }

    /// Reset every upstream's circuit breaker to closed without touching its
    /// EWMA latency, and drop the silences recorded on the old path. Called by
    /// `ProxyOrchestrator` after a VPN flap recovers
    /// (`.reasserting → .connected`) so the next request through each upstream
    /// gets an honest first attempt instead of being rejected by an open
    /// circuit that was tripped on the now-stale flap-network path.
    ///
    /// Latency stats (EWMA) are preserved by the breaker's `reset(_:_:)`
    /// because the upstream itself didn't change, only the path through the
    /// kernel did. See `docs/design-vpn-flap-resilience.md` § "Pool Hardening".
    ///
    /// Every upstream passed over for a local dial failure is selectable
    /// again too: the routing it failed on has changed.
    package func resetCircuitsAfterFlap() {
        let baseOpenInterval = breakerThresholds(from: configProvider()).baseOpenInterval
        var pending: [PendingTransitionEmission] = []
        var reachableAgain: [(name: String, endpoint: String)] = []
        lock.withLockVoid {
            syncUpstreamStatesLocked(with: configProvider().enabledUpstreams)
            silences.removeAll()
            reachableAgain = locallyUnreachableSince.keys.compactMap { upstreamIdentities[$0] }.sorted { $0.name < $1.name }
            locallyUnreachableSince.removeAll()
            for (id, var breaker) in breakers {
                if let transition = breaker.reset(reason: .vpnFlapRecovered, baseOpenInterval: baseOpenInterval) {
                    let identity = upstreamIdentities[id]
                    pending.append(PendingTransitionEmission(
                        transition: transition,
                        name: identity?.name ?? "unknown",
                        endpoint: identity?.endpoint ?? "unknown"
                    ))
                }
                breakers[id] = breaker
            }
        }
        for upstream in reachableAgain {
            emitLocallyReachable(name: upstream.name, endpoint: upstream.endpoint, reason: "reset_vpn_flap")
        }
        for emission in pending {
            publishEmission(emission)
        }
    }

    private func syncUpstreamStatesLocked(with proxies: [UpstreamProxy]) {
        let allowedIDs = Set(proxies.map(\.id))
        breakers = breakers.filter { allowedIDs.contains($0.key) }
        silences = silences.filter { allowedIDs.contains($0.key) }
        locallyUnreachableSince = locallyUnreachableSince.filter { allowedIDs.contains($0.key) }
        upstreamIdentities = upstreamIdentities.filter { allowedIDs.contains($0.key) }
        for proxy in proxies {
            if breakers[proxy.id] == nil {
                breakers[proxy.id] = UpstreamCircuitBreaker()
            }
            // Refresh identity on every sync; the user may have renamed an
            // upstream or moved it to a new host without changing its UUID.
            if let known = upstreamIdentities[proxy.id], known.endpoint != proxy.endpoint {
                silences[proxy.id] = nil
                locallyUnreachableSince[proxy.id] = nil
            }
            upstreamIdentities[proxy.id] = (proxy.name, proxy.endpoint)
        }
    }

    /// Container the callers that move a breaker under the pool lock use to
    /// publish its transitions OUTSIDE the lock. The fields are pre-
    /// resolved (`name` + `endpoint` already looked up while still holding
    /// the lock) so the publish path is purely a `eventSink?` + `logger.log`
    /// fan-out — no further state lookups, no further locking.
    private struct PendingTransitionEmission {
        let transition: UpstreamCircuitBreaker.Transition
        let name: String
        let endpoint: String
    }

    private func chooseProxyLocked(from proxies: [UpstreamProxy]) -> UpstreamProxy {
        guard proxies.count > 1 else { return proxies[0] }

        selectionCounter += 1
        let preferredIndex = min(preferredProxyIndex, max(0, proxies.count - 1))
        let firstIndex = (preferredIndex + selectionCounter) % proxies.count
        let secondIndex = (preferredIndex + (selectionCounter * 7) + 1) % proxies.count

        let first = proxies[firstIndex]
        let second = proxies[secondIndex]
        let firstScore = breakers[first.id]?.ewmaLatencyMS ?? Double.greatestFiniteMagnitude
        let secondScore = breakers[second.id]?.ewmaLatencyMS ?? Double.greatestFiniteMagnitude
        return firstScore <= secondScore ? first : second
    }

    // MARK: - Circuit breaker helpers

    private struct BreakerThresholds {
        var failureThreshold: Int
        var windowSeconds: TimeInterval
        var baseOpenInterval: TimeInterval
        var maxOpenInterval: TimeInterval
    }

    private func breakerThresholds(from config: ProxyConfig) -> BreakerThresholds {
        // All four thresholds live on `HealthSection`. The defaults preserve
        // the legacy hardcoded values (5 / 30 s / 300 s), so existing configs
        // that don't carry the keys still behave identically.
        BreakerThresholds(
            failureThreshold: config.circuitFailureThreshold,
            windowSeconds: config.circuitBreakerWindowSeconds,
            baseOpenInterval: config.circuitBaseOpenIntervalSeconds,
            maxOpenInterval: config.circuitMaxOpenIntervalSeconds
        )
    }

    /// Fan a breaker transition out to the runtime event log + the local
    /// `logger`. Used by `recordSuccess` / `recordFailure` (which still
    /// operate on a known `UpstreamProxy` and call this directly after
    /// releasing the lock).
    private func emitTransition(
        _ transition: UpstreamCircuitBreaker.Transition,
        for proxy: UpstreamProxy
    ) {
        publishEmission(PendingTransitionEmission(
            transition: transition,
            name: proxy.name,
            endpoint: proxy.endpoint
        ))
    }

    /// Side-effect-only publish path. Pre-resolved emission (no state
    /// lookups, no locking) so it's safe to call from any context — most
    /// importantly from inside a `lock.withLock` *immediately after* the
    /// lock is released. Single funnel for both the recordSuccess /
    /// recordFailure direct-emit paths and the deferred-emit paths
    /// (`selectProxy`, `resetCircuitsAfterFlap`) that batch transitions
    /// to publish outside the pool lock.
    private func publishEmission(_ emission: PendingTransitionEmission) {
        let event: RuntimeEvent
        let logMessage: String
        let name = emission.name
        let endpoint = emission.endpoint
        switch emission.transition {
        case let .opened(reason, consecutiveFailures, openInterval):
            let reasonTag: String
            switch reason {
            case .thresholdReached: reasonTag = "threshold"
            case .probeFailed: reasonTag = "probe_failed"
            }
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_opened",
                detail: "upstream=\(name) endpoint=\(endpoint) reason=\(reasonTag) failures=\(consecutiveFailures) openInterval=\(Int(openInterval))s\(poolTag)"
            )
            logMessage = "Upstream \(name) circuit opened (\(reasonTag), \(Int(openInterval))s backoff)."
        case let .halfOpened(elapsedSeconds):
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_half_opened",
                detail: "upstream=\(name) endpoint=\(endpoint) openForSeconds=\(Int(elapsedSeconds))\(poolTag)"
            )
            logMessage = "Upstream \(name) circuit half-open (probe armed, was open \(Int(elapsedSeconds))s)."
        case let .closed(reason):
            let reasonTag: String
            switch reason {
            case .probeSuccess: reasonTag = "probe_success"
            case let .reset(resetReason):
                switch resetReason {
                case .vpnFlapRecovered: reasonTag = "reset_vpn_flap"
                case .daemonRestart: reasonTag = "reset_daemon_restart"
                case .manualOverride: reasonTag = "reset_manual"
                }
            }
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_closed",
                detail: "upstream=\(name) endpoint=\(endpoint) reason=\(reasonTag)\(poolTag)"
            )
            logMessage = "Upstream \(name) circuit closed (\(reasonTag))."
        }
        eventSink?(event)
        logger.log(.notice, logMessage, category: .network)
    }

    /// Removes the expired idle connections and returns them; the caller
    /// closes them once the lock is released.
    private func pruneExpiredIdleConnectionsLocked(now: Date) -> [PooledUpstreamConnection] {
        let expiredIDs = allConnections.values.compactMap { connection in
            (!connection.inUse && isConnectionExpired(connection, now: now)) ? connection.id : nil
        }
        return retireConnectionsLocked(ids: Set(expiredIDs))
    }

    /// Removes `ids` from the pool and returns the connections removed. The
    /// choice of `ids` and this removal belong in one hold of the lock: in
    /// between, an acquisition could hand out a connection being retired.
    /// The caller closes the returned channels after releasing the lock, so
    /// no close callback can run under it.
    private func retireConnectionsLocked(ids: Set<UUID>) -> [PooledUpstreamConnection] {
        let retired = ids.compactMap { allConnections[$0] }
        removeConnectionsLocked(ids: ids)
        return retired
    }

    private func insertConnectionLocked(_ connection: PooledUpstreamConnection) {
        allConnections[connection.id] = connection
        connectionIDsByChannel[ObjectIdentifier(connection.channel)] = connection.id
    }

    private func removeConnectionLocked(id: UUID) {
        if let connection = allConnections.removeValue(forKey: id) {
            connectionIDsByChannel.removeValue(forKey: ObjectIdentifier(connection.channel))
        }
        idleConnections = idleConnections.mapValues { connections in
            connections.filter { $0.id != id }
        }
    }

    private func removeConnectionsLocked(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let connection = allConnections.removeValue(forKey: id) {
                connectionIDsByChannel.removeValue(forKey: ObjectIdentifier(connection.channel))
            }
        }
        idleConnections = idleConnections.mapValues { connections in
            connections.filter { !ids.contains($0.id) }
        }
    }

    private func preconditionCapacityLocked(maxConnections: Int) {
        precondition(pendingConnectionCount >= 0, "ConnectionPool pending count must never go negative")
        precondition(
            allConnections.count + pendingConnectionCount <= maxConnections,
            "ConnectionPool invariant violated: active + idle + pending must stay <= maxConnections"
        )
    }

    private func isConnectionExpired(_ connection: PooledUpstreamConnection, now: Date) -> Bool {
        now.timeIntervalSince(connection.createdAt) >= Self.maxConnectionAgeSeconds
    }

    package static func streamingResponseInterruptedDetail(uri: String, upstream: String, cause: Error) -> String {
        "uri=\(SensitiveValueSanitizer.observableTarget(uri)) upstream=\(upstream) cause=\(cause.displayDescription)"
    }

    package static func streamingResponseInterruptedEvent(uri: String, upstream: String, cause: Error) -> RuntimeEvent {
        RuntimeEvent(
            kind: .connection,
            event: "streaming.response_interrupted",
            detail: streamingResponseInterruptedDetail(uri: uri, upstream: upstream, cause: cause)
        )
    }

    package static func upstreamResponseTimedOutEvent(uri: String, upstream: String) -> RuntimeEvent {
        RuntimeEvent(
            kind: .connection,
            event: "upstream.response_timeout",
            detail: "uri=\(SensitiveValueSanitizer.observableTarget(uri)) upstream=\(upstream)"
        )
    }

    private static func isIdempotentMethod(_ method: HTTPMethod) -> Bool {
        switch method {
        case .GET, .HEAD, .OPTIONS, .TRACE:
            return true
        default:
            return false
        }
    }

    private static func isRetryableConnectionError(_ error: Error) -> Bool {
        // A sweep closed it because routing left that path (#148), or the
        // pool refused it locally; the message fallback below would
        // otherwise match a "closed".
        if ConnectionPoolError.isLocalNonUpstreamFailure(error) { return false }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .ioOnClosedChannel, .alreadyClosed:
                return true
            default:
                break
            }
        }

        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNRESET, EPIPE, ETIMEDOUT:
                return true
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("connection reset")
            || message.contains("broken pipe")
            || message.contains("closed")
    }
}

/// Protocol-based 2-step HTTP exchange with optional response streaming.
/// Buffered mode (health checks): accumulates full response, resolves bufferedPromise.
/// Streaming mode (proxy traffic): forwards non-407 response parts directly to clientChannel.
private final class HTTPExchangeHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private enum Phase {
        case awaitingChallenge
        case awaitingFinal
    }

    private let connection: PooledUpstreamConnection
    private let authenticatorProvider: (UpstreamProxy) throws -> ProxyAuthenticator
    private let originalHead: HTTPRequestHead
    private let originalBody: HTTPRequestBody?
    private let isAuthenticated: Bool
    private let authSource: String?
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let authLimitProvider: @Sendable () -> AuthHandshakeLimiter.Limits
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let responseTimeout: TimeAmount

    private let clientChannel: Channel?
    private let bufferedPromise: EventLoopPromise<UpstreamExchangeResponse>?
    private let streamingPromise: EventLoopPromise<StreamingExchangeResult>?
    /// Called once, when a streamed response's head goes to the client.
    private var onStreamedHead: (@Sendable () -> Void)?

    private var phase: Phase
    private var responseHead: HTTPResponseHead?
    private var responseBody = ByteBufferAllocator().buffer(capacity: 0)
    private var challengeHeaders: [String] = []
    private var ctx: ChannelHandlerContext?
    private var isStreaming = false
    /// Set once a streamed response's `.end` has gone to the client. From
    /// there the client's write decides the exchange, and the upstream
    /// closing, which is how a response with no length ends, no longer can.
    private var streamedResponseEnded = false
    private var authenticator: ProxyAuthenticator?
    private var lastAuthMethod: String?
    private var authPermit: AuthHandshakePermit?
    private var backpressure: HTTPResponseBackpressureController?
    private var responseTimeoutTask: Scheduled<Void>?
    private var completed = false

    init(
        connection: PooledUpstreamConnection,
        authenticatorProvider: @escaping (UpstreamProxy) throws -> ProxyAuthenticator,
        originalHead: HTTPRequestHead,
        body: HTTPRequestBody?,
        isAuthenticated: Bool,
        authSource: String?,
        authHandshakeLimiter: AuthHandshakeLimiter,
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        responseTimeout: TimeAmount,
        responsePromise: EventLoopPromise<UpstreamExchangeResponse>
    ) {
        self.connection = connection
        self.authenticatorProvider = authenticatorProvider
        self.originalHead = originalHead
        self.originalBody = body
        self.isAuthenticated = isAuthenticated
        self.authSource = authSource
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
        self.responseTimeout = responseTimeout
        self.clientChannel = nil
        self.bufferedPromise = responsePromise
        self.streamingPromise = nil
        self.onStreamedHead = nil
        self.phase = isAuthenticated ? .awaitingFinal : .awaitingChallenge
    }

    init(
        connection: PooledUpstreamConnection,
        authenticatorProvider: @escaping (UpstreamProxy) throws -> ProxyAuthenticator,
        originalHead: HTTPRequestHead,
        body: HTTPRequestBody?,
        isAuthenticated: Bool,
        authSource: String?,
        authHandshakeLimiter: AuthHandshakeLimiter,
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        clientChannel: Channel,
        responseTimeout: TimeAmount,
        streamingPromise: EventLoopPromise<StreamingExchangeResult>,
        onStreamedHead: (@Sendable () -> Void)?
    ) {
        self.connection = connection
        self.authenticatorProvider = authenticatorProvider
        self.originalHead = originalHead
        self.originalBody = body
        self.isAuthenticated = isAuthenticated
        self.authSource = authSource
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
        self.responseTimeout = responseTimeout
        self.clientChannel = clientChannel
        self.bufferedPromise = nil
        self.streamingPromise = streamingPromise
        self.onStreamedHead = onStreamedHead
        self.phase = isAuthenticated ? .awaitingFinal : .awaitingChallenge
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.ctx = context
        if let clientChannel {
            let controller = HTTPResponseBackpressureController(
                clientChannel: clientChannel,
                upstreamChannel: context.channel
            )
            backpressure = controller
            controller.install()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        backpressure?.complete()
        backpressure = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        self.ctx = nil
    }

    func start() {
        guard let ctx else {
            failPromises(ConnectionPoolError.invalidResponse)
            return
        }
        if isAuthenticated {
            sendRequest(authHeader: nil, context: ctx)
        } else {
            guard beginAuthHandshake(host: connection.proxy.endpoint) else {
                failPromises(ConnectionPoolError.authHandshakeLimitExceeded)
                return
            }
            nonisolated(unsafe) let provider = self.authenticatorProvider
            let upstream = self.connection.proxy
            let host = upstream.host
            let eventLoop = ctx.eventLoop
            let handler = self
            nonisolated(unsafe) let capturedCtx = ctx
            Task { @Sendable in
                do {
                    let auth = try provider(upstream)
                    let token = try await AuthCredentialRetry.shared.initialToken(
                        from: auth, host: host, outageKey: upstream.endpoint, eventSink: handler.eventSink
                    )
                    eventLoop.execute {
                        handler.authenticator = auth
                        handler.recordAuthMethod(fromHeader: token)
                        handler.sendRequest(authHeader: token, context: capturedCtx)
                    }
                } catch {
                    eventLoop.execute { handler.failPromises(error) }
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            responseHead = head
            if head.status == .proxyAuthenticationRequired {
                // The challenge's body must still arrive before it can be
                // answered; a fresh deadline keeps a stalled one from holding
                // the exchange, and a probe slot, for good.
                resetResponseTimeout(context: context)
                challengeHeaders = head.headers["Proxy-Authenticate"]
            } else {
                finishAuthHandshake()
                cancelResponseTimeout()
            }
            if head.status != .proxyAuthenticationRequired, let clientChannel {
                isStreaming = true
                cancelResponseTimeout()
                onStreamedHead?()
                onStreamedHead = nil
                var clientHead = head
                HTTPHopByHopHeaders.sanitizeForwardedResponseHeaders(&clientHead.headers)
                if let backpressure {
                    backpressure.write(.head(clientHead), flush: false, upstreamContext: context)
                } else {
                    clientChannel.write(HTTPServerResponsePart.head(clientHead), promise: nil)
                }
            }
        case .body(var buffer):
            if isStreaming, let clientChannel {
                if let backpressure {
                    backpressure.write(.body(.byteBuffer(buffer)), flush: true, upstreamContext: context)
                } else {
                    clientChannel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                }
            } else {
                responseBody.writeBuffer(&buffer)
            }
        case .end(let trailers):
            if isStreaming, let clientChannel {
                streamedResponseEnded = true
                nonisolated(unsafe) let ctx = context
                // The client write completes on the client channel's loop.
                // Handler state is confined to this loop, so hop back before
                // touching it; `handlerRemoved` runs here too.
                let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                    ctx.eventLoop.assertInEventLoop()
                    self.backpressure?.complete()
                    ctx.pipeline.removeHandler(self, promise: nil)
                    switch result {
                    case .success:
                        self.succeedStreaming(StreamingExchangeResult(
                            upstream: self.connection.proxy,
                            keepAlive: self.responseHead?.isKeepAlive ?? false,
                            authMethod: self.resolvedAuthMethod()
                        ))
                    case .failure:
                        // The upstream answered in full; only the write to
                        // the client failed, so the client has gone.
                        self.failPromises(ConnectionPoolError.clientClosedDuringResponse)
                    }
                }
                // Trailers ride `.end` — dropping them here silently breaks
                // chunked responses that carry them (gRPC-Web status, digest
                // trailers). The direct path already forwards them.
                if let backpressure {
                    backpressure.write(.end(trailers), flush: true, upstreamContext: context)
                        .hop(to: context.eventLoop).whenComplete(finish)
                } else {
                    clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers))
                        .hop(to: context.eventLoop).whenComplete(finish)
                }
            } else {
                handleEnd(context: context)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        interrupt(error)
        context.close(promise: nil)
    }

    /// A peer that closes cleanly raises no error, only this. Without it an
    /// upstream that closed a kept-alive connection just as a request was
    /// written to it left the exchange pending for good: `handlerRemoved`
    /// cancels the response timeout, and nothing else completes the promise,
    /// so the caller never returned and the pool slot was never released.
    /// A response delimited by the close has already ended by the time this
    /// arrives, because the decoder sits ahead of this handler, but a streamed
    /// one is not `completed` yet: its `.end` is still being written on the
    /// client's loop. `streamedResponseEnded` covers that gap. `.eof` is what
    /// the pool retries an idempotent request on.
    func channelInactive(context: ChannelHandlerContext) {
        interrupt(ChannelError.eof)
        context.fireChannelInactive()
    }

    private func interrupt(_ error: Error) {
        guard !completed, !streamedResponseEnded else { return }
        if isStreaming {
            backpressure?.complete()
            eventSink?(ConnectionPool.streamingResponseInterruptedEvent(
                uri: originalHead.uri,
                upstream: connection.proxy.endpoint,
                cause: error
            ))
            clientChannel?.close(mode: .all, promise: nil)
            failPromises(ConnectionPoolError.streamingResponseInterrupted)
        } else {
            failPromises(error)
        }
    }

    private func failPromises(_ error: Error) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        backpressure?.complete()
        finishAuthHandshake()
        bufferedPromise?.fail(error)
        streamingPromise?.fail(error)
    }

    private func succeedBuffered(_ response: UpstreamExchangeResponse) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        bufferedPromise?.succeed(response)
    }

    private func succeedStreaming(_ result: StreamingExchangeResult) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        streamingPromise?.succeed(result)
    }

    private func handleEnd(context: ChannelHandlerContext) {
        guard let head = responseHead else {
            failPromises(ConnectionPoolError.invalidResponse)
            return
        }

        if head.status != .proxyAuthenticationRequired {
            context.pipeline.removeHandler(self, promise: nil)
            succeedBuffered(
                UpstreamExchangeResponse(
                    head: head,
                    body: responseBody,
                    upstream: connection.proxy,
                    authMethod: resolvedAuthMethod()
                )
            )
            return
        }
        // The challenge arrived in full. Computing the answer may take a
        // while (a Kerberos ticket); the answer's own send arms the next
        // deadline.
        cancelResponseTimeout()

        switch phase {
        case .awaitingChallenge:
            guard let auth = self.authenticator else {
                failPromises(ConnectionPoolError.authenticationRejected)
                context.close(promise: nil)
                return
            }
            let headers = challengeHeaders
            let host = connection.proxy.host
            let eventLoop = context.eventLoop
            let handler = self
            nonisolated(unsafe) let ctx = context
            Task { @Sendable in
                do {
                    // nil here means the authenticator has no token to send. Since we're
                    // inside a 407 response, the proxy still demands auth — this is a rejection.
                    // (Successful mutual-auth completion arrives as 200, not 407; see RFC 4559 §4.)
                    guard let response = try auth.processChallenge(headerValues: headers, host: host) else {
                        eventLoop.execute {
                            handler.failPromises(ConnectionPoolError.authenticationRejected)
                            ctx.close(promise: nil)
                        }
                        return
                    }
                    eventLoop.execute {
                        handler.phase = .awaitingFinal
                        handler.responseHead = nil
                        handler.responseBody.clear()
                        handler.challengeHeaders = []
                        handler.recordAuthMethod(fromHeader: response)
                        handler.sendRequest(authHeader: response, context: ctx)
                    }
                } catch {
                    eventLoop.execute {
                        handler.failPromises(error)
                        ctx.close(promise: nil)
                    }
                }
            }

        case .awaitingFinal:
            // Nil on an already-authenticated connection: no handshake of
            // ours sent credentials, so none were rejected.
            authenticator?.credentialsRejected(host: connection.proxy.host)
            failPromises(ConnectionPoolError.authenticationRejected)
            context.close(promise: nil)
        }
    }

    private func beginAuthHandshake(host: String) -> Bool {
        switch authHandshakeLimiter.acquire(source: authSource, limits: authLimitProvider()) {
        case .success(let permit):
            authPermit = permit
            return true
        case .failure(let rejection):
            emitAuthLimitEvent(rejection: rejection, host: host)
            return false
        }
    }

    private func finishAuthHandshake() {
        authPermit?.release()
        authPermit = nil
    }

    private func emitAuthLimitEvent(rejection: AuthHandshakeLimiter.Rejection, host: String) {
        let detail: String
        switch rejection {
        case .totalLimit(let total, let limit):
            detail = "host=\(host) scope=total pending=\(total) limit=\(limit)"
        case .perSourceLimit(let source, let total, let limit):
            detail = "host=\(host) scope=source source=\(source) pending=\(total) limit=\(limit)"
        }
        eventSink?(RuntimeEvent(kind: .auth, event: "auth.handshake_rejected", detail: detail))
    }

    private func sendRequest(authHeader: String?, context: ChannelHandlerContext) {
        guard var head = upstreamHead(for: originalHead) else {
            failPromises(ConnectionPoolError.invalidResponse)
            context.close(promise: nil)
            return
        }
        if let authHeader {
            recordAuthMethod(fromHeader: authHeader)
            head.headers.replaceOrAdd(name: "Proxy-Authorization", value: authHeader)
        }

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        nonisolated(unsafe) let ctx = context
        let endRequest: @Sendable () -> Void = {
            self.resetResponseTimeout(context: ctx)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenFailure { error in
                self.failPromises(error)
                ctx.close(promise: nil)
            }
        }
        guard let body = originalBody else {
            endRequest()
            return
        }
        body.writeClientBody(context: ctx).whenComplete { result in
            switch result {
            case .success:
                endRequest()
            case .failure(let error):
                self.failPromises(error)
                ctx.close(promise: nil)
            }
        }
    }

    private func resolvedAuthMethod() -> String? {
        lastAuthMethod ?? connection.authMethod
    }

    private func recordAuthMethod(fromHeader header: String) {
        if let scheme = Self.authMethod(fromAuthorizationHeader: header) {
            lastAuthMethod = scheme
        }
    }

    private static func authMethod(fromAuthorizationHeader header: String) -> String? {
        header
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }

    private func resetResponseTimeout(context: ChannelHandlerContext) {
        cancelResponseTimeout()
        nonisolated(unsafe) let ctx = context
        responseTimeoutTask = ctx.eventLoop.scheduleTask(in: responseTimeout) { [weak self] in
            guard let self else { return }
            self.eventSink?(ConnectionPool.upstreamResponseTimedOutEvent(
                uri: self.originalHead.uri,
                upstream: self.connection.proxy.endpoint
            ))
            self.failPromises(ConnectionPoolError.upstreamResponseTimedOut)
            ctx.close(promise: nil)
        }
    }

    private func cancelResponseTimeout() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
    }

    private func upstreamHead(for head: HTTPRequestHead) -> HTTPRequestHead? {
        var updated = head
        guard HTTPRequestTarget.isSafeHTTPRequestTarget(updated.uri) else { return nil }

        if !updated.uri.contains("://"), let host = updated.headers.first(name: "Host") {
            guard HTTPRequestTarget.isSafeHTTPHostHeader(host) else { return nil }
            updated.uri = "http://\(host)\(updated.uri)"
        }
        HTTPHopByHopHeaders.sanitizeForwardedRequestHeaders(&updated.headers)
        return updated
    }
}
