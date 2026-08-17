// SPDX-License-Identifier: Apache-2.0
// Concrete `PrivilegeClient` implementations. Both classes
// call `CommandRunner.runPrivilegedShellScript(...)` / `CommandRunner.run(...)`,
// which is the reason the file lives in `PlatformMac` (STYLE: only
// PlatformMac is allowed to shell out via `Process`).

import Foundation
import ProxyKernel
import ConduitShared

/// Uses osascript "do shell script ... with administrator privileges" for elevation.
/// Maps each typed privileged operation to the equivalent networksetup / filesystem operation.
package final class AppleScriptPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    /// How the rendered script is actually run. Injectable only so the
    /// exit-code handling below is testable: the real implementation raises an
    /// admin password prompt, which no test may do.
    private let runner: @Sendable (String) throws -> CommandResult

    package init(
        runner: @escaping @Sendable (String) throws -> CommandResult = { script in
            try CommandRunner.runPrivilegedShellScript(script)
        }
    ) {
        self.runner = runner
    }

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        let script = try shellScript(for: operation, values: values)
        try runPrivileged(Self.abortOnFirstFailure(script))
    }

    /// One prompt for the whole batch. Every step is still rendered through
    /// `shellScript(for:values:)`, so the same argument validation applies —
    /// this only changes how many times the user is asked.
    package func execute(batch: [PrivilegedBatchStep]) throws {
        guard !batch.isEmpty else { return }
        try runPrivileged(Self.abortOnFirstFailure(batchScript(for: batch)))
    }

    func runPrivilegedScript(_ script: String) throws {
        try runPrivileged(script)
    }

    /// `sh` reports only the *last* command's status, and every script rendered
    /// here is several `networksetup` calls. Without this a restore whose
    /// endpoint write failed but whose trailing state write succeeded came back
    /// as exit 0 — the same hole `SystemProxyManager.write` closes on the
    /// unprivileged path. Every write is an absolute set, so aborting early and
    /// retrying the whole sequence is safe.
    ///
    /// Not applied to `runPrivilegedScript`: the installer scripts carry their
    /// own `|| true` guards for steps that are expected to fail.
    private static func abortOnFirstFailure(_ script: String) -> String {
        "set -e\n" + script
    }

    /// The one place the privileged result is inspected.
    ///
    /// A script that failed — or a user who dismissed the password dialog, which
    /// `osascript` reports as exit 1 with `User canceled. (-128)` — comes back as
    /// an ordinary `CommandResult` rather than a thrown error. Discarding it made
    /// a cancelled prompt indistinguishable from a completed restore, so
    /// `SystemProxyManager.clear` went on to `forgetAll` the only copy of the
    /// user's previous proxy settings.
    ///
    /// `CommandRunner.runPrivilegedShellScript` throws for launch failure and
    /// also for its own bounds — `timedOut` at 600s, `outputTooLarge`,
    /// `outputIncomplete`. Those are not `PrivilegeClientError`s, so they
    /// propagate as-is; nothing branches on the concrete type, and every caller
    /// treats any throw from here as "the write did not land", which is the
    /// answer that keeps the journal records. Do not narrow that to a type check
    /// without re-reading `SystemProxyManager.write`.
    private func runPrivileged(_ script: String) throws {
        let result = try runner(script)
        guard result.exitCode != 0 else { return }
        let output = [result.standardError, result.standardOutput]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        throw PrivilegeClientError.executionFailed(
            "Privileged script failed (exit \(result.exitCode)): \(output.isEmpty ? "no output" : output)"
        )
    }

    /// Internal rather than private so tests can assert on what these render
    /// to. The ordering inside them is the contract, and it cannot otherwise be
    /// observed without prompting a human for a password.
    func batchScript(for batch: [PrivilegedBatchStep]) throws -> String {
        try batch
            .map { try shellScript(for: $0.operation, values: $0.values) }
            .joined(separator: "\n")
    }

    func shellScript(for operation: PrivilegedOperation, values: [String]) throws -> String {
        switch operation {
        case .applyDNS:
            guard values.count >= 2 else { throw PrivilegeClientError.executionFailed("applyDNS requires domain and servers") }
            let domain = values[0].shellQuoted
            var content = values[1].split(separator: ",").map { "nameserver \($0)" }.joined(separator: "\n")
            if values.count >= 3, let port = Int(values[2]), port >= 1, port <= 65535 {
                content += "\nport \(port)"
            }
            return "mkdir -p /etc/resolver && cat > /etc/resolver/\(domain) <<'EOF'\n\(content)\nEOF"
        case .removeDNS:
            guard let domain = values.first else { throw PrivilegeClientError.executionFailed("removeDNS requires domain") }
            return "rm -f /etc/resolver/\(domain.shellQuoted)"
        case .applySystemProxy:
            guard values.count >= 3 else { throw PrivilegeClientError.executionFailed("applySystemProxy requires service, host, port") }
            guard HelperInputValidator.validateServiceName(values[0]) else { throw PrivilegeClientError.executionFailed("invalid service name") }
            guard HelperInputValidator.validateIPAddress(values[1]) || HelperInputValidator.validateDomain(values[1]) else { throw PrivilegeClientError.executionFailed("invalid host") }
            guard HelperInputValidator.validatePort(values[2]) else { throw PrivilegeClientError.executionFailed("invalid port") }
            let s = values[0].shellQuoted, h = values[1].shellQuoted, p = values[2]
            return """
            /usr/sbin/networksetup -setwebproxy \(s) \(h) \(p)
            /usr/sbin/networksetup -setsecurewebproxy \(s) \(h) \(p)
            /usr/sbin/networksetup -setwebproxystate \(s) on
            /usr/sbin/networksetup -setsecurewebproxystate \(s) on
            """
        case .clearSystemProxy:
            guard let service = values.first else { throw PrivilegeClientError.executionFailed("clearSystemProxy requires service") }
            let s = service.shellQuoted
            return """
            /usr/sbin/networksetup -setwebproxystate \(s) off
            /usr/sbin/networksetup -setsecurewebproxystate \(s) off
            /usr/sbin/networksetup -setautoproxystate \(s) off
            """
        case .setProxyBypass:
            guard values.count >= 2 else { throw PrivilegeClientError.executionFailed("setProxyBypass requires service and at least one domain or 'Empty'") }
            // The one bypass rule this renderer needs, and deliberately not the
            // helper's whole `validateProxyBypassEntry`. `shellQuoted` already
            // neutralises every metacharacter, so what survives it is the shape
            // quoting cannot help with: an entry that reaches `networksetup` as
            // argv looking like a flag. Applying the full entry regex here
            // instead would make the fallback reject captured lists the
            // unprivileged path restores today, which is a teardown failure
            // rather than a defence.
            guard !values.dropFirst().contains(where: { $0.hasPrefix("-") }) else {
                throw PrivilegeClientError.executionFailed("bypass domain must not look like a networksetup flag")
            }
            let s = values[0].shellQuoted
            let domains = values.dropFirst().map { $0.shellQuoted }.joined(separator: " ")
            return "/usr/sbin/networksetup -setproxybypassdomains \(s) \(domains)"
        case .setWebProxyEndpoint:
            guard values.count >= 5 else { throw PrivilegeClientError.executionFailed("setWebProxyEndpoint requires service, kind, host, port, state") }
            // Same rules the helper applies, for the same reason: this script
            // runs as root. `state` is the argument that matters most — it is
            // interpolated bare, because `networksetup` wants a literal
            // `on`/`off` and quoting it would be the only unquoted-looking
            // value in the file. Validating it is what makes that safe. The
            // helper-client path validated first and this one did not, so
            // `AppleScriptPrivilegeClient` — the default `privilegeClient` for
            // `SystemProxyManager` — was the unguarded way in.
            guard HelperInputValidator.validateServiceName(values[0]) else { throw PrivilegeClientError.executionFailed("invalid service name") }
            guard HelperInputValidator.validateWebProxyKind(values[1]) else { throw PrivilegeClientError.executionFailed("invalid web proxy kind") }
            guard HelperInputValidator.validateOptionalEndpoint(host: values[2], port: values[3]) else { throw PrivilegeClientError.executionFailed("invalid web proxy endpoint") }
            guard HelperInputValidator.validateProxyState(values[4]) else { throw PrivilegeClientError.executionFailed("invalid proxy state") }
            let s = values[0].shellQuoted
            let kind = values[1]
            let host = values[2], port = values[3], state = values[4]
            let setter = kind == "web" ? "-setwebproxy" : "-setsecurewebproxy"
            let stateSetter = kind == "web" ? "-setwebproxystate" : "-setsecurewebproxystate"
            var script = ""
            if HelperInputValidator.isEmptyListSentinel(host) {
                script += "/usr/sbin/networksetup \(setter) \(s) '' 0\n"
            } else if !host.isEmpty {
                script += "/usr/sbin/networksetup \(setter) \(s) \(host.shellQuoted) \(port.shellQuoted)\n"
            }
            // State last — `-setwebproxy` enables the proxy as a side effect.
            script += "/usr/sbin/networksetup \(stateSetter) \(s) \(state)"
            return script
        case .setAutoproxy:
            guard values.count >= 3 else { throw PrivilegeClientError.executionFailed("setAutoproxy requires service, url, state") }
            // As above: `state` reaches a root shell uninterpolated-safe only
            // because it is checked here. An empty URL is the "write only the
            // state" form, so it is the one value allowed to be absent.
            guard HelperInputValidator.validateServiceName(values[0]) else { throw PrivilegeClientError.executionFailed("invalid service name") }
            guard values[1].isEmpty || HelperInputValidator.validateAutoproxyURL(values[1]) else { throw PrivilegeClientError.executionFailed("invalid autoproxy URL") }
            guard HelperInputValidator.validateProxyState(values[2]) else { throw PrivilegeClientError.executionFailed("invalid proxy state") }
            let s = values[0].shellQuoted
            let url = values[1], state = values[2]
            var script = ""
            if !url.isEmpty {
                script += "/usr/sbin/networksetup -setautoproxyurl \(s) \(url.shellQuoted)\n"
            }
            // State last — `-setautoproxyurl` enables autoproxy as a side effect.
            script += "/usr/sbin/networksetup -setautoproxystate \(s) \(state)"
            return script
        case .setAutoproxyURL:
            guard values.count >= 2 else { throw PrivilegeClientError.executionFailed("setAutoproxyURL requires service and URL") }
            let s = values[0].shellQuoted, url = values[1].shellQuoted
            return """
            /usr/sbin/networksetup -setautoproxyurl \(s) \(url)
            /usr/sbin/networksetup -setautoproxystate \(s) on
            """
        case .disableAutoproxy:
            guard let service = values.first else { throw PrivilegeClientError.executionFailed("disableAutoproxy requires service") }
            return "/usr/sbin/networksetup -setautoproxystate \(service.shellQuoted) off"
        case .setDNSServers:
            guard values.count >= 2 else { throw PrivilegeClientError.executionFailed("setDNSServers requires service and servers") }
            let s = values[0].shellQuoted
            let servers = values.dropFirst().map { $0.shellQuoted }.joined(separator: " ")
            return "/usr/sbin/networksetup -setdnsservers \(s) \(servers)"
        case .startDNSRelay, .stopDNSRelay, .startTCPRelay, .stopTCPRelay:
            throw PrivilegeClientError.executionFailed("Relay commands require the privileged helper")
        case .ping:
            return "true"
        }
    }
}

/// Communicates with the installed LaunchDaemon helper via Unix domain socket.
/// Falls back to AppleScript when the helper is not installed or unreachable.
package final class HelperToolPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let fallback = AppleScriptPrivilegeClient()
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?

    /// - Parameter eventSink: notified when the helper cannot be reached and
    ///   the AppleScript fallback takes over. Optional only so the many
    ///   `HelperToolPrivilegeClient()` call sites in tests stay unchanged;
    ///   production hosts should pass one, because a silent degrade to an
    ///   admin prompt is exactly the kind of recovery `AGENTS.md` requires an
    ///   event for.
    package init(eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil) {
        self.eventSink = eventSink
    }

    package enum Status: Sendable, Equatable {
        case installed
        case outdated
        case notInstalled
        case notResponding
    }

    package var status: Status {
        guard FileManager.default.fileExists(atPath: HelperConstants.binaryInstallPath) else {
            return .notInstalled
        }
        guard let response = try? sendRequest(HelperRequest(command: .ping, values: [])) else {
            return .notResponding
        }
        guard response.protocolVersion == HelperProtocolVersion.current else {
            return .outdated
        }
        return response.success ? .installed : .notResponding
    }

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    package func execute(batch: [PrivilegedBatchStep]) throws {
        guard !batch.isEmpty else { return }
        // Validate the whole batch before running any of it: a step rejected
        // halfway through would leave the surface in a state no caller asked
        // for, and the fallback would then re-run the steps that already
        // landed.
        let commands = batch.map { (HelperCommand($0.operation), $0.values) }
        for (command, values) in commands {
            try validate(command: command, values: values)
        }

        for (index, (command, values)) in commands.enumerated() {
            do {
                let response = try sendRequest(HelperRequest(command: command, values: values))
                guard response.protocolVersion == HelperProtocolVersion.current else {
                    throw PrivilegeClientError.communicationFailed(
                        "Helper speaks protocol \(response.protocolVersion), this build speaks \(HelperProtocolVersion.current)."
                    )
                }
                guard response.success else {
                    // The helper ran the command and it failed. Re-running the
                    // same command through osascript would raise an admin
                    // prompt only to fail identically, so this is a real
                    // error, not a reachability problem.
                    throw PrivilegeClientError.executionFailed(response.errorMessage ?? "Command failed")
                }
            } catch {
                // One catch, deliberately, and not two. There used to be a
                // `catch let error as PrivilegeClientError` here and a bare
                // `catch` below it that degraded just the same with no event —
                // so a helper whose reply could not be decoded raised an admin
                // password prompt with nothing in the event stream saying why,
                // against `AGENTS.md`'s rule that recovery carries a structured
                // event explaining how. Merging them makes the event a property
                // of the structure rather than of remembering to add it twice.
                //
                // The helper having *run* the command and reported it failed is
                // the one thing that is not a reachability problem: re-running
                // it through osascript would raise a prompt only to fail
                // identically. Everything else — cannot connect, cannot
                // understand the reply — is worth retrying by another route.
                if let clientError = error as? PrivilegeClientError, !clientError.isHelperUnreachable {
                    throw clientError
                }
                // The documented fallback, which until now was unreachable:
                // `sendRequest` throws `helperNotInstalled` on a failed connect
                // and `communicationFailed` on a version mismatch, and both
                // were rethrown by a `catch let error as PrivilegeClientError`
                // placed ahead of the fallback. So a machine with no helper —
                // or one running a helper from before a protocol bump — failed
                // every privileged operation outright instead of asking for an
                // admin password. On a machine that cannot write proxy
                // settings unprivileged that meant teardown cleared nothing.
                eventSink?(
                    RuntimeEvent(
                        kind: .auth,
                        event: "auth.privilege_helper_degraded",
                        detail: "command=\(command.rawValue) reason=\(error.displayDescription) fallback=applescript"
                    )
                )
                // Everything from here on goes through one prompt, including
                // the step that just failed.
                try fallback.execute(batch: Array(batch[index...]))
                return
            }
        }
    }

    package func ping() -> Bool {
        guard let response = try? sendRequest(HelperRequest(command: .ping, values: [])) else {
            return false
        }
        return response.success && response.protocolVersion == HelperProtocolVersion.current
    }

    package func sendCommand(_ command: HelperCommand, values: [String]) -> Bool {
        guard (try? validate(command: command, values: values)) != nil else {
            return false
        }
        guard let response = try? sendRequest(HelperRequest(command: command, values: values)) else {
            return false
        }
        return response.success
    }

    private func validate(command: HelperCommand, values: [String]) throws {
        switch command {
        case .ping, .stopDNSRelay, .stopTCPRelay:
            return
        case .startDNSRelay:
            guard values.count == 1, HelperInputValidator.validatePort(values[0]) else {
                throw PrivilegeClientError.executionFailed("invalid DNS relay target port")
            }
        case .startTCPRelay:
            guard values.count >= 2,
                  HelperInputValidator.validatePort(values[0]),
                  HelperInputValidator.validatePort(values[1]) else {
                throw PrivilegeClientError.executionFailed("invalid TCP relay listen/target port")
            }
            if values.count >= 3, !HelperInputValidator.validateRelayBindHost(values[2]) {
                throw PrivilegeClientError.executionFailed("invalid TCP relay bind host")
            }
        case .applyDNS:
            guard values.count >= 2, HelperInputValidator.validateDomain(values[0]) else {
                throw PrivilegeClientError.executionFailed("invalid DNS resolver domain")
            }
            let servers = values[1].split(separator: ",").map(String.init)
            guard !servers.isEmpty, servers.allSatisfy(HelperInputValidator.validateIPAddress) else {
                throw PrivilegeClientError.executionFailed("invalid DNS resolver server")
            }
            if values.count >= 3, !HelperInputValidator.validatePort(values[2]) {
                throw PrivilegeClientError.executionFailed("invalid DNS resolver port")
            }
        case .removeDNS:
            guard let domain = values.first, HelperInputValidator.validateDomain(domain) else {
                throw PrivilegeClientError.executionFailed("invalid DNS resolver domain")
            }
        case .applySystemProxy:
            guard values.count >= 3,
                  HelperInputValidator.validateServiceName(values[0]),
                  HelperInputValidator.validateIPAddress(values[1]) || HelperInputValidator.validateDomain(values[1]),
                  HelperInputValidator.validatePort(values[2]) else {
                throw PrivilegeClientError.executionFailed("invalid system proxy service, host, or port")
            }
        case .clearSystemProxy, .disableAutoproxy:
            guard let service = values.first, HelperInputValidator.validateServiceName(service) else {
                throw PrivilegeClientError.executionFailed("invalid network service name")
            }
        case .setProxyBypass:
            guard values.count >= 2, HelperInputValidator.validateServiceName(values[0]) else {
                throw PrivilegeClientError.executionFailed("invalid bypass service or empty domain list")
            }
            let domains = Array(values.dropFirst())
            if domains.contains(where: HelperInputValidator.isEmptyListSentinel) {
                guard domains.count == 1 else {
                    throw PrivilegeClientError.executionFailed("'Empty' must be the only bypass domain value")
                }
            } else if !domains.allSatisfy(HelperInputValidator.validateProxyBypassEntry) {
                throw PrivilegeClientError.executionFailed("invalid bypass domain")
            }
        case .setWebProxyEndpoint:
            guard values.count >= 5,
                  HelperInputValidator.validateServiceName(values[0]),
                  HelperInputValidator.validateWebProxyKind(values[1]),
                  HelperInputValidator.validateOptionalEndpoint(host: values[2], port: values[3]),
                  HelperInputValidator.validateProxyState(values[4]) else {
                throw PrivilegeClientError.executionFailed("invalid web proxy service, kind, endpoint, or state")
            }
        case .setAutoproxy:
            guard values.count >= 3,
                  HelperInputValidator.validateServiceName(values[0]),
                  values[1].isEmpty || HelperInputValidator.validateAutoproxyURL(values[1]),
                  HelperInputValidator.validateProxyState(values[2]) else {
                throw PrivilegeClientError.executionFailed("invalid autoproxy service, URL, or state")
            }
        case .setAutoproxyURL:
            guard values.count >= 2,
                  HelperInputValidator.validateServiceName(values[0]),
                  HelperInputValidator.validateAutoproxyURL(values[1]) else {
                throw PrivilegeClientError.executionFailed("invalid autoproxy service or URL")
            }
        case .setDNSServers:
            guard values.count >= 2, HelperInputValidator.validateServiceName(values[0]) else {
                throw PrivilegeClientError.executionFailed("invalid DNS service or servers")
            }
            let servers = Array(values.dropFirst())
            let clears = servers.contains { $0.lowercased() == "empty" }
            if clears {
                guard servers.count == 1 else {
                    throw PrivilegeClientError.executionFailed("'empty' must be the only DNS server value")
                }
            } else if !servers.allSatisfy(HelperInputValidator.validateIPAddress) {
                throw PrivilegeClientError.executionFailed("invalid DNS server")
            }
        }
    }

    /// One-time install: copies the helper to /Library/PrivilegedHelperTools and registers
    /// a LaunchDaemon. Requires one admin prompt via AppleScript.
    package func installHelper(from sourcePath: String) throws {
        let binaryDst = HelperConstants.binaryInstallPath
        let plistDst = HelperConstants.launchdPlistPath
        let socketPath = HelperConstants.socketPath

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperConstants.serviceLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryDst)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/var/log/\(HelperConstants.serviceLabel).log</string>
        </dict>
        </plist>
        """

        let script = """
        launchctl bootout system \(plistDst.shellQuoted) 2>/dev/null || true
        rm -f \(socketPath.shellQuoted)
        mkdir -p /Library/PrivilegedHelperTools
        cp \(sourcePath.shellQuoted) \(binaryDst.shellQuoted)
        chown root:wheel \(binaryDst.shellQuoted)
        chmod 755 \(binaryDst.shellQuoted)
        cat > \(plistDst.shellQuoted) <<'PLISTEOF'
        \(plistContent)
        PLISTEOF
        chown root:wheel \(plistDst.shellQuoted)
        chmod 644 \(plistDst.shellQuoted)
        launchctl bootstrap system \(plistDst.shellQuoted)
        """

        try fallback.runPrivilegedScript(script)
    }

    package func uninstallHelper() throws {
        let script = """
        launchctl bootout system \(HelperConstants.launchdPlistPath.shellQuoted) 2>/dev/null || true
        rm -f \(HelperConstants.binaryInstallPath.shellQuoted) \(HelperConstants.launchdPlistPath.shellQuoted) \(HelperConstants.socketPath.shellQuoted)
        """
        try? fallback.runPrivilegedScript(script)
    }

    // MARK: - Socket Communication

    private func sendRequest(_ request: HelperRequest) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PrivilegeClientError.communicationFailed("Failed to create socket")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        HelperConstants.socketPath.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let dst = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dst, cstr, maxLen)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw PrivilegeClientError.helperNotInstalled
        }

        var requestData = try JSONEncoder().encode(request)
        requestData.append(UInt8(ascii: "\n"))
        let written = requestData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard written == requestData.count else {
            throw PrivilegeClientError.communicationFailed("Write failed")
        }

        var responseData = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            responseData.append(byte)
            if responseData.count > 1_048_576 {
                throw PrivilegeClientError.communicationFailed(
                    "Response too large: exceeded 1,048,576 byte limit"
                )
            }
        }

        guard !responseData.isEmpty else {
            throw PrivilegeClientError.communicationFailed("Empty response")
        }
        return try JSONDecoder().decode(HelperResponse.self, from: responseData)
    }
}

extension HelperCommand {
    package init(_ operation: PrivilegedOperation) {
        switch operation {
        case .applyDNS:
            self = .applyDNS
        case .removeDNS:
            self = .removeDNS
        case .applySystemProxy:
            self = .applySystemProxy
        case .clearSystemProxy:
            self = .clearSystemProxy
        case .setProxyBypass:
            self = .setProxyBypass
        case .setAutoproxyURL:
            self = .setAutoproxyURL
        case .disableAutoproxy:
            self = .disableAutoproxy
        case .setWebProxyEndpoint:
            self = .setWebProxyEndpoint
        case .setAutoproxy:
            self = .setAutoproxy
        case .setDNSServers:
            self = .setDNSServers
        case .startDNSRelay:
            self = .startDNSRelay
        case .stopDNSRelay:
            self = .stopDNSRelay
        case .startTCPRelay:
            self = .startTCPRelay
        case .stopTCPRelay:
            self = .stopTCPRelay
        case .ping:
            self = .ping
        }
    }
}

/// Resolves the best available source path for the helper binary.
package enum HelperBinaryLocator {
    package static var sourcePath: String? {
        let bundleHelperPath = Bundle.main.bundlePath
            + "/Contents/Library/LaunchServices/\(HelperConstants.serviceLabel)"
        if FileManager.default.fileExists(atPath: bundleHelperPath) {
            return bundleHelperPath
        }

        let macOSPath = Bundle.main.bundlePath + "/Contents/MacOS/ConduitHelper"
        if FileManager.default.fileExists(atPath: macOSPath) {
            return macOSPath
        }

        return nil
    }
}
