// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// The framed client over the production in-memory transport, with a manual clock and a manual owner hop queue. Each test
/// states what the transport did, and the owner and the service record what they admitted.
@MainActor
final class RuntimeServiceTransportTests: XCTestCase {
    private let frameLimits = try! ControlFrameLimits(maxFrameBytes: 64 * 1024)

    private func thrownError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }

    private func makeClient(_ harness: RuntimeServiceHarness, _ transport: RuntimeInMemoryTransport) throws -> any RuntimeClient {
        let epoch = harness.timing.now
        return try makeFramedRuntimeClient(
            transport: transport,
            limits: frameLimits,
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
    }

    func testAnAdmittedCommandAnswersThroughTheFramedClient() async throws {
        let harness = try RuntimeServiceHarness()
        let client = try makeClient(harness, harness.transport())
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let admission = try await runCall(harness.scheduling) {
            try await client.submit(
                .stop(.dns),
                requestID: RuntimeServiceFixtures.requestID(1),
                expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
                deadline: deadline
            )
        }
        guard case .accepted = admission else { return XCTFail("expected an accepted admission, got \(admission)") }
        XCTAssertEqual(harness.owner.fenceLog.count, 1)
    }

    func testALostReplyIsRecoveredByLookupAndNeverResent() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let id = RuntimeServiceFixtures.requestID(2)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)

        transport.faults.loseNextReplies(1)
        let error = await thrownError {
            try await runCall(harness.scheduling) {
                try await client.submit(.stop(.proxy), requestID: id, expectedIncarnation: RuntimeServiceFixtures.incarnation(1), deadline: deadline)
            }
        }
        XCTAssertEqual(error, .admissionUnknown(id, .disconnected))
        XCTAssertEqual(harness.owner.fenceLog.count, 1, "the owner admitted the command once; the lost reply did not resend it")

        let recovered = try await runCall(harness.scheduling) {
            try await client.lookupAdmission(of: id, expectedIncarnation: RuntimeServiceFixtures.incarnation(1), deadline: deadline)
        }
        guard case .admission(.accepted) = recovered else {
            return XCTFail("the lookup recovers the recorded admission, got \(recovered)")
        }
        XCTAssertEqual(harness.owner.fenceLog.count, 1)
    }

    func testAnExpiredDeadlineIsRefusedBeforeTheOwnerClaimsIt() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let limits = frameLimits
        let frame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(3),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(0), call: .submit(ControlOperationRequest(
                    requestID: RuntimeServiceFixtures.requestID(3),
                    expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
                    command: .stop(.tunnels)
                ))))
            ),
            limits: limits
        )
        let expired = RuntimeDeadline(instant: harness.timing.now.advanced(by: .seconds(-1)))
        var failure: ControlRuntimeTransportFailure?
        do {
            _ = try await runCall(harness.scheduling) {
                try await transport.exchange(frame, limits: limits, deadline: expired)
            }
        } catch {
            failure = error as? ControlRuntimeTransportFailure
        }
        XCTAssertEqual(failure, .notSent(.deadlineExpired), "a claim after the deadline is not sent")
        XCTAssertTrue(harness.owner.fenceLog.isEmpty, "the owner never fenced the expired command")
    }

    func testASubscriberPastTheLimitIsRefusedOnTheWire() async throws {
        let harness = try RuntimeServiceHarness(subscribers: 1)
        let client = try makeClient(harness, harness.transport())
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)

        let first = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        let baseline = try await first.next(deadline)
        XCTAssertEqual(baseline.kind, .baseline)

        let second = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        let refused = await thrownError { try await second.next(deadline) }
        XCTAssertEqual(refused, .wire(.subscriberLimit))
        first.cancel()
        second.cancel()
        harness.scheduling.drainAll()
    }

    func testAPublishedEventWakesAParkedStreamWait() async throws {
        let harness = try RuntimeServiceHarness()
        let client = try makeClient(harness, harness.transport())
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)

        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        let baseline = try await subscription.next(deadline)
        XCTAssertEqual(baseline.kind, .baseline)

        let parked = Task { try await subscription.next(deadline) }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued, "the pull queued its owner round")
        harness.scheduling.drainAll()
        let registered = await awaitState { harness.core.parkedWaiterCount == 1 }
        XCTAssertTrue(registered, "the pull is parked before the event arrives")

        let event = ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event")
        harness.core.ingest(event)
        // The ingest queues the drain, the drain wakes the parked pull, and the rearmed pull delivers the frame. Each is a hop.
        harness.scheduling.drainAll()
        let delivered = try await parked.value
        XCTAssertEqual(delivered.kind, .events, "the published event reaches the parked wait")
        subscription.cancel()
        harness.scheduling.drainAll()
    }
}
