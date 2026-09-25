// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Security
import XCTest
@testable import ConduitShared

/// #46: the helper admits a peer only if it is the console user *and*, once
/// `install-helper.sh` has pinned one, the program the pin names.
final class HelperCallerIdentityTests: XCTestCase {

    // MARK: - The decision

    private let pinned = HelperCallerIdentity(
        pid: 42, signingIdentifier: "io.github.srps.Conduit", cdhashPrefix: "abcdef012345",
        hardenedRuntime: true, satisfiesRequirement: true
    )

    func testEnforcedAdmitsAPinnedProgramUnderTheHardenedRuntime() {
        XCTAssertEqual(HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: pinned), .verified)
    }

    func testEnforcedRefusesAProgramThePinDoesNotName() {
        var stranger = pinned
        stranger.signingIdentifier = "a.out"
        stranger.satisfiesRequirement = false
        guard case .refused(let message) = HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: stranger) else {
            return XCTFail("a program outside the pin was admitted")
        }
        XCTAssertTrue(message.contains("'a.out'"), message)
        XCTAssertTrue(message.contains("install-helper.sh"), "the refusal must say how to fix it: \(message)")
    }

    func testEnforcedRefusesAPinnedProgramWithoutTheHardenedRuntime() {
        var injectable = pinned
        injectable.hardenedRuntime = false
        guard case .refused(let message) = HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: injectable) else {
            return XCTFail("a program open to DYLD_INSERT_LIBRARIES was admitted")
        }
        XCTAssertTrue(message.contains("hardened runtime"), message)
    }

    func testEnforcedRefusesWhenTheIdentityCannotBeRead() {
        let unknown = HelperCallerIdentity(readFailure: "LOCAL_PEERTOKEN: Bad file descriptor")
        XCTAssertNotEqual(HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: unknown), .verified)
        guard case .refused = HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: unknown) else {
            return XCTFail("an unidentifiable peer was admitted under an enforced pin")
        }
    }

    func testEnforcedRefusesAnIdentityWhoseRequirementWasNeverChecked() {
        var unchecked = pinned
        unchecked.satisfiesRequirement = nil
        guard case .refused = HelperAdmission.callerVerdict(policy: .enforced(requirement: "x"), identity: unchecked) else {
            return XCTFail("only a positive check admits")
        }
    }

    func testUnenforcedLeavesTheVerdictToTheConsoleUID() {
        let stranger = HelperCallerIdentity(signingIdentifier: "a.out", satisfiesRequirement: nil)
        XCTAssertEqual(HelperAdmission.callerVerdict(policy: .unenforced, identity: stranger), .unenforced)
        XCTAssertEqual(HelperAdmission.callerVerdict(policy: .unenforced, identity: HelperCallerIdentity(readFailure: "x")), .unenforced)
    }

    func testAnUntrustedPinRefusesEvenThePinnedProgram() {
        guard case .refused(let message) = HelperAdmission.callerVerdict(policy: .untrusted(reason: "mode 666"), identity: pinned) else {
            return XCTFail("a tampered pin must not admit anyone")
        }
        XCTAssertTrue(message.contains("mode 666") && message.contains("install-helper.sh"), message)
    }

    // MARK: - The requirement file

    private func scratchDirectory() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        chmod(base.path, 0o755)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.path
    }

    private func writePin(_ text: String, in directory: String, mode: mode_t = 0o644) -> String {
        let path = directory + "/helper-callers.req"
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        chmod(path, mode)
        return path
    }

    private var me: uid_t { getuid() }

    func testNoDirectoryIsUnenforced() throws {
        let dir = try scratchDirectory()
        XCTAssertEqual(HelperCallerPolicyFile.load(path: dir + "/absent/helper-callers.req", requiredOwner: me), .unenforced)
    }

    func testASoundDirectoryWithNoPinIsUnenforced() throws {
        let dir = try scratchDirectory()
        XCTAssertEqual(HelperCallerPolicyFile.load(path: dir + "/helper-callers.req", requiredOwner: me), .unenforced)
    }

    func testASoundPinIsEnforcedAndTrimmed() throws {
        let dir = try scratchDirectory()
        let path = writePin("identifier \"x\"\n", in: dir)
        XCTAssertEqual(HelperCallerPolicyFile.load(path: path, requiredOwner: me), .enforced(requirement: "identifier \"x\""))
    }

    func testAPinSomeoneElseOwnsIsUntrusted() throws {
        let dir = try scratchDirectory()
        let path = writePin("identifier \"x\"", in: dir)
        // The test runs as a user; the production owner is root.
        guard case .untrusted = HelperCallerPolicyFile.load(path: path, requiredOwner: 0) else {
            return XCTFail("a pin the user owns is one the user could have written")
        }
    }

    func testAWritablePinIsUntrusted() throws {
        let dir = try scratchDirectory()
        for mode: mode_t in [0o664, 0o646, 0o666] {
            let path = writePin("identifier \"x\"", in: dir, mode: mode)
            guard case .untrusted(let reason) = HelperCallerPolicyFile.load(path: path, requiredOwner: me) else {
                return XCTFail("mode \(String(mode, radix: 8)) was trusted")
            }
            XCTAssertTrue(reason.contains("writable"), reason)
        }
    }

    func testAWritableDirectoryIsUntrustedEvenWithNoPinInIt() throws {
        let dir = try scratchDirectory()
        chmod(dir, 0o777)
        // Anyone could have deleted the pin from it: that must not read as
        // "never enforced".
        guard case .untrusted = HelperCallerPolicyFile.load(path: dir + "/helper-callers.req", requiredOwner: me) else {
            return XCTFail("a writable directory with no pin read as unenforced")
        }
    }

    func testASymlinkedPinIsUntrusted() throws {
        let dir = try scratchDirectory()
        let real = writePin("identifier \"x\"", in: dir)
        let link = dir + "/link.req"
        XCTAssertEqual(symlink(real, link), 0)
        guard case .untrusted(let reason) = HelperCallerPolicyFile.load(path: link, requiredOwner: me) else {
            return XCTFail("a symlink was followed")
        }
        XCTAssertTrue(reason.contains("symbolic link"), reason)
    }

    func testAnEmptyOrOversizedPinIsUntrusted() throws {
        let dir = try scratchDirectory()
        var path = writePin("  \n", in: dir)
        guard case .untrusted = HelperCallerPolicyFile.load(path: path, requiredOwner: me) else {
            return XCTFail("an empty pin was trusted")
        }
        path = writePin(String(repeating: "a", count: HelperCallerPolicyFile.maxBytes + 1), in: dir)
        guard case .untrusted = HelperCallerPolicyFile.load(path: path, requiredOwner: me) else {
            return XCTFail("an oversized pin was trusted")
        }
    }

    // MARK: - The Security framework, against this process

    private func connectedPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let (a, b) = (fds[0], fds[1])
        addTeardownBlock { close(a); close(b) }
        return (a, b)
    }

    func testLocalPeerTokenNamesThePeerProcess() throws {
        let (a, _) = try connectedPair()
        let token = try SecCodeCallerIdentifier.peerAuditToken(fd: a).get()
        XCTAssertEqual(pid_t(bitPattern: token.val.5), getpid())
        XCTAssertEqual(token.val.1, geteuid())
    }

    func testLocalPeerTokenFailsOnANonSocket() {
        guard case .failure = SecCodeCallerIdentifier.peerAuditToken(fd: -1) else {
            return XCTFail("no token can come from no socket")
        }
    }

    /// The test runner's own designated requirement: the process is its peer
    /// on a socketpair, so what the helper would compute for a caller it
    /// computes here for us.
    private func ownDesignatedRequirement() throws -> String {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else {
            throw XCTSkip("SecCodeCopySelf failed; this runner has no code identity to test against")
        }
        var requirement: SecRequirement?
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else {
            throw XCTSkip("the test runner is unsigned, so it has no designated requirement to check against")
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw XCTSkip("the runner's designated requirement has no text form")
        }
        return text as String
    }

    func testTheRealCheckAdmitsThisProcessAgainstItsOwnRequirement() throws {
        let requirement = try ownDesignatedRequirement()
        let (a, _) = try connectedPair()
        let identity = try SecCodeCallerIdentifier(requirementText: requirement).identify(fd: a)
        XCTAssertNil(identity.readFailure)
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertNotNil(identity.signingIdentifier)
        XCTAssertEqual(identity.cdhashPrefix?.count, 12)
        XCTAssertEqual(identity.satisfiesRequirement, true, "rejected against its own designated requirement: \(requirement)")
    }

    func testTheRealCheckRejectsThisProcessAgainstAnUnrelatedPin() throws {
        _ = try ownDesignatedRequirement()
        let (a, _) = try connectedPair()
        // The shape install-helper.sh writes, for a certificate nobody has.
        let pin = #"certificate leaf = H"0123456789abcdef0123456789abcdef01234567" and (identifier "io.github.srps.Conduit" or identifier "io.github.srps.Conduit.Daemon")"#
        let identity = try SecCodeCallerIdentifier(requirementText: pin).identify(fd: a)
        XCTAssertNil(identity.readFailure)
        XCTAssertEqual(identity.satisfiesRequirement, false)
        guard case .refused = HelperAdmission.callerVerdict(policy: .enforced(requirement: pin), identity: identity) else {
            return XCTFail("an unpinned same-uid process was admitted")
        }
    }

    /// The threat itself: another program of the same user dials the socket.
    /// `nc` stands in for it; the helper must see `nc`, not whoever spawned it,
    /// and an Apple-anchored requirement for `nc` must hold where the pin does not.
    func testAnotherSameUIDProgramIsIdentifiedFromTheConnection() throws {
        let path = "/tmp/pm-cid-\(getpid()).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server); unlink(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { src in buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(buf.count))) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        XCTAssertEqual(listen(server, 1), 0)

        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", path]
        let stdin = Pipe()
        nc.standardInput = stdin
        nc.standardOutput = FileHandle.nullDevice
        try nc.run()
        defer { try? stdin.fileHandleForWriting.close(); nc.terminate(); nc.waitUntilExit() }

        let client = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }

        let ncRequirement = #"anchor apple and identifier "com.apple.nc""#
        let asNC = try SecCodeCallerIdentifier(requirementText: ncRequirement).identify(fd: client)
        XCTAssertNil(asNC.readFailure)
        XCTAssertEqual(asNC.pid, nc.processIdentifier)
        XCTAssertEqual(asNC.signingIdentifier, "com.apple.nc")
        XCTAssertEqual(asNC.satisfiesRequirement, true)

        let pin = #"certificate leaf = H"0123456789abcdef0123456789abcdef01234567" and identifier "io.github.srps.Conduit""#
        let asPinned = try SecCodeCallerIdentifier(requirementText: pin).identify(fd: client)
        XCTAssertEqual(asPinned.satisfiesRequirement, false)
        guard case .refused = HelperAdmission.callerVerdict(policy: .enforced(requirement: pin), identity: asPinned) else {
            return XCTFail("a same-uid program outside the pin was admitted")
        }
    }

    func testWithoutARequirementTheRealCheckOnlyIdentifies() throws {
        let (a, _) = try connectedPair()
        let identity = try SecCodeCallerIdentifier(requirementText: nil).identify(fd: a)
        XCTAssertNil(identity.satisfiesRequirement)
        XCTAssertEqual(identity.pid, getpid())
    }

    func testARequirementThatDoesNotCompileIsAnError() {
        XCTAssertThrowsError(try SecCodeCallerIdentifier(requirementText: "certificate leaf = ((("))
    }
}
