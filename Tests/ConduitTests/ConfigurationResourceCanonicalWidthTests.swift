// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The canonical JSON width of a bypass list (decision 0021, 8,192 encoded bytes). The width is `JSONEncoder`'s
/// default output, counted instead of written, so the private scanner, both typed checks and the app's
/// `ProxyBypassSyntax` agree. The policy is pinned by differential comparison against `JSONEncoder`, not by a copied
/// table, and the wire side is checked at the same boundaries as the typed side.
final class ConfigurationResourceCanonicalWidthTests: XCTestCase {
    // MARK: - Differential width

    /// Every Unicode scalar value, in chunks, against `JSONEncoder`'s default output. Surrogates are not scalars and
    /// are skipped. A mismatch names the scalar that differs, not only the chunk.
    func testCanonicalWidthMatchesJSONEncoderForEveryScalarValue() throws {
        let encoder = JSONEncoder()
        let chunkSize: UInt32 = 0x1000
        var first: UInt32 = 0
        while first < 0x11_0000 {
            let last = min(first + chunkSize, 0x11_0000)
            let texts = (first..<last).compactMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            var counted = CanonicalJSONStringList()
            for text in texts {
                counted.append(quotedWidth: CanonicalJSONWidth.quotedWidth(text))
            }
            let encoded = try encoder.encode(texts).count
            if counted.bytes != encoded {
                for text in texts {
                    let single = try encoder.encode([text]).count
                    let counted = CanonicalJSONWidth.quotedWidth(text) + 2
                    if single != counted {
                        let scalar = String(text.unicodeScalars.first?.value ?? 0, radix: 16, uppercase: true)
                        XCTFail("U+\(scalar) encodes to \(single - 2) bytes, counted \(counted - 2)")
                    }
                }
            }
            XCTAssertEqual(counted.bytes, encoded, "chunk starting at U+\(String(first, radix: 16, uppercase: true))")
            first = last
        }
    }

    /// The classes the policy names, as items and as one list: slash, quote, backslash, the short escapes, other
    /// controls, DEL, multibyte scalars and the two line and paragraph separators.
    func testNamedClassesMatchTheEncoderAsItemsAndAsAList() throws {
        let samples = [
            "", "plain", "a/b", "quote\"and\\slash", "\u{08}\u{0C}\n\r\t", "\u{01}\u{1F}\u{7F}",
            "é€🙂", "\u{2028}\u{2029}", "*.example.test",
        ]
        var counted = CanonicalJSONStringList()
        for sample in samples {
            let encoded = try JSONEncoder().encode([sample]).count
            XCTAssertEqual(CanonicalJSONWidth.quotedWidth(sample) + 2, encoded, sample.debugDescription)
            counted.append(quotedWidth: CanonicalJSONWidth.quotedWidth(sample))
        }
        XCTAssertEqual(counted.bytes, try JSONEncoder().encode(samples).count)
        XCTAssertEqual(CanonicalJSONStringList().bytes, try JSONEncoder().encode([String]()).count)
    }

    // MARK: - Wire boundary parity

    /// 31 items of 253 bytes and one of 252 are exactly 8,192 canonical bytes: accepted, and decoded to the same list.
    /// One more byte on the last item is refused by the scanner as the aggregate, before any suffix is read.
    func testScannerAcceptsExactlyTheCanonicalCeilingAndRefusesOneMore() throws {
        let full = String(repeating: "a", count: 253)
        let exact = Array(repeating: full, count: 31) + [String(repeating: "a", count: 252)]
        let accepted = try decodeText(bodyText(noProxyHosts: exact.map(jsonString)))
        XCTAssertEqual(accepted.runtime.routing.noProxyHosts, exact)
        XCTAssertNil(accepted.resourceViolation())

        let over = Array(repeating: full, count: 32)
        XCTAssertEqual(
            refusal(try bodyText(noProxyHosts: over.map(jsonString))),
            .resourceLimitExceeded(DomainResourceViolation(.noProxyList, 8_192))
        )
        XCTAssertEqual(
            kernelViolation(noProxyHosts: over),
            DomainResourceViolation(.noProxyList, 8_192)
        )
        XCTAssertNil(kernelViolation(noProxyHosts: exact))
    }

    /// The width is canonical, not physical. Each item spelled as `a` is 6 bytes on the wire, so the body is
    /// well past 8,192 bytes, yet its canonical width is the same 8,192 and it is accepted and decodes exactly.
    func testEscapedSpellingIsMeasuredByItsDecodedWidthNotItsWireWidth() throws {
        let exact = Array(repeating: String(repeating: "a", count: 253), count: 31) + [String(repeating: "a", count: 252)]
        let text = try bodyText(noProxyHosts: exact.map(escapedItem))
        XCTAssertGreaterThan(text.utf8.count, 8_192 * 4)
        XCTAssertEqual(try decodeText(text).runtime.routing.noProxyHosts, exact)

        let over = Array(exact.dropLast()) + [String(repeating: "a", count: 253)]
        XCTAssertEqual(
            refusal(try bodyText(noProxyHosts: over.map(escapedItem))),
            .resourceLimitExceeded(DomainResourceViolation(.noProxyList, 8_192))
        )
    }

    /// A solidus is 2 canonical bytes, because the default encoder escapes it, and 1 raw byte on the wire. Sixteen
    /// items of 253 solidi are 8,145 canonical bytes and pass. Seventeen are 8,654 and are refused, whether raw or
    /// spelled `\/`. The app's `ProxyBypassSyntax` gives the same verdict, since it uses the same encoder policy.
    func testSolidusWidthIsTheDefaultEscapedWidthForRawAndEscapedSpellings() throws {
        let slashes = String(repeating: "/", count: 253)
        let sixteen = Array(repeating: slashes, count: 16)
        let seventeen = Array(repeating: slashes, count: 17)
        XCTAssertNil(kernelViolation(noProxyHosts: sixteen))
        XCTAssertNil(ProxyBypassSyntax.validationProblem(sixteen))
        XCTAssertNil(try decodeText(bodyText(noProxyHosts: sixteen.map(jsonString))).resourceViolation())
        XCTAssertNil(try decodeText(bodyText(noProxyHosts: sixteen.map(escapedSolidi))).resourceViolation())

        XCTAssertEqual(kernelViolation(noProxyHosts: seventeen), DomainResourceViolation(.noProxyList, 8_192))
        XCTAssertNotNil(ProxyBypassSyntax.validationProblem(seventeen))
        XCTAssertEqual(
            refusal(try bodyText(noProxyHosts: seventeen.map(jsonString))),
            .resourceLimitExceeded(DomainResourceViolation(.noProxyList, 8_192))
        )
        XCTAssertEqual(
            refusal(try bodyText(noProxyHosts: seventeen.map(escapedSolidi))),
            .resourceLimitExceeded(DomainResourceViolation(.noProxyList, 8_192))
        )
    }

    /// The bypass ceiling and the app's validation agree at the boundary: the same exact list passes both, and one
    /// more byte fails both. `ProxyBypassSyntax` still measures with `JSONEncoder`, so this pins the two together.
    func testAppBypassValidationAgreesWithTheCanonicalCeiling() {
        let full = String(repeating: "a", count: 253)
        let exact = Array(repeating: full, count: 31) + [String(repeating: "a", count: 252)]
        XCTAssertNil(ProxyBypassSyntax.validationProblem(exact))
        XCTAssertNotNil(ProxyBypassSyntax.validationProblem(Array(exact.dropLast()) + [full]))
    }

    /// An item past its own 253-byte ceiling is refused before the aggregate. Here 31 items fill 7,937 canonical
    /// bytes, and the 32nd is 254 bytes: its item ceiling fires mid-item and reports the item, not the aggregate. The
    /// typed check reports the same violation, so the two agree on the first ceiling in item order.
    func testItemCeilingInTheCrossingItemIsReportedBeforeTheAggregate() throws {
        let hosts = Array(repeating: String(repeating: "a", count: 253), count: 31) + [String(repeating: "a", count: 254)]
        let expected = DomainResourceViolation(.noProxyPattern, 253)
        XCTAssertEqual(refusal(try bodyText(noProxyHosts: hosts.map(jsonString))), .resourceLimitExceeded(expected))
        XCTAssertEqual(kernelViolation(noProxyHosts: hosts), expected)
    }

    // MARK: - Bypass diagnostics and their order

    /// The count is checked first, so an over-count list with a NUL reports the count, not the NUL.
    func testBypassCountDiagnosticPrecedesTheItemAndSizeDiagnostics() {
        let overCount = Array(repeating: "a", count: 257)
        XCTAssertEqual(ProxyBypassSyntax.validationProblem(overCount), "At most 256 bypass entries are supported.")
        XCTAssertEqual(
            ProxyBypassSyntax.validationProblem(overCount + ["a\u{0}"]),
            "At most 256 bypass entries are supported."
        )
    }

    /// The item diagnostic precedes the size diagnostic. An entry with a NUL, or one past 253 bytes, is reported even
    /// when the list is also over its encoded size.
    func testBypassItemDiagnosticPrecedesTheSizeDiagnostic() {
        let oversize = Array(repeating: String(repeating: "a", count: 253), count: 32)
        XCTAssertEqual(
            ProxyBypassSyntax.validationProblem(oversize),
            "The encoded bypass list must fit 8192 bytes."
        )
        let nul = "Each bypass entry must fit 253 UTF-8 bytes and contain no NUL characters."
        XCTAssertEqual(ProxyBypassSyntax.validationProblem(["a\u{0}"] + oversize), nul)
        XCTAssertEqual(ProxyBypassSyntax.validationProblem([String(repeating: "a", count: 254)] + oversize), nul)
    }

    /// Exactly 8,192 encoded bytes passes, and one more byte is refused with the size diagnostic.
    func testBypassExactSizeIsAcceptedAndOneMoreIsRefused() {
        let full = String(repeating: "a", count: 253)
        let exact = Array(repeating: full, count: 31) + [String(repeating: "a", count: 252)]
        XCTAssertNil(ProxyBypassSyntax.validationProblem(exact))
        XCTAssertEqual(
            ProxyBypassSyntax.validationProblem(Array(exact.dropLast()) + [full]),
            "The encoded bypass list must fit 8192 bytes."
        )
    }

    // MARK: - Token guard derivation

    /// The token guard is a lexical bound, so it must sit above every valid token. A canonical UUID is 36 bytes, and
    /// every enumeration raw value the decoder accepts in a token place is shorter. The list names every enumeration the
    /// private decoders read from a token: the value mirrors, the baseline component, the module intent action, the
    /// component state and its retained reason, the rejection code and the admission type. The widest is pinned so the
    /// implementation notes state the actual bound.
    func testTokenGuardIsDerivedFromTheTokenGrammarNotAProductCeiling() {
        XCTAssertEqual(UUID().uuidString.utf8.count, 36)
        let enumerationRaws = PrivateAuthenticationMode.allCases.map { $0.rawValue }
            + PrivateTunnelPreset.allCases.map { $0.rawValue }
            + PrivateSystemProxyMode.allCases.map { $0.rawValue }
            + ControlConfigWorkflowFile.allCases.map { $0.rawValue }
            + PrivateModuleIntentAction.allCases.map { $0.rawValue }
            + PrivateComponentStateKind.allCases.map { $0.rawValue }
            + PrivateRetainedReason.allCases.map { $0.rawValue }
            + ControlRejectionCode.allCases.map { $0.rawValue }
            + ["accepted", "joined", "rejected"]
        let widest = enumerationRaws.map { $0.utf8.count }.max() ?? 0
        XCTAssertEqual(widest, "changedSinceBaseline".utf8.count, "update the token guard paragraph in the codec notes")
        XCTAssertLessThanOrEqual(widest, DomainResourceLimits.token)
        XCTAssertLessThanOrEqual(36, DomainResourceLimits.token)
    }

    /// A token past the guard is not a valid token, so it is malformed. It is not reported as a resource limit.
    func testOverlongTokenIsMalformedNotAResourceLimit() throws {
        let text = try bodyText(noProxyHosts: ["\"a\""])
        let identifier = PrivateConfigSamples.uuid(1).uuidString
        let overlong = String(repeating: "a", count: DomainResourceLimits.token + 1)
        let replaced = text.replacingOccurrences(of: "\"requestID\":\"\(identifier)\"", with: "\"requestID\":\"\(overlong)\"")
        XCTAssertNotEqual(replaced, text, "the sample identifier must be present in the body")
        XCTAssertEqual(refusal(replaced), .malformedBody)
    }

    // MARK: - Fixtures

    private func jsonString(_ text: String) -> String {
        "\"" + text + "\""
    }

    /// Every scalar of `text` written as a `\uXXXX` escape, in quotes. The fixtures use ASCII only.
    private func escapedItem(_ text: String) -> String {
        "\"" + text.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined() + "\""
    }

    /// Solidi written as `\/`, in quotes. Each is 2 raw bytes and 2 canonical bytes.
    private func escapedSolidi(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "/", with: "\\/") + "\""
    }

    /// The kernel's typed check on a fixture config whose bypass list is `hosts`.
    private func kernelViolation(noProxyHosts hosts: [String]) -> DomainResourceViolation? {
        var config = ProxyConfig.testFixture()
        config.routing.noProxyHosts = hosts
        return config.resourceViolation()
    }

    /// The sample request's body text with its bypass list replaced by `elements`, each already spelled as JSON.
    private func bodyText(noProxyHosts elements: [String]) throws -> String {
        let frame = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request()).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        let text = String(decoding: frame[start..<(frame.count - 1)], as: UTF8.self)
        let open = try XCTUnwrap(text.range(of: "\"noProxyHosts\":[")).upperBound
        let close = try XCTUnwrap(text[open...].firstIndex(of: "]"))
        return text.replacingCharacters(in: open..<close, with: elements.joined(separator: ","))
    }

    private func decodeText(_ text: String) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(Array(text.utf8))))
    }

    /// The wire error a body is refused with, or nil when it decodes.
    private func refusal(_ text: String) -> PrivateConfigurationWireError? {
        do {
            _ = try decodeText(text)
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }
}
