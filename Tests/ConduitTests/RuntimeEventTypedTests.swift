// SPDX-License-Identifier: Apache-2.0
import Foundation
import RuntimeEvents
import XCTest
@testable import ProxyKernel

/// The typed `lifecycle.*` family (decision 0013): derived names, kinds and
/// details, the file encoding, compatibility with readers that predate `typed`,
/// and rejection of malformed known payloads.
final class RuntimeEventTypedTests: XCTestCase {

    /// Each typed value with the name and human line its legacy record carried.
    private let goldens: [(value: LifecycleEvent, name: String, detail: String)] = [
        (.superseded(LifecycleSuperseded(operation: .proxyStart, generation: 1, current: 2, reason: .superseded)),
         "lifecycle.superseded", "operation=proxy_start generation=1 current=2 reason=superseded"),
        (.superseded(LifecycleSuperseded(operation: .runtimeStop, generation: 3, current: 4, reason: .runtimeDown)),
         "lifecycle.superseded", "operation=runtime_stop generation=3 current=4 reason=runtime_down"),
        (.coalesced(LifecycleCoalesced(operation: .dnsStop, joined: 2)),
         "lifecycle.coalesced", "operation=dns_stop joined=2"),
        (.terminationDrainExpired(LifecycleTerminationDrainExpired(deadlineMilliseconds: 200)),
         "lifecycle.termination_drain_expired", "deadline_ms=200"),
        // `runtime_down` is recorded while the operation may still be the latest.
        (.superseded(LifecycleSuperseded(operation: .proxyStart, generation: 2, current: 2, reason: .runtimeDown)),
         "lifecycle.superseded", "operation=proxy_start generation=2 current=2 reason=runtime_down"),
        // The app's own launch record: the human line AppUpdates wrote before the typed field existed.
        (.versionChanged(LifecycleVersionChanged(from: "0.4.1", to: "0.5.0")),
         "lifecycle.version_changed", "from=0.4.1 to=0.5.0"),
        (.versionChanged(LifecycleVersionChanged(from: "0.5.8-rc.1+7", to: "unbundled")),
         "lifecycle.version_changed", "from=0.5.8-rc.1+7 to=unbundled"),
    ]

    private let superseded = #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":1,"current":2,"reason":"superseded"}}"#

    func testTypedEventsDeriveTheLegacyNameKindAndDetail() {
        for golden in goldens {
            let event = RuntimeEvent(payload: .lifecycle(golden.value))
            XCTAssertEqual(event.event, golden.name)
            XCTAssertEqual(event.kind, .lifecycle)
            XCTAssertEqual(event.detail, golden.detail, "golden: the human line is unchanged")
            XCTAssertEqual(event.typed, .lifecycle(golden.value))
        }
    }

    func testTheTypedInventoryIsTheFourLifecycleNamesAndTheConfigWorkflowFour() {
        XCTAssertEqual(
            RuntimeEventPayload.typedNames,
            Set([
                "lifecycle.superseded", "lifecycle.coalesced", "lifecycle.termination_drain_expired",
                "lifecycle.version_changed",
                "config.workflow.observed", "config.workflow.committed", "config.workflow.held", "config.workflow.superseded",
            ])
        )
        XCTAssertEqual(LifecycleEventName.allCases.count, 4)
        XCTAssertEqual(ConfigurationWorkflowEventName.allCases.count, 4)
    }

    /// The namespace is closed with no untyped exception. The legacy envelope traps on a name
    /// `requiresTypedPayload` accepts, so this pins the rule on the pure helper, with names a
    /// producer could assemble at run time as well as literals. A literal in product code is
    /// covered by `scripts/check-event-catalogue.py`.
    func testTheWholeLifecycleNamespaceNeedsATypedValue() {
        for name in RuntimeEventPayload.typedNames {
            XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(name), name)
        }
        let assembled = ["lifecycle", "future"].joined(separator: ".")
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(assembled), "a run-time name in the namespace")
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload("lifecycle.future"))
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload("lifecycle.crash_restart"), "planned, not emitted")
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload("lifecycle.superseded.extra"))
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload("lifecycle.version_changed.extra"))
        XCTAssertFalse(RuntimeEventPayload.requiresTypedPayload("proxy.lifecycle.future"))
        XCTAssertFalse(RuntimeEventPayload.requiresTypedPayload("routing.lifecycle"))
        XCTAssertFalse(RuntimeEventPayload.requiresTypedPayload("lifecycle"), "a kind, not an event name")
    }

    /// The legacy envelope refuses every `lifecycle.*` name, the version change included. The
    /// names are built here, so the check does not depend on a literal the catalogue gate reads.
    func testTheLegacyEnvelopeRefusesEveryLifecycleNameTypedOrNot() {
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(["lifecycle", "version_changed"].joined(separator: ".")))
        XCTAssertTrue(RuntimeEventPayload.requiresTypedPayload(["lifecycle", "crash_restart"].joined(separator: ".")))
    }

    /// A record the file already holds with a lifecycle name and no `typed` field stays readable
    /// as a legacy display record, and the reader does not invent a typed value for it.
    func testAHistoricalVersionChangedRecordStaysReadableAsLegacy() throws {
        let line = #"{"detail":"from=0.4.1 to=0.5.0","event":"lifecycle.version_changed","kind":"lifecycle","timestamp":1700000000}"#
        let event = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.event, "lifecycle.version_changed")
        XCTAssertEqual(event.detail, "from=0.4.1 to=0.5.0")
        XCTAssertNil(event.typed)
    }

    /// The version grammar: one short token per side, so a credential, a URL or a header has no
    /// place in a typed field. Legitimate bundle versions are unchanged, and the bound is 59 bytes.
    func testAVersionIsOneShortTokenAndNothingElse() {
        let longest = String(repeating: "a", count: LifecycleVersionChanged.maximumVersionBytes)
        for accepted in ["0.5.8", "0.5.8-rc.1+7", "unbundled", "1_0", longest] {
            XCTAssertTrue(LifecycleVersionChanged.isValid(version: accepted), accepted)
        }
        let rejected = [
            "", String(repeating: "a", count: 65), "0.5.8 beta", "0.5.8\n", "token=abc", "https://user:pw@host/",
            "Bearer abc", "Authorization:abc", "a\"b", "<redacted>", "ghp_" + String(repeating: "A", count: 61),
            "1.0/x", "é",
        ]
        for version in rejected {
            XCTAssertFalse(LifecycleVersionChanged.isValid(version: version), version)
        }
        XCTAssertFalse(LifecycleVersionChanged.isValid(from: "0.4.1", to: "bad version"))
    }

    /// The bound is the longest version whose `from=` line the sanitizer leaves alone: `from=` is five
    /// bytes, and the sanitizer masks a run of 65 or more base64-like bytes.
    func testTheBoundKeepsTheFromLineUnderTheSanitizerRun() {
        XCTAssertEqual(LifecycleVersionChanged.maximumVersionBytes, 59)
        XCTAssertLessThan("from=".utf8.count + LifecycleVersionChanged.maximumVersionBytes, 65)
        XCTAssertEqual(LifecycleVersionFixtures.boundary.map { $0.utf8.count }.max(), LifecycleVersionChanged.maximumVersionBytes)
        for version in LifecycleVersionFixtures.boundary {
            XCTAssertTrue(LifecycleVersionChanged.isValid(version: version), "\(version.utf8.count) bytes")
        }
    }

    /// Every version the bound admits renders a line the sanitizer returns unchanged, in either field
    /// and with dots and separators in any position, so the typed detail and the outer detail are one string.
    func testTheRenderedLineIsAFixedPointForEveryValidPair() {
        for from in LifecycleVersionFixtures.valid {
            for to in LifecycleVersionFixtures.valid {
                let change = LifecycleVersionChanged(from: from, to: to)
                let detail = LifecycleEvent.versionChanged(change).detail
                let shape = "from \(from.utf8.count) bytes, to \(to.utf8.count) bytes"
                XCTAssertEqual(SensitiveValueSanitizer.sanitize(detail), detail, shape)
                XCTAssertEqual(RuntimeEvent(payload: .lifecycle(.versionChanged(change))).detail, detail, shape)
            }
        }
    }

    /// One byte past the bound is refused in either field, dot-free or dotted, so no typed value carries a
    /// line the sanitizer would rewrite.
    func testAVersionPastTheBoundIsRefusedInEitherField() {
        for version in LifecycleVersionFixtures.overBound {
            XCTAssertFalse(LifecycleVersionChanged.isValid(version: version), "\(version.utf8.count) bytes")
            XCTAssertFalse(LifecycleVersionChanged.isValid(from: version, to: "0.5.0"), "\(version.utf8.count) bytes, from")
            XCTAssertFalse(LifecycleVersionChanged.isValid(from: "0.4.1", to: version), "\(version.utf8.count) bytes, to")
        }
    }

    /// The pair rule is the sanitizer's fixed-point test, pair by pair. Every grammar token is a side of the
    /// matrix, valid or not, so no pair is dropped for being invalid: the predicate accepts a pair exactly
    /// when the sanitizer leaves its rendered line unchanged, and the refused pairs are the bearer-shaped `from`s.
    func testThePairRuleIsExactlyTheSanitizerFixedPointOverTheGrammar() {
        var rewritten = 0
        for from in LifecycleVersionFixtures.grammar {
            for to in LifecycleVersionFixtures.grammar {
                let line = "from=\(from) to=\(to)"
                let unchanged = SensitiveValueSanitizer.sanitize(line) == line
                XCTAssertEqual(
                    LifecycleVersionChanged.isValid(from: from, to: to), unchanged,
                    "from \(from.utf8.count) bytes, to \(to.utf8.count) bytes"
                )
                if !unchanged { rewritten += 1 }
            }
        }
        XCTAssertEqual(rewritten, LifecycleVersionFixtures.bearerFrom.count * LifecycleVersionFixtures.grammar.count)
    }

    /// A `from` that ends in the word `Bearer`, in any case and after any of `.`, `-`, `+` or at the start,
    /// is refused. The same token is a valid `to`, and the near misses are valid as `from`.
    func testAFromThatReadsAsABearerCredentialIsRefusedAndAsToItIsNot() {
        for token in LifecycleVersionFixtures.bearerFrom {
            XCTAssertTrue(LifecycleVersionChanged.isValid(version: token), token)
            XCTAssertFalse(LifecycleVersionChanged.isValid(from: token, to: "0.5.0"), token)
            XCTAssertTrue(LifecycleVersionChanged.isValid(from: "0.4.1", to: token), token)
        }
        for token in LifecycleVersionFixtures.bearerNearMiss {
            XCTAssertTrue(LifecycleVersionChanged.isValid(from: token, to: "0.5.0"), token)
        }
    }

    /// A typed record whose `from` reads as a bearer credential throws on read, whatever its outer detail says.
    func testAFromThatReadsAsABearerCredentialThrowsOnRead() {
        for token in LifecycleVersionFixtures.bearerFrom {
            let typed = #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"\#(token)","to":"0.5.0"}}"#
            XCTAssertThrowsError(
                try decode(event: "lifecycle.version_changed", detail: "from=\(token) to=0.5.0", typed: typed),
                token
            )
        }
    }

    /// The bound is the edge of the sanitizer's masking. A dot-free `from` one byte past it renders a run of
    /// 65 base64-like bytes, which the sanitizer rewrites, and the bound keeps the line at 64.
    func testOneByteOverTheBoundIsTheRunTheSanitizerMasks() {
        let atBound = "from=\(String(repeating: "a", count: LifecycleVersionChanged.maximumVersionBytes)) to=0.5.0"
        XCTAssertEqual(SensitiveValueSanitizer.sanitize(atBound), atBound)
        for count in (LifecycleVersionChanged.maximumVersionBytes + 1)...65 {
            let line = "from=\(String(repeating: "a", count: count)) to=0.5.0"
            XCTAssertNotEqual(SensitiveValueSanitizer.sanitize(line), line, "\(count) bytes")
        }
    }

    /// Every valid boundary pair survives the file: the typed value and both details come back as written.
    func testEveryValidVersionRoundTripsTheCanonicalFileEncoding() throws {
        for from in LifecycleVersionFixtures.valid {
            for to in LifecycleVersionFixtures.valid {
                let original = RuntimeEvent(payload: .lifecycle(.versionChanged(LifecycleVersionChanged(from: from, to: to))))
                let decoded = try CanonicalJSON.decoder().decode(
                    RuntimeEvent.self,
                    from: try CanonicalJSON.encoder().encode(original)
                )
                XCTAssertEqual(decoded.typed, original.typed, "\(from.utf8.count) bytes, \(to.utf8.count) bytes")
                XCTAssertEqual(decoded.detail, original.detail, "\(from.utf8.count) bytes, \(to.utf8.count) bytes")
            }
        }
    }

    /// The domain's `superseded` rule: a later generation overtook this one, so `current`
    /// is strictly newer. `runtime_down` allows equality. The wire and the domain share it.
    func testSupersededNeedsAStrictlyNewerCurrentExceptForRuntimeDown() {
        XCTAssertFalse(LifecycleSuperseded.isValid(generation: 2, current: 2, reason: .superseded))
        XCTAssertTrue(LifecycleSuperseded.isValid(generation: 2, current: 3, reason: .superseded))
        XCTAssertTrue(LifecycleSuperseded.isValid(generation: 2, current: 2, reason: .runtimeDown))
        XCTAssertFalse(LifecycleSuperseded.isValid(generation: 0, current: 2, reason: .runtimeDown))
    }

    func testEveryOperationAndReasonKeepsItsLegacySpelling() {
        XCTAssertEqual(
            LifecycleOperation.allCases.map(\.rawValue).sorted(),
            ["dns_start", "dns_stop", "proxy_start", "proxy_stop", "runtime_start", "runtime_stop", "tunnels_start", "tunnels_stop"]
        )
        XCTAssertEqual(LifecycleSupersessionReason.allCases.map(\.rawValue).sorted(), ["runtime_down", "superseded"])
    }

    func testTheFileCarriesTheTypedFieldBesideTheLegacyFields() throws {
        let event = RuntimeEvent(payload: goldens[0].value.payload)
        let line = String(decoding: try CanonicalJSON.encoder().encode(event), as: UTF8.self)
        XCTAssertTrue(
            line.contains(#""typed":{"family":"lifecycle","lifecycle":{"current":2,"generation":1,"operation":"proxy_start","reason":"superseded","type":"superseded"}}"#),
            line
        )
        XCTAssertTrue(line.contains(#""event":"lifecycle.superseded""#), line)
    }

    func testTheVersionChangeCarriesItsFromAndToFieldsInTheFile() throws {
        let event = RuntimeEvent(payload: .lifecycle(.versionChanged(LifecycleVersionChanged(from: "0.4.1", to: "0.5.0"))))
        let line = String(decoding: try CanonicalJSON.encoder().encode(event), as: UTF8.self)
        XCTAssertTrue(
            line.contains(#""typed":{"family":"lifecycle","lifecycle":{"from":"0.4.1","to":"0.5.0","type":"version_changed"}}"#),
            line
        )
        XCTAssertTrue(line.contains(#""detail":"from=0.4.1 to=0.5.0""#), line)
    }

    func testTypedValuesRoundTripThroughTheCanonicalFileEncoding() throws {
        for golden in goldens {
            let original = RuntimeEvent(payload: .lifecycle(golden.value))
            let decoded = try CanonicalJSON.decoder().decode(
                RuntimeEvent.self,
                from: try CanonicalJSON.encoder().encode(original)
            )
            assertSameMoment(decoded.timestamp, original.timestamp)
            XCTAssertEqual(decoded.kind, original.kind)
            XCTAssertEqual(decoded.event, original.event)
            XCTAssertEqual(decoded.detail, original.detail)
            XCTAssertEqual(decoded.typed, original.typed)
        }
    }

    /// The reader that predates `typed`: it knows four fields and nothing else.
    private struct ReaderBeforeTyped: Decodable {
        let timestamp: Date
        let kind: String
        let event: String
        let detail: String?
    }

    func testAReaderThatPredatesTheTypedFieldStillReadsEveryTypedRecord() throws {
        for golden in goldens {
            let original = RuntimeEvent(payload: .lifecycle(golden.value))
            let old = try CanonicalJSON.decoder().decode(
                ReaderBeforeTyped.self,
                from: try CanonicalJSON.encoder().encode(original)
            )
            assertSameMoment(old.timestamp, original.timestamp)
            XCTAssertEqual(old.kind, "lifecycle")
            XCTAssertEqual(old.event, golden.name)
            XCTAssertEqual(old.detail, golden.detail)
        }
    }

    /// The grammar is checked on a typed value only. A legacy line with a token past today's bound
    /// still reads as the display record it is.
    func testAHistoricalVersionChangeWithALongTokenStaysReadableAsLegacy() throws {
        let longToken = String(repeating: "a", count: LifecycleVersionChanged.maximumVersionBytes + 1)
        let line = #"{"detail":"from=\#(longToken) to=0.5.0","event":"lifecycle.version_changed","kind":"lifecycle","timestamp":1700000000}"#
        let event = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.event, "lifecycle.version_changed")
        XCTAssertEqual(event.detail, "from=\(longToken) to=0.5.0")
        XCTAssertNil(event.typed)
    }

    func testAHistoricalRecordWithoutTheTypedFieldDecodesAsLegacyWithoutInventingOne() throws {
        let line = #"{"detail":"operation=proxy_start generation=1 current=2 reason=superseded","event":"lifecycle.superseded","kind":"lifecycle","timestamp":1700000000}"#
        let event = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event.event, "lifecycle.superseded")
        XCTAssertEqual(event.detail, "operation=proxy_start generation=1 current=2 reason=superseded")
        XCTAssertNil(event.typed, "a record without the field is not evidence of a typed value")
    }

    func testAValidTypedRecordDecodesToItsValue() throws {
        let event = try decode(event: "lifecycle.superseded", detail: goldens[0].detail, typed: superseded)
        XCTAssertEqual(event.typed, goldens[0].value.payload)
    }

    func testMalformedKnownPayloadsThrowInsteadOfBecomingUnknown() {
        let detail = goldens[0].detail
        let overBound = String(repeating: "a", count: LifecycleVersionChanged.maximumVersionBytes + 1)
        let rejected: [(label: String, event: String, kind: String, detail: String, typed: String)] = [
            ("an unknown family",
             "lifecycle.superseded", "lifecycle", detail,
             #"{"family":"config","lifecycle":{"type":"superseded"}}"#),
            ("an unknown lifecycle type",
             "lifecycle.superseded", "lifecycle", detail,
             #"{"family":"lifecycle","lifecycle":{"type":"started","operation":"proxy_start"}}"#),
            ("an unknown operation",
             "lifecycle.superseded", "lifecycle", detail,
             #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_flip","generation":1,"current":2,"reason":"superseded"}}"#),
            ("an unknown reason",
             "lifecycle.superseded", "lifecycle", detail,
             #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":1,"current":2,"reason":"timeout"}}"#),
            ("generation zero",
             "lifecycle.superseded", "lifecycle", "operation=proxy_start generation=0 current=2 reason=superseded",
             #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":0,"current":2,"reason":"superseded"}}"#),
            ("current below generation",
             "lifecycle.superseded", "lifecycle", "operation=proxy_start generation=3 current=2 reason=superseded",
             #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":3,"current":2,"reason":"superseded"}}"#),
            ("a superseded reason with current equal to generation",
             "lifecycle.superseded", "lifecycle", "operation=proxy_start generation=2 current=2 reason=superseded",
             #"{"family":"lifecycle","lifecycle":{"type":"superseded","operation":"proxy_start","generation":2,"current":2,"reason":"superseded"}}"#),
            ("a joined generation of zero",
             "lifecycle.coalesced", "lifecycle", "operation=dns_stop joined=0",
             #"{"family":"lifecycle","lifecycle":{"type":"coalesced","operation":"dns_stop","joined":0}}"#),
            ("a negative drain deadline",
             "lifecycle.termination_drain_expired", "lifecycle", "deadline_ms=-1",
             #"{"family":"lifecycle","lifecycle":{"type":"termination_drain_expired","deadline_ms":-1}}"#),
            ("a version with a space",
             "lifecycle.version_changed", "lifecycle", "from=0.4.1 to=bad version",
             #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"0.4.1","to":"bad version"}}"#),
            ("a version that carries a credential",
             "lifecycle.version_changed", "lifecycle", "from=https://u:p@h/ to=0.5.0",
             #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"https://u:p@h/","to":"0.5.0"}}"#),
            ("a version one byte past the bound",
             "lifecycle.version_changed", "lifecycle", "from=\(overBound) to=0.5.0",
             #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"\#(overBound)","to":"0.5.0"}}"#),
            ("an empty version",
             "lifecycle.version_changed", "lifecycle", "from= to=0.5.0",
             #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"","to":"0.5.0"}}"#),
            ("a version_changed without its to field",
             "lifecycle.version_changed", "lifecycle", "from=0.4.1 to=0.5.0",
             #"{"family":"lifecycle","lifecycle":{"type":"version_changed","from":"0.4.1"}}"#),
            ("a name that disagrees with its payload",
             "lifecycle.coalesced", "lifecycle", detail, superseded),
            ("a kind that disagrees with its payload",
             "lifecycle.superseded", "routing", detail, superseded),
            ("a detail that disagrees with its payload",
             "lifecycle.superseded", "lifecycle", "operation=proxy_start generation=9 current=9 reason=superseded", superseded),
            ("a typed value that is null",
             "lifecycle.superseded", "lifecycle", detail, "null"),
        ]
        for case_ in rejected {
            XCTAssertThrowsError(
                try decode(event: case_.event, kind: case_.kind, detail: case_.detail, typed: case_.typed),
                case_.label
            )
        }
    }

    // MARK: - Helpers

    /// `CanonicalJSON` writes a `Date` as epoch seconds in a `Double`, so a round
    /// trip can move the last bit. The file's timestamps are exact to the microsecond.
    private func assertSameMoment(
        _ decoded: Date,
        _ original: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(decoded.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 1e-6, file: file, line: line)
    }

    /// A record in the file's shape, with the typed value spliced in as written.
    private func decode(event: String, kind: String = "lifecycle", detail: String, typed: String) throws -> RuntimeEvent {
        let line = #"{"detail":"\#(detail)","event":"\#(event)","kind":"\#(kind)","timestamp":1700000000,"typed":\#(typed)}"#
        return try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line.utf8))
    }
}

private extension LifecycleEvent {
    var payload: RuntimeEventPayload { .lifecycle(self) }
}
