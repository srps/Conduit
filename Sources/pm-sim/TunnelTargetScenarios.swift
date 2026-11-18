// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

/// A SOCKS5 client names its target as up to 255 bytes of anything, and the
/// listener writes that name into log lines and into the CONNECT request line
/// and `Host` header of a request that carries Conduit's `Proxy-Authorization`.
/// A name that is not a host (CR LF, a space and `=`, userinfo) is refused when
/// the request is parsed, with one `connection.socks5_name_rejected` and no log
/// line or CONNECT of its own; a well-formed name still tunnels (#309).
enum TunnelTargetScenarios {
    @RuntimeActor
    static func crlfTargetRefused(verbose: Bool) async throws -> ScenarioResult {
        let name = "tunnel-target-crlf"
        let start = Date()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let logger = RecordingLogSink(minLevel: .debug)
        let harness = SimHarness(verbose: verbose, logger: logger)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silent,
            socksEnabled: true,
            eventSink: { event in events.withLockedValue { if $0.count < 64 { $0.append(event) } } }
        )
        guard let socksPort = harness.server?.socksListeningPort, let upstream = harness.upstream else {
            throw NSError(domain: "pm-sim.tunnel-target", code: 1, userInfo: [NSLocalizedDescriptionKey: "SOCKS5 listener did not start"])
        }

        let forgedNames = ["a.corp.example\r\nX-Injected: 1", "a.corp.example upstream=X-Injected", "alice:s3cr3t@a.corp.example"]
        var forgedReplies: [UInt8?] = []
        for forged in forgedNames {
            forgedReplies.append(try await reply(connecting: forged, port: 443, socksPort: socksPort, harness: harness))
        }
        let headsAfterForged = upstream.requestHeadCount
        let rejected = events.withLockedValue { $0 }.filter { $0.event == "connection.socks5_name_rejected" }
        let detail = rejected.first?.detail ?? ""
        let forgedText = (logger.entries().map(\.message) + events.withLockedValue { $0 }.map { $0.detail ?? "" })
            .filter { text in ["X-Injected", "s3cr3t", "\r", "\n"].contains { text.contains($0) } }

        let wellFormed = try await reply(connecting: "origin.corp.example", port: 443, socksPort: socksPort, harness: harness)
        let tunnelsAfterWellFormed = upstream.connectCount

        return ScenarioResult(
            name: name,
            clientCount: forgedNames.count + 1, clientsOpened: forgedNames.count + 1,
            clientsWithFirstByte: forgedNames.count + 1, clientsClosedEarly: forgedNames.count,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every forged name got a general-failure reply", forgedReplies == forgedNames.map { _ in 0x01 }),
                .init("no forged name reached the upstream", headsAfterForged == 0),
                .init("one connection.socks5_name_rejected for the three", rejected.count == 1),
                .init("the event shows only the first name's length", detail == "name_bytes=\(forgedNames[0].utf8.count) suppressed=0"),
                .init("no log line or event holds a forged name's text", forgedText.isEmpty),
                .init("a well-formed name still tunnels", wellFormed == 0x00 && tunnelsAfterWellFormed == 1),
            ],
            notes: [
                "forgedReplies=\(forgedReplies.map { $0.map { String(format: "0x%02X", $0) } ?? "<none>" })",
                "upstreamHeadsAfterForged=\(headsAfterForged)",
                "rejected=\(rejected.map { $0.detail ?? "" })",
                "forgedText=\(forgedText.map(\.debugDescription))",
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
