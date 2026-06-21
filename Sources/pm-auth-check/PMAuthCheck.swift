// SPDX-License-Identifier: Apache-2.0
// pm-auth-check — diagnostic CLI that exercises every realistic GSS path
// against a target proxy host and reports which one(s) succeed.
//
// Used to triangulate "Kerberos works for some apps but not Conduit"
// reports. On macOS Tahoe (26+) with the Apple Kerberos SSO Extension
// installed, ad-hoc-signed apps can be denied default-credential delivery
// even when the SSO profile's `credentialBundleIDACL` is absent. This CLI
// runs four progressively more explicit credential-acquisition strategies
// so we can tell which (if any) gets past the extension's policy filter.
//
// Side-effect surface (mirrors AGENTS.md's pm-proxy constraint):
//   - GSS framework calls (gss_*, GSSCreate*) against the user's live
//     Heimdal cache.
//   - One DNS-style hostname argument. No proxy listener, no Keychain,
//     no system-proxy mutation, no privileged helper IPC.
//
// Usage:
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-auth-check
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-auth-check --host proxy.example.test
//   DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
//     xcrun swift run pm-auth-check --host proxy.example.test \
//       --cache-uuid 04BAA863-CF77-4951-95C3-D40E2FFFC4C8

import CoreFoundation
import Foundation
import GSS
import ProxyKernel

@main
enum PMAuthCheck {
    static func main() {
        let args = parseArgs()

        print("pm-auth-check — GSS / SSO Extension diagnostic")
        print("  target host  : \(args.host)")
        print("  cache UUID   : \(args.cacheUUID ?? "<auto>")")
        print("  bundle ID    : \(Bundle.main.bundleIdentifier ?? "<n/a (CLI binary)>")")
        print("  process exec : \(executablePath())")
        print("  signing kind : \(codeSigningSummary())")
        print()

        printHeimdalDefaultMech()
        printAvailableMechs()

        // Test 1 — what production code does today: gss_init_sec_context with
        // claimant_cred_handle = NULL ("use my default credential"). This routes
        // through the SSO Extension's default-policy filter on Tahoe.
        runTest(
            label: "Test 1: gss_init_sec_context, default credential (current production code)",
            host: args.host
        ) { name in
            return try acquireSecContextWithDefaultCred(targetName: name)
        }

        // Test 2 — explicit gss_acquire_cred with GSS_C_NO_NAME first, then pass
        // the resulting handle as claimant_cred_handle. Some Heimdal builds
        // route NULL-default through a different code path than an explicit
        // acquire, so this is worth testing in isolation.
        runTest(
            label: "Test 2: gss_acquire_cred(GSS_C_NO_NAME, INITIATE) then init_sec_context",
            host: args.host
        ) { name in
            return try acquireSecContextWithExplicitDefaultCred(targetName: name)
        }

        // Test 3 — Apple's GSSCreateCredentialFromUUID, using the cache UUID we
        // already have from `klist`. This addresses the cache by UUID, which on
        // Tahoe should bypass any "give me whatever default you want" filtering.
        // If the user passed --cache-uuid we use that; otherwise we try to
        // discover one via gss_iter_creds.
        let resolvedUUID = args.cacheUUID ?? discoverFirstCacheUUID()
        if let uuidString = resolvedUUID {
            runTest(
                label: "Test 3: GSSCreateCredentialFromUUID(\(uuidString)) then init_sec_context",
                host: args.host
            ) { name in
                return try acquireSecContextWithCredFromUUID(uuidString: uuidString, targetName: name)
            }
        } else {
            print("=== Test 3: SKIPPED (no cache UUID available) ===")
            print()
        }

        // Test 4 — gss_acquire_cred with the user's principal NAME (parsed from
        // klist's "Principal:" line via env var KRB_PRINCIPAL or auto). This
        // tells the framework "give me the credential for this user," which
        // some SSO implementations special-case to honor.
        if let principal = ProcessInfo.processInfo.environment["KRB_PRINCIPAL"] {
            runTest(
                label: "Test 4: gss_acquire_cred with explicit principal '\(principal)' then init_sec_context",
                host: args.host
            ) { name in
                return try acquireSecContextWithPrincipal(principal: principal, targetName: name)
            }
        } else {
            print("=== Test 4: SKIPPED (set KRB_PRINCIPAL=user@REALM to enable) ===")
            print()
        }

        print("---")
        print("Reading the results:")
        print("  • If Test 1 returns CONTINUE_NEEDED with a token > 0 bytes, production")
        print("    code already works for this binary; Conduit.app probably has a")
        print("    different signing identity and needs to be re-signed/installed.")
        print("  • If Test 1 fails with BAD_MECH (major=65536) but Test 2 or 3 succeeds,")
        print("    we should change production code to use that path.")
        print("  • If all tests fail with the same BAD_MECH, the SSO Extension is")
        print("    excluding this binary regardless of API call shape — fix is signing,")
        print("    notarization, or asking IT to add the bundle ID to credentialBundleIDACL.")
    }

    // MARK: - Test paths

    private static func acquireSecContextWithDefaultCred(targetName: gss_name_t) throws -> InitSecContextResult {
        var minor: OM_uint32 = 0
        var output = gss_buffer_desc(length: 0, value: nil)
        var ctx: gss_ctx_id_t?
        var retFlags: OM_uint32 = 0

        let major = withSPNEGOMech { mechPtr -> OM_uint32 in
            return gss_init_sec_context(
                &minor,
                nil,                          // claimant_cred_handle = NULL → default cred
                &ctx,
                targetName,
                mechPtr,
                kFlags,
                0, nil, nil, nil,
                &output, &retFlags, nil
            )
        }
        defer {
            var rel: OM_uint32 = 0
            gss_release_buffer(&rel, &output)
            if ctx != nil { gss_delete_sec_context(&rel, &ctx, nil) }
        }
        return InitSecContextResult(major: major, minor: minor, tokenLength: output.length)
    }

    private static func acquireSecContextWithExplicitDefaultCred(targetName: gss_name_t) throws -> InitSecContextResult {
        var minor: OM_uint32 = 0
        var cred: gss_cred_id_t?
        let acquireMajor = gss_acquire_cred(
            &minor,
            nil,                              // desired_name = NULL → default
            OM_uint32(GSS_C_INDEFINITE),
            nil,                              // desired_mechs = NULL → all
            gss_cred_usage_t(GSS_C_INITIATE),
            &cred,
            nil,
            nil
        )
        guard acquireMajor == 0, let credHandle = cred else {
            throw GSSError(major: acquireMajor, minor: minor, stage: "acquire_cred")
        }
        defer { var rel: OM_uint32 = 0; gss_release_cred(&rel, &cred) }

        var output = gss_buffer_desc(length: 0, value: nil)
        var ctx: gss_ctx_id_t?
        var retFlags: OM_uint32 = 0

        let initMajor = withSPNEGOMech { mechPtr -> OM_uint32 in
            gss_init_sec_context(
                &minor,
                credHandle,
                &ctx,
                targetName,
                mechPtr,
                kFlags,
                0, nil, nil, nil,
                &output, &retFlags, nil
            )
        }
        defer {
            var rel: OM_uint32 = 0
            gss_release_buffer(&rel, &output)
            if ctx != nil { gss_delete_sec_context(&rel, &ctx, nil) }
        }
        return InitSecContextResult(major: initMajor, minor: minor, tokenLength: output.length)
    }

    private static func acquireSecContextWithCredFromUUID(uuidString: String, targetName: gss_name_t) throws -> InitSecContextResult {
        guard let cfuuid = CFUUIDCreateFromString(kCFAllocatorDefault, uuidString as CFString) else {
            throw GSSError(major: 0, minor: 0, stage: "CFUUIDCreateFromString failed for \(uuidString)")
        }
        guard let credUnmanaged = GSSCreateCredentialFromUUID(cfuuid) else {
            throw GSSError(major: 0, minor: 0, stage: "GSSCreateCredentialFromUUID returned NULL — UUID not in any cache the framework can see")
        }
        var cred: gss_cred_id_t? = credUnmanaged
        defer { var rel: OM_uint32 = 0; gss_release_cred(&rel, &cred) }

        var minor: OM_uint32 = 0
        var output = gss_buffer_desc(length: 0, value: nil)
        var ctx: gss_ctx_id_t?
        var retFlags: OM_uint32 = 0

        let initMajor = withSPNEGOMech { mechPtr -> OM_uint32 in
            gss_init_sec_context(
                &minor,
                credUnmanaged,
                &ctx,
                targetName,
                mechPtr,
                kFlags,
                0, nil, nil, nil,
                &output, &retFlags, nil
            )
        }
        defer {
            var rel: OM_uint32 = 0
            gss_release_buffer(&rel, &output)
            if ctx != nil { gss_delete_sec_context(&rel, &ctx, nil) }
        }
        return InitSecContextResult(major: initMajor, minor: minor, tokenLength: output.length)
    }

    private static func acquireSecContextWithPrincipal(principal: String, targetName: gss_name_t) throws -> InitSecContextResult {
        var minor: OM_uint32 = 0
        var principalName: gss_name_t? = try importPrincipalName(principal: principal)
        defer { var rel: OM_uint32 = 0; gss_release_name(&rel, &principalName) }

        var cred: gss_cred_id_t?
        let acquireMajor = gss_acquire_cred(
            &minor,
            principalName,
            OM_uint32(GSS_C_INDEFINITE),
            nil,
            gss_cred_usage_t(GSS_C_INITIATE),
            &cred,
            nil,
            nil
        )
        guard acquireMajor == 0, let credHandle = cred else {
            throw GSSError(major: acquireMajor, minor: minor, stage: "acquire_cred(principal)")
        }
        defer { var rel: OM_uint32 = 0; gss_release_cred(&rel, &cred) }

        var output = gss_buffer_desc(length: 0, value: nil)
        var ctx: gss_ctx_id_t?
        var retFlags: OM_uint32 = 0

        let initMajor = withSPNEGOMech { mechPtr -> OM_uint32 in
            gss_init_sec_context(
                &minor,
                credHandle,
                &ctx,
                targetName,
                mechPtr,
                kFlags,
                0, nil, nil, nil,
                &output, &retFlags, nil
            )
        }
        defer {
            var rel: OM_uint32 = 0
            gss_release_buffer(&rel, &output)
            if ctx != nil { gss_delete_sec_context(&rel, &ctx, nil) }
        }
        return InitSecContextResult(major: initMajor, minor: minor, tokenLength: output.length)
    }

    // MARK: - GSS helpers

    private static let kFlags: OM_uint32 = OM_uint32(
        GSS_C_MUTUAL_FLAG | GSS_C_REPLAY_FLAG | GSS_C_SEQUENCE_FLAG
    )

    /// SPNEGO OID 1.3.6.1.5.5.2 — encoded by hand instead of via the
    /// framework's `__gss_spnego_mechanism_oid_desc` extern, which Swift 6's
    /// strict-concurrency checker rejects as "not concurrency-safe because
    /// it involves shared mutable state". Mirrors `spnegoOIDBytes` in
    /// `KerberosAuth.swift` (verified byte-equal in pm-vpn-check).
    private static let spnegoOIDBytes: [UInt8] = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
    /// GSS_C_NT_HOSTBASED_SERVICE OID 1.2.840.113554.1.2.1.4
    private static let hostbasedServiceOIDBytes: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04]
    /// GSS_C_NT_USER_NAME OID 1.2.840.113554.1.2.1.1
    private static let userNameOIDBytes: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x01]

    private static func withSPNEGOMech<R>(_ body: (UnsafeMutablePointer<gss_OID_desc>) -> R) -> R {
        var bytes = spnegoOIDBytes
        return bytes.withUnsafeMutableBufferPointer { ptr in
            var oid = gss_OID_desc(length: OM_uint32(ptr.count), elements: ptr.baseAddress)
            return withUnsafeMutablePointer(to: &oid, body)
        }
    }

    private static func withHostbasedServiceMech<R>(_ body: (UnsafeMutablePointer<gss_OID_desc>) -> R) -> R {
        var bytes = hostbasedServiceOIDBytes
        return bytes.withUnsafeMutableBufferPointer { ptr in
            var oid = gss_OID_desc(length: OM_uint32(ptr.count), elements: ptr.baseAddress)
            return withUnsafeMutablePointer(to: &oid, body)
        }
    }

    private static func withUserNameMech<R>(_ body: (UnsafeMutablePointer<gss_OID_desc>) -> R) -> R {
        var bytes = userNameOIDBytes
        return bytes.withUnsafeMutableBufferPointer { ptr in
            var oid = gss_OID_desc(length: OM_uint32(ptr.count), elements: ptr.baseAddress)
            return withUnsafeMutablePointer(to: &oid, body)
        }
    }

    private static func runTest(
        label: String,
        host: String,
        body: (gss_name_t) throws -> InitSecContextResult
    ) {
        print("=== \(label) ===")
        do {
            var name: gss_name_t? = try importHostbasedServiceName(host: host)
            defer { var rel: OM_uint32 = 0; gss_release_name(&rel, &name) }
            guard let n = name else {
                print("  FAIL: gss_import_name returned nil")
                print()
                return
            }
            let result = try body(n)
            let majorHex = String(result.major, radix: 16)
            let routine = (result.major & 0x00FF_0000) >> 16
            let majorLabel = describeMajor(result.major)
            print("  major   : \(result.major) (0x\(majorHex)) \(majorLabel)")
            print("  routine : \(routine)")
            print("  minor   : \(result.minor)")
            print("  token   : \(result.tokenLength) bytes")
            if result.major == 0 || result.major == 1 {
                print("  ✓ SUCCESS — this auth path works for this binary.")
            } else {
                print("  ✗ FAILED — this path is blocked.")
            }
        } catch let err as GSSError {
            print("  GSSError at \(err.stage): major=\(err.major) minor=\(err.minor)")
        } catch {
            print("  Error: \(error)")
        }
        print()
    }

    private static func importHostbasedServiceName(host: String) throws -> gss_name_t {
        let spn = "HTTP@\(host)"
        var minor: OM_uint32 = 0
        var name: gss_name_t?
        let major: OM_uint32 = spn.withCString { cstr in
            var nameBuf = gss_buffer_desc(
                length: strlen(cstr),
                value: UnsafeMutableRawPointer(mutating: cstr)
            )
            return withHostbasedServiceMech { typePtr in
                gss_import_name(&minor, &nameBuf, typePtr, &name)
            }
        }
        guard major == 0, let n = name else {
            throw GSSError(major: major, minor: minor, stage: "import_name(HTTP@\(host))")
        }
        return n
    }

    private static func importPrincipalName(principal: String) throws -> gss_name_t {
        var minor: OM_uint32 = 0
        var name: gss_name_t?
        let major: OM_uint32 = principal.withCString { cstr in
            var nameBuf = gss_buffer_desc(
                length: strlen(cstr),
                value: UnsafeMutableRawPointer(mutating: cstr)
            )
            return withUserNameMech { typePtr in
                gss_import_name(&minor, &nameBuf, typePtr, &name)
            }
        }
        guard major == 0, let n = name else {
            throw GSSError(major: major, minor: minor, stage: "import_name(user='\(principal)')")
        }
        return n
    }

    private static func discoverFirstCacheUUID() -> String? {
        // gss_iter_creds enumerates the credentials the framework can see for
        // this process. Each yielded credential, on Apple's GSS, has an
        // attached CFUUIDRef accessible via GSSCredentialCopyUUID. The block
        // is invoked once per credential and once more with NULL to signal
        // completion. Wait briefly for that terminating callback.
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        var minor: OM_uint32 = 0
        gss_iter_creds(&minor, 0, nil) { _, cred in
            guard let cred else { semaphore.signal(); return }
            if box.uuidString == nil,
               let uuidUnmanaged = GSSCredentialCopyUUID(cred) {
                let uuid = uuidUnmanaged.takeRetainedValue()
                if let cfStr = CFUUIDCreateString(kCFAllocatorDefault, uuid) {
                    box.uuidString = cfStr as String
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        return box.uuidString
    }

    /// Tiny reference-typed inbox for the `gss_iter_creds` block, which
    /// can't capture mutable `var` cleanly under Swift 6.
    private final class ResultBox: @unchecked Sendable {
        var uuidString: String?
    }

    // MARK: - Diagnostics

    private static func printAvailableMechs() {
        var minor: OM_uint32 = 0
        var mechSet: gss_OID_set?
        let major = gss_indicate_mechs(&minor, &mechSet)
        guard major == 0, let set = mechSet else {
            print("Available mechanisms: <gss_indicate_mechs failed major=\(major)>")
            return
        }
        defer { var rel: OM_uint32 = 0; gss_release_oid_set(&rel, &mechSet) }

        let count = set.pointee.count
        print("Available mechanisms (\(count) total):")
        for i in 0..<count {
            let oid = set.pointee.elements.advanced(by: i)
            print("  \(i): \(oidString(oid))")
        }
        print()
    }

    private static func printHeimdalDefaultMech() {
        // The user's default Kerberos mechanism per krb5.conf, useful to
        // distinguish "no Kerberos at all" from "Kerberos exists but
        // SPNEGO selection is restricted".
        let env = ProcessInfo.processInfo.environment
        if let krb5cc = env["KRB5CCNAME"] {
            print("KRB5CCNAME env: \(krb5cc)")
        }
        if let krb5conf = env["KRB5_CONFIG"] {
            print("KRB5_CONFIG env: \(krb5conf)")
        }
    }

    private static func oidString(_ oid: UnsafePointer<gss_OID_desc>) -> String {
        let bytes = (0..<Int(oid.pointee.length)).map { i -> UInt8 in
            oid.pointee.elements.advanced(by: i).load(as: UInt8.self)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return hex
    }

    private static func describeMajor(_ major: OM_uint32) -> String {
        switch major {
        case 0: return "GSS_S_COMPLETE"
        case 1: return "GSS_S_CONTINUE_NEEDED (success, more rounds expected)"
        case 0x0001_0000: return "GSS_S_BAD_MECH"
        case 0x0007_0000: return "GSS_S_NO_CRED"
        case 0x000B_0000: return "GSS_S_CREDENTIALS_EXPIRED"
        case 0x000D_0000: return "GSS_S_FAILURE"
        default: return "(routine \((major & 0x00FF_0000) >> 16))"
        }
    }

    // MARK: - Process introspection

    private static func executablePath() -> String {
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        _ = _NSGetExecutablePath(&buf, &size)
        let length = buf.firstIndex(of: 0) ?? buf.count
        let bytes = buf[..<length].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func codeSigningSummary() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--verbose=2", executablePath()]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Keep one line summarizing identifier + signature kind
            let lines = output.split(whereSeparator: \.isNewline)
            let kept = lines.filter { line in
                line.contains("Identifier=") || line.contains("Authority=") ||
                line.contains("Signature=") || line.contains("adhoc")
            }
            return kept.joined(separator: " | ")
        } catch {
            return "<codesign unavailable: \(error.localizedDescription)>"
        }
    }

    // MARK: - Args

    private struct Args {
        var host: String
        var cacheUUID: String?
    }

    private static func parseArgs() -> Args {
        var host = "proxy.example.test"
        var cacheUUID: String?
        var iter = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iter.next() {
            switch arg {
            case "--host":
                if let next = iter.next() { host = next }
            case "--cache-uuid":
                if let next = iter.next() { cacheUUID = next }
            case "--help", "-h":
                print("Usage: pm-auth-check [--host <name>] [--cache-uuid <UUID>]")
                print("  Default host: proxy.example.test")
                print("  Optional KRB_PRINCIPAL=<user@REALM> env var enables Test 4.")
                exit(0)
            default:
                FileHandle.standardError.write(Data("Unknown arg: \(arg)\n".utf8))
            }
        }
        return Args(host: host, cacheUUID: cacheUUID)
    }
}

private struct InitSecContextResult {
    let major: OM_uint32
    let minor: OM_uint32
    let tokenLength: Int
}

private struct GSSError: Error, CustomStringConvertible {
    let major: OM_uint32
    let minor: OM_uint32
    let stage: String

    var description: String {
        "GSSError(\(stage)) major=\(major) minor=\(minor)"
    }
}
