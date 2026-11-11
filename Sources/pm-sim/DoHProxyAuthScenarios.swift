// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// `pm-sim dns-doh-upstream-407` (decision 0045). The only enabled upstream
/// answers 407 to everything, as a corporate proxy does before Conduit has a
/// Kerberos service ticket. On 0.6.2, DoH sent lookups straight at it, and
/// macOS answered its challenge with a credential dialog. The DoH provider is
/// a TEST-NET address, so only a proxy can answer for it.
///
/// | # | condition                                          | expected                                                  |
/// |---|----------------------------------------------------|-----------------------------------------------------------|
/// | A | a public name, provider over HTTP                  | answered, through the listener                            |
/// | B | the upstream                                       | sees no request at all                                    |
/// | C | the listener                                       | saw the lookup                                            |
/// | D | the listener now answers 407; HTTPS provider       | `auth.proxy_challenge_refused client=doh` for the listener |
/// | E | every request either fake saw                      | carries no `Proxy-Authorization`                          |
enum DoHProxyAuthScenarios {
    private static let providerHost = "192.0.2.10"
    private static let publicIP = "198.51.100.30"

    @RuntimeActor
    static func upstreamChallengeNeverReached(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsDoHUpstream407"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let upstream = ScriptedHTTPProxy(group: group, mode: .challenge)
        ScenarioCleanup.register { await upstream.stop() }
        try await upstream.start()
        let listener = ScriptedHTTPProxy(group: group, mode: .answer(ip: publicIP))
        ScenarioCleanup.register { await listener.stop() }
        try await listener.start()
        notes.append("upstream 127.0.0.1:\(upstream.port) answers 407; listener stand-in 127.0.0.1:\(listener.port)")

        let providers = NIOLockedValueBox(["http://\(providerHost)/dns-query"])
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        config.localHost = "127.0.0.1"
        config.localPort = listener.port
        config.dnsEntries = []
        let base = config
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let listenerPort = listener.port
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger,
            configProvider: {
                var current = base
                current.dohProviders = providers.withLockedValue { $0 }
                return current
            },
            preferProxyPathForDoH: { true },
            localProxyPort: { listenerPort },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = forwarder.listeningPort ?? 0

        let first = DNSWireFormat.buildQuery(domain: "first-lookup.example", txID: 0x4070, qtype: 1)
        let answer = try await DNSProbe.overUDP(query: first, port: port, timeout: 12)
        let answeredIP = answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }
        notes.append("A answer=\(answeredIP ?? "none") listenerRequests=\(listener.requests(naming: "first-lookup")) upstreamRequests=\(upstream.requestCount)")
        let passA = answeredIP == publicIP
        let passC = listener.requests(naming: "first-lookup") > 0

        listener.mode = .challenge
        providers.withLockedValue { $0 = ["https://\(providerHost)/dns-query"] }
        let second = DNSWireFormat.buildQuery(domain: "second-lookup.example", txID: 0x4071, qtype: 1)
        _ = try await DNSProbe.overUDP(query: second, port: port, timeout: 12)
        let refusals = events.withLockedValue { $0 }.filter { $0.event == "auth.proxy_challenge_refused" }
        notes.append("D refusals=\(refusals.map { $0.detail ?? "" })")
        let passD = refusals.count == 1
            && (refusals.first?.detail ?? "").hasPrefix("client=doh proxy=127.0.0.1:\(listener.port) ")

        let passB = upstream.requestCount == 0
        notes.append("B upstreamRequests=\(upstream.requestCount)")
        let credentialed = (upstream.heads() + listener.heads()).filter { $0.lowercased().contains("proxy-authorization") }
        notes.append("E credentialedRequests=\(credentialed.count) listenerRequests=\(listener.requestCount)")
        let passE = credentialed.isEmpty

        let checks = [passA, passB, passC, passD, passE]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — DoH never reaches the upstream, and a proxy challenge is refused, never handed to macOS"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: 2,
            clientsOpened: 2,
            clientsWithFirstByte: passA ? 1 : 0,
            clientsClosedEarly: passA ? 1 : 2,
            totalBytes: answer?.count ?? 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a public name is answered through the listener", passA),
                .init("no DoH request reaches the upstream directly", passB),
                .init("the listener carries the lookup", passC),
                .init("a proxy challenge is refused with auth.proxy_challenge_refused", passD),
                .init("no request carries Proxy-Authorization", passE),
            ],
            notes: notes
        )
    }
}

/// A loopback HTTP proxy stand-in. `.answer` replies to every request with one
/// `application/dns-json` A record, as Conduit's listener does once it has
/// reached a provider. `.challenge` replies 407 with Negotiate, NTLM and Basic,
/// as a corporate upstream does. Keeps each request's first read.
final class ScriptedHTTPProxy: @unchecked Sendable {
    enum Mode: Sendable {
        case answer(ip: String)
        case challenge
    }

    private let group: EventLoopGroup
    private let modeBox: NIOLockedValueBox<Mode>
    private let headsBox = NIOLockedValueBox<[String]>([])
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    var mode: Mode {
        get { modeBox.withLockedValue { $0 } }
        set { modeBox.withLockedValue { $0 = newValue } }
    }

    var requestCount: Int { headsBox.withLockedValue { $0.count } }
    func heads() -> [String] { headsBox.withLockedValue { $0 } }
    func requests(naming label: String) -> Int { heads().filter { $0.contains(label) }.count }

    init(group: EventLoopGroup, mode: Mode) {
        self.group = group
        self.modeBox = NIOLockedValueBox(mode)
    }

    func start() async throws {
        let modeBox = modeBox
        let headsBox = headsBox
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ScriptedHTTPProxyHandler(mode: modeBox, heads: headsBox))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async {
        do {
            try await channel?.close().get()
        } catch ChannelError.alreadyClosed {
            // Nothing left to release.
        } catch {
            FileHandle.standardError.write(Data("ScriptedHTTPProxy close failed: \(error)\n".utf8))
        }
        channel = nil
    }
}

private final class ScriptedHTTPProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let mode: NIOLockedValueBox<ScriptedHTTPProxy.Mode>
    private let heads: NIOLockedValueBox<[String]>
    private var responded = false

    init(mode: NIOLockedValueBox<ScriptedHTTPProxy.Mode>, heads: NIOLockedValueBox<[String]>) {
        self.mode = mode
        self.heads = heads
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        responded = true
        var request = unwrapInboundIn(data)
        let head = String(decoding: request.readBytes(length: request.readableBytes) ?? [], as: UTF8.self)
        heads.withLockedValue { if $0.count < 256 { $0.append(head) } }

        let response: String
        switch mode.withLockedValue({ $0 }) {
        case .answer(let ip):
            let body = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"\#(ip)"}]}"#
            response = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\n" +
                "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        case .challenge:
            response = "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Negotiate\r\nProxy-Authenticate: NTLM\r\n" +
                "Proxy-Authenticate: Basic realm=\"corp.example\"\r\n" +
                "Content-Length: 0\r\nConnection: close\r\n\r\n"
        }
        let channel = context.channel
        var buffer = channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
