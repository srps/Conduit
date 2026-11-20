// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// The forwarder across network changes (#292, #296, #290 part 1), driven
/// over UDP against loopback fakes: the internal servers are scripted
/// loopback sockets and the DoH provider a loopback fake, so nothing leaves
/// the machine. Every check is a count: datagrams a fake received, replies a
/// client got, slots the forwarder holds, events it emitted.
enum DNSHealthScenarios {
    /// RFC 5737 TEST-NET addresses: the configured internal servers (reached
    /// on loopback ports through the tuning seam) and the answers the fakes give.
    private static let serverA = "192.0.2.1"
    private static let serverB = "192.0.2.2"
    private static let internalIP = "192.0.2.80"
    private static let secondInternalIP = "192.0.2.81"
    private static let publicIP = "198.51.100.7"

    /// `pm-sim dns-unsatisfied-path` (#292).
    ///
    /// | # | condition                                              | expected                                                   |
    /// |---|--------------------------------------------------------|------------------------------------------------------------|
    /// | A | 40 lookups while the path is unsatisfied               | no reply, the internal server saw none, no DoH request     |
    /// | B | after A                                                | no slot held, one `dns.unsatisfied_path_dropped`           |
    /// | C | 8 split-DNS lookups waiting on a silent server, reset  | each re-run once; a second reset drops them, no slot held  |
    /// | D | the path returns, one fresh public lookup              | the DoH answer                                             |
    @RuntimeActor
    static func unsatisfiedPath(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsUnsatisfiedPath"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let silent = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [serverA])],
            endpoints: [serverA: silent.port], internalDomainTimeout: .seconds(20), internalAttemptTimeout: .milliseconds(50)
        )
        let port = forwarder.listeningPort ?? 0
        func count(_ event: String) -> Int { events.withLockedValue { $0 }.filter { $0.event == event }.count }

        forwarder.updateNetworkPath(satisfied: false)
        var burst = (0..<39).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x5A00 + UInt16($0)) }
        burst.append(DNSWireFormat.buildQuery(domain: "intranet.corp.example", txID: 0x5AFF))
        let refused = try await DNSBurstClient.start(group: group, sending: burst, to: port)
        try await drain(port: port, forwarder: forwarder, client: refused, group: group)
        notes.append("A replies=\(refused.replies().count)/\(burst.count) internal=\(silent.queryCount) doh=\(provider.requests(naming: "example"))")
        let passA = refused.replies().isEmpty && silent.queryCount == 0 && provider.requests(naming: "example") == 0
        let inFlightAfterBurst = forwarder.inFlightQueryCount
        notes.append("B inFlight=\(inFlightAfterBurst) events=\(count("dns.unsatisfied_path_dropped"))")
        let passB = inFlightAfterBurst == 0 && count("dns.unsatisfied_path_dropped") == 1

        forwarder.updateNetworkPath(satisfied: true)
        let waiting = (0..<8).map { DNSWireFormat.buildQuery(domain: "host-\($0).corp.example", txID: 0x5B00 + UInt16($0)) }
        let client = try await DNSBurstClient.start(group: group, sending: waiting, to: port)
        try await settle { silent.queryCount == waiting.count }
        let heldBeforeReset = forwarder.inFlightQueryCount
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { silent.queryCount == 2 * waiting.count }
        let rerun = silent.queryCount
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { forwarder.inFlightQueryCount == 0 }
        notes.append("C held=\(heldBeforeReset) rerun=\(rerun) replies=\(client.replies().count) inFlight=\(forwarder.inFlightQueryCount) internal=\(silent.queryCount)")
        let passC = heldBeforeReset == waiting.count && rerun == 2 * waiting.count && client.replies().isEmpty
            && forwarder.inFlightQueryCount == 0 && silent.queryCount == 2 * waiting.count

        let fresh = try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: "fresh.example", txID: 0x5C00), port: port, timeout: 12)
        let freshIP = fresh.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        notes.append("D fresh ip=\(freshIP ?? "none")")
        let passD = freshIP == publicIP

        let checks = [passA, passB, passC, passD]
        notes.append(checks.allSatisfy { $0 } ? "PASS — no path drops at once, a reset re-runs once and frees the slots, the returned path answers" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: burst.count + waiting.count + 1,
            answered: refused.replies().count + client.replies().count + (fresh == nil ? 0 : 1),
            assertions: [
                .init("a burst while the path is unsatisfied gets no reply and no internal or DoH attempt", passA),
                .init("the burst holds no slot and reports one throttled event", passB),
                .init("a transports reset re-runs the lookups in flight once; a second reset drops them and frees their slots", passC),
                .init("a fresh lookup right after the path returns is answered", passD),
            ]
        )
    }

    /// `pm-sim dns-reset-no-negative-answer` (decision 0049). With the
    /// override every lookup on the Mac reaches the forwarder, and a stub
    /// caches SERVFAIL, so a transports reset must never produce one.
    ///
    /// | # | condition                                                     | expected                                                     |
    /// |---|---------------------------------------------------------------|--------------------------------------------------------------|
    /// | A | split-DNS lookup waiting on its server, reset                 | one reply: the server's answer to the re-run, no SERVFAIL    |
    /// | B | public lookup waiting on DoH, reset                           | one reply: the fresh transports' DoH answer                  |
    /// | C | 4 lookups, reset, second reset during their re-runs           | no reply at all, no slot held, server saw each twice         |
    /// | D | lookup with no time left in its window, reset                 | no reply, no re-run                                          |
    /// | E | events                                                        | `dns.reset_lookup_rerun` rerun, answered, both drop causes   |
    @RuntimeActor
    static func resetNoNegativeAnswer(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsResetNoNegativeAnswer"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let corp = try await ScriptedInternalServer.start(group: group, silentFor: 1, answering: internalIP)
        let held = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            // `held.example` first: its silent server is the one internal attempt a public name makes.
            entries: [
                DomainDNSEntry(domain: "held.example", servers: [serverB]),
                DomainDNSEntry(domain: "corp.example", servers: [serverA]),
            ],
            endpoints: [serverA: corp.port, serverB: held.port],
            internalDomainTimeout: .seconds(20), internalAttemptTimeout: .milliseconds(50)
        )
        let port = forwarder.listeningPort ?? 0
        func decisions() -> [String] {
            events.withLockedValue { $0 }.filter { $0.event == "dns.reset_lookup_rerun" }.compactMap(\.detail)
        }

        let clientA = try await DNSBurstClient.start(group: group, sending: [DNSWireFormat.buildQuery(domain: "app.corp.example", txID: 0x5F00)], to: port)
        try await settle { corp.queryCount == 1 }
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { clientA.replies().count == 1 && forwarder.inFlightQueryCount == 0 }
        let rcodesA = clientA.replies().map(DNSWireFormat.extractRCode)
        let ipA = clientA.replies().first.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        notes.append("A replies=\(clientA.replies().count) rcodes=\(rcodesA) ip=\(ipA ?? "none") server=\(corp.queryCount)")
        let passA = rcodesA == [0] && ipA == internalIP && corp.queryCount == 2

        provider.holdResponses(true)
        let clientB = try await DNSBurstClient.start(group: group, sending: [DNSWireFormat.buildQuery(domain: "news.example", txID: 0x5F10)], to: port)
        try await settle { provider.requests(naming: "news.example") >= 1 }
        let firstRequests = provider.requests(naming: "news.example")
        provider.holdResponses(false)
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { clientB.replies().count == 1 && forwarder.inFlightQueryCount == 0 }
        let rcodesB = clientB.replies().map(DNSWireFormat.extractRCode)
        let ipB = clientB.replies().first.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        notes.append("B replies=\(clientB.replies().count) rcodes=\(rcodesB) ip=\(ipB ?? "none") doh=\(firstRequests)->\(provider.requests(naming: "news.example"))")
        let passB = rcodesB == [0] && ipB == publicIP && provider.requests(naming: "news.example") > firstRequests

        let waiting = (0..<4).map { DNSWireFormat.buildQuery(domain: "host-\($0).held.example", txID: 0x5F20 + UInt16($0)) }
        let heldBefore = held.queryCount
        let clientC = try await DNSBurstClient.start(group: group, sending: waiting, to: port)
        try await settle { held.queryCount == heldBefore + waiting.count }
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { held.queryCount == heldBefore + 2 * waiting.count }
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { forwarder.inFlightQueryCount == 0 }
        try await drain(port: port, forwarder: forwarder, client: clientC, group: group)
        let heldC = held.queryCount - heldBefore
        notes.append("C replies=\(clientC.replies().count) inFlight=\(forwarder.inFlightQueryCount) server=\(heldC)")
        let passC = clientC.replies().isEmpty && forwarder.inFlightQueryCount == 0 && heldC == 2 * waiting.count

        let late = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let noWindow = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [serverA])],
            endpoints: [serverA: late.port],
            internalDomainTimeout: .seconds(20), internalAttemptTimeout: .milliseconds(50), lookupWindow: .zero
        )
        let noWindowPort = noWindow.listeningPort ?? 0
        let clientD = try await DNSBurstClient.start(group: group, sending: [DNSWireFormat.buildQuery(domain: "late.corp.example", txID: 0x5F30)], to: noWindowPort)
        try await settle { late.queryCount == 1 }
        noWindow.resetUpstreamTransports(reason: "network_change")
        try await settle { noWindow.inFlightQueryCount == 0 }
        try await drain(port: noWindowPort, forwarder: noWindow, client: clientD, group: group)
        notes.append("D replies=\(clientD.replies().count) server=\(late.queryCount)")
        let passD = clientD.replies().isEmpty && late.queryCount == 1

        let seen = decisions()
        notes.append("E events: \(seen)")
        func has(_ fragment: String) -> Bool { seen.contains { $0.contains(fragment) } }
        let passE = has("name=app.corp.example outcome=rerun ") && has("name=app.corp.example outcome=answered ")
            && has(" outcome=dropped cause=reset_again ") && has("name=late.corp.example outcome=dropped cause=no_time_left ")

        let everyReply = clientA.replies() + clientB.replies() + clientC.replies() + clientD.replies()
        let negative = everyReply.filter { DNSWireFormat.extractRCode(from: $0) != 0 }.count
        notes.append("negative replies=\(negative)")
        let checks = [passA, passB, passC, passD, passE, negative == 0]
        notes.append(checks.allSatisfy { $0 } ? "PASS — a reset re-runs the lookup on the fresh transports and never answers it SERVFAIL" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: 7 + waiting.count, answered: everyReply.count,
            assertions: [
                .init("a split-DNS lookup cancelled by a reset is answered by its re-run, with no SERVFAIL", passA),
                .init("a public lookup cancelled during DoH is answered by the fresh transports", passB),
                .init("a re-run cancelled by a second reset gets no reply and frees its slot", passC),
                .init("a lookup with no time left in its window gets no reply and no re-run", passD),
                .init("each retry and drop decision emits dns.reset_lookup_rerun", passE),
                .init("no reply in the scenario carries a negative rcode", negative == 0),
            ]
        )
    }

    /// `pm-sim dns-no-split-entries` (#296). With the only entry disabled,
    /// a public name is answered by DoH and the internal server, which also
    /// sits on the default internal port, receives nothing.
    @RuntimeActor
    static func noSplitEntries(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsNoSplitEntries"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let silent = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [serverA], enabled: false)],
            endpoints: [serverA: silent.port], internalDomainTimeout: .seconds(2), internalAttemptTimeout: .seconds(2),
            defaultInternalPort: silent.port
        )
        let port = forwarder.listeningPort ?? 0

        let queries = (0..<4).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x5D00 + UInt16($0)) }
        let replies = try await DNSBurstClient.ask(queries, port: port, group: group)
        let ips = Set(replies.compactMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip })
        notes.append("replies=\(replies.count)/\(queries.count) ips=\(ips.sorted()) internal=\(silent.queryCount)")
        let passA = replies.count == queries.count && ips == [publicIP]
        let passB = silent.queryCount == 0
        let checks = [passA, passB]
        notes.append(checks.allSatisfy { $0 } ? "PASS — no entry, no internal attempt" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: queries.count, answered: replies.count,
            assertions: [
                .init("with no enabled split-DNS entry a public name is answered by DoH", passA),
                .init("no UDP attempt reaches any internal address", passB),
            ]
        )
    }

    /// `pm-sim dns-internal-server-circuit` (#290 part 1). The internal
    /// timeout is 300 ms, so the three lookups of E finish while the one probe
    /// they share is still out.
    ///
    /// | # | condition                                                  | expected                                                       |
    /// |---|------------------------------------------------------------|----------------------------------------------------------------|
    /// | A | 3 split-DNS lookups, server silent                         | 3 DoH answers, server saw 3, one `..._circuit_opened`          |
    /// | B | the server now answers; one lookup                         | the DoH answer (skipped), the probe closes the circuit, saw 4 |
    /// | C | one lookup                                                 | the internal answer, saw 5                                     |
    /// | D | the server is silent again; 3 lookups                      | 3 DoH answers, saw 8; the reopening event is gated (still 1)   |
    /// | E | 3 lookups while open, then a transports reset, one lookup  | saw 9 (one probe) then 10 (the lookup asks), no `_closed`      |
    /// | F | entry with two servers, first silent                       | the second server's answer, each asked once, no fallback       |
    /// | G | entries `corp.example` and `eu.corp.example`               | `host.eu.corp.example` is answered by the eu entry's server     |
    @RuntimeActor
    static func internalServerCircuit(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsInternalServerCircuit"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let flaky = try await ScriptedInternalServer.start(group: group, silentFor: 3, answering: internalIP)
        let second = try await ScriptedInternalServer.start(group: group, silentFor: 0, answering: secondInternalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [
                DomainDNSEntry(domain: "corp.example", servers: [serverA]),
                DomainDNSEntry(domain: "eu.corp.example", servers: [serverB]),
                DomainDNSEntry(domain: "two.example", servers: [serverA, serverB]),
            ],
            endpoints: [serverA: flaky.port, serverB: second.port],
            internalDomainTimeout: .milliseconds(300), internalAttemptTimeout: .milliseconds(300)
        )
        let port = forwarder.listeningPort ?? 0
        func count(_ event: String) -> Int { events.withLockedValue { $0 }.filter { $0.event == event }.count }
        func lookup(_ domain: String, _ id: UInt16) async throws -> String? {
            try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: domain, txID: id), port: port, timeout: 12)
                .flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        }
        func lookups(_ prefix: String, _ base: UInt16) async throws -> [String] {
            var ips: [String] = []
            for index in 0..<3 { ips.append(try await lookup("\(prefix)-\(index).corp.example", base + UInt16(index)) ?? "none") }
            return ips
        }

        let ipsA = try await lookups("wait", 0x5E00)
        notes.append("A ips=\(ipsA) server=\(flaky.queryCount) opened=\(count("dns.internal_server_circuit_opened"))")
        let passA = ipsA.allSatisfy { $0 == publicIP } && flaky.queryCount == 3 && count("dns.internal_server_circuit_opened") == 1

        let skipped = try await lookup("probe.corp.example", 0x5E10)
        try await settle { count("dns.internal_server_circuit_closed") == 1 }
        notes.append("B ip=\(skipped ?? "none") server=\(flaky.queryCount) closed=\(count("dns.internal_server_circuit_closed"))")
        let passB = skipped == publicIP && flaky.queryCount == 4 && count("dns.internal_server_circuit_closed") == 1

        let afterProbe = try await lookup("back.corp.example", 0x5E20)
        notes.append("C ip=\(afterProbe ?? "none") server=\(flaky.queryCount)")
        let passC = afterProbe == internalIP && flaky.queryCount == 5

        flaky.silentFor(.max)
        let ipsD = try await lookups("again", 0x5E30)
        notes.append("D ips=\(ipsD) server=\(flaky.queryCount) opened=\(count("dns.internal_server_circuit_opened"))")
        // The second opening inside the minute is held back by the per-server event gate; E shows the circuit is open.
        let passD = ipsD.allSatisfy { $0 == publicIP } && flaky.queryCount == 8 && count("dns.internal_server_circuit_opened") == 1

        let ipsE = try await lookups("skip", 0x5E40)
        let sawWhileOpen = flaky.queryCount
        forwarder.resetUpstreamTransports(reason: "vpn_connected")
        let afterReset = try await lookup("reset.corp.example", 0x5E4F)
        notes.append("E ips=\(ipsE) sawWhileOpen=\(sawWhileOpen) ip=\(afterReset ?? "none") server=\(flaky.queryCount) closed=\(count("dns.internal_server_circuit_closed"))")
        let passE = ipsE.allSatisfy { $0 == publicIP } && sawWhileOpen == 9 && afterReset == publicIP && flaky.queryCount == 10
            && count("dns.internal_server_circuit_closed") == 1

        let fallbackEventsBefore = count("dns.split_dns_doh_fallback")
        let twoIP = try await lookup("mail.two.example", 0x5E50)
        notes.append("F ip=\(twoIP ?? "none") first=\(flaky.queryCount) second=\(second.queryCount) fallbacks=\(count("dns.split_dns_doh_fallback") - fallbackEventsBefore)")
        let passF = twoIP == secondInternalIP && flaky.queryCount == 11 && second.queryCount == 1
            && count("dns.split_dns_doh_fallback") == fallbackEventsBefore

        let euIP = try await lookup("host.eu.corp.example", 0x5E60)
        notes.append("G ip=\(euIP ?? "none") first=\(flaky.queryCount) second=\(second.queryCount)")
        let passG = euIP == secondInternalIP && flaky.queryCount == 11 && second.queryCount == 2

        let checks = [passA, passB, passC, passD, passE, passF, passG]
        notes.append(checks.allSatisfy { $0 } ? "PASS — the circuit opens, skips, probes closed and resets; servers in order; longest suffix wins" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: 14, answered: 14,
            assertions: [
                .init("three silences open the server's circuit, each lookup falling back", passA),
                .init("a lookup skips the open circuit and its probe's reply closes it", passB),
                .init("the next lookup asks the server again", passC),
                .init("three silences reopen the circuit, its event held by the per-server gate", passD),
                .init("lookups while open share one probe, and a transports reset closes the circuit without one", passE),
                .init("an entry's second server answers when the first is silent", passF),
                .init("the longest-suffix entry's server answers its names", passG),
            ]
        )
    }

    /// `pm-sim dns-internal-stage-budget` (#290 part 1). Six silent servers
    /// under one entry at the production timeouts: the 5 s budget fits two
    /// 2 s attempts, so the DoH answer reaches the client inside the helper
    /// relay's pending window (`UDPRelay.staleTimeoutSeconds`) instead of
    /// 12 s later, and the servers the budget left unasked saw nothing.
    @RuntimeActor
    static func internalStageBudget(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsInternalStageBudget"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let addresses = (1...6).map { "192.0.2.\($0)" }
        var servers: [ScriptedInternalServer] = []
        for _ in addresses {
            servers.append(try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP))
        }
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let defaults = DNSForwarderTuning()
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: addresses)],
            endpoints: Dictionary(uniqueKeysWithValues: zip(addresses, servers.map(\.port))),
            internalDomainTimeout: defaults.internalDomainTimeout, internalAttemptTimeout: defaults.internalAttemptTimeout
        )
        let port = forwarder.listeningPort ?? 0

        let asked = Date()
        let reply = try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: "portal.corp.example", txID: 0x5E00), port: port, timeout: 12)
        let seconds = Date().timeIntervalSince(asked)
        let ip = reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        let counts = servers.map(\.queryCount)
        let fallbacks = events.withLockedValue { $0 }.filter { $0.event == "dns.split_dns_doh_fallback" }.map { $0.detail ?? "" }
        let relayWindow = UDPRelay.staleTimeoutSeconds
        notes.append("A ip=\(ip ?? "none") in \(String(format: "%.2f", seconds))s, relay window \(Int(relayWindow))s")
        let passA = ip == publicIP && seconds < relayWindow
        notes.append("B servers saw \(counts)")
        let passB = counts == [1, 1, 0, 0, 0, 0]
        notes.append("C events: \(fallbacks)")
        let passC = fallbacks == ["domain=corp.example name=portal.corp.example server=192.0.2.1,192.0.2.2 outcome=answered suppressed=0"]

        let checks = [passA, passB, passC]
        notes.append(checks.allSatisfy { $0 } ? "PASS — two attempts fit the budget, the rest are not asked, the fallback answers inside the relay window" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: 1, answered: reply == nil ? 0 : 1,
            assertions: [
                .init("the fallback answer arrives inside UDPRelay's pending window with six silent servers", passA),
                .init("two 2 s attempts fit the 5 s budget; the other four servers are not asked", passB),
                .init("the fallback event lists the two servers asked", passC),
            ]
        )
    }

    // MARK: - Fixtures

    @RuntimeActor
    private static func startForwarder(
        group: EventLoopGroup,
        logger: any LogSink,
        provider: FakeAnsweringDoHProvider,
        events: NIOLockedValueBox<[RuntimeEvent]>,
        entries: [DomainDNSEntry],
        endpoints: [String: Int],
        internalDomainTimeout: TimeAmount,
        internalAttemptTimeout: TimeAmount,
        defaultInternalPort: Int = 53,
        lookupWindow: TimeAmount? = nil
    ) async throws -> LocalDNSForwarder {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = entries
        config.dohProviders = ["http://127.0.0.1:\(provider.port)/dns-query"]
        config.upstreams = []
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = defaultInternalPort
        tuning.internalServerEndpoint = { server in ("127.0.0.1", endpoints[server] ?? defaultInternalPort) }
        tuning.internalDomainTimeout = internalDomainTimeout
        tuning.internalAttemptTimeout = internalAttemptTimeout
        // The production budget, widened when one attempt would not fit it.
        tuning.internalStageBudget = max(tuning.internalStageBudget, internalDomainTimeout, internalAttemptTimeout)
        if let lookupWindow { tuning.lookupWindow = lookupWindow }
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger, configProvider: { frozen }, tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return forwarder
    }

    /// Returns once every query `client` sent before now has ended: the
    /// forwarder probe is answered on the event loop after the earlier
    /// datagrams were admitted, and each admitted lookup holds a slot.
    @RuntimeActor
    private static func drain(port: Int, forwarder: LocalDNSForwarder, client: DNSBurstClient, group: EventLoopGroup) async throws {
        let marker = try await DNSBurstClient.start(
            group: group, sending: [DNSWireFormat.buildQuery(domain: DNSWireFormat.forwarderProbeDomain, txID: 0x5FFF)], to: port
        )
        try await settle { !marker.replies().isEmpty && forwarder.inFlightQueryCount == 0 }
    }

    /// Polls `condition` every 10 ms for up to ten seconds; the caller's
    /// counts then say whether it held.
    @RuntimeActor
    private static func settle(_ condition: @RuntimeActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func result(
        name: String, start: Date, notes: [String], clients: Int, answered: Int, assertions: [ScenarioAssertion]
    ) -> ScenarioResult {
        ScenarioResult(
            name: name,
            clientCount: clients,
            clientsOpened: clients,
            clientsWithFirstByte: answered,
            clientsClosedEarly: clients - answered,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions,
            notes: notes
        )
    }
}

/// A loopback internal DNS server that counts the queries it receives, stays
/// silent for the next `silentFor` of them and answers the rest with one A
/// record for `answering`.
private final class ScriptedInternalServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let answering: String
    private let state = NIOLockedValueBox((received: 0, silentUntil: 0))
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    var queryCount: Int { state.withLockedValue { $0.received } }

    private init(answering: String) {
        self.answering = answering
    }

    @RuntimeActor
    static func start(group: EventLoopGroup, silentFor: Int, answering: String) async throws -> ScriptedInternalServer {
        let server = ScriptedInternalServer(answering: answering)
        server.silentFor(silentFor)
        server.channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(server) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ScenarioCleanup.register { _ = try? await server.channel?.close().get() }
        return server
    }

    /// Stays silent for the next `count` queries.
    func silentFor(_ count: Int) {
        state.withLockedValue { $0.silentUntil = count == .max ? .max : $0.received + count }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        let answers = state.withLockedValue { state -> Bool in
            state.received += 1
            return state.received > state.silentUntil
        }
        guard answers, let reply = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: answering) else { return }
        var out = context.channel.allocator.buffer(capacity: reply.count)
        out.writeBytes(reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
    }
}

/// One client socket that sends a burst of queries and collects up to 256
/// replies, so a scenario can count them.
private final class DNSBurstClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let received = NIOLockedValueBox<[[UInt8]]>([])

    func replies() -> [[UInt8]] { received.withLockedValue { $0 } }

    @RuntimeActor
    static func start(group: EventLoopGroup, sending queries: [[UInt8]], to port: Int) async throws -> DNSBurstClient {
        let client = DNSBurstClient()
        let channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(client) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ScenarioCleanup.register { _ = try? await channel.close().get() }
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        for query in queries {
            var buffer = channel.allocator.buffer(capacity: query.count)
            buffer.writeBytes(query)
            try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buffer)).get()
        }
        return client
    }

    /// Sends `queries` and returns the replies that arrived within ten seconds.
    @RuntimeActor
    static func ask(_ queries: [[UInt8]], port: Int, group: EventLoopGroup) async throws -> [[UInt8]] {
        let client = try await start(group: group, sending: queries, to: port)
        for _ in 0..<1000 where client.replies().count < queries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return client.replies()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        received.withLockedValue { if $0.count < 256 { $0.append(bytes) } }
    }
}
