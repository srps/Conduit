// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// The package's one domain-name grammar. See `DomainNameSyntax`'s own doc
/// comment for the RFC reasoning; this file pins the decisions.
final class DomainNameSyntaxTests: XCTestCase {

    private func assertValid(_ domain: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try DomainNameSyntax.validate(domain)
        } catch {
            XCTFail("expected '\(domain)' to validate, got \(error)", file: file, line: line)
        }
    }

    private func assertRejected(
        _ domain: String,
        _ expected: DomainNameError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try DomainNameSyntax.validate(domain)
            XCTFail("expected '\(domain)' to be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Underscores

    /// The change this type exists for. `/etc/resolver/<domain>` names a
    /// resolution domain, not a hostname, so LDH was never the right grammar —
    /// and an underscored resolver file was verified working on macOS 26.
    func testUnderscoreAccepted() {
        assertValid("foo_bar.example")
    }

    /// RFC 8552 / RFC 8553 formalise these; RFC 2782 mandates the `_service.
    /// _proto` shape outright. They are ordinary names that LDH rejects.
    func testUnderscorePrefixedLabelsAccepted() {
        assertValid("_dmarc.example.com")
        assertValid("_http._tcp.example.com")
        assertValid("_acme-challenge.example.com")
        assertValid("selector._domainkey.example.com")
    }

    // MARK: - Ordinary names

    func testOrdinaryNamesAccepted() {
        assertValid("example.test")
        assertValid("corp.example.test")
        assertValid("my-host.example.com")
        assertValid("123.456")
        assertValid("xn--bcher-kva.example")
    }

    /// A single-label name is a real resolver domain, and `localhost` is the
    /// one everybody has.
    func testSingleLabelAccepted() {
        assertValid("localhost")
    }

    func testMaximumLengthsAccepted() {
        let label = String(repeating: "a", count: 63)
        assertValid(label)
        assertValid("\(label).\(label).\(label)")

        // Exactly 253: three 63-char labels, three dots, and a 61-char label.
        let atLimit = "\(label).\(label).\(label).\(String(repeating: "b", count: 61))"
        XCTAssertEqual(atLimit.count, 253)
        assertValid(atLimit)
    }

    // MARK: - Length

    func testLabelLongerThan63Rejected() {
        let label = String(repeating: "a", count: 64)
        assertRejected("\(label).example", .labelTooLong(label: label, count: 64))
    }

    func testTotalLongerThan253Rejected() {
        // Every label legal on its own, so only the total can reject it.
        let label = String(repeating: "a", count: 63)
        let domain = Array(repeating: label, count: 4).joined(separator: ".")
        XCTAssertEqual(domain.count, 255)
        assertRejected(domain, .tooLong(count: 255))
    }

    // MARK: - Labels

    func testEmptyRejected() {
        assertRejected("", .empty)
    }

    func testEmptyLabelRejected() {
        assertRejected("foo..bar", .emptyLabel)
        assertRejected(".foo", .emptyLabel)
    }

    /// Rejected rather than normalised: this validator returns a verdict, not a
    /// cleaned-up string, so stripping the dot here would leave the caller
    /// writing `/etc/resolver/example.com.` regardless. See the type's doc
    /// comment.
    func testTrailingDotRejected() {
        assertRejected("example.com.", .trailingDot)
        assertRejected(".", .trailingDot)
        // `..` ends with a dot too, and the trailing-dot check runs first. The
        // advice is still the applicable one — the string is nothing but
        // separators, and either reason points at the same edit.
        assertRejected("..", .trailingDot)
    }

    func testLeadingHyphenRejected() {
        assertRejected("-invalid.com", .labelStartsWithHyphen(label: "-invalid"))
    }

    func testTrailingHyphenRejected() {
        assertRejected("invalid-.com", .labelEndsWithHyphen(label: "invalid-"))
    }

    // MARK: - Path and argv hazards

    /// `<domain>` becomes a path component under `/etc/resolver/`, so these are
    /// the shapes that matter more than any RFC.
    func testPathTraversalRejected() {
        assertRejected("../etc/passwd", .emptyLabel)
    }

    func testSlashRejected() {
        assertRejected("evil/path", .invalidCharacter("/", label: "evil/path"))
    }

    func testNullByteRejected() {
        assertRejected("bad\0.com", .invalidCharacter("\0", label: "bad\0"))
    }

    func testNewlineRejected() {
        assertRejected("bad\n.com", .invalidCharacter("\n", label: "bad\n"))
    }

    func testSpaceRejected() {
        assertRejected("bad domain.com", .invalidCharacter(" ", label: "bad domain"))
    }

    func testSemicolonRejected() {
        assertRejected("evil;rm -rf /", .invalidCharacter(";", label: "evil;rm -rf /"))
    }

    // MARK: - Non-ASCII

    /// Rejected with instructions, not just refused: the caller has to convert
    /// to A-label form itself, because that is what goes on the wire and what
    /// the resolver filename has to be.
    func testNonASCIIRejected() {
        assertRejected("bücher.example", .nonASCII("ü"))
        assertRejected("日本.example", .nonASCII("日"))
    }

    func testNonASCIIErrorNamesTheALabelForm() {
        let message = DomainNameError.nonASCII("ü").localizedDescription
        XCTAssertTrue(message.contains("xn--"), "got: \(message)")
    }

    // MARK: - Error messages

    /// A control character has no printable form, so it is named by code point
    /// rather than emitted raw into a log line or a Settings label.
    func testControlCharactersAreDescribedByCodePoint() {
        let message = DomainNameError.invalidCharacter("\0", label: "bad").localizedDescription
        XCTAssertTrue(message.contains("U+0000"), "got: \(message)")
    }

    func testEveryReasonHasADescription() {
        let reasons: [DomainNameError] = [
            .empty,
            .tooLong(count: 300),
            .labelTooLong(label: "a", count: 64),
            .emptyLabel,
            .trailingDot,
            .labelStartsWithHyphen(label: "-a"),
            .labelEndsWithHyphen(label: "a-"),
            .invalidCharacter("/", label: "a/b"),
            .nonASCII("ü"),
        ]
        for reason in reasons {
            XCTAssertFalse(
                reason.localizedDescription.isEmpty,
                "\(reason) must render something a user can act on"
            )
        }
    }

    // MARK: - The two delegating validators agree

    /// The point of having one grammar. Two byte-identical regexes used to live
    /// in `DNSManager` and `HelperInputValidator`, which is the shape that lets
    /// them drift — and a name the app accepts but the helper refuses is a
    /// privileged operation failing for no visible reason.
    func testHelperValidatorAgreesWithTheGrammar() {
        for domain in [
            "foo_bar.example", "_dmarc.example.com", "localhost", "example.com",
            "", "../etc/passwd", "-start.com", "has spaces.com", "example.com.",
            String(repeating: "a", count: 64),
        ] {
            XCTAssertEqual(
                HelperInputValidator.validateDomain(domain),
                DomainNameSyntax.isValid(domain),
                "disagreement on '\(domain)'"
            )
        }
    }
}
