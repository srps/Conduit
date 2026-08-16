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

    /// Whether the helper could not be *reached or understood*, as opposed to
    /// having run the command and reported it failed. Only the former is worth
    /// retrying by another route.
    package var isHelperUnreachable: Bool {
        switch self {
        case .helperNotInstalled, .communicationFailed: return true
        case .executionFailed: return false
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
