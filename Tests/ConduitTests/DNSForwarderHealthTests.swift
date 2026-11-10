// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The forwarder across network changes (#292, #296, #290 part 1): an
/// unsatisfied path answers at once, a transports reset cancels the lookups
/// in flight, no entry means no internal attempt, a silent internal server
/// opens its circuit, an entry's servers are tried in order and the longest
/// suffix wins. Every server is a loopback fake; nothing leaves the machine.
final class DNSForwarderHealthTests: XCTestCase {
    private var ownedForwarder: LocalDNSForwarder?
    private var ownedChannels: [Channel] = []
    private var ownedProviders: [AnsweringDoHProvider] = []
    private var ownedGroups: [MultiThreadedEventLoopGroup] = []
    private let log = RecordingLogSink(minLevel: .debug)
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    private let group = MultiThreadedEventLoopGroup.singleton

    override func tearDown() async throws {
        if let forwarder = ownedForwarder {
            ownedForwarder = nil
            await forwarder.stop()
        }
        for channel in ownedChannels { _ = try? await channel.close().get() }
        ownedChannels = []
        for provider in ownedProviders { _ = try? await provider.channel.close().get() }
        ownedProviders = []
        for group in ownedGroups { try await group.shutdownGracefully() }
        ownedGroups = []
        try await super.tearDown()
    }

    // MARK: - #292: an unsatisfied path

    @MainActor
    func testUnsatisfiedPathAnswersServfailAtOnceWithoutAnAttempt() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .seconds(5)
        )
        ownedForwarder?.updateNetworkPath(satisfied: false)

        var queries = (0..<16).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x7000 + UInt16($0)) }
        queries.append(DNSWireFormat.buildQuery(domain: "intranet.corp.example", txID: 0x70FF))
        let replies = try await askAll(queries, port: port)

        XCTAssertEqual(replies.count, queries.count, "every refused lookup is answered")
        XCTAssertEqual(Set(replies.map(DNSWireFormat.extractRCode)), [2], "SERVFAIL, nothing else")
        XCTAssertEqual(internalServer.queryCount, 0, "no internal attempt while the path is down")
        XCTAssertEqual(doh.requestCount(), 0, "no DoH attempt while the path is down")
        XCTAssertEqual(ownedForwarder?.inFlightQueryCount, 0, "no slot is held")
        let refused = events(named: "dns.unsatisfied_path_servfail")
        XCTAssertEqual(refused.count, 1, "the burst reports once inside the window")
        XCTAssertEqual(refused.first?.kind, .routing)
        XCTAssertEqual(refused.first?.detail?.hasSuffix(" suppressed=0"), true)
    }

    @MainActor
    func testUnsatisfiedPathStillAnswersFromInterceptAndCache() async throws {
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [], endpoints: [:], dohPort: doh.port, internalTimeout: .seconds(5),
            interceptRules: [DNSInterceptRule(pattern: "*.intercept.example", interceptIP: "127.44.3.9", enabled: true)]
        )
        let cached = DNSWireFormat.buildQuery(domain: "news.example", txID: 0x7100)
        let warm = try await ask(cached, port: port)
        XCTAssertEqual(warm.map(DNSWireFormat.extractRCode), 0, "warm the cache on a satisfied path")
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 1)
        let providerRequests = doh.requestCount()

        ownedForwarder?.updateNetworkPath(satisfied: false)

        let fromCache = try await ask(cached, port: port)
        XCTAssertEqual(fromCache.map(DNSWireFormat.extractRCode), 0, "a fresh cache entry still answers")
        XCTAssertEqual(fromCache.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        let intercepted = try await ask(DNSWireFormat.buildQuery(domain: "app.intercept.example", txID: 0x7101), port: port)
        XCTAssertEqual(intercepted.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "127.44.3.9", "an intercept rule still answers")
        XCTAssertEqual(doh.requestCount(), providerRequests, "neither asked a provider")
        XCTAssertEqual(ownedForwarder?.metricCounts?.cacheHits, 1)
    }

    @MainActor
    func testTransportsResetCancelsLookupsInFlightAndFreesTheirSlots() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .seconds(20)
        )
        let forwarder = try XCTUnwrap(ownedForwarder)
        let queries = (0..<8).map { DNSWireFormat.buildQuery(domain: "host-\($0).corp.example", txID: 0x7200 + UInt16($0)) }
        let collector = try await client(sending: queries, to: port)

        // A lookup holds its slot before its datagram reaches the server, so
        // the server's count is the one to settle on; the slot follows.
        try await settle(until: { internalServer.queryCount == queries.count }, "every lookup is waiting on the silent server")
        XCTAssertEqual(forwarder.inFlightQueryCount, queries.count, "every waiting lookup holds its slot")

        forwarder.resetUpstreamTransports(reason: "network_change")

        try await settle(until: { collector.replies().count == queries.count }, "every cancelled lookup answers")
        XCTAssertEqual(Set(collector.replies().map(DNSWireFormat.extractRCode)), [2], "a cancelled lookup answers SERVFAIL")
        try await settle(until: { forwarder.inFlightQueryCount == 0 }, "every slot is released")
        XCTAssertEqual(doh.requestCount(), 0, "a cancelled lookup starts no fallback")
        XCTAssertEqual(events(named: "dns.split_dns_doh_fallback").count, 0)
    }

    @MainActor
    func testFreshLookupAfterThePathReturnsIsAnswered() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let forwarder = try XCTUnwrap(ownedForwarder)
        forwarder.updateNetworkPath(satisfied: false)
        let burst = (0..<48).map { DNSWireFormat.buildQuery(domain: "burst-\($0).example", txID: 0x7300 + UInt16($0)) }
        let refused = try await askAll(burst, port: port)
        XCTAssertEqual(refused.count, burst.count)
        XCTAssertEqual(Set(refused.map(DNSWireFormat.extractRCode)), [2])

        forwarder.updateNetworkPath(satisfied: true)
        forwarder.resetUpstreamTransports(reason: "network_change")

        let fresh = try await ask(DNSWireFormat.buildQuery(domain: "fresh.example", txID: 0x73FF), port: port)
        XCTAssertEqual(fresh.map(DNSWireFormat.extractRCode), 0, "the first lookup on the returned path is answered")
        XCTAssertEqual(fresh.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        XCTAssertEqual(forwarder.inFlightQueryCount, 0)
    }

    /// A reset while the providers are being asked cancels the fetches, which
    /// then throw like a failed provider does. That is no provider failure:
    /// no "all providers failed" warning, no `dns.split_dns_doh_fallback`.
    @MainActor
    func testResetDuringTheDoHStageReportsNoProviderFailure() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7", silent: true)
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let forwarder = try XCTUnwrap(ownedForwarder)
        let queries = [
            DNSWireFormat.buildQuery(domain: "intranet.corp.example", txID: 0x7500),
            DNSWireFormat.buildQuery(domain: "news.example", txID: 0x7501),
        ]
        let collector = try await client(sending: queries, to: port)
        try await settle(until: { doh.requestCount() >= queries.count }, "both lookups are waiting on the provider")

        forwarder.resetUpstreamTransports(reason: "network_change")

        try await settle(until: { collector.replies().count == queries.count }, "every cancelled lookup answers")
        XCTAssertEqual(Set(collector.replies().map(DNSWireFormat.extractRCode)), [2], "SERVFAIL for a cancelled lookup")
        try await settle(until: { forwarder.inFlightQueryCount == 0 }, "every slot is released")
        XCTAssertFalse(log.containsMessage("DoH provider(s) failed", at: .warning), "a cancellation is no provider failure")
        XCTAssertTrue(log.containsMessage("DoH lookup for intranet.corp.example cancelled", at: .debug))
        XCTAssertTrue(log.containsMessage("DoH lookup for news.example cancelled", at: .debug))
        XCTAssertEqual(events(named: "dns.split_dns_doh_fallback").count, 0, "no fallback outcome to report")
    }

    /// A reset that lands after the lookup installed its response collector
    /// and before its datagram connect completed. The cancel ends the wait;
    /// the connect then fails, since the collector closed the channel. That
    /// failure must not resume the lookup a second time (it killed the
    /// process with SWIFT TASK CONTINUATION MISUSE). The forwarder runs on
    /// one event loop that the test holds while the reset lands, so the
    /// connect is pending by construction, every iteration.
    @MainActor
    func testResetWhileTheConnectIsPendingAnswersTheLookupOnce() async throws {
        let loopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        ownedGroups.append(loopGroup)
        let doh = try await provider(ip: "198.51.100.7")
        let gate = NIOLockedValueBox<DispatchSemaphore?>(nil)
        let reachedConnect = NIOLockedValueBox(false)
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": 5353], dohPort: doh.port, internalTimeout: .seconds(5),
            group: loopGroup,
            beforeInternalConnect: {
                if let hold = gate.withLockedValue({ $0 }) {
                    loopGroup.next().execute { hold.wait() }
                }
                reachedConnect.withLockedValue { $0 = true }
            }
        )
        let forwarder = try XCTUnwrap(ownedForwarder)

        for iteration in 0..<20 {
            let hold = DispatchSemaphore(value: 0)
            gate.withLockedValue { $0 = hold }
            reachedConnect.withLockedValue { $0 = false }
            let query = DNSWireFormat.buildQuery(domain: "host-\(iteration).corp.example", txID: 0x7400 + UInt16(iteration))
            let collector = try await client(sending: [query], to: port)
            try await settle(until: { reachedConnect.withLockedValue { $0 } }, "the lookup reached its connect")
            // The lookup installs its collector and hands the connect to the
            // held loop; neither waits on anything but the CPU.
            try await Task.sleep(for: .milliseconds(50))

            forwarder.resetUpstreamTransports(reason: "network_change")
            hold.signal()

            try await settle(until: { collector.replies().count == 1 }, "the cancelled lookup answers")
            XCTAssertEqual(collector.replies().map(DNSWireFormat.extractRCode), [2], "SERVFAIL, iteration \(iteration)")
            try await settle(until: { forwarder.inFlightQueryCount == 0 }, "its slot is released")
        }
    }

    // MARK: - #296: no enabled entry

    @MainActor
    func testNoEnabledSplitDNSEntrySkipsTheInternalAttempt() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        // The disabled entry's server is the only one the forwarder could
        // pick; its port is also the default internal port, so an attempt on
        // any address the forwarder made up would reach it too.
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"], enabled: false)],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .seconds(2),
            defaultInternalPort: internalServer.port
        )
        let reply = try await ask(DNSWireFormat.buildQuery(domain: "public.example", txID: 0x7400), port: port)

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 0)
        XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        XCTAssertEqual(internalServer.queryCount, 0, "no UDP attempt to any internal address")
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 1)
    }

    // MARK: - #290: per-server circuits

    /// The circuit opens on the third silence, here counted by the one
    /// internal attempt a public name makes. The probe a skipping lookup
    /// sends runs for the split-DNS timeout, 20 s here, so it is still out
    /// while the three skipping lookups run and are settled (10 s at most):
    /// no second probe can start while the first is in flight. With one
    /// 50 ms timeout for both, the probe timed out between the skipping
    /// lookups under CI load and each of them sent a new one.
    @MainActor
    func testSilentServerOpensItsCircuitAfterThreeSilencesAndIsSkipped() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port,
            internalTimeout: .milliseconds(50), internalDomainTimeout: .seconds(20)
        )
        for index in 0..<3 {
            let reply = try await ask(DNSWireFormat.buildQuery(domain: "wait-\(index).example", txID: 0x7500 + UInt16(index)), port: port)
            XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7", "silence falls back")
        }
        XCTAssertEqual(internalServer.queryCount, 3, "each of the first three lookups waited on the server")
        let opened = events(named: "dns.internal_server_circuit_opened")
        XCTAssertEqual(opened.map(\.detail), ["server=192.0.2.1 silences=3 suppressed=0"])
        XCTAssertEqual(opened.first?.kind, .health)

        let skipping = (0..<3).map { DNSWireFormat.buildQuery(domain: "skip-\($0).corp.example", txID: 0x7510 + UInt16($0)) }
        let collector = try await client(sending: skipping, to: port)
        try await settle(until: { collector.replies().count == skipping.count }, "every skipping lookup takes the fallback")
        XCTAssertEqual(Set(collector.replies().compactMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }), ["198.51.100.7"])
        XCTAssertEqual(internalServer.queryCount, 4, "three skipping lookups shared one probe")
        XCTAssertEqual(events(named: "dns.internal_server_circuit_closed").count, 0)
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 6)
    }

    @MainActor
    func testProbeReplyClosesTheCircuit() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: 3, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        for index in 0..<3 {
            _ = try await ask(DNSWireFormat.buildQuery(domain: "wait-\(index).corp.example", txID: 0x7600 + UInt16(index)), port: port)
        }
        XCTAssertEqual(events(named: "dns.internal_server_circuit_opened").count, 1)

        let skipped = try await ask(DNSWireFormat.buildQuery(domain: "probe.corp.example", txID: 0x7610), port: port)
        XCTAssertEqual(skipped.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7", "the skipping lookup takes the fallback")
        try await settle(until: { self.events(named: "dns.internal_server_circuit_closed").count == 1 }, "the probe's reply closes the circuit")
        XCTAssertEqual(events(named: "dns.internal_server_circuit_closed").first?.detail, "server=192.0.2.1 suppressed=0")
        XCTAssertEqual(internalServer.queryCount, 4)

        let internalAnswer = try await ask(DNSWireFormat.buildQuery(domain: "back.corp.example", txID: 0x7611), port: port)
        XCTAssertEqual(internalAnswer.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "192.0.2.80", "the next lookup asks the server again")
        XCTAssertEqual(internalServer.queryCount, 5)
    }

    @MainActor
    func testTransportsResetClosesOpenCircuits() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        for index in 0..<3 {
            _ = try await ask(DNSWireFormat.buildQuery(domain: "wait-\(index).corp.example", txID: 0x7700 + UInt16(index)), port: port)
        }
        XCTAssertEqual(events(named: "dns.internal_server_circuit_opened").count, 1)

        ownedForwarder?.resetUpstreamTransports(reason: "vpn_connected")

        _ = try await ask(DNSWireFormat.buildQuery(domain: "again.corp.example", txID: 0x7710), port: port)
        XCTAssertEqual(internalServer.queryCount, 4, "after the reset the lookup itself asks the server")
        XCTAssertEqual(events(named: "dns.internal_server_circuit_closed").count, 0, "a reset closes without a probe and without an event")
    }

    // MARK: - #290: per-entry servers

    @MainActor
    func testSecondServerIsAskedWhenTheFirstIsSilent() async throws {
        let silent = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let answering = try await ScriptedInternalServer.start(group: group, silentFor: 0, answering: "192.0.2.81")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1", "192.0.2.2"])],
            endpoints: ["192.0.2.1": silent.port, "192.0.2.2": answering.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let reply = try await ask(DNSWireFormat.buildQuery(domain: "mail.corp.example", txID: 0x7800), port: port)

        XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "192.0.2.81", "the second server's answer")
        XCTAssertEqual(silent.queryCount, 1)
        XCTAssertEqual(answering.queryCount, 1)
        XCTAssertEqual(doh.requestCount(), 0, "an internal reply is the answer; no fallback")
        XCTAssertEqual(events(named: "dns.split_dns_doh_fallback").count, 0)
    }

    @MainActor
    func testLongestSuffixEntryServersAreAsked() async throws {
        let parent = try await ScriptedInternalServer.start(group: group, silentFor: 0, answering: "192.0.2.80")
        let child = try await ScriptedInternalServer.start(group: group, silentFor: 0, answering: "192.0.2.81")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [
                DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"]),
                DomainDNSEntry(domain: "eu.corp.example", servers: ["192.0.2.2"]),
            ],
            endpoints: ["192.0.2.1": parent.port, "192.0.2.2": child.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let eu = try await ask(DNSWireFormat.buildQuery(domain: "host.eu.corp.example", txID: 0x7900), port: port)
        let global = try await ask(DNSWireFormat.buildQuery(domain: "host.corp.example", txID: 0x7901), port: port)

        XCTAssertEqual(eu.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "192.0.2.81", "the eu entry's server answers its names")
        XCTAssertEqual(global.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "192.0.2.80")
        XCTAssertEqual(parent.queryCount, 1)
        XCTAssertEqual(child.queryCount, 1)
    }

    @MainActor
    func testSplitDNSFallbackAnswerHasAShortTTL() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])],
            endpoints: ["192.0.2.1": internalServer.port], dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let fallback = try await ask(DNSWireFormat.buildQuery(domain: "vpn.corp.example", txID: 0x7A00), port: port)
        XCTAssertEqual(fallback.flatMap(DNSWireFormat.firstIPv4Answer)?.ttl, 5, "the provider said 60 s")

        let publicAnswer = try await ask(DNSWireFormat.buildQuery(domain: "public.example", txID: 0x7A01), port: port)
        XCTAssertEqual(publicAnswer.flatMap(DNSWireFormat.firstIPv4Answer)?.ttl, 60, "a public answer keeps its TTL")
    }

    // MARK: - #290: the internal stage budget

    /// Six silent servers under one entry, at the production timeouts. The
    /// attempts stop once the next would not fit the 5 s budget, so the
    /// fallback answer reaches the client inside the helper relay's pending
    /// window instead of 12 s later, when the relay would have dropped it.
    /// Measured, as a budget has to be; the margin is the window's other
    /// half.
    @MainActor
    func testSixSilentServersStillAnswerInsideTheRelayWindow() async throws {
        let defaults = DNSForwarderTuning()
        let servers = try await sixSilentServers()
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: sixAddresses)],
            endpoints: endpoints(of: servers), dohPort: doh.port,
            internalTimeout: defaults.internalDomainTimeout, internalStageBudget: defaults.internalStageBudget
        )
        let clock = ContinuousClock()
        let started = clock.now
        let reply = try await ask(DNSWireFormat.buildQuery(domain: "portal.corp.example", txID: 0x7B00), port: port)
        let elapsed = clock.now - started

        XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7", "the fallback answers")
        XCTAssertLessThan(elapsed, .seconds(UDPRelay.staleTimeoutSeconds), "inside the relay window")
        XCTAssertEqual(servers.map(\.queryCount), [1, 1, 0, 0, 0, 0], "two 2 s attempts fit the 5 s budget; a third would not")
        XCTAssertEqual(
            events(named: "dns.split_dns_doh_fallback").map(\.detail),
            ["domain=corp.example name=portal.corp.example server=192.0.2.1,192.0.2.2 outcome=answered suppressed=0"]
        )
    }

    /// A server the budget left unasked recorded no silence. With a budget
    /// that fits two 300 ms attempts, three lookups open the circuits of
    /// the first two servers and no other; the fourth lookup skips those
    /// two and asks the next two. The second attempt fits as long as the
    /// first ends within 450 ms, a 150 ms allowance for a late timer.
    @MainActor
    func testServersTheBudgetLeftUnaskedRecordNoSilence() async throws {
        let servers = try await sixSilentServers()
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: sixAddresses)],
            endpoints: endpoints(of: servers), dohPort: doh.port,
            internalTimeout: .milliseconds(300), internalStageBudget: .milliseconds(750)
        )
        for index in 0..<3 {
            let reply = try await ask(DNSWireFormat.buildQuery(domain: "wait-\(index).corp.example", txID: 0x7C00 + UInt16(index)), port: port)
            XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7", "silence falls back")
        }
        XCTAssertEqual(servers.map(\.queryCount), [3, 3, 0, 0, 0, 0], "each lookup asked the first two servers and no other")
        XCTAssertEqual(
            events(named: "dns.internal_server_circuit_opened").map(\.detail),
            ["server=192.0.2.1 silences=3 suppressed=0", "server=192.0.2.2 silences=3 suppressed=0"],
            "only the servers asked three times have open circuits"
        )

        let reply = try await ask(DNSWireFormat.buildQuery(domain: "next.corp.example", txID: 0x7C10), port: port)
        XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        try await settle(until: { servers[0].queryCount == 4 && servers[1].queryCount == 4 }, "each open circuit is probed once")
        XCTAssertEqual(servers.map(\.queryCount), [4, 4, 1, 1, 0, 0], "the fourth lookup asks the next two servers; the last two wait their turn")
        XCTAssertEqual(events(named: "dns.internal_server_circuit_opened").count, 2)
    }

    /// The production budget is a promise about the relay window: two
    /// attempts fit it, and what it leaves the DoH race exceeds the race's
    /// request timeout.
    func testInternalStageBudgetLeavesTheDoHRaceRoomInTheRelayWindow() {
        let tuning = DNSForwarderTuning()
        let budget = Double(tuning.internalStageBudget.nanoseconds) / 1e9
        let attempt = Double(tuning.internalDomainTimeout.nanoseconds) / 1e9
        XCTAssertGreaterThanOrEqual(budget, 2 * attempt, "a silent first server still leaves room for a second")
        XCTAssertLessThan(budget + DoHSessionFactory.requestTimeout, UDPRelay.staleTimeoutSeconds)
    }

    // MARK: - Fixtures

    /// The configured addresses of `sixSilentServers()`, in the order an
    /// entry names them.
    private let sixAddresses = (1...6).map { "192.0.2.\($0)" }

    /// One silent internal server per address in `sixAddresses`, each on
    /// its own loopback port.
    @MainActor
    private func sixSilentServers() async throws -> [ScriptedInternalServer] {
        var servers: [ScriptedInternalServer] = []
        for _ in sixAddresses {
            servers.append(try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80"))
        }
        return servers
    }

    private func endpoints(of servers: [ScriptedInternalServer]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(sixAddresses, servers.map(\.port)))
    }

    /// Starts the owned forwarder: `entries` as the split-DNS table, each
    /// configured server address reached on its loopback port in
    /// `endpoints`, one cleartext DoH provider on `dohPort`, and both internal
    /// timeouts set to `internalTimeout` unless `internalDomainTimeout` sets
    /// the split-DNS one apart. The internal stage budget is the production
    /// default, widened when one attempt would not fit it, unless
    /// `internalStageBudget` sets it. `beforeInternalConnect` runs on the
    /// lookup's task right before each internal datagram connect. Returns
    /// the UDP port.
    @MainActor
    private func startForwarder(
        entries: [DomainDNSEntry],
        endpoints: [String: Int],
        dohPort: Int,
        internalTimeout: TimeAmount,
        internalDomainTimeout: TimeAmount? = nil,
        internalStageBudget: TimeAmount? = nil,
        interceptRules: [DNSInterceptRule] = [],
        defaultInternalPort: Int = 53,
        group: EventLoopGroup? = nil,
        beforeInternalConnect: (@Sendable () -> Void)? = nil
    ) async throws -> Int {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = entries
        config.dnsInterceptRules = interceptRules
        config.dohProviders = ["http://127.0.0.1:\(dohPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = defaultInternalPort
        tuning.internalServerEndpoint = { server in
            beforeInternalConnect?()
            return ("127.0.0.1", endpoints[server] ?? defaultInternalPort)
        }
        tuning.internalDomainTimeout = internalDomainTimeout ?? internalTimeout
        tuning.internalAttemptTimeout = internalTimeout
        tuning.internalStageBudget = internalStageBudget
            ?? max(tuning.internalStageBudget, tuning.internalDomainTimeout, tuning.internalAttemptTimeout)
        let events = events
        let forwarder = LocalDNSForwarder(
            group: group ?? self.group,
            logger: log,
            configProvider: { frozen },
            tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return try XCTUnwrap(forwarder.listeningPort)
    }

    @MainActor
    private func provider(ip: String, silent: Bool = false) async throws -> AnsweringDoHProvider {
        let provider = try await AnsweringDoHProvider.start(group: group, ip: ip, silent: silent)
        ownedProviders.append(provider)
        return provider
    }

    @MainActor
    private func events(named name: String) -> [RuntimeEvent] {
        events.withLockedValue { $0 }.filter { $0.event == name }
    }

    /// Opens one client socket, sends every query from it and returns the
    /// collector of its replies. The channel is closed in `tearDown`.
    @MainActor
    private func client(sending queries: [[UInt8]], to port: Int) async throws -> BurstReplyCollector {
        let collector = BurstReplyCollector()
        let client = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ownedChannels.append(client)
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        for query in queries {
            var buf = client.allocator.buffer(capacity: query.count)
            buf.writeBytes(query)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        }
        return collector
    }

    /// Sends `queries` and returns the replies once all have arrived, or
    /// those that did within ten seconds.
    @MainActor
    private func askAll(_ queries: [[UInt8]], port: Int) async throws -> [[UInt8]] {
        let collector = try await client(sending: queries, to: port)
        for _ in 0..<1000 where collector.replies().count < queries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.replies()
    }

    @MainActor
    private func ask(_ query: [UInt8], port: Int) async throws -> [UInt8]? {
        try await askAll([query], port: port).first
    }

    /// Polls `condition` every 10 ms for up to ten seconds and fails the test
    /// with `what` if it never holds.
    @MainActor
    private func settle(until condition: @MainActor @escaping () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }
}

/// A loopback internal DNS server that counts the queries it receives, stays
/// silent for the first `silentFor` of them and answers the rest with one A
/// record for `answering`.
private final class ScriptedInternalServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let silentFor: Int
    private let answering: String
    private let received = NIOLockedValueBox(0)
    private(set) var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    var queryCount: Int { received.withLockedValue { $0 } }

    private init(silentFor: Int, answering: String) {
        self.silentFor = silentFor
        self.answering = answering
    }

    static func start(group: EventLoopGroup, silentFor: Int, answering: String) async throws -> ScriptedInternalServer {
        let server = ScriptedInternalServer(silentFor: silentFor, answering: answering)
        server.channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(server) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        let index = received.withLockedValue { count -> Int in
            count += 1
            return count
        }
        guard index > silentFor, let reply = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: answering) else { return }
        var out = context.channel.allocator.buffer(capacity: reply.count)
        out.writeBytes(reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
    }
}

/// Captures the datagrams a test client receives, up to 256: enough for a
/// burst over the forwarder's 64 in-flight slots, bounded like the forwarder.
private final class BurstReplyCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let lock = NSLock()
    private var received: [[UInt8]] = []

    func replies() -> [[UInt8]] {
        lock.withLock { received }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.withLock { if received.count < 256 { received.append(bytes) } }
    }
}
