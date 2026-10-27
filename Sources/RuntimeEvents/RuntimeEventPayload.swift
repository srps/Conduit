// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The typed value behind a runtime event whose family has migrated (decision
/// 0013). The kernel's `RuntimeEvent` carries one beside its legacy fields. On
/// the file it is written as `{"family": "lifecycle", "lifecycle": {…}}`.
package enum RuntimeEventPayload: Equatable, Sendable {
    case lifecycle(LifecycleEvent)
    case configWorkflow(ConfigurationWorkflowEvent)
    case runtimeService(RuntimeServiceEvent)

    /// The stable event name.
    package var name: String {
        switch self {
        case .lifecycle(let event): event.name
        case .configWorkflow(let event): event.name
        case .runtimeService(let event): event.name
        }
    }

    /// The human detail, derived from the typed fields.
    package var detail: String {
        switch self {
        case .lifecycle(let event): event.detail
        case .configWorkflow(let event): event.detail
        case .runtimeService(let event): event.detail
        }
    }

    /// Every name the typed families emit: the finite inventory `scripts/check-event-catalogue.py`
    /// pins for the schema.
    package static let typedNames: Set<String> = Set(LifecycleEventName.allCases.map(\.rawValue))
        .union(ConfigurationWorkflowEventName.allCases.map(\.rawValue))
        .union(RuntimeServiceEventName.allCases.map(\.rawValue))

    /// Whether the legacy envelope must refuse `name`. The `lifecycle.`, `config.workflow.` and `runtime_service.` namespaces are
    /// closed: every name in them, emitted or planned or assembled at run time, goes through a typed value.
    /// There is no untyped exception. Historical records that lack `typed` still decode, because
    /// decoding never consults this rule. Other `config.*` names keep their legacy envelope.
    package static func requiresTypedPayload(_ name: String) -> Bool {
        name.hasPrefix(lifecyclePrefix) || name.hasPrefix(configWorkflowPrefix) || name.hasPrefix(runtimeServicePrefix)
    }

    private static let lifecyclePrefix = "lifecycle."
    private static let configWorkflowPrefix = "config.workflow."
    private static let runtimeServicePrefix = "runtime_service."
}

extension RuntimeEventPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case family, lifecycle, configWorkflow, runtimeService
    }

    private enum Family: String {
        case lifecycle
        case configWorkflow = "config_workflow"
        case runtimeService = "runtime_service"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch Family(rawValue: try container.decode(String.self, forKey: .family)) {
        case .lifecycle?:
            self = .lifecycle(try container.decode(LifecycleEvent.self, forKey: .lifecycle))
        case .configWorkflow?:
            self = .configWorkflow(try container.decode(ConfigurationWorkflowEvent.self, forKey: .configWorkflow))
        case .runtimeService?:
            self = .runtimeService(try container.decode(RuntimeServiceEvent.self, forKey: .runtimeService))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .family, in: container, debugDescription: "an unknown typed event family"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lifecycle(let event):
            try container.encode(Family.lifecycle.rawValue, forKey: .family)
            try container.encode(event, forKey: .lifecycle)
        case .configWorkflow(let event):
            try container.encode(Family.configWorkflow.rawValue, forKey: .family)
            try container.encode(event, forKey: .configWorkflow)
        case .runtimeService(let event):
            try container.encode(Family.runtimeService.rawValue, forKey: .family)
            try container.encode(event, forKey: .runtimeService)
        }
    }
}
