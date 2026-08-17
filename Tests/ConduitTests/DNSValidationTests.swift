// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

final class DNSValidationTests: XCTestCase {

    // MARK: - Valid domain names

    func testSimpleDomainAccepted() throws {
        try DNSManager.validateDomain("example.test")
    }

    func testSubdomainAccepted() throws {
        try DNSManager.validateDomain("corp.example.test")
    }

    func testHyphenatedDomainAccepted() throws {
        try DNSManager.validateDomain("my-host.example.com")
    }

    func testSingleLabelDomainAccepted() throws {
        try DNSManager.validateDomain("localhost")
    }

    /// `/etc/resolver/<domain>` names a resolution domain, not a hostname, so
    /// the old LDH regex was rejecting names the OS honours — verified live on
    /// macOS 26. The grammar itself is covered in `DomainNameSyntaxTests`; this
    /// case pins that `DNSManager` is on it.
    func testUnderscoredDomainAccepted() throws {
        try DNSManager.validateDomain("foo_bar.example")
        try DNSManager.validateDomain("_dmarc.example.com")
    }

    func testNumericDomainAccepted() throws {
        try DNSManager.validateDomain("123.456")
    }

    func testLongButValidDomain() throws {
        let label = String(repeating: "a", count: 63)
        let domain = "\(label).\(label).\(label)"
        XCTAssertLessThanOrEqual(domain.count, 253)
        try DNSManager.validateDomain(domain)
    }

    // MARK: - Invalid domain names

    func testEmptyDomainRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainWithSpacesRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("bad domain.com")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainWithSlashRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("evil/path")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainWithSemicolonRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("evil;rm -rf /")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainStartingWithHyphenRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("-invalid.com")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainEndingWithHyphenRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("invalid-.com")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainWithNewlineRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("bad\n.com")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainExceeding253CharsRejected() {
        // Every label legal on its own, so only the total can reject it.
        let label = String(repeating: "a", count: 63)
        let long = Array(repeating: label, count: 4).joined(separator: ".")
        XCTAssertGreaterThan(long.count, 253)
        XCTAssertThrowsError(try DNSManager.validateDomain(long)) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testLabelExceeding63CharsRejected() {
        let label = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try DNSManager.validateDomain("\(label).example")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testTrailingDotRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("example.com.")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testNonASCIIDomainRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("bücher.example")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testPathTraversalDomainRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("../etc/passwd")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testDomainWithNullByteRejected() {
        XCTAssertThrowsError(try DNSManager.validateDomain("bad\0.com")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    // MARK: - Valid server IPs

    func testIPv4Accepted() throws {
        try DNSManager.validateServer("10.0.0.53")
    }

    func testIPv4LoopbackAccepted() throws {
        try DNSManager.validateServer("127.0.0.1")
    }

    func testIPv4AllZerosAccepted() throws {
        try DNSManager.validateServer("0.0.0.0")
    }

    func testIPv6LoopbackAccepted() throws {
        try DNSManager.validateServer("::1")
    }

    func testIPv6FullAccepted() throws {
        try DNSManager.validateServer("2001:db8::1")
    }

    func testIPv6ExpandedAccepted() throws {
        try DNSManager.validateServer("fe80:0000:0000:0000:0000:0000:0000:0001")
    }

    // MARK: - Invalid server IPs

    func testHostnameAsServerRejected() {
        XCTAssertThrowsError(try DNSManager.validateServer("dns.example.test")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testEmptyServerRejected() {
        XCTAssertThrowsError(try DNSManager.validateServer("")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testServerWithSpacesRejected() {
        XCTAssertThrowsError(try DNSManager.validateServer("10.0.0.1 && rm -rf /")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testServerWithSemicolonRejected() {
        XCTAssertThrowsError(try DNSManager.validateServer("10.0.0.1;echo hacked")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    func testServerWithNewlineRejected() {
        XCTAssertThrowsError(try DNSManager.validateServer("10.0.0.1\nmalicious")) { error in
            XCTAssertTrue(error is DNSValidationError)
        }
    }

    // MARK: - Error descriptions

    /// The description carries the reason as well as the name: "invalid domain"
    /// in a log leaves an operator guessing which character to change.
    func testInvalidDomainErrorDescription() {
        let error = DNSValidationError.invalidDomain(
            "bad;domain",
            reason: .invalidCharacter(";", label: "bad;domain")
        )
        XCTAssertTrue(error.errorDescription!.contains("bad;domain"))
        XCTAssertTrue(error.errorDescription!.contains("';'"))
    }

    func testInvalidServerErrorDescription() {
        let error = DNSValidationError.invalidServer("not-an-ip")
        XCTAssertTrue(error.errorDescription!.contains("not-an-ip"))
    }
}
