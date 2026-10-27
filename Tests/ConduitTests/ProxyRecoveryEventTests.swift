// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import RuntimeEvents
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The typed `proxy_recovery.*` family: every value round-trips through the domain and the wire with the `health` kind and a detail
/// derived from its closed fields only, the namespace refuses an untyped record, and an unknown or malformed value is refused rather
/// than read as another value.
final class ProxyRecoveryEventTests: XCTestCase {
    private static let domainValues: [ProxyRecoveryEvent] = [
        .recovered, .failed(authenticationLikely: false), .failed(authenticationLikely: true),
    ]

    func testEveryValueMirrorsItsNameDetailAndRoundTripsThroughTheClassifier() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in Self.domainValues {
            let wire = ControlProxyRecoveryEvent(value)
            XCTAssertEqual(wire.name, value.name)
            XCTAssertEqual(wire.detail, value.detail)
            XCTAssertTrue(ControlProxyRecoveryEvent.knownEventNames.contains(wire.name), wire.name)

            let event = RuntimeEvent(payload: .proxyRecovery(value))
            XCTAssertEqual(event.kind, .health)
            XCTAssertEqual(event.event, value.name)
            XCTAssertEqual(event.detail, value.detail, "the derived detail is a sanitizer fixed point")
            XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(value.name), value.name)
            XCTAssertTrue(RuntimeEventPayload.typedNames.contains(value.name), value.name)

            let domainData = try encoder.encode(RuntimeEventPayload.proxyRecovery(value))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: domainData), .proxyRecovery(value))
            let wireData = try encoder.encode(ControlTypedRuntimeEvent.proxyRecovery(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: wireData), .proxyRecovery(wire))
            XCTAssertEqual(try decoder.decode(ControlTypedRuntimeEvent.self, from: domainData), .proxyRecovery(wire))
            XCTAssertEqual(try decoder.decode(RuntimeEventPayload.self, from: wireData), .proxyRecovery(value))
            let record = ControlRuntimeEvent(event)
            XCTAssertEqual(record.kind, "health")
            XCTAssertEqual(record.typed, .proxyRecovery(wire))
            XCTAssertEqual(try decoder.decode(ControlRuntimeEventRecord.self, from: encoder.encode(record)), .known(record))
            let line = try CanonicalJSON.encoder().encode(event)
            XCTAssertEqual(try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: line).typed, .proxyRecovery(value))
        }
        XCTAssertEqual(Set(Self.domainValues.map(\.name)), Set(ProxyRecoveryEventName.allCases.map(\.rawValue)))
        XCTAssertEqual(ControlProxyRecoveryEvent.knownEventNames, Set(ProxyRecoveryEventName.allCases.map(\.rawValue)))
        XCTAssertEqual(ControlProxyRecoveryEvent.knownWireTypes, ["recovered", "failed"])

        // Frozen records pin the family spelling, the key and the derived detail even if both mirrors were renamed together.
        let codec = ControlRuntimeCodec.makeDecoder()
        let failed = Data(#"{"timestamp":0,"kind":"health","event":"proxy_recovery.failed","detail":"outcome=failed authentication_likely=true","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"failed","authentication_likely":true}}}"#.utf8)
        XCTAssertEqual(try codec.decode(ControlRuntimeEventRecord.self, from: failed), .known(ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 0), kind: "health", event: "proxy_recovery.failed",
            detail: "outcome=failed authentication_likely=true", typed: .proxyRecovery(.failed(authenticationLikely: true))
        )))
        XCTAssertEqual(try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: failed).typed,
                       .proxyRecovery(.failed(authenticationLikely: true)))
        let recovered = Data(#"{"timestamp":0,"kind":"health","event":"proxy_recovery.recovered","detail":"outcome=recovered","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"recovered"}}}"#.utf8)
        XCTAssertEqual(try codec.decode(ControlRuntimeEventRecord.self, from: recovered), .known(ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 0), kind: "health", event: "proxy_recovery.recovered",
            detail: "outcome=recovered", typed: .proxyRecovery(.recovered)
        )))
    }

    func testAnUnknownOrMalformedValueIsRefused() throws {
        let decoder = JSONDecoder()
        let invalid: [String] = [
            #"{"type":"failed"}"#,
            #"{"type":"failed","authentication_likely":"true"}"#,
            #"{"type":"failed","authentication_likely":1}"#,
            #"{"type":"failed","authentication_likely":null}"#,
            #"{"type":"recovered","authentication_likely":false}"#,
            #"{"type":"partial"}"#,
            #"{"authentication_likely":true}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try decoder.decode(ControlProxyRecoveryEvent.self, from: Data(json.utf8)), json)
            XCTAssertThrowsError(try decoder.decode(ProxyRecoveryEvent.self, from: Data(json.utf8)), json)
        }
        let codec = ControlRuntimeCodec.makeDecoder()
        // A known name with a payload this build cannot read, or one that disagrees with its outer fields, is corruption.
        let corrupt: [String] = [
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.failed","detail":"x","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"partial"}}}"#,
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.failed","detail":"outcome=failed authentication_likely=true","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"failed"}}}"#,
            #"{"timestamp":0,"kind":"config","event":"proxy_recovery.recovered","detail":"outcome=recovered","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"recovered"}}}"#,
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.failed","detail":"outcome=failed authentication_likely=false","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"failed","authentication_likely":true}}}"#,
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.recovered","detail":"outcome=failed authentication_likely=false","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"failed","authentication_likely":false}}}"#,
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.later","detail":"outcome=recovered","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"recovered"}}}"#,
            #"{"timestamp":0,"kind":"health","event":"proxy_recovery.recovered","detail":"outcome=recovered","typed":{"family":"proxy_recovery"}}"#,
        ]
        for json in corrupt {
            XCTAssertThrowsError(try codec.decode(ControlRuntimeEventRecord.self, from: Data(json.utf8)), json)
            XCTAssertThrowsError(try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(json.utf8)), json)
        }
        // A future type under an unknown name is displayed as unknown, and its payload is discarded.
        let future = Data(#"{"timestamp":0,"kind":"health","event":"proxy_recovery.later","detail":"x=1","typed":{"family":"proxy_recovery","proxyRecovery":{"type":"later","summary":"Proxy rejected"}}}"#.utf8)
        guard case .unknown(let display) = try codec.decode(ControlRuntimeEventRecord.self, from: future) else {
            return XCTFail("a future proxy_recovery type with an unknown name is displayed, not decoded")
        }
        XCTAssertEqual(display.event, "proxy_recovery.later")
    }

    /// The namespace is closed with no untyped exception, while the ladder's step names keep their legacy envelope. The names are built
    /// here, so the check does not depend on a literal the catalogue gate reads.
    func testTheProxyRecoveryNamespaceNeedsATypedValueAndTheLegacyStepsDoNot() {
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(["proxy_recovery", "recovered"].joined(separator: ".")))
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(["proxy_recovery", "partial"].joined(separator: ".")), "a future spelling")
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(["proxy_recovery", "failed", "extra"].joined(separator: ".")))
        for legacy in ["recovery.exhausted", "recovery.cooldown_started", "recovery.cooldown_cleared", "recovery.abandoned",
                       "recovery.step_skipped", "recovery.suppressed", "recovery.skipped", "proxy.listener_recycle_skipped"] {
            XCTAssertFalse(RuntimeEventPayload.requiresTypedPayload(legacy), legacy)
        }
        XCTAssertFalse(RuntimeEventPayload.requiresTypedPayload("proxy_recovery"), "a family, not an event name")
    }
}
