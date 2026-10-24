// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How much privilege an integration step needs. Mirrors PlatformMac's
/// `PrivilegeLevel` without importing it.
package enum ControlPrivilegeLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case mayRequireAdmin
    case requiresAdmin
}

/// One integration's preflight status, mirroring PlatformMac's `IntegrationStatus`.
package struct ControlIntegrationStatus: Codable, Sendable, Equatable {
    package var enabled: Bool
    package var alreadyApplied: Bool
    package var privilegeLevel: ControlPrivilegeLevel

    package init(enabled: Bool, alreadyApplied: Bool, privilegeLevel: ControlPrivilegeLevel) {
        self.enabled = enabled
        self.alreadyApplied = alreadyApplied
        self.privilegeLevel = privilegeLevel
    }

    package var needsChange: Bool { enabled && !alreadyApplied }
    package var willPromptAdmin: Bool { needsChange && privilegeLevel != .none }
}

/// The privileged helper's status as the app last observed it. Mirrors
/// `HelperToolPrivilegeClient.Status` case for case.
package enum ControlHelperStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case installed
    case outdated
    case notInstalled
    case notResponding
    /// Installed, but the ping ran out of budget. Inconclusive: it proves neither a
    /// working helper nor a broken one.
    case busy
    case waitingForConsoleUser
    /// Refusing this process for good: its user is not the console user.
    case unauthorized
    /// Refusing this build. The helper's own explanation is not carried on the wire.
    case callerNotAccepted
}

/// The integration and helper readings of one preflight pass.
package struct ControlPreflightItems: Codable, Sendable, Equatable {
    package var systemProxy: ControlIntegrationStatus
    package var environmentVariables: ControlIntegrationStatus
    package var splitDNS: ControlIntegrationStatus
    package var helper: ControlHelperStatus

    package init(
        systemProxy: ControlIntegrationStatus,
        environmentVariables: ControlIntegrationStatus,
        splitDNS: ControlIntegrationStatus,
        helper: ControlHelperStatus
    ) {
        self.systemProxy = systemProxy
        self.environmentVariables = environmentVariables
        self.splitDNS = splitDNS
        self.helper = helper
    }

    /// Derived from the item statuses; it cannot disagree with them.
    package var requiresAdmin: Bool {
        systemProxy.willPromptAdmin || splitDNS.willPromptAdmin
    }
}

/// Why no preflight reading is available for an observation.
package enum ControlPreflightUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    case notObserved = "not_observed"
    case busy
}

/// Whether a preflight pass produced a reading. An unavailable pass carries no
/// items, so it can never be read as a stopped or healthy integration.
package enum ControlPreflightReading: Codable, Sendable, Equatable {
    case observed(ControlPreflightItems)
    case unavailable(ControlPreflightUnavailableReason)

    private enum CodingKeys: String, CodingKey {
        case type
        case items
        case reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "observed":
            self = .observed(try container.decode(ControlPreflightItems.self, forKey: .items))
        case "unavailable":
            self = .unavailable(try container.decode(ControlPreflightUnavailableReason.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "an unknown reading")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observed(let items):
            try container.encode("observed", forKey: .type)
            try container.encode(items, forKey: .items)
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// A preflight pass with its freshness anchor. A reading is applicable only to the
/// stamp it names: a newer configuration or lifecycle revision, or a new incarnation,
/// means it must not authorize repair.
package struct ControlPreflightObservation: Codable, Sendable, Equatable {
    package var stamp: ControlRuntimeStamp
    package var observedAt: ControlTimestamp
    package var reading: ControlPreflightReading

    package init(stamp: ControlRuntimeStamp, observedAt: ControlTimestamp, reading: ControlPreflightReading) {
        self.stamp = stamp
        self.observedAt = observedAt
        self.reading = reading
    }
}
