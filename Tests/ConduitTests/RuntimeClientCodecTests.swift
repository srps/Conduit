// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared

/// The v2 frame codec: round trips, golden bytes, the order of refusal, bounded
/// framing and encoding, the known and unknown event split, and v1's unchanged bytes.
final class RuntimeClientCodecTests: XCTestCase {
    private let limits = try! ControlFrameLimits(maxFrameBytes: 16 * 1024)
    private let correlationText = "00000000-0000-0000-0000-00000000000A"
    private let incarnationText = "00000000-0000-0000-0000-000000000001"

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private func requestID(_ value: Int) -> ControlRequestID {
        ControlRequestID(rawValue: uuid(value))
    }

    private func incarnation(_ value: Int) -> ControlHostIncarnation {
        ControlHostIncarnation(rawValue: uuid(value))
    }

    private func operationID(_ value: Int) -> ControlOperationID {
        ControlOperationID(rawValue: uuid(value))
    }

    private func budget(_ milliseconds: Int) throws -> ControlWireBudget {
        try ControlWireBudget(milliseconds)
    }

    private func request(_ call: ControlRuntimeCall, budget milliseconds: Int = 1_000, correlation: Int = 10) throws -> ControlRuntimeMessage {
        ControlRuntimeMessage(
            correlation: requestID(correlation),
            body: .request(ControlRuntimeRequest(budget: try budget(milliseconds), call: call))
        )
    }

    private func submit(_ command: ControlRuntimeCommand, id: Int = 10) throws -> ControlRuntimeMessage {
        try request(.submit(ControlOperationRequest(
            requestID: requestID(id),
            expectedIncarnation: incarnation(1),
            command: command
        )), correlation: id)
    }

    private func assertFrameRefused(
        _ payload: String,
        expected: ControlRuntimeWireError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ControlRuntimeCodec.decodeFrame(Data(payload.utf8), limits: limits),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, expected, file: file, line: line)
        }
    }

    /// A complete v2 request envelope for a submit. The budget is the envelope's own field, next to the correlation. Each
    /// argument can be replaced by a bad value, or dropped, to build one malformed fixture at a time. A nil incarnation
    /// omits the field.
    private func submitRequest(
        correlation: String? = nil,
        requestID: String? = nil,
        incarnation: String? = nil,
        budget: String = "1",
        command: String = #"{"type":"stop","module":"dns"}"#
    ) -> String {
        let incarnationField = incarnation.map { ",\"expectedIncarnation\":\"\($0)\"" } ?? ""
        return #"{"version":2,"kind":"request","correlation":""#
            + (correlation ?? correlationText)
            + #"","budget":"#
            + budget
            + #","body":{"type":"submit","submit":{"requestID":""#
            + (requestID ?? correlationText)
            + "\""
            + incarnationField
            + #","command":"#
            + command
            + #"}}}"#
    }

    // MARK: - Round trips and golden bytes

    func testEveryCommandRoundTripsThroughAFramedMessage() throws {
        let commands: [ControlRuntimeCommand] = [
            .stop(.dns),
            .stop(.proxy),
            .restart(.tunnels, ifLifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 4))),
            .testDNS,
            .testUpstream(ControlUpstreamReference(
                configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 2)),
                upstreamID: ControlUpstreamID(rawValue: uuid(7))
            )),
            .refreshPreflight,
        ]
        for command in commands {
            let message = try submit(command)
            let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
            XCTAssertEqual(frame.last, 0x0A)
            XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits), message)
        }
    }

    func testSubmitFrameBytesMatchTheGoldenV2Shape() throws {
        let frame = try ControlRuntimeCodec.encodeFrame(try submit(.stop(.dns)), limits: limits)
        let expected = #"{"body":{"submit":{"command":{"module":"dns","type":"stop"},"expectedIncarnation":"00000000-0000-0000-0000-000000000001","requestID":"00000000-0000-0000-0000-00000000000A"},"type":"submit"},"budget":1000,"correlation":"00000000-0000-0000-0000-00000000000A","kind":"request","version":2}"#
        XCTAssertEqual(String(decoding: frame.dropLast(), as: UTF8.self), expected)
    }

    func testAStaleOrdinalFromAnotherIncarnationIsAnotherCommand() throws {
        // The same ordinal under a restarted host's incarnation must not look equal.
        let restart = ControlRuntimeCommand.restart(.dns, ifLifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 9)))
        let before = try request(.submit(ControlOperationRequest(
            requestID: requestID(10), expectedIncarnation: incarnation(1), command: restart
        )))
        let after = try request(.submit(ControlOperationRequest(
            requestID: requestID(10), expectedIncarnation: incarnation(2), command: restart
        )))
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(
            try ControlRuntimeCodec.encodeBoundedPayload(before, limits: limits),
            try ControlRuntimeCodec.encodeBoundedPayload(after, limits: limits)
        )
    }

    func testReadSnapshotIsAPayloadlessRequestWithItsCorrelation() throws {
        // No incarnation: a bootstrap has nothing to expect yet. The budget is still mandatory on every request.
        let frame = try ControlRuntimeCodec.encodeFrame(try request(.readSnapshot, correlation: 12), limits: limits)
        let expected = #"{"body":{"type":"readSnapshot"},"budget":1000,"correlation":"00000000-0000-0000-0000-00000000000C","kind":"request","version":2}"#
        XCTAssertEqual(String(decoding: frame.dropLast(), as: UTF8.self), expected)
    }

    func testAMutationWithoutItsExpectedIncarnationIsMalformed() {
        assertFrameRefused(submitRequest(incarnation: nil), expected: .malformedMessage)
    }

    func testRestartCarriesOnlyTheLifecycleRevisionAsItsPrecondition() throws {
        let message = try submit(.restart(.dns, ifLifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 9))))
        let text = String(decoding: try ControlRuntimeCodec.encodeBoundedPayload(message, limits: limits), as: UTF8.self)
        XCTAssertTrue(text.contains(#""lifecycleRevision":9"#))
        XCTAssertFalse(text.contains("presentation"), "a presentation revision must never be a command precondition")
    }

    func testEveryRequestKindRoundTrips() throws {
        let page = ControlPageRequest(expectedIncarnation: incarnation(1), collection: .activeConnections)
        let calls: [ControlRuntimeCall] = [
            .outcome(ControlOperationQuery(expectedIncarnation: incarnation(1), operationID: operationID(2))),
            .requestLookup(ControlRequestQuery(expectedIncarnation: incarnation(1), requestID: requestID(3))),
            .subscribe(.live),
            .subscribe(.resume(incarnation: incarnation(1), from: try XCTUnwrap(ControlEventCursor(rawValue: 4)))),
            .readPage(page),
            .readSnapshot,
        ]
        for value in calls {
            let message = try request(value, budget: 5)
            XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(
                Data(try ControlRuntimeCodec.encodeFrame(message, limits: limits).dropLast()), limits: limits
            ), message)
        }
    }

    func testResponsesAndFramesRoundTripWithTheirCorrelation() throws {
        let responses: [ControlRuntimeResponse] = [
            .admission(.accepted(operationID(1))),
            .admission(.joined(operationID(1))),
            .requestLookup(.admission(.rejected(.notImplemented))),
            .requestLookup(.unknown(.expiredHistory)),
            .lookup(.pending),
            .lookup(.unknown(.changedIncarnation)),
            .lookup(.finished(.failed(.effectFailed))),
            .failure(.unsupportedVersion),
        ]
        for response in responses {
            let message = ControlRuntimeMessage(correlation: requestID(10), body: .response(response))
            let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
            XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits), message)
        }

        let frames: [ControlRuntimeFrame] = [
            .replayCaughtUp(try XCTUnwrap(ControlEventCursor(rawValue: 3))),
            .end(ControlStreamEnd(reason: .slowConsumer)),
            .operationFinished(ControlOperationFinished(
                operationID: operationID(2),
                outcome: .superseded(by: operationID(3))
            )),
        ]
        for frame in frames {
            let message = ControlRuntimeMessage(correlation: requestID(11), body: .frame(frame))
            let bytes = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
            XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(bytes.dropLast()), limits: limits), message)
        }
    }

    func testCorrelationIsRequiredOnEveryMessage() {
        assertFrameRefused(
            #"{"version":2,"kind":"response","body":{"type":"admission","admission":{"type":"accepted","operation":"00000000-0000-0000-0000-000000000002"}}}"#,
            expected: .malformedMessage
        )
        assertFrameRefused(submitRequest(correlation: "not-a-uuid"), expected: .malformedMessage)
    }

    func testEncodingIsDeterministic() throws {
        let message = try submit(.refreshPreflight)
        XCTAssertEqual(
            try ControlRuntimeCodec.encodeFrame(message, limits: limits),
            try ControlRuntimeCodec.encodeFrame(message, limits: limits)
        )
    }

    // MARK: - Refusal order: size, version, discriminators, then typed body

    func testMissingOrUnknownVersionIsUnsupportedNotMalformed() {
        assertFrameRefused(#"{"kind":"request","body":{"type":"readPage"}}"#, expected: .unsupportedVersion)
        assertFrameRefused(#"{"version":3,"kind":"request","body":{"type":"readPage"}}"#, expected: .unsupportedVersion)
        assertFrameRefused(#"{"version":"2","kind":"request","body":{"type":"readPage"}}"#, expected: .unsupportedVersion)
    }

    func testTheVersionIsReadBeforeAMalformedBodyIsParsed() {
        // A version this build does not speak wins over a body that would not decode.
        assertFrameRefused(
            #"{"version":99,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"submit","submit":5}}"#,
            expected: .unsupportedVersion
        )
        assertFrameRefused(
            #"{"version":"2","kind":"push","body":{"type":"submit","submit":5}}"#,
            expected: .unsupportedVersion
        )
        // Within version 2, an unknown envelope kind is refused before its body is read.
        assertFrameRefused(
            #"{"version":2,"kind":"push","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"submit","submit":5}}"#,
            expected: .unknownCommand
        )
        // A known discriminator with a bad payload is malformed, and only then.
        assertFrameRefused(
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"readPage","readPage":5}}"#,
            expected: .malformedMessage
        )
    }

    func testAnUnknownKindIsRefusedBeforeItsBodyIsRead() {
        // Each body here cannot be read as a body at all. The kind is checked first, so the
        // answer is unknown_command, never malformed.
        assertFrameRefused(
            #"{"version":2,"kind":"push","correlation":"00000000-0000-0000-0000-00000000000A","body":5}"#,
            expected: .unknownCommand
        )
        assertFrameRefused(
            #"{"version":2,"kind":"push","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":5}}"#,
            expected: .unknownCommand
        )
        assertFrameRefused(
            #"{"version":2,"kind":"push","correlation":"00000000-0000-0000-0000-00000000000A","body":[1,2]}"#,
            expected: .unknownCommand
        )
        // A version this build does not speak still wins over an unknown kind.
        assertFrameRefused(#"{"version":99,"kind":"push","body":5}"#, expected: .unsupportedVersion)
        // A known kind whose body is not an object is malformed, and only then.
        assertFrameRefused(
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":5}"#,
            expected: .malformedMessage
        )
        // A kind that is not a string is malformed, not an unknown kind.
        assertFrameRefused(#"{"version":2,"kind":7,"body":{"type":"readPage"}}"#, expected: .malformedMessage)
    }

    func testV1RequestBytesAreRefusedByTheV2Codec() {
        // A v1 peer's request has no `version` and speaks `command`, not `body`.
        assertFrameRefused(#"{"protocolVersion":1,"command":"status","arguments":[]}"#, expected: .unsupportedVersion)
    }

    func testUnknownCommandFailsClosedWithoutBeingCalledMalformed() {
        assertFrameRefused(
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"start"}}"#,
            expected: .unknownCommand
        )
        // Apply-config's payload is unknown, and the submit's other fields are malformed. The
        // command discriminator is checked first, so the answer is unknown_command.
        assertFrameRefused(
            submitRequest(requestID: "not-a-uuid", command: #"{"type":"apply-config"}"#),
            expected: .unknownCommand
        )
        assertFrameRefused(
            #"{"version":2,"kind":"push","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"events"}}"#,
            expected: .unknownCommand
        )
        assertFrameRefused(
            #"{"version":2,"kind":"response","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"admitted"}}"#,
            expected: .unknownCommand
        )
    }

    func testMalformedKnownPayloadsThrowMalformed() {
        // Each fixture is complete except for the one field it breaks.
        let malformed: [String] = [
            submitRequest(requestID: "not-a-uuid"),
            submitRequest(incarnation: "not-a-uuid"),
            submitRequest(budget: "2147483648"),
            submitRequest(command: #"{"type":"restart","module":"dns","lifecycleRevision":-1}"#),
            submitRequest(command: #"{"type":"stop","module":"tunnel"}"#),
            submitRequest(command: #"{"type":"test-upstream"}"#),
            submitRequest(correlation: "not-a-uuid"),
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"outcome","outcome":{"operationID":"00000000-0000-0000-0000-000000000002","budget":5}}}"#,
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"requestLookup","requestLookup":{"expectedIncarnation":"00000000-0000-0000-0000-000000000001","requestID":"nope","budget":5}}}"#,
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"readPage","readPage":{"collection":"activeConnections"}}}"#,
            #"{"version":2,"kind":"response","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"admission","admission":{"type":"maybe"}}}"#,
            #"{"version":2,"kind":"response","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"requestLookup","requestLookup":{"type":"other"}}}"#,
            #"["version", 2]"#,
            #"{"version":2,"kind":"request","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"submit""#,
        ]
        for payload in malformed {
            assertFrameRefused(payload, expected: .malformedMessage)
        }
    }

    func testAnUnknownAdmissionValueIsMalformedInsideAKnownResponse() {
        assertFrameRefused(
            #"{"version":2,"kind":"response","correlation":"00000000-0000-0000-0000-00000000000A","body":{"type":"admission","admission":{"type":"maybe"}}}"#,
            expected: .malformedMessage
        )
    }

    func testAnOversizeFrameIsRefusedBeforeItIsParsed() {
        // Not JSON at all. The size check must answer first, so the parser never runs.
        let small = try! ControlFrameLimits(maxFrameBytes: 64)
        let garbage = String(repeating: "not json ", count: 40)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(Data(garbage.utf8), limits: small)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testARawLineFeedInsideAPayloadIsRefused() {
        let payload = Data("{\"version\":2,\n\"kind\":\"request\"}".utf8)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(payload, limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage)
        }
    }

    // MARK: - Encode-side bounds

    func testEncodingRefusesAFrameOverTheCallersLimitInsteadOfTruncating() throws {
        let tiny = try ControlFrameLimits(maxFrameBytes: 40)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(try submit(.stop(.dns)), limits: tiny)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testFreeTextOverTheLimitIsRefusedBeforeItIsSerialized() throws {
        let probe = try upstreamProbeMessage(name: String(repeating: "n", count: 2_000))
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeBoundedPayload(probe, limits: try ControlFrameLimits(maxFrameBytes: 1_024))) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testEscapingExpansionIsRefusedNotTruncated() throws {
        // 600 raw control bytes pass the raw-text check at 1 KiB. Each escapes to six
        // bytes as \u0001, so the published form is about 3.6 KiB and must be refused.
        let message = try upstreamProbeMessage(name: String(repeating: "\u{01}", count: 600))
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 1_024)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeBoundedPayload(message, limits: frameLimits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
        // The same text at a limit it fits in is published whole, and round-trips.
        let roomy = try ControlFrameLimits(maxFrameBytes: 8_192)
        let payload = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: roomy)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(payload, limits: roomy), message)
    }

    func testAnElementFloodIsRefusedBeforeItIsSerialized() throws {
        // Ten thousand records cost at least two bytes each, which already exceeds a 16 KiB frame.
        let record = ControlRuntimeEventRecord.known(ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: "proxy", event: "proxy.started", detail: nil
        ))
        let batch = try ControlEventBatch(
            firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 1)),
            events: Array(repeating: record, count: 10_000)
        )
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(correlation: requestID(10), body: .frame(.events(batch))),
            limits: limits
        )) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testAPageWithAnOffsetNearIntMaxIsRefusedNotTrapped() throws {
        let row = #"{"id":"00000000-0000-0000-0000-000000000001","name":"a","endpoint":"e:1","circuitState":"closed","consecutiveFailures":0}"#
        func page(offset: String, total: String, rows: String) -> Data {
            Data(#"{"version":2,"kind":"response","correlation":"\#(correlationText)","body":{"type":"page","page":{"type":"upstreamHealth","page":{"incarnation":"\#(incarnationText)","revision":1,"offset":\#(offset),"totalCount":\#(total),"rows":\#(rows),"status":{"type":"current"}}}}}"#.utf8)
        }
        // Offset Int.max plus one row would overflow. The small frame must be refused, not trapped.
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(
            page(offset: "9223372036854775807", total: "9223372036854775807", rows: "[\(row)]"), limits: limits
        )) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage)
        }
        // Valid progress at the same magnitude still decodes: one row that ends exactly at Int.max,
        // and an empty last page at Int.max.
        XCTAssertNoThrow(try ControlRuntimeCodec.decodeFrame(
            page(offset: "9223372036854775806", total: "9223372036854775807", rows: "[\(row)]"), limits: limits
        ))
        XCTAssertNoThrow(try ControlRuntimeCodec.decodeFrame(
            page(offset: "9223372036854775807", total: "9223372036854775807", rows: "[]"), limits: limits
        ))
        // The encoder refuses the same counts without trapping.
        XCTAssertThrowsError(try ControlCollectionPage(
            incarnation: incarnation(1),
            revision: try XCTUnwrap(ControlCollectionRevision(rawValue: 1)),
            offset: try ControlCount(Int.max),
            totalCount: try ControlCount(Int.max),
            rows: [ControlUpstreamRow(
                id: ControlUpstreamID(rawValue: uuid(1)), name: "a", endpoint: "e:1", circuitState: .closed,
                ewmaLatencyMilliseconds: nil, consecutiveFailures: try ControlCount(0), openUntil: nil
            )],
            nextCursor: nil,
            status: .current
        ))
    }

    func testATypedRecordPublishesAtItsExactFrameSizeAndRefusesOneByteLess() throws {
        // The budget counts only free text, so a typed record must publish at exactly the size its
        // encoding measures, line feed included. The fixed allowance this replaces refused records
        // of this size that do fit.
        let version = String(repeating: "v", count: ControlLifecycleEvent.maximumVersionBytes)
        let typed = ControlTypedRuntimeEvent.lifecycle(.versionChanged(from: version, to: "1.1"))
        let event = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: typed.kind, event: typed.name, detail: typed.detail, typed: typed
        )
        let batch = try ControlEventBatch(
            firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 1)), events: [.known(event)]
        )
        let message = ControlRuntimeMessage(correlation: requestID(10), body: .frame(.events(batch)))
        let payloadSize = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: limits).count

        let exact = try ControlFrameLimits(maxFrameBytes: payloadSize + 1)
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: exact)
        XCTAssertEqual(frame.count, payloadSize + 1)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: exact), message)

        let oneShort = try ControlFrameLimits(maxFrameBytes: payloadSize)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(message, limits: oneShort)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testTheFrameBudgetRefusesTextOneByteOverItsRoom() throws {
        var exact = ControlFrameBudget(limit: 5)
        XCTAssertNoThrow(try exact.text("abcde"))
        XCTAssertThrowsError(try exact.text("f")) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }

        var single = ControlFrameBudget(limit: 5)
        XCTAssertThrowsError(try single.text("abcdef"))

        // Counts are UTF-8 bytes, so a two-byte character takes two of the room.
        var multibyte = ControlFrameBudget(limit: 4)
        XCTAssertNoThrow(try multibyte.text("é"))
        XCTAssertNoThrow(try multibyte.text("ab"))
        XCTAssertThrowsError(try multibyte.text("c"))
    }

    func testFrameLimitsRefuseTheValuesNoFrameCanUse() {
        XCTAssertThrowsError(try ControlFrameLimits(maxFrameBytes: 0))
        XCTAssertThrowsError(try ControlFrameLimits(maxFrameBytes: 1))
        XCTAssertNoThrow(try ControlFrameLimits(maxFrameBytes: 2))
    }

    func testScalarsRefuseOutOfRangeValuesOnConstructionAndDecode() throws {
        XCTAssertThrowsError(try ControlCount(-1))
        XCTAssertThrowsError(try ControlPort(0))
        XCTAssertThrowsError(try ControlPort(65_536))
        XCTAssertThrowsError(try ControlWireBudget(-1))
        XCTAssertThrowsError(try ControlWireBudget(Int(Int32.max) + 1))
        XCTAssertNil(ControlConfigRevision(rawValue: -1))

        XCTAssertThrowsError(try JSONDecoder().decode(ControlCount.self, from: Data("-3".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ControlConfigRevision.self, from: Data("-3".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ControlPort.self, from: Data("70000".utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(ControlPort.self, from: Data("8080".utf8)))
    }

    func testEventBatchesAndModuleOutcomesRefuseToBeEmptyOrDuplicated() throws {
        let record = ControlRuntimeEventRecord.known(ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: "proxy", event: "proxy.started", detail: nil
        ))
        XCTAssertThrowsError(try ControlEventBatch(firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 1)), events: []))
        XCTAssertThrowsError(try ControlModuleOutcomes([]))
        XCTAssertThrowsError(try ControlModuleOutcomes([
            ControlModuleOutcome(module: .dns, result: .succeeded),
            ControlModuleOutcome(module: .dns, result: .cleanupPending),
        ]))
        XCTAssertNoThrow(try ControlModuleOutcomes([
            ControlModuleOutcome(module: .dns, result: .succeeded),
            ControlModuleOutcome(module: .tunnels, result: .failed(.effectFailed)),
        ]))
        XCTAssertNoThrow(try ControlEventBatch(firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 1)), events: [record]))
    }

    func testACompletionRefusesAResultThatBelongsToAnotherCommand() throws {
        let revision = try XCTUnwrap(ControlPresentationRevision(rawValue: 3))
        // A test that never ran cannot settle as a generic success.
        XCTAssertThrowsError(try ControlCompletion(command: .testDNS, presentationRevision: revision, result: .settled))
        XCTAssertThrowsError(try ControlCompletion(command: .stop, presentationRevision: revision, result: .preflight(
            ControlPreflightObservation(
                stamp: ControlRuntimeStamp(
                    incarnation: incarnation(1),
                    presentationRevision: revision,
                    configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 1)),
                    lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 1))
                ),
                observedAt: try ControlTimestamp(1_700_000_000),
                reading: .unavailable(.notObserved)
            )
        )))
        XCTAssertNoThrow(try ControlCompletion(
            command: .testDNS,
            presentationRevision: revision,
            result: .dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(53), answered: false))
        ))

        let mismatched = #"{"command":"test-dns","presentationRevision":3,"result":{"type":"settled"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ControlCompletion.self, from: Data(mismatched.utf8)))
    }

    func testAReplayRangeThatRunsBackwardsFailsOnEncodeAndDecode() throws {
        let from = try XCTUnwrap(ControlEventCursor(rawValue: 9))
        let through = try XCTUnwrap(ControlEventCursor(rawValue: 2))
        XCTAssertThrowsError(try JSONEncoder().encode(ControlReplayAvailability.replay(from: from, through: through)))
        let backwards = #"{"type":"replay","from":9,"through":2}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ControlReplayAvailability.self, from: Data(backwards.utf8)))
    }

    private func upstreamProbeMessage(name: String) throws -> ControlRuntimeMessage {
        let probe = ControlUpstreamProbe(
            upstreamID: ControlUpstreamID(rawValue: uuid(7)),
            name: name,
            endpoint: "proxy.corp.example.test:8080",
            reachable: true,
            latencyMilliseconds: try ControlCount(12)
        )
        let completion = try ControlCompletion(
            command: .testUpstream,
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: 3)),
            result: .upstreamProbe(probe)
        )
        return ControlRuntimeMessage(
            correlation: requestID(10),
            body: .response(.lookup(.finished(.completed(completion))))
        )
    }

    // MARK: - Bounded incremental framing

    func testFramerHandlesFragmentedAndCoalescedFrames() throws {
        let first = try ControlRuntimeCodec.encodeFrame(try submit(.testDNS, id: 1), limits: limits)
        let second = try ControlRuntimeCodec.encodeFrame(try submit(.refreshPreflight, id: 2), limits: limits)
        let stream = first + second

        var byteByByte = ControlRuntimeLineFramer(limits: limits)
        var payloads: [Data] = []
        for byte in stream {
            if case .frame(let payload) = try byteByByte.consume([byte]).step {
                payloads.append(payload)
            }
        }
        try byteByByte.finish()
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(payloads[0], limits: limits), try submit(.testDNS, id: 1))
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(payloads[1], limits: limits), try submit(.refreshPreflight, id: 2))

        var coalesced = ControlRuntimeLineFramer(limits: limits)
        let (frames, consumed) = try drain(&coalesced, Array(stream))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(consumed, stream.count)
        XCTAssertEqual(coalesced.retainedByteCount, 0)
    }

    func testManyTinyFramesInOneChunkAreLosslessWithOneFramePerCall() throws {
        // A single socket read can carry hundreds of frames. Each call must return one of
        // them and report exactly where it stopped, so none is dropped or read twice.
        let frameCount = 1_000
        let chunk = Array(String(repeating: "{}\n", count: frameCount).utf8)
        var framer = ControlRuntimeLineFramer(limits: limits)
        var offset = 0
        var frames: [Data] = []
        while offset < chunk.count {
            let (step, consumed) = try framer.consume(chunk[offset...])
            XCTAssertGreaterThan(consumed, 0)
            XCTAssertLessThanOrEqual(consumed, limits.maxFrameBytes, "one call reads at most one frame's bytes")
            offset += consumed
            if case .frame(let payload) = step {
                frames.append(payload)
            }
        }
        XCTAssertEqual(offset, chunk.count)
        XCTAssertEqual(frames.count, frameCount)
        XCTAssertTrue(frames.allSatisfy { $0 == Data("{}".utf8) })
        XCTAssertEqual(framer.retainedByteCount, 0)
        XCTAssertNoThrow(try framer.finish())
    }

    func testAFramerReadsNothingPastTheFrameItCompletes() throws {
        var framer = ControlRuntimeLineFramer(limits: limits)
        let (step, consumed) = try framer.consume(Array("a\nb".utf8))
        XCTAssertEqual(step, .frame(Data("a".utf8)))
        XCTAssertEqual(consumed, 2, "the line feed is consumed, the byte after it is not")
        let (rest, restConsumed) = try framer.consume(Array("b".utf8))
        XCTAssertEqual(rest, .needsInput)
        XCTAssertEqual(restConsumed, 1)
        XCTAssertEqual(framer.retainedByteCount, 1)
    }

    func testAHugeSegmentWithoutALineFeedIsRefusedBeforeItIsCopied() throws {
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 64)
        let counter = ReadCounter()
        let segment = CountedBytes(bytes: [UInt8](repeating: UInt8(ascii: "z"), count: 1_000_000), counter: counter)
        var framer = ControlRuntimeLineFramer(limits: frameLimits)
        XCTAssertThrowsError(try framer.consume(segment)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
        // At most one byte past the payload capacity is read before the refusal.
        XCTAssertLessThanOrEqual(counter.reads, frameLimits.maxFrameBytes)
        XCTAssertEqual(framer.retainedByteCount, 0)
        XCTAssertThrowsError(try framer.consume([0x0A])) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testFramerRetainsNoMoreThanOneFrameOfIncompleteBytes() throws {
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 64)
        var framer = ControlRuntimeLineFramer(limits: frameLimits)
        var peak = 0
        for _ in 0..<12 {
            _ = try framer.consume(Array(repeating: UInt8(ascii: "a"), count: 5))
            peak = max(peak, framer.retainedByteCount)
        }
        XCTAssertEqual(peak, 60)
        XCTAssertLessThanOrEqual(peak, frameLimits.maxFrameBytes - 1)
    }

    func testFramerAcceptsAFrameExactlyAtTheLimitAndRefusesOneByteMore() throws {
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 20)
        var atLimit = ControlRuntimeLineFramer(limits: frameLimits)
        // 19 payload bytes plus the line feed fill the 20-byte frame.
        let (step, _) = try atLimit.consume(Array(repeating: UInt8(ascii: "x"), count: 19) + [0x0A])
        guard case .frame(let payload) = step else { return XCTFail("the frame at the limit was not returned") }
        XCTAssertEqual(payload.count, 19)

        var overLimit = ControlRuntimeLineFramer(limits: frameLimits)
        XCTAssertThrowsError(try overLimit.consume(Array(repeating: UInt8(ascii: "x"), count: 20) + [0x0A])) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testFramerOverflowReleasesItsBytesAndStaysFailed() throws {
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 16)
        var framer = ControlRuntimeLineFramer(limits: frameLimits)
        _ = try framer.consume(Array("{\"a\":1".utf8))
        XCTAssertThrowsError(try framer.consume(Array(repeating: UInt8(ascii: "z"), count: 1_000_000))) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
        XCTAssertEqual(framer.retainedByteCount, 0)
        XCTAssertThrowsError(try framer.consume([0x0A])) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testFramerReportsAnIncompleteFrameAtEndOfInput() throws {
        var framer = ControlRuntimeLineFramer(limits: limits)
        _ = try framer.consume(Array("{\"version\":2".utf8))
        XCTAssertThrowsError(try framer.finish()) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameIncomplete)
        }
    }

    /// Consumes a whole chunk through the single-frame API, the way a caller drives it.
    private func drain(_ framer: inout ControlRuntimeLineFramer, _ bytes: [UInt8]) throws -> ([Data], Int) {
        var offset = 0
        var frames: [Data] = []
        while offset < bytes.count {
            let (step, consumed) = try framer.consume(bytes[offset...])
            offset += consumed
            if case .frame(let payload) = step {
                frames.append(payload)
            }
        }
        return (frames, offset)
    }

    // MARK: - Events: known values, and bounded display for the unknown

    /// A frame holding one batch of the given records. Line breaks in the fixtures are
    /// removed, since a frame payload may not carry a raw line feed.
    private func eventFrame(_ records: String) -> Data {
        let unbroken = records.replacingOccurrences(of: "\n", with: " ")
        return Data((#"{"version":2,"kind":"frame","correlation":"\#(correlationText)","body":{"type":"events","events":{"firstCursor":1,"events":["#
            + unbroken + #"]}}}"#).utf8)
    }

    private func decodeRecord(_ json: String) throws -> ControlRuntimeEventRecord {
        let message = try ControlRuntimeCodec.decodeFrame(eventFrame(json), limits: limits)
        guard case .frame(.events(let batch)) = message.body, let record = batch.events.first else {
            throw ControlRuntimeWireError.invalidValue
        }
        return record
    }

    func testAKnownLifecycleEventRoundTripsAsOneContiguousRun() throws {
        let typed = ControlTypedRuntimeEvent.lifecycle(.terminationDrainExpired(deadlineMilliseconds: 500))
        let known = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: typed.kind,
            event: typed.name,
            detail: typed.detail,
            typed: typed
        )
        let batch = try ControlEventBatch(
            firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 40)),
            events: [.known(known), .known(known)]
        )
        let message = ControlRuntimeMessage(correlation: requestID(10), body: .frame(.events(batch)))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits), message)
    }

    func testEveryLifecycleCaseTheEventWorkerEncodesIsKnownToThisBuild() throws {
        // Guards the duplicated lifecycle spellings in ControlRuntimeEventRecord: if the event
        // worker adds or renames a type, its records must not silently read as unknown.
        let cases: [ControlLifecycleEvent] = [
            .superseded(operation: .proxyStart, generation: 1, current: 2, reason: .superseded),
            .coalesced(operation: .proxyStart, joined: 2),
            .terminationDrainExpired(deadlineMilliseconds: 500),
            .versionChanged(from: "1.0", to: "1.1"),
        ]
        for lifecycle in cases {
            let typed = ControlTypedRuntimeEvent.lifecycle(lifecycle)
            let event = ControlRuntimeEvent(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: typed.kind, event: typed.name, detail: typed.detail, typed: typed
            )
            let data = try ControlRuntimeCodec.makeEncoder().encode(ControlRuntimeEventRecord.known(event))
            let decoded = try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeEventRecord.self, from: data)
            XCTAssertEqual(decoded, .known(event), "\(typed.name) must decode as known")
        }
    }

    func testAKnownRecordWhoseDetailDisagreesWithItsPayloadIsMalformedNotUnknown() throws {
        let typed = ControlTypedRuntimeEvent.lifecycle(.terminationDrainExpired(deadlineMilliseconds: 500))
        let known = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: typed.kind, event: typed.name, detail: typed.detail, typed: typed
        )
        let text = String(decoding: try ControlRuntimeCodec.makeEncoder().encode(ControlRuntimeEventRecord.known(known)), as: UTF8.self)
        let tampered = text.replacingOccurrences(of: typed.detail, with: "a detail the payload does not imply")
        XCTAssertNotEqual(tampered, text, "the fixture must contain the detail it changes")
        XCTAssertThrowsError(try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeEventRecord.self, from: Data(tampered.utf8)))
    }

    func testAKnownLifecycleTypeWithAMalformedPayloadIsMalformedNotUnknown() {
        let record = #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.coalesced","detail":"x","typed":{"family":"lifecycle","lifecycle":{"type":"coalesced","operation":"restart","joined":"many"}}}"#
        XCTAssertThrowsError(try decodeRecord(record))
        XCTAssertThrowsError(try decodeRecord(
            #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.coalesced","detail":"x","typed":{"family":"lifecycle"}}"#
        ), "a lifecycle family with no payload is malformed")
    }

    func testAFutureFamilyBecomesABoundedRedactedDisplayRecord() throws {
        let record = try decodeRecord(#"""
        {"timestamp":0,"kind":"dns","event":"dns.future_probe","detail":"Authorization: Basic ARTIFICIALBASIC-44aa https://u:ARTIFICIAL-PW@h.example.test/p?token=ARTIFICIAL-Q",
         "typed":{"family":"dns","dns":{"password":"ARTIFICIAL-STRUCT","nested":{"cookie":"ARTIFICIAL-COOKIE"}}}}
        """#)
        guard case .unknown(let display) = record else { return XCTFail("a future family must be a display record") }
        XCTAssertEqual(display.kind, "dns")
        XCTAssertEqual(display.event, "dns.future_probe")
        XCTAssertNotNil(display.detail)
        XCTAssertFalse(String(describing: record).contains("ARTIFICIAL"), "no token or structured secret reaches the display")
        XCTAssertFalse(String(describing: record).contains("?token="))
    }

    func testAFutureLifecycleTypeIsDisplayedNotMalformed() throws {
        let record = try decodeRecord(#"""
        {"timestamp":0,"kind":"lifecycle","event":"lifecycle.future_thing","detail":"later","typed":{"family":"lifecycle","lifecycle":{"type":"future_kind","extra":1}}}
        """#)
        guard case .unknown(let display) = record else { return XCTFail("an unknown lifecycle type must be a display record") }
        XCTAssertEqual(display.event, "lifecycle.future_thing")
    }

    func testAnEventWithNoTypedValueIsTheKnownV1Layout() throws {
        let record = try decodeRecord(#"{"timestamp":0,"kind":"proxy","event":"proxy.started","detail":"port=3128"}"#)
        guard case .known(let event) = record else { return XCTFail("a v1-layout record is known") }
        XCTAssertEqual(event.event, "proxy.started")
    }

    func testAFutureRecordWithoutItsOuterFieldsIsMalformed() {
        XCTAssertThrowsError(try decodeRecord(#"{"timestamp":0,"kind":"dns","typed":{"family":"dns"}}"#))
        XCTAssertThrowsError(try decodeRecord(#"{"kind":"dns","event":"dns.x","typed":{"family":"dns"}}"#))
    }

    func testAKnownEventNameWithAnUnknownFamilyIsCorruptNotDisplayed() {
        // The name says lifecycle, so this is known data whose family was changed. It is refused.
        XCTAssertThrowsError(try decodeRecord(
            #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.superseded","detail":"x","typed":{"family":"future"}}"#
        ))
    }

    func testAKnownEventNameWithAnUnknownLifecycleTypeIsCorruptNotDisplayed() {
        XCTAssertThrowsError(try decodeRecord(
            #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.coalesced","detail":"x","typed":{"family":"lifecycle","lifecycle":{"type":"future_kind"}}}"#
        ))
    }

    func testAnUnknownEventNameWithAKnownFamilyAndTypeStaysStrict() {
        // An unknown name with a known inner type is not a future event. Its name does not match the payload.
        XCTAssertThrowsError(try decodeRecord(
            #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.future_thing","detail":"x","typed":{"family":"lifecycle","lifecycle":{"type":"coalesced","operation":"proxy_start","joined":2}}}"#
        ))
    }

    func testAnUnknownFamilyDiscardsEveryNestedShapeUnread() throws {
        // The family probe reads only `family`, so a nested value of any shape is ignored, not decoded.
        let shapes = [
            #""lifecycle":5"#,
            #""lifecycle":[1,{"type":null}]"#,
            #""payload":{"deep":[[[true]]],"secret":"ARTIFICIAL-NESTED"}"#,
            #""lifecycle":{"type":"superseded","generation":"not a number"}"#,
        ]
        for shape in shapes {
            let record = try decodeRecord(
                #"{"timestamp":0,"kind":"future","event":"future.thing","detail":"d","typed":{"family":"future",\#(shape)}}"#
            )
            guard case .unknown(let display) = record else { return XCTFail("\(shape) must be a display record") }
            XCTAssertEqual(display.event, "future.thing")
            XCTAssertFalse(String(describing: record).contains("ARTIFICIAL"), "no structured secret reaches the display")
        }
    }

    func testATypedValueWithoutAStringFamilyOrAtAllIsMalformed() {
        XCTAssertThrowsError(try decodeRecord(#"{"timestamp":0,"kind":"dns","event":"dns.future","typed":{"family":7}}"#))
        XCTAssertThrowsError(try decodeRecord(#"{"timestamp":0,"kind":"dns","event":"dns.future","typed":null}"#))
        XCTAssertThrowsError(try decodeRecord(
            #"{"timestamp":0,"kind":"lifecycle","event":"lifecycle.future_thing","typed":{"family":"lifecycle","lifecycle":5}}"#
        ), "a lifecycle payload that is not an object")
    }

    func testTheEventWorkersVocabularyIsTheOneTheClassifierReads() {
        // The classifier reads these sets. A renamed or added spelling must fail here, not
        // read as an unknown record in production.
        let cases: [ControlLifecycleEvent] = [
            .superseded(operation: .proxyStart, generation: 1, current: 2, reason: .superseded),
            .coalesced(operation: .proxyStart, joined: 2),
            .terminationDrainExpired(deadlineMilliseconds: 500),
            .versionChanged(from: "1.0", to: "1.1"),
        ]
        XCTAssertEqual(ControlLifecycleEvent.knownEventNames, Set(cases.map(\.name)))
        XCTAssertEqual(
            ControlLifecycleEvent.knownWireTypes,
            ["superseded", "coalesced", "termination_drain_expired", "version_changed"]
        )
        XCTAssertEqual(ControlTypedRuntimeEvent.knownFamilies, ["lifecycle"])
    }

    func testAnUnboundedDisplayDetailIsTruncatedAtAFixedBound() throws {
        let long = String(repeating: "e", count: 5_000)
        let record = try decodeRecord(
            #"{"timestamp":0,"kind":"dns","event":"dns.future","detail":"\#(long)","typed":{"family":"dns"}}"#
        )
        guard case .unknown(let display) = record else { return XCTFail("expected a display record") }
        XCTAssertTrue(display.truncated)
        XCTAssertLessThanOrEqual(display.detail?.utf8.count ?? 0, ControlUnknownEventDisplay.maxDetailBytes)
    }

    func testADisplayRecordIsNeverEncoded() {
        let display = ControlUnknownEventDisplay(
            timestamp: Date(timeIntervalSince1970: 0), kind: "dns", event: "dns.future", detail: nil
        )
        XCTAssertThrowsError(try ControlRuntimeCodec.makeEncoder().encode(ControlRuntimeEventRecord.unknown(display)))
    }

    func testAnEventTimestampIsUnixEpochSecondsOnTheWire() throws {
        // v2 timestamps are Unix-epoch seconds, as ControlTimestamp is. Foundation's default writes
        // seconds since 2001, 978307200 seconds lower, which an external reader would misplace.
        let instant = Date(timeIntervalSince1970: 1_700_000_000.125)
        let event = ControlRuntimeEvent(timestamp: instant, kind: "proxy", event: "proxy.started", detail: nil)
        let written = try ControlRuntimeCodec.makeEncoder().encode(ControlRuntimeEventRecord.known(event))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(object["timestamp"] as? Double, 1_700_000_000.125, "the number on the wire is Unix epoch seconds")

        // A snapshot or preflight time is a ControlTimestamp, and is written on the same scale.
        let scalar = try ControlTimestamp(1_700_000_000.125)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: ControlRuntimeCodec.makeEncoder().encode([scalar])) as? [Double],
            [1_700_000_000.125]
        )

        // A reader's number decodes back to the same instant, both in a record and in a frame.
        XCTAssertEqual(
            try decodeRecord(#"{"timestamp":1700000000.125,"kind":"proxy","event":"proxy.started","detail":null}"#),
            .known(event)
        )
        let batch = try ControlEventBatch(
            firstCursor: try XCTUnwrap(ControlEventCursor(rawValue: 1)), events: [.known(event)]
        )
        let message = ControlRuntimeMessage(correlation: requestID(10), body: .frame(.events(batch)))
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(
            try ControlRuntimeCodec.encodeBoundedPayload(message, limits: limits), limits: limits
        ), message)
    }

    // MARK: - v1 is unchanged

    func testV1RequestAndResponseBytesAreUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = try encoder.encode(ControlRequest(command: .status))
        XCTAssertEqual(String(decoding: request, as: UTF8.self), #"{"arguments":[],"command":"status","protocolVersion":1}"#)

        let response = try encoder.encode(ControlResponse.error(.unsupportedVersion, "Unsupported protocol version."))
        XCTAssertEqual(
            String(decoding: response, as: UTF8.self),
            #"{"errorCode":"unsupported_version","errorMessage":"Unsupported protocol version.","protocolVersion":1,"success":false}"#
        )
        XCTAssertEqual(ControlSocket.maxFrameBytes, 16 * 1024)
        XCTAssertEqual(ControlProtocolVersion.current, 1)
    }
}

/// Counts every read of its elements, so a test can measure the work a consumer does.
private final class ReadCounter {
    var reads = 0
}

/// A byte collection that counts its reads.
private struct CountedBytes: Collection {
    let bytes: [UInt8]
    let counter: ReadCounter

    var startIndex: Int { 0 }
    var endIndex: Int { bytes.count }

    func index(after position: Int) -> Int {
        position + 1
    }

    subscript(position: Int) -> UInt8 {
        counter.reads += 1
        return bytes[position]
    }
}
