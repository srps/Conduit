// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

final class NTLMAuthTests: XCTestCase {

    // MARK: - NT Hash

    func testNTHashMatchesKnownValue() throws {
        let hash = try NTLMAuth.ntHash(for: "Password")
        // `NTLMAuth.ntHash` now returns SecretBytes;
        // reach the raw bytes explicitly through `withUnsafeBytes` for
        // this hex comparison (the only test that validates the bit
        // pattern; production code never reads raw ntHash bytes outside
        // CCHmac calls that take `UnsafeBufferPointer` directly).
        let hex = hash.withUnsafeBytes { buf in
            buf.map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(hex, "a4f49c406510bdcab6824ee7c30fd852")
    }

    func testNTHashEmptyPassword() throws {
        let hash = try NTLMAuth.ntHash(for: "")
        XCTAssertEqual(hash.count, 16)
    }

    // MARK: - Type 1 (Negotiate) Message Layout

    func testType1HasNTLMSSPSignature() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        XCTAssertTrue(msg.starts(with: Data("NTLMSSP\0".utf8)))
    }

    func testType1MessageTypeIs1() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        XCTAssertEqual(msg.uint32LE(at: 8), 1)
    }

    func testType1FlagsMatchCNTLM() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        let flags = msg.uint32LE(at: 12)
        XCTAssertEqual(flags, 0xa208b205, "Flags should match CNTLM's NTLMv2 value")
    }

    func testType1FlagsIncludeOEMDomainSupplied() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        let flags = msg.uint32LE(at: 12)
        XCTAssertTrue(flags & 0x1000 != 0, "OEM_DOMAIN_SUPPLIED should be set")
    }

    func testType1FlagsIncludeOEMWorkstationSupplied() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        let flags = msg.uint32LE(at: 12)
        XCTAssertTrue(flags & 0x2000 != 0, "OEM_WORKSTATION_SUPPLIED should be set")
    }

    func testType1FieldOrder() throws {
        let creds = testCredentials()
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: creds))

        // Signature at 0, Type at 8, Flags at 12, DomainBuffer at 16, WorkstationBuffer at 24, Version at 32
        XCTAssertTrue(msg.count >= 40, "Header must be at least 40 bytes (includes Version)")

        let domainLen = msg.uint16LE(at: 16)
        let domainOffset = msg.uint32LE(at: 20)
        let wsLen = msg.uint16LE(at: 24)
        let wsOffset = msg.uint32LE(at: 28)

        XCTAssertEqual(Int(domainLen), "EMEA".utf8.count)
        XCTAssertEqual(Int(wsLen), "MACBOOK".utf8.count)
        XCTAssertEqual(Int(wsOffset), 40, "Workstation payload starts right after the 40-byte header")
        XCTAssertEqual(Int(domainOffset), 40 + Int(wsLen), "Domain payload follows workstation")
    }

    func testType1VersionBlockPresent() throws {
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: testCredentials()))
        let versionBytes = [UInt8](msg[32..<40])
        XCTAssertEqual(versionBytes.last, 0x0F, "NTLMRevisionCurrent should be 0x0F (W2K3)")
    }

    func testType1PayloadContainsDomainAndWorkstation() throws {
        let creds = testCredentials()
        let msg = try decode(NTLMAuth.negotiateMessage(credentials: creds))

        let domainLen = Int(msg.uint16LE(at: 16))
        let domainOffset = Int(msg.uint32LE(at: 20))
        let wsLen = Int(msg.uint16LE(at: 24))
        let wsOffset = Int(msg.uint32LE(at: 28))

        let domain = String(data: msg[domainOffset..<(domainOffset + domainLen)], encoding: .utf8)
        let workstation = String(data: msg[wsOffset..<(wsOffset + wsLen)], encoding: .utf8)

        XCTAssertEqual(domain, "EMEA")
        XCTAssertEqual(workstation, "MACBOOK")
    }

    // MARK: - Type 3 (Authenticate) Message Layout

    func testType3HasCorrectSignatureAndType() throws {
        let type2 = buildMinimalType2Challenge()
        let msg = try decode(NTLMAuth.authenticateMessage(challengeBase64: type2, credentials: testCredentials()))
        XCTAssertTrue(msg.starts(with: Data("NTLMSSP\0".utf8)))
        XCTAssertEqual(msg.uint32LE(at: 8), 3)
    }

    func testType3FieldOrder() throws {
        let type2 = buildMinimalType2Challenge()
        let msg = try decode(NTLMAuth.authenticateMessage(challengeBase64: type2, credentials: testCredentials()))

        // LM at 12, NT at 20, Domain at 28, User at 36, Workstation at 44, SessionKey at 52, Flags at 60
        XCTAssertTrue(msg.count >= 64, "Type 3 header must be at least 64 bytes")

        let lmLen = msg.uint16LE(at: 12)
        let ntLen = msg.uint16LE(at: 20)
        let domainLen = msg.uint16LE(at: 28)
        let userLen = msg.uint16LE(at: 36)
        let wsLen = msg.uint16LE(at: 44)
        let sessionLen = msg.uint16LE(at: 52)
        let flags = msg.uint32LE(at: 60)

        XCTAssertEqual(Int(lmLen), 24, "LMv2 response = 16-byte HMAC + 8-byte client nonce")
        XCTAssertTrue(ntLen > 16, "NTv2 response includes 16-byte proof + blob")
        XCTAssertEqual(Int(domainLen), "EMEA".utf16LE.count)
        XCTAssertEqual(Int(userLen), "testuser".utf16LE.count)
        XCTAssertEqual(Int(wsLen), "MACBOOK".utf16LE.count)
        XCTAssertEqual(sessionLen, 0)
        XCTAssertTrue(flags != 0, "Flags should be non-zero")
    }

    func testType3PayloadsStartAt64() throws {
        let type2 = buildMinimalType2Challenge()
        let msg = try decode(NTLMAuth.authenticateMessage(challengeBase64: type2, credentials: testCredentials()))
        let lmOffset = msg.uint32LE(at: 16)
        XCTAssertEqual(lmOffset, 64, "First payload (LM response) starts at byte 64")
    }

    func testType3EchoesServerFlags() throws {
        let serverFlags: UInt32 = 0xa2889205
        let type2 = buildMinimalType2Challenge(flags: serverFlags)
        let msg = try decode(NTLMAuth.authenticateMessage(challengeBase64: type2, credentials: testCredentials()))
        let flags = msg.uint32LE(at: 60)
        XCTAssertEqual(flags, serverFlags, "Type 3 should echo server's flags from Type 2")
    }

    // MARK: - Challenge Extraction

    func testExtractChallengeFromNTLMHeader() {
        let headers = ["NTLM TlRMTVNTUAAC"]
        XCTAssertEqual(NTLMAuth.extractChallenge(from: headers), "TlRMTVNTUAAC")
    }

    func testExtractChallengeCaseInsensitive() {
        let headers = ["ntlm TlRMTVNTUAAC"]
        XCTAssertEqual(NTLMAuth.extractChallenge(from: headers), "TlRMTVNTUAAC")
    }

    func testExtractChallengeIgnoresBareNTLM() {
        let headers = ["NTLM"]
        XCTAssertNil(NTLMAuth.extractChallenge(from: headers), "Bare 'NTLM' is an advertisement, not a challenge")
    }

    func testExtractChallengeIgnoresNegotiate() {
        let headers = ["Negotiate", "NTLM TlRMTVNTUAAC"]
        XCTAssertEqual(NTLMAuth.extractChallenge(from: headers), "TlRMTVNTUAAC")
    }

    func testExtractChallengeReturnsNilForNoNTLM() {
        let headers = ["Negotiate", "Basic realm=\"proxy\""]
        XCTAssertNil(NTLMAuth.extractChallenge(from: headers))
    }

    func testExtractChallengeTrimsOuterWhitespace() {
        let headers = ["  NTLM TlRMTVNTUAAC  "]
        let result = NTLMAuth.extractChallenge(from: headers)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("TlRMTVNTUAAC"))
    }

    // MARK: - Challenge Parsing

    func testParseChallengeExtractsServerChallenge() throws {
        let type2 = buildMinimalType2Challenge()
        let challenge = try NTLMAuth.parseChallenge(type2)
        XCTAssertEqual(challenge.serverChallenge, Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testParseChallengeExtractsFlags() throws {
        let type2 = buildMinimalType2Challenge(flags: 0xDEADBEEF)
        let challenge = try NTLMAuth.parseChallenge(type2)
        XCTAssertEqual(challenge.flags, 0xDEADBEEF)
    }

    func testParseChallengeRejectsShortData() {
        XCTAssertThrowsError(try NTLMAuth.parseChallenge("AAAA"))
    }

    func testParseChallengeRejectsWrongSignature() {
        var data = Data("XXXXXXXX".utf8)
        data.append(contentsOf: [UInt8](repeating: 0, count: 40))
        XCTAssertThrowsError(try NTLMAuth.parseChallenge(data.base64EncodedString()))
    }

    func testParseChallengeRejectsWrongType() {
        var data = Data("NTLMSSP\0".utf8)
        data.append(littleEndian: UInt32(1)) // Type 1 instead of Type 2
        data.append(contentsOf: [UInt8](repeating: 0, count: 36))
        XCTAssertThrowsError(try NTLMAuth.parseChallenge(data.base64EncodedString()))
    }

    func testParseChallengeHandlesMinimalType2() throws {
        var data = Data("NTLMSSP\0".utf8)
        data.append(littleEndian: UInt32(2))
        data.append(contentsOf: [UInt8](repeating: 0, count: 4)) // target name fields
        data.append(contentsOf: [UInt8](repeating: 0, count: 4)) // target name fields
        data.append(littleEndian: UInt32(0x00088205)) // flags
        data.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]) // challenge
        let challenge = try NTLMAuth.parseChallenge(data.base64EncodedString())
        XCTAssertEqual(challenge.serverChallenge, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]))
        XCTAssertEqual(challenge.targetInfo, Data())
    }

    // MARK: - Security Buffer Helper

    func testSecurityBufferLayout() {
        let buf = NTLMAuth.securityBuffer(length: 0x1234, offset: 0xDEADBEEF)
        XCTAssertEqual(buf.count, 8)
        XCTAssertEqual(buf.uint16LE(at: 0), 0x1234, "Length")
        XCTAssertEqual(buf.uint16LE(at: 2), 0x1234, "MaxLength == Length")
        XCTAssertEqual(buf.uint32LE(at: 4), 0xDEADBEEF, "Offset")
    }

    func testSecurityBufferDataReturnsEmptyForTruncatedHeader() {
        let truncated = Data([0x04, 0x00, 0x04, 0x00, 0x08, 0x00])
        XCTAssertEqual(truncated.securityBufferData(offsetFieldAt: 0), Data())
    }

    // MARK: - Helpers

    private func testCredentials() -> ProxyCredentials {
        ProxyCredentials(
            username: "testuser",
            domain: "EMEA",
            workstation: "MACBOOK",
            ntHash: SecretBytes.repeating(0x11, count: 16)
        )
    }

    private func decode(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw NTLMAuthError.invalidMessage
        }
        return data
    }

    private func buildMinimalType2Challenge(flags: UInt32 = 0xa2889205) -> String {
        var data = Data("NTLMSSP\0".utf8)                           // 0: Signature
        data.append(littleEndian: UInt32(2))                        // 8: Type
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))   // 12: TargetNameFields
        data.append(littleEndian: flags)                            // 20: Flags
        data.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])         // 24: ServerChallenge
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))   // 32: Reserved
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))   // 40: TargetInfoFields
        return data.base64EncodedString()
    }
}
