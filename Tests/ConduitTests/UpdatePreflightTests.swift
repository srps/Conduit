// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import XCTest
import Security
@testable import ConduitShared
@testable import PlatformMac

final class UpdatePreflightTests: XCTestCase {
    func testAnAuthenticCandidateStillMustMatchTheHelpersRequirement() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        var code: SecStaticCode?
        var requirement: SecRequirement?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &code), errSecSuccess)
        let actualCode = try XCTUnwrap(code)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(actualCode, [], &requirement), errSecSuccess)
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        try SystemUpdatePreflight.validateSignature(executable, helperPolicy: .enforced(requirement: try XCTUnwrap(text) as String))
        XCTAssertThrowsError(try SystemUpdatePreflight.validateSignature(executable,
            helperPolicy: .enforced(requirement: "identifier \"io.github.srps.never-admitted\""))) { error in
                XCTAssertEqual((error as? UpdatePreflightError)?.reason, "helper_rejects_candidate_identity")
            }
        XCTAssertThrowsError(try SystemUpdatePreflight.validateSignature(executable,
            helperPolicy: .untrusted(reason: "writable pin"))) { error in
                XCTAssertEqual((error as? UpdatePreflightError)?.reason, "helper_policy_untrusted")
            }
    }
    func testAuthenticationRejectsTamperingAndLengthMismatchBeforeExtraction() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try! FileManager.default.removeItem(at: file) }
        let bytes = Data("signed archive".utf8)
        try bytes.write(to: file)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: bytes).base64EncodedString()
        func candidate(_ length: UInt64, _ signature: String) -> UpdateCandidate {
            UpdateCandidate(archive: URL(string: "https://example.invalid/update.zip")!, version: "0.5.3", length: length,
                            signature: signature, publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                            host: URL(fileURLWithPath: "/tmp/Conduit.app"))
        }
        try SystemUpdatePreflight.authenticate(file, candidate: candidate(UInt64(bytes.count), signature))
        XCTAssertThrowsError(try SystemUpdatePreflight.authenticate(file, candidate: candidate(UInt64(bytes.count + 1), signature)))
        XCTAssertThrowsError(try SystemUpdatePreflight.authenticate(file, candidate: candidate(UInt64(bytes.count), "invalid")))
        try Data("tampered bytes".utf8).write(to: file)
        XCTAssertThrowsError(try SystemUpdatePreflight.authenticate(file, candidate: candidate(UInt64(bytes.count), signature)))
    }

    func testExpansionLimitsRefuseOversizedAndMalformedArchives() throws {
        try SystemUpdatePreflight.validateArchiveSummary("413 files, 50169732 bytes uncompressed, 15016568 bytes compressed: 70.1%")
        for summary in ["0 files, 0 bytes uncompressed,", "16385 files, 10 bytes uncompressed,",
                        "1 files, 1073741825 bytes uncompressed,", "unknown", "1 files, -1 bytes uncompressed,"] {
            XCTAssertThrowsError(try SystemUpdatePreflight.validateArchiveSummary(summary), summary)
        }
    }

    func testHelperWorkerCannotStartTheAppOrUsePrivilegeFallback() {
        var calls = 0
        XCTAssertNil(UpdateHelperPreflightWorker.run(arguments: []) { calls += 1; return .installed })
        for args in [[UpdateHelperPreflightWorker.argument, "--dev"], ["--dev", UpdateHelperPreflightWorker.argument]] {
            XCTAssertEqual(UpdateHelperPreflightWorker.run(arguments: args) { calls += 1; return .installed }, 64)
        }
        XCTAssertEqual(calls, 0)
        for status: HelperToolPrivilegeClient.Status in [.installed, .notInstalled] {
            XCTAssertEqual(UpdateHelperPreflightWorker.run(arguments: [UpdateHelperPreflightWorker.argument]) { status }, 0)
        }
        let failures: [(HelperToolPrivilegeClient.Status, Int32)] = [(.notResponding, 69), (.outdated, 70),
            (.unauthorized, 71), (.waitingForConsoleUser, 72), (.callerNotAccepted(message: "pin mismatch"), 73), (.busy, 74)]
        for (status, code) in failures {
            XCTAssertEqual(UpdateHelperPreflightWorker.run(arguments: [UpdateHelperPreflightWorker.argument]) { status }, code)
        }
    }

    /// A busy helper proves no admission, so the install is still refused,
    /// but as something to try again, not a broken helper (#197).
    func testABusyHelperRefusesTheUpdateAsBusyNotBroken() {
        XCTAssertEqual(UpdateHelperPreflightWorker.failureReason(exitCode: 74), "helper_busy")
        XCTAssertEqual(UpdateHelperPreflightWorker.failureReason(exitCode: 69), "helper_not_responding")
    }

    func testProductionURLPolicyPreservesTLSAndRejectsCredentialBearingURLs() {
        XCTAssertTrue(UpdateArchiveDownload.allowed(URL(string: "https://example.com/release.zip")!))
        for url in ["file:///tmp/release.zip", "http://example.com/release.zip", "https://user:secret@example.com/release.zip"] {
            XCTAssertFalse(UpdateArchiveDownload.allowed(URL(string: url)!))
        }
    }
}
