// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Independent review witnesses: a transport body can bypass the encoder/bridge. The
/// aggregate bypass budget is a different bound from entry count and per-item UTF-8.
final class PrivateConfigResourceReviewTests: XCTestCase {
    func testDirectDecoderRejectsTheAggregateBypassBudgetWhenEveryItemAndCountFits() throws {
        let host = longDomain(lastLabel: 61)
        let hosts = Array(repeating: host, count: 32)
        XCTAssertEqual(host.utf8.count, 253)
        XCTAssertEqual(try JSONEncoder().encode(hosts).count, 8193)
        try assertLimit(.noProxyList, limit: 8192, body: fullBody(noProxyHosts: hosts))
    }

    func testAggregateBudgetRefusalPrecedesMissingRequiredFieldsAndMalformedSuffix() throws {
        let hosts = Array(repeating: longDomain(lastLabel: 61), count: 32)
        let list = try JSONEncoder().encode(hosts)
        var bytes = Array(#"{"runtime":{"routing":{"noProxyHosts":"#.utf8)
        bytes.append(contentsOf: list)
        // No required request metadata, and invalid UTF-8 after the over-budget list.
        // A later Foundation/decode/grammar failure must not replace this resource refusal.
        bytes.append(0xFF)
        assertLimit(.noProxyList, limit: 8192, bytes: bytes)
    }

    func testBypassBudgetCountsCanonicalEncodingRatherThanPhysicalWireSpelling() throws {
        let hosts = Array(repeating: String(repeating: "/", count: 253), count: 17)
        XCTAssertGreaterThan(try JSONEncoder().encode(hosts).count, 8192)
        // A raw private value can be resource-invalid and domain-invalid independently.
        // The resource check must happen before a domain object is allocated/validated.
        try assertLimit(.noProxyList, limit: 8192, body: fullBody(noProxyHosts: hosts))
    }

    func testNinthProviderIsRefusedBeforeItsMalformedValueIsScanned() {
        let eight = Array(repeating: #""""#, count: 8).joined(separator: ",")
        var bytes = Array((#"{"runtime":{"dns":{"dohProviders":["# + eight + ",").utf8)
        bytes.append(0xFF)
        assertLimit(.dohProviders, limit: 8, bytes: bytes)
    }

    func testDisplayByteLimitIsRefusedBeforeLaterInvalidUTF8() {
        var bytes = Array((#"{"runtime":{"profileName":""# + String(repeating: "x", count: 1025)).utf8)
        bytes.append(0xFF)
        assertLimit(.profileName, limit: 1024, bytes: bytes)
    }

    func testScannerObjectTablesMatchTheActualEncoderKeySets() throws {
        let data = try fullBody(noProxyHosts: [])
        let object = try JSONSerialization.jsonObject(with: data)
        try compare(.object(PrivateConfigurationSchema.request), to: object, path: "request")
    }

    /// The read and reply roots against the encoder's actual output. The observation subtree is compared table by table.
    /// The admission table names the union of the members `ControlAdmission`'s own encoding writes across its variants.
    func testReadAndReplyTablesMatchTheActualEncoderKeySets() throws {
        let read = PrivateEditorReadRequest(
            requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(5)),
            incarnation: ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(2)),
            budget: try ControlWireBudget(5_000)
        )
        try compare(.object(PrivateConfigurationSchema.readRequest), to: jsonBody(PrivateConfigurationEncoder.encode(read)), path: "read")

        let observation = try PrivateEditorMaximumFixture.reply(distinct: false)
        let replyObject = try XCTUnwrap(jsonBody(PrivateConfigurationEncoder.encode(observation)) as? [String: Any])
        let rootNames = PrivateConfigurationSchema.editorReply.members.map { String(decoding: $0.name, as: UTF8.self) }
        XCTAssertEqual(Set(replyObject.keys), Set(rootNames))
        try compare(.object(PrivateConfigurationSchema.observation), to: XCTUnwrap(replyObject["observation"]), path: "observation")

        let operation = ControlOperationID(rawValue: PrivateConfigSamples.uuid(70))
        var admissionKeys = Set<String>()
        for admission in [ControlAdmission.accepted(operation), .joined(operation), .rejected(.queueFull)] {
            let reply = PrivateEditorReply(requestID: read.requestID, hostIncarnation: read.incarnation, answer: .admission(admission))
            let object = try XCTUnwrap(jsonBody(PrivateConfigurationEncoder.encode(reply)) as? [String: Any])
            admissionKeys.formUnion(try XCTUnwrap(object["admission"] as? [String: Any]).keys)
        }
        XCTAssertEqual(admissionKeys, Set(PrivateConfigurationSchema.admission.members.map { String(decoding: $0.name, as: UTF8.self) }))
    }

    private func jsonBody(_ frame: SecretBytes) throws -> Any {
        let bytes = frame.bytes()
        let start = try XCTUnwrap(bytes.firstIndex(of: 0x0A)) + 1
        return try JSONSerialization.jsonObject(with: Data(bytes[start..<(bytes.count - 1)]))
    }

    /// Compare independently materialized encoder JSON with every object table the
    /// scanner traverses. A newly encoded or omitted member cannot silently drift.
    private func compare(_ shape: PrivateValueShape, to value: Any, path: String) throws {
        switch shape {
        case .object(let object):
            let actual = try XCTUnwrap(value as? [String: Any], path)
            let names = object.members.map { String(decoding: $0.name, as: UTF8.self) }
            XCTAssertEqual(Set(actual.keys), Set(names), path)
            XCTAssertEqual(Set(names).count, object.members.count, "duplicate schema name at \(path)")
            for member in object.members {
                let name = String(decoding: member.name, as: UTF8.self)
                try compare(member.shape, to: XCTUnwrap(actual[name], path), path: path + "." + name)
            }
        case .array(_, let element):
            let actual = try XCTUnwrap(value as? [Any], path)
            if case .object = element {
                XCTAssertFalse(actual.isEmpty, "fixture must exercise nested object table at \(path)")
            }
            for (index, value) in actual.enumerated() {
                try compare(element, to: value, path: path + "[\(index)]")
            }
        case .nullable(let inner):
            // A null member has no table below it. A present one is compared as its wrapped shape.
            if !(value is NSNull) {
                try compare(inner, to: value, path: path)
            }
        case .string, .bool, .number, .unsignedDecimal:
            break // Existing encoded round-trip tests pin primitive value semantics.
        }
    }

    private func longDomain(lastLabel: Int) -> String {
        [63, 63, 63, lastLabel].map { String(repeating: "a", count: $0) }.joined(separator: ".")
    }

    private func fullBody(noProxyHosts: [String]) throws -> Data {
        let frame = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request()).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        let body = Data(frame[start..<(frame.count - 1)])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var runtime = try XCTUnwrap(root["runtime"] as? [String: Any])
        var routing = try XCTUnwrap(runtime["routing"] as? [String: Any])
        routing["noProxyHosts"] = noProxyHosts
        runtime["routing"] = routing
        root["runtime"] = runtime
        // Deliberately choose a different physical spelling from JSONEncoder's slash policy.
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    private func assertLimit(
        _ field: DomainResourceField, limit: Int, body: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertLimit(field, limit: limit, bytes: Array(body), file: file, line: line)
    }

    private func assertLimit(
        _ field: DomainResourceField, limit: Int, bytes: [UInt8],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(
            PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(bytes))), file: file, line: line) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError,
                           .resourceLimitExceeded(DomainResourceViolation(field, limit)), file: file, line: line)
        }
    }
}
