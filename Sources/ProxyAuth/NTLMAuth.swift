// SPDX-License-Identifier: Apache-2.0
import CommonCrypto
import Foundation
import ProxyKernel
import Security

package enum NTLMAuthError: Error, LocalizedError {
    case invalidChallenge
    case invalidMessage
    case cryptoFailure

    package var errorDescription: String? {
        switch self {
        case .invalidChallenge:
            return "The proxy challenge was missing or malformed."
        case .invalidMessage:
            return "The NTLM message could not be encoded."
        case .cryptoFailure:
            return "A required NTLM cryptographic operation failed."
        }
    }
}

package enum NTLMAuth {
    package static let signature = Data("NTLMSSP\0".utf8)

    // Match CNTLM's NTLMv2 flags exactly: 0xa208b205
    //   NEGOTIATE_56 | NEGOTIATE_128 | NEGOTIATE_VERSION |
    //   EXTENDED_SESSIONSECURITY | ALWAYS_SIGN |
    //   OEM_WORKSTATION_SUPPLIED | OEM_DOMAIN_SUPPLIED |
    //   NEGOTIATE_NTLM | REQUEST_TARGET | NEGOTIATE_UNICODE
    package static let negotiateFlags: UInt32 = 0xa208b205

    package static let ntlmsspVersion: [UInt8] = [
        10, 0,          // ProductMajorVersion=10, ProductMinorVersion=0
        0x41, 0x4A,     // ProductBuild=19009 (LE)
        0x00, 0x00, 0x00, // Reserved
        0x0F            // NTLMRevisionCurrent = NTLMSSP_REVISION_W2K3
    ]

    package struct Challenge {
        let flags: UInt32
        let serverChallenge: Data
        let targetInfo: Data
    }

    /// Returns `SecretBytes` so the NT hash is opaque
    /// from the moment it's computed. Previously returned raw `Data`;
    /// the raw-bytes form would travel briefly through AppState before
    /// being persisted, bypassing SecretBytes's print/Mirror/Codable
    /// defenses. The MD4 digest is computed into a local `Data` buffer
    /// (CommonCrypto needs a writable raw pointer) and immediately
    /// wrapped — the intermediate `Data` is released by ARC at the end
    /// of this function and is not accessible to callers.
    package static func ntHash(for password: String) throws -> SecretBytes {
        let unicode = Data(password.utf16LE)
        var digest = Data(count: Int(CC_MD4_DIGEST_LENGTH))
        let status = digest.withUnsafeMutableBytes { digestBytes in
            unicode.withUnsafeBytes { unicodeBytes in
                CC_MD4(unicodeBytes.baseAddress, CC_LONG(unicode.count), digestBytes.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard status != nil else {
            throw NTLMAuthError.cryptoFailure
        }
        return SecretBytes(digest)
    }

    /// Type 1 (Negotiate) message per MS-NLMP with CNTLM-compatible layout:
    ///   Signature(8) + Type(4) + Flags(4) + DomainBuffer(8) + WorkstationBuffer(8) + Version(8) + Payload
    package static func negotiateMessage(credentials: ProxyCredentials) throws -> String {
        let domainData = Data(credentials.domain.uppercased().utf8)
        let workstationData = Data(credentials.workstation.uppercased().utf8)
        let headerSize = 40 // 8+4+4+8+8+8

        var message = Data()
        message.append(signature)                                                                           // 0:  Signature
        message.append(littleEndian: UInt32(1))                                                             // 8:  MessageType
        message.append(littleEndian: negotiateFlags)                                                        // 12: NegotiateFlags
        message.append(securityBuffer(length: UInt16(domainData.count),                                     // 16: DomainNameFields
                                      offset: UInt32(headerSize + workstationData.count)))
        message.append(securityBuffer(length: UInt16(workstationData.count),                                // 24: WorkstationFields
                                      offset: UInt32(headerSize)))
        message.append(contentsOf: ntlmsspVersion)                                                          // 32: Version
        message.append(workstationData)                                                                     // 40: Payload
        message.append(domainData)

        return message.base64EncodedString()
    }

    /// Type 3 (Authenticate) message per MS-NLMP:
    ///   Signature(8) + Type(4) + LmBuffer(8) + NtBuffer(8) + DomainBuffer(8) +
    ///   UserBuffer(8) + WorkstationBuffer(8) + SessionKeyBuffer(8) + Flags(4) + Payload
    package static func authenticateMessage(challengeBase64: String, credentials: ProxyCredentials) throws -> String {
        let challenge = try parseChallenge(challengeBase64)

        let domainData = Data(credentials.domain.utf16LE)
        let userData = Data(credentials.username.utf16LE)
        let workstationData = Data(credentials.workstation.utf16LE)

        // `credentials.ntHash` is SecretBytes; bridge into hmacMD5 via
        // the withUnsafeBytes closure that keeps the key on the stack
        // for the duration of the CCHmac call (no Data materialisation,
        // no escape of the pointer beyond this scope).
        let ntlmV2Hash = try credentials.ntHash.withUnsafeBytes { keyBuf in
            try hmacMD5(
                keyBytes: keyBuf,
                message: Data((credentials.username.uppercased() + credentials.domain).utf16LE)
            )
        }

        let clientChallenge = randomBytes(count: 8)
        let timestamp = fileTimeTimestamp()
        var blob = Data()
        blob.append(contentsOf: [0x01, 0x01, 0x00, 0x00])
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        blob.append(timestamp)
        blob.append(clientChallenge)
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        blob.append(challenge.targetInfo)
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        let ntProof = try hmacMD5(key: ntlmV2Hash, message: challenge.serverChallenge + blob)
        let ntResponse = ntProof + blob
        let lmHash = try hmacMD5(key: ntlmV2Hash, message: challenge.serverChallenge + clientChallenge)
        let lmResponse = lmHash + clientChallenge

        let payloadOffset = 64
        let payloadSegments: [Data] = [lmResponse, ntResponse, domainData, userData, workstationData]
        let offsets = payloadOffsets(start: payloadOffset, payloads: payloadSegments)
        let responseFlags = challenge.flags == 0 ? negotiateFlags : challenge.flags

        var message = Data()
        message.append(signature)                                                                           // 0:  Signature
        message.append(littleEndian: UInt32(3))                                                             // 8:  MessageType
        message.append(securityBuffer(length: UInt16(lmResponse.count), offset: offsets[0]))                // 12: LmChallengeResponse
        message.append(securityBuffer(length: UInt16(ntResponse.count), offset: offsets[1]))                // 20: NtChallengeResponse
        message.append(securityBuffer(length: UInt16(domainData.count), offset: offsets[2]))                // 28: DomainName
        message.append(securityBuffer(length: UInt16(userData.count), offset: offsets[3]))                  // 36: UserName
        message.append(securityBuffer(length: UInt16(workstationData.count), offset: offsets[4]))           // 44: Workstation
        message.append(securityBuffer(length: 0, offset: UInt32(payloadOffset +                             // 52: EncryptedRandomSessionKey
            payloadSegments.reduce(0) { $0 + $1.count })))
        message.append(littleEndian: responseFlags)                                                         // 60: NegotiateFlags
        payloadSegments.forEach { message.append($0) }                                                     // 64: Payload

        return message.base64EncodedString()
    }

    package static func extractChallenge(from proxyAuthenticateHeaders: [String]) -> String? {
        for header in proxyAuthenticateHeaders {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("ntlm "), trimmed.count > 5 {
                return String(trimmed.dropFirst(5))
            }
        }
        return nil
    }

    package static func parseChallenge(_ base64: String) throws -> Challenge {
        guard let data = Data(base64Encoded: base64), data.count >= 32 else {
            throw NTLMAuthError.invalidChallenge
        }
        guard data.starts(with: signature), data.uint32LE(at: 8) == 2 else {
            throw NTLMAuthError.invalidChallenge
        }

        let flags = data.uint32LE(at: 20)
        let serverChallenge = data.subdata(in: 24 ..< 32)
        let targetInfo = data.count >= 48 ? data.securityBufferData(offsetFieldAt: 40) : Data()

        return Challenge(flags: flags, serverChallenge: serverChallenge, targetInfo: targetInfo)
    }

    package static func securityBuffer(length: UInt16, offset: UInt32) -> Data {
        var data = Data()
        data.append(littleEndian: length)
        data.append(littleEndian: length)
        data.append(littleEndian: offset)
        return data
    }

    private static func payloadOffsets(start: Int, payloads: [Data]) -> [UInt32] {
        var running = start
        return payloads.map { payload in
            defer { running += payload.count }
            return UInt32(running)
        }
    }

    private static func fileTimeTimestamp(date: Date = .now) -> Data {
        let windowsEpochOffset: TimeInterval = 11_644_473_600
        let value = UInt64((date.timeIntervalSince1970 + windowsEpochOffset) * 10_000_000)
        var data = Data()
        data.append(littleEndian: value)
        return data
    }

    /// Cryptographically-strong random bytes for the NTLMv2 client challenge.
    /// The client challenge is a security-relevant nonce, so it is sourced from
    /// the system CSPRNG (`SecRandomCopyBytes`) rather than the general-purpose
    /// `SystemRandomNumberGenerator`. Falls back to `arc4random_buf` (also a
    /// CSPRNG) on the practically-impossible `SecRandomCopyBytes` failure so a
    /// weak nonce is never emitted.
    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, count)
        }
        return Data(bytes)
    }

    /// HMAC-MD5 with a `Data`-typed key. Used for the NTLMv2 chain's
    /// intermediate HMAC rounds (lines 107 / 109 in `authenticateMessage`)
    /// where the key is itself the output of a prior HMAC and is a
    /// short-lived local.
    private static func hmacMD5(key: Data, message: Data) throws -> Data {
        try key.withUnsafeBytes { keyBytes in
            try hmacMD5(
                keyBytes: keyBytes.bindMemory(to: UInt8.self),
                message: message
            )
        }
    }

    /// HMAC-MD5 with the key supplied directly as an
    /// `UnsafeBufferPointer<UInt8>`. Used at the `SecretBytes` boundary
    /// so `credentials.ntHash.withUnsafeBytes { ... }` can feed the
    /// CCHmac call without materialising the hash as a `Data` along
    /// the way.
    private static func hmacMD5(
        keyBytes: UnsafeBufferPointer<UInt8>,
        message: Data
    ) throws -> Data {
        var output = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        output.withUnsafeMutableBytes { outputBytes in
            message.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgMD5),
                    keyBytes.baseAddress,
                    keyBytes.count,
                    messageBytes.baseAddress,
                    message.count,
                    outputBytes.baseAddress
                )
            }
        }
        return output
    }
}

// MARK: - ProxyAuthenticator conformance

package final class NTLMAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    package let scheme = "NTLM"

    private let credentials: ProxyCredentials

    package init(credentials: ProxyCredentials) {
        self.credentials = credentials
    }

    package func initialToken(for host: String) throws -> String {
        "NTLM " + (try NTLMAuth.negotiateMessage(credentials: credentials))
    }

    package func processChallenge(headerValues: [String], host: String) throws -> String? {
        guard let challengeBase64 = NTLMAuth.extractChallenge(from: headerValues),
              !challengeBase64.isEmpty else {
            return nil
        }
        return "NTLM " + (try NTLMAuth.authenticateMessage(challengeBase64: challengeBase64, credentials: credentials))
    }

    package func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("NTLM") == .orderedSame
    }

    package func reset() {}
}

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func uint16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func securityBufferData(offsetFieldAt offset: Int) -> Data {
        let headerSize = MemoryLayout<UInt16>.size + MemoryLayout<UInt16>.size + MemoryLayout<UInt32>.size
        let (headerEnd, headerOverflow) = offset.addingReportingOverflow(headerSize)
        guard offset >= 0, !headerOverflow, count >= headerEnd else {
            return Data()
        }
        let length = Int(uint16LE(at: offset))
        let dataOffset = Int(uint32LE(at: offset + 4))
        let (end, overflow) = dataOffset.addingReportingOverflow(length)
        guard !overflow, length > 0, count >= end else {
            return Data()
        }
        return subdata(in: dataOffset ..< end)
    }
}

extension String {
    var utf16LE: [UInt8] {
        utf16.flatMap { codeUnit in
            let little = codeUnit.littleEndian
            return [
                UInt8(truncatingIfNeeded: little & 0x00ff),
                UInt8(truncatingIfNeeded: little >> 8)
            ]
        }
    }
}
