// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import CryptoKit
import Foundation
import Security

package struct UpdateCandidate: Sendable {
    package let archive: URL
    package let version: String
    package let length: UInt64
    package let signature: String
    package let publicKey: String
    package let host: URL

    package init(archive: URL, version: String, length: UInt64, signature: String, publicKey: String, host: URL) {
        self.archive = archive; self.version = version; self.length = length
        self.signature = signature; self.publicKey = publicKey; self.host = host
    }
}

package struct UpdatePreflightError: Error, LocalizedError, Sendable {
    package let reason: String
    package init(_ reason: String) { self.reason = reason }
    package var errorDescription: String? { reason }
}

/// Only checks compatibility. Sparkle remains the archive installer and
/// performs its own authentication of the bytes it independently downloads.
package protocol UpdatePreflighting: Sendable {
    func check(_ candidate: UpdateCandidate) async throws
}

package enum UpdatePreflightLimits {
    package static let archiveBytes = 256 * 1_024 * 1_024
    package static let expandedBytes = 1_024 * 1_024 * 1_024
    package static let archiveEntries = 16_384
    package static let downloadTimeout: TimeInterval = 120
}

/// Composition roots receive the protocol, not the platform implementation.
package func systemUpdatePreflight() -> any UpdatePreflighting { SystemUpdatePreflight() }

struct SystemUpdatePreflight: UpdatePreflighting {
    private let run: @Sendable (String, [String]) throws -> CommandResult

    init(run: @escaping @Sendable (String, [String]) throws -> CommandResult = {
        try CommandRunner.run(launchPath: $0, arguments: $1, timeout: 30, maxOutputBytes: 4_096)
    }) { self.run = run }

    func check(_ candidate: UpdateCandidate) async throws {
        guard candidate.length > 0, candidate.length <= UpdatePreflightLimits.archiveBytes,
              UpdateArchiveDownload.allowed(candidate.archive) else {
            throw UpdatePreflightError("invalid_update_archive")
        }
        // One directory per host, protected by the updater's existing host
        // ownership lock. A new attempt removes a previous interrupted one.
        let digest = SHA256.hash(data: Data(candidate.host.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-update-preflight-\(digest)")
        try Self.resetStage(stage)
        do {
            let archive = stage.appendingPathComponent("candidate.zip")
            try await UpdateArchiveDownload.fetch(candidate.archive, to: archive)
            try await Task.detached {
                try Self.authenticate(archive, candidate: candidate)
                try validate(archive, in: stage, candidate: candidate)
            }.value
        } catch {
            let primary = (error as? UpdatePreflightError)?.reason ?? "preflight_error"
            do { try FileManager.default.removeItem(at: stage) }
            catch { throw UpdatePreflightError("preflight_cleanup_failed_after_\(primary)") }
            throw error
        }
        try FileManager.default.removeItem(at: stage)
    }

    private static func resetStage(_ stage: URL) throws {
        var info = stat()
        if lstat(stage.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o077 == 0 else { throw UpdatePreflightError("untrusted_update_staging") }
            try FileManager.default.removeItem(at: stage)
        } else if errno != ENOENT { throw UpdatePreflightError("update_staging_unreadable") }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    static func authenticate(_ archive: URL, candidate: UpdateCandidate) throws {
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard bytes.count == candidate.length, bytes.count <= UpdatePreflightLimits.archiveBytes,
              let signature = Data(base64Encoded: candidate.signature), signature.count == 64,
              let keyBytes = Data(base64Encoded: candidate.publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              key.isValidSignature(signature, for: bytes) else {
            throw UpdatePreflightError("update_signature_or_length_invalid")
        }
    }

    private func command(_ executable: String, _ args: [String]) throws -> String {
        let result = try run(executable, args)
        guard result.exitCode == 0 else { throw UpdatePreflightError("preflight_command_failed_\(URL(fileURLWithPath: executable).lastPathComponent)") }
        return result.standardOutput
    }

    private func validate(_ archive: URL, in stage: URL, candidate: UpdateCandidate) throws {
        try Self.validateArchiveSummary(command("/usr/bin/unzip", ["-Z", "-t", archive.path]))
        let extracted = stage.appendingPathComponent("extracted")
        _ = try command("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let app = extracted.appendingPathComponent(candidate.host.lastPathComponent)
        guard let bundle = Bundle(url: app), let host = Bundle(url: candidate.host),
              bundle.bundleIdentifier == host.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == candidate.version,
              let executable = bundle.executableURL,
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else {
            throw UpdatePreflightError("candidate_bundle_mismatch")
        }
        let currentOS = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"
        guard minimum.compare(os, options: .numeric) != .orderedDescending else {
            throw UpdatePreflightError("candidate_requires_newer_macos")
        }
        let architectures = try command("/usr/bin/lipo", ["-archs", executable.path]).split(whereSeparator: \.isWhitespace)
        guard architectures.contains("arm64") else { throw UpdatePreflightError("candidate_missing_arm64") }
        guard FileManager.default.isWritableFile(atPath: candidate.host.path),
              FileManager.default.isWritableFile(atPath: candidate.host.deletingLastPathComponent().path) else {
            throw UpdatePreflightError("update_destination_unwritable")
        }
        let usesHelper = bundle.bundleIdentifier == "io.github.srps.Conduit"
        try Self.validateSignature(app, helperPolicy: usesHelper ? HelperCallerPolicyFile.load() : .unenforced)
        // Execute only authenticated, statically verified code. Its early
        // worker dispatch performs one read-only ping before app composition.
        if usesHelper {
            guard bundle.object(forInfoDictionaryKey: "ConduitUpdatePreflightVersion") as? Int == 1 else {
                throw UpdatePreflightError("candidate_has_no_helper_preflight")
            }
            let result = try run(executable.path, [UpdateHelperPreflightWorker.argument])
            guard result.exitCode == 0 else {
                throw UpdatePreflightError(UpdateHelperPreflightWorker.failureReason(exitCode: result.exitCode))
            }
        }
    }

    static func validateArchiveSummary(_ summary: String) throws {
        let fields = summary.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 5, fields[1] == "files,", fields[3] == "bytes", fields[4] == "uncompressed,",
              let entries = Int(fields[0]), (1...UpdatePreflightLimits.archiveEntries).contains(entries),
              let expanded = UInt64(fields[2]), expanded <= UpdatePreflightLimits.expandedBytes else {
            throw UpdatePreflightError("update_expansion_limit")
        }
    }

    static func validateSignature(_ app: URL, helperPolicy: HelperCallerPolicy) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw UpdatePreflightError("candidate_code_signature_invalid")
        }
        // The worker verifies actual in-memory helper admission. Also check
        // the root-owned on-disk policy, conservatively refusing a bad pin.
        switch helperPolicy {
        case .unenforced: return
        case .untrusted: throw UpdatePreflightError("helper_policy_untrusted")
        case .enforced(let text):
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                throw UpdatePreflightError("helper_rejects_candidate_identity")
            }
        }
    }
}

/// Candidate-side read-only helper check, dispatched before composing the
/// app. No proxy, DNS, credential, login-item, installer or fallback calls.
package enum UpdateHelperPreflightWorker {
    package static let argument = "--conduit-update-helper-preflight"
    package static func run(arguments: [String], status: () -> HelperToolPrivilegeClient.Status = {
        HelperToolPrivilegeClient(transactionMilliseconds: 3_000).status
    }) -> Int32? {
        guard arguments.contains(argument) else { return nil }
        guard arguments == [argument] else { return 64 }
        switch status() {
        case .notInstalled, .installed: return 0
        case .notResponding: return 69
        case .outdated: return 70
        case .unauthorized: return 71
        case .waitingForConsoleUser: return 72
        case .callerNotAccepted: return 73
        // Inconclusive, so it proves no admission either: still a refusal,
        // with a reason that says to try again rather than to repair.
        case .busy: return 74
        }
    }

    package static func failureReason(exitCode: Int32) -> String {
        switch exitCode {
        case 69: return "helper_not_responding"
        case 70: return "helper_protocol_incompatible"
        case 71: return "helper_caller_unauthorized"
        case 72: return "helper_no_console_user"
        case 73: return "helper_rejects_candidate_identity"
        case 74: return "helper_busy"
        default: return "candidate_helper_preflight_failed"
        }
    }
}
