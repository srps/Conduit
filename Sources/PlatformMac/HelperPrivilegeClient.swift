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
    package init() {}

    package func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        let script = try shellScript(for: operation, values: values)
        try CommandRunner.runPrivilegedShellScript(script)
    }

    func runPrivilegedScript(_ script: String) throws {
        try CommandRunner.runPrivilegedShellScript(script)
    }

    private func shellScript(for operation: PrivilegedOperation, values: [String]) throws -> String {
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
            guard !values.isEmpty else { throw PrivilegeClientError.executionFailed("setProxyBypass requires service") }
            let s = values[0].shellQuoted
            let domains = values.dropFirst().map { $0.shellQuoted }.joined(separator: " ")
            return "/usr/sbin/networksetup -setproxybypassdomains \(s) \(domains)"
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
    package init() {}
    private let fallback = AppleScriptPrivilegeClient()

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
        let command = HelperCommand(operation)
        try validate(command: command, values: values)
        do {
            let response = try sendRequest(HelperRequest(command: command, values: values))
            guard response.protocolVersion == HelperProtocolVersion.current else {
                throw PrivilegeClientError.communicationFailed("Helper protocol mismatch.")
            }
            guard response.success else {
                throw PrivilegeClientError.executionFailed(response.errorMessage ?? "Command failed")
            }
        } catch let error as PrivilegeClientError {
            throw error
        } catch {
            try fallback.execute(operation, values: values)
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
            guard let service = values.first, HelperInputValidator.validateServiceName(service) else {
                throw PrivilegeClientError.executionFailed("invalid network service name")
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
