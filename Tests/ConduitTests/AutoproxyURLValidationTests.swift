// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitShared

final class AutoproxyURLValidationTests: XCTestCase {

    func testAcceptsHTTP() {
        XCTAssertTrue(HelperInputValidator.validateAutoproxyURL("http://pac.example.test/proxy.pac"))
    }

    func testAcceptsHTTPS() {
        XCTAssertTrue(HelperInputValidator.validateAutoproxyURL("https://secure.example.com/proxy.pac"))
    }

    func testAcceptsLocalhostHTTP() {
        XCTAssertTrue(HelperInputValidator.validateAutoproxyURL("http://127.0.0.1:8080/proxy.pac"))
    }

    func testAcceptsLocalhostHTTPS() {
        XCTAssertTrue(HelperInputValidator.validateAutoproxyURL("https://localhost:9443/pac"))
    }

    func testRejectsFileURL() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("file:///etc/passwd"))
    }

    func testRejectsFTPURL() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("ftp://evil.com/pac"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL(""))
    }

    func testRejectsGarbage() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("not a url at all"))
    }

    func testRejectsBareHostname() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("example.com"))
    }

    func testRejectsJavascriptScheme() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("javascript:alert(1)"))
    }

    func testRejectsDataScheme() {
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("data:text/plain,hello"))
    }
}
