// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// Each task's own completion, recorded inside the task. Teardown reads it to know whether awaiting the task is safe.
@MainActor
private final class Completion {
    var finished = false
    var pullOutcome: Result<Data, any Error>?
}

/// One spawned call or pull: its task, and the completion the task records as it ends.
private struct Pending {
    let task: Task<Void, Never>
    let completion: Completion
}

/// One parked subscription: its stream, and the pull that waits on it.
private struct ParkedStream {
    let stream: ControlRuntimeStream
    let pending: Pending
}

/// Capacity, Stop and status pressure under the candidate lanes, through the production transport and the manual owner hops. Every bound comes
/// from `RuntimeServiceProfileCandidate.limits()`. Each reply is decoded, and each outcome is counted in exactly one category: an admitted or
/// status reply of the expected kind, a host failure with its code (a wire failure or a rejected admission), a typed lane refusal, or an
/// unexpected outcome kept with its description. Every launched call and every parked pull is retained. Teardown cancels what has not ended,
/// pumps the owner in a bounded wait, and awaits only the tasks that have recorded their end. The counts are the evidence, and no timeout,
/// latency or memory figure is asserted.
@MainActor
final class RuntimeServiceProfilePressureTests: XCTestCase {
    /// How the calls of one kind resolved. Each call lands in exactly one count.
    private final class Tally: @unchecked Sendable {
        /// An admission that was accepted or joined, or a snapshot read, decoded to the expected kind.
        var answered = 0
        /// A host failure: a decoded `.response(.failure(code))`, or a rejected admission. Each records its code.
        var hostFailures = 0
        var hostCodes: [String] = []
        /// `ControlRuntimeTransportFailure.notSent(.transportBusy)`: the lane had no free slot, so nothing was sent.
        var laneBusy = 0
        /// Any other outcome, kept with its description so a failure is visible in the log.
        var unexpected: [String] = []

        var resolved: Int {
            answered + hostFailures + laneBusy + unexpected.count
        }
    }

    /// The reply kind each call is expected to decode to. An admitted Stop is `accepted` or `joined`; a rejection is a host failure, never this.
    private enum ExpectedReply: CustomStringConvertible {
        case admitted
        case snapshot

        var description: String {
            switch self {
            case .admitted: "admission"
            case .snapshot: "snapshot"
            }
        }
    }

    /// One measured row. Each count is what the transport did with the calls of one kind.
    private struct Row {
        let label: String
        let ordinaryAttempted: Int
        let ordinaryAnswered: Int
        let ordinaryBusy: Int
        let streamHeld: Int
        let stopModules: Int
        let stopAnswered: Int
        let statusAttempted: Int
        let statusAnswered: Int
        let statusBusy: Int
        let hostFailures: Int
        let unexpected: Int

        var line: String {
            "RUNTIME-SERVICE-PROFILE pressure \(label): streams held=\(streamHeld)"
                + " | ordinary attempted=\(ordinaryAttempted) answered=\(ordinaryAnswered) laneBusy=\(ordinaryBusy)"
                + " | stop modules answered=\(stopAnswered)/\(stopModules)"
                + " | status attempted=\(statusAttempted) answered=\(statusAnswered) laneBusy=\(statusBusy)"
                + " | hostFailures=\(hostFailures) unexpected=\(unexpected)"
        }
    }

    /// The candidate's request cap encodes every call.
    private func encoded(_ id: Int, _ call: ControlRuntimeCall, requestCap: Int) throws -> Data {
        try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(id),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(1_000), call: call))
            ),
            limits: try RuntimeServiceProfileCandidate.frameLimits(requestCap)
        )
    }

    /// Classifies one decoded response into exactly one tally count.
    private func record(_ response: ControlRuntimeResponse, expecting: ExpectedReply, tally: Tally) {
        switch (expecting, response) {
        case (.admitted, .admission(.accepted)), (.admitted, .admission(.joined)):
            tally.answered += 1
        case (.snapshot, .snapshot):
            tally.answered += 1
        case (_, .admission(.rejected(let code))):
            tally.hostFailures += 1
            tally.hostCodes.append("rejected:\(code)")
        case (_, .failure(let code)):
            tally.hostFailures += 1
            tally.hostCodes.append("failure:\(code)")
        default:
            tally.unexpected.append("reply \(response.kind) for an expected \(expecting)")
        }
    }

    /// One caller call through the production transport. Its reply is decoded under the reply cap and classified. Its typed lane refusal is
    /// counted apart. The completion is recorded at the end of the task, so teardown knows when awaiting it is safe.
    private func launch(
        _ transport: RuntimeInMemoryTransport,
        _ request: Data,
        expecting: ExpectedReply,
        replyLimits: ControlFrameLimits,
        deadline: RuntimeDeadline,
        tally: Tally
    ) -> Pending {
        let completion = Completion()
        let task = Task {
            defer { completion.finished = true }
            do {
                let reply = try await transport.exchange(request, limits: replyLimits, deadline: deadline)
                let message = try ControlRuntimeCodec.decodeFullFrame(reply, limits: replyLimits)
                guard case .response(let response) = message.body else {
                    tally.unexpected.append("the reply body is not a response")
                    return
                }
                record(response, expecting: expecting, tally: tally)
            } catch ControlRuntimeTransportFailure.notSent(.transportBusy) {
                tally.laneBusy += 1
            } catch {
                tally.unexpected.append("\(error)")
            }
        }
        return Pending(task: task, completion: completion)
    }

    /// Waits until the owner queue holds exactly one first round per admitted call, then returns whether it did. A call reserves its lane and
    /// queues that round in one synchronous step, but in its own task, and those tasks run in parallel with the calls refused. A refusal count
    /// or a lane count can therefore be reached while an admitted call has reserved and not yet queued its round. A drain made then misses the
    /// round, and the call stays unanswered until teardown cancels it as `notSent(cancelled)`: the status reads seen on 2026-10-27. The
    /// failure message names the queue as it was, so a recurrence shows which stage was short.
    private func awaitQueuedRounds(_ harness: RuntimeServiceHarness, _ rounds: Int, _ stage: String) async {
        let queued = await awaitState { harness.scheduling.pendingCount == rounds }
        XCTAssertTrue(queued, "\(stage): \(harness.scheduling.pendingCount) owner rounds queued, expected one per admitted call (\(rounds))")
    }

    /// Opens one live subscription through the production transport and consumes its buffered baseline.
    private func openStream(
        _ harness: RuntimeServiceHarness,
        _ transport: RuntimeInMemoryTransport,
        id: Int
    ) async throws -> ControlRuntimeStream {
        let limits = harness.limits
        let frame = try encoded(id, .subscribe(.live), requestCap: limits.maxRequestBytes)
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let replyLimits = try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
        let stream = try await runCall(harness.scheduling) {
            try await transport.openStream(frame, limits: replyLimits, deadline: deadline)
        }
        _ = try await stream.next(deadline)
        return stream
    }

    /// One pull on a subscription. Its outcome is written to the completion before the task ends.
    private func startPull(_ stream: ControlRuntimeStream, _ deadline: RuntimeDeadline) -> Pending {
        let completion = Completion()
        let task = Task {
            defer { completion.finished = true }
            do {
                completion.pullOutcome = .success(try await stream.next(deadline))
            } catch {
                completion.pullOutcome = .failure(error)
            }
        }
        return Pending(task: task, completion: completion)
    }

    /// Parks one pull on each of `count` subscriptions. Each parked pull holds one stream-lane reservation, as a live stream does.
    private func parkStreamPulls(
        _ harness: RuntimeServiceHarness,
        _ transport: RuntimeInMemoryTransport,
        count: Int
    ) async throws -> [ParkedStream] {
        // Two phases. Every stream opens first, with no pull outstanding, so no open's owner turn waits behind an earlier pull.
        var streams: [ControlRuntimeStream] = []
        for n in 0..<count {
            streams.append(try await openStream(harness, transport, id: 600 + n))
        }
        // Only after every open does one pull per stream start, so the owner queue then holds exactly these pulls.
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let parked = streams.map { ParkedStream(stream: $0, pending: startPull($0, deadline)) }
        let queued = await awaitState { harness.scheduling.pendingCount == count }
        XCTAssertTrue(queued, "each stream queued one pull")
        harness.scheduling.drainAll()
        let held = await awaitState { transport.lanes.inFlight(.stream) == count }
        XCTAssertTrue(held, "each parked pull holds one stream-lane reservation")
        return parked
    }

    /// Ends every parked pull and every launched call, then checks that nothing is still owned. An unfinished task is cancelled first, so a
    /// cancelled wait ends as its typed cancellation. Each stream's registration is then released, and the owner is pumped inside a bounded
    /// `awaitState` until every task has recorded its end. Only the ended tasks are awaited, since awaiting an unfinished one would block the
    /// manual scheduler. Lanes, subscribers and owner effects must then reach zero.
    private func teardown(
        _ harness: RuntimeServiceHarness,
        _ transport: RuntimeInMemoryTransport,
        parked: [ParkedStream],
        launches: [Pending]
    ) async {
        for entry in parked where !entry.pending.completion.finished {
            entry.pending.task.cancel()
        }
        for pending in launches where !pending.completion.finished {
            pending.task.cancel()
        }
        for entry in parked {
            entry.stream.cancel()
        }
        let ended = await awaitState {
            harness.scheduling.drainAll()
            return parked.allSatisfy { $0.pending.completion.finished } && launches.allSatisfy { $0.completion.finished }
        }
        XCTAssertTrue(ended, "every parked pull and launched call records its end after cancellation and pumping")

        for operation in harness.owner.startedOperations {
            harness.owner.quiesce(operation)
        }
        let released = await awaitState {
            harness.scheduling.drainAll()
            return transport.lanes.inFlight(.ordinary) == 0
                && transport.lanes.inFlight(.read) == 0
                && transport.lanes.inFlight(.stream) == 0
                && ControlModule.allCases.allSatisfy { transport.lanes.inFlight(.stop($0)) == 0 }
                && harness.core.openSubscriberCount == 0
                && harness.owner.liveEffectCount == 0
        }
        XCTAssertTrue(released, "every lane, subscriber and owner effect is released at teardown")
        XCTAssertEqual(transport.lanes.inFlight(.ordinary), 0, "no ordinary reservation survives teardown")
        XCTAssertEqual(transport.lanes.inFlight(.read), 0, "no read reservation survives teardown")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 0, "no stream reservation survives teardown")
        for module in ControlModule.allCases {
            XCTAssertEqual(transport.lanes.inFlight(.stop(module)), 0, "no \(module) stop reservation survives teardown")
        }
        XCTAssertEqual(harness.core.openSubscriberCount, 0, "no subscriber survives teardown")
        XCTAssertEqual(harness.owner.liveEffectCount, 0, "no owner effect survives teardown")

        for entry in parked {
            guard entry.pending.completion.finished else {
                XCTFail("a parked pull did not end, so it is not awaited")
                continue
            }
            await entry.pending.task.value
            switch entry.pending.completion.pullOutcome {
            case .some(.success):
                XCTFail("a cancelled parked pull delivered a frame")
            case .some(.failure(let error)):
                let end = error as? RuntimeWaitEnd
                XCTAssertTrue(end == .cancelled || error is CancellationError, "a cancelled parked pull ends as its typed cancellation, got \(error)")
            case .none:
                XCTFail("a parked pull ended without recording its outcome")
            }
        }
        for pending in launches {
            guard pending.completion.finished else {
                XCTFail("a launched call did not end, so it is not awaited")
                continue
            }
            await pending.task.value
        }
    }

    /// Measures one row under the candidate lanes: the stream lane is empty or full of parked pulls, then an ordinary flood, one Stop per module
    /// and status reads, all through the production transport. Each stage waits for the observable state it expects, with a bounded wait.
    private func measure(_ label: String, streamPressure: Bool) async throws -> Row {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let harness = try RuntimeServiceHarness(limits: limits)
        let transport = harness.transport()
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let replyLimits = try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
        let streamsHeld = streamPressure ? limits.streamLaneCapacity : 0
        let parked = try await parkStreamPulls(harness, transport, count: streamsHeld)
        var launches: [Pending] = []

        let ordinaryAttempts = limits.ordinaryLaneCapacity + 4
        let ordinary = Tally()
        for n in 0..<ordinaryAttempts {
            let call = ControlRuntimeCall.submit(try RuntimeServiceFixtures.request(300 + n, .testDNS))
            let request = try encoded(300 + n, call, requestCap: limits.maxRequestBytes)
            launches.append(launch(transport, request, expecting: .admitted, replyLimits: replyLimits, deadline: deadline, tally: ordinary))
        }
        let ordinaryRefused = await awaitState { ordinary.laneBusy == ordinaryAttempts - limits.ordinaryLaneCapacity }
        XCTAssertTrue(ordinaryRefused, "the ordinary lane admits its own capacity")

        let modules = ControlModule.allCases
        let stops = Tally()
        for (index, module) in modules.enumerated() {
            let call = ControlRuntimeCall.submit(try RuntimeServiceFixtures.request(400 + index, .stop(module)))
            let request = try encoded(400 + index, call, requestCap: limits.maxRequestBytes)
            launches.append(launch(transport, request, expecting: .admitted, replyLimits: replyLimits, deadline: deadline, tally: stops))
        }
        let stopsReserved = await awaitState { modules.allSatisfy { transport.lanes.inFlight(.stop($0)) == 1 } }
        XCTAssertTrue(stopsReserved, "every module's Stop reserves its own lane under the ordinary flood")

        let statusAttempts = limits.readLaneCapacity + 4
        let status = Tally()
        for n in 0..<statusAttempts {
            let request = try encoded(500 + n, .readSnapshot, requestCap: limits.maxRequestBytes)
            launches.append(launch(transport, request, expecting: .snapshot, replyLimits: replyLimits, deadline: deadline, tally: status))
        }
        let statusRefused = await awaitState { status.laneBusy == statusAttempts - limits.readLaneCapacity }
        XCTAssertTrue(statusRefused, "the read lane admits only its own free slots, whatever the stream lane holds")

        await awaitQueuedRounds(harness, limits.ordinaryLaneCapacity + modules.count + limits.readLaneCapacity, label)
        harness.scheduling.drainAll()
        let resolved = await awaitState {
            ordinary.resolved == ordinaryAttempts && stops.resolved == modules.count && status.resolved == statusAttempts
        }
        XCTAssertTrue(resolved, "every call resolves once the owner drains")
        await teardown(harness, transport, parked: parked, launches: launches)

        XCTAssertEqual(ordinary.unexpected, [], "every ordinary reply decodes to an expected outcome")
        XCTAssertEqual(stops.unexpected, [], "every Stop reply decodes to an expected outcome")
        XCTAssertEqual(status.unexpected, [], "every status reply decodes to the expected kind")
        let unexpected = ordinary.unexpected.count + stops.unexpected.count + status.unexpected.count
        let row = Row(
            label: label,
            ordinaryAttempted: ordinaryAttempts,
            ordinaryAnswered: ordinary.answered,
            ordinaryBusy: ordinary.laneBusy,
            streamHeld: streamsHeld,
            stopModules: modules.count,
            stopAnswered: stops.answered,
            statusAttempted: statusAttempts,
            statusAnswered: status.answered,
            statusBusy: status.laneBusy,
            hostFailures: ordinary.hostFailures + stops.hostFailures + status.hostFailures,
            unexpected: unexpected
        )
        XCTAssertEqual(row.stopAnswered, modules.count, "a Stop for each module is admitted despite the flood and the stream pressure")
        XCTAssertEqual(row.ordinaryAnswered, limits.ordinaryLaneCapacity, "the ordinary lane admits exactly its capacity")
        XCTAssertEqual(row.statusAnswered, limits.readLaneCapacity, "a read is answered from the read lane's own free slots")
        print(row.line)
        return row
    }

    /// Under the candidate lanes, Stop and status answers are the same with an ordinary flood alone and with the stream lane full of parked pulls.
    func testCandidateStopAndStatusAnswersAreTheSameWithAFullStreamLane() async throws {
        let flood = try await measure("candidate-ordinary-flood", streamPressure: false)
        let streams = try await measure("candidate-ordinary-flood+stream-lane-full", streamPressure: true)
        XCTAssertEqual(flood.stopAnswered, streams.stopAnswered, "Stop is independent of stream pressure")
        XCTAssertEqual(flood.statusAnswered, streams.statusAnswered, "status is independent of stream pressure")
    }

    /// The candidate's stream lane equals its subscriber limit, so the lane is full exactly when the table is full. Through the public framed client,
    /// a ninth subscription opens as a stream whose first frame is the host's typed refusal. The refusal is
    /// `RuntimeClientError.wire(.subscriberLimit)` at the first pull, and it changes nothing. The parked pulls are then torn down.
    func testCandidateNinthSubscriptionIsRefusedAsTheTypedSubscriberLimitAtItsFirstPull() async throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let harness = try RuntimeServiceHarness(limits: limits)
        let transport = harness.transport()
        let parked = try await parkStreamPulls(harness, transport, count: limits.streamLaneCapacity)
        XCTAssertEqual(harness.core.openSubscriberCount, limits.subscriberLimit)

        let clock = harness.timing
        let client = try makeFramedRuntimeClient(
            transport: transport,
            limits: try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes),
            wireBudgetCap: .seconds(60),
            now: { clock.now }
        )
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        // The open is answered by the transport. The host's refusal is the stream's first frame, so it surfaces at the first pull.
        let subscription = try await runCall(harness.scheduling) {
            try await client.subscribe(.live, deadline: deadline)
        }
        do {
            _ = try await subscription.next(deadline)
            XCTFail("the ninth subscription must be refused at its first pull")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .wire(.subscriberLimit), "the refusal is the typed subscriber-limit failure")
        } catch {
            XCTFail("the refusal must be a RuntimeClientError, got \(error)")
        }
        XCTAssertEqual(harness.core.openSubscriberCount, limits.subscriberLimit, "a refused subscription changes nothing")
        XCTAssertEqual(transport.lanes.inFlight(.stream), limits.streamLaneCapacity)

        subscription.cancel()
        await teardown(harness, transport, parked: parked, launches: [])
    }

    /// Each module's Stop lane holds the candidate's reservations. A Stop beyond them is refused as a typed lane-busy, with nothing sent, and the
    /// other modules' Stops are still admitted while that module's lane is held.
    func testCandidateStopLanePerModuleHoldsItsReservationsWhileOtherModulesStayAdmitted() async throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let harness = try RuntimeServiceHarness(limits: limits)
        let transport = harness.transport()
        let deadline = RuntimeDeadline.after(.seconds(60), from: harness.timing.now)
        let replyLimits = try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
        let stopLane = limits.stopLaneCapacityPerModule
        let attempts = stopLane + 1
        var launches: [Pending] = []

        let dns = Tally()
        for n in 0..<attempts {
            let call = ControlRuntimeCall.submit(try RuntimeServiceFixtures.request(900 + n, .stop(.dns)))
            let request = try encoded(900 + n, call, requestCap: limits.maxRequestBytes)
            launches.append(launch(transport, request, expecting: .admitted, replyLimits: replyLimits, deadline: deadline, tally: dns))
        }
        // The excess attempt must reach the full lane and be refused before anything drains, or it could find a released reservation.
        let reserved = await awaitState {
            transport.lanes.inFlight(.stop(.dns)) == stopLane && dns.laneBusy == attempts - stopLane
        }
        XCTAssertTrue(reserved, "the dns Stop lane holds exactly its own reservations, and refuses the one beyond them")

        let others = Tally()
        for (index, module) in [ControlModule.proxy, .tunnels].enumerated() {
            let call = ControlRuntimeCall.submit(try RuntimeServiceFixtures.request(950 + index, .stop(module)))
            let request = try encoded(950 + index, call, requestCap: limits.maxRequestBytes)
            launches.append(launch(transport, request, expecting: .admitted, replyLimits: replyLimits, deadline: deadline, tally: others))
        }
        let othersReserved = await awaitState {
            transport.lanes.inFlight(.stop(.proxy)) == 1 && transport.lanes.inFlight(.stop(.tunnels)) == 1
        }
        XCTAssertTrue(othersReserved, "the other modules' Stops are admitted while dns holds its lane")

        await awaitQueuedRounds(harness, stopLane + 2, "stop-lane")
        harness.scheduling.drainAll()
        let resolved = await awaitState {
            dns.resolved == attempts && others.resolved == 2
        }
        XCTAssertTrue(resolved, "every Stop resolves once the owner drains")
        await teardown(harness, transport, parked: [], launches: launches)

        XCTAssertEqual(dns.answered, stopLane, "the dns Stops within its lane are admitted")
        XCTAssertEqual(dns.laneBusy, attempts - stopLane, "the dns Stop beyond its lane is refused as a typed lane-busy")
        XCTAssertEqual(dns.hostFailures, 0, "no dns Stop is rejected by the host")
        XCTAssertEqual(dns.unexpected, [], "no dns Stop has an unexpected outcome")
        XCTAssertEqual(others.answered, 2, "the other modules' Stops are admitted")
        XCTAssertEqual(others.unexpected, [], "no other module's Stop has an unexpected outcome")
        print(
            "RUNTIME-SERVICE-PROFILE stop-lane dns attempts=\(attempts) stopLanePerModule=\(stopLane)"
                + " admitted=\(dns.answered) laneBusy=\(dns.laneBusy) hostFailures=\(dns.hostFailures)"
                + " otherModulesAdmitted=\(others.answered)"
        )
    }

    /// The event ring and the ingress hold the candidate's bounds. A flood beyond the ingress queue is one loss marker, and the held snapshot stays
    /// one generation at a time within its byte bound. A Stop is admitted during the flood. The flood sizes are derived from the candidate's ring
    /// and ingress, so no count is a free literal.
    func testCandidateEventAndSnapshotFloodKeepsTheWindowBoundedAndAdmitsAStop() throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let harness = try RuntimeServiceHarness(limits: limits)
        // Positions past the ring, so the window must slide. The overflow is a fixture choice of 88 positions.
        let drained = limits.ringCapacity + 88
        for _ in 0..<drained {
            harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
            harness.scheduling.drainAll()
        }
        XCTAssertEqual(harness.core.observedHighWater, drained)
        XCTAssertEqual(harness.core.observedFirstRetained, drained - limits.ringCapacity + 1, "the ring keeps its newest positions")

        // An undrained flood beyond the ingress queue.
        let undrained = limits.ingressCapacity + 36
        for _ in 0..<undrained {
            harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 2), kind: "proxy", event: "test.event"))
        }
        harness.scheduling.drainAll()
        XCTAssertEqual(
            harness.core.observedHighWater,
            drained + limits.ingressCapacity + 1,
            "a flood beyond the ingress queue is one loss marker"
        )

        let changes = 40
        for revision in 0..<changes {
            harness.owner.snapshotValue = try observationSnapshot(presentation: 10 + revision)
            harness.core.ownerDidChange()
        }
        XCTAssertEqual(harness.core.snapshotGeneration, changes, "each real change is one generation")
        XCTAssertLessThanOrEqual(harness.core.retainedSnapshotBytes, limits.latestSnapshotByteCapacity)

        let stop = harness.core.submit(try RuntimeServiceFixtures.request(700, .stop(.dns)))
        guard case .accepted = stop else {
            return XCTFail("a Stop is admitted under the candidate event and snapshot flood, got \(stop)")
        }
        print(
            "RUNTIME-SERVICE-PROFILE pressure-state highWater=\(harness.core.observedHighWater)"
                + " firstRetained=\(harness.core.observedFirstRetained) snapshotGeneration=\(harness.core.snapshotGeneration)"
                + " retainedSnapshotBytes=\(harness.core.retainedSnapshotBytes) latestSnapshotByteCapacity=\(limits.latestSnapshotByteCapacity)"
                + " outcomes=\(harness.core.outcomeCount) aliasBytes=\(harness.core.aliasBytesTotal)"
                + " retainedByteBudget=\(limits.retainedByteBudget)"
        )
    }
}
