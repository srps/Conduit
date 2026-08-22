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
    /// See `HelperCommand.setWebProxyEndpoint` for the argument contract and
    /// why endpoint-then-state ordering lives inside the operation.
    case setWebProxyEndpoint = "set-web-proxy-endpoint"
    /// See `HelperCommand.setAutoproxy`.
    case setAutoproxy = "set-autoproxy"
    case setDNSServers = "set-dns-servers"
    case startDNSRelay = "start-dns-relay"
    case stopDNSRelay = "stop-dns-relay"
    case startTCPRelay = "start-tcp-relay"
    case stopTCPRelay = "stop-tcp-relay"
    case ping
}

/// Why the privileged helper declined to act. The kernel's own reading of
/// the wire's `HelperRefusal`, translated in `PlatformMac`, so kernel
/// consumers are not typed against the helper protocol.
package enum PrivilegeRefusal: String, Sendable, Equatable {
    /// A verdict: this process is not the console user's. Nothing to wait for.
    case unauthorized
    /// A moment: nobody is at the console yet. State to show and to
    /// reconcile past — never to sleep on. See `HelperToolPrivilegeClient`.
    case noConsoleUser
}

package enum PrivilegeClientError: Error, LocalizedError {
    case executionFailed(String)
    case helperNotInstalled
    case communicationFailed(String)
    /// The helper was reached and declined to talk — see `PrivilegeRefusal`.
    /// Not unreachability, and the distinction is the whole point: the
    /// fallback for "unreachable" is an admin password prompt, and a denial
    /// must never turn into one.
    case refused(PrivilegeRefusal, String)

    package var errorDescription: String? {
        switch self {
        case .executionFailed(let message): return message
        case .helperNotInstalled: return "Privileged helper is not installed."
        case .communicationFailed(let message): return "Helper communication failed: \(message)"
        case .refused(.noConsoleUser, _):
            return "Privileged helper is waiting for a login session before it will act."
        case .refused(.unauthorized, let message):
            return "Privileged helper refused this process: \(message)"
        }
    }

    /// Whether the helper could not be *reached or understood*, as opposed to
    /// having run the command and reported it failed — or having refused to
    /// run it at all. Only the first is worth retrying by another route.
    package var isHelperUnreachable: Bool {
        switch self {
        case .helperNotInstalled, .communicationFailed: return true
        case .executionFailed, .refused: return false
        }
    }
}

/// One operation inside a `PrivilegeClient` batch.
package struct PrivilegedBatchStep: Sendable, Equatable {
    package var operation: PrivilegedOperation
    package var values: [String]

    package init(_ operation: PrivilegedOperation, _ values: [String]) {
        self.operation = operation
        self.values = values
    }
}

package protocol PrivilegeClient: Sendable {
    func execute(_ operation: PrivilegedOperation, values: [String]) throws

    /// Runs several operations as a single unit of elevation.
    ///
    /// Restoring one network service's proxy configuration takes four
    /// operations, and the elevation cost is not per-operation everywhere: the
    /// helper socket is free to call repeatedly, but the AppleScript fallback
    /// raises an admin prompt *per invocation*. Looping over `execute` on a
    /// machine with no helper would ask a user tearing down two services for
    /// eight passwords. Implementations that can amortise elevation override
    /// this; the default loops, which is correct for anything that cannot.
    func execute(batch: [PrivilegedBatchStep]) throws
}

extension PrivilegeClient {
    package func execute(batch: [PrivilegedBatchStep]) throws {
        for step in batch {
            try execute(step.operation, values: step.values)
        }
    }
}
