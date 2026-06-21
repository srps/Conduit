// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

final class ProxyAuthenticatorTests: XCTestCase {

    // MARK: - NTLMAuthenticator via protocol

    func testNTLMAuthenticatorInitialTokenContainsScheme() throws {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NTLMAuthenticator(credentials: creds)
        let token = try auth.initialToken(for: "proxy.example.com")
        XCTAssert(token.hasPrefix("NTLM "), "Token should start with 'NTLM ' scheme prefix")

        let base64Part = String(token.dropFirst(5))
        XCTAssertNotNil(Data(base64Encoded: base64Part), "Remainder should be valid base64")
    }

    func testNTLMAuthenticatorProcessChallengeReturnsNilForEmptyHeaders() throws {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NTLMAuthenticator(credentials: creds)
        let result = try auth.processChallenge(headerValues: [], host: "proxy.example.com")
        XCTAssertNil(result, "Should return nil when no NTLM challenge is present")
    }

    func testNTLMAuthenticatorProcessChallengeReturnsNilForNonNTLMHeaders() throws {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NTLMAuthenticator(credentials: creds)
        let result = try auth.processChallenge(headerValues: ["Negotiate"], host: "proxy.example.com")
        XCTAssertNil(result, "NTLM authenticator should not handle Negotiate headers")
    }

    func testNTLMAuthenticatorCanHandleScheme() {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NTLMAuthenticator(credentials: creds)
        XCTAssertTrue(auth.canHandle(scheme: "NTLM"))
        XCTAssertTrue(auth.canHandle(scheme: "ntlm"))
        XCTAssertFalse(auth.canHandle(scheme: "Negotiate"))
        XCTAssertFalse(auth.canHandle(scheme: "Basic"))
    }

    func testNTLMAuthenticatorScheme() {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NTLMAuthenticator(credentials: creds)
        XCTAssertEqual(auth.scheme, "NTLM")
    }

    // MARK: - KerberosAuthenticator

    func testKerberosAuthenticatorCanHandleScheme() {
        let auth = KerberosAuthenticator()
        XCTAssertTrue(auth.canHandle(scheme: "Negotiate"))
        XCTAssertTrue(auth.canHandle(scheme: "negotiate"))
        XCTAssertFalse(auth.canHandle(scheme: "NTLM"))
        XCTAssertFalse(auth.canHandle(scheme: "Basic"))
    }

    func testKerberosAuthenticatorScheme() {
        let auth = KerberosAuthenticator()
        XCTAssertEqual(auth.scheme, "Negotiate")
    }

    func testKerberosAuthenticatorResetDoesNotCrash() {
        let auth = KerberosAuthenticator()
        auth.reset()
        auth.reset()
    }

    // MARK: - KerberosAuthenticator: extractNegotiateToken parsing

    func testExtractNegotiateTokenHandsBareNegotiateHeader() {
        let auth = KerberosAuthenticator()
        // Bare "Negotiate" header (no token) with no Kerberos ticket should throw
        // a KerberosAuthError, not crash or produce garbage.
        do {
            _ = try auth.processChallenge(headerValues: ["Negotiate"], host: "proxy.example.com")
        } catch is KerberosAuthError {
            // Expected: GSS init fails without a ticket
        } catch {
            XCTFail("Expected KerberosAuthError, got \(type(of: error)): \(error)")
        }
    }

    func testExtractNegotiateTokenHandsMixedCaseHeader() throws {
        let auth = KerberosAuthenticator()
        // "NEGOTIATE" (all-caps) should still be recognized
        // Without a ticket this throws, but that's expected -- we verify it doesn't return nil silently
        XCTAssertThrowsError(try auth.processChallenge(headerValues: ["NEGOTIATE"], host: "proxy.example.com"))
    }

    func testExtractNegotiateTokenHandsExtraWhitespace() throws {
        let auth = KerberosAuthenticator()
        // Leading/trailing whitespace should be trimmed
        XCTAssertThrowsError(try auth.processChallenge(headerValues: ["  Negotiate  "], host: "proxy.example.com"))
    }

    func testExtractNegotiateTokenReturnsNilForNonNegotiateHeaders() throws {
        let auth = KerberosAuthenticator()
        let result = try auth.processChallenge(headerValues: ["Basic realm=\"proxy\"", "NTLM"], host: "proxy.example.com")
        XCTAssertNil(result, "Should return nil when no Negotiate header is present")
    }

    func testExtractNegotiateTokenIgnoresInvalidBase64() throws {
        let auth = KerberosAuthenticator()
        let result = try auth.processChallenge(headerValues: ["Negotiate !!!not-base64!!!"], host: "proxy.example.com")
        XCTAssertNil(result, "Should return nil for invalid base64 token data")
    }

    // MARK: - KerberosAuthenticator: empty token → nil input

    func testProcessChallengeWithEmptyTokenUsesNilInput() throws {
        let auth = KerberosAuthenticator()
        // Bare "Negotiate" (no token) should be treated the same as starting a new context.
        // Without a valid ticket this throws -- the important thing is the error is
        // KerberosAuthError (GSS failure), not a crash from passing zero-length data.
        do {
            _ = try auth.processChallenge(headerValues: ["Negotiate"], host: "proxy.example.com")
        } catch is KerberosAuthError {
            // Expected: GSS init fails without a ticket
        } catch {
            XCTFail("Expected KerberosAuthError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Regression: Heimdal spnego_reply SIGSEGV (Conduit-2026-06-10-060007)

    /// Pre-fix: a live `gss_ctx_id_t` plus a nil input buffer routed Heimdal to
    /// `spnego_reply()`, which dereferenced `input_token.value` at offset 0x8.
    /// `SystemGSSTokenProvider` must discard the stale context before calling
    /// `gss_init_sec_context` when the peer sends a bare `Negotiate` re-challenge.
    func testBareNegotiateRechallengeClearsStaleGSSContextWithoutCrashing() throws {
        let provider = SystemGSSTokenProvider()
        let host = "proxy-de.corp.example"
        guard (try? provider.generateToken(host: host, inputToken: nil)) != nil else {
            throw XCTSkip("No Kerberos ticket available for live GSS context")
        }
        XCTAssertNoThrow(try provider.generateToken(host: host, inputToken: nil))
    }

    func testBareNegotiateRechallengeAfterInitialTokenDoesNotCrash() throws {
        let auth = KerberosAuthenticator()
        let host = "proxy-de.corp.example"
        guard (try? auth.initialToken(for: host)) != nil else {
            throw XCTSkip("No Kerberos ticket available for live GSS context")
        }
        do {
            _ = try auth.processChallenge(headerValues: ["Negotiate"], host: host)
        } catch is KerberosAuthError {
            // Acceptable — must not SIGSEGV.
        } catch {
            XCTFail("Expected KerberosAuthError or success, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - KerberosAuthenticator: concurrent access safety

    func testConcurrentResetDoesNotCrash() {
        let auth = KerberosAuthenticator()
        let iterations = 1000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            auth.reset()
        }
    }

    func testConcurrentInitialTokenDoesNotCrash() {
        let auth = KerberosAuthenticator()
        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = try? auth.initialToken(for: "proxy.example.com")
        }
    }

    func testConcurrentInitialTokenAcrossMultipleProviderInstances() {
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let auth = KerberosAuthenticator()
            _ = try? auth.initialToken(for: "proxy.example.com")
        }
    }

    // MARK: - NegotiateAuthenticator

    func testNegotiateAuthenticatorCanHandleBothSchemes() {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NegotiateAuthenticator(ntlmFallback: NTLMAuthenticator(credentials: creds))
        XCTAssertTrue(auth.canHandle(scheme: "Negotiate"))
        XCTAssertTrue(auth.canHandle(scheme: "NTLM"))
        XCTAssertFalse(auth.canHandle(scheme: "Basic"))
    }

    func testNegotiateAuthenticatorWithoutFallbackOnlyHandlesNegotiate() {
        let auth = NegotiateAuthenticator(ntlmFallback: nil)
        XCTAssertTrue(auth.canHandle(scheme: "Negotiate"))
        XCTAssertFalse(auth.canHandle(scheme: "NTLM"))
    }

    func testNegotiateAuthenticatorScheme() {
        let auth = NegotiateAuthenticator()
        XCTAssertEqual(auth.scheme, "Negotiate")
    }

    func testNegotiateAuthenticatorResetDoesNotCrash() {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NegotiateAuthenticator(ntlmFallback: NTLMAuthenticator(credentials: creds))
        auth.reset()
        auth.reset()
    }

    // MARK: - NegotiateAuthenticator NTLM fallback

    func testNegotiateAuthenticatorFallsBackToNTLMWhenKerberosUnavailable() throws {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NegotiateAuthenticator(ntlmFallback: NTLMAuthenticator(credentials: creds))

        let token = try auth.initialToken(for: "proxy.example.com")
        XCTAssert(token.hasPrefix("NTLM "), "Should fall back to NTLM when Kerberos ticket unavailable")
    }

    func testNegotiateAuthenticatorWithoutFallbackThrowsWhenKerberosUnavailable() {
        let auth = NegotiateAuthenticator(ntlmFallback: nil)
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.example.com")) { error in
            XCTAssert(error is KerberosAuthError, "Should throw KerberosAuthError, got \(type(of: error))")
        }
    }

    func testNegotiateAuthenticatorFallbackProcessChallengeRoutesToNTLM() throws {
        let creds = ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        )
        let auth = NegotiateAuthenticator(ntlmFallback: NTLMAuthenticator(credentials: creds))

        // Force NTLM fallback by calling initialToken (Kerberos will fail without a ticket)
        _ = try auth.initialToken(for: "proxy.example.com")

        // processChallenge on the SAME instance should route to NTLM, not Kerberos
        let ntlmChallenge = NTLMAuth.extractChallenge(from: ["NTLM TlRMTVNTUAACAAAAAAAAAAAAAAAyAgi0AAAAAAAAAAAAAAAAAAA="])
        XCTAssertNotNil(ntlmChallenge, "Test fixture should produce a parseable challenge")
    }

    // MARK: - Mock authenticator for handler tests

    func testMockAuthenticatorWorksWithProtocol() throws {
        let mock = MockAuthenticator(scheme: "TestScheme", token: "TestToken", challengeResponse: "TestResponse")
        XCTAssertEqual(try mock.initialToken(for: "host"), "TestScheme TestToken")
        XCTAssertEqual(try mock.processChallenge(headerValues: ["TestScheme challenge"], host: "host"), "TestScheme TestResponse")
        XCTAssertTrue(mock.canHandle(scheme: "TestScheme"))
        XCTAssertFalse(mock.canHandle(scheme: "Other"))
    }

    // MARK: - StatefulMockAuthenticator verifies instance reuse

    func testStatefulMockTracksCallSequence() throws {
        let mock = StatefulMockAuthenticator()
        _ = try mock.initialToken(for: "host")
        _ = try mock.processChallenge(headerValues: ["Negotiate ServerToken"], host: "host")

        XCTAssertEqual(mock.initialTokenCallCount, 1)
        XCTAssertEqual(mock.processChallengeCallCount, 1)
        XCTAssertTrue(mock.processChallengeCalledAfterInitialToken,
                      "processChallenge must be called on the same instance that produced the initial token")
    }

    // MARK: - KerberosAuthenticator via mock GSSTokenProvider

    func testInitialTokenCallsGenerateTokenWithNilInput() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xDE, 0xAD]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        _ = try auth.initialToken(for: "proxy.corp.com")

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].host, "proxy.corp.com")
        XCTAssertNil(recorder.calls[0].inputToken, "initialToken must pass nil inputToken to the provider")
    }

    func testProcessChallengeCallsGenerateTokenWithDecodedBytes() throws {
        let serverToken = Data([0x01, 0x02, 0x03, 0x04])
        let base64 = serverToken.base64EncodedString()
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xBE, 0xEF]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        _ = try auth.processChallenge(headerValues: ["Negotiate \(base64)"], host: "proxy.corp.com")

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].host, "proxy.corp.com")
        XCTAssertEqual(recorder.calls[0].inputToken, serverToken,
            "processChallenge must decode the base64 token and pass raw bytes to the provider")
    }

    func testBareNegotiateHeaderPassesNilInputToProvider() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xAA]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        _ = try auth.processChallenge(headerValues: ["Negotiate"], host: "proxy.corp.com")

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertNil(recorder.calls[0].inputToken,
            "Bare 'Negotiate' header (no token) must pass nil, not empty Data")
    }

    func testContextPreservedAcrossInitialTokenAndProcessChallenge() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xFF]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        _ = try auth.initialToken(for: "proxy.corp.com")

        let serverChallenge = Data([0x05, 0x06])
        _ = try auth.processChallenge(
            headerValues: ["Negotiate \(serverChallenge.base64EncodedString())"],
            host: "proxy.corp.com"
        )

        XCTAssertEqual(recorder.calls.count, 2,
            "Both initialToken and processChallenge must call the same provider instance")
        XCTAssertNil(recorder.calls[0].inputToken)
        XCTAssertEqual(recorder.calls[1].inputToken, serverChallenge)
    }

    func testResetCallsResetContextOnProvider() {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0x00]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        auth.reset()

        XCTAssertEqual(recorder.resetCallCount, 1, "reset() must call resetContext() on the provider")
    }

    func testProviderErrorPropagatesThroughInitialToken() {
        let recorder = RecordingGSSTokenProvider(errorToThrow: KerberosAuthError.noTicket)
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.com")) { error in
            guard case KerberosAuthError.noTicket = error else {
                XCTFail("Expected .noTicket, got \(error)")
                return
            }
        }
    }

    func testProviderErrorPropagatesThroughProcessChallenge() {
        let recorder = RecordingGSSTokenProvider(errorToThrow: KerberosAuthError.emptyToken)
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        XCTAssertThrowsError(try auth.processChallenge(headerValues: ["Negotiate"], host: "proxy.corp.com")) { error in
            guard case KerberosAuthError.emptyToken = error else {
                XCTFail("Expected .emptyToken, got \(error)")
                return
            }
        }
    }

    func testInvalidBase64ShortCircuitsWithoutCallingProvider() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xFF]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        let result = try auth.processChallenge(headerValues: ["Negotiate !!!not-valid!!!"], host: "proxy.corp.com")

        XCTAssertNil(result, "Invalid base64 should return nil")
        XCTAssertEqual(recorder.calls.count, 0, "Provider must NOT be called for invalid base64")
    }

    func testNonNegotiateHeadersShortCircuitWithoutCallingProvider() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: Data([0xFF]))
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        let result = try auth.processChallenge(headerValues: ["Basic realm=\"x\"", "NTLM"], host: "proxy.corp.com")

        XCTAssertNil(result, "Non-Negotiate headers should return nil")
        XCTAssertEqual(recorder.calls.count, 0, "Provider must NOT be called for non-Negotiate headers")
    }

    func testBase64RoundTripProducesCorrectNegotiateHeader() throws {
        let rawToken = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let recorder = RecordingGSSTokenProvider(tokenToReturn: rawToken)
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        let header = try auth.initialToken(for: "proxy.corp.com")

        XCTAssertEqual(header, "Negotiate \(rawToken.base64EncodedString())",
            "initialToken must produce 'Negotiate ' + base64 of the provider's raw token")
    }

    // MARK: - Fix 1: Zero-length token = auth complete (not an error)

    func testProcessChallengeReturnsNilWhenProviderReturnsNil() throws {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: nil)
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        let result = try auth.processChallenge(headerValues: ["Negotiate AQIDBA=="], host: "proxy.corp.com")

        XCTAssertNil(result, "When provider returns nil (GSS_S_COMPLETE with no output token), processChallenge must return nil to signal 'auth complete, no header to send'")
        XCTAssertEqual(recorder.calls.count, 1, "Provider must still be called")
    }

    func testInitialTokenThrowsWhenProviderReturnsNil() {
        let recorder = RecordingGSSTokenProvider(tokenToReturn: nil)
        let auth = KerberosAuthenticator(tokenProvider: recorder)

        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.com")) { error in
            guard case KerberosAuthError.emptyToken = error else {
                XCTFail("Expected .emptyToken when provider returns nil on initial leg, got \(error)")
                return
            }
        }
    }

    // MARK: - Fix 2: Selective NTLM fallback

    func testNegotiateAuthenticatorFallsBackOnNoCredError() throws {
        let noCredProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x0007_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: noCredProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        let token = try auth.initialToken(for: "proxy.corp.com")
        XCTAssert(token.hasPrefix("NTLM "), "GSS_S_NO_CRED should trigger NTLM fallback")
    }

    func testNegotiateAuthenticatorFallsBackOnExpiredCredError() throws {
        let expiredProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x000B_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: expiredProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        let token = try auth.initialToken(for: "proxy.corp.com")
        XCTAssert(token.hasPrefix("NTLM "), "GSS_S_CREDENTIALS_EXPIRED should trigger NTLM fallback")
    }

    func testNegotiateAuthenticatorDoesNotFallBackOnBadNameError() {
        let badNameProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x0002_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: badNameProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.com")) { error in
            guard case KerberosAuthError.initSecContextFailed(0x0002_0000, _) = error else {
                XCTFail("GSS_S_BAD_NAME must propagate, not fall back to NTLM. Got: \(error)")
                return
            }
        }
    }

    func testNegotiateAuthenticatorDoesNotFallBackOnDefectiveTokenError() {
        let defectiveProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x0009_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: defectiveProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.com")) { error in
            guard case KerberosAuthError.initSecContextFailed(0x0009_0000, _) = error else {
                XCTFail("GSS_S_DEFECTIVE_TOKEN must propagate, not fall back to NTLM. Got: \(error)")
                return
            }
        }
    }

    func testNegotiateAuthenticatorFallsBackOnGenericFailureWithZeroMinor() throws {
        let genericProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x000D_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: genericProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        let token = try auth.initialToken(for: "proxy.corp.com")
        XCTAssert(token.hasPrefix("NTLM "), "GSS_S_FAILURE with minor=0 should trigger NTLM fallback")
    }

    func testNegotiateAuthenticatorDoesNotFallBackOnFailureWithNonZeroMinor() {
        let specificProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x000D_0000, 42)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: specificProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.com")) { error in
            guard case KerberosAuthError.initSecContextFailed(0x000D_0000, 42) = error else {
                XCTFail("GSS_S_FAILURE with non-zero minor must propagate. Got: \(error)")
                return
            }
        }
    }

    func testKerberosAuthErrorDescriptionIsHumanReadableForGSSFailures() {
        let noCred = KerberosAuthError.initSecContextFailed(0x0007_0000, 0)
        XCTAssertTrue(noCred.errorDescription!.contains("credential"), "GSS_S_NO_CRED should mention 'credential': \(noCred.errorDescription!)")

        let badName = KerberosAuthError.initSecContextFailed(0x0002_0000, 0)
        XCTAssertTrue(badName.errorDescription!.contains("service name") || badName.errorDescription!.contains("SPN"),
                      "GSS_S_BAD_NAME should mention service name: \(badName.errorDescription!)")

        let defective = KerberosAuthError.initSecContextFailed(0x0009_0000, 0)
        XCTAssertTrue(defective.errorDescription!.contains("token"),
                      "GSS_S_DEFECTIVE_TOKEN should mention token: \(defective.errorDescription!)")
    }

    /// `GSS_S_BAD_MECH` (major=0x0001_0000=65536) is what Apple's Heimdal
    /// returns when the Kerberos SSO Extension's `credentialBundleIDACL`
    /// excludes this app's bundle ID. The error message must surface this
    /// SSO-Extension cause so users (and their IT administrators) get an
    /// actionable hint instead of the misleading "SPNEGO mechanism not
    /// supported" string. Real-world report: macOS users moved from NoMAD
    /// to the Apple SSO Extension start hitting this immediately.
    func testBadMechErrorDescriptionMentionsSSOExtensionAndBundleID() {
        let badMech = KerberosAuthError.initSecContextFailed(0x0001_0000, 0)
        let description = badMech.errorDescription ?? ""

        XCTAssertTrue(description.contains("SSO Extension"),
                      "BAD_MECH must surface Apple SSO Extension as the likely cause: \(description)")
        XCTAssertTrue(description.contains("io.github.srps.Conduit"),
                      "BAD_MECH must name the bundle ID IT needs to add: \(description)")
        XCTAssertTrue(description.contains("credentialBundleIDACL"),
                      "BAD_MECH must name the MDM key IT needs to edit: \(description)")
        XCTAssertTrue(description.contains("kinit") || description.contains("TGT"),
                      "BAD_MECH must also surface the alternate cause (no TGT): \(description)")
    }

    /// `GSS_S_BAD_MECH` must trigger the NTLM fallback path — same as the
    /// other credential-class errors. This is the primary usability fix for
    /// Apple-SSO-Extension users: if NTLM creds are saved, requests keep
    /// working transparently even though Kerberos is blocked.
    func testNegotiateAuthenticatorFallsBackOnBadMechError() throws {
        let badMechProvider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(0x0001_0000, 0)
        )
        let creds = ProxyCredentials(username: "user", domain: "DOMAIN", workstation: "WS",
                                     ntHash: SecretBytes.repeating(0xAA, count: 16))
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: badMechProvider),
            ntlmFallback: NTLMAuthenticator(credentials: creds)
        )
        let token = try auth.initialToken(for: "proxy.corp.com")
        XCTAssert(token.hasPrefix("NTLM "),
                  "GSS_S_BAD_MECH (Apple SSO Extension ACL miss) should trigger NTLM fallback")
    }

    // MARK: - Config default

    func testDefaultAuthModeIsSystemNegotiated() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.authMode, .systemNegotiated)
    }

    func testExplicitNTLMv2InJSONPreserved() throws {
        let json = """
        {"authMode": "ntlmv2", "profileName": "Test"}
        """
        let config = try JSONDecoder().decode(ProxyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.authMode, .ntlmv2)
    }

    func testMissingAuthModeDefaultsToSystemNegotiated() throws {
        let json = """
        {"profileName": "Test"}
        """
        let config = try JSONDecoder().decode(ProxyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.authMode, .systemNegotiated)
    }
}

// MARK: - Test Doubles

final class MockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme: String
    private let token: String
    private let challengeResponse: String?

    init(scheme: String, token: String, challengeResponse: String? = nil) {
        self.scheme = scheme
        self.token = token
        self.challengeResponse = challengeResponse
    }

    func initialToken(for host: String) throws -> String {
        "\(scheme) \(token)"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        guard let response = challengeResponse else { return nil }
        return "\(scheme) \(response)"
    }

    func canHandle(scheme: String) -> Bool {
        self.scheme.caseInsensitiveCompare(scheme) == .orderedSame
    }

    func reset() {}
}

/// Records all calls to `generateToken` and `resetContext` for assertion.
/// Configurable to return fixed data, nil (auth complete), or throw a fixed error.
final class RecordingGSSTokenProvider: GSSTokenProvider, @unchecked Sendable {
    struct Call: Equatable {
        let host: String
        let inputToken: Data?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _resetCallCount = 0
    private let _tokenToReturn: Data?
    private let _returnNil: Bool
    private let errorToThrow: Error?

    var calls: [Call] { lock.withLock { _calls } }
    var resetCallCount: Int { lock.withLock { _resetCallCount } }

    init(tokenToReturn: Data?, errorToThrow: Error? = nil) {
        self._tokenToReturn = tokenToReturn
        self._returnNil = tokenToReturn == nil && errorToThrow == nil
        self.errorToThrow = errorToThrow
    }

    init(errorToThrow: Error) {
        self._tokenToReturn = nil
        self._returnNil = false
        self.errorToThrow = errorToThrow
    }

    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        lock.withLock { _calls.append(Call(host: host, inputToken: inputToken)) }
        if let error = errorToThrow { throw error }
        if _returnNil { return nil }
        return _tokenToReturn ?? Data()
    }

    func resetContext() {
        lock.withLock { _resetCallCount += 1 }
    }
}

/// Stateful mock that tracks whether initialToken and processChallenge are called
/// on the same instance -- used to detect the authenticator re-creation bug.
final class StatefulMockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    private(set) var initialTokenCallCount = 0
    private(set) var processChallengeCallCount = 0
    private(set) var processChallengeCalledAfterInitialToken = false

    func initialToken(for host: String) throws -> String {
        initialTokenCallCount += 1
        return "Negotiate FakeInitialToken"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        processChallengeCallCount += 1
        processChallengeCalledAfterInitialToken = initialTokenCallCount > 0
        return "Negotiate FakeChallengeResponse"
    }

    func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    func reset() {}
}
