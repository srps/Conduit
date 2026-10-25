// SPDX-License-Identifier: Apache-2.0
import Foundation

// The codec of the records that display text (decision 0029). Each record encodes and decodes its own fields, so the display check runs on
// every encode and every decode, whichever encoder the value reaches. The keys are the property names, and an absent optional is an absent
// key, as the synthesized codec wrote it. The only wire addition is the `displayNotices` key.

extension ControlRuntimeSnapshot {
    private enum CodingKeys: String, CodingKey {
        case stamp, profileName, proxyState, activeUpstream, healthSummary, proxyError, dnsRunState, dnsError
        case tunnelsRunState, tunnelsError, directModeCause, vpnState, vpnInterfaceName, bindings
        case lastAuthOutcome, lastAuthOutcomeAt, lastAuthFallbackReason, metrics
        case dnsQueryCount, dnsDoHFallbackCount, dnsCacheHitCount, tunnelActiveCount, tunnelSessionCount
        case tunnelDNSOverride, vpnFlap, collections, appliedState, displayNotices
    }

    /// The text this record displays, in the owner's canonical field order. It names every field of the owner, nil when absent.
    package var displayValues: ControlDisplayValues {
        [
            (.profileName, profileName),
            (.activeUpstream, activeUpstream),
            (.healthSummary, healthSummary),
            (.proxyError, proxyError),
            (.dnsError, dnsError),
            (.tunnelsError, tunnelsError),
            (.vpnInterfaceName, vpnInterfaceName),
            (.lastAuthFallbackReason, lastAuthFallbackReason),
            (.tunnelDNSUnavailableReason, tunnelDNSOverride.unavailableReason),
            (.proxyHost, bindings.proxy?.host),
            (.socksHost, bindings.socks?.host),
            (.localPACHost, bindings.localPAC?.host),
            (.dnsHost, bindings.dns?.host),
            (.transparentProxyHost, bindings.transparentProxy?.host),
        ]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stamp = try container.decode(ControlRuntimeStamp.self, forKey: .stamp)
        profileName = try container.decode(String.self, forKey: .profileName)
        proxyState = try container.decode(ControlProxyState.self, forKey: .proxyState)
        activeUpstream = try container.decodeIfPresent(String.self, forKey: .activeUpstream)
        healthSummary = try container.decode(String.self, forKey: .healthSummary)
        proxyError = try container.decodeIfPresent(String.self, forKey: .proxyError)
        dnsRunState = try container.decode(ControlModuleRunState.self, forKey: .dnsRunState)
        dnsError = try container.decodeIfPresent(String.self, forKey: .dnsError)
        tunnelsRunState = try container.decode(ControlModuleRunState.self, forKey: .tunnelsRunState)
        tunnelsError = try container.decodeIfPresent(String.self, forKey: .tunnelsError)
        directModeCause = try container.decode(ControlDirectModeCause.self, forKey: .directModeCause)
        vpnState = try container.decode(ControlVPNState.self, forKey: .vpnState)
        vpnInterfaceName = try container.decodeIfPresent(String.self, forKey: .vpnInterfaceName)
        bindings = try container.decode(ControlRuntimeBindings.self, forKey: .bindings)
        lastAuthOutcome = try container.decodeIfPresent(ControlAuthOutcome.self, forKey: .lastAuthOutcome)
        lastAuthOutcomeAt = try container.decodeIfPresent(ControlTimestamp.self, forKey: .lastAuthOutcomeAt)
        lastAuthFallbackReason = try container.decodeIfPresent(String.self, forKey: .lastAuthFallbackReason)
        metrics = try container.decode(ControlRuntimeMetrics.self, forKey: .metrics)
        dnsQueryCount = try container.decode(ControlCount.self, forKey: .dnsQueryCount)
        dnsDoHFallbackCount = try container.decode(ControlCount.self, forKey: .dnsDoHFallbackCount)
        dnsCacheHitCount = try container.decode(ControlCount.self, forKey: .dnsCacheHitCount)
        tunnelActiveCount = try container.decode(ControlCount.self, forKey: .tunnelActiveCount)
        tunnelSessionCount = try container.decode(ControlCount.self, forKey: .tunnelSessionCount)
        tunnelDNSOverride = try container.decode(ControlTunnelDNSSummary.self, forKey: .tunnelDNSOverride)
        vpnFlap = try container.decode(ControlVPNFlapMetrics.self, forKey: .vpnFlap)
        collections = try container.decode(ControlRuntimeCollections.self, forKey: .collections)
        appliedState = try container.decode(ControlAppliedState.self, forKey: .appliedState)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .snapshot)
        try ControlDisplayCheck.checkDecoded(
            owner: .snapshot, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .snapshot, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stamp, forKey: .stamp)
        try container.encode(profileName, forKey: .profileName)
        try container.encode(proxyState, forKey: .proxyState)
        try container.encodeIfPresent(activeUpstream, forKey: .activeUpstream)
        try container.encode(healthSummary, forKey: .healthSummary)
        try container.encodeIfPresent(proxyError, forKey: .proxyError)
        try container.encode(dnsRunState, forKey: .dnsRunState)
        try container.encodeIfPresent(dnsError, forKey: .dnsError)
        try container.encode(tunnelsRunState, forKey: .tunnelsRunState)
        try container.encodeIfPresent(tunnelsError, forKey: .tunnelsError)
        try container.encode(directModeCause, forKey: .directModeCause)
        try container.encode(vpnState, forKey: .vpnState)
        try container.encodeIfPresent(vpnInterfaceName, forKey: .vpnInterfaceName)
        try container.encode(bindings, forKey: .bindings)
        try container.encodeIfPresent(lastAuthOutcome, forKey: .lastAuthOutcome)
        try container.encodeIfPresent(lastAuthOutcomeAt, forKey: .lastAuthOutcomeAt)
        try container.encodeIfPresent(lastAuthFallbackReason, forKey: .lastAuthFallbackReason)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(dnsQueryCount, forKey: .dnsQueryCount)
        try container.encode(dnsDoHFallbackCount, forKey: .dnsDoHFallbackCount)
        try container.encode(dnsCacheHitCount, forKey: .dnsCacheHitCount)
        try container.encode(tunnelActiveCount, forKey: .tunnelActiveCount)
        try container.encode(tunnelSessionCount, forKey: .tunnelSessionCount)
        try container.encode(tunnelDNSOverride, forKey: .tunnelDNSOverride)
        try container.encode(vpnFlap, forKey: .vpnFlap)
        try container.encode(collections, forKey: .collections)
        try container.encode(appliedState, forKey: .appliedState)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}

extension ControlConnectionRow {
    private enum CodingKeys: String, CodingKey {
        case id, destination, upstream, method, startedAt, lastActivityAt, bytesSent, bytesReceived, tunnel, authMethod
        case displayNotices
    }

    /// The text this row displays, in canonical field order.
    package var displayValues: ControlDisplayValues {
        [
            (.connectionDestination, destination),
            (.connectionUpstream, upstream),
            (.connectionMethod, method),
            (.connectionAuthMethod, authMethod),
        ]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ControlConnectionID.self, forKey: .id)
        destination = try container.decode(String.self, forKey: .destination)
        upstream = try container.decode(String.self, forKey: .upstream)
        method = try container.decode(String.self, forKey: .method)
        startedAt = try container.decode(ControlTimestamp.self, forKey: .startedAt)
        lastActivityAt = try container.decode(ControlTimestamp.self, forKey: .lastActivityAt)
        bytesSent = try container.decode(ControlCount.self, forKey: .bytesSent)
        bytesReceived = try container.decode(ControlCount.self, forKey: .bytesReceived)
        tunnel = try container.decode(Bool.self, forKey: .tunnel)
        authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .connectionRow)
        try ControlDisplayCheck.checkDecoded(
            owner: .connectionRow, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .connectionRow, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(destination, forKey: .destination)
        try container.encode(upstream, forKey: .upstream)
        try container.encode(method, forKey: .method)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
        try container.encode(bytesSent, forKey: .bytesSent)
        try container.encode(bytesReceived, forKey: .bytesReceived)
        try container.encode(tunnel, forKey: .tunnel)
        try container.encodeIfPresent(authMethod, forKey: .authMethod)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}

extension ControlUpstreamRow {
    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, circuitState, ewmaLatencyMilliseconds, consecutiveFailures, openUntil, displayNotices
    }

    /// The text this row displays, in canonical field order.
    package var displayValues: ControlDisplayValues {
        [
            (.upstreamName, name),
            (.upstreamEndpoint, endpoint),
        ]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ControlUpstreamID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        circuitState = try container.decode(ControlCircuitState.self, forKey: .circuitState)
        ewmaLatencyMilliseconds = try container.decodeIfPresent(ControlNonNegativeNumber.self, forKey: .ewmaLatencyMilliseconds)
        consecutiveFailures = try container.decode(ControlCount.self, forKey: .consecutiveFailures)
        openUntil = try container.decodeIfPresent(ControlTimestamp.self, forKey: .openUntil)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .upstreamRow)
        try ControlDisplayCheck.checkDecoded(
            owner: .upstreamRow, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .upstreamRow, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(circuitState, forKey: .circuitState)
        try container.encodeIfPresent(ewmaLatencyMilliseconds, forKey: .ewmaLatencyMilliseconds)
        try container.encode(consecutiveFailures, forKey: .consecutiveFailures)
        try container.encodeIfPresent(openUntil, forKey: .openUntil)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}

extension ControlTunnelBindingRow {
    private enum CodingKeys: String, CodingKey {
        case id, label, localHost, localPort, remoteHost, remotePort, proxied, healthy, displayNotices
    }

    /// The text this row displays, in canonical field order.
    package var displayValues: ControlDisplayValues {
        [
            (.tunnelLabel, label),
            (.tunnelLocalHost, localHost),
            (.tunnelRemoteHost, remoteHost),
        ]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ControlTunnelID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        localHost = try container.decode(String.self, forKey: .localHost)
        localPort = try container.decode(ControlPort.self, forKey: .localPort)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        remotePort = try container.decode(ControlPort.self, forKey: .remotePort)
        proxied = try container.decode(Bool.self, forKey: .proxied)
        healthy = try container.decode(Bool.self, forKey: .healthy)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .tunnelBindingRow)
        try ControlDisplayCheck.checkDecoded(
            owner: .tunnelBindingRow, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .tunnelBindingRow, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(localHost, forKey: .localHost)
        try container.encode(localPort, forKey: .localPort)
        try container.encode(remoteHost, forKey: .remoteHost)
        try container.encode(remotePort, forKey: .remotePort)
        try container.encode(proxied, forKey: .proxied)
        try container.encode(healthy, forKey: .healthy)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}

extension ControlTunnelDNSHostRow {
    private enum CodingKeys: String, CodingKey {
        case hostname, outcome, displayNotices
    }

    /// The text this row displays, in canonical field order.
    package var displayValues: ControlDisplayValues {
        [(.dnsHostname, hostname)]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decode(String.self, forKey: .hostname)
        outcome = try container.decode(ControlTunnelDNSHostOutcome.self, forKey: .outcome)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .dnsHostRow)
        try ControlDisplayCheck.checkDecoded(
            owner: .dnsHostRow, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .dnsHostRow, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}

extension ControlUpstreamProbe {
    private enum CodingKeys: String, CodingKey {
        case upstreamID, name, endpoint, reachable, latencyMilliseconds, displayNotices
    }

    /// The text this probe displays, in canonical field order.
    package var displayValues: ControlDisplayValues {
        [
            (.probeName, name),
            (.probeEndpoint, endpoint),
        ]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upstreamID = try container.decode(ControlUpstreamID.self, forKey: .upstreamID)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        reachable = try container.decode(Bool.self, forKey: .reachable)
        latencyMilliseconds = try container.decode(ControlCount.self, forKey: .latencyMilliseconds)
        displayNotices = try ControlDisplayCheck.decodeNotices(from: container, forKey: .displayNotices, owner: .upstreamProbe)
        try ControlDisplayCheck.checkDecoded(
            owner: .upstreamProbe, notices: displayNotices, values: displayValues, codingPath: decoder.codingPath
        )
    }

    package func encode(to encoder: any Encoder) throws {
        try ControlDisplayCheck.checkEncoded(
            self, owner: .upstreamProbe, notices: displayNotices, values: displayValues, codingPath: encoder.codingPath
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upstreamID, forKey: .upstreamID)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(latencyMilliseconds, forKey: .latencyMilliseconds)
        try container.encode(displayNotices, forKey: .displayNotices)
    }
}
