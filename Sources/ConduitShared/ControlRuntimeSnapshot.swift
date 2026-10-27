// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The freshness anchor of a value: which host lifetime, which presentation
/// generation, and which configuration and lifecycle generations it reflects.
/// Commands compare lifecycle and configuration revisions; the presentation
/// revision advances on counter traffic and is never a command precondition.
package struct ControlRuntimeStamp: Codable, Sendable, Equatable {
    package var incarnation: ControlHostIncarnation
    package var presentationRevision: ControlPresentationRevision
    package var configRevision: ControlConfigRevision
    /// The whole-host lifecycle counter: it moves on every module's admission, so a matching value means no module moved.
    package var lifecycleRevision: ControlLifecycleRevision
    /// Each module's own lifecycle revision in the same turn (decision 0035), which a request names for one module, such as Restart's
    /// conditional DNS companion. Absent from a stamp that does not report them, which keeps the earlier encoding.
    package var modules: ControlModuleRevisions?

    package init(
        incarnation: ControlHostIncarnation,
        presentationRevision: ControlPresentationRevision,
        configRevision: ControlConfigRevision,
        lifecycleRevision: ControlLifecycleRevision,
        modules: ControlModuleRevisions? = nil
    ) {
        self.incarnation = incarnation
        self.presentationRevision = presentationRevision
        self.configRevision = configRevision
        self.lifecycleRevision = lifecycleRevision
        self.modules = modules
    }
}

/// One lifecycle revision per module, in a fixed shape.
package struct ControlModuleRevisions: Codable, Sendable, Equatable {
    package var proxy: ControlLifecycleRevision
    package var dns: ControlLifecycleRevision
    package var tunnels: ControlLifecycleRevision

    package init(proxy: ControlLifecycleRevision, dns: ControlLifecycleRevision, tunnels: ControlLifecycleRevision) {
        self.proxy = proxy
        self.dns = dns
        self.tunnels = tunnels
    }
}

/// Mirrors the kernel's proxy connection state. Its values are the wire spelling.
package enum ControlProxyState: String, Codable, Sendable, Equatable, CaseIterable {
    case stopped
    case starting
    case running
    case degraded
    case recovering
    case failed
}

/// Mirrors the kernel's module run state.
package enum ControlModuleRunState: String, Codable, Sendable, Equatable, CaseIterable {
    case stopped
    case starting
    case running
    case warning
    case failed
}

/// The single typed cause of direct or degraded routing. Direct mode is derived
/// from it, never sent beside it.
package enum ControlDirectModeCause: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case transientNetworkChange
    case vpnDisconnected
    case noUpstreamsConfigured
    case upstreamsUnreachable
}

/// Why the VPN is observed as disconnected.
package enum ControlVPNDisconnectReason: String, Codable, Sendable, Equatable, CaseIterable {
    case userInitiated
    case networkLost
    case unknown
}

/// What the VPN observer believes.
package enum ControlVPNState: Codable, Sendable, Equatable {
    case unknown
    case connected
    case reasserting
    case disconnected(ControlVPNDisconnectReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "unknown": self = .unknown
        case "connected": self = .connected
        case "reasserting": self = .reasserting
        case "disconnected":
            self = .disconnected(try container.decode(ControlVPNDisconnectReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown VPN state")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try container.encode("unknown", forKey: .type)
        case .connected:
            try container.encode("connected", forKey: .type)
        case .reasserting:
            try container.encode("reasserting", forKey: .type)
        case .disconnected(let reason):
            try container.encode("disconnected", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// What the runtime actually produced on the most recent handshake.
package enum ControlAuthOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case kerberos
    case ntlmFallback
    case ntlmDirect
}

/// Upstream circuit-breaker state.
package enum ControlCircuitState: String, Codable, Sendable, Equatable, CaseIterable {
    case closed
    case open
    case halfOpen
}

/// A bound host and port. Either part may be absent, as in the kernel's bindings;
/// nothing is dropped when only one is set.
package struct ControlEndpoint: Codable, Sendable, Equatable {
    package var host: String?
    package var port: ControlPort?

    package init(host: String?, port: ControlPort?) {
        self.host = host
        self.port = port
    }
}

/// The endpoints the runtime is actually listening on. Each is nil when that
/// surface is not bound.
package struct ControlRuntimeBindings: Codable, Sendable, Equatable {
    package var proxy: ControlEndpoint?
    package var socks: ControlEndpoint?
    package var localPAC: ControlEndpoint?
    package var dns: ControlEndpoint?
    package var transparentProxy: ControlEndpoint?

    package init(
        proxy: ControlEndpoint?,
        socks: ControlEndpoint?,
        localPAC: ControlEndpoint?,
        dns: ControlEndpoint?,
        transparentProxy: ControlEndpoint?
    ) {
        self.proxy = proxy
        self.socks = socks
        self.localPAC = localPAC
        self.dns = dns
        self.transparentProxy = transparentProxy
    }

    /// Derived, so it cannot contradict the bindings: both the DNS forwarder and the
    /// transparent proxy it points clients at must be bound.
    package var dnsInterceptReady: Bool {
        dns?.port != nil && transparentProxy?.port != nil
    }
}

/// The raw runtime counters. Presentation baselines stay local to the view.
package struct ControlRuntimeMetrics: Codable, Sendable, Equatable {
    package var requestsHandled: ControlCount
    package var failedRequests: ControlCount
    package var successfulRecoveries: ControlCount
    package var openConnections: ControlCount
    package var inboundConnections: ControlCount
    package var uptimeStartedAt: ControlTimestamp?
    package var lastFailure: ControlTimestamp?

    package init(
        requestsHandled: ControlCount,
        failedRequests: ControlCount,
        successfulRecoveries: ControlCount,
        openConnections: ControlCount,
        inboundConnections: ControlCount,
        uptimeStartedAt: ControlTimestamp?,
        lastFailure: ControlTimestamp?
    ) {
        self.requestsHandled = requestsHandled
        self.failedRequests = failedRequests
        self.successfulRecoveries = successfulRecoveries
        self.openConnections = openConnections
        self.inboundConnections = inboundConnections
        self.uptimeStartedAt = uptimeStartedAt
        self.lastFailure = lastFailure
    }
}

/// VPN flap telemetry. Only flaps that survive the kernel's visibility debounce count.
package struct ControlVPNFlapMetrics: Codable, Sendable, Equatable {
    package var count: ControlCount
    package var totalDurationSeconds: ControlNonNegativeNumber
    package var lastFlapAt: ControlTimestamp?
    package var streamsPreserved: ControlCount

    package init(
        count: ControlCount,
        totalDurationSeconds: ControlNonNegativeNumber,
        lastFlapAt: ControlTimestamp?,
        streamsPreserved: ControlCount
    ) {
        self.count = count
        self.totalDurationSeconds = totalDurationSeconds
        self.lastFlapAt = lastFlapAt
        self.streamsPreserved = streamsPreserved
    }
}

/// The state of the tunnel DNS override, as the kernel reports it.
package enum ControlTunnelDNSKind: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case partial
    case unavailable
    case notNeeded
}

/// The tunnel DNS override. Its hosts are a paged collection, not inline arrays.
package struct ControlTunnelDNSSummary: Codable, Sendable, Equatable {
    package var kind: ControlTunnelDNSKind
    /// Sanitized, and set only when `kind` is `unavailable`.
    package var unavailableReason: String?
    package var hosts: ControlCollectionReference

    package init(kind: ControlTunnelDNSKind, unavailableReason: String?, hosts: ControlCollectionReference) {
        self.kind = kind
        self.unavailableReason = unavailableReason
        self.hosts = hosts
    }
}

/// Why per-surface applied state is not reported. It arrives with #194; until then
/// it is never inferred from an enabled flag.
package enum ControlAppliedStateUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    case pendingAppliedStateSlice = "pending_applied_state_slice"
}

/// The per-surface applied state. Only the explicit unavailable value exists today.
package enum ControlAppliedState: Codable, Sendable, Equatable {
    case unavailable(ControlAppliedStateUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == "unavailable" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown applied state")
        }
        self = .unavailable(try container.decode(ControlAppliedStateUnavailableReason.self, forKey: .reason))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// The scalar runtime snapshot. It holds every presentation scalar the adapter
/// reads, and refers to the lists by revision instead of inlining them.
package struct ControlRuntimeSnapshot: Codable, Sendable, Equatable {
    package var stamp: ControlRuntimeStamp
    package var profileName: String
    package var proxyState: ControlProxyState
    package var activeUpstream: String?
    package var healthSummary: String
    package var proxyError: String?
    package var dnsRunState: ControlModuleRunState
    package var dnsError: String?
    package var tunnelsRunState: ControlModuleRunState
    package var tunnelsError: String?
    package var directModeCause: ControlDirectModeCause
    package var vpnState: ControlVPNState
    package var vpnInterfaceName: String?
    package var bindings: ControlRuntimeBindings
    package var lastAuthOutcome: ControlAuthOutcome?
    package var lastAuthOutcomeAt: ControlTimestamp?
    package var lastAuthFallbackReason: String?
    package var metrics: ControlRuntimeMetrics
    package var dnsQueryCount: ControlCount
    package var dnsDoHFallbackCount: ControlCount
    package var dnsCacheHitCount: ControlCount
    package var tunnelActiveCount: ControlCount
    package var tunnelSessionCount: ControlCount
    package var tunnelDNSOverride: ControlTunnelDNSSummary
    package var vpnFlap: ControlVPNFlapMetrics
    package var collections: ControlRuntimeCollections
    package var appliedState: ControlAppliedState
    /// The notices of the display text above, in canonical order. Each names a field whose text was shortened or omitted.
    package var displayNotices: [ControlDisplayNotice]

    /// Derived from the typed cause, so it cannot disagree with it.
    package var isDirectMode: Bool {
        directModeCause != .none
    }

    package init(
        stamp: ControlRuntimeStamp,
        profileName: String,
        proxyState: ControlProxyState,
        activeUpstream: String?,
        healthSummary: String,
        proxyError: String?,
        dnsRunState: ControlModuleRunState,
        dnsError: String?,
        tunnelsRunState: ControlModuleRunState,
        tunnelsError: String?,
        directModeCause: ControlDirectModeCause,
        vpnState: ControlVPNState,
        vpnInterfaceName: String?,
        bindings: ControlRuntimeBindings,
        lastAuthOutcome: ControlAuthOutcome?,
        lastAuthOutcomeAt: ControlTimestamp?,
        lastAuthFallbackReason: String?,
        metrics: ControlRuntimeMetrics,
        dnsQueryCount: ControlCount,
        dnsDoHFallbackCount: ControlCount,
        dnsCacheHitCount: ControlCount,
        tunnelActiveCount: ControlCount,
        tunnelSessionCount: ControlCount,
        tunnelDNSOverride: ControlTunnelDNSSummary,
        vpnFlap: ControlVPNFlapMetrics,
        collections: ControlRuntimeCollections,
        appliedState: ControlAppliedState,
        displayNotices: [ControlDisplayNotice] = []
    ) {
        self.stamp = stamp
        self.profileName = profileName
        self.proxyState = proxyState
        self.activeUpstream = activeUpstream
        self.healthSummary = healthSummary
        self.proxyError = proxyError
        self.dnsRunState = dnsRunState
        self.dnsError = dnsError
        self.tunnelsRunState = tunnelsRunState
        self.tunnelsError = tunnelsError
        self.directModeCause = directModeCause
        self.vpnState = vpnState
        self.vpnInterfaceName = vpnInterfaceName
        self.bindings = bindings
        self.lastAuthOutcome = lastAuthOutcome
        self.lastAuthOutcomeAt = lastAuthOutcomeAt
        self.lastAuthFallbackReason = lastAuthFallbackReason
        self.metrics = metrics
        self.dnsQueryCount = dnsQueryCount
        self.dnsDoHFallbackCount = dnsDoHFallbackCount
        self.dnsCacheHitCount = dnsCacheHitCount
        self.tunnelActiveCount = tunnelActiveCount
        self.tunnelSessionCount = tunnelSessionCount
        self.tunnelDNSOverride = tunnelDNSOverride
        self.vpnFlap = vpnFlap
        self.collections = collections
        self.appliedState = appliedState
        self.displayNotices = displayNotices
    }
}
