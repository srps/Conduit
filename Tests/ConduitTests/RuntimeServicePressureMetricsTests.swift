// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// Stop and status admission under fake-owner pressure, through the production transport. The owner is stalled: its hops are queued and
/// not run until the test drains them. Parked stream pulls are real subscriptions, so each one holds a stream-lane reservation for as long
/// as its wait is parked. The counts come from the answers and the lane reservations, and they are printed as metrics. The assertions are the
/// invariants only: a Stop is admitted under the ordinary flood and under full stream pressure, a status read is answered from its own lane,
/// and a pull beyond the stream lane is refused as busy without ending its stream. No latency threshold is asserted, and nothing here is a
/// resource or RSS claim.
final class RuntimeServicePressureMetricsTests: XCTestCase {
    private let frameLimits = try! ControlFrameLimits(maxFrameBytes: 64 * 1024)

    /// How many calls of one kind were answered, and how many were refused as busy before they reached the owner.
    final class Tally: @unchecked Sendable {
        var answered = 0
        var refused = 0
    }

    /// One measured row. Each count is what the transport did with the calls of one kind.
    struct PressureRow {
        let label: String
        let ordinaryAttempted: Int
        let ordinaryAnswered: Int
        let streamHeld: Int
        let stopModules: Int
        let stopAnswered: Int
        let statusAttempted: Int
        let statusAnswered: Int

        var line: String {
            "PRESSURE \(label): streams held=\(streamHeld)"
                + " | ordinary attempted=\(ordinaryAttempted) answered=\(ordinaryAnswered) refused=\(ordinaryAttempted - ordinaryAnswered)"
                + " | stop modules answered=\(stopAnswered)/\(stopModules)"
                + " | status attempted=\(statusAttempted) answered=\(statusAnswered) refused=\(statusAttempted - statusAnswered)"
        }
    }

    @RuntimeActor private func encoded(_ id: Int, _ call: ControlRuntimeCall) throws -> Data {
        try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(id),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(1_000), call: call))
            ),
            limits: frameLimits
        )
    }

    /// One caller call through the production transport, tallied when it resolves.
    @RuntimeActor private func launch(
        _ transport: RuntimeInMemoryTransport,
        _ request: Data,
        deadline: RuntimeDeadline,
        tally: Tally
    ) -> Task<Void, Never> {
        let limits = frameLimits
        return Task {
            do {
                _ = try await transport.exchange(request, limits: limits, deadline: deadline)
                tally.answered += 1
            } catch {
                tally.refused += 1
            }
        }
    }

    /// Opens one live subscription through the production transport, and consumes its buffered baseline.
    @RuntimeActor private func openStream(_ harness: RuntimeServiceHarness, _ transport: RuntimeInMemoryTransport, id: Int) async throws -> ControlRuntimeStream {
        let frame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(id),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(1_000), call: .subscribe(.live)))
            ),
            limits: frameLimits
        )
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let limits = frameLimits
        let stream = try await runCall(harness.scheduling) {
            try await transport.openStream(frame, limits: limits, deadline: deadline)
        }
        _ = try await stream.next(deadline)
        return stream
    }

    /// Parks one pull on each of `count` subscriptions. Each parked pull holds one stream-lane reservation, as a live stream does. The
    /// pulls are queued first, so the test drains them once and then waits until every reservation is held.
    @RuntimeActor private func parkStreamPulls(
        _ harness: RuntimeServiceHarness,
        _ transport: RuntimeInMemoryTransport,
        count: Int
    ) async throws -> [ControlRuntimeStream] {
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        var streams: [ControlRuntimeStream] = []
        for n in 0..<count {
            streams.append(try await openStream(harness, transport, id: 600 + n))
        }
        for stream in streams {
            _ = Task { try await stream.next(deadline) }
        }
        let queued = await awaitState { harness.scheduling.pendingCount == count }
        XCTAssertTrue(queued, "each stream queued one pull")
        harness.scheduling.drainAll()
        let held = await awaitState { transport.lanes.inFlight(.stream) == count }
        XCTAssertTrue(held, "each parked pull holds one stream-lane reservation")
        return streams
    }

    /// Measures one row: the stream lane is either empty or full of parked pulls, then an ordinary flood, one Stop per module and status
    /// reads run through the production transport. Each stage waits for the observable state it expects, with a bounded wait.
    @RuntimeActor private func measure(_ label: String, streamPressure: Bool) async throws -> PressureRow {
        let harness = try RuntimeServiceHarness(subscribers: 3)
        let transport = harness.transport()
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let streamsHeld = streamPressure ? harness.limits.streamLaneCapacity : 0
        _ = try await parkStreamPulls(harness, transport, count: streamsHeld)

        let ordinaryAttempts = 6
        let ordinary = Tally()
        for n in 0..<ordinaryAttempts {
            let request = try encoded(300 + n, .submit(try RuntimeServiceFixtures.request(300 + n, .testDNS)))
            _ = launch(transport, request, deadline: deadline, tally: ordinary)
        }
        let ordinaryAdmitted = harness.limits.ordinaryLaneCapacity
        let ordinaryRefused = await awaitState { ordinary.refused == ordinaryAttempts - ordinaryAdmitted }
        XCTAssertTrue(ordinaryRefused, "the ordinary lane admits its own capacity")

        let modules = ControlModule.allCases
        let stops = Tally()
        for (index, module) in modules.enumerated() {
            let request = try encoded(400 + index, .submit(try RuntimeServiceFixtures.request(400 + index, .stop(module))))
            _ = launch(transport, request, deadline: deadline, tally: stops)
        }
        let stopsReserved = await awaitState { modules.allSatisfy { transport.lanes.inFlight(.stop($0)) == 1 } }
        XCTAssertTrue(stopsReserved, "every module's Stop reserves its own lane under the ordinary flood")

        let statusAttempts = 4
        let status = Tally()
        for n in 0..<statusAttempts {
            _ = launch(transport, try encoded(500 + n, .readSnapshot), deadline: deadline, tally: status)
        }
        let readFree = harness.limits.readLaneCapacity
        let statusRefused = await awaitState { status.refused == statusAttempts - readFree }
        XCTAssertTrue(statusRefused, "the read lane admits only its own free slots, whatever the stream lane holds")

        harness.scheduling.drainAll()
        let resolved = await awaitState {
            ordinary.answered + ordinary.refused == ordinaryAttempts
                && stops.answered == modules.count
                && status.answered + status.refused == statusAttempts
        }
        XCTAssertTrue(resolved, "every call resolves once the owner drains")
        let row = PressureRow(
            label: label,
            ordinaryAttempted: ordinaryAttempts,
            ordinaryAnswered: ordinary.answered,
            streamHeld: streamsHeld,
            stopModules: modules.count,
            stopAnswered: stops.answered,
            statusAttempted: statusAttempts,
            statusAnswered: status.answered
        )
        XCTAssertEqual(row.stopAnswered, modules.count, "a Stop for each module is answered despite the flood and the stream pressure")
        XCTAssertEqual(row.ordinaryAnswered, ordinaryAdmitted, "the ordinary lane answers exactly its capacity")
        XCTAssertEqual(row.statusAnswered, readFree, "a read is answered from the read lane's own free slots")
        print(row.line)
        return row
    }

    /// Stop admission and status answers with an ordinary flood alone, and with the stream lane full of parked pulls. Full stream pressure
    /// does not change either answer, so the stream lane is independent of the read lane, the ordinary lane and each module's stop.
    @RuntimeActor func testStopAndStatusAnswersAreTheSameWithAFullStreamLane() async throws {
        let flood = try await measure("ordinary-flood", streamPressure: false)
        let streams = try await measure("ordinary-flood+stream-lane-full", streamPressure: true)
        XCTAssertEqual(flood.stopAnswered, streams.stopAnswered, "Stop is independent of stream pressure")
        XCTAssertEqual(flood.statusAnswered, streams.statusAnswered, "status is independent of stream pressure")
    }

    /// A pull beyond the stream lane is refused as `transportBusy`, which consumes nothing and ends no stream. The other subscriptions keep
    /// their parked pulls, and the refused subscription stays open.
    @RuntimeActor func testAPullBeyondTheStreamLaneIsBusyAndNonTerminal() async throws {
        let harness = try RuntimeServiceHarness(subscribers: 3)
        let transport = harness.transport()
        _ = try await parkStreamPulls(harness, transport, count: harness.limits.streamLaneCapacity)
        let extra = try await openStream(harness, transport, id: 700)
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        do {
            _ = try await extra.next(deadline)
            XCTFail("a pull beyond the stream lane must be refused")
        } catch {
            XCTAssertEqual(error as? RuntimeWaitEnd, .transportBusy)
        }
        XCTAssertEqual(harness.core.openSubscriberCount, 3, "a busy pull ends no subscription")
        XCTAssertEqual(transport.lanes.inFlight(.stream), harness.limits.streamLaneCapacity)
    }

    /// The retained window and the held snapshot stay bounded under an event flood and a snapshot flood, and a Stop is admitted during both.
    /// The ingress holds its own bound, so a flood with no drain becomes one loss marker, and the window moves only by its ring bound.
    @RuntimeActor func testAnEventAndSnapshotFloodKeepsTheRetainedStateBoundedAndAStopAdmitted() async throws {
        let harness = try RuntimeServiceHarness()
        for _ in 0..<40 {
            harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
            harness.scheduling.drainAll()
        }
        XCTAssertEqual(harness.core.observedHighWater, 40)
        XCTAssertEqual(harness.core.observedFirstRetained, 40 - harness.limits.ringCapacity + 1, "the ring keeps its newest positions")

        for _ in 0..<20 {
            harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 2), kind: "proxy", event: "test.event"))
        }
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.observedHighWater, 40 + harness.limits.ingressCapacity + 1, "a flood beyond the ingress queue is one loss marker")

        for revision in 10..<50 {
            harness.owner.snapshotValue = try observationSnapshot(presentation: revision)
            harness.core.ownerDidChange()
        }
        XCTAssertEqual(harness.core.snapshotGeneration, 40, "each real change is one generation, and the held snapshot is one")
        XCTAssertLessThanOrEqual(harness.core.retainedSnapshotBytes, harness.limits.latestSnapshotByteCapacity)

        let stop = harness.core.submit(try RuntimeServiceFixtures.request(700, .stop(.dns)))
        guard case .accepted = stop else {
            return XCTFail("a Stop is admitted under the event and snapshot flood, got \(stop)")
        }
        print(
            "PRESSURE-STATE highWater=\(harness.core.observedHighWater) firstRetained=\(harness.core.observedFirstRetained)"
                + " snapshotGeneration=\(harness.core.snapshotGeneration) retainedSnapshotBytes=\(harness.core.retainedSnapshotBytes)"
                + " outcomes=\(harness.core.outcomeCount) aliasBytes=\(harness.core.aliasBytesTotal)"
                + " retainedByteBudget=\(harness.limits.retainedByteBudget)"
        )
    }
}
