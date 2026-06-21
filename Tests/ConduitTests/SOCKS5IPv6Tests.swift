// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class SOCKS5IPv6Tests: XCTestCase {

    func testIPv6AddressFormattedWithBracketsForConnect() {
        let host = "2001:db8:0:0:0:0:0:1"
        let port: UInt16 = 443
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        XCTAssertEqual(target, "[2001:db8:0:0:0:0:0:1]:443")
    }

    func testIPv4AddressNotBracketed() {
        let host = "10.0.0.1"
        let port: UInt16 = 80
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        XCTAssertEqual(target, "10.0.0.1:80")
    }

    func testIPv6BytesParsedCorrectly() {
        // ::1 in 16 bytes
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let parts = stride(from: 0, to: 16, by: 2).map { i in
            String(format: "%x", UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
        }
        let host = parts.joined(separator: ":")
        XCTAssertEqual(host, "0:0:0:0:0:0:0:1")
    }

    func testIPv6BytesParsedForRealAddress() {
        // 2001:0db8::0001
        let bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let parts = stride(from: 0, to: 16, by: 2).map { i in
            String(format: "%x", UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
        }
        let host = parts.joined(separator: ":")
        XCTAssertEqual(host, "2001:db8:0:0:0:0:0:1")
    }
}
