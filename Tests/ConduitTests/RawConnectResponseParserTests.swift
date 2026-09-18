// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import XCTest
@testable import ProxyKernel

final class RawConnectResponseParserTests: XCTestCase {
    private let challenge = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate fixture\r\n"

    private func buffer(_ text: String) -> ByteBuffer {
        var result = ByteBuffer()
        result.writeString(text)
        return result
    }

    func testInvalidContentLengthsThrowWithoutMovingReader() {
        for value in ["-65536", "-1", "+1", "", "garbage", "1, 1", "65536", "18446744073709551616"] {
            var input = buffer(challenge + "Content-Length: \(value)\r\n\r\n")
            XCTAssertThrowsError(try RawConnectResponseParser.parse(&input), value)
            XCTAssertEqual(input.readerIndex, 0)
        }
    }

    func testAmbiguousFramingAndUnsupportedEncodingsThrow() {
        for fields in [
            "Content-Length: 0\r\nContent-Length: 1",
            "Content-Length: 0\r\nContent-Length: 0",
            "Content-Length: 0\r\nTransfer-Encoding: chunked",
            "Transfer-Encoding: gzip, chunked",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked",
        ] {
            var input = buffer(challenge + fields + "\r\n\r\n0\r\n\r\n")
            XCTAssertThrowsError(try RawConnectResponseParser.parse(&input), fields)
        }
    }

    func testMalformedStatusAndFieldsThrow() {
        for text in [
            "HTTP/1.1 +200 OK\r\n\r\n", "HTTP/2 407 Nope\r\n\r\n",
            challenge + "Content-Length : 0\r\n\r\n",
            challenge + "Missing-Colon\r\n\r\n",
            challenge + " Folded: header\r\n\r\n",
            challenge + "Bad: value\u{0}\r\n\r\n",
        ] {
            var input = buffer(text)
            XCTAssertThrowsError(try RawConnectResponseParser.parse(&input), text)
        }
    }

    func testBinaryBodyAndNonASCIIHeadersUseByteOffsets() throws {
        var input = buffer(challenge + "X-Text: café\r\nContent-Length: 4\r\n\r\n")
        input.writeBytes([0xff, 0, 13, 10])
        input.writeString("NEXT")
        let response = try XCTUnwrap(RawConnectResponseParser.parse(&input))
        XCTAssertEqual(response.statusCode, 407)
        XCTAssertEqual(response.headers(named: "proxy-authenticate"), ["Negotiate fixture"])
        XCTAssertEqual(input.readString(length: input.readableBytes), "NEXT")
    }

    func testFixedLengthResponseAtEverySplitPoint() throws {
        let bytes = Array((challenge + "Content-Length: 4\r\n\r\nBODY").utf8)
        try assertEverySplit(bytes)
    }

    func testChunkedBinaryBodyExtensionsAndTrailersAtEverySplitPoint() throws {
        var bytes = Array((challenge + "Transfer-Encoding: chunked\r\n\r\n4;name=value\r\n").utf8)
        bytes += [0xff, 0, 13, 10]
        bytes += Array("\r\n0\r\nX-Trailer: yes\r\n\r\n".utf8)
        try assertEverySplit(bytes)
    }

    private func assertEverySplit(_ bytes: [UInt8]) throws {
        for split in 0..<bytes.count {
            var input = ByteBuffer()
            input.writeBytes(bytes[..<split])
            XCTAssertNil(try RawConnectResponseParser.parse(&input), "split=\(split)")
            XCTAssertEqual(input.readerIndex, 0)
            input.writeBytes(bytes[split...])
            XCTAssertEqual(try RawConnectResponseParser.parse(&input)?.statusCode, 407)
            XCTAssertEqual(input.readableBytes, 0)
        }
    }

    func testEmptyChunkedBodyCompletesWithoutAnExtraCRLF() throws {
        var input = buffer(challenge + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\nNEXT")
        XCTAssertEqual(try RawConnectResponseParser.parse(&input)?.statusCode, 407)
        XCTAssertEqual(input.readString(length: input.readableBytes), "NEXT")
    }

    func testInvalidChunkLengthsAndFramingThrow() {
        for body in ["-1\r\n", "+1\r\n", "FFFFFFFFFFFFFFFFFFFFFFFF\r\n", "1\r\naXX", "0\r\nContent-Length: 1\r\n\r\n"] {
            var input = buffer(challenge + "Transfer-Encoding: chunked\r\n\r\n" + body)
            XCTAssertThrowsError(try RawConnectResponseParser.parse(&input), body)
            XCTAssertEqual(input.readerIndex, 0)
        }
    }

    func testSuccessfulConnectIgnoresBodyFramingAndLeavesBinaryTunnelBytes() throws {
        var input = buffer("HTTP/1.1 200 Connection Established\r\nContent-Length: -65536\r\nTransfer-Encoding: chunked\r\n\r\n")
        let tunnel: [UInt8] = [0xff, 0, 1, 13, 10]
        input.writeBytes(tunnel)
        XCTAssertEqual(try RawConnectResponseParser.parse(&input)?.statusCode, 200)
        XCTAssertEqual(input.readBytes(length: input.readableBytes), tunnel)
    }

    func testNonzeroReaderIndex() throws {
        var input = buffer("PREFIX" + challenge + "Content-Length: 0\r\n\r\n")
        input.moveReaderIndex(forwardBy: 6)
        XCTAssertEqual(try RawConnectResponseParser.parse(&input)?.statusCode, 407)
        XCTAssertEqual(input.readableBytes, 0)
    }

    func testAccumulationLimit() {
        var input = ByteBuffer()
        input.writeRepeatingByte(65, count: RawConnectResponseParser.maxResponseBytes + 1)
        XCTAssertThrowsError(try RawConnectResponseParser.parse(&input))
    }

    @MainActor
    func testMalformedResponseFailsLiveHandshakeAndReleasesPoolSlot() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        for fieldsAndBody in ["Content-Length: -65536\r\n\r\n", "Transfer-Encoding: chunked\r\n\r\n-1\r\n"] {
            let response = challenge + fieldsAndBody
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(MalformedConnectResponseFixture(response: response))
                }
                .bind(host: "127.0.0.1", port: 0).get()
            addTeardownBlock { try await server.close().get() }
            var config = ProxyConfig.testFixture()
            config.upstreamResponseTimeoutSeconds = 2
            config.upstreams = [UpstreamProxy(name: "Fixture", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0)]
            let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { config },
                                      authenticatorProvider: { _ in ConnectFramingFixtureAuthenticator() })
            defer { pool.closeAll() }
            let rejections = NIOLockedValueBox(0)
            let coordinator = CONNECTCoordinator(
                pool: pool, authenticatorProvider: { _ in ConnectFramingFixtureAuthenticator() },
                logger: DiscardingLogSink(), eventSink: { event in
                    if event.event == "connection.upstream_invalid_response" {
                        rejections.withLockedValue { $0 += 1 }
                    }
                })
            do {
                _ = try await coordinator.connectUpstreamTunnel(target: "example.test:443").get()
                XCTFail("Malformed framing must fail the handshake")
            } catch {
                guard case ConnectionPoolError.invalidResponse = error else {
                    return XCTFail("Expected invalid framing, got \(error)")
                }
            }
            XCTAssertEqual(rejections.withLockedValue { $0 }, 1)
            XCTAssertTrue(pool.allConnectionSnapshot.isEmpty)
        }
    }
}

private final class MalformedConnectResponseFixture: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let response: String
    private var sent = false
    init(response: String) { self.response = response }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !sent else { return }
        sent = true
        var bytes = context.channel.allocator.buffer(capacity: response.utf8.count)
        bytes.writeString(response)
        context.writeAndFlush(NIOAny(bytes), promise: nil)
    }
}

private final class ConnectFramingFixtureAuthenticator: ProxyAuthenticator, Sendable {
    let scheme = "Fixture"
    func initialToken(for host: String) throws -> String { "Fixture initial" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { "Fixture response" }
    func canHandle(scheme: String) -> Bool { scheme == self.scheme }
    func reset() {}
}
