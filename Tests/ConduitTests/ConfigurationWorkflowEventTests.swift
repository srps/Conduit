// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import RuntimeEvents
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The typed `config.workflow.*` family (decisions 0031 and 0032): representative values round-trip through the domain and the
/// wire, the wire refuses the combinations the domain refuses, and the wire's name and detail match the domain's byte for byte.
final class ConfigurationWorkflowEventTests: XCTestCase {
    private static let domainValues: [ConfigurationWorkflowEvent] = [
        .observed(ConfigurationWorkflowObserved(phase: .startup, observation: .adopted)),
        .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.unreadable(.runtime)))),
        .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.versionExhausted(.preferences)))),
        .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.invalidContent))),
        .observed(ConfigurationWorkflowObserved(phase: .startup, observation: .refused(.busy))),
        .committed(ConfigurationWorkflowCommitted(file: .platform, write: .persisted(reportedError: true))),
        .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .unchanged)),
        .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notPersisted)),
        .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .unknown(.readbackDiffers, reportedError: false))),
        .committed(ConfigurationWorkflowCommitted(file: .platform, write: .conflict)),
        .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.superseded))),
        .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.heldBehindPlatform))),
        .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)),
        .held(ConfigurationWorkflowHeld(phase: .start, input: .runtime, reason: .heldBehind)),
        .held(ConfigurationWorkflowHeld(phase: .start, input: .platform, reason: .commitFailed)),
        .held(ConfigurationWorkflowHeld(phase: .reload, input: .runtime, reason: .startBlocking)),
        .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .uncommitted)),
        .superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: 3, current: 4)),
    ]

    /// Each domain value's wire mirror has the same name and detail, and decodes back to the mirror it encodes from.
    func testRepresentativeEventsMirrorTheirNameDetailAndRoundTripThroughTheClassifier() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in Self.domainValues {
            let wire = ControlConfigWorkflowEvent(value)
            XCTAssertEqual(wire.name, value.name)
            XCTAssertEqual(wire.detail, value.detail)
            XCTAssertTrue(ControlConfigWorkflowEvent.knownEventNames.contains(wire.name), wire.name)

            let domainData = try encoder.encode(RuntimeEventPayload.configWorkflow(value))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: domainData), .configWorkflow(value))
            let wireData = try encoder.encode(ControlTypedRuntimeEvent.configWorkflow(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: wireData), .configWorkflow(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: domainData), .configWorkflow(wire))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: wireData), .configWorkflow(value))
            let record = ControlRuntimeEvent(RuntimeEvent(payload: .configWorkflow(value)))
            XCTAssertEqual(try decoder.decode(ControlRuntimeEventRecord.self, from: encoder.encode(record)), .known(record))
        }
        // A frozen record pins the family spelling even if both mirrors were renamed together.
        let golden = Data(#"{"timestamp":0,"kind":"config","event":"config.workflow.held","detail":"phase=reload component=unit reason=stop_fenced","typed":{"family":"config_workflow","configWorkflow":{"type":"held","phase":"reload","component":"unit","reason":"stop_fenced"}}}"#.utf8)
        let expected = ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "config", event: "config.workflow.held",
                                           detail: "phase=reload component=unit reason=stop_fenced",
                                           typed: .configWorkflow(.held(phase: .reload, input: .unit, reason: .stopFenced)))
        XCTAssertEqual(try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeEventRecord.self, from: golden), .known(expected))
    }

    /// The typed envelope derives the record's kind from the family, and its name and detail from the value.
    func testTheEnvelopeDerivesConfigKindNameAndDetail() {
        for value in Self.domainValues {
            let event = RuntimeEvent(payload: .configWorkflow(value))
            XCTAssertEqual(event.kind, .config)
            XCTAssertEqual(event.event, value.name)
            XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(value.name), value.name)
        }
    }

    /// A stop fence holds only a reload's whole unit. A held runtime write belongs to a Start. Each refusal names the
    /// combination the domain refuses.
    func testTheWireRefusesCombinationsTheDomainRefuses() throws {
        let decoder = JSONDecoder()
        let invalid: [String] = [
            // An adopted observation carries no reason.
            #"{"type":"observed","phase":"startup","outcome":"adopted","reason":"busy"}"#,
            // A refusal names a reason.
            #"{"type":"observed","phase":"reload","outcome":"refused"}"#,
            // A Stop fence holds the whole unit, never one file.
            #"{"type":"held","phase":"start","component":"runtime","reason":"stop_fenced"}"#,
            // A runtime write is held behind a platform write only in a Start.
            #"{"type":"held","phase":"reload","component":"runtime","reason":"held_behind"}"#,
            // A commit can fail only in a Start.
            #"{"type":"held","phase":"reload","component":"platform","reason":"commit_failed"}"#,
            // Preferences never hold an apply.
            #"{"type":"held","phase":"reload","component":"preferences","reason":"uncommitted"}"#,
            // These reasons belong to a specific input or phase.
            #"{"type":"held","phase":"reload","component":"platform","reason":"start_blocking"}"#,
            #"{"type":"held","phase":"start","component":"unit","reason":"uncommitted"}"#,
            #"{"type":"held","phase":"reload","component":"unit","reason":"terminating"}"#,
            // A superseded generation is older than the latest.
            #"{"type":"superseded","phase":"start","generation":3,"current":3}"#,
            // An unknown write cause is refused.
            #"{"type":"committed","file":"runtime","outcome":"unknown","cause":"raw_error","reported_error":true}"#,
            // A not-attempted write without its cause is refused.
            #"{"type":"committed","file":"runtime","outcome":"not_attempted"}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try decoder.decode(ControlConfigWorkflowEvent.self, from: Data(json.utf8)), json)
            XCTAssertThrowsError(try decoder.decode(ConfigurationWorkflowEvent.self, from: Data(json.utf8)), json)
        }
    }

    /// The write a revoked or unresolved attempt reports keeps its closed cause, so it stays diagnosable.
    func testRevokedAndUnresolvedWritesKeepTheirClosedCause() {
        XCTAssertEqual(
            ConfigurationWorkflowEvent.committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.superseded))).detail,
            "file=runtime outcome=not_attempted cause=superseded"
        )
        XCTAssertEqual(
            ConfigurationWorkflowEvent.committed(
                ConfigurationWorkflowCommitted(file: .platform, write: .unknown(.readbackMissing, reportedError: true))
            ).detail,
            "file=platform outcome=unknown cause=readback_missing reported_error=true"
        )
    }

    /// A superseded value and a held value both refuse their impossible shapes at construction.
    func testTheConstructorsRefuseImpossibleShapes() {
        XCTAssertTrue(ConfigurationWorkflowHeld.isValid(phase: .reload, input: .unit, reason: .stopFenced))
        XCTAssertTrue(ConfigurationWorkflowHeld.isValid(phase: .start, input: .unit, reason: .stopFenced))
        XCTAssertFalse(ConfigurationWorkflowHeld.isValid(phase: .start, input: .runtime, reason: .stopFenced))
        XCTAssertFalse(ConfigurationWorkflowHeld.isValid(phase: .reload, input: .runtime, reason: .heldBehind))
        XCTAssertTrue(ConfigurationWorkflowSuperseded.isValid(phase: .start, generation: 1, current: 2))
        XCTAssertFalse(ConfigurationWorkflowSuperseded.isValid(phase: .start, generation: 0, current: 1))
        XCTAssertTrue(ConfigurationWorkflowSuperseded.isValid(phase: .reload, generation: 0, current: 1))
        XCTAssertFalse(ConfigurationWorkflowSuperseded.isValid(phase: .reload, generation: 2, current: 2))
    }
}
