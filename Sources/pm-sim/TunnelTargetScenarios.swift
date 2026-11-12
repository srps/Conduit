// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

/// A SOCKS5 client names its target as up to 255 bytes of anything, and the
/// listener's tunnel writes that target into the CONNECT request line and
/// `Host` header it sends the upstream, after Conduit's `Proxy-Authorization`.
/// A name with CR LF in it is refused before anything is dialled, with one
/// `connection.tunnel_target_rejected`; a well-formed name still tunnels.
enum TunnelTargetScenarios {
    @RuntimeActor
    static func crlfTargetRefused(verbose: Bool) async throws -> ScenarioResult {
        let name = "tunnel-target-crlf"
        let start = Date()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silent,
            socksEnabled: true,
            eventSink: { event in events.withLockedValue { if $0.count < 64 { $0.append(event) } } }
        )
        guard let socksPort = harness.server?.socksListeningPort, let upstream = harness.upstream else {
            throw NSError(domain: "pm-sim.tunnel-target", code: 1, userInfo: [NSLocalizedDescriptionKey: "SOCKS5 listener did not start"])
        }

        let forged = try await reply(connecting: "a.corp.example\r\nX-Injected: 1", port: 443, socksPort: socksPort, harness: harness)
        let headsAfterForged = upstream.requestHeadCount
        let rejected = events.withLockedValue { $0 }.filter { $0.event == "connection.tunnel_target_rejected" }
        let detail = rejected.first?.detail ?? ""

        let wellFormed = try await reply(connecting: "origin.corp.example", port: 443, socksPort: socksPort, harness: harness)
        let tunnelsAfterWellFormed = upstream.connectCount

        return ScenarioResult(
            name: name,
            clientCount: 2, clientsOpened: 2, clientsWithFirstByte: 2, clientsClosedEarly: 1,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the CR LF target got a SOCKS failure reply", forged != nil && forged != 0x00),
                .init("the CR LF target never reached the upstream", headsAfterForged == 0),
                .init("one connection.tunnel_target_rejected", rejected.count == 1),
                .init("the event names the target as one token", detail == "target=[a.corp.example__X-Injected:_1]:443 suppressed=0"),
                .init("a well-formed target still tunnels", wellFormed == 0x00 && tunnelsAfterWellFormed == 1),
            ],
            notes: [
                "forgedReply=\(forged.map { String(format: "0x%02X", $0) } ?? "<none>")",
                "upstreamHeadsAfterForged=\(headsAfterForged)",
                "rejected=\(rejected.map { $0.detail ?? "" })",
                "wellFormedReply=\(wellFormed.map { String(format: "0x%02X", $0) } ?? "<none>") tunnels=\(tunnelsAfterWellFormed)",
            ]
        )
    }

    /// The reply code of one SOCKS5 CONNECT for `host` as a name, nil when the listener closed without one.
    private static func reply(connecting host: String, port: Int, socksPort: Int, harness: SimHarness) async throws -> UInt8? {
        let request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.utf8.count)] + Array(host.utf8)
            + [UInt8(port >> 8), UInt8(port & 0xFF)]
        let responses = try await SOCKS5AuditClient.exchange(
            group: harness.group, port: socksPort, writes: [[0x05, 0x01, 0x00], request], expectedResponses: 2
        )
        return responses.count == 2 ? responses[1].dropFirst().first : nil
    }
}
