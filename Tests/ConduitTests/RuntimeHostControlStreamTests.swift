// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import ProxyControlBridge
import RuntimeEvents

/// The actual host's own events and its quit's end on the actual framed stream (decision 0014), through the host's one composition
/// (`RuntimeControlComposition`, which the production `makeInMemoryControlClient` builds and pm-sim drives) over a `FakeMachine` and a
/// scratch root. The actual-host tests ingest nothing: each event is one the host recorded on its own diagnostics log. The shutdown-wakeup
/// unit runs over the service core alone and ingests its own events. Every wait is bounded, so a missing feed or end fails, never hangs.
@MainActor
final class RuntimeHostControlStreamTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    private struct Composed {
        let host: RuntimeHost
        let composition: RuntimeControlComposition
        let control: any RuntimeClient
        let editor: PrivateEditorClient
    }

    /// One host and its composition, with the framed and editor clients the production factory hands out over the same transport.
    private func compose(subscribers: Int = 2) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(subscribers: subscribers), timing: .system,
            scheduling: TaskOwnerScheduling()
        )
        let control = try makeFramedRuntimeClient(
            transport: composition.transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return Composed(host: host, composition: composition, control: control, editor: PrivateEditorClient(transport: composition.transport))
    }

    /// Frames from a stream until `stop` holds, or until the stream ends or one wait passes `quiet` with no frame; each read is one plain
    /// `next`, back to back. Bounded in frames and in each wait; the result is the error that ended reading, nil when `stop` held.
    private func read(
        _ stream: RuntimeSubscription,
        of composed: Composed,
        into frames: inout [ControlRuntimeFrame],
        quiet: Duration = .seconds(5),
        until stop: ([ControlRuntimeFrame]) -> Bool
    ) async throws -> RuntimeClientError? {
        for _ in 0..<1_024 {
            if stop(frames) { return nil }
            do {
                frames.append(try await stream.next(.after(quiet, from: ContinuousClock.now)))
            } catch let error as RuntimeClientError {
                return error
            }
        }
        return stop(frames) ? nil : .unexpectedReply
    }

    private func typed(_ frames: [ControlRuntimeFrame]) -> [ControlTypedRuntimeEvent] {
        frames.flatMap { frame -> [ControlTypedRuntimeEvent] in
            guard case .events(let batch) = frame else { return [] }
            return batch.events.compactMap { record in
                guard case .known(let event) = record else { return nil }
                return event.typed
            }
        }
    }

    private func finished(_ frames: [ControlRuntimeFrame]) -> [ControlOperationFinished] {
        frames.compactMap { frame in
            guard case .operationFinished(let finished) = frame else { return nil }
            return finished
        }
    }

    private static func proxyStarted(_ event: ControlTypedRuntimeEvent) -> Bool {
        guard case .lifecycle(.moduleSettled(let settlement, _)) = event else { return false }
        return settlement == .explicit(.proxy, .started)
    }

    private static func reloadObserved(_ event: ControlTypedRuntimeEvent) -> Bool {
        guard case .configWorkflow(.observed(let phase, _)) = event else { return false }
        return phase == .reload
    }

    /// The events the host's file writer recorded, read back after a flush.
    private func written(_ host: RuntimeHost) async throws -> [RuntimeEvent] {
        await host.flushEvents()
        let text = try String(contentsOf: try XCTUnwrap(harness).environment.eventsFile, encoding: .utf8)
        let decoder = CanonicalJSON.decoder()
        return try text.split(separator: "\n").map { try decoder.decode(RuntimeEvent.self, from: Data($0.utf8)) }
    }

    /// A saved Start through the actual client and a reload of an external edit: each typed record the host emits through its owner and
    /// its workflow reaches the live stream, the Start's own settlement too, and the file writer still records each event exactly once.
    func testTheHostsTypedEventsReachTheActualStreamAndTheWriterRecordsEachOnce() async throws {
        let composed = try await compose()
        let host = composed.host
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }
        let snapshot = try await composed.control.readSnapshot(deadline: deadline())
        let proxy = try XCTUnwrap(snapshot.stamp.modules?.proxy)
        let admission = try await composed.control.submit(
            .start(.proxy, ifModuleRevision: proxy), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: host.incarnation, deadline: deadline()
        )
        guard case .accepted(let start) = admission else { return XCTFail("the saved Start is admitted: \(admission)") }

        var frames: [ControlRuntimeFrame] = []
        var ended = try await read(stream, of: composed, into: &frames) { frames in
            self.finished(frames).contains { $0.operationID == start } && self.typed(frames).contains(where: Self.proxyStarted)
        }
        XCTAssertNil(ended, "the stream stayed open")
        XCTAssertTrue(finished(frames).contains { $0.operationID == start }, "the Start's settlement reached the stream")
        XCTAssertTrue(typed(frames).contains(where: Self.proxyStarted), "the proxy member's typed settlement reached the stream")

        // The Start has settled, so a reload now is not a supersession of it.
        var edited = try ProxyConfigPersistence.load(in: try XCTUnwrap(harness).environment, allowMissing: false)
        edited.profileName = "Streamed reload"
        try ProxyConfigPersistence.save(edited, in: try XCTUnwrap(harness).environment)
        await host.reloadConfiguration()
        ended = try await read(stream, of: composed, into: &frames) { frames in self.typed(frames).contains(where: Self.reloadObserved) }
        XCTAssertNil(ended, "the stream stayed open")
        XCTAssertTrue(typed(frames).contains(where: Self.reloadObserved), "the reload's typed observation reached the stream")

        let recorded = host.orchestrator.eventLog.events.filter { if case .lifecycle(.moduleSettled)? = $0.typed { true } else { false } }
        let file = try await written(host).filter { if case .lifecycle(.moduleSettled)? = $0.typed { true } else { false } }
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertEqual(file.count, recorded.count, "every settlement the host recorded is written once, not once per destination")
    }

    /// An event too large for the stream's bound is an explicit loss: the live subscriber that reaches it ends with a resync, never a
    /// silent gap. The file writer still records it once.
    func testAnOversizedHostEventEndsTheStreamWithAResyncAndIsStillWrittenOnce() async throws {
        let composed = try await compose()
        let host = composed.host
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }

        // Over the fixture's 4096-byte event bound, in words the sanitizer leaves alone.
        let marker = "witness=oversized"
        host.orchestrator.eventLog.append(RuntimeEvent(
            kind: .config, event: "platform.settings_observed", detail: marker + String(repeating: " pad", count: 1_200)
        ))
        var frames: [ControlRuntimeFrame] = []
        let ended = try await read(stream, of: composed, into: &frames) { _ in false }
        XCTAssertEqual(ended, .streamClosed(.resyncRequired), "the loss reaches the subscriber as an explicit resync")

        let file = try await written(host).filter { $0.detail?.hasPrefix(marker) == true }
        XCTAssertEqual(file.count, 1, "the writer records the event the stream could not carry, once")
    }

    /// The bounded client Quit through the actual composition. A stream already waiting is woken by the end. It receives the Quit's own
    /// settlement first and then `hostShutdown`, and the settlement is still answered by lookup. A subscription opened after the
    /// physical end receives its baseline and the same end.
    func testTheQuitSettlesOnTheStreamBeforeHostShutdownAndALaterOpenGetsTheSameEnd() async throws {
        let composed = try await compose(subscribers: 3)
        let host = composed.host
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }
        // One pull parked before the Quit, so what the Quit publishes, or its end, must wake a wait that is already parked.
        let parkedPull = Task { @MainActor in try await stream.next(.after(.seconds(10), from: ContinuousClock.now)) }
        var parked = composed.composition.service.parkedWaiterCount == 1
        for _ in 0..<2_000 where !parked {
            try await Task.sleep(for: .milliseconds(1))
            parked = composed.composition.service.parkedWaiterCount == 1
        }
        XCTAssertTrue(parked, "the witness pull is parked before the Quit")

        let result = await RuntimeClientQuit.quit(
            control: composed.control, editor: composed.editor, incarnation: host.incarnation, total: .seconds(30)
        )
        guard case .settled(.completed(let completion)) = result.quit, completion.command == .quit else {
            return XCTFail("the Quit settles completed: \(result.quit)")
        }
        XCTAssertNil(result.observationFailure, "the routine read its settlements from its stream, back to back, with no busy refusal")

        var frames: [ControlRuntimeFrame] = []
        var ended: RuntimeClientError?
        do {
            frames.append(try await parkedPull.value)
        } catch let error as RuntimeClientError {
            ended = error
        }
        if ended == nil {
            ended = try await read(stream, of: composed, into: &frames, quiet: .seconds(10)) { _ in false }
        }
        XCTAssertEqual(ended, .streamClosed(.hostShutdown), "the stream ends with hostShutdown")
        let quits = finished(frames).filter {
            if case .completed(let completion) = $0.outcome { completion.command == .quit } else { false }
        }
        XCTAssertEqual(quits.count, 1, "the Quit's settlement reached the stream before its end")
        XCTAssertTrue(host.quitEnded, "the end followed the quit's physical work")
        if let quit = quits.first {
            let lookup = try await composed.control.outcome(of: quit.operationID, expectedIncarnation: host.incarnation, deadline: deadline())
            XCTAssertEqual(lookup, .finished(quit.outcome), "the settlement is still answered by lookup")
        }

        let later = try await composed.control.subscribe(.live, deadline: deadline())
        defer { later.cancel() }
        guard case .baseline = try await later.next(deadline()) else { return XCTFail("a later open still receives its baseline") }
        var laterFrames: [ControlRuntimeFrame] = []
        let laterEnd = try await read(later, of: composed, into: &laterFrames) { _ in false }
        XCTAssertEqual(laterEnd, .streamClosed(.hostShutdown), "a stream opened after the end ends the same way, at once")
    }

    /// The shutdown alone wakes a parked wait: no operation is pending and no snapshot changes, so nothing else could. An event published
    /// before the shutdown is read first; the end follows, and an event recorded after the shutdown is not queued. Over the service with
    /// its fake owner and manual hops, so every step is explicit.
    func testTheShutdownAloneWakesAParkedWaitAfterWhatWasPublished() throws {
        let harness = try RuntimeServiceHarness()
        guard case .opened(let subscriber, _) = harness.core.openSubscription(.live) else { return XCTFail("the subscription opens") }
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "config", event: "test.before"))
        harness.scheduling.drainAll()
        guard let published = try harness.core.peekFrame(subscriber, fits: { _ in true }), case .frame(.events) = published.pull else {
            return XCTFail("the event published before the shutdown is read first")
        }
        harness.core.commitCursor(subscriber, published.after)
        let woken = LockedSlot<Bool>()
        XCTAssertEqual(harness.core.parkWaiter(subscriber, token: RuntimeWaiterToken(), wake: { woken.set(true) }), .parked)
        XCTAssertEqual(harness.core.liveOperationCount, 0, "no operation is pending, so no settlement can wake the wait")
        XCTAssertEqual(harness.scheduling.pendingCount, 0, "no drain is pending, so no publication can wake it either")

        harness.core.hostDidShutDown()
        XCTAssertEqual(woken.value, true, "the shutdown woke the parked wait")
        XCTAssertEqual(try harness.core.peekFrame(subscriber, fits: { _ in true })?.pull, .end(.hostShutdown))
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "config", event: "test.after"))
        XCTAssertEqual(harness.scheduling.pendingCount, 0, "an event recorded after the shutdown is not queued")
        harness.core.removeSubscriber(subscriber)
    }

    /// A factory that refuses its client after composing (a zero wire budget cap) undoes every connection: no state or shutdown callback
    /// is left, the file writer records alone, once, and a later composition over the same host works.
    func testAFailedFactoryDetachesEveryConnectionAndALaterCompositionWorks() async throws {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        XCTAssertThrowsError(try host.makeInMemoryControlClient(
            limits: try RuntimeServiceFixtures.hostLimits(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .zero
        ))
        XCTAssertNil(host.onControlStateChange, "no state callback is left")
        XCTAssertNil(host.onControlShutdown, "no shutdown callback is left")
        host.orchestrator.eventLog.append(RuntimeEvent(kind: .config, event: "platform.settings_observed", detail: "witness=refused"))
        let refusedRecords = try await written(host).filter { $0.detail == "witness=refused" }
        XCTAssertEqual(refusedRecords.count, 1, "the writer records alone, once")

        let clients = try host.makeInMemoryControlClient(
            limits: try RuntimeServiceFixtures.hostLimits(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(30)
        )
        XCTAssertNotNil(host.onControlStateChange)
        XCTAssertNotNil(host.onControlShutdown)
        let stream = try await clients.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("the later composition's stream opens") }
    }

    /// A composition built after the quit's physical end has no later end to hear, so it starts shut down: its stream's baseline is
    /// followed at once by `hostShutdown`.
    func testACompositionBuiltAfterTheQuitEndedStartsShutDown() async throws {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        await host.shutdown()
        XCTAssertTrue(host.quitEnded)
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let control = try makeFramedRuntimeClient(
            transport: composition.transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        let stream = try await control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("the stream opens with its baseline") }
        do {
            let frame = try await stream.next(.after(.seconds(5), from: ContinuousClock.now))
            XCTFail("the stream ends at once, got \(frame)")
        } catch let error as RuntimeClientError {
            XCTAssertEqual(error, .streamClosed(.hostShutdown))
        }
    }

    /// The host holds its composition only weakly: the state, event and shutdown connections let the service go with the composition,
    /// and the file writer goes on recording every event once. None of them holds the host.
    func testADroppedCompositionIsReleasedAndTheWriterStillRecordsEachEventOnce() async throws {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        self.harness = harness
        let host = try await harness.makeHost()
        weak var released: RuntimeServiceCore?
        do {
            let composition = RuntimeControlComposition(
                host: host, limits: try RuntimeServiceFixtures.hostLimits(), timing: .system, scheduling: TaskOwnerScheduling()
            )
            released = composition.service
            host.orchestrator.eventLog.append(RuntimeEvent(kind: .config, event: "platform.settings_observed", detail: "witness=composed"))
        }
        var freed = released == nil
        for _ in 0..<2_000 where !freed {
            try await Task.sleep(for: .milliseconds(1))
            freed = released == nil
        }
        XCTAssertTrue(freed, "no host connection keeps the service")

        host.orchestrator.eventLog.append(RuntimeEvent(kind: .config, event: "platform.settings_observed", detail: "witness=released"))
        let file = try await written(host)
        XCTAssertEqual(file.filter { $0.detail == "witness=composed" }.count, 1)
        XCTAssertEqual(file.filter { $0.detail == "witness=released" }.count, 1, "the writer still records alone once the service is gone")
    }
}
