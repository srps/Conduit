// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// `pm-sim transparent-direct`. Covers the routing decision the transparent
/// SNI listener makes for an intercepted client, across the five states that
/// matter:
///
/// | # | upstream | cause                        | strict | expected            |
/// |---|----------|------------------------------|--------|---------------------|
/// | A | alive    | `.none`                      | yes    | tunnel via upstream |
/// | B | dead     | `.vpnDisconnected`           | yes    | direct relay        |
/// | C | dead     | `.none`                      | yes    | connection closed   |
/// | D | dead     | `.none`                      | no     | direct relay        |
/// | E | dead     | `.none` → `.vpnDisconnected`  | yes    | direct relay        |
///
/// E is the mid-dial VPN drop: the cause flips *between* the handler's routing
/// read and its fallback read. It fails whenever the fallback decision reuses
/// the pre-dial cause instead of re-reading the current one.
///
/// **B is the regression.** An intercepted client's DNS answer *is* this
/// listener, so when the VPN drops and the corporate upstreams stop resolving,
/// the listener is the only thing standing between the client and the origin.
/// Before the fix it dialed the dead upstream unconditionally and closed the
/// socket on failure — the client saw a TCP close mid-TLS-handshake
/// (`Client network socket disconnected before secure TLS connection was
/// established`) while plain proxy-aware clients on `LocalProxyServer` kept
/// working, because only *they* consulted `DirectModeCause`.
///
/// C is the guardrail on the fix: a strict profile whose upstream is merely
/// *down* must still refuse to bypass corporate proxy policy. D is the
/// non-strict counterpart. Both share `HTTPProxyHandler.directFallbackAllowed`
/// with the HTTP listener so the two paths cannot drift.
///
/// Why the assertions look the way they do: upstream-routed and direct-relayed
/// bytes both land at the same `FakeOrigin`, so an echo alone proves only that
/// *some* path worked. `FakeUpstreamProxy.connectCount` is what distinguishes
/// them.
enum TransparentProxyScenarios {

    private static let interceptedHost = "api2.cursor.sh"

    @MainActor
    static func transparentDirectRouting(verbose: Bool) async throws -> ScenarioResult {
        let name = "transparentDirectRouting"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)

        // Echoes the ClientHello back at us. We never speak real TLS — the
        // listener relays raw bytes, so an echo of the exact ClientHello is a
        // complete proof that the relay reached the origin and is bidirectional.
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start()

        let upstream = FakeUpstreamProxy(
            group: group,
            originHost: "127.0.0.1",
            originPort: origin.port,
            requireAuth: false
        )
        try await upstream.start()
        let upstreamPort = upstream.port

        defer {
            Task { @MainActor in
                await upstream.stop()
                await origin.stop()
            }
        }

        // Stands in for `DoHOriginResolver`. The real one exists precisely so
        // this hostname does NOT resolve through the system resolver (which
        // would hand back the listener's own address); the stub short-circuits
        // to the origin the same way a public A record would.
        let resolver = StubOriginResolver(host: "127.0.0.1", port: origin.port)

        let hello = TLSClientHello.bytes(hostname: interceptedHost)

        // ── Case A: upstream healthy, no direct cause → route via upstream ──
        let caseA = try await probe(
            group: group, logger: logger, resolver: resolver,
            upstreamPort: upstreamPort, causeProvider: { .none }, strictMode: true, hello: hello
        )
        let connectsAfterA = upstream.connectCount
        notes.append("A upstream-alive/.none/strict: echoed=\(caseA.echoedHello) closed=\(caseA.closedWithoutData) upstreamCONNECTs=\(connectsAfterA)")
        let passA = caseA.echoedHello && connectsAfterA == 1

        // Kill the upstream. This is the sim's stand-in for a corporate upstream
        // going NXDOMAIN the moment the VPN's split-DNS resolver file is removed —
        // upstream proxies are typically named inside the corporate zone, which is
        // exactly the zone that stops resolving when the tunnel drops.
        await upstream.stop()
        notes.append("upstream stopped (simulates upstreams unresolvable off-VPN)")

        // ── Case B: the regression. VPN down → relay direct, never touch upstream ──
        let caseB = try await probe(
            group: group, logger: logger, resolver: resolver,
            upstreamPort: upstreamPort, causeProvider: { .vpnDisconnected }, strictMode: true, hello: hello
        )
        let connectsAfterB = upstream.connectCount
        notes.append("B upstream-dead/.vpnDisconnected/strict: echoed=\(caseB.echoedHello) closed=\(caseB.closedWithoutData) upstreamCONNECTs=\(connectsAfterB - connectsAfterA)")
        let passB = caseB.echoedHello && connectsAfterB == connectsAfterA

        // ── Case C: strict profile, upstream merely down → must NOT bypass ──
        let caseC = try await probe(
            group: group, logger: logger, resolver: resolver,
            upstreamPort: upstreamPort, causeProvider: { .none }, strictMode: true, hello: hello
        )
        notes.append("C upstream-dead/.none/strict: echoed=\(caseC.echoedHello) closed=\(caseC.closedWithoutData) events=\(caseC.eventNames)")
        let passC = !caseC.echoedHello && caseC.closedWithoutData
            && caseC.eventNames.contains("transparent_proxy.blocked")

        // ── Case D: same, but strictMode off → direct fallback permitted ──
        let caseD = try await probe(
            group: group, logger: logger, resolver: resolver,
            upstreamPort: upstreamPort, causeProvider: { .none }, strictMode: false, hello: hello
        )
        notes.append("D upstream-dead/.none/non-strict: echoed=\(caseD.echoedHello) closed=\(caseD.closedWithoutData) events=\(caseD.eventNames)")
        let passD = caseD.echoedHello && caseD.eventNames.contains("transparent_proxy.direct_fallback")

        // ── Case E: the VPN drops *while the upstream dial is in flight* ──
        //
        // The handler reads the cause once to choose a route, then again in the
        // failure callback to decide whether falling back to direct is
        // sanctioned. This provider answers `.none` on the first read — so the
        // connection commits to the upstream — and `.vpnDisconnected` on every
        // read after, as if the tunnel dropped mid-dial. A handler that reuses
        // the cause it captured before dialing judges the failure against a
        // state that no longer exists and closes the client under strict mode,
        // reviving the very bug this scenario exists to catch, in a window a
        // fixed-cause test can never enter.
        let reads = NIOLockedValueBox(0)
        let caseE = try await probe(
            group: group, logger: logger, resolver: resolver,
            upstreamPort: upstreamPort,
            causeProvider: {
                let priorReads = reads.withLockedValue { count -> Int in
                    defer { count += 1 }
                    return count
                }
                return priorReads == 0 ? .none : .vpnDisconnected
            },
            strictMode: true, hello: hello
        )
        notes.append("E upstream-dead/.none→.vpnDisconnected mid-dial/strict: echoed=\(caseE.echoedHello) closed=\(caseE.closedWithoutData) causeReads=\(reads.withLockedValue { $0 }) events=\(caseE.eventNames)")
        let passE = caseE.echoedHello && caseE.eventNames.contains("transparent_proxy.direct_fallback")

        let pass = passA && passB && passC && passD && passE
        notes.append("A=\(verdict(passA)) B=\(verdict(passB)) C=\(verdict(passC)) D=\(verdict(passD)) E=\(verdict(passE))")
        notes.append(pass
            ? "PASS — intercepted clients relay direct on VPN-down (including a mid-dial drop), upstream otherwise, and strict mode still blocks bypass"
            : "FAIL — see per-case lines above")

        return ScenarioResult(
            name: name,
            clientCount: 5,
            clientsOpened: 5,
            clientsWithFirstByte: [passA, passB, passC, passD, passE].filter { $0 }.count,
            clientsClosedEarly: [passA, passB, passC, passD, passE].filter { !$0 }.count,
            totalBytes: caseA.bytesRead + caseB.bytesRead + caseC.bytesRead + caseD.bytesRead + caseE.bytesRead,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes
        )
    }

    private static func verdict(_ pass: Bool) -> String { pass ? "pass" : "FAIL" }

    // MARK: - One listener, one client, one ClientHello

    private struct ProbeOutcome {
        let echoedHello: Bool
        let closedWithoutData: Bool
        let bytesRead: Int
        /// `RuntimeEvent.event` names the listener emitted during this probe.
        /// Routing decisions that depart from configured policy are part of the
        /// observability contract, not just the log, so they are asserted here.
        let eventNames: [String]
    }

    /// Stands up a `TransparentTCPProxy` wired to the given routing state,
    /// pushes one ClientHello through it, and reports what came back.
    ///
    /// `causeProvider` is a closure rather than a value so a scenario can change
    /// the answer between the handler's two reads — see case E.
    @MainActor
    private static func probe(
        group: EventLoopGroup,
        logger: any LogSink,
        resolver: any OriginResolving,
        upstreamPort: Int,
        causeProvider: @escaping @Sendable () -> DirectModeCause,
        strictMode: Bool,
        hello: [UInt8]
    ) async throws -> ProbeOutcome {
        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.strictMode = strictMode
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.upstreams = [
            UpstreamProxy(name: "SimUpstream", host: "127.0.0.1", port: upstreamPort, priority: 0)
        ]
        let capturedConfig = config

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { capturedConfig },
            authenticatorProvider: { _ in MockAuthenticator() }
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in MockAuthenticator() },
            logger: logger
        )

        let events = NIOLockedValueBox<[String]>([])
        let proxy = TransparentTCPProxy(
            group: group,
            connectCoordinator: coordinator,
            connectionPool: pool,
            logger: logger,
            originResolver: resolver,
            directModeProvider: causeProvider,
            strictModeProvider: { strictMode },
            eventSink: { event in events.withLockedValue { $0.append(event.event) } }
        )
        try await proxy.start(host: "127.0.0.1", port: 0)
        defer { Task { @MainActor in await proxy.stop() } }

        guard let port = proxy.listeningPort else {
            return ProbeOutcome(echoedHello: false, closedWithoutData: true, bytesRead: 0, eventNames: [])
        }

        let collector = RawByteCollector(expecting: hello.count)
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.tcpNoDelay, value: 1)
            .channelInitializer { channel in channel.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: port)
            .get()

        var buffer = channel.allocator.buffer(capacity: hello.count)
        buffer.writeBytes(hello)
        try await channel.writeAndFlush(buffer).get()

        // Long enough for a loopback round trip through either path, and for a
        // refused upstream connect to surface as a close. Nothing here waits on
        // a real network.
        let echoed = await collector.waitForEcho(hello, timeout: .seconds(3))
        try? await channel.close().get()

        return ProbeOutcome(
            echoedHello: echoed,
            closedWithoutData: collector.sawCloseWithoutData,
            bytesRead: collector.byteCount,
            eventNames: events.withLockedValue { $0 }
        )
    }
}

// MARK: - Stub resolver

/// Resolves every hostname to one fixed address. The production
/// `DoHOriginResolver` reaches a public resolver to avoid the intercept file
/// that maps this hostname back to the listener; in-sim there is no intercept
/// file, so a constant is a faithful stand-in for "a real A record".
private struct StubOriginResolver: OriginResolving {
    let host: String
    let port: Int

    func resolveOrigin(host _: String, port _: Int, on eventLoop: EventLoop) -> EventLoopFuture<SocketAddress> {
        eventLoop.makeCompletedFuture { try SocketAddress(ipAddress: self.host, port: self.port) }
    }
}

// MARK: - Raw byte collector

/// Accumulates inbound bytes and signals once the expected echo has arrived (or
/// the peer closed first). Backed by a lock because the event loop writes and
/// the scenario's `await` reads.
private final class RawByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private struct State {
        var bytes: [UInt8] = []
        var closed = false
    }

    private let expecting: Int
    private let state = NIOLockedValueBox(State())

    init(expecting: Int) {
        self.expecting = expecting
    }

    var byteCount: Int { state.withLockedValue { $0.bytes.count } }

    /// True when the peer hung up before sending anything — the exact shape of
    /// the bug this scenario guards, as seen from the client.
    var sawCloseWithoutData: Bool {
        state.withLockedValue { $0.closed && $0.bytes.isEmpty }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let incoming = buffer.readBytes(length: buffer.readableBytes) ?? []
        state.withLockedValue { $0.bytes += incoming }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLockedValue { $0.closed = true }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.withLockedValue { $0.closed = true }
        context.close(promise: nil)
    }

    func waitForEcho(_ expected: [UInt8], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (bytes, closed) = state.withLockedValue { ($0.bytes, $0.closed) }
            if bytes.count >= expecting { return bytes == expected }
            if closed { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

// MARK: - Minimal TLS ClientHello

/// Just enough of a ClientHello for `SNIParser` to find the SNI. Mirrors the
/// builder in `SNIParserTests`; kept separate because pm-sim does not link the
/// test target.
private enum TLSClientHello {
    static func bytes(hostname: String) -> [UInt8] {
        let hostnameBytes = Array(hostname.utf8)

        var sniPayload = [UInt8]()
        let nameLength = UInt16(hostnameBytes.count)
        sniPayload += beBytes(nameLength + 3)
        sniPayload += [0x00] // name_type: host_name
        sniPayload += beBytes(nameLength)
        sniPayload += hostnameBytes

        var ext = [UInt8]()
        ext += [0x00, 0x00] // extension type: server_name
        ext += beBytes(UInt16(sniPayload.count))
        ext += sniPayload

        return wrap(extensions: ext)
    }

    private static func wrap(extensions: [UInt8]) -> [UInt8] {
        let sessionID: [UInt8] = [0x00]
        let cipherSuites: [UInt8] = [0x00, 0x02, 0x00, 0x2F]
        let compression: [UInt8] = [0x01, 0x00]

        var body = [UInt8]()
        body += [0x03, 0x03]                          // client_version TLS 1.2
        body += [UInt8](repeating: 0x41, count: 32)   // random
        body += sessionID
        body += cipherSuites
        body += compression
        body += beBytes(UInt16(extensions.count))
        body += extensions

        var handshake = [UInt8]()
        handshake += [0x01]                            // ClientHello
        handshake += be24(UInt32(body.count))
        handshake += body

        var record = [UInt8]()
        record += [0x16, 0x03, 0x01]                   // handshake, TLS 1.0 record
        record += beBytes(UInt16(handshake.count))
        record += handshake
        return record
    }

    private static func beBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func be24(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
