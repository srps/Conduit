// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Codec tests for the editor preconditions an update carries: exact store baselines and per-module lifecycle intent
/// (decisions 0015, 0018 and 0034). They use the real encoder, scanner and decoder.
final class PrivateEditorCodecTests: XCTestCase {
    // MARK: - Exact baselines

    /// The full `UInt64` range crosses the scanner and `JSONDecoder` exactly, with no narrowing to `Int`.
    func testBaselineVersionsRoundTripAcrossTheWholeUInt64Range() throws {
        let pairs: [(UInt64, UInt64)] = [
            (UInt64.max, 0), (UInt64(Int.max) + 1, UInt64(Int.max)), (1, 10_000_000_000_000_000_000),
        ]
        for (runtime, platform) in pairs {
            let request = try sample(runtimeVersion: runtime, platformVersion: platform)
            let text = try bodyText(request)
            XCTAssertTrue(text.contains("\"version\":\(runtime)"), "\(runtime)")
            XCTAssertTrue(text.contains("\"version\":\(platform)"), "\(platform)")
            let decoded = try decodeText(text)
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.runtimeBaseline.version, runtime)
            XCTAssertEqual(decoded.platformBaseline.version, platform)
        }
    }

    /// A version is plain decimal digits within `UInt64`. Every other spelling is refused by the scanner, including ones
    /// Foundation would read as the same or a nearby integer.
    func testBaselineVersionSpellingsOutsideAnExactUInt64AreRefused() throws {
        let text = try bodyText(sample(runtimeVersion: 4, platformVersion: 3))
        let refused = [
            "18446744073709551616", "99999999999999999999", "184467440737095516150", "100000000000000000000",
            "-1", "-0", "1.0", "4.0", "1e3", "4E0", "01", "00", "\"4\"", "null", "true", "0x4",
        ]
        for lexeme in refused {
            XCTAssertEqual(refusal(replacing(text, "\"version\":4}", with: "\"version\":\(lexeme)}")), .malformedBody, lexeme)
        }
        let accepted: [(String, UInt64)] = [
            ("0", 0), ("9999999999999999999", 9_999_999_999_999_999_999), ("18446744073709551615", UInt64.max),
        ]
        for (lexeme, value) in accepted {
            let decoded = try decodeText(replacing(text, "\"version\":4}", with: "\"version\":\(lexeme)}"))
            XCTAssertEqual(decoded.runtimeBaseline.version, value, lexeme)
        }
    }

    /// The scanner alone decides the version's range, before Foundation reads anything. Foundation also refuses an
    /// overflow, so an end-to-end decode cannot show which layer refused; this drives the scanner directly on the baseline
    /// table.
    func testScannerAloneRefusesAVersionPastUInt64Max() throws {
        func scan(_ version: String) throws {
            let text = "{\"namespace\":\"n\",\"component\":\"runtime\",\"version\":\(version)}"
            var bytes = Array(text.utf8)
            try bytes.withUnsafeMutableBufferPointer { buffer in
                try PrivateJSONScanner.validate(UnsafeBufferPointer(buffer), root: PrivateConfigurationSchema.baseline)
            }
        }
        XCTAssertNoThrow(try scan("18446744073709551615"))
        XCTAssertNoThrow(try scan("0"))
        for version in ["18446744073709551616", "99999999999999999999"] {
            XCTAssertThrowsError(try scan(version), version) {
                XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody, version)
            }
        }
    }

    /// Each baseline slot holds its own file. The initializer refuses a swap with `invalidValue`, and the decoder refuses
    /// the same swap, an unknown component and a namespace that is not a UUID.
    func testBaselineSlotsComponentsAndNamespacesAreChecked() throws {
        let runtime = PrivateConfigSamples.baseline(.runtime, version: 4)
        let platform = PrivateConfigSamples.baseline(.platform, version: 3)
        let preferences = PrivateConfigSamples.baseline(.preferences, version: 2)
        let base = try PrivateConfigSamples.request()
        for (runtimeSlot, platformSlot) in [(platform, runtime), (runtime, runtime), (preferences, platform), (runtime, preferences)] {
            XCTAssertThrowsError(try PrivateConfigurationRequest(
                requestID: base.requestID, incarnation: base.incarnation, budget: base.budget,
                runtimeBaseline: runtimeSlot, platformBaseline: platformSlot, modules: base.modules,
                runtime: base.runtime, platform: base.platform
            )) {
                XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidValue)
            }
        }

        let text = try bodyText(base)
        let namespace = PrivateConfigSamples.storeNamespace.rawValue.uuidString
        XCTAssertEqual(refusal(replacing(text, "\"component\":\"platform\"", with: "\"component\":\"runtime\"")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"component\":\"runtime\"", with: "\"component\":\"preferences\"")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"component\":\"runtime\"", with: "\"component\":\"journal\"")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"namespace\":\"\(namespace)\"", with: "\"namespace\":\"store-1\"")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, ",\"version\":4", with: "")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"version\":4", with: "\"version\":4,\"version\":4")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"version\":4", with: "\"version\":4,\"epoch\":1")), .malformedBody)
    }

    // MARK: - Per-module intent

    /// Every intent crosses the wire unchanged in every slot, including the widest lifecycle revision.
    func testEveryModuleIntentRoundTripsInEverySlot() throws {
        let intents: [PrivateModuleIntent] = [
            .saveOnly,
            .applyWhileRunning(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(0)),
            .applyWhileRunning(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(Int.max)),
            .start(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(5)),
            .start(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(Int.max)),
        ]
        for module in ControlModule.allCases {
            for intent in intents {
                var request = try PrivateConfigSamples.request()
                request.modules[module] = intent
                XCTAssertEqual(try decodeText(bodyText(request)), request, "\(module) \(intent)")
            }
        }
    }

    /// The action and the revision must pair: save-only names no revision, and apply and start each name one. An unknown
    /// action, a negative revision, a missing or repeated module and a missing revision key are refused, never defaulted.
    func testModuleIntentPairingsAndShapeAreStrict() throws {
        var request = try PrivateConfigSamples.request()
        request.modules = PrivateModuleSlots(
            proxy: .saveOnly,
            dns: .applyWhileRunning(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(7)),
            tunnels: .start(ifLifecycleRevision: try PrivateConfigSamples.lifecycleRevision(9))
        )
        let text = try bodyText(request)
        let saveOnly = "\"proxy\":{\"action\":\"saveOnly\",\"lifecycleRevision\":null}"
        let apply = "\"dns\":{\"action\":\"applyWhileRunning\",\"lifecycleRevision\":7}"
        let start = "\"tunnels\":{\"action\":\"start\",\"lifecycleRevision\":9}"
        for fragment in [saveOnly, apply, start] {
            XCTAssertTrue(text.contains(fragment), fragment)
        }
        let mutations: [(String, String)] = [
            (saveOnly, "\"proxy\":{\"action\":\"saveOnly\",\"lifecycleRevision\":1}"),
            // The nullable member is required even where its value would be null: a missing key is never read as null.
            (saveOnly, "\"proxy\":{\"action\":\"saveOnly\"}"),
            (apply, "\"dns\":{\"action\":\"applyWhileRunning\",\"lifecycleRevision\":null}"),
            (start, "\"tunnels\":{\"action\":\"start\",\"lifecycleRevision\":null}"),
            (start, "\"tunnels\":{\"action\":\"stop\",\"lifecycleRevision\":9}"),
            (start, "\"tunnels\":{\"action\":\"Start\",\"lifecycleRevision\":9}"),
            (start, "\"tunnels\":{\"action\":\"start\",\"lifecycleRevision\":-1}"),
            (start, "\"tunnels\":{\"action\":\"start\",\"lifecycleRevision\":9.5}"),
            (start, "\"tunnels\":{\"action\":\"start\"}"),
            (start, "\"tunnels\":{\"lifecycleRevision\":9}"),
            ("," + start, ""),
            (start, start + ",\"proxy\":{\"action\":\"saveOnly\",\"lifecycleRevision\":null}"),
            (start, start + ",\"helper\":{\"action\":\"saveOnly\",\"lifecycleRevision\":null}"),
        ]
        for (original, mutated) in mutations {
            XCTAssertEqual(refusal(replacing(text, original, with: mutated)), .malformedBody, mutated)
        }
    }

    // MARK: - Request shape, reflection and coding

    /// The old Int revision members are gone from the wire: the scanner refuses each as an unknown key.
    func testRetiredRevisionMembersAreRefusedAsUnknownKeys() throws {
        let text = try bodyText(PrivateConfigSamples.request())
        for retired in ["expectedConfigRevision", "expectedPlatformRevision", "expectedOwnerGeneration"] {
            XCTAssertFalse(text.contains(retired))
            XCTAssertEqual(
                refusal(replacing(text, "\"budgetMilliseconds\":5000", with: "\"budgetMilliseconds\":5000,\"\(retired)\":1")),
                .malformedBody,
                retired
            )
        }
    }

    /// The description names the request's identity and preconditions, which carry no secret, and never a value.
    func testDescriptionNamesPreconditionsAndNeverValues() throws {
        let request = try sample(runtimeVersion: .max, platformVersion: 3)
        let described = String(describing: request) + String(reflecting: request)
        XCTAssertTrue(described.contains("runtime v18446744073709551615"))
        XCTAssertTrue(described.contains("platform v3"))
        XCTAssertFalse(described.contains("PAC-TOKEN-7"))
        XCTAssertFalse(described.contains("sample"), "the profile name is a value")
    }

    /// The lifecycle intents have no generic coding path; only the private codec writes or reads them. A baseline holds no configuration
    /// value, so a causal receipt carries it on the ordinary wire too, with the same members and the version as the same exact `UInt64`
    /// number, at its maximum included. The private codec's own bytes are pinned by the frame tests and do not change.
    func testIntentsAreNotCodableAndABaselineKeepsItsExactVersionOnTheOrdinaryWire() throws {
        let request = try PrivateConfigSamples.request()
        XCTAssertNil(request.modules as Any as? any Encodable)
        XCTAssertNil(request.modules.proxy as Any as? any Encodable)

        let widest = PrivateConfigSamples.baseline(.runtime, version: UInt64.max)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = String(decoding: try encoder.encode(widest), as: UTF8.self)
        XCTAssertEqual(
            encoded,
            #"{"component":"runtime","namespace":"\#(widest.namespace.rawValue.uuidString)","version":18446744073709551615}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(PrivateBaseline.self, from: Data(encoded.utf8)), widest)
    }

    // MARK: - Helpers

    private func sample(runtimeVersion: UInt64, platformVersion: UInt64) throws -> PrivateConfigurationRequest {
        let base = try PrivateConfigSamples.request()
        return try PrivateConfigurationRequest(
            requestID: base.requestID, incarnation: base.incarnation, budget: base.budget,
            runtimeBaseline: PrivateConfigSamples.baseline(.runtime, version: runtimeVersion),
            platformBaseline: PrivateConfigSamples.baseline(.platform, version: platformVersion),
            modules: base.modules, runtime: base.runtime, platform: base.platform
        )
    }

    /// The request's JSON body, without its header and terminator.
    private func bodyText(_ request: PrivateConfigurationRequest) throws -> String {
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        return String(decoding: frame[start..<(frame.count - 1)], as: UTF8.self)
    }

    /// `text` with `original` replaced. The original must be present, so a mutation cannot silently miss.
    private func replacing(_ text: String, _ original: String, with replacement: String) -> String {
        XCTAssertTrue(text.contains(original), "fixture lacks \(original)")
        return text.replacingOccurrences(of: original, with: replacement)
    }

    private func decodeText(_ text: String) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(Array(text.utf8))))
    }

    private func refusal(_ text: String) -> PrivateConfigurationWireError? {
        do {
            _ = try decodeText(text)
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }
}
