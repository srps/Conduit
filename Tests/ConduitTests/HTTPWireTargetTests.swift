// SPDX-License-Identifier: Apache-2.0
import NIOHTTP1
import XCTest
@testable import ProxyKernel

final class HTTPWireTargetTests: XCTestCase {
    func testOriginFormPreservesEncodedSyntax() throws {
        let cases = [
            ("", "/"), ("?", "/?"), ("/?", "/?"),
            ("/a%2Fb/%3F/%23/%25", "/a%2Fb/%3F/%23/%25"),
            ("/a%2fb?key=1&key=2&next=%2F%3F&empty=", "/a%2fb?key=1&key=2&next=%2F%3F&empty="),
            ("/safe%20HTTP/1.1%0D%0AX-Injected:%20yes", "/safe%20HTTP/1.1%0D%0AX-Injected:%20yes"),
            ("/caf%C3%A9?q=%0D%0A#discard", "/caf%C3%A9?q=%0D%0A"),
            ("/café", "/caf%C3%A9"), ("/#discard", "/"),
        ]
        for (suffix, expected) in cases {
            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.test\(suffix)")
            XCTAssertEqual(try XCTUnwrap(HTTPRequestTarget.parse(head)).originForm, expected, suffix)
            if suffix.hasPrefix("/") {
                head.uri = suffix
                head.headers.add(name: "Host", value: "example.test")
                XCTAssertEqual(try XCTUnwrap(HTTPRequestTarget.parse(head)).originForm, expected, suffix)
            }
        }
    }

    func testAbsoluteAndOriginTargetsRejectLiteralControlsAndSpaces() {
        for invalid in ["/a\r\nb", "/a\u{0}b", "/a\u{7f}b", "/a b", "/a\tb"] {
            for uri in [invalid, "http://example.test\(invalid)"] {
                var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
                head.headers.add(name: "Host", value: "example.test")
                XCTAssertNil(HTTPRequestTarget.parse(head), uri.debugDescription)
            }
        }
    }
}
