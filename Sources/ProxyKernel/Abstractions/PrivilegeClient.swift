// SPDX-License-Identifier: Apache-2.0
// Kernel-side protocol seam for privileged host-side operations. The concrete
// impls — `AppleScriptPrivilegeClient` (osascript fallback) and
// `HelperToolPrivilegeClient` (Unix-socket helper daemon client) — live in
// `HelperPrivilegeClient.swift`, which lives in `Sources/PlatformMac/`.
// The protocol itself stays in the kernel so consumers
// (`ProxyOrchestrator`, `TunnelResolverManager`, future kernel callers) can
// type against it without linking `PlatformMac`.

import Foundation

package enum PrivilegedOperation: String, Sendable, CaseIterable {
    case applyDNS = "apply-dns"
    case removeDNS = "remove-dns"
    case applySystemProxy = "apply-system-proxy"
    case clearSystemProxy = "clear-system-proxy"
    case setProxyBypass = "set-proxy-bypass"
    case setAutoproxyURL = "set-autoproxy-url"
    case disableAutoproxy = "disable-autoproxy"
    case setDNSServers = "set-dns-servers"
    case startDNSRelay = "start-dns-relay"
    case stopDNSRelay = "stop-dns-relay"
    case startTCPRelay = "start-tcp-relay"
    case stopTCPRelay = "stop-tcp-relay"
    case ping
}

package enum PrivilegeClientError: Error, LocalizedError {
    case executionFailed(String)
    case helperNotInstalled
    case communicationFailed(String)

    package var errorDescription: String? {
        switch self {
        case .executionFailed(let message): return message
        case .helperNotInstalled: return "Privileged helper is not installed."
        case .communicationFailed(let message): return "Helper communication failed: \(message)"
        }
    }
}

package protocol PrivilegeClient: Sendable {
    func execute(_ operation: PrivilegedOperation, values: [String]) throws
}
