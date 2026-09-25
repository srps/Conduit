// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Security

// Who may call the helper, beyond being the console user (#46).
//
// The console-uid rule in `HelperAdmission` says *whose* process is asking;
// it says nothing about *which* program. Any binary the console user runs
// could reshape the system proxy. This adds the program: the helper reads
// the peer's audit token off the connection itself, asks the Security
// framework for the code behind it, and checks that code against a
// requirement `install-helper.sh` pinned — the leaf certificate of the local
// signing identity plus the identifiers of the programs that call the helper.
//
// Nothing here is supplied by the caller. The audit token carries a pid
// *version*, so the code the kernel reports is the code on the other end of
// this socket, not whatever reused its pid; a caller-supplied pid or path
// would be the reverse.

/// What `helper-callers.req` tells the helper, read once at start.
package enum HelperCallerPolicy: Equatable, Sendable {
    /// No requirement file, and a directory nobody else could have deleted
    /// one from. Admit by console uid alone, as before #46, and say so.
    case unenforced
    /// Callers must satisfy this code-signing requirement.
    case enforced(requirement: String)
    /// A requirement file exists but cannot be trusted: owned by someone
    /// other than root, writable by group or others, a symlink, oversized,
    /// unreadable, or not a requirement the Security framework compiles.
    ///
    /// Refuses every caller. Treating it as `unenforced` would make "chmod
    /// the pin" a downgrade anyone who can do it could use, and a pin whose
    /// content we cannot vouch for could name the attacker's certificate;
    /// either way admitting on it is worse than having no pin. The owner's
    /// recovery is the same command that wrote it: `sudo ./install-helper.sh`.
    case untrusted(reason: String)
}

/// What the helper could learn about the program on the other end.
/// Everything but `satisfiesRequirement` is for the audit line only.
package struct HelperCallerIdentity: Equatable, Sendable {
    /// From the audit token; diagnostics only, never a key for anything.
    package var pid: pid_t?
    /// Effective uid from the same token; for the audit line. Admission by
    /// uid stays with `getpeereid` and `HelperAdmission`.
    package var uid: uid_t?
    package var signingIdentifier: String?
    /// The first bytes of the code directory hash, in hex.
    package var cdhashPrefix: String?
    /// Signed with `--options runtime`. Without it a same-uid process can
    /// start the genuine app with `DYLD_INSERT_LIBRARIES` and speak through
    /// a signature that still checks out.
    package var hardenedRuntime: Bool
    /// `nil` when no requirement was checked (policy not `enforced`).
    package var satisfiesRequirement: Bool?
    /// Why the identity could not be read at all; `nil` when it was.
    package var readFailure: String?

    package init(
        pid: pid_t? = nil,
        uid: uid_t? = nil,
        signingIdentifier: String? = nil,
        cdhashPrefix: String? = nil,
        hardenedRuntime: Bool = false,
        satisfiesRequirement: Bool? = nil,
        readFailure: String? = nil
    ) {
        self.pid = pid
        self.uid = uid
        self.signingIdentifier = signingIdentifier
        self.cdhashPrefix = cdhashPrefix
        self.hardenedRuntime = hardenedRuntime
        self.satisfiesRequirement = satisfiesRequirement
        self.readFailure = readFailure
    }

    /// One line's worth, no secrets: the helper logs it for every peer.
    package var auditSummary: String {
        var parts = [
            "pid=\(pid.map(String.init) ?? "?")",
            "uid=\(uid.map(String.init) ?? "?")",
            "id=\(signingIdentifier.map(HelperAudit.safe) ?? "?")",
            "cdhash=\(cdhashPrefix ?? "?")",
            "runtime=\(hardenedRuntime ? "yes" : "no")",
        ]
        // The helper's own words (`strerror`, an OSStatus message), bounded all the same.
        if let readFailure { parts.append("identity-error=\"\(HelperAudit.bounded(readFailure))\"") }
        return parts.joined(separator: " ")
    }
}

/// Reads a connected peer's identity. The seam between the admission
/// decision, which is pure, and the Security framework, which is not.
package protocol HelperCallerIdentifying {
    func identify(fd: Int32) -> HelperCallerIdentity
}

/// Whether identity lets a peer through, before the console-uid rule has
/// its say.
package enum HelperCallerVerdict: Equatable, Sendable {
    /// Enforced, and the peer is a pinned program under the hardened runtime.
    case verified
    /// No pin installed: identity is recorded, not required.
    case unenforced
    /// Refused whatever it asks.
    case refused(HelperCallerRefusal)
}

/// Why identity refused a peer. Sent to the peer as the `errorMessage` of an
/// `.unauthorized` refusal, and logged as `auditOutcome` only.
package enum HelperCallerRefusal: Equatable, Sendable {
    /// The pin exists but cannot be vouched for. `reason` is the helper's own
    /// text (a path, a mode, `strerror`), never the peer's.
    case policyUntrusted(reason: String)
    /// The Security framework could not say what the peer is.
    case identityUnreadable
    /// The peer's code fails the pin. The identifier is the peer's own
    /// choice of name, so it only ever appears through `auditSafe`.
    case notPinned(identifier: String?)
    /// Pinned, but open to `DYLD_INSERT_LIBRARIES`.
    case noHardenedRuntime(identifier: String?)

    /// Every identity refusal's `errorMessage` starts with this, and nothing
    /// else the helper sends does. The app reads it to tell "this build is
    /// not the pinned one" (rebuild, rerun `install-helper.sh`) from "you are
    /// not the console user", without a new wire field: an older app just
    /// shows the message. Part of the helper contract; do not reword it.
    package static let messagePrefix = "caller identity: "

    package var message: String {
        switch self {
        case .policyUntrusted(let reason):
            return Self.messagePrefix
                + "the helper's caller pin is not trustworthy (\(reason)); an administrator must rerun sudo ./install-helper.sh"
        case .identityUnreadable:
            return Self.messagePrefix + "the helper could not read this program's code signature"
        case .notPinned(let identifier):
            return Self.messagePrefix
                + "\(Self.who(identifier)) is not signed by the identity this helper was installed for; "
                + "build the app with ./bundle-app.sh after scripts/create-signing-identity.sh, "
                + "then rerun sudo ./install-helper.sh"
        case .noHardenedRuntime(let identifier):
            return Self.messagePrefix
                + "\(Self.who(identifier)) is not signed with the hardened runtime; rebuild it with ./bundle-app.sh"
        }
    }

    package var auditOutcome: HelperAuditOutcome {
        switch self {
        case .policyUntrusted: return .refusedPolicyUntrusted
        case .identityUnreadable: return .refusedIdentityUnreadable
        case .notPinned: return .refusedNotPinned
        case .noHardenedRuntime: return .refusedNoHardenedRuntime
        }
    }

    private static func who(_ identifier: String?) -> String {
        identifier.map { "'\(HelperAudit.safe($0))'" } ?? "this program"
    }
}

extension HelperAdmission {
    /// The identity half of admission. Pure: the policy was read at helper
    /// start and the identity off the socket, and this only decides.
    ///
    /// A refusal here is known before the request is read, so it belongs in
    /// the early verdict (`refusalBeforeReading`) — no command could change it.
    package static func callerVerdict(policy: HelperCallerPolicy, identity: HelperCallerIdentity) -> HelperCallerVerdict {
        switch policy {
        case .unenforced:
            return .unenforced
        case .untrusted(let reason):
            return .refused(.policyUntrusted(reason: reason))
        case .enforced:
            if identity.readFailure != nil {
                return .refused(.identityUnreadable)
            }
            guard identity.satisfiesRequirement == true else {
                return .refused(.notPinned(identifier: identity.signingIdentifier))
            }
            guard identity.hardenedRuntime else {
                return .refused(.noHardenedRuntime(identifier: identity.signingIdentifier))
            }
            return .verified
        }
    }
}

// MARK: - Audit

/// How a connection ended, as the audit line records it: a closed set, so
/// nothing a peer sends — a domain, a service name, a URL echoed back in an
/// error — can reach the log through it. The peer still gets the full error
/// text in its reply; the log gets the category.
package enum HelperAuditOutcome: String, CaseIterable, Sendable {
    case ok
    case invalidRequest = "invalid-request"
    case unsupportedVersion = "unsupported-version"
    case invalidArguments = "invalid-arguments"
    case commandFailed = "command-failed"
    case relayFailed = "relay-failed"
    case refusedNotConsoleUser = "refused-not-console-user"
    case deferredNoConsoleUser = "deferred-no-console-user"
    case refusedPolicyUntrusted = "refused-policy-untrusted"
    case refusedIdentityUnreadable = "refused-identity-unreadable"
    case refusedNotPinned = "refused-not-pinned"
    case refusedNoHardenedRuntime = "refused-no-hardened-runtime"
}

package enum HelperAudit {
    /// The most of a peer-chosen string a log line will carry.
    package static let maxFieldLength = 128

    /// A peer-chosen string (its signing identifier) made fit for one log
    /// line: bundle-identifier characters only, everything else `?`, bounded.
    /// A code signature's identifier is whatever its signer typed, and the
    /// peer being logged is the one under suspicion.
    package static func safe(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars.prefix(maxFieldLength) {
            let ok = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
            out.unicodeScalars.append(ok ? scalar : "?")
        }
        if value.unicodeScalars.count > maxFieldLength { out += "…" }
        return out
    }

    /// The helper's own text for one quoted field: printable ASCII, no quote,
    /// bounded. For words the helper chose, not the peer.
    package static func bounded(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars.prefix(maxFieldLength) {
            let printable = scalar.value >= 0x20 && scalar.value < 0x7f && scalar != "\""
            out.unicodeScalars.append(printable ? scalar : "?")
        }
        return out
    }

    /// The one line per connection. Takes no request values and no error
    /// text: only what the helper itself measured or decided.
    package static func line(
        identity: HelperCallerIdentity,
        verdict: HelperCallerVerdict,
        command: HelperCommand?,
        outcome: HelperAuditOutcome
    ) -> String {
        let word: String
        switch verdict {
        case .verified: word = "verified"
        case .unenforced: word = "unenforced"
        case .refused: word = "refused"
        }
        return "peer \(identity.auditSummary) identity=\(word) command=\(command?.rawValue ?? "?") outcome=\(outcome.rawValue)"
    }
}

// MARK: - The requirement file

package enum HelperCallerPolicyFile {
    /// A requirement for two identifiers and one certificate is well under
    /// a kilobyte; anything near this is not one of ours.
    package static let maxBytes = 4_096

    /// Reads the pin without following links, and trusts it only if the file
    /// *and* its directory are owned by `requiredOwner` (root in production)
    /// and writable by nobody else. A directory someone else can write to
    /// is where a pin could have been deleted from, so it is `untrusted`
    /// even with no file in it; only a missing directory, or a sound one
    /// with no file, is `unenforced`.
    package static func load(
        path: String = HelperConstants.callerRequirementPath,
        requiredOwner: uid_t = 0
    ) -> HelperCallerPolicy {
        let directory = (path as NSString).deletingLastPathComponent
        var dirStat = stat()
        if lstat(directory, &dirStat) != 0 {
            let code = errno
            return code == ENOENT ? .unenforced : .untrusted(reason: "cannot inspect \(directory): \(String(cString: strerror(code)))")
        }
        if let problem = ownershipProblem(dirStat, requiredOwner: requiredOwner, expectDirectory: true) {
            return .untrusted(reason: "\(directory) \(problem)")
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return .unenforced }
            if code == ELOOP { return .untrusted(reason: "\(path) is a symbolic link") }
            return .untrusted(reason: "cannot open \(path): \(String(cString: strerror(code)))")
        }
        defer { close(fd) }
        // Checked on the descriptor, not the path: what was vetted is what is read.
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            return .untrusted(reason: "cannot inspect \(path): \(String(cString: strerror(errno)))")
        }
        if let problem = ownershipProblem(fileStat, requiredOwner: requiredOwner, expectDirectory: false) {
            return .untrusted(reason: "\(path) \(problem)")
        }
        guard fileStat.st_size <= maxBytes else {
            return .untrusted(reason: "\(path) is \(fileStat.st_size) bytes, over \(maxBytes)")
        }
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var total = 0
        while total < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, $0.count - total) }
            if n < 0 {
                if errno == EINTR { continue }
                return .untrusted(reason: "cannot read \(path): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            total += n
        }
        guard total <= maxBytes else {
            return .untrusted(reason: "\(path) grew past \(maxBytes) bytes while being read")
        }
        guard let text = String(bytes: bytes[0..<total], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .untrusted(reason: "\(path) is empty or not UTF-8")
        }
        return .enforced(requirement: text)
    }

    private static func ownershipProblem(_ info: stat, requiredOwner: uid_t, expectDirectory: Bool) -> String? {
        let type = info.st_mode & S_IFMT
        if expectDirectory, type != S_IFDIR { return "is not a directory" }
        if !expectDirectory, type != S_IFREG { return "is not a regular file" }
        if info.st_uid != requiredOwner { return "is owned by uid \(info.st_uid), not \(requiredOwner)" }
        if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            return "is writable by group or others (mode \(String(info.st_mode & 0o7777, radix: 8)))"
        }
        return nil
    }
}

// MARK: - The Security framework

/// Identifies the peer by its audit token: `LOCAL_PEERTOKEN` on the socket,
/// then `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`.
package struct SecCodeCallerIdentifier: HelperCallerIdentifying {
    package enum CompileError: Error, CustomStringConvertible {
        case invalidRequirement(OSStatus)
        package var description: String {
            switch self {
            case .invalidRequirement(let status):
                return "requirement does not compile (\(SecCodeCallerIdentifier.describe(status)))"
            }
        }
    }

    private let requirement: SecRequirement?

    /// `requirementText` nil: identify for the audit line, check nothing.
    package init(requirementText: String?) throws {
        guard let requirementText else {
            requirement = nil
            return
        }
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirementText as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw CompileError.invalidRequirement(status)
        }
        requirement = compiled
    }

    /// The peer's audit token, straight from the kernel.
    package static func peerAuditToken(fd: Int32) -> Result<audit_token_t, POSIXError> {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL))
        }
        return .success(token)
    }

    package func identify(fd: Int32) -> HelperCallerIdentity {
        let token: audit_token_t
        switch Self.peerAuditToken(fd: fd) {
        case .success(let value): token = value
        case .failure(let code):
            return HelperCallerIdentity(readFailure: "LOCAL_PEERTOKEN: \(String(cString: strerror(code.code.rawValue)))")
        }
        // `audit_token_to_pid` lives in libbsm, which nothing else here
        // links; the token's sixth word is the pid (<bsm/audit.h>). Logged,
        // never trusted — the token itself is what the code is looked up by.
        // The second word is the effective uid.
        var identity = HelperCallerIdentity(pid: pid_t(bitPattern: token.val.5), uid: token.val.1)

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            identity.readFailure = "SecCodeCopyGuestWithAttributes: \(Self.describe(guestStatus))"
            return identity
        }

        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
               let dict = info as? [String: Any] {
                identity.signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String
                if let unique = dict[kSecCodeInfoUnique as String] as? Data {
                    identity.cdhashPrefix = unique.prefix(6).map { String(format: "%02x", $0) }.joined()
                }
                if let flags = dict[kSecCodeInfoFlags as String] as? UInt32 {
                    identity.hardenedRuntime = flags & SecCodeSignatureFlags.runtime.rawValue != 0
                }
            }
        }

        if let requirement {
            // Dynamic validity too: a process whose pages no longer match its
            // signature fails here even though its file on disk would pass.
            identity.satisfiesRequirement = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        return identity
    }

    static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(status): \(message)"
        }
        return "\(status)"
    }
}
