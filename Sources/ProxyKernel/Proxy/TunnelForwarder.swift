// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

package enum TunnelDNSOverrideStatus: Sendable, Equatable, Codable {
    case active(hostnames: [String])
    case partial(succeeded: [String], failed: [String])
    case unavailable(reason: String)
    case notNeeded

    private enum CodingKeys: String, CodingKey {
        case kind
        case hostnames
        case succeeded
        case failed
        case reason
    }

    private enum Kind: String, Codable {
        case active
        case partial
        case unavailable
        case notNeeded
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .active:
            self = .active(hostnames: try container.decode([String].self, forKey: .hostnames))
        case .partial:
            self = .partial(
                succeeded: try container.decode([String].self, forKey: .succeeded),
                failed: try container.decode([String].self, forKey: .failed)
            )
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        case .notNeeded:
            self = .notNeeded
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active(let hostnames):
            try container.encode(Kind.active, forKey: .kind)
            try container.encode(hostnames, forKey: .hostnames)
        case .partial(let succeeded, let failed):
            try container.encode(Kind.partial, forKey: .kind)
            try container.encode(succeeded, forKey: .succeeded)
            try container.encode(failed, forKey: .failed)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .notNeeded:
            try container.encode(Kind.notNeeded, forKey: .kind)
        }
    }
}

package struct TunnelStartResult: Sendable {
    package var started: Int
    package var failed: Int
    package var boundPorts: [Int]
    package var bindings: [TunnelBindingInfo] = []
    package var dnsOverrideStatus: TunnelDNSOverrideStatus = .notNeeded
}

package struct TunnelBindingInfo: Sendable, Codable, Equatable {
    /// Stable identifier sourced from the originating `TunnelDefinition.id`. Used to correlate
    /// health-probe results back to bindings without relying on `label`, which can collide when
    /// two tunnels share an auto-generated or user-defined label. Decoded with a fallback so
    /// legacy status payloads (pre-id) still parse.
    package var id: UUID = UUID()
    package var label: String
    package var localHost: String
    package var localPort: Int
    package var remoteHost: String
    package var remotePort: Int
    package var proxied: Bool
    package var healthy: Bool = true

    package init(
        id: UUID = UUID(),
        label: String,
        localHost: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        proxied: Bool,
        healthy: Bool = true
    ) {
        self.id = id
        self.label = label
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.proxied = proxied
        self.healthy = healthy
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try container.decode(String.self, forKey: .label)
        self.localHost = try container.decode(String.self, forKey: .localHost)
        self.localPort = try container.decode(Int.self, forKey: .localPort)
        self.remoteHost = try container.decode(String.self, forKey: .remoteHost)
        self.remotePort = try container.decode(Int.self, forKey: .remotePort)
        self.proxied = try container.decode(Bool.self, forKey: .proxied)
        self.healthy = try container.decodeIfPresent(Bool.self, forKey: .healthy) ?? true
    }
}

/// Periodically probes tunnel listeners with a TCP connect to verify they're accepting connections.
package final class TunnelHealthProber: @unchecked Sendable {
    private struct State {
        var timer: DispatchSourceTimer?
        var onResult: (@Sendable ([UUID: Bool]) -> Void)?
    }

    private let queue = DispatchQueue(label: "tunnel-health-prober")
    // `timer` and `onResult` are read on `queue` by the event handler and
    // written on the caller's thread by `start()` / `stop()`. Keep them behind
    // a single lock so the handler never races with teardown — `timer.cancel()`
    // only prevents *future* firings, so an in-flight handler could otherwise
    // read `onResult` concurrently with `stop()` clearing it.
    private let state = NIOLockedValueBox(State())

    package init() {}

    package func start(
        interval: TimeInterval,
        tunnels: @escaping @Sendable () -> [(id: UUID, host: String, port: Int)],
        onResult: @escaping @Sendable ([UUID: Bool]) -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let targets = tunnels()
            guard !targets.isEmpty else { return }
            var results: [UUID: Bool] = [:]
            for target in targets {
                results[target.id] = Self.probeTCPConnect(host: target.host, port: target.port)
            }
            let callback = self.state.withLockedValue { $0.onResult }
            callback?(results)
        }
        let previousTimer: DispatchSourceTimer? = state.withLockedValue { state in
            let previous = state.timer
            state.timer = timer
            state.onResult = onResult
            return previous
        }
        previousTimer?.cancel()
        timer.resume()
    }

    package func stop() {
        let timer: DispatchSourceTimer? = state.withLockedValue { state in
            let previous = state.timer
            state.timer = nil
            state.onResult = nil
            return previous
        }
        timer?.cancel()
    }

    private static func probeTCPConnect(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Thread-safe session counter shared between the forwarder and its child handlers.
package final class TunnelSessionTracker: @unchecked Sendable {
    private let globalCount = NIOLockedValueBox(0)
    private let perTunnelCounts = NIOLockedValueBox<[Int: Int]>([:])
    private let limitsBox: NIOLockedValueBox<Limits>
    package var onChange: (@Sendable (Int) -> Void)?

    package struct Limits: Sendable {
        package var maxGlobal: Int
        package var maxPerTunnel: Int
    }

    package var limits: Limits {
        get { limitsBox.withLockedValue { $0 } }
        set { limitsBox.withLockedValue { $0 = newValue } }
    }

    package init(limits: Limits) { self.limitsBox = NIOLockedValueBox(limits) }

    package func tryAcquire(tunnelPort: Int) -> Bool {
        let currentLimits = limitsBox.withLockedValue { $0 }
        let acquired = globalCount.withLockedValue { global in
            perTunnelCounts.withLockedValue { perTunnel in
                let current = perTunnel[tunnelPort, default: 0]
                guard global < currentLimits.maxGlobal, current < currentLimits.maxPerTunnel else { return false }
                global += 1
                perTunnel[tunnelPort] = current + 1
                return true
            }
        }
        if acquired {
            onChange?(totalActiveSessions)
        }
        return acquired
    }

    package func release(tunnelPort: Int) {
        globalCount.withLockedValue { global in
            perTunnelCounts.withLockedValue { perTunnel in
                global = max(0, global - 1)
                let current = perTunnel[tunnelPort, default: 0]
                perTunnel[tunnelPort] = max(0, current - 1)
            }
        }
        onChange?(totalActiveSessions)
    }

    package func reset() {
        globalCount.withLockedValue { $0 = 0 }
        perTunnelCounts.withLockedValue { $0.removeAll() }
        onChange?(0)
    }

    package var totalActiveSessions: Int {
        globalCount.withLockedValue { $0 }
    }
}

package final class TunnelForwarder: @unchecked Sendable {
    private let group: EventLoopGroup
    private let connectCoordinator: CONNECTCoordinator
    private let connectionPool: ConnectionPool
    private let logger: any LogSink
    private var listeners: [Channel] = []
    package private(set) var listenersByID: [UUID: Channel] = [:]
    package private(set) var activeDefinitions: [UUID: TunnelDefinition] = [:]
    package let sessionTracker: TunnelSessionTracker
    private let dnsResponder: TunnelDNSResponder
    private let resolverManager: (any TunnelResolverApplying)?
    private var managedHostnames: [String] = []
    /// Last computed DNS override status. Cached so reconcile() can return an accurate value when
    /// the active proxied hostname set hasn't changed (and we skipped the DNS refresh) — without
    /// this, the early-return path would report `.notNeeded` even with live overrides in place.
    private var dnsOverrideStatus: TunnelDNSOverrideStatus = .notNeeded

    private struct BindingBatch {
        var started: Int = 0
        var failed: Int = 0
        var bindings: [TunnelBindingInfo] = []
    }

    package init(
        group: EventLoopGroup,
        connectCoordinator: CONNECTCoordinator,
        connectionPool: ConnectionPool,
        logger: any LogSink,
        resolverManager: (any TunnelResolverApplying)? = nil
    ) {
        self.group = group
        self.connectCoordinator = connectCoordinator
        self.connectionPool = connectionPool
        self.logger = logger
        self.resolverManager = resolverManager
        self.dnsResponder = TunnelDNSResponder(group: group, logger: logger)
        self.sessionTracker = TunnelSessionTracker(
            limits: .init(maxGlobal: 128, maxPerTunnel: 32)
        )
    }

    package func updateLimits(maxGlobal: Int, maxPerTunnel: Int) {
        sessionTracker.limits = .init(maxGlobal: maxGlobal, maxPerTunnel: maxPerTunnel)
    }

    @discardableResult
    package func start(tunnels: [TunnelDefinition], listenHost: String) async -> TunnelStartResult {
        let batch = await bindTunnels(tunnels, listenHost: listenHost)
        var result = TunnelStartResult(
            started: batch.started,
            failed: batch.failed,
            boundPorts: batch.bindings.map(\.localPort),
            bindings: batch.bindings
        )
        await reconcileDNSOverride()
        result.dnsOverrideStatus = dnsOverrideStatus
        return result
    }

    /// Bind tunnel listeners without touching DNS override state. DNS is reconciled separately via
    /// `reconcileDNSOverride()` so both `start()` and `reconcile()` can apply the override against
    /// the full set of currently-active proxied tunnels rather than just the delta being bound.
    private func bindTunnels(_ tunnels: [TunnelDefinition], listenHost: String) async -> BindingBatch {
        var batch = BindingBatch()
        for tunnel in tunnels where tunnel.enabled {
            do {
                let def = tunnel
                let tracker = self.sessionTracker
                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.tcpNoDelay, value: 1)
                    .childChannelInitializer { channel in
                        guard tracker.tryAcquire(tunnelPort: def.localPort) else {
                            self.logger.log(.warning, "Tunnel \(def.effectiveLabel): session limit reached, rejecting connection.", category: .tunnel)
                            return channel.close().flatMap { channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                        }
                        channel.closeFuture.whenComplete { _ in
                            tracker.release(tunnelPort: def.localPort)
                        }
                        if def.proxied {
                            return channel.pipeline.addHandler(
                                ProxiedTunnelClientHandler(
                                    remoteHost: def.remoteHost,
                                    remotePort: def.remotePort,
                                    label: def.effectiveLabel,
                                    connectCoordinator: self.connectCoordinator,
                                    logger: self.logger,
                                    onTunnelClosed: { [weak self] upstreamChannel in
                                        self?.connectionPool.removeDedicatedTunnelByChannel(upstreamChannel)
                                    }
                                )
                            )
                        } else {
                            return channel.pipeline.addHandler(
                                DirectTunnelClientHandler(
                                    remoteHost: def.remoteHost,
                                    remotePort: def.remotePort,
                                    group: self.group,
                                    logger: self.logger
                                )
                            )
                        }
                    }
                let ch = try await bootstrap.bind(host: listenHost, port: tunnel.localPort).get()
                listeners.append(ch)
                listenersByID[tunnel.id] = ch
                activeDefinitions[tunnel.id] = tunnel
                batch.started += 1
                let actualHost = ch.localAddress?.ipAddress ?? listenHost
                let actualPort = ch.localAddress?.port ?? tunnel.localPort
                batch.bindings.append(
                    TunnelBindingInfo(
                        id: tunnel.id,
                        label: tunnel.effectiveLabel,
                        localHost: actualHost,
                        localPort: actualPort,
                        remoteHost: tunnel.remoteHost,
                        remotePort: tunnel.remotePort,
                        proxied: tunnel.proxied
                    )
                )
                let mode = tunnel.proxied ? "proxied" : "direct"
                logger.log(
                    .notice,
                    "Tunnel \(tunnel.effectiveLabel) (\(mode)) listening on \(listenHost):\(actualPort) → \(tunnel.remoteHost):\(tunnel.remotePort).",
                    category: .tunnel
                )
            } catch {
                batch.failed += 1
                logger.log(.error, "Tunnel \(tunnel.effectiveLabel) failed to start: \(error.localizedDescription)", category: .tunnel)
            }
        }
        return batch
    }

    /// The set of hostnames that should currently have DNS overrides, derived from the proxied
    /// tunnels that are actually bound (i.e., present in `activeDefinitions`). Lower-cased and
    /// deduplicated to match the DNS responder's lookup contract.
    private func desiredProxiedHostnames() -> Set<String> {
        Set(activeDefinitions.values.filter(\.proxied).map { $0.remoteHost.lowercased() })
    }

    /// Bring the DNS responder and `/etc/resolver/*` files in line with `desiredProxiedHostnames()`.
    /// Idempotent: if the set of hostnames we've *successfully* written resolver files for already
    /// matches the desired set, this is a no-op so frequent reconciles don't thrash the UDP
    /// listener or re-poke the privileged helper.
    ///
    /// The comparison intentionally uses `managedHostnames` (only populated after successful
    /// resolver writes) rather than `dnsResponder.activeOverrides` (populated *before* writes are
    /// attempted). Otherwise a prior partial failure would never be retried, because the in-memory
    /// override map would falsely report the full desired set as already "current."
    /// Updates `dnsOverrideStatus` as a side effect.
    private func reconcileDNSOverride() async {
        let desired = desiredProxiedHostnames()
        let current = Set(managedHostnames)
        guard desired != current else { return }

        if desired.isEmpty {
            await teardownDNSOverride()
        } else {
            dnsOverrideStatus = await setupDNSOverride(hostnames: Array(desired).sorted())
        }
    }

    private func setupDNSOverride(hostnames: [String]) async -> TunnelDNSOverrideStatus {
        do {
            try await dnsResponder.start(host: "127.0.0.1", port: TunnelResolverPort.port)
        } catch {
            logger.log(.warning, "Tunnel DNS responder failed to start: \(error.localizedDescription)", category: .tunnel)
            return .unavailable(reason: "DNS responder bind failed: \(error.localizedDescription)")
        }

        let loopback = "127.0.0.1"
        let mapping = Dictionary(uniqueKeysWithValues: hostnames.map { ($0, loopback) })
        dnsResponder.updateHostnames(mapping)

        guard let resolver = resolverManager else {
            logger.log(.info, "Tunnel DNS: no resolver manager available, DNS override requires manual setup.", category: .tunnel)
            return .unavailable(reason: "Privileged helper not available")
        }

        resolver.cleanupStale(activeHostnames: Set(hostnames))
        let (succeeded, failed) = resolver.applyAll(hostnames: hostnames, listenIP: loopback)
        managedHostnames = succeeded

        if failed.isEmpty {
            return .active(hostnames: succeeded)
        } else if !succeeded.isEmpty {
            return .partial(succeeded: succeeded, failed: failed)
        } else {
            return .unavailable(reason: "All resolver file writes failed")
        }
    }

    private func teardownDNSOverride() async {
        if let resolver = resolverManager, !managedHostnames.isEmpty {
            resolver.removeAll(hostnames: managedHostnames)
        }
        managedHostnames.removeAll()
        await dnsResponder.stop()
        dnsOverrideStatus = .notNeeded
    }

    /// Reconcile running tunnels with a new set of definitions.
    /// Stops removed/changed tunnels, starts new/changed tunnels, leaves unchanged tunnels running.
    /// DNS overrides are then reconciled against the full active proxied set — this is what stops
    /// a removal-only reconcile from leaving stale responder mappings or `/etc/resolver/` files
    /// behind, and also stops a partial add from clobbering unchanged proxied tunnels' overrides.
    package func reconcile(newDefinitions: [TunnelDefinition], listenHost: String) async -> TunnelStartResult {
        let newEnabled = newDefinitions.filter(\.enabled)
        let newIDs = Set(newEnabled.map(\.id))
        let oldIDs = Set(activeDefinitions.keys)

        let toRemove = oldIDs.subtracting(newIDs)
        var toAdd: [TunnelDefinition] = []
        for def in newEnabled {
            if let existing = activeDefinitions[def.id] {
                // Only listener-relevant fields force a rebind. `label` is metadata and can be
                // propagated in place (see below) without tearing down the socket.
                let rebindNeeded = existing.localPort != def.localPort
                    || existing.remoteHost != def.remoteHost
                    || existing.remotePort != def.remotePort
                    || existing.proxied != def.proxied
                    || existing.enabled != def.enabled
                if rebindNeeded {
                    toAdd.append(def)
                    if let ch = listenersByID[def.id] {
                        _ = try? await ch.close().get()
                        listeners.removeAll { $0 === ch }
                        listenersByID.removeValue(forKey: def.id)
                        activeDefinitions.removeValue(forKey: def.id)
                        logger.log(.notice, "Tunnel \(existing.effectiveLabel) stopped for reconfiguration.", category: .tunnel)
                    }
                } else if existing != def {
                    // Non-rebind fields changed (label, preset). Update the stored definition so
                    // the binding rebuilt below carries the new metadata; without this a label-
                    // only rename would never propagate to `TunnelBindingInfo.label`.
                    activeDefinitions[def.id] = def
                    if existing.effectiveLabel != def.effectiveLabel {
                        logger.log(
                            .notice,
                            "Tunnel \(existing.effectiveLabel) relabeled to \(def.effectiveLabel).",
                            category: .tunnel
                        )
                    }
                }
            } else {
                toAdd.append(def)
            }
        }

        for id in toRemove {
            if let ch = listenersByID[id] {
                let label = activeDefinitions[id]?.effectiveLabel ?? id.uuidString
                _ = try? await ch.close().get()
                listeners.removeAll { $0 === ch }
                listenersByID.removeValue(forKey: id)
                activeDefinitions.removeValue(forKey: id)
                logger.log(.notice, "Tunnel \(label) removed.", category: .tunnel)
            }
        }

        var addFailed = 0
        if !toAdd.isEmpty {
            let batch = await bindTunnels(toAdd, listenHost: listenHost)
            addFailed = batch.failed
        }

        await reconcileDNSOverride()

        // Build bindings in `newEnabled` (definition-list) order. Iterating
        // `activeDefinitions.values` directly produces non-deterministic ordering across
        // reconciles, which shuffled snapshot diffs and flapped observers on every reload.
        let orderedBindings: [TunnelBindingInfo] = newEnabled.compactMap { def in
            guard let activeDef = activeDefinitions[def.id],
                  let ch = listenersByID[def.id] else { return nil }
            return TunnelBindingInfo(
                id: activeDef.id,
                label: activeDef.effectiveLabel,
                localHost: ch.localAddress?.ipAddress ?? listenHost,
                localPort: ch.localAddress?.port ?? activeDef.localPort,
                remoteHost: activeDef.remoteHost,
                remotePort: activeDef.remotePort,
                proxied: activeDef.proxied
            )
        }

        return TunnelStartResult(
            started: activeDefinitions.count,
            failed: addFailed,
            boundPorts: orderedBindings.map(\.localPort),
            bindings: orderedBindings,
            dnsOverrideStatus: dnsOverrideStatus
        )
    }

    package func stop() async {
        await teardownDNSOverride()

        for ch in listeners {
            _ = try? await ch.close().get()
        }
        listeners.removeAll()
        listenersByID.removeAll()
        activeDefinitions.removeAll()
        sessionTracker.reset()
    }
}

// MARK: - Proxied tunnel: routes through corporate proxy via HTTP CONNECT

private final class ProxiedTunnelClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private static let maxPendingBufferBytes = 65_536

    private let remoteHost: String
    private let remotePort: Int
    private let label: String
    private let connectCoordinator: CONNECTCoordinator
    private let logger: any LogSink
    private let onTunnelClosed: @Sendable (Channel) -> Void

    private var upstream: Channel?
    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    private var tunnelReady = false
    private var protocolDetected = false
    private var clientGone = false

    init(
        remoteHost: String,
        remotePort: Int,
        label: String,
        connectCoordinator: CONNECTCoordinator,
        logger: any LogSink,
        onTunnelClosed: @Sendable @escaping (Channel) -> Void
    ) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label
        self.connectCoordinator = connectCoordinator
        self.logger = logger
        self.onTunnelClosed = onTunnelClosed
    }

    func channelActive(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        let target = remoteHost.contains(":") ? "[\(remoteHost)]:\(remotePort)" : "\(remoteHost):\(remotePort)"

        logger.log(.info, "Proxied tunnel \(label): establishing CONNECT to \(target).", category: .tunnel)

        // Hop the CONNECT result to the client channel's event loop — every
        // piece of handler state is owned by it. Same shape as
        // DirectTunnelClientHandler so the two flows read identically.
        connectCoordinator.connectUpstreamTunnel(target: target)
            .hop(to: context.eventLoop)
            .whenComplete { [self] result in
                handleConnectResult(result, clientChannel: clientChannel)
            }
    }

    /// Runs on the client event loop (the caller hops the future there).
    private func handleConnectResult(
        _ result: Result<(channel: Channel, endpoint: String, authMethod: String?), Error>,
        clientChannel: Channel
    ) {
        switch result {
        case .success(let (upstreamChannel, endpoint, _)):
            if clientGone {
                // Client dropped while CONNECT was in flight. `upstream` was
                // never assigned, so channelInactive could not close it —
                // do both halves of the upstream teardown here.
                onTunnelClosed(upstreamChannel)
                upstreamChannel.close(mode: .all, promise: nil)
                return
            }
            upstream = upstreamChannel
            logger.log(.notice, "Proxied tunnel \(label): established via \(endpoint).", category: .tunnel)

            let relay = TunnelPeerRelay(peer: clientChannel)
            // The addHandler future completes on the UPSTREAM channel's
            // event loop; hop back before touching handler state (the same
            // race the TSan soak flagged on the direct path).
            upstreamChannel.pipeline.addHandler(relay)
                .hop(to: clientChannel.eventLoop)
                .whenComplete { [self] relayResult in
                    finishTunnelSetup(relayResult, upstreamChannel: upstreamChannel, clientChannel: clientChannel)
                }

        case .failure(let error):
            logger.log(
                .error,
                "Proxied tunnel \(label): CONNECT failed — \(error.localizedDescription)",
                category: .tunnel
            )
            // channelInactive clears the backlog when this close lands.
            clientChannel.close(promise: nil)
        }
    }

    /// Runs on the client event loop (the caller hops the future there).
    private func finishTunnelSetup(_ relayResult: Result<Void, Error>, upstreamChannel: Channel, clientChannel: Channel) {
        if clientGone {
            // Client dropped between CONNECT and relay setup; channelInactive
            // already closed the upstream and cleared the backlog.
            return
        }
        guard case .success = relayResult else {
            // Without the relay, upstream-to-client data can never flow —
            // close the client and let channelInactive run the one canonical
            // teardown (upstream close + onTunnelClosed + backlog clear).
            clientChannel.close(promise: nil)
            return
        }
        // Drain the pre-CONNECT backlog BEFORE flipping tunnelReady:
        // channelRead writes directly to the upstream once the flag is set,
        // so setting it first lets fresh reads overtake the buffered bytes
        // and corrupt the stream.
        for buf in buffered {
            upstreamChannel.write(buf, promise: nil)
        }
        if !buffered.isEmpty {
            upstreamChannel.flush()
        }
        buffered.removeAll()
        bufferedBytes = 0
        tunnelReady = true
        // channelRead pauses reads when the backlog cap is hit; this is the
        // only place that can resume them.
        clientChannel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)

        if !protocolDetected {
            protocolDetected = true
            let detected = ProtocolDetector.detect(buf)
            if detected != .unknown {
                logger.log(.info, "Proxied tunnel \(label): detected \(detected.displayName) wire protocol.", category: .tunnel)
            }
        }

        if tunnelReady, let upstream {
            upstream.writeAndFlush(buf, promise: nil)
            if !upstream.isWritable {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
        } else {
            bufferedBytes += buf.readableBytes
            buffered.append(buf)
            if bufferedBytes >= Self.maxPendingBufferBytes {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Only manage upstream reads once the relay is installed: `upstream`
        // is assigned before the relay (so channelInactive can close it if
        // the client drops mid-setup), and the relay is the only thing that
        // pauses upstream reads — resuming them earlier would enable reads
        // into a pipeline with no handler to forward the data.
        if context.channel.isWritable, tunnelReady, let upstream {
            upstream.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        clientGone = true
        if let upstream {
            onTunnelClosed(upstream)
            upstream.close(mode: .all, promise: nil)
        }
        buffered.removeAll()
        bufferedBytes = 0
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(.warning, "Proxied tunnel \(label) error: \(error.localizedDescription)", category: .tunnel)
        clientGone = true
        if let upstream {
            onTunnelClosed(upstream)
            upstream.close(mode: .all, promise: nil)
        }
        buffered.removeAll()
        bufferedBytes = 0
        context.close(promise: nil)
    }
}

// MARK: - Direct tunnel: plain TCP forwarding (unchanged behavior)

private final class DirectTunnelClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private static let maxPendingBufferBytes = 65_536

    private let remoteHost: String
    private let remotePort: Int
    private let group: EventLoopGroup
    private let logger: any LogSink
    private var upstream: Channel?
    private var buffered: [ByteBuffer] = []
    private var bufferedBytes = 0
    private var connectComplete = false
    private var clientGone = false

    init(remoteHost: String, remotePort: Int, group: EventLoopGroup, logger: any LogSink) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.group = group
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        // The connect future completes on the UPSTREAM channel's event loop;
        // all handler state is owned by the client channel's loop, so hop the
        // future there — the TSan soak flagged clientGone/upstream/buffered
        // accesses in this callback racing channelRead/channelInactive.
        ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.tcpNoDelay, value: 1)
            .connect(host: remoteHost, port: remotePort)
            .hop(to: context.eventLoop)
            .whenComplete { [self] result in
                handleConnectResult(result, clientChannel: clientChannel)
            }
    }

    /// Runs on the client event loop (the caller hops the future there).
    private func handleConnectResult(_ result: Result<Channel, Error>, clientChannel: Channel) {
        switch result {
        case .success(let ch):
            if clientGone {
                // Client dropped while the connect was in flight. `upstream`
                // was never assigned, so channelInactive could not close it.
                ch.close(mode: .all, promise: nil)
                return
            }
            upstream = ch
            let relay = TunnelPeerRelay(peer: clientChannel)
            // The addHandler future completes on the UPSTREAM channel's
            // event loop; hop back before touching handler state.
            ch.pipeline.addHandler(relay)
                .hop(to: clientChannel.eventLoop)
                .whenComplete { [self] relayResult in
                    finishTunnelSetup(relayResult, upstreamChannel: ch, clientChannel: clientChannel)
                }
        case .failure(let error):
            logger.log(.error, "Tunnel to \(remoteHost):\(remotePort) failed: \(error.localizedDescription)", category: .tunnel)
            clientChannel.close(promise: nil)
        }
    }

    /// Runs on the client event loop (the caller hops the future there).
    private func finishTunnelSetup(_ relayResult: Result<Void, Error>, upstreamChannel: Channel, clientChannel: Channel) {
        if clientGone {
            // Client dropped between connect and relay setup; channelInactive
            // already closed the upstream and cleared the backlog.
            return
        }
        guard case .success = relayResult else {
            // Without the relay, upstream-to-client data can never flow —
            // close the client and let channelInactive run the one canonical
            // teardown (upstream close + backlog clear).
            clientChannel.close(promise: nil)
            return
        }
        // Drain the pre-connect backlog BEFORE flipping connectComplete:
        // channelRead writes directly to the upstream once the flag is set,
        // so setting it first (as the old code did) let fresh reads overtake
        // the buffered bytes and corrupt the stream.
        for buf in buffered {
            upstreamChannel.write(buf, promise: nil)
        }
        if !buffered.isEmpty {
            upstreamChannel.flush()
        }
        buffered.removeAll()
        bufferedBytes = 0
        connectComplete = true
        // channelRead pauses reads when the backlog cap is hit; this is the
        // only place that can resume them.
        clientChannel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if connectComplete, let upstream {
            upstream.writeAndFlush(buf, promise: nil)
            if !upstream.isWritable {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
        } else {
            bufferedBytes += buf.readableBytes
            buffered.append(buf)
            if bufferedBytes >= Self.maxPendingBufferBytes {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Only manage upstream reads once the relay is installed — see the
        // twin comment in `ProxiedTunnelClientHandler`.
        if context.channel.isWritable, connectComplete, let upstream {
            upstream.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        clientGone = true
        upstream?.close(mode: .all, promise: nil)
        buffered.removeAll()
        bufferedBytes = 0
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        clientGone = true
        upstream?.close(mode: .all, promise: nil)
        buffered.removeAll()
        bufferedBytes = 0
        context.close(promise: nil)
    }
}

// MARK: - Shared bidirectional relay

private final class TunnelPeerRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            peer.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Drain peer's outbound queue before closing. `close(mode: .all)` fails all
        // buffered writes, which truncates streamed responses when this side FINs
        // while the peer still has queued bytes under backpressure — same class of
        // bug fixed in `TunnelRelayHandler` / `DirectTunnelRelay`.
        gracefulClosePeer()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        gracefulClosePeer()
        context.close(promise: nil)
    }

    private func gracefulClosePeer() {
        let peer = self.peer
        guard peer.isActive else {
            peer.close(mode: .all, promise: nil)
            return
        }
        // Write 0 bytes then flush; the future fires when all previously-queued writes
        // have been dispatched to the kernel send buffer. Then close cleanly.
        peer.writeAndFlush(NIOAny(peer.allocator.buffer(capacity: 0))).whenComplete { _ in
            peer.close(mode: .all, promise: nil)
        }
    }
}
