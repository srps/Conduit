// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum PrivilegeLevel: Sendable, Equatable {
    case none
    case mayRequireAdmin
    case requiresAdmin
}

package struct IntegrationStatus: Sendable, Equatable {
    package let enabled: Bool
    package let alreadyApplied: Bool
    package let privilegeLevel: PrivilegeLevel

    package var needsChange: Bool { enabled && !alreadyApplied }
    package var willPromptAdmin: Bool { needsChange && privilegeLevel != .none }

    package static let disabled = IntegrationStatus(enabled: false, alreadyApplied: false, privilegeLevel: .none)
}

package struct ActivationPreflight: Sendable, Equatable {
    package let systemProxy: IntegrationStatus
    package let environmentVariables: IntegrationStatus
    package let splitDNS: IntegrationStatus

    package var requiresAdmin: Bool {
        systemProxy.willPromptAdmin || splitDNS.willPromptAdmin
    }

    package var summary: String {
        var parts: [String] = []
        if systemProxy.willPromptAdmin { parts.append("system proxy") }
        if splitDNS.willPromptAdmin { parts.append("DNS resolvers") }
        if parts.isEmpty { return "" }
        return "May need admin for: " + parts.joined(separator: ", ")
    }

    package static let noAdmin = ActivationPreflight(
        systemProxy: .disabled,
        environmentVariables: .disabled,
        splitDNS: .disabled
    )
}

package struct ActivationPreflightEvaluator {
    package static func evaluate(
        config: ProxyConfig,
        platformConfig: PlatformIntegrationConfig,
        isRunning: Bool,
        helperStatus: HelperToolPrivilegeClient.Status,
        systemConduit: SystemProxyManager,
        dnsManager: DNSManager
    ) -> ActivationPreflight {
        let helperAvailable = helperStatus == .installed

        let systemProxy: IntegrationStatus
        if platformConfig.manageSystemProxy {
            let alreadyApplied = isRunning
                ? systemConduit.isCleared()
                : systemConduit.isApplied(config: config, mode: platformConfig.systemProxyMode)
            let level: PrivilegeLevel = helperAvailable ? .none : .mayRequireAdmin
            systemProxy = IntegrationStatus(enabled: true, alreadyApplied: alreadyApplied, privilegeLevel: level)
        } else {
            systemProxy = .disabled
        }

        let environmentVariables = IntegrationStatus(
            enabled: platformConfig.manageEnvironmentVariables,
            alreadyApplied: false,
            privilegeLevel: .none
        )

        let splitDNS: IntegrationStatus
        if platformConfig.manageDNSResolvers {
            let hasEntries = isRunning
                ? !config.dnsEntries.filter(\.enabled).isEmpty
                : !config.dnsEntries.filter(\.enabled).filter { !$0.servers.isEmpty }.isEmpty
            if hasEntries {
                let alreadyApplied = isRunning
                    ? dnsManager.isCleared(config: config)
                    : dnsManager.isApplied(config: config)
                let level: PrivilegeLevel = helperAvailable ? .none : .requiresAdmin
                splitDNS = IntegrationStatus(enabled: true, alreadyApplied: alreadyApplied, privilegeLevel: level)
            } else {
                splitDNS = .disabled
            }
        } else {
            splitDNS = .disabled
        }

        return ActivationPreflight(
            systemProxy: systemProxy,
            environmentVariables: environmentVariables,
            splitDNS: splitDNS
        )
    }
}
