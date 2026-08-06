// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The UDP admission gate's slot accounting.
///
/// The forwarder caps concurrent resolutions, and the gate has to sit in
/// `channelRead` — ahead of task creation — so a flood is turned away before it
/// allocates. The rule that falls out of that placement is a rule about work
/// *not* done: a datagram too short to be a DNS query must never reach the
/// gate at all.
///
/// Nothing observable distinguishes the two placements from outside. The runt
/// is dropped silently either way, and watching the in-flight count does not
/// help: a resolution admitted for a runt does nothing and hands its slot back
/// almost immediately, so a gauge reads zero whether the slot was never taken
/// or taken and already returned. Both a real socket and
/// `NIOAsyncTestingChannel.writeInbound` yield long enough for that to happen —
/// a gauge-based version of this test passes with the guard deleted.
///
/// So the rule itself is pinned with `admissionDecisionCount`, which only ever
/// climbs and therefore records the admission a correct implementation never
/// attempts. The gauge is read in exactly one place, under a resolution parked
/// by `ParkingConfigProvider` — never under a network timeout.
final class DNSAdmissionGateTests: XCTestCase {

    /// Well under the 64-slot cap per iteration, far past it in aggregate: if
    /// runts took slots, this many would exhaust the gate outright.
    private static let floodSize = 500

    private struct Gate {
        let channel: NIOAsyncTestingChannel
        let inFlight: @Sendable () -> Int
        let decisions: @Sendable () -> Int
        /// Holds the next resolution open — see `ParkingConfigProvider`.
        let armPark: @Sendable (TimeInterval) -> Void

        func tearDown() async {
            _ = try? await channel.finish()
        }
    }

    /// A config provider that can be armed to park its next caller.
    ///
    /// `resolve` calls `configProvider()` immediately after the gate has granted
    /// a slot, so a provider that has not returned yet holds that resolution —
    /// and its slot — open for as long as the test needs, with no packet and no
    /// timer anywhere in the picture.
    ///
    /// This replaces pointing the forwarder's internal nameserver at an
    /// unroutable address and leaning on its 1.5 s timeout. That looked
    /// equivalent and was not: `forwardUDP` resumes its continuation straight
    /// from `connect(host:port:)`, so on a sandbox with no route to the address
    /// the connect fails at once, the resolution finishes in microseconds, and
    /// the gauge reads 0. The park owes nothing to the network.
    ///
    /// Armed explicitly rather than parking the first caller it sees, because
    /// the first caller is not a resolution: `DNSResolutionCore.init` reads the
    /// config to build its DoH transports. An implicit "park the first call"
    /// spends itself on that one and leaves the resolution unparked — which
    /// looks like a passing test for as long as some other delay happens to
    /// cover the gap.
    ///
    /// Deliberately a blocking sleep rather than an awaited one — it has to hold
    /// a synchronous, non-async call. It is bounded and self-releasing, so even
    /// on a single-threaded cooperative pool it can only delay the test, never
    /// deadlock it.
    private final class ParkingConfigProvider: @unchecked Sendable {
        private let config: ProxyConfig
        private let armedFor = NIOLockedValueBox<TimeInterval?>(nil)

        init(config: ProxyConfig) {
            self.config = config
        }

        func arm(seconds: TimeInterval) {
            armedFor.withLockedValue { $0 = seconds }
        }

        func provide() -> ProxyConfig {
            // Disarm under the lock, sleep outside it: parking is meant to hold
            // one resolution, not serialize every later config read behind it.
            let park = armedFor.withLockedValue { armed -> TimeInterval? in
                defer { armed = nil }
                return armed
            }
            if let park {
                Thread.sleep(forTimeInterval: park)
            }
            return config
        }
    }

    /// A gate whose every resolution path is hermetic: no upstream proxies and
    /// DoH pointed at a closed loopback port. Nothing reaches the network.
    private func makeGate(
        logger: RecordingLogSink = RecordingLogSink(minLevel: .debug)
    ) async -> Gate {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dohProviders = ["https://127.0.0.1:1/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9

        let provider = ParkingConfigProvider(config: config)
        let (handler, inFlight, decisions) = LocalDNSForwarder.makeUDPHandlerForTesting(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: logger,
            configProvider: { provider.provide() }
        )
        return Gate(
            channel: await NIOAsyncTestingChannel(handler: handler),
            inFlight: inFlight,
            decisions: decisions,
            armPark: { provider.arm(seconds: $0) }
        )
    }

    private func datagram(
        _ bytes: [UInt8],
        on channel: NIOAsyncTestingChannel
    ) throws -> AddressedEnvelope<ByteBuffer> {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return AddressedEnvelope(
            remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 51_234),
            data: buffer
        )
    }

    /// A datagram too short to hold a DNS header is rejected in `channelRead`,
    /// ahead of the admission gate — it costs neither a slot nor a task.
    ///
    /// This is the regression the guard exists for. With the length check inside
    /// `resolve` instead, every runt reached the gate and spawned a task that
    /// immediately did nothing, so a flood could occupy all 64 slots with no-op
    /// work and push real queries onto the over-limit SERVFAIL path.
    func testMalformedDatagramNeverReachesTheAdmissionGate() async throws {
        let gate = await makeGate()

        for _ in 0..<Self.floodSize {
            // 4 bytes: a plausible-looking runt, well under the 12-byte header.
            try await gate.channel.writeInbound(datagram([0, 1, 2, 3], on: gate.channel))
        }

        XCTAssertEqual(
            gate.decisions(), 0,
            "\(Self.floodSize) runt datagrams reached the admission gate — the length guard is behind it again"
        )

        let reply = try await gate.channel.readOutbound(as: AddressedEnvelope<ByteBuffer>.self)
        XCTAssertNil(reply, "A runt carries no transaction ID, so there is nothing to answer")
        await gate.tearDown()
    }

    /// A datagram of exactly the header length is not a runt. Pins the boundary
    /// so the guard cannot drift into rejecting real queries.
    func testTwelveByteDatagramDoesReachTheAdmissionGate() async throws {
        let gate = await makeGate()

        try await gate.channel.writeInbound(datagram([UInt8](repeating: 0, count: 12), on: gate.channel))

        XCTAssertEqual(gate.decisions(), 1, "A 12-byte datagram is header-sized and must be admitted")

        await gate.tearDown()
    }

    /// The control for the counters themselves: a real query takes exactly one
    /// slot, holds it while the resolution runs, and returns it at the end.
    /// Without this, the assertions above could pass on counters wired to
    /// nothing.
    func testWellFormedQueryHoldsExactlyOneSlotAndReturnsIt() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let gate = await makeGate(logger: logger)
        XCTAssertEqual(gate.inFlight(), 0)
        XCTAssertEqual(gate.decisions(), 0)

        // Armed after construction, so the park lands on the resolution rather
        // than on the core's own start-up read of the config.
        gate.armPark(2)

        let query = DNSWireFormat.buildQuery(domain: "slot.example.com", txID: 0x0101, qtype: 1)
        try await gate.channel.writeInbound(datagram(query, on: gate.channel))

        XCTAssertEqual(gate.decisions(), 1, "A well-formed query must reach the gate exactly once")
        XCTAssertTrue(
            logger.entries().filter { $0.message.contains("query limit reached") }.isEmpty,
            "The decision must be a grant, not a refusal"
        )
        // Sound as a gauge read because the resolution is parked in the config
        // provider: it cannot have released the slot yet, whatever the machine
        // or the network is doing.
        XCTAssertEqual(gate.inFlight(), 1, "A well-formed query must hold exactly one admission slot")

        // And the slot comes back: `resolve` pairs with `releaseQuery` on every
        // exit path, including the ones that answer SERVFAIL.
        let released = await pollUntil(timeoutSeconds: 30) { gate.inFlight() == 0 }
        XCTAssertTrue(released, "The admission slot was never released (in flight: \(gate.inFlight()))")
        XCTAssertEqual(gate.decisions(), 1, "Releasing a slot must not re-open a decision")

        await gate.tearDown()
    }

    /// The user-visible consequence: a garbage flood does not starve a real
    /// query. Pre-fix, 500 runts would have pinned the gate and driven this
    /// query onto the over-limit SERVFAIL path.
    ///
    /// Asserted through the refusal log rather than the in-flight gauge: a
    /// refusal is logged synchronously inside `channelRead`, so its absence is
    /// settled by the time `writeInbound` returns and nothing here depends on
    /// how long a resolution happens to run.
    func testGarbageFloodDoesNotStarveAWellFormedQuery() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let gate = await makeGate(logger: logger)

        for _ in 0..<Self.floodSize {
            try await gate.channel.writeInbound(datagram([0xFF, 0xFF], on: gate.channel))
        }

        let query = DNSWireFormat.buildQuery(domain: "survivor.example.com", txID: 0x0202, qtype: 1)
        try await gate.channel.writeInbound(datagram(query, on: gate.channel))

        XCTAssertEqual(gate.decisions(), 1, "Only the well-formed query may reach the gate")
        XCTAssertTrue(
            logger.entries().filter { $0.message.contains("query limit reached") }.isEmpty,
            "Runt datagrams must never drive the forwarder to its in-flight cap"
        )

        await gate.tearDown()
    }

    private func pollUntil(timeoutSeconds: Int, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<(timeoutSeconds * 20) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
