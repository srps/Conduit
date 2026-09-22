// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import ProxyKernel

// MARK: - GSSTokenProvider protocol

/// Abstraction over the stateful GSS-API operations (context init, continuation,
/// cleanup). Production code uses `SystemGSSTokenProvider`; tests can inject a mock.
package protocol GSSTokenProvider: AnyObject, Sendable {
    /// Generate a SPNEGO token for `host`. Pass `nil` for the initial leg;
    /// pass the server's challenge bytes for continuation legs.
    /// Returns `nil` when GSS_S_COMPLETE is reached with no output token
    /// (mutual-auth final leg -- RFC 2744: "no token need be sent").
    func generateToken(host: String, inputToken: Data?) throws -> Data?

    /// Discard any in-flight GSS context (called on pool eviction or reconnect).
    func resetContext()
}

// MARK: - SystemGSSTokenProvider (real GSS.framework)

private let kGSSErrorMask: OM_uint32 = 0xFFFF_0000
private let kGSSRoutineErrorMask: OM_uint32 = 0x00FF_0000
private let kGSSContextFlags: OM_uint32 = OM_uint32(GSS_C_MUTUAL_FLAG | GSS_C_REPLAY_FLAG | GSS_C_SEQUENCE_FLAG)

/// SPNEGO: 1.3.6.1.5.5.2
private let spnegoOIDBytes: [UInt8] = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
/// GSS_C_NT_HOSTBASED_SERVICE: 1.2.840.113554.1.2.1.4
private let hostbasedServiceOIDBytes: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04]
/// Kerberos 5 mechanism: 1.2.840.113554.1.2.2
private let krb5OIDBytes: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x02]

package final class SystemGSSTokenProvider: GSSTokenProvider, @unchecked Sendable {
    private var gssContext: gss_ctx_id_t?
    private let lock = NSLock()
    private let gate: GSSInitiatorGate
    private let hasInitiatorCredential: @Sendable () -> Bool

    /// `hasInitiatorCredential` is asked only after an ambiguous failure; see
    /// `KerberosAuthError.initiatorFailure`. Tests inject it.
    package init(
        gate: GSSInitiatorGate = .shared,
        hasInitiatorCredential: @escaping @Sendable () -> Bool = SystemGSSTokenProvider.hasDefaultInitiatorCredential
    ) {
        self.gate = gate
        self.hasInitiatorCredential = hasInitiatorCredential
    }

    /// Whether the default credential cache holds an unexpired Kerberos
    /// initiator credential (a TGT). Reads the cache only; it never asks the
    /// KDC. A failure to acquire answers `false`, which keeps the caller's
    /// original "credential unavailable" classification and its message.
    package static func hasDefaultInitiatorCredential() -> Bool {
        var minor: OM_uint32 = 0
        var credential: gss_cred_id_t?
        var lifetime: OM_uint32 = 0
        var mechOIDBytes = krb5OIDBytes
        let major: OM_uint32 = mechOIDBytes.withUnsafeMutableBufferPointer { oidPtr in
            var mechOID = gss_OID_desc(length: OM_uint32(oidPtr.count), elements: oidPtr.baseAddress)
            return withUnsafeMutablePointer(to: &mechOID) { mechPtr in
                var mechs = gss_OID_set_desc(count: 1, elements: mechPtr)
                return gss_acquire_cred(
                    &minor,
                    nil,
                    OM_uint32.max,  // GSS_C_INDEFINITE
                    &mechs,
                    gss_cred_usage_t(GSS_C_INITIATE),
                    &credential,
                    nil,
                    &lifetime
                )
            }
        }
        if credential != nil {
            var releaseMinor: OM_uint32 = 0
            gss_release_cred(&releaseMinor, &credential)
        }
        return major & kGSSErrorMask == 0 && lifetime > 0
    }

    package func generateToken(host: String, inputToken: Data?) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }

        // Serialised process-wide: see `GSSInitiatorGate`. A credential-
        // absence error is cheap to repeat and must stay visible to
        // `NegotiateAuthenticator`'s NTLM fallback on every call; anything
        // else (KDC unreachable, clock skew, ...) is a network-class failure
        // that every queued handshake would otherwise re-run.
        return try gate.run(target: host, shouldCoolDown: { error in
            guard let kerberosError = error as? KerberosAuthError else { return true }
            return !kerberosError.isCredentialUnavailable
        }) {
            try initiateLocked(host: host, inputToken: inputToken)
        }
    }

    /// Caller holds `lock` and the gate.
    private func initiateLocked(host: String, inputToken: Data?) throws -> Data? {
        // A nil/empty input token means the peer started a fresh handshake
        // (initial leg, or a bare `Negotiate` re-challenge after rejecting a
        // token on a kept-alive connection). Heimdal routes a live context to
        // spnego_reply(), which dereferences the NULL input buffer and
        // crashes (EXC_BAD_ACCESS at 0x8) — discard the stale context so the
        // call takes the spnego_initial() path instead.
        if inputToken?.isEmpty ?? true {
            deleteContext()
        }

        let targetNameNonOpt = try importServiceName(host: host)
        var targetName: gss_name_t? = targetNameNonOpt
        defer {
            var minor: OM_uint32 = 0
            gss_release_name(&minor, &targetName)
        }

        var minor: OM_uint32 = 0
        var outputToken = gss_buffer_desc(length: 0, value: nil)
        var retFlags: OM_uint32 = 0

        var spnegoOID = spnegoOIDBytes
        let major: OM_uint32 = spnegoOID.withUnsafeMutableBufferPointer { spnegoPtr in
            var mechOID = gss_OID_desc(length: OM_uint32(spnegoPtr.count), elements: spnegoPtr.baseAddress)
            if let inputToken, !inputToken.isEmpty {
                return inputToken.withUnsafeBytes { inputBytes in
                    var inputBuffer = gss_buffer_desc(
                        length: inputToken.count,
                        value: UnsafeMutableRawPointer(mutating: inputBytes.baseAddress)
                    )
                    return gss_init_sec_context(
                        &minor,
                        nil,
                        &gssContext,
                        targetNameNonOpt,
                        &mechOID,
                        kGSSContextFlags,
                        0,
                        nil,
                        &inputBuffer,
                        nil,
                        &outputToken,
                        &retFlags,
                        nil
                    )
                }
            } else {
                return gss_init_sec_context(
                    &minor,
                    nil,
                    &gssContext,
                    targetNameNonOpt,
                    &mechOID,
                    kGSSContextFlags,
                    0,
                    nil,
                    nil,
                    nil,
                    &outputToken,
                    &retFlags,
                    nil
                )
            }
        }

        defer {
            var relMinor: OM_uint32 = 0
            gss_release_buffer(&relMinor, &outputToken)
        }

        guard major & kGSSErrorMask == 0 else {
            deleteContext()
            throw KerberosAuthError.initiatorFailure(
                major: major, minor: minor, host: host,
                hasInitiatorCredential: hasInitiatorCredential
            )
        }

        guard outputToken.length > 0, let value = outputToken.value else {
            return nil
        }

        return Data(bytes: value, count: outputToken.length)
    }

    package func resetContext() {
        lock.lock()
        defer { lock.unlock() }
        deleteContext()
    }

    deinit {
        deleteContext()
    }

    private func importServiceName(host: String) throws -> gss_name_t {
        let spn = "HTTP@\(host)"
        var minor: OM_uint32 = 0
        var targetName: gss_name_t?

        var serviceOID = hostbasedServiceOIDBytes
        let major = serviceOID.withUnsafeMutableBufferPointer { oidPtr in
            var nameType = gss_OID_desc(length: OM_uint32(oidPtr.count), elements: oidPtr.baseAddress)
            return spn.withCString { cstr in
                var nameBuffer = gss_buffer_desc(
                    length: strlen(cstr),
                    value: UnsafeMutableRawPointer(mutating: cstr)
                )
                return gss_import_name(
                    &minor,
                    &nameBuffer,
                    &nameType,
                    &targetName
                )
            }
        }

        guard major == 0, let name = targetName else {
            throw KerberosAuthError.importNameFailed(major, minor)
        }
        return name
    }

    private func deleteContext() {
        guard gssContext != nil else { return }
        var minor: OM_uint32 = 0
        gss_delete_sec_context(&minor, &gssContext, nil)
        gssContext = nil
    }
}

// MARK: - KerberosAuthError

/// `CredentialFailureClassifying` lets the kernel tell a missing ticket from a broken exchange.
package enum KerberosAuthError: Error, LocalizedError, CredentialFailureClassifying {
    case importNameFailed(OM_uint32, OM_uint32)
    case initSecContextFailed(OM_uint32, OM_uint32)
    /// A ticket-granting ticket is present, but no service ticket for `host`
    /// could be obtained: the KDC is unreachable, or the SPN is not registered.
    /// See `initiatorFailure(major:minor:host:hasInitiatorCredential:)`.
    case serviceTicketUnavailable(host: String, major: OM_uint32, minor: OM_uint32)
    case emptyToken
    case noTicket

    /// Classify a failed `gss_init_sec_context`.
    ///
    /// SPNEGO answers `GSS_S_BAD_MECH` (or `GSS_S_FAILURE` with minor 0) for
    /// any failure of the Kerberos mech to produce a token, so the code alone
    /// cannot tell "no TGT" from "a TGT, but the TGS request failed". Only
    /// for those ambiguous codes, `hasInitiatorCredential` asks whether a
    /// default Kerberos credential exists; if it does, the failure is the
    /// service ticket's, which is a network-class failure and not a missing
    /// credential. Issue #73.
    package static func initiatorFailure(
        major: OM_uint32,
        minor: OM_uint32,
        host: String,
        hasInitiatorCredential: () -> Bool
    ) -> KerberosAuthError {
        let routine = major & kGSSRoutineErrorMask
        let ambiguous = routine == UInt32(GSS_S_BAD_MECH)
            || (routine == UInt32(GSS_S_FAILURE) && minor == 0)
        if ambiguous, hasInitiatorCredential() {
            return .serviceTicketUnavailable(host: host, major: major, minor: minor)
        }
        return .initSecContextFailed(major, minor)
    }

    package var errorDescription: String? {
        switch self {
        case .importNameFailed(let major, let minor):
            return "Kerberos: service name import failed — check the proxy hostname (GSS major=\(major), minor=\(minor))."
        case .initSecContextFailed(let major, let minor):
            return "Kerberos: \(Self.gssRoutineDescription(major)) (GSS major=\(major), minor=\(minor))."
        case .serviceTicketUnavailable(let host, let major, let minor):
            return "Kerberos: a Kerberos ticket is present, but no service ticket for HTTP/\(host) could be obtained — the KDC may be unreachable (check the VPN and DNS), or the proxy has no registered service principal (GSS major=\(major), minor=\(minor))."
        case .emptyToken:
            return "Kerberos: the initial authentication step produced no token."
        case .noTicket:
            return "No Kerberos ticket available for the target service."
        }
    }

    /// Whether this error represents a missing or expired credential,
    /// as opposed to a configuration, integrity, or protocol error.
    package var isCredentialUnavailable: Bool {
        switch self {
        case .initSecContextFailed(let major, let minor):
            let routine = major & kGSSRoutineErrorMask
            // GSS_S_NO_CRED / GSS_S_CREDENTIALS_EXPIRED: explicit credential absence.
            // GSS_S_BAD_MECH / GSS_S_FAILURE with minor==0: SPNEGO's answer to any
            //   Kerberos-mech failure. `initiatorFailure` has already turned the
            //   ones with a TGT present into `.serviceTicketUnavailable`, so what
            //   reaches here had no usable credential.
            //   Non-zero minor indicates a specific sub-error (KDC unreachable, clock skew,
            //   etc.) which should not silently downgrade to NTLM.
            return routine == UInt32(GSS_S_NO_CRED)
                || routine == UInt32(GSS_S_CREDENTIALS_EXPIRED)
                || routine == UInt32(GSS_S_BAD_MECH)
                || (routine == UInt32(GSS_S_FAILURE) && minor == 0)
        case .noTicket:
            return true
        case .importNameFailed, .emptyToken, .serviceTicketUnavailable:
            return false
        }
    }

    /// Whether `NegotiateAuthenticator` may answer this failure with NTLM.
    /// Besides a missing credential, that includes a service ticket that
    /// cannot be had: a proxy without a registered SPN is exactly where
    /// browsers fall back to NTLM, and an NTLM exchange needs no KDC on this
    /// side.
    package var permitsNTLMFallback: Bool {
        if case .serviceTicketUnavailable = self { return true }
        return isCredentialUnavailable
    }

    /// Short, machine-consumable reason code for the credential-unavailable
    /// case. Surfaced via `RuntimeEvent.detail` (e.g. `reason=bad_mech`) so
    /// UI and log consumers can distinguish "TGT missing" from "TGT
    /// expired" without parsing the full human error message.
    package var fallbackReasonCode: String {
        switch self {
        case .initSecContextFailed(let major, _):
            let routine = (major & kGSSRoutineErrorMask) >> 16
            switch routine {
            case UInt32(GSS_S_NO_CRED) >> 16: return "no_credential"
            case UInt32(GSS_S_CREDENTIALS_EXPIRED) >> 16: return "credentials_expired"
            case UInt32(GSS_S_BAD_MECH) >> 16: return "bad_mech"
            case UInt32(GSS_S_FAILURE) >> 16: return "failure"
            default: return "routine_\(routine)"
            }
        case .noTicket: return "no_ticket"
        case .serviceTicketUnavailable: return "service_ticket_unavailable"
        case .importNameFailed, .emptyToken: return "other"
        }
    }

    private static func gssRoutineDescription(_ major: OM_uint32) -> String {
        let routine = major & kGSSRoutineErrorMask
        switch routine {
        case UInt32(GSS_S_NO_CRED):
            return "no Kerberos credential available — run kinit or check macOS Kerberos SSO"
        case UInt32(GSS_S_CREDENTIALS_EXPIRED):
            return "Kerberos ticket has expired — run kinit to renew"
        case UInt32(GSS_S_BAD_NAME):
            return "invalid service name (SPN) — check the proxy hostname configuration"
        case UInt32(GSS_S_BAD_NAMETYPE):
            return "unsupported service name type"
        case UInt32(GSS_S_DEFECTIVE_TOKEN):
            return "the proxy sent a defective authentication token"
        case UInt32(GSS_S_DEFECTIVE_CREDENTIAL):
            return "the local Kerberos credential is defective"
        case UInt32(GSS_S_BAD_MECH):
            // Apple's Heimdal returns BAD_MECH in two distinct cases:
            //
            //   1. No TGT exists in the user's default credential cache.
            //      Fix: run `kinit` (legacy) or sign back into the Kerberos
            //      SSO Extension via System Settings.
            //   2. A TGT exists but the Apple Kerberos SSO Extension's
            //      `credentialBundleIDACL` does not include this app's
            //      bundle ID. The extension owns the default credential
            //      cache (cache type `API:<UUID>`) and gates which apps may
            //      use it. WKWebView- and NSURLSession-based system apps
            //      (Safari, Edge) are admitted natively; everything else
            //      must be explicitly listed by the MDM administrator.
            //      Fix: ask IT to add `io.github.srps.Conduit` to the
            //      `credentialBundleIDACL` array in the SSO Extension
            //      configuration profile (payload `com.apple.extensiblesso`).
            //
            // A third case, a TGT whose service-ticket request fails, is
            // also BAD_MECH; `initiatorFailure` separates it out as
            // `.serviceTicketUnavailable` because the TGT is visible to us.
            //
            // We can't distinguish (1) from (2) from the GSS routine code
            // alone — both manifest as BAD_MECH. The message names both so
            // the user (or their IT) can pick the right action. NTLM
            // fallback fires if NTLM credentials are saved.
            return "Kerberos credential unavailable — either no TGT (run kinit) or the Apple Kerberos SSO Extension is not allowing this app to use its credentials (ask IT to add io.github.srps.Conduit to the SSO profile's credentialBundleIDACL); falling back to NTLM if a saved password is available"
        case UInt32(GSS_S_BAD_BINDINGS):
            return "channel binding mismatch — the proxy may require TLS channel binding (EPA) which macOS GSS does not support"
        case UInt32(GSS_S_FAILURE):
            return "authentication failed"
        default:
            return "authentication failed (routine error \(routine >> 16))"
        }
    }
}

// MARK: - KerberosAuthenticator

/// Authenticator that produces SPNEGO (Negotiate) tokens via a `GSSTokenProvider`.
/// Handles HTTP Negotiate header parsing, base64 encoding, and scheme matching.
/// Production uses `SystemGSSTokenProvider` (macOS GSS.framework); tests inject a mock.
package final class KerberosAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    package let scheme = "Negotiate"

    private let tokenProvider: GSSTokenProvider

    package init(tokenProvider: GSSTokenProvider = SystemGSSTokenProvider()) {
        self.tokenProvider = tokenProvider
    }

    package func initialToken(for host: String) throws -> String {
        guard let tokenData = try tokenProvider.generateToken(host: host, inputToken: nil) else {
            throw KerberosAuthError.emptyToken
        }
        return "Negotiate \(tokenData.base64EncodedString())"
    }

    package func processChallenge(headerValues: [String], host: String) throws -> String? {
        guard let inputBase64 = extractNegotiateToken(from: headerValues) else {
            return nil
        }
        let inputData: Data?
        if inputBase64.isEmpty {
            inputData = nil
        } else {
            guard let decoded = Data(base64Encoded: inputBase64) else {
                return nil
            }
            inputData = decoded
        }
        guard let tokenData = try tokenProvider.generateToken(host: host, inputToken: inputData) else {
            return nil
        }
        return "Negotiate \(tokenData.base64EncodedString())"
    }

    package func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    package func reset() {
        tokenProvider.resetContext()
    }

    private func extractNegotiateToken(from headers: [String]) -> String? {
        for header in headers {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare("Negotiate") == .orderedSame {
                return ""
            }
            let prefix = "Negotiate "
            if trimmed.count > prefix.count,
               trimmed[trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: prefix.count)].caseInsensitiveCompare(prefix) == .orderedSame {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }
}

/// Composite authenticator: tries Kerberos (Negotiate) first, falls back to NTLM
/// if Kerberos fails and NTLM credentials are available.
/// Only falls back on credential-class errors (missing/expired ticket) and on
/// a service ticket that cannot be obtained (`permitsNTLMFallback`).
/// Configuration and integrity errors propagate without downgrading.
package final class NegotiateAuthenticator: FallbackDeferringAuthenticator, @unchecked Sendable {
    package let scheme = "Negotiate"

    /// Callback invoked on successful initial-leg Kerberos token production.
    /// Receives the target host. Used by the auth factory to fire an
    /// `auth.kerberos_succeeded` `RuntimeEvent` so the UI chip can reflect
    /// that Kerberos actually ran — not merely that `authMode == .systemNegotiated`.
    package typealias KerberosSuccessHandler = @Sendable (_ host: String) -> Void
    /// Callback invoked on the credential-unavailable branch that triggers
    /// NTLM fallback. Receives the target host plus a short machine-readable
    /// reason code (see `KerberosAuthError.fallbackReasonCode`). Used by the
    /// auth factory to fire an `auth.kerberos_fallback_ntlm` `RuntimeEvent`
    /// so the silent downgrade to NTLM is no longer invisible.
    package typealias KerberosFallbackHandler = @Sendable (_ host: String, _ reason: String) -> Void

    private let kerberos: KerberosAuthenticator
    private var ntlmFallback: NTLMAuthenticator?
    private let ntlmFallbackProvider: (@Sendable () -> NTLMAuthenticator?)?
    private let onKerberosSuccess: KerberosSuccessHandler?
    private let onKerberosFallback: KerberosFallbackHandler?
    private let lock = NSLock()
    private var usingFallback = false

    package init(
        ntlmFallback: NTLMAuthenticator? = nil,
        onKerberosSuccess: KerberosSuccessHandler? = nil,
        onKerberosFallback: KerberosFallbackHandler? = nil
    ) {
        self.kerberos = KerberosAuthenticator()
        self.ntlmFallback = ntlmFallback
        self.ntlmFallbackProvider = nil
        self.onKerberosSuccess = onKerberosSuccess
        self.onKerberosFallback = onKerberosFallback
    }

    package init(
        ntlmFallbackProvider: @Sendable @escaping () -> NTLMAuthenticator?,
        onKerberosSuccess: KerberosSuccessHandler? = nil,
        onKerberosFallback: KerberosFallbackHandler? = nil
    ) {
        self.kerberos = KerberosAuthenticator()
        self.ntlmFallback = nil
        self.ntlmFallbackProvider = ntlmFallbackProvider
        self.onKerberosSuccess = onKerberosSuccess
        self.onKerberosFallback = onKerberosFallback
    }

    package init(
        kerberos: KerberosAuthenticator,
        ntlmFallback: NTLMAuthenticator? = nil,
        onKerberosSuccess: KerberosSuccessHandler? = nil,
        onKerberosFallback: KerberosFallbackHandler? = nil
    ) {
        self.kerberos = kerberos
        self.ntlmFallback = ntlmFallback
        self.ntlmFallbackProvider = nil
        self.onKerberosSuccess = onKerberosSuccess
        self.onKerberosFallback = onKerberosFallback
    }

    private func resolvedFallback() -> NTLMAuthenticator? {
        if let ntlmFallback { return ntlmFallback }
        if let provider = ntlmFallbackProvider {
            let resolved = provider()
            ntlmFallback = resolved
            return resolved
        }
        return nil
    }

    package func initialToken(for host: String) throws -> String {
        try initialToken(for: host, allowFallback: true).token
    }

    /// `FallbackDeferringAuthenticator`: with `allowFallback` false a
    /// credential-unavailable Kerberos failure is thrown instead of answered
    /// with NTLM, so the kernel's retry can give the ticket a moment to return.
    package func initialToken(for host: String, allowFallback: Bool) throws -> (token: String, usedFallback: Bool) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let token = try kerberos.initialToken(for: host)
            usingFallback = false
            onKerberosSuccess?(host)
            return (token, false)
        } catch let kerberosError as KerberosAuthError where kerberosError.permitsNTLMFallback {
            // Deferring the fallback gives a credential that may come back a
            // moment to do so. A failure that is not retryable, such as a
            // service ticket the KDC would not issue, gains nothing from the
            // wait, and the caller will not retry it to reach the last attempt.
            if allowFallback || !kerberosError.isCredentialRetryable, let fallback = resolvedFallback() {
                usingFallback = true
                onKerberosFallback?(host, kerberosError.fallbackReasonCode)
                return (try fallback.initialToken(for: host), true)
            }
            throw kerberosError
        }
    }

    package func processChallenge(headerValues: [String], host: String) throws -> String? {
        lock.lock()
        let fallback = usingFallback
        lock.unlock()

        if fallback, let ntlm = resolvedFallback() {
            return try ntlm.processChallenge(headerValues: headerValues, host: host)
        }
        return try kerberos.processChallenge(headerValues: headerValues, host: host)
    }

    package func canHandle(scheme: String) -> Bool {
        if kerberos.canHandle(scheme: scheme) { return true }
        if let existing = ntlmFallback { return existing.canHandle(scheme: scheme) }
        if ntlmFallbackProvider != nil {
            return scheme.caseInsensitiveCompare("NTLM") == .orderedSame
                || scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
        }
        return false
    }

    package func reset() {
        lock.lock()
        usingFallback = false
        lock.unlock()
        kerberos.reset()
        ntlmFallback?.reset()
    }
}
