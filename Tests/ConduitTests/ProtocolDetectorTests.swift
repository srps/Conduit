// SPDX-License-Identifier: Apache-2.0
import NIOCore
import XCTest
@testable import ProxyKernel

final class ProtocolDetectorTests: XCTestCase {

    private func makeBuffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        return buf
    }

    private func leBytes(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func beBytes(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    // MARK: - MongoDB

    func testDetectMongoDB_OP_MSG() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(100))   // messageLength
        bytes.append(contentsOf: leBytes(1))     // requestID
        bytes.append(contentsOf: leBytes(0))     // responseTo
        bytes.append(contentsOf: leBytes(2013))  // opCode = OP_MSG
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    func testDetectMongoDB_OP_QUERY() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(200))   // messageLength
        bytes.append(contentsOf: leBytes(42))    // requestID
        bytes.append(contentsOf: leBytes(0))     // responseTo
        bytes.append(contentsOf: leBytes(2004))  // opCode = OP_QUERY
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    func testDetectMongoDB_OP_COMPRESSED() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(64))
        bytes.append(contentsOf: leBytes(7))
        bytes.append(contentsOf: leBytes(0))
        bytes.append(contentsOf: leBytes(2012))  // OP_COMPRESSED
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    func testDetectMongoDB_OP_REPLY() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(36))
        bytes.append(contentsOf: leBytes(0))
        bytes.append(contentsOf: leBytes(1))
        bytes.append(contentsOf: leBytes(1))  // OP_REPLY
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    func testRejectInvalidMongoDBOpcode() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(100))
        bytes.append(contentsOf: leBytes(1))
        bytes.append(contentsOf: leBytes(0))
        bytes.append(contentsOf: leBytes(9999))  // invalid opcode
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    func testRejectMongoDBTooSmallMessageLength() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: leBytes(4))  // too small — minimum is 16
        bytes.append(contentsOf: leBytes(1))
        bytes.append(contentsOf: leBytes(0))
        bytes.append(contentsOf: leBytes(2013))
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mongodb)
    }

    // MARK: - TLS

    func testDetectTLS12ClientHello() {
        let bytes: [UInt8] = [0x16, 0x03, 0x03, 0x01, 0x00]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .tls)
    }

    func testDetectTLS10ClientHello() {
        let bytes: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0xF1]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .tls)
    }

    func testDetectTLS13ClientHello() {
        let bytes: [UInt8] = [0x16, 0x03, 0x04, 0x02, 0x00]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .tls)
    }

    func testRejectNonTLS() {
        let bytes: [UInt8] = [0x15, 0x03, 0x03, 0x01, 0x00]  // 0x15 = alert, not handshake
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .tls)
    }

    // MARK: - PostgreSQL

    func testDetectPostgreSQLSSLRequest() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: beBytes(8))          // length
        bytes.append(contentsOf: beBytes(80877103))   // SSL request magic
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .postgresql)
    }

    func testDetectPostgreSQLStartup() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: beBytes(50))      // length
        bytes.append(contentsOf: beBytes(196608))  // protocol 3.0
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .postgresql)
    }

    // MARK: - Redis

    func testDetectRedisArray() {
        let bytes: [UInt8] = Array("*3\r\n$3\r\nSET\r\n".utf8)
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .redis)
    }

    func testDetectRedisPing() {
        let bytes: [UInt8] = Array("*1\r\n$4\r\nPING\r\n".utf8)
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .redis)
    }

    func testRejectNonRedis() {
        let bytes: [UInt8] = Array("GET / HTTP/1.1\r\n".utf8)
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .redis)
    }

    // MARK: - MySQL

    func testDetectMySQLGreeting() {
        // MySQL server greeting: 3-byte length (LE) + seq=0 + protocol=0x0A + "8.0.0\0"
        var bytes: [UInt8] = []
        let serverVersion = Array("8.0.0\0".utf8)
        let payloadLength = 1 + serverVersion.count + 4 + 8 + 1 + 2 + 1 // minimal greeting fields
        bytes.append(UInt8(payloadLength & 0xFF))
        bytes.append(UInt8((payloadLength >> 8) & 0xFF))
        bytes.append(UInt8((payloadLength >> 16) & 0xFF))
        bytes.append(0x00) // sequence ID
        bytes.append(0x0A) // protocol version 10
        bytes.append(contentsOf: serverVersion)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: payloadLength - 1 - serverVersion.count))
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mysql)
    }

    func testRejectNonMySQLSequenceID() {
        var bytes: [UInt8] = [50, 0, 0, 0x01, 0x0A]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 50))
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mysql)
    }

    func testRejectNonMySQLProtocolVersion() {
        var bytes: [UInt8] = [50, 0, 0, 0x00, 0x09]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 50))
        XCTAssertNotEqual(ProtocolDetector.detect(makeBuffer(bytes)), .mysql)
    }

    // MARK: - AMQP

    func testDetectAMQP() {
        let bytes: [UInt8] = [0x41, 0x4D, 0x51, 0x50, 0x00, 0x00, 0x09, 0x01]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .amqp)
    }

    // MARK: - HTTP/2

    func testDetectHTTP2Preface() {
        let bytes: [UInt8] = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .http2)
    }

    // MARK: - Unknown / Edge Cases

    func testUnknownProtocol() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .unknown)
    }

    func testTooFewBytes() {
        let bytes: [UInt8] = [0x16, 0x03]
        XCTAssertEqual(ProtocolDetector.detect(makeBuffer(bytes)), .unknown)
    }

    func testEmptyBuffer() {
        let buf = ByteBufferAllocator().buffer(capacity: 0)
        XCTAssertEqual(ProtocolDetector.detect(buf), .unknown)
    }

    func testDisplayNames() {
        XCTAssertEqual(DetectedProtocol.mongodb.displayName, "MongoDB")
        XCTAssertEqual(DetectedProtocol.tls.displayName, "TLS/SSL")
        XCTAssertEqual(DetectedProtocol.postgresql.displayName, "PostgreSQL")
        XCTAssertEqual(DetectedProtocol.mysql.displayName, "MySQL")
        XCTAssertEqual(DetectedProtocol.redis.displayName, "Redis")
        XCTAssertEqual(DetectedProtocol.amqp.displayName, "AMQP")
        XCTAssertEqual(DetectedProtocol.http2.displayName, "HTTP/2")
        XCTAssertEqual(DetectedProtocol.unknown.displayName, "Unknown")
    }
}
