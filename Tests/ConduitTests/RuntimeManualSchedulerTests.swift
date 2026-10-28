// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// The manual owner-hop driver the runtime-service suites read pages through. The capture flight's commit hop is queued off the owner,
/// by the detached projection job, so it can arrive after the driver has run everything queued. These tests hold that job so its hop
/// comes only then.
final class RuntimeManualSchedulerTests: XCTestCase {
    /// Holds the capture job where it suspends, on no thread, until opened, and lets the test wait, on no thread, until it is held.
    private final class HeldJob: Sendable {
        private let entered: AsyncStream<Void>
        private let enter: AsyncStream<Void>.Continuation
        private let opened: AsyncStream<Void>
        private let opening: AsyncStream<Void>.Continuation

        /// Each stream is a one-shot signal, so it buffers at most one element.
        init() {
            (entered, enter) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            (opened, opening) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        }

        func pass() async {
            enter.yield()
            for await _ in opened {}
        }

        func untilHeld() async {
            var arrivals = entered.makeAsyncIterator()
            _ = await arrivals.next()
        }

        func open() {
            opening.finish()
        }
    }

    @RuntimeActor private func pageRead(_ harness: RuntimeServiceHarness, hosts: [String], held: HeldJob) throws -> @Sendable () async throws -> ControlPageReply {
        harness.owner.dnsHostnames = hosts
        harness.owner.snapshotValue = try RuntimeServiceFixtures.snapshot(
            incarnation: 1,
            collections: ControlCollectionRevisions(tunnelDNSHosts: try XCTUnwrap(ControlCollectionRevision(rawValue: 1))),
            dnsStatus: .active(hostnames: hosts)
        )
        harness.owner.projectionGate = { _ in await held.pass() }
        let epoch = harness.timing.now
        let client = try makeFramedRuntimeClient(
            transport: harness.transport(),
            limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
        let deadline = RuntimeDeadline.after(.seconds(5), from: epoch)
        let request = ControlPageRequest(expectedIncarnation: RuntimeServiceFixtures.incarnation(1), collection: .tunnelDNSHosts, cursor: nil)
        return { try await client.readPage(request, deadline: deadline) }
    }

    /// The commit hop comes only after the driver has run everything queued, and the page is still answered by the driver alone. A driver
    /// that stopped there left the hop to no one, and the page waited for good on a clock that never moves by itself.
    @RuntimeActor func testACommitHopQueuedAfterTheDriverWentIdleIsStillRun() async throws {
        let harness = try RuntimeServiceHarness()
        let held = HeldJob()
        let read = try pageRead(harness, hosts: ["a.example", "b.example"], held: held)
        let page = Task { try await runDrainingCall(harness.scheduling, read) }
        await held.untilHeld()
        XCTAssertEqual(harness.scheduling.pendingCount, 0, "the job is held, so its commit hop is not queued")
        XCTAssertEqual(harness.core.captureFlightWaitCount, 1, "the page waits on the flight")
        guard harness.scheduling.hasWaitingDriver else {
            held.open()
            return XCTFail("with nothing queued and the page pending, the driver waits for the next hop")
        }
        let before = harness.scheduling.queuedHopCount
        held.open()
        guard case .tunnelDNSHosts(let reply) = try await page.value else { return XCTFail("the page was answered with rows") }
        XCTAssertEqual(reply.status, .current)
        XCTAssertEqual(reply.rows.count, 2, "the capture is whole")
        XCTAssertGreaterThan(harness.scheduling.queuedHopCount, before, "the commit hop came after the driver went idle")
        XCTAssertEqual(harness.scheduling.pendingCount, 0, "every hop the page needed was run by its driver")
    }

    /// A driver cancelled while its page waits on a held flight cancels the call, and the call ends as the client's cancellation without
    /// any hop being run for it by the test.
    @RuntimeActor func testACancelledDriverEndsItsWaitingCallAsCancelled() async throws {
        let harness = try RuntimeServiceHarness()
        let held = HeldJob()
        let read = try pageRead(harness, hosts: ["a.example", "b.example"], held: held)
        let page = Task { try await runDrainingCall(harness.scheduling, read) }
        await held.untilHeld()
        guard harness.scheduling.hasWaitingDriver else {
            held.open()
            return XCTFail("with nothing queued and the page pending, the driver waits for the next hop")
        }
        // No suspension between the cancel and the open: the cancellation resolves the wait first, and a call the cancel did not reach
        // is answered by the commit hop instead, so it fails the test rather than hanging it.
        page.cancel()
        held.open()
        let result = await page.result
        guard case .failure(let error) = result else { return XCTFail("a cancelled page is not answered") }
        XCTAssertEqual(error as? RuntimeClientError, .notSent(.cancelled), "the parked page ends unsent, with the caller's cancellation")
    }
}
