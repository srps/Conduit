// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation
import Security

/// #46 end to end, minus root: a pin file, a Unix socket, real peers, and the
/// Security framework, deciding the way the helper's accept loop does.
/// The pin is owned by this user rather than root, and says so to the loader.
enum HelperCallerIdentityScenarios {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let directory = "/tmp/pm-sim-pin-\(getpid())"
        let socketPath = directory + "/h.sock"
        let pinPath = directory + "/helper-callers.req"
        if FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.removeItem(atPath: directory)
        }
        guard mkdir(directory, 0o755) == 0 else { throw Failure(description: "mkdir \(directory): \(String(cString: strerror(errno)))") }
        defer { removeScratch(directory) }

        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let me = getuid()

        // Unenforced: no pin, so another program of this user is identified
        // for the audit line and not refused for it.
        check("no pin is unenforced", HelperCallerPolicyFile.load(path: pinPath, requiredOwner: me) == .unenforced)
        try withListener(at: socketPath) { accept in
            let peer = try connectNC(to: socketPath)
            defer { peer.stop() }
            let fd = try accept()
            defer { close(fd) }
            let identity = try SecCodeCallerIdentifier(requirementText: nil).identify(fd: fd)
            check("unenforced: nc is identified as itself", identity.signingIdentifier == "com.apple.nc" && identity.pid == peer.pid)
            check("unenforced: identity does not refuse", HelperAdmission.callerVerdict(policy: .unenforced, identity: identity) == .unenforced)
        }

        // Enforced on this process's own designated requirement.
        let pin = try ownDesignatedRequirement()
        FileManager.default.createFile(atPath: pinPath, contents: Data((pin + "\n").utf8))
        chmod(pinPath, 0o644)
        let policy = HelperCallerPolicyFile.load(path: pinPath, requiredOwner: me)
        check("a sound pin is enforced", policy == .enforced(requirement: pin))
        let identifier = try SecCodeCallerIdentifier(requirementText: pin)

        try withListener(at: socketPath) { accept in
            let peer = try connectNC(to: socketPath)
            defer { peer.stop() }
            let fd = try accept()
            defer { close(fd) }
            let identity = identifier.identify(fd: fd)
            check("enforced: another same-uid program fails the pin", identity.satisfiesRequirement == false)
            if case .refused = HelperAdmission.callerVerdict(policy: policy, identity: identity) {
                check("enforced: another same-uid program is refused", true)
            } else {
                check("enforced: another same-uid program is refused", false)
            }
        }

        try withListener(at: socketPath) { accept in
            let client = try connectSelf(to: socketPath)
            defer { close(client) }
            let fd = try accept()
            defer { close(fd) }
            let identity = identifier.identify(fd: fd)
            check("enforced: the pinned program satisfies the pin", identity.satisfiesRequirement == true && identity.pid == getpid())
            // SwiftPM links pm-sim without the hardened runtime, so it is the
            // genuine program anyone could inject into: refused all the same.
            let verdict = HelperAdmission.callerVerdict(policy: policy, identity: identity)
            if identity.hardenedRuntime {
                check("enforced: the pinned program under the hardened runtime is verified", verdict == .verified)
            } else if case .refused(let message) = verdict {
                check("enforced: the pinned program without the hardened runtime is refused", message.contains("hardened runtime"))
            } else {
                check("enforced: the pinned program without the hardened runtime is refused", false)
            }
        }

        // Tampered: a pin anyone could have rewritten refuses even the pinned program.
        chmod(pinPath, 0o666)
        let tampered = HelperCallerPolicyFile.load(path: pinPath, requiredOwner: me)
        if case .untrusted = tampered,
           case .refused = HelperAdmission.callerVerdict(policy: tampered, identity: HelperCallerIdentity(satisfiesRequirement: true)) {
            check("a writable pin refuses everyone", true)
        } else {
            check("a writable pin refuses everyone", false)
        }

        let passed = assertions.allSatisfy(\.passed)
        return ScenarioResult(
            name: "helper-caller-identity", clientCount: 3, clientsOpened: 3, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions,
            notes: [passed
                ? "PASS: peers identified from LOCAL_PEERTOKEN; unenforced admits, the pin refuses a stranger and an injectable build, a writable pin refuses all"
                : "FAIL: see assertions"]
        )
    }

    // MARK: - Plumbing

    /// Cleanup cannot throw from a `defer`; a leftover is reported, not hidden.
    private static func removeScratch(_ directory: String) {
        do {
            try FileManager.default.removeItem(atPath: directory)
        } catch {
            fputs("helper-caller-identity: could not remove \(directory): \(error)\n", stderr)
        }
    }

    private static func ownDesignatedRequirement() throws -> String {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw Failure(description: "pm-sim has no designated requirement to pin")
        }
        return text as String
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count))) }
        }
        return addr
    }

    private static func withListener(at path: String, _ body: (() throws -> Int32) throws -> Void) throws {
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        defer { close(server); unlink(path) }
        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else { throw Failure(description: "listen \(path): \(String(cString: strerror(errno)))") }
        try body {
            let fd = accept(server, nil, nil)
            guard fd >= 0 else { throw Failure(description: "accept: \(String(cString: strerror(errno)))") }
            return fd
        }
    }

    private static func connectSelf(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, rc == 0 else { throw Failure(description: "connect \(path): \(String(cString: strerror(errno)))") }
        return fd
    }

    private final class Child {
        let process: Process
        let stdin: Pipe
        var pid: pid_t { process.processIdentifier }
        init(process: Process, stdin: Pipe) { self.process = process; self.stdin = stdin }
        func stop() {
            do {
                try stdin.fileHandleForWriting.close()
            } catch {
                fputs("helper-caller-identity: closing nc's stdin: \(error)\n", stderr)
            }
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Another program of this user dialling the socket.
    private static func connectNC(to path: String) throws -> Child {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return Child(process: process, stdin: stdin)
    }
}
