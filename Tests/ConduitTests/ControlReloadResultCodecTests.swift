// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared

/// The reload command and its typed result on the v2 wire (decision 0032): exact shapes and key sets, the refusal of inconsistent known
/// fields and of holds a reload never produces, the command/result pairing, and the unchanged spellings the workflow event shares.
final class ControlReloadResultCodecTests: XCTestCase {
    private func encoded<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// The top-level member names of one encoded object.
    private func keys<Value: Encodable>(of value: Value) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
        return Set((object as? [String: Any])?.keys.map { $0 } ?? [])
    }

    // MARK: - Command

    func testTheReloadCommandCarriesNothingAndRefusesAnotherCommandsField() throws {
        XCTAssertEqual(try encoded(ControlRuntimeCommand.reload), #"{"type":"reload"}"#)
        XCTAssertEqual(ControlRuntimeCommand.reload.kind, .reload)
        XCTAssertEqual(try decode(ControlRuntimeCommand.self, #"{"type":"reload"}"#), .reload)
        XCTAssertEqual(try decode(ControlRuntimeCommand.self, #"{"type":"reload","future":1}"#), .reload, "an unknown key is additive")
        for field in [#""module":"dns""#, #""helperReplaced":false"#, #""moduleRevision":1"#] {
            XCTAssertThrowsError(try decode(ControlRuntimeCommand.self, #"{"type":"reload",\#(field)}"#), field)
        }
    }

    func testTheReloadSubmitFramesThroughTheCodec() throws {
        let limits = try ControlFrameLimits(maxFrameBytes: 16 * 1024)
        let message = ControlRuntimeMessage(
            correlation: ControlRequestID(rawValue: UUID()),
            body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(1_000), call: .submit(ControlOperationRequest(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: ControlHostIncarnation(rawValue: UUID()), command: .reload
            ))))
        )
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits), message)
    }

    // MARK: - Result shapes

    /// Each case's exact bytes and member names. None names a value, path, baseline, token, generation or summary.
    func testEachResultHasItsExactShapeAndRoundTrips() throws {
        let shapes: [(ControlReloadResult, String)] = [
            (.refused(.unreadable(.platform)), #"{"file":"platform","reason":"unreadable","type":"refused"}"#),
            (.refused(.versionExhausted(.preferences)), #"{"file":"preferences","reason":"version_exhausted","type":"refused"}"#),
            (.refused(.invalidContent), #"{"reason":"invalid_content","type":"refused"}"#),
            (.refused(.busy), #"{"reason":"busy","type":"refused"}"#),
            (.adopted(.superseded), #"{"apply":"superseded","type":"adopted"}"#),
            (.adopted(.held(.runtime, .startBlocking)), #"{"apply":"held","input":"runtime","reason":"start_blocking","type":"adopted"}"#),
            (.adopted(.held(.unit, .uncommitted)), #"{"apply":"held","input":"unit","reason":"uncommitted","type":"adopted"}"#),
            (.adopted(.held(.unit, .stopFenced)), #"{"apply":"held","input":"unit","reason":"stop_fenced","type":"adopted"}"#),
            (.adopted(.reconcileAttempted(currentAtEnd: false)), #"{"apply":"reconcile_attempted","currentAtEnd":false,"type":"adopted"}"#),
        ]
        for (result, text) in shapes {
            XCTAssertEqual(try encoded(result), text)
            XCTAssertEqual(try decode(ControlReloadResult.self, text), result, text)
        }
        let allowed: Set<String> = ["type", "reason", "file", "apply", "input", "currentAtEnd"]
        for result in everyControlReloadResult() {
            XCTAssertTrue(try keys(of: result).isSubset(of: allowed), "\(result)")
            XCTAssertEqual(try decode(ControlReloadResult.self, try encoded(result)), result)
        }
    }

    /// Missing keys, a known key of another case, an unknown discriminator or reason, and a hold a reload never produces are each refused
    /// on decode; such a hold is refused on encode too. An unknown key is additive.
    func testMalformedAndInconsistentResultsAreRefused() throws {
        let refused = [
            #"{"type":"refused"}"#,
            #"{"type":"refused","reason":"unreadable"}"#,
            #"{"type":"refused","reason":"invalid_content","file":"runtime"}"#,
            #"{"type":"refused","reason":"busy","apply":"superseded"}"#,
            #"{"type":"refused","reason":"stale"}"#,
            #"{"type":"adopted"}"#,
            #"{"type":"adopted","apply":"held","input":"unit"}"#,
            #"{"type":"adopted","apply":"held","reason":"stop_fenced"}"#,
            #"{"type":"adopted","apply":"held","input":"runtime","reason":"uncommitted"}"#,
            #"{"type":"adopted","apply":"held","input":"unit","reason":"stale_revision"}"#,
            #"{"type":"adopted","apply":"held","input":"platform","reason":"start_blocking"}"#,
            #"{"type":"adopted","apply":"reconcile_attempted"}"#,
            #"{"type":"adopted","apply":"superseded","currentAtEnd":true}"#,
            #"{"type":"adopted","apply":"superseded","reason":"busy"}"#,
            #"{"type":"adopted","apply":"reconcile_attempted","currentAtEnd":true,"input":"unit"}"#,
            #"{"type":"adopted","apply":"applied"}"#,
            #"{"type":"done"}"#,
        ]
        for text in refused {
            XCTAssertThrowsError(try decode(ControlReloadResult.self, text), text)
        }
        XCTAssertEqual(try decode(ControlReloadResult.self, #"{"type":"adopted","apply":"superseded","future":{"x":1}}"#), .adopted(.superseded))
        XCTAssertThrowsError(try JSONEncoder().encode(ControlReloadResult.adopted(.held(.unit, .staleRevision))))
        XCTAssertThrowsError(try JSONEncoder().encode(ControlReloadResult.adopted(.held(.runtime, .uncommitted))))
    }

    // MARK: - Pairing and compatibility

    func testAReloadCompletesOnlyWithItsOwnResult() throws {
        let revision = try XCTUnwrap(ControlPresentationRevision(rawValue: 3))
        let completion = try ControlCompletion(command: .reload, presentationRevision: revision, result: .reload(.adopted(.superseded)))
        XCTAssertEqual(
            try encoded(completion),
            #"{"command":"reload","presentationRevision":3,"result":{"reload":{"apply":"superseded","type":"adopted"},"type":"reload"}}"#
        )
        XCTAssertEqual(try decode(ControlCompletion.self, try encoded(completion)), completion)
        XCTAssertThrowsError(try ControlCompletion(command: .reload, presentationRevision: revision, result: .settled))
        XCTAssertThrowsError(try ControlCompletion(command: .stop, presentationRevision: revision, result: .reload(.refused(.busy))))
        XCTAssertThrowsError(try decode(ControlCompletion.self, #"{"command":"reload","presentationRevision":3,"result":{"type":"settled"}}"#))
        XCTAssertThrowsError(try decode(ControlCompletion.self, #"{"command":"quit","presentationRevision":3,"result":{"type":"reload","reload":{"type":"refused","reason":"busy"}}}"#))
    }

    /// The workflow event's refusal now shares the result's spelling; its bytes and its leniency are as before.
    func testTheWorkflowEventsRefusalSpellingIsUnchanged() throws {
        let unreadable = ControlConfigWorkflowEvent.observed(phase: .reload, observation: .refused(.unreadable(.runtime)))
        XCTAssertEqual(try encoded(unreadable), #"{"file":"runtime","outcome":"refused","phase":"reload","reason":"unreadable","type":"observed"}"#)
        let busy = ControlConfigWorkflowEvent.observed(phase: .startup, observation: .refused(.busy))
        XCTAssertEqual(try encoded(busy), #"{"outcome":"refused","phase":"startup","reason":"busy","type":"observed"}"#)
        XCTAssertEqual(
            try decode(ControlConfigWorkflowEvent.self, #"{"type":"observed","phase":"reload","outcome":"refused","reason":"invalid_content","file":"runtime"}"#),
            .observed(phase: .reload, observation: .refused(.invalidContent)),
            "the event keeps ignoring a file a fileless reason does not name"
        )
        XCTAssertThrowsError(try decode(ControlConfigWorkflowEvent.self, #"{"type":"observed","phase":"reload","outcome":"refused","reason":"version_exhausted"}"#))
    }
}

/// Every reload answer the wire carries: each refusal with each file it may name, and each adopted apply with every hold a reload
/// produces and both ends of a reconcile attempt. The sizing evidence measures the widest of them.
func everyControlReloadResult() -> [ControlReloadResult] {
    var results: [ControlReloadResult] = [.refused(.invalidContent), .refused(.journalPresenceUnknown), .refused(.unexpected), .refused(.busy)]
    for file in ControlConfigWorkflowFile.allCases {
        results += [.refused(.unreadable(file)), .refused(.versionExhausted(file))]
    }
    results += [.adopted(.superseded), .adopted(.reconcileAttempted(currentAtEnd: false)), .adopted(.reconcileAttempted(currentAtEnd: true))]
    for input in ControlConfigWorkflowHeldInput.allCases {
        for reason in ControlConfigWorkflowHoldReason.allCases
        where ControlConfigWorkflowEvent.isValidHeld(phase: .reload, input: input, reason: reason) {
            results.append(.adopted(.held(input, reason)))
        }
    }
    return results
}
