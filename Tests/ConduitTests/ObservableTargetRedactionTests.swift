// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
import ConduitShared

final class ObservableTargetRedactionTests: XCTestCase {
    func testObservedTargetsHideSuffixesWithoutChangingPathOrAuthority() throws {
        let cases = [
            ("http://example.test/p%3Fkeep?sig=short#fragment", "http://example.test/p%3Fkeep?<redacted>"),
            ("/p%23keep#fragment?short", "/p%23keep#<redacted>"),
            ("/path?short", "/path?<redacted>"),
            ("[::1]:443", "[::1]:443"),
            ("example.test:443", "example.test:443"),
            ("http://[broken/path?short", "http://[broken/path?<redacted>"),
        ]
        for (wire, expected) in cases {
            XCTAssertEqual(SensitiveValueSanitizer.observableTarget(wire), expected)
            XCTAssertEqual(SensitiveValueSanitizer.auditTarget(wire), expected)
            XCTAssertEqual(SensitiveValueSanitizer.observableTarget(expected), expected)
            let record = ActiveConnectionInfo(destination: wire, upstream: "DIRECT", method: "GET")
            XCTAssertEqual(record.destination, expected)
            let encoded = try CanonicalJSON.encoder().encode(record)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["destination"] as? String, expected)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("short"))
        }
    }

    func testLogsEventsAndDiagnosticExportsShareURLPrivacyContract() throws {
        for value in [
            "GET http://example.test/path?sig=short#fragment failed",
            "GET HTTPS://example.test/path#fragment failed",
            "http://user:password@example.test/path?sig=short",
            "http://[broken/path?sig=short",
        ] {
            let log = RecordingLogSink()
            log.log(.warning, value, category: .proxy)
            let event = RuntimeEvent(kind: .routing, event: "routing.test", detail: value)
            let kernel = SensitiveValueSanitizer.sanitize(value)
            let shared = ControlDiagnostics.sanitizeString(value)
            XCTAssertEqual(kernel, shared)
            XCTAssertEqual(SensitiveValueSanitizer.sanitize(kernel), kernel)
            XCTAssertEqual(ControlDiagnostics.sanitizeString(shared), shared)
            let data = try CanonicalJSON.encoder().encode(event)
            for output in [kernel, shared, log.entries()[0].message, String(decoding: data, as: UTF8.self)] {
                for secret in ["short", "fragment", "password"] { XCTAssertFalse(output.contains(secret)) }
            }
        }
        let legacy = Data(#"{"destination":"/path?sig=short","uri":"/path#fragment","detail":"https://example.test/?sig=short"}"#.utf8)
        let exported = String(decoding: try ControlDiagnostics.sanitizedJSONData(from: legacy), as: UTF8.self)
        XCTAssertFalse(exported.contains("short"))
        XCTAssertFalse(exported.contains("fragment"))
    }
}
