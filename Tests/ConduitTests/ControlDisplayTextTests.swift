import XCTest
import ConduitShared

/// The display text path (decision 0029) against an independent model. The model and the production path share no loop. The model finds the
/// longest run of whole Characters within a limit by binary search over the Character count. The production path walks the Characters once.
/// Generators are seeded, and each failure message names its seed. Redaction is checked only for the credential forms the sanitizer's grammar
/// covers: a Bearer or Basic token of eight or more token bytes, and a URL with userinfo or a query.
final class ControlDisplayTextTests: XCTestCase {
    /// SplitMix64, the seeded generator. Each walk is replayable from its seed.
    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func below(_ bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }
    }

    /// Pieces that cannot form a redaction pattern: no colon, no question mark or hash, and no letters but x and z, so no Bearer, Basic,
    /// NTLM or Negotiate word can appear. They cover one, two, three and four byte scalars, a combining mark, a ZWJ sequence, NUL, quotes,
    /// a backslash and a newline.
    private static let pieces = ["x", "z", "0", "9", " ", "é", "€", "𝄞", "👨\u{200D}👩", "e\u{301}", "\u{0}", "\"", "\\", "\n"]

    /// The longest prefix of whole Characters whose UTF-8 length is within `limit`, by binary search over the Character count.
    private func modelPrefix(_ value: String, limit: Int) -> String {
        let characters = Array(value)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if String(characters[..<middle]).utf8.count <= limit {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return String(characters[..<low])
    }

    // MARK: - The model

    func testTheBoundedTextMatchesTheCharacterModelOnSeededInputs() {
        let limits = [0, 1, 2, 3, 6, 9, 17, 512, 1_024]
        for seed in UInt64(1)...100 {
            var random = SplitMix64(state: seed)
            var value = ""
            for _ in 0..<random.below(400) {
                value += Self.pieces[random.below(Self.pieces.count)]
            }
            let limit = limits[random.below(limits.count)]
            let shown = ControlDisplayText.bounded(value, maxBytes: limit)
            XCTAssertEqual(shown.text, modelPrefix(value, limit: limit), "seed \(seed), limit \(limit)")
            XCTAssertEqual(shown.treatment, value.utf8.count > limit ? .shortened : nil, "seed \(seed), limit \(limit)")
        }
    }

    // MARK: - Named edges

    func testNamedEdgesCutAtTheirCapsAndKeepWholeCharacters() {
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "a", count: 512), maxBytes: 512).treatment, nil)
        let cut = ControlDisplayText.bounded(String(repeating: "a", count: 513), maxBytes: 512)
        XCTAssertEqual(cut.text, String(repeating: "a", count: 512))
        XCTAssertEqual(cut.treatment, .shortened)

        // Two bytes each: 256 scalars is exactly 512 bytes, and 257 cut to 256.
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "é", count: 256), maxBytes: 512).treatment, nil)
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "é", count: 257), maxBytes: 512).text,
                       String(repeating: "é", count: 256))

        // A letter with a combining mark is three bytes in one Character. 170 of them are 510 bytes, and no 171st fits.
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "e\u{301}", count: 200), maxBytes: 512).text,
                       String(repeating: "e\u{301}", count: 170))

        // A family ZWJ sequence is 18 bytes in one Character. Under a cap of 17 nothing fits, so the kept text is empty and says so.
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(family.utf8.count, 18)
        let emptied = ControlDisplayText.bounded(family, maxBytes: 17)
        XCTAssertEqual(emptied.text, "")
        XCTAssertEqual(emptied.treatment, .shortened)

        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "\u{0}", count: 513), maxBytes: 512).text,
                       String(repeating: "\u{0}", count: 512))
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "\"", count: 600), maxBytes: 512).text,
                       String(repeating: "\"", count: 512))
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "p", count: 1_025), maxBytes: 1_024).text,
                       String(repeating: "p", count: 1_024))
    }

    func testTheInputGateOmitsOnlyAboveTheLimit() {
        // At the limit the input is cut, not omitted. One byte over, it is replaced whole, and nothing of it is sanitized or kept.
        let atLimit = ControlDisplayText.bounded(String(repeating: "a", count: 16_384), maxBytes: 512)
        XCTAssertEqual(atLimit.text, String(repeating: "a", count: 512))
        XCTAssertEqual(atLimit.treatment, .shortened)

        let over = ControlDisplayText.bounded(String(repeating: "a", count: 16_385), maxBytes: 512)
        XCTAssertEqual(over.text, "<omitted>")
        XCTAssertEqual(over.treatment, .omitted)
        XCTAssertEqual(ControlDisplayText.omittedValue, "<omitted>")

        // Multi-byte input at the limit is measured in bytes: 8,192 two-byte scalars are 16,384 bytes, and 8,193 are over.
        XCTAssertFalse(ControlDisplayText.exceeds(String(repeating: "é", count: 8_192), limit: 16_384))
        XCTAssertTrue(ControlDisplayText.exceeds(String(repeating: "é", count: 8_193), limit: 16_384))
        XCTAssertEqual(ControlDisplayText.bounded(String(repeating: "👨", count: 4_097), maxBytes: 512).treatment, .omitted)
    }

    // MARK: - Credentials across the cut points

    func testACredentialAcrossEachCutPointIsNeverPartlyKept() {
        let bearer = "ABCDEFGHIJKLMNOP1234"
        let basic = "dXNlcjpzZWNyZXRwYXNz"
        let userinfo = "https://svc-user:HunterSecretPassword@proxy.example.test/path"
        let query = "https://files.example.test/a?token=QUERYSECRETVALUE"
        let credentials: [(text: String, forbidden: [String])] = [
            ("Bearer \(bearer)", [String(bearer.prefix(8)), bearer]),
            ("Basic \(basic)", [String(basic.prefix(8)), basic]),
            (userinfo, ["HunterSe"]),
            (query, ["QUERYSEC"]),
            ("https://svc-user:HunterSecretPassword@proxy.example.test/path?token=QUERYSECRETVALUE", ["HunterSe", "QUERYSEC"]),
        ]
        for cut in [512, 1_024] {
            for offset in (cut - 12)...(cut + 12) {
                for credential in credentials {
                    let value = String(repeating: "x", count: offset) + " " + credential.text + " tail"
                    let shown = ControlDisplayText.bounded(value, maxBytes: cut)
                    for forbidden in credential.forbidden {
                        XCTAssertFalse(shown.text.contains(forbidden), "cut \(cut), offset \(offset): \(forbidden.prefix(8))… survives")
                    }
                    XCTAssertLessThanOrEqual(shown.text.utf8.count, cut)
                }
            }
        }
    }

    func testACredentialStraddlingTheInputLimitIsOmittedWholeOrRedactedWhole() {
        let bearer = "ABCDEFGHIJKLMNOP1234"
        // Past the limit the whole input is omitted, so the credential is not kept even as a partial prefix.
        let past = String(repeating: "x", count: 16_376) + " Bearer " + bearer
        XCTAssertGreaterThan(past.utf8.count, 16_384)
        let omitted = ControlDisplayText.bounded(past, maxBytes: 512)
        XCTAssertEqual(omitted.treatment, .omitted)
        XCTAssertFalse(omitted.text.contains("ABCDEFGH"))

        // Exactly at the limit the input is sanitized before the cut, so the Bearer token is redacted and never partly kept.
        let atLimit = String(repeating: "x", count: 16_356) + " Bearer " + bearer
        XCTAssertEqual(atLimit.utf8.count, 16_384)
        let redacted = ControlDisplayText.bounded(atLimit, maxBytes: 512)
        XCTAssertEqual(redacted.treatment, .shortened)
        XCTAssertFalse(redacted.text.contains("ABCDEFGH"))
    }
}
