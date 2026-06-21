// SPDX-License-Identifier: Apache-2.0
import NIOCore

package enum DetectedProtocol: String, Sendable, Equatable {
    case mongodb
    case tls
    case postgresql
    case mysql
    case redis
    case amqp
    case http2
    case unknown

    package var displayName: String {
        switch self {
        case .mongodb: return "MongoDB"
        case .tls: return "TLS/SSL"
        case .postgresql: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        case .amqp: return "AMQP"
        case .http2: return "HTTP/2"
        case .unknown: return "Unknown"
        }
    }

    package var defaultPort: Int {
        switch self {
        case .mongodb: return 27017
        case .tls: return 443
        case .postgresql: return 5432
        case .mysql: return 3306
        case .redis: return 6379
        case .amqp: return 5672
        case .http2: return 443
        case .unknown: return 0
        }
    }
}

/// Zero-copy protocol sniffer. Reads fields directly from the ByteBuffer's
/// backing storage via getInteger(at:endianness:) -- no array copies.
package enum ProtocolDetector {

    package static func detect(_ buffer: ByteBuffer) -> DetectedProtocol {
        let readable = buffer.readableBytes
        guard readable >= 4 else { return .unknown }
        let base = buffer.readerIndex

        if readable >= 16, isMongoDB(buffer, at: base) { return .mongodb }
        if readable >= 5, isTLS(buffer, at: base) { return .tls }
        if readable >= 8, isPostgreSQL(buffer, at: base) { return .postgresql }
        if readable >= 5, isMySQL(buffer, at: base, readable: readable) { return .mysql }
        if readable >= 4, isAMQP(buffer, at: base) { return .amqp }
        if readable >= 24, isHTTP2(buffer, at: base) { return .http2 }
        if readable >= 4, isRedis(buffer, at: base, readable: readable) { return .redis }

        return .unknown
    }

    // MARK: - MongoDB Wire Protocol
    // Header: messageLength(4 LE) + requestID(4) + responseTo(4) + opCode(4 LE)

    private static func isMongoDB(_ buf: ByteBuffer, at base: Int) -> Bool {
        guard let messageLength: Int32 = buf.getInteger(at: base, endianness: .little),
              let opCode: Int32 = buf.getInteger(at: base + 12, endianness: .little)
        else { return false }
        let validOpcodes: Set<Int32> = [1, 2004, 2012, 2013]
        return messageLength >= 16 && messageLength < 48_000_000 && validOpcodes.contains(opCode)
    }

    // MARK: - TLS ClientHello
    // Byte 0: 0x16 (handshake), bytes 1-2: version (0x0301..0x0304)

    private static func isTLS(_ buf: ByteBuffer, at base: Int) -> Bool {
        guard let contentType: UInt8 = buf.getInteger(at: base),
              let major: UInt8 = buf.getInteger(at: base + 1),
              let minor: UInt8 = buf.getInteger(at: base + 2)
        else { return false }
        return contentType == 0x16 && major == 0x03 && minor >= 0x01 && minor <= 0x04
    }

    // MARK: - PostgreSQL
    // SSLRequest: length=8 (BE), magic=80877103
    // StartupMessage: length (BE), protocol 196608 (3.0)

    private static func isPostgreSQL(_ buf: ByteBuffer, at base: Int) -> Bool {
        guard let length: Int32 = buf.getInteger(at: base, endianness: .big),
              let code: Int32 = buf.getInteger(at: base + 4, endianness: .big)
        else { return false }
        if length == 8 && code == 80877103 { return true }
        if length >= 8 && length < 10000 && code == 196608 { return true }
        return false
    }

    // MARK: - Redis RESP
    // Starts with *N\r\n where N is a digit

    private static func isRedis(_ buf: ByteBuffer, at base: Int, readable: Int) -> Bool {
        guard let first: UInt8 = buf.getInteger(at: base), first == 0x2A,
              let second: UInt8 = buf.getInteger(at: base + 1),
              second >= 0x30, second <= 0x39
        else { return false }
        let scanEnd = min(readable, 8)
        for i in 2 ..< scanEnd - 1 {
            guard let b0: UInt8 = buf.getInteger(at: base + i),
                  let b1: UInt8 = buf.getInteger(at: base + i + 1)
            else { break }
            if b0 == 0x0D && b1 == 0x0A { return true }
        }
        return false
    }

    // MARK: - MySQL
    // Server greeting: 3-byte payload length (LE) + sequence 0x00 + protocol version 0x0A
    // Payload length is typically 50..200 bytes for the initial handshake.

    private static func isMySQL(_ buf: ByteBuffer, at base: Int, readable: Int) -> Bool {
        guard let b0: UInt8 = buf.getInteger(at: base),
              let b1: UInt8 = buf.getInteger(at: base + 1),
              let b2: UInt8 = buf.getInteger(at: base + 2),
              let seqID: UInt8 = buf.getInteger(at: base + 3),
              let protocolVersion: UInt8 = buf.getInteger(at: base + 4)
        else { return false }
        let payloadLength = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16)
        return seqID == 0x00 && protocolVersion == 0x0A && payloadLength >= 7 && payloadLength < 65536
    }

    // MARK: - AMQP
    // Protocol header: "AMQP" (0x41 0x4D 0x51 0x50)

    private static func isAMQP(_ buf: ByteBuffer, at base: Int) -> Bool {
        guard let magic: UInt32 = buf.getInteger(at: base, endianness: .big) else { return false }
        return magic == 0x414D_5150
    }

    // MARK: - HTTP/2
    // Connection preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" (24 bytes)

    private static let http2PrefaceHead: UInt64 = 0x5052_4920_2A20_4854  // "PRI * HT"

    private static func isHTTP2(_ buf: ByteBuffer, at base: Int) -> Bool {
        guard let head: UInt64 = buf.getInteger(at: base, endianness: .big) else { return false }
        guard head == http2PrefaceHead else { return false }
        guard let tail: UInt64 = buf.getInteger(at: base + 8, endianness: .big),
              tail == 0x5450_2F32_2E30_0D0A // "TP/2.0\r\n"
        else { return false }
        return true
    }
}
