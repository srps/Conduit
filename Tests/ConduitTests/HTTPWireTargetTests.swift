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

    func testDirectForwardReplacesHostWithTheAbsoluteTargetAuthority() throws {
        let cases: [(uri: String, hosts: [String], expected: String)] = [
            ("http://a.example/p", ["b.internal"], "a.example"),
            ("http://a.example:8080/p?q", ["a.example", "b.internal"], "a.example:8080"),
            ("http://[::1]:8080#f", [], "[::1]:8080"),
            ("http://a.example?q", ["a.example"], "a.example"),
            ("/p", ["origin.example:81"], "origin.example:81"),
        ]
        for (uri, hosts, expected) in cases {
            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
            for host in hosts { head.headers.add(name: "Host", value: host) }
            let forwarded = try XCTUnwrap(HTTPRequestTarget.parse(head)?.directRequestHead(from: head), uri)
            XCTAssertEqual(forwarded.headers["Host"], [expected], uri)
        }
    }

    func testAbsoluteTargetWithUnsafeAuthorityIsRejected() {
        for uri in ["http://a.example\\b/", "http://user@a.example/"] {
            XCTAssertNil(HTTPRequestTarget.parse(HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)), uri)
        }
    }
}
