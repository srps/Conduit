// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The control wire's projection of a typed runtime event (decision 0013). It
/// mirrors the domain layout without importing `RuntimeEvents` or the kernel, so
/// `ProxyControlBridge` maps the domain values onto these types exhaustively.
/// The JSON matches the file's: `{"family": "lifecycle", "lifecycle": {"type": …}}`.
///
/// Package access: `ControlRuntimeEvent`'s v1 shape and public API are unchanged;
/// this field is additive and absent from every legacy record. The kind, name and
/// detail a payload implies are derived here, and `ControlRuntimeEvent` requires the
/// outer fields to agree with them on both decode and encode.
package enum ControlTypedRuntimeEvent: Codable, Sendable, Equatable {
    case lifecycle(ControlLifecycleEvent)
    case configWorkflow(ControlConfigWorkflowEvent)
    case runtimeService(ControlRuntimeServiceEvent)
    case proxyRecovery(ControlProxyRecoveryEvent)

    /// The `kind` the outer record must carry for this family.
    package var kind: String {
        switch self {
        case .lifecycle: "lifecycle"
        case .configWorkflow: "config"
        case .runtimeService: "health"
        case .proxyRecovery: "health"
        }
    }

    /// The `event` the outer record must carry for this payload.
    package var name: String {
        switch self {
        case .lifecycle(let event): event.name
        case .configWorkflow(let event): event.name
        case .runtimeService(let event): event.name
        case .proxyRecovery(let event): event.name
        }
    }

    /// The human `detail` the outer record must carry for this payload.
    package var detail: String {
        switch self {
        case .lifecycle(let event): event.detail
        case .configWorkflow(let event): event.detail
        case .runtimeService(let event): event.detail
        case .proxyRecovery(let event): event.detail
        }
    }

    private enum CodingKeys: String, CodingKey {
        case family, lifecycle, configWorkflow, runtimeService, proxyRecovery
    }

    /// Shared by the codec and record classifier so a new family requires both to handle it.
    enum Family: String {
        case lifecycle
        case configWorkflow = "config_workflow"
        case runtimeService = "runtime_service"
        case proxyRecovery = "proxy_recovery"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let family = try container.decode(String.self, forKey: .family)
        switch Family(rawValue: family) {
        case .lifecycle?:
            self = .lifecycle(try container.decode(ControlLifecycleEvent.self, forKey: .lifecycle))
        case .configWorkflow?:
            self = .configWorkflow(try container.decode(ControlConfigWorkflowEvent.self, forKey: .configWorkflow))
        case .runtimeService?:
            self = .runtimeService(try container.decode(ControlRuntimeServiceEvent.self, forKey: .runtimeService))
        case .proxyRecovery?:
            self = .proxyRecovery(try container.decode(ControlProxyRecoveryEvent.self, forKey: .proxyRecovery))
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
        case .proxyRecovery(let event):
            try container.encode(Family.proxyRecovery.rawValue, forKey: .family)
            try container.encode(event, forKey: .proxyRecovery)
        }
    }
}

/// The wire's `lifecycle.*` values. Operations and reasons are closed enums; the
/// numeric and version fields carry the same invariants as the domain values, through
/// the same predicates `isValid…` below (the domain's copies are checked against these
/// by the projection tests).
package enum ControlLifecycleEvent: Codable, Sendable, Equatable {
    case superseded(operation: ControlLifecycleOperation, generation: Int, current: Int, reason: ControlLifecycleReason)
    case coalesced(operation: ControlLifecycleOperation, joined: Int)
    case terminationDrainExpired(deadlineMilliseconds: Int)
    case versionChanged(from: String, to: String)
    case moduleSettled(settlement: ControlLifecycleSettlement, group: Int)
    case logFlushUnconfirmed(source: ControlLifecycleLogFlushSource, outcome: ControlLifecycleLogFlushOutcome)

    private enum WireType: String, Codable, CaseIterable {
        case superseded
        case coalesced
        case terminationDrainExpired = "termination_drain_expired"
        case versionChanged = "version_changed"
        case moduleSettled = "module_settled"
        case logFlushUnconfirmed = "log_flush_unconfirmed"
    }

    /// The stable event names, spelled once here. The domain's `LifecycleEventName` pins the same six.
    private enum EventName: String, CaseIterable {
        case superseded = "lifecycle.superseded"
        case coalesced = "lifecycle.coalesced"
        case terminationDrainExpired = "lifecycle.termination_drain_expired"
        case versionChanged = "lifecycle.version_changed"
        case moduleSettled = "lifecycle.module_settled"
        case logFlushUnconfirmed = "lifecycle.log_flush_unconfirmed"
    }

    private enum CodingKeys: String, CodingKey {
        case type, operation, generation, current, reason, joined, from, to, module, source, outcome, group
        case deadlineMilliseconds = "deadline_ms"
    }

    /// The `type` spellings this build decodes. The record classifier reads this set, so it cannot drift.
    package static let knownWireTypes: Set<String> = Set(WireType.allCases.map(\.rawValue))

    /// The event names this build emits and decodes. The record classifier reads this set, so it cannot drift.
    package static let knownEventNames: Set<String> = Set(EventName.allCases.map(\.rawValue))

    /// A `superseded` reason means a later generation overtook this one, so `current`
    /// must be strictly newer. `runtime_down` may have `current == generation`.
    package static func isValidSuperseded(generation: Int, current: Int, reason: ControlLifecycleReason) -> Bool {
        guard generation >= 1 else { return false }
        return reason == .superseded ? current > generation : current >= generation
    }

    package static func isValidCoalesced(joined: Int) -> Bool { joined >= 1 }

    package static func isValidTerminationDrain(deadlineMilliseconds: Int) -> Bool { deadlineMilliseconds >= 0 }

    /// The longest version the wire carries, in bytes: the domain's `LifecycleVersionChanged.maximumVersionBytes`,
    /// with the same reason. At 59 the rendered `from=<version>` line is 64 bytes, under the sanitizer's
    /// 65-byte run, so the outer detail the wire compares against is the line this value renders unchanged.
    package static let maximumVersionBytes = 59

    /// A version is 1 to `maximumVersionBytes` ASCII token bytes: letters, digits, `.`, `-`, `+`, `_`. The
    /// same grammar as the domain's `LifecycleVersionChanged`, not a semver parse.
    private static let versionBytes = Set(
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+_".utf8)
    )

    package static func isValidVersion(_ version: String) -> Bool {
        (1...maximumVersionBytes).contains(version.utf8.count) && version.utf8.allSatisfy { versionBytes.contains($0) }
    }

    /// The mirror of the domain's `readsAsBearerCredential`: a `from` ending in the word `Bearer` (any case),
    /// at the start or after `.`, `-` or `+`. The sanitizer masks its rendered `from=… to=…` line.
    private static func readsAsBearerCredential(from version: String) -> Bool {
        let word = "bearer"
        guard version.lowercased().hasSuffix(word) else { return false }
        let stem = version.dropLast(word.count)
        return stem.last.map { ".-+".contains($0) } ?? true
    }

    /// The mirror of the domain's pair rule, checked against it by the projection tests.
    package static func isValidVersionChange(from: String, to: String) -> Bool {
        isValidVersion(from) && !readsAsBearerCredential(from: from) && isValidVersion(to)
    }

    /// The mirror of the domain's settlement rule: an admitted group, and a proxy member never `not_configured`.
    package static func isValidModuleSettled(settlement: ControlLifecycleSettlement, group: Int) -> Bool {
        group >= 1 && settlement != .explicit(.proxy, .notConfigured)
    }

    /// The source selects which closed result set `outcome` is read from, as the domain's decoder does.
    private static func decodeSettlement(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ControlLifecycleSettlement {
        let module = try container.decode(ControlModule.self, forKey: .module)
        switch try container.decode(String.self, forKey: .source) {
        case "explicit":
            return .explicit(module, try container.decode(ControlLifecycleModuleResult.self, forKey: .outcome))
        case "conditional":
            guard module == .dns else {
                throw DecodingError.dataCorruptedError(forKey: .module, in: container, debugDescription: "a conditional companion settles DNS only")
            }
            return .conditionalDNS(try container.decode(ControlLifecycleConditionalDNSResult.self, forKey: .outcome))
        default:
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "a settlement is explicit or conditional")
        }
    }

    /// The stable event name, the same spelling the domain derives.
    package var name: String {
        switch self {
        case .superseded: EventName.superseded.rawValue
        case .coalesced: EventName.coalesced.rawValue
        case .terminationDrainExpired: EventName.terminationDrainExpired.rawValue
        case .versionChanged: EventName.versionChanged.rawValue
        case .moduleSettled: EventName.moduleSettled.rawValue
        case .logFlushUnconfirmed: EventName.logFlushUnconfirmed.rawValue
        }
    }

    /// The human detail, byte for byte what the legacy records carried.
    package var detail: String {
        switch self {
        case .superseded(let operation, let generation, let current, let reason):
            "operation=\(operation.rawValue) generation=\(generation) current=\(current) reason=\(reason.rawValue)"
        case .coalesced(let operation, let joined):
            "operation=\(operation.rawValue) joined=\(joined)"
        case .terminationDrainExpired(let deadlineMilliseconds):
            "deadline_ms=\(deadlineMilliseconds)"
        case .versionChanged(let from, let to):
            "from=\(from) to=\(to)"
        case .moduleSettled(let settlement, let group):
            "module=\(settlement.module.rawValue) source=\(settlement.source) outcome=\(settlement.outcome) group=\(group)"
        case .logFlushUnconfirmed(let source, let outcome):
            "source=\(source.rawValue) outcome=\(outcome.rawValue)"
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .superseded:
            let operation = try container.decode(ControlLifecycleOperation.self, forKey: .operation)
            let generation = try container.decode(Int.self, forKey: .generation)
            let current = try container.decode(Int.self, forKey: .current)
            let reason = try container.decode(ControlLifecycleReason.self, forKey: .reason)
            guard Self.isValidSuperseded(generation: generation, current: current, reason: reason) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .current, in: container,
                    debugDescription: "generation must be at least 1, and current must exceed it when superseded"
                )
            }
            self = .superseded(operation: operation, generation: generation, current: current, reason: reason)
        case .coalesced:
            let joined = try container.decode(Int.self, forKey: .joined)
            guard Self.isValidCoalesced(joined: joined) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .joined, in: container, debugDescription: "a joined generation is at least 1"
                )
            }
            self = .coalesced(
                operation: try container.decode(ControlLifecycleOperation.self, forKey: .operation),
                joined: joined
            )
        case .terminationDrainExpired:
            let milliseconds = try container.decode(Int.self, forKey: .deadlineMilliseconds)
            guard Self.isValidTerminationDrain(deadlineMilliseconds: milliseconds) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deadlineMilliseconds, in: container, debugDescription: "a drain deadline is not negative"
                )
            }
            self = .terminationDrainExpired(deadlineMilliseconds: milliseconds)
        case .versionChanged:
            let from = try container.decode(String.self, forKey: .from)
            let to = try container.decode(String.self, forKey: .to)
            guard Self.isValidVersionChange(from: from, to: to) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .from, in: container,
                    debugDescription: "a version is 1 to \(Self.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                )
            }
            self = .versionChanged(from: from, to: to)
        case .moduleSettled:
            let settlement = try Self.decodeSettlement(container)
            let group = try container.decode(Int.self, forKey: .group)
            guard Self.isValidModuleSettled(settlement: settlement, group: group) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .group, in: container,
                    debugDescription: "a settled group is at least 1, and a proxy member is never not_configured"
                )
            }
            self = .moduleSettled(settlement: settlement, group: group)
        case .logFlushUnconfirmed:
            self = .logFlushUnconfirmed(
                source: try container.decode(ControlLifecycleLogFlushSource.self, forKey: .source),
                outcome: try container.decode(ControlLifecycleLogFlushOutcome.self, forKey: .outcome)
            )
        }
    }

    /// Refuses to write a known value that decoding would reject.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .superseded(let operation, let generation, let current, let reason):
            guard Self.isValidSuperseded(generation: generation, current: current, reason: reason) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "generation must be at least 1, and current must exceed it when superseded"
                ))
            }
            try container.encode(WireType.superseded, forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encode(generation, forKey: .generation)
            try container.encode(current, forKey: .current)
            try container.encode(reason, forKey: .reason)
        case .coalesced(let operation, let joined):
            guard Self.isValidCoalesced(joined: joined) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a joined generation is at least 1"
                ))
            }
            try container.encode(WireType.coalesced, forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encode(joined, forKey: .joined)
        case .terminationDrainExpired(let deadlineMilliseconds):
            guard Self.isValidTerminationDrain(deadlineMilliseconds: deadlineMilliseconds) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a drain deadline is not negative"
                ))
            }
            try container.encode(WireType.terminationDrainExpired, forKey: .type)
            try container.encode(deadlineMilliseconds, forKey: .deadlineMilliseconds)
        case .versionChanged(let from, let to):
            guard Self.isValidVersionChange(from: from, to: to) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "a version is 1 to \(Self.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                ))
            }
            try container.encode(WireType.versionChanged, forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        case .moduleSettled(let settlement, let group):
            guard Self.isValidModuleSettled(settlement: settlement, group: group) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "a settled group is at least 1, and a proxy member is never not_configured"
                ))
            }
            try container.encode(WireType.moduleSettled, forKey: .type)
            try container.encode(settlement.module, forKey: .module)
            try container.encode(settlement.source, forKey: .source)
            try container.encode(settlement.outcome, forKey: .outcome)
            try container.encode(group, forKey: .group)
        case .logFlushUnconfirmed(let source, let outcome):
            try container.encode(WireType.logFlushUnconfirmed, forKey: .type)
            try container.encode(source, forKey: .source)
            try container.encode(outcome, forKey: .outcome)
        }
    }
}

/// Wire spelling of whose logger drain went unconfirmed: the domain's raw values, kept here as a separate closed set.
package enum ControlLifecycleLogFlushSource: String, Codable, Sendable, Equatable, CaseIterable {
    case host
    case app
}

/// Wire spelling of how an unconfirmed logger drain ended. A separate closed set with no `drained`, so a reader refuses one.
package enum ControlLifecycleLogFlushOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case timedOut = "timed_out"
    case busy
    case skippedBudget = "skipped_budget"
    case cancelled
    case unavailable
}

/// Wire spelling of one module Start settlement: an explicit member with its result, or the conditional DNS companion with its own. The
/// module reuses the control contract's `ControlModule`; the results are separate closed sets with the domain's raw values.
package enum ControlLifecycleSettlement: Sendable, Equatable {
    case explicit(ControlModule, ControlLifecycleModuleResult)
    case conditionalDNS(ControlLifecycleConditionalDNSResult)

    package var module: ControlModule {
        switch self {
        case .explicit(let module, _): module
        case .conditionalDNS: .dns
        }
    }

    package var source: String {
        switch self {
        case .explicit: "explicit"
        case .conditionalDNS: "conditional"
        }
    }

    package var outcome: String {
        switch self {
        case .explicit(_, let result): result.rawValue
        case .conditionalDNS(let result): result.rawValue
        }
    }
}

/// Wire spelling of an explicit member's result.
package enum ControlLifecycleModuleResult: String, Codable, Sendable, Equatable, CaseIterable {
    case started
    case notConfigured = "not_configured"
    case failed
    case superseded
}

/// Wire spelling of the conditional DNS companion's result.
package enum ControlLifecycleConditionalDNSResult: String, Codable, Sendable, Equatable, CaseIterable {
    case started
    case fenced
    case notConfigured = "not_configured"
    case alreadyActive = "already_active"
    case superseded
    case failed
}

/// Wire spelling of a lifecycle operation: the same raw values as the domain's,
/// kept here as a separate closed set.
package enum ControlLifecycleOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case proxyStart = "proxy_start"
    case proxyStop = "proxy_stop"
    case dnsStart = "dns_start"
    case dnsStop = "dns_stop"
    case runtimeStart = "runtime_start"
    case runtimeStop = "runtime_stop"
    case tunnelsStart = "tunnels_start"
    case tunnelsStop = "tunnels_stop"
}

/// Wire spelling of a supersession reason.
package enum ControlLifecycleReason: String, Codable, Sendable, Equatable, CaseIterable {
    case superseded
    case runtimeDown = "runtime_down"
}
