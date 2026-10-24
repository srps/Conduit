// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyAuth
import ProxyKernel

/// NTLM identity field lengths, headless. The real `NTLMAuthenticator` builds
/// the Type 1 and Type 3 messages from synthetic credentials; no socket is
/// opened and nothing under the machine's configuration is read. A field that
/// fits its 16-bit length is accepted at the boundary. A field that does not,
/// including a Negotiate name that only overflows once uppercased, is refused
/// with `messageFieldTooLong`, and that refusal is not classified as a
/// credential-unavailable failure, so the kernel does not skip recovery for it.
enum AuthIdentityLengthScenario {
    private struct Failure: Error { let message: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let host = "proxy.example.test"
        let ntHash = SecretBytes(Data(repeating: 0x11, count: 16))
        func authenticator(username: String = "alice", domain: String = "CORP", workstation: String = "WS01") -> NTLMAuthenticator {
            NTLMAuthenticator(credentials: ProxyCredentials(
                username: username, domain: domain, workstation: workstation, ntHash: ntHash
            ))
        }
        let challenge = challengeHeader()

        // The largest 16-bit domain is accepted, and so is the largest UTF-16 username.
        let domainAtBoundary = refusal { _ = try authenticator(domain: String(repeating: "d", count: 65_535)).initialToken(for: host) }
        let usernameAtBoundary = refusal {
            let token = try authenticator(username: String(repeating: "u", count: 32_767)).processChallenge(headerValues: [challenge], host: host)
            guard token?.hasPrefix("NTLM ") == true else { throw Failure(message: "no Type 3 token") }
        }

        // "ŉ" is two UTF-8 bytes; uppercased it is "ʼN", three bytes. 25,000 of them fit as typed and overflow as sent.
        let expanding = String(repeating: "ŉ", count: 25_000)
        let expansionFitsAsTyped = Data(expanding.utf8).count <= 65_535
        let expansionRefusal = refusal { _ = try authenticator(workstation: expanding).initialToken(for: host) }

        // Type 3 fields past 65,535 bytes: a 65,536-byte UTF-16 username and a 66,000-byte UTF-16 workstation.
        let usernameRefusal = refusal {
            _ = try authenticator(username: String(repeating: "u", count: 32_768)).processChallenge(headerValues: [challenge], host: host)
        }
        let workstationRefusal = refusal {
            _ = try authenticator(workstation: String(repeating: "w", count: 33_000)).processChallenge(headerValues: [challenge], host: host)
        }

        let refusals = [expansionRefusal, usernameRefusal, workstationRefusal]
        let allMessageFieldTooLong = refusals.allSatisfy { error in
            (error as? NTLMAuthError) == .messageFieldTooLong
        }
        let noCredentialMisclassification = refusals.allSatisfy { error in
            error?.isCredentialUnavailable == false
        }
        let fixedDescription = refusals.allSatisfy { error in
            (error as? LocalizedError)?.errorDescription
                == "An NTLM message field is longer than the protocol allows."
        }

        let checks: [ScenarioAssertion] = [
            .init("a 65,535-byte domain at the boundary is accepted in the Type 1 message", domainAtBoundary == nil),
            .init("a 65,534-byte UTF-16 username at the boundary is accepted in the Type 3 message", usernameAtBoundary == nil),
            .init("an uppercase expansion that fits as typed but not as sent is refused", expansionFitsAsTyped && expansionRefusal != nil),
            .init("a Type 3 username past 65,535 UTF-16 bytes is refused before the response", usernameRefusal != nil),
            .init("a Type 3 workstation past 65,535 UTF-16 bytes is refused before the response", workstationRefusal != nil),
            .init("every refusal is messageFieldTooLong", allMessageFieldTooLong),
            .init("no refusal is classified as credential-unavailable", noCredentialMisclassification),
            .init("every refusal carries the fixed description, which names no identity", fixedDescription),
        ]
        let passed = checks.allSatisfy(\.passed)
        guard passed else {
            throw Failure(message: "auth identity length assertions failed: \(checks.filter { !$0.passed }.map(\.name))")
        }
        return ScenarioResult(
            name: "auth-identity-length", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: NTLM identity fields at the 16-bit boundary are accepted; uppercase expansion and oversized Type 3 fields are refused as messageFieldTooLong, never as credential-unavailable"]
        )
    }

    /// The error `body` throws, or nil when it succeeds.
    private static func refusal(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }

    /// A 48-byte Type 2 challenge with an empty target info. The server's
    /// target info is not what this scenario varies.
    private static func challengeHeader() -> String {
        var message = NTLMAuth.signature                                                        // 0:  Signature
        message.append(littleEndianBytes(UInt32(2)))                                            // 8:  MessageType
        message.append(NTLMAuth.securityBuffer(length: 0, offset: 48))                         // 12: TargetNameFields
        message.append(littleEndianBytes(UInt32(0xa208b205)))                                   // 20: NegotiateFlags
        message.append(Data(repeating: 0x22, count: 8))                                         // 24: ServerChallenge
        message.append(Data(repeating: 0, count: 8))                                            // 32: Reserved
        message.append(NTLMAuth.securityBuffer(length: 0, offset: 48))                         // 40: TargetInfoFields
        return "NTLM " + message.base64EncodedString()
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
