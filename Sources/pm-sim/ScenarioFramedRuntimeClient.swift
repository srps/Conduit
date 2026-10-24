// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel

/// `framed-runtime-client` (decision 0014): the framed client over an in-memory host that answers
/// through the same v2 codec. A lost reply after admission is one send and no replay, and a lookup
/// recovers the recorded admission. A host failure with the request's correlation is a wire answer.
/// An oversize request is refused locally and never reaches the host. A stream's first frame is its
/// baseline, and its end is typed and releases the stream once. The host is simulated, with no
/// socket, no machine, no network and no helper effects.
enum FramedRuntimeClientScenario {
    static func run() async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }

        let incarnation = ControlHostIncarnation(rawValue: frameSimUUID(1))
        let host = FramedSimHost(incarnation: incarnation)
        let epoch = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.seconds(5), from: epoch)
        let client = try makeFramedRuntimeClient(
            transport: host,
            limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(60),
            now: { epoch }
        )
        let requestID = ControlRequestID(rawValue: frameSimUUID(2))

        // A reply lost after the host admitted the command: one send, admission unknown, no replay.
        host.losesNextReply()
        let lost = await simulatedError {
            try await client.submit(.stop(.dns), requestID: requestID, expectedIncarnation: incarnation, deadline: deadline)
        }
        check("a lost reply after a send is admission unknown for that request",
              lost == .admissionUnknown(requestID, .disconnected))
        check("the lost submit reached the host once, with no replay", host.requestsReceived == 1)

        // The lookup recovers what the host recorded, and only in the incarnation it was admitted in.
        let recovered = try await client.lookupAdmission(of: requestID, expectedIncarnation: incarnation, deadline: deadline)
        check("a lookup recovers the admission the host recorded", recovered == .admission(.accepted(host.operation)))
        let otherIncarnation = ControlHostIncarnation(rawValue: frameSimUUID(9))
        let stale = try await client.lookupAdmission(of: requestID, expectedIncarnation: otherIncarnation, deadline: deadline)
        check("a lookup from another incarnation is changedIncarnation", stale == .unknown(.changedIncarnation))

        // A host failure with the request's correlation is the host's answer, not an unknown.
        host.refuse(with: .invalidValue)
        let refused = await simulatedError {
            try await client.submit(.stop(.proxy), requestID: ControlRequestID(rawValue: frameSimUUID(3)),
                                    expectedIncarnation: incarnation, deadline: deadline)
        }
        check("a host failure with the request's correlation is a wire answer", refused == .wire(.invalidValue))
        host.refuse(with: nil)

        // An oversize request is refused locally, so the host sees no new request.
        let small = try makeFramedRuntimeClient(
            transport: host,
            limits: try ControlFrameLimits(maxFrameBytes: 64),
            wireBudgetCap: .seconds(60),
            now: { epoch }
        )
        let receivedBefore = host.requestsReceived
        let local = await simulatedError {
            try await small.submit(.stop(.dns), requestID: ControlRequestID(rawValue: frameSimUUID(4)),
                                   expectedIncarnation: incarnation, deadline: deadline)
        }
        check("an oversize request is refused locally", local == .localRefusal(.frameTooLarge))
        check("the refused request never reached the host", host.requestsReceived == receivedBefore)

        // A stream opens with its baseline, and its typed end releases it exactly once.
        let subscription = try await client.subscribe(.live, deadline: deadline)
        let first = try await subscription.next(deadline)
        check("the first stream frame is the baseline", first.kind == .baseline)
        let closing = await simulatedError { try await subscription.next(deadline) }
        check("a typed end closes the stream with its reason", closing == .streamClosed(.hostShutdown))
        subscription.cancel()
        check("the stream is released exactly once", host.streamCancelCount == 1)

        notes.append("transport=simulated in-memory host over the v2 codec")
        notes.append("no socket, machine, network or helper effects")
        return ScenarioResult(
            name: "framed-runtime-client", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions.isEmpty ? [.init("scenario produced assertions", false)] : assertions,
            notes: notes
        )
    }

    private static func simulatedError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }
}

private func frameSimUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
}

/// The baseline a live stream opens with, projected from an empty kernel snapshot.
private func simulatedBaseline(_ incarnation: ControlHostIncarnation) throws -> ControlBaseline {
    let snapshot = try RuntimeSnapshotControlProjection.snapshot(
        ProxyOrchestratorSnapshot(),
        stamp: ControlRuntimeStamp(
            incarnation: incarnation,
            presentationRevision: ControlPresentationRevision(rawValue: 9)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        ),
        profileName: "Corp",
        collectionRevisions: ControlCollectionRevisions()
    )
    return try ControlBaseline(
        incarnation: incarnation,
        snapshot: snapshot,
        highWater: ControlEventCursor(rawValue: 0)!,
        replay: .live
    )
}

/// An in-memory host that answers through the v2 codec. It admits what it receives, can lose one reply
/// after admitting it, refuses with a configured code, and answers a lookup from what it recorded.
/// Its stream is a baseline followed by a typed end, and it counts releases of that stream.
private final class FramedSimHost: ControlRuntimeTransport, @unchecked Sendable {
    let incarnation: ControlHostIncarnation
    let operation = ControlOperationID(rawValue: frameSimUUID(7))
    private let lock = NSLock()
    private var received = 0
    private var admitted: ControlRequestID?
    private var losesNext = false
    private var refusal: ControlRuntimeErrorCode?
    private var streamQueue: [Data] = []
    private var streamReleases = 0

    init(incarnation: ControlHostIncarnation) {
        self.incarnation = incarnation
    }

    var requestsReceived: Int { lock.withLock { received } }
    var streamCancelCount: Int { lock.withLock { streamReleases } }

    func losesNextReply() {
        lock.withLock { losesNext = true }
    }

    func refuse(with code: ControlRuntimeErrorCode?) {
        lock.withLock { refusal = code }
    }

    func exchange(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> Data {
        let message = try ControlRuntimeCodec.decodeFullFrame(request, limits: limits)
        let (response, lost) = answer(to: message.body)
        let reply = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(correlation: message.correlation, body: .response(response)),
            limits: limits
        )
        if lost {
            throw ControlRuntimeTransportFailure.sent(.disconnected)
        }
        return reply
    }

    func openStream(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> ControlRuntimeStream {
        let message = try ControlRuntimeCodec.decodeFullFrame(request, limits: limits)
        let baseline = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: message.correlation,
                body: .frame(.baseline(try simulatedBaseline(incarnation)))
            ),
            limits: limits
        )
        let end = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: message.correlation,
                body: .frame(.end(ControlStreamEnd(reason: .hostShutdown)))
            ),
            limits: limits
        )
        lock.withLock { streamQueue = [baseline, end] }
        return ControlRuntimeStream(
            next: { _ in try self.nextStreamFrame() },
            cancel: { self.releaseStream() }
        )
    }

    /// The host's answer, and whether the reply is lost after the command was admitted.
    private func answer(to body: ControlRuntimeBody) -> (ControlRuntimeResponse, Bool) {
        lock.withLock { () -> (ControlRuntimeResponse, Bool) in
            guard case .request(let request) = body else { return (.failure(.unknownCommand), false) }
            received += 1
            switch request {
            case .submit(let submit):
                if let refusal { return (.failure(refusal), false) }
                admitted = submit.requestID
                let lost = losesNext
                losesNext = false
                return (.admission(.accepted(operation)), lost)
            case .requestLookup(let query):
                guard query.expectedIncarnation == incarnation else {
                    return (.requestLookup(.unknown(.changedIncarnation)), false)
                }
                if admitted == query.requestID {
                    return (.requestLookup(.admission(.accepted(operation))), false)
                }
                return (.requestLookup(.unknown(.notRecorded)), false)
            default:
                return (.failure(.unknownCommand), false)
            }
        }
    }

    private func nextStreamFrame() throws -> Data {
        try lock.withLock { () throws -> Data in
            guard !streamQueue.isEmpty else { throw RuntimeWaitEnd.disconnected }
            return streamQueue.removeFirst()
        }
    }

    private func releaseStream() {
        lock.withLock { streamReleases += 1 }
    }
}
