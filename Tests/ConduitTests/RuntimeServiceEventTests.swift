// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import RuntimeEvents
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The typed `runtime_service.*` family (#180): every value round-trips through the domain and the wire, keeps the untyped record's
/// `health` kind, name and detail, and an unknown fault, reason or type is refused rather than read as another value.
final class RuntimeServiceEventTests: XCTestCase {
    private static let domainValues: [RuntimeServiceEvent] = RuntimeServiceFault.allCases.map { .fault($0) }
        + RuntimeServiceSnapshotUnavailableReason.allCases.map { .snapshotUnavailable($0) }

    func testEveryValueMirrorsItsNameDetailAndRoundTripsThroughTheClassifier() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in Self.domainValues {
            let wire = ControlRuntimeServiceEvent(value)
            XCTAssertEqual(wire.name, value.name)
            XCTAssertEqual(wire.detail, value.detail)
            XCTAssertTrue(ControlRuntimeServiceEvent.knownEventNames.contains(wire.name), wire.name)

            let event = RuntimeEvent(payload: .runtimeService(value))
            XCTAssertEqual(event.kind, .health)
            XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(value.name), value.name)
            XCTAssertTrue(RuntimeEventPayload.typedNames.contains(value.name), value.name)

            let domainData = try encoder.encode(RuntimeEventPayload.runtimeService(value))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: domainData), .runtimeService(value))
            let wireData = try encoder.encode(ControlTypedRuntimeEvent.runtimeService(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: wireData), .runtimeService(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: domainData), .runtimeService(wire))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: wireData), .runtimeService(value))
            let record = ControlRuntimeEvent(event)
            XCTAssertEqual(record.kind, "health")
            XCTAssertEqual(try decoder.decode(ControlRuntimeEventRecord.self, from: encoder.encode(record)), .known(record))
            XCTAssertEqual(try decoder.decode(RuntimeEvent.self, from: encoder.encode(event)).typed, .runtimeService(value))
        }
        // The two closed sets keep one spelling each, so no case is collapsed into another on the wire.
        XCTAssertEqual(Set(RuntimeServiceFault.allCases.map(\.rawValue)), Set(ControlRuntimeServiceFault.allCases.map(\.rawValue)))
        XCTAssertEqual(
            Set(RuntimeServiceSnapshotUnavailableReason.allCases.map(\.rawValue)),
            Set(ControlRuntimeServiceSnapshotReason.allCases.map(\.rawValue))
        )
        // A frozen record pins the family spelling and the untyped detail even if both mirrors were renamed together.
        let golden = Data(#"{"timestamp":0,"kind":"health","event":"runtime_service.fault","detail":"fault=snapshot_over_bound","typed":{"family":"runtime_service","runtimeService":{"type":"fault","fault":"snapshot_over_bound"}}}"#.utf8)
        let expected = ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "health", event: "runtime_service.fault",
                                           detail: "fault=snapshot_over_bound", typed: .runtimeService(.fault(.snapshotOverBound)))
        XCTAssertEqual(try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeEventRecord.self, from: golden), .known(expected))
        // The v1 record these names carried before they were typed still decodes, with no typed value.
        let legacy = Data(#"{"timestamp":0,"kind":"health","event":"runtime_service.snapshot_unavailable","detail":"reason=revision_exhausted"}"#.utf8)
        let untyped = try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeEventRecord.self, from: legacy)
        guard case .known(let known) = untyped else { return XCTFail("a v1 record is always known: \(untyped)") }
        XCTAssertNil(known.typed)
        XCTAssertNil(try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: legacy).typed)
    }

    func testAnUnknownOrMalformedValueIsRefused() throws {
        let decoder = JSONDecoder()
        let invalid: [String] = [
            #"{"type":"fault","fault":"raw_error"}"#,
            #"{"type":"fault"}"#,
            #"{"type":"fault","reason":"projection_failed"}"#,
            #"{"type":"snapshot_unavailable","reason":"timed_out"}"#,
            #"{"type":"snapshot_unavailable","fault":"snapshot_over_bound"}"#,
            #"{"type":"degraded","reason":"projection_failed"}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try decoder.decode(ControlRuntimeServiceEvent.self, from: Data(json.utf8)), json)
            XCTAssertThrowsError(try decoder.decode(RuntimeServiceEvent.self, from: Data(json.utf8)), json)
        }
        let codec = ControlRuntimeCodec.makeDecoder()
        // A known name with a payload this build cannot read, or one that disagrees with its outer fields, is corruption.
        let corrupt: [String] = [
            #"{"timestamp":0,"kind":"health","event":"runtime_service.fault","detail":"fault=other","typed":{"family":"runtime_service","runtimeService":{"type":"other"}}}"#,
            #"{"timestamp":0,"kind":"config","event":"runtime_service.fault","detail":"fault=snapshot_over_bound","typed":{"family":"runtime_service","runtimeService":{"type":"fault","fault":"snapshot_over_bound"}}}"#,
            #"{"timestamp":0,"kind":"health","event":"runtime_service.fault","detail":"fault=outcome_not_encodable","typed":{"family":"runtime_service","runtimeService":{"type":"fault","fault":"snapshot_over_bound"}}}"#,
        ]
        for json in corrupt {
            XCTAssertThrowsError(try codec.decode(ControlRuntimeEventRecord.self, from: Data(json.utf8)), json)
        }
        // A future type under an unknown name is displayed as unknown, and its payload is discarded.
        let future = Data(#"{"timestamp":0,"kind":"health","event":"runtime_service.later","detail":"x=1","typed":{"family":"runtime_service","runtimeService":{"type":"later"}}}"#.utf8)
        guard case .unknown(let display) = try codec.decode(ControlRuntimeEventRecord.self, from: future) else {
            return XCTFail("a future runtime_service type with an unknown name is displayed, not decoded")
        }
        XCTAssertEqual(display.event, "runtime_service.later")
    }
}
