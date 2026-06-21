// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import ProxyKernel

final class HTTPExpectContinueTests: XCTestCase {

    private func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTPResponseEncoder(), name: ProxyPipelineNames.serverEncoder)
        try channel.pipeline.syncOperations.addHandler(
            HTTPExpectContinueHandler(), name: ProxyPipelineNames.serverExpectContinue)
        return channel
    }

    private func drainOutbound(_ channel: EmbeddedChannel) throws -> String {
        var collected = ""
        while let out: ByteBuffer = try channel.readOutbound() {
            collected += String(buffer: out)
        }
        return collected
    }

    func testAnswers100ContinueAndStripsExpectation() throws {
        let channel = try makeChannel()

        var head = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "http://origin.example/upload")
        head.headers.add(name: "Host", value: "origin.example")
        head.headers.add(name: "Expect", value: "100-Continue")
        head.headers.add(name: "Content-Length", value: "5")
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        let wire = try drainOutbound(channel)
        XCTAssertTrue(wire.contains("HTTP/1.1 100 Continue"), "proxy must answer the expectation itself; got: \(wire)")

        let forwarded = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head(let inner)? = forwarded else {
            return XCTFail("head must continue inward")
        }
        XCTAssertTrue(inner.headers["Expect"].isEmpty, "satisfied expectation must not be forwarded upstream")
        XCTAssertEqual(inner.headers["Content-Length"], ["5"], "other headers untouched")
    }

    func testPassesThroughWithoutExpectation() throws {
        let channel = try makeChannel()

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.example/")
        head.headers.add(name: "Host", value: "origin.example")
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        XCTAssertEqual(try drainOutbound(channel), "", "no interim response without Expect")
        let forwarded = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head(let inner)? = forwarded else {
            return XCTFail("head must continue inward")
        }
        XCTAssertEqual(inner.headers["Host"], ["origin.example"])
    }

    func testPreservesUnknownExpectations() throws {
        let channel = try makeChannel()

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "http://origin.example/x")
        head.headers.add(name: "Expect", value: "100-continue, x-custom-expectation")
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        XCTAssertTrue(try drainOutbound(channel).contains("100 Continue"))
        let forwarded = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head(let inner)? = forwarded else {
            return XCTFail("head must continue inward")
        }
        XCTAssertEqual(inner.headers["Expect"], ["x-custom-expectation"], "unknown expectations are the origin's to judge (417)")
    }

    /// The load-bearing encoder assumption: an informational `100` head
    /// followed by the real response head + end must encode cleanly through
    /// the same `HTTPResponseEncoder`. If this ever regresses in NIO, the
    /// whole approach needs rework — fail loudly here, not in the field.
    func testEncoderAcceptsFinalResponseAfterInterim100() throws {
        let channel = try makeChannel()

        var head = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "http://origin.example/upload")
        head.headers.add(name: "Expect", value: "100-continue")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        XCTAssertTrue(try drainOutbound(channel).contains("100 Continue"))

        var final = HTTPResponseHead(version: .http1_1, status: .ok)
        final.headers.add(name: "Content-Length", value: "2")
        try channel.writeOutbound(HTTPServerResponsePart.head(final))
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("ok")
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(body)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))

        let wire = try drainOutbound(channel)
        XCTAssertTrue(wire.contains("HTTP/1.1 200 OK"), "final response must encode after the interim 100; got: \(wire)")
        XCTAssertTrue(wire.hasSuffix("ok"))
    }
}
