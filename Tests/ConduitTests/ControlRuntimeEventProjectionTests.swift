// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import ProxyControlBridge
import RuntimeEvents
import XCTest
@testable import ProxyKernel

/// The control wire's projection of typed runtime events (decision 0013). The
/// bridge maps every domain value exhaustively; these tests pin the spelling on
/// each side and the agreement between the file's JSON and the wire's.
final class ControlRuntimeEventProjectionTests: XCTestCase {

    func testEveryOperationProjectsToItsLegacySpelling() throws {
        for operation in LifecycleOperation.allCases {
            let event = RuntimeEvent(payload: .lifecycle(.coalesced(LifecycleCoalesced(operation: operation, joined: 7))))
            let projected = ControlRuntimeEvent(event)
            let expected = try XCTUnwrap(ControlLifecycleOperation(rawValue: operation.rawValue))
            XCTAssertEqual(projected.typed, .lifecycle(.coalesced(operation: expected, joined: 7)))
            XCTAssertEqual(projected.kind, "lifecycle")
            XCTAssertEqual(projected.event, "lifecycle.coalesced")
            XCTAssertEqual(projected.detail, "operation=\(operation.rawValue) joined=7", "golden: the human line is unchanged")
        }
    }

    func testEveryReasonAndTheDrainProjectToTheirWireValues() throws {
        for reason in LifecycleSupersessionReason.allCases {
            let event = RuntimeEvent(payload: .lifecycle(.superseded(LifecycleSuperseded(
                operation: .proxyStart, generation: 1, current: 2, reason: reason
            ))))
            let expected = try XCTUnwrap(ControlLifecycleReason(rawValue: reason.rawValue))
            XCTAssertEqual(
                ControlRuntimeEvent(event).typed,
                .lifecycle(.superseded(operation: .proxyStart, generation: 1, current: 2, reason: expected))
            )
        }
        let drain = RuntimeEvent(payload: .lifecycle(.terminationDrainExpired(LifecycleTerminationDrainExpired(deadlineMilliseconds: 200))))
        XCTAssertEqual(ControlRuntimeEvent(drain).typed, .lifecycle(.terminationDrainExpired(deadlineMilliseconds: 200)))
        XCTAssertEqual(ControlRuntimeEvent(drain).event, "lifecycle.termination_drain_expired")
        let version = RuntimeEvent(payload: .lifecycle(.versionChanged(LifecycleVersionChanged(from: "0.4.1", to: "0.5.0"))))
        XCTAssertEqual(ControlRuntimeEvent(version).typed, .lifecycle(.versionChanged(from: "0.4.1", to: "0.5.0")))
        XCTAssertEqual(ControlRuntimeEvent(version).event, "lifecycle.version_changed")
        XCTAssertEqual(ControlRuntimeEvent(version).detail, "from=0.4.1 to=0.5.0")
    }

    func testAFileLineDecodesOnTheControlWireToTheProjectionOfTheSameEvent() throws {
        let event = RuntimeEvent(payload: .lifecycle(.superseded(LifecycleSuperseded(
            operation: .runtimeStart, generation: 1, current: 2, reason: .runtimeDown
        ))))
        let line = try CanonicalJSON.encoder().encode(event)
        // `pmctl` reads `events.ndjson` with this decoder.
        let pmctlDecoder = JSONDecoder()
        pmctlDecoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try pmctlDecoder.decode(ControlRuntimeEvent.self, from: line)
        let projected = ControlRuntimeEvent(event)
        // Epoch seconds in a Double can move the last bit on a round trip; the file is exact to the microsecond.
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, projected.timestamp.timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(decoded.kind, projected.kind)
        XCTAssertEqual(decoded.event, projected.event)
        XCTAssertEqual(decoded.detail, projected.detail)
        XCTAssertEqual(decoded.typed, projected.typed)
        XCTAssertNotNil(decoded.typed, "the wire reads the typed field")
    }

    func testAPreTypedLineStillDecodesWithoutATypedValue() throws {
        let line = Data(#"{"detail":"operation=proxy_start generation=1 current=2 reason=superseded","event":"lifecycle.superseded","kind":"lifecycle","timestamp":1700000000}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ControlRuntimeEvent.self, from: line)
        XCTAssertEqual(decoded.event, "lifecycle.superseded")
        XCTAssertEqual(decoded.detail, "operation=proxy_start generation=1 current=2 reason=superseded")
        XCTAssertNil(decoded.typed)
    }

    func testAHistoricalVersionChangeLineDecodesWithoutATypedValue() throws {
        let line = Data(#"{"detail":"from=0.4.1 to=0.5.0","event":"lifecycle.version_changed","kind":"lifecycle","timestamp":1700000000}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ControlRuntimeEvent.self, from: line)
        XCTAssertEqual(decoded.event, "lifecycle.version_changed")
        XCTAssertEqual(decoded.detail, "from=0.4.1 to=0.5.0")
        XCTAssertNil(decoded.typed)
    }

    func testAMalformedWirePayloadThrows() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let rejected = [
            // generation zero
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.superseded","typed":{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":0,"current":2,"reason":"superseded"}}}"#,
            // an operation the wire does not spell
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.coalesced","typed":{"family":"lifecycle","lifecycle":{"type":"coalesced","operation":"proxy_flip","joined":2}}}"#,
            // an unknown family
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.superseded","typed":{"family":"config","lifecycle":{}}}"#,
            // a version change missing its `to`
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.version_changed","typed":{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"0.4.1"}}}"#,
            // a companion on a module other than DNS
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.module_settled","detail":"module=proxy source=conditional outcome=started group=1","typed":{"family":"lifecycle","lifecycle":{"type":"module_settled","module":"proxy","source":"conditional","outcome":"started","group":1}}}"#,
            // an explicit member with a companion's result
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.module_settled","detail":"module=tunnels source=explicit outcome=already_active group=1","typed":{"family":"lifecycle","lifecycle":{"type":"module_settled","module":"tunnels","source":"explicit","outcome":"already_active","group":1}}}"#,
            // a settlement in group zero
            #"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.module_settled","detail":"module=dns source=explicit outcome=failed group=0","typed":{"family":"lifecycle","lifecycle":{"type":"module_settled","module":"dns","source":"explicit","outcome":"failed","group":0}}}"#,
        ]
        for line in rejected {
            XCTAssertThrowsError(try decoder.decode(ControlRuntimeEvent.self, from: Data(line.utf8)), line)
        }
    }

    /// The domain's and the wire's numeric rules are separate copies. They must agree on every
    /// value in a small grid, including the boundaries and `runtime_down` with equal generations.
    func testTheWireAndTheDomainAgreeOnEveryNumericInvariant() throws {
        for generation in -1...3 {
            for current in -1...4 {
                for reason in LifecycleSupersessionReason.allCases {
                    let wire = try XCTUnwrap(ControlLifecycleReason(rawValue: reason.rawValue))
                    XCTAssertEqual(
                        LifecycleSuperseded.isValid(generation: generation, current: current, reason: reason),
                        ControlLifecycleEvent.isValidSuperseded(generation: generation, current: current, reason: wire),
                        "generation \(generation), current \(current), \(reason.rawValue)"
                    )
                }
            }
        }
        for joined in -1...2 {
            XCTAssertEqual(LifecycleCoalesced.isValid(joined: joined), ControlLifecycleEvent.isValidCoalesced(joined: joined))
        }
        for deadline in -1...1 {
            XCTAssertEqual(
                LifecycleTerminationDrainExpired.isValid(deadlineMilliseconds: deadline),
                ControlLifecycleEvent.isValidTerminationDrain(deadlineMilliseconds: deadline)
            )
        }
    }

    /// Every spellable settlement projects to the wire value with the same module, source and outcome spelling, and the two copies of
    /// the settlement rule agree on it at every group in a small grid.
    func testEverySettlementProjectsAndTheWireAndTheDomainAgreeOnItsRule() throws {
        for settlement in LifecycleModuleSettlement.everySpelling {
            let wire = ControlLifecycleSettlement(settlement)
            XCTAssertEqual(wire.module.rawValue, settlement.module.rawValue)
            XCTAssertEqual(wire.source, settlement.source)
            XCTAssertEqual(wire.outcome, settlement.outcome)
            for group in -1...2 {
                XCTAssertEqual(
                    LifecycleModuleSettled.isValid(settlement: settlement, group: group),
                    ControlLifecycleEvent.isValidModuleSettled(settlement: wire, group: group),
                    "\(settlement) group \(group)"
                )
            }
            guard LifecycleModuleSettled.isValid(settlement: settlement, group: 1) else { continue }
            let projected = ControlRuntimeEvent(RuntimeEvent(payload: .lifecycle(.moduleSettled(
                LifecycleModuleSettled(settlement: settlement, group: 1)
            ))))
            XCTAssertEqual(projected.typed, .lifecycle(.moduleSettled(settlement: wire, group: 1)))
            XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEvent.self, from: JSONEncoder().encode(projected)), projected)
        }
        XCTAssertEqual(ControlLifecycleModuleResult.allCases.map(\.rawValue), LifecycleModuleStartResult.allCases.map(\.rawValue))
        XCTAssertEqual(ControlLifecycleConditionalDNSResult.allCases.map(\.rawValue), LifecycleConditionalDNSResult.allCases.map(\.rawValue))
    }

    /// The version grammar and the pair rule are a second copy on each side. Pairs over a grid of boundaries,
    /// bearer-shaped and near-miss tokens, separators, non-ASCII bytes and a credential-looking token must agree.
    func testTheWireAndTheDomainAgreeOnEveryVersionGrammarValue() {
        let versions = [
            "", "a", "0.5.8", "0.5.8-rc.1+7", "unbundled", "A_b.c-d+e",
            "a:b", "a/b", "a=b", "a b", "a\"b", "\u{E9}", "token=abc123",
        ] + LifecycleVersionFixtures.grammar + LifecycleVersionFixtures.overBound
        for from in versions {
            for to in versions {
                XCTAssertEqual(
                    LifecycleVersionChanged.isValid(from: from, to: to),
                    ControlLifecycleEvent.isValidVersionChange(from: from, to: to),
                    "from \(from), to \(to)"
                )
            }
        }
    }

    /// A `from` that reads as a bearer credential throws on read and on write, while the same token is a
    /// valid `to`. The outer detail is the rendered line, so the record is the one the sanitizer would rewrite.
    func testTheWireRefusesABearerShapedFromOnReadAndWrite() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let encoder = JSONEncoder()
        for token in LifecycleVersionFixtures.bearerFrom {
            let typed = #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"\#(token)","to":"0.5.0"}}"#
            let line = Data(#"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.version_changed","detail":"from=\#(token) to=0.5.0","typed":\#(typed)}"#.utf8)
            XCTAssertThrowsError(try decoder.decode(ControlRuntimeEvent.self, from: line), token)
            XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.versionChanged(from: token, to: "0.5.0")), token)
            XCTAssertNoThrow(try encoder.encode(ControlLifecycleEvent.versionChanged(from: "0.4.1", to: token)), token)
        }
    }

    /// Lifecycle names and types retain their wire spelling, and encoded records traverse the classifier as known events.
    func testTheKnownVocabularyIsWhatTheWireWrites() throws {
        XCTAssertEqual(
            ControlLifecycleEvent.knownWireTypes,
            ["superseded", "coalesced", "termination_drain_expired", "version_changed", "module_settled"]
        )
        XCTAssertEqual(ControlLifecycleEvent.knownEventNames, Set(LifecycleEventName.allCases.map(\.rawValue)))
        let values: [ControlLifecycleEvent] = [
            .superseded(operation: .proxyStart, generation: 1, current: 2, reason: .superseded),
            .coalesced(operation: .dnsStop, joined: 2),
            .terminationDrainExpired(deadlineMilliseconds: 200),
            .versionChanged(from: "0.4.1", to: "0.5.0"),
            .moduleSettled(settlement: .explicit(.tunnels, .failed), group: 3),
            .moduleSettled(settlement: .conditionalDNS(.fenced), group: 1),
        ]
        for value in values {
            XCTAssertTrue(ControlLifecycleEvent.knownEventNames.contains(value.name), value.name)
            let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ControlTypedRuntimeEvent.lifecycle(value)))
            let object = try XCTUnwrap(written as? [String: Any])
            let record = ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "lifecycle", event: value.name,
                                             detail: value.detail, typed: .lifecycle(value))
            XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEventRecord.self, from: JSONEncoder().encode(record)), .known(record))
            let lifecycle = try XCTUnwrap(object["lifecycle"] as? [String: Any])
            XCTAssertTrue(ControlLifecycleEvent.knownWireTypes.contains(try XCTUnwrap(lifecycle["type"] as? String)))
        }
    }

    func testTheWireCarriesTheSameNameKindAndDetailAsTheDomain() {
        let values: [LifecycleEvent] = [
            .superseded(LifecycleSuperseded(operation: .runtimeStop, generation: 3, current: 4, reason: .runtimeDown)),
            .superseded(LifecycleSuperseded(operation: .proxyStart, generation: 2, current: 2, reason: .runtimeDown)),
            .coalesced(LifecycleCoalesced(operation: .dnsStop, joined: 2)),
            .terminationDrainExpired(LifecycleTerminationDrainExpired(deadlineMilliseconds: 200)),
            .versionChanged(LifecycleVersionChanged(from: "0.4.1", to: "0.5.8-rc.1+7")),
        ] + LifecycleModuleSettlement.everySpelling.filter { LifecycleModuleSettled.isValid(settlement: $0, group: 2) }.map {
            LifecycleEvent.moduleSettled(LifecycleModuleSettled(settlement: $0, group: 2))
        }
        for value in values {
            let domain = RuntimeEvent(payload: .lifecycle(value))
            let projected = ControlRuntimeEvent(domain)
            let typed = ControlTypedRuntimeEvent(RuntimeEventPayload.lifecycle(value))
            XCTAssertEqual(projected.typed, typed)
            XCTAssertEqual(typed.kind, projected.kind)
            XCTAssertEqual(typed.name, projected.event)
            XCTAssertEqual(typed.detail, projected.detail)
            XCTAssertEqual(projected.detail, domain.detail)
        }
    }

    /// The outer record must agree with the typed value it carries. A contradiction in
    /// any of the three fields, or a malformed known payload, throws; a consistent record decodes.
    func testAWireRecordWhoseTypedValueContradictsItsOuterFieldsThrows() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let superseded = #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":1,"current":2,"reason":"superseded"}}"#
        let consistentDetail = "operation=proxy_start generation=1 current=2 reason=superseded"
        func line(kind: String = "lifecycle", event: String = "lifecycle.superseded", detail: String = consistentDetail, typed: String) -> Data {
            Data(#"{"timestamp":1700000000,"kind":"\#(kind)","event":"\#(event)","detail":"\#(detail)","typed":\#(typed)}"#.utf8)
        }

        let consistent = try decoder.decode(ControlRuntimeEvent.self, from: line(typed: superseded))
        XCTAssertEqual(consistent.typed, .lifecycle(.superseded(operation: .proxyStart, generation: 1, current: 2, reason: .superseded)))

        let rejected: [(label: String, line: Data)] = [
            ("a name that disagrees", line(event: "lifecycle.coalesced", typed: superseded)),
            ("a kind that disagrees", line(kind: "routing", typed: superseded)),
            ("a detail that disagrees", line(detail: "operation=proxy_start generation=9 current=9 reason=superseded", typed: superseded)),
            ("a typed null", line(typed: "null")),
            ("a superseded reason with no newer generation", line(
                detail: "operation=proxy_start generation=2 current=2 reason=superseded",
                typed: #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":2,"current":2,"reason":"superseded"}}"#
            )),
        ]
        for case_ in rejected {
            XCTAssertThrowsError(try decoder.decode(ControlRuntimeEvent.self, from: case_.line), case_.label)
        }
    }

    /// A version change reads only when its outer fields agree with it, and the typed values round-trip.
    func testAVersionChangeWhoseOuterFieldsContradictItThrows() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let typed = #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"0.4.1","to":"0.5.0"}}"#
        func line(detail: String) -> Data {
            Data(#"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.version_changed","detail":"\#(detail)","typed":\#(typed)}"#.utf8)
        }

        let consistent = try decoder.decode(ControlRuntimeEvent.self, from: line(detail: "from=0.4.1 to=0.5.0"))
        XCTAssertEqual(consistent.typed, .lifecycle(.versionChanged(from: "0.4.1", to: "0.5.0")))
        XCTAssertThrowsError(
            try decoder.decode(ControlRuntimeEvent.self, from: line(detail: "from=0.4.1 to=0.6.0")),
            "a detail that disagrees with the typed versions"
        )

        let contradictory = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "lifecycle",
            event: "lifecycle.version_changed",
            detail: "from=0.4.1 to=0.6.0",
            typed: .lifecycle(.versionChanged(from: "0.4.1", to: "0.5.0"))
        )
        XCTAssertThrowsError(try JSONEncoder().encode(contradictory), "a version change whose detail disagrees")

        let projected = ControlRuntimeEvent(RuntimeEvent(payload: .lifecycle(.versionChanged(
            LifecycleVersionChanged(from: "0.4.1", to: "0.5.8-rc.1+7")
        ))))
        let data = try JSONEncoder().encode(projected)
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEvent.self, from: data), projected)
    }

    /// The grammar holds on read as well: a crafted, empty or oversize version in a known
    /// payload throws, whatever the outer fields say.
    func testAnAbnormalVersionChangeThrowsOnRead() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let abnormal = [
            "token=abc123", "Bearer abc", "0.4.1 beta", "", "https://user:pw@host/x",
            String(repeating: "a", count: ControlLifecycleEvent.maximumVersionBytes + 1),
        ]
        for version in abnormal {
            let typed = #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"\#(version)","to":"0.5.0"}}"#
            let line = Data(#"{"timestamp":1700000000,"kind":"lifecycle","event":"lifecycle.version_changed","detail":"from=\#(version) to=0.5.0","typed":\#(typed)}"#.utf8)
            XCTAssertThrowsError(try decoder.decode(ControlRuntimeEvent.self, from: line), version)
        }
    }

    /// Writing refuses the values reading refuses, and a contradictory outer record.
    func testTheWireRefusesToWriteAValueItWouldNotRead() throws {
        let encoder = JSONEncoder()
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.superseded(
            operation: .proxyStart, generation: 0, current: 0, reason: .superseded
        )), "generation zero")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.superseded(
            operation: .proxyStart, generation: 2, current: 2, reason: .superseded
        )), "a superseded reason with no newer generation")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.coalesced(operation: .dnsStop, joined: 0)))
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.terminationDrainExpired(deadlineMilliseconds: -1)))
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.versionChanged(from: "token=abc123", to: "0.5.0")), "a version outside the grammar")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.versionChanged(from: "0.4.1", to: "")), "an empty version")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.versionChanged(
            from: "0.4.1", to: String(repeating: "a", count: ControlLifecycleEvent.maximumVersionBytes + 1)
        )), "a version one byte past the bound")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.moduleSettled(settlement: .explicit(.dns, .started), group: 0)),
                             "a settlement in group zero")
        XCTAssertThrowsError(try encoder.encode(ControlLifecycleEvent.moduleSettled(settlement: .explicit(.proxy, .notConfigured), group: 1)),
                             "a proxy member that is not configured")
        let contradictory = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "lifecycle",
            event: "lifecycle.coalesced",
            detail: "deadline_ms=1",
            typed: .lifecycle(.terminationDrainExpired(deadlineMilliseconds: 1))
        )
        XCTAssertThrowsError(try encoder.encode(contradictory), "a typed value its outer fields contradict")
    }

    /// A legacy event keeps the v1 layout: no `typed` key, and the same fields on the way back.
    func testALegacyEventStillWritesTheV1LayoutWithoutATypedKey() throws {
        let legacy = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: "routing", event: "routing.test", detail: "x"
        )
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("typed"))
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEvent.self, from: data), legacy)
    }

    func testATypedWireValueRoundTripsThroughItsOwnEncoding() throws {
        let projected = ControlRuntimeEvent(RuntimeEvent(payload: .lifecycle(.superseded(LifecycleSuperseded(
            operation: .runtimeStart, generation: 1, current: 1, reason: .runtimeDown
        )))))
        let data = try JSONEncoder().encode(projected)
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEvent.self, from: data), projected)
    }

    /// The wire's bound is the domain's, and every value the domain admits survives the wire: the projected
    /// detail is the typed line, and encoding then decoding returns the same record.
    func testEveryBoundaryVersionProjectsAndRoundTripsOnTheWire() throws {
        XCTAssertEqual(ControlLifecycleEvent.maximumVersionBytes, LifecycleVersionChanged.maximumVersionBytes)
        for from in LifecycleVersionFixtures.valid {
            for to in LifecycleVersionFixtures.valid {
                let change = LifecycleVersionChanged(from: from, to: to)
                let projected = ControlRuntimeEvent(RuntimeEvent(payload: .lifecycle(.versionChanged(change))))
                let shape = "from \(from.utf8.count) bytes, to \(to.utf8.count) bytes"
                XCTAssertEqual(projected.typed?.detail, projected.detail, shape)
                let data = try JSONEncoder().encode(projected)
                XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeEvent.self, from: data), projected, shape)
            }
        }
    }
}
