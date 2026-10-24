// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import RuntimeEvents
import ConduitShared

// Maps the kernel's runtime events onto the control wire's projection (decision
// 0013). Every switch is exhaustive over the domain values and has no default:
// a new operation, reason or lifecycle case fails to compile here until its wire
// shape is chosen.

extension ControlRuntimeEvent {
    package init(_ event: RuntimeEvent) {
        self.init(
            timestamp: event.timestamp,
            kind: event.kind.rawValue,
            event: event.event,
            detail: event.detail,
            typed: event.typed.map { ControlTypedRuntimeEvent($0) }
        )
    }
}

extension ControlTypedRuntimeEvent {
    package init(_ payload: RuntimeEventPayload) {
        switch payload {
        case .lifecycle(let event):
            self = .lifecycle(ControlLifecycleEvent(event))
        }
    }
}

extension ControlLifecycleEvent {
    package init(_ event: LifecycleEvent) {
        switch event {
        case .superseded(let superseded):
            self = .superseded(
                operation: ControlLifecycleOperation(superseded.operation),
                generation: superseded.generation,
                current: superseded.current,
                reason: ControlLifecycleReason(superseded.reason)
            )
        case .coalesced(let coalesced):
            self = .coalesced(
                operation: ControlLifecycleOperation(coalesced.operation),
                joined: coalesced.joined
            )
        case .terminationDrainExpired(let expired):
            self = .terminationDrainExpired(deadlineMilliseconds: expired.deadlineMilliseconds)
        case .versionChanged(let changed):
            self = .versionChanged(from: changed.from, to: changed.to)
        }
    }
}

extension ControlLifecycleOperation {
    package init(_ operation: LifecycleOperation) {
        switch operation {
        case .proxyStart: self = .proxyStart
        case .proxyStop: self = .proxyStop
        case .dnsStart: self = .dnsStart
        case .dnsStop: self = .dnsStop
        case .runtimeStart: self = .runtimeStart
        case .runtimeStop: self = .runtimeStop
        }
    }
}

extension ControlLifecycleReason {
    package init(_ reason: LifecycleSupersessionReason) {
        switch reason {
        case .superseded: self = .superseded
        case .runtimeDown: self = .runtimeDown
        }
    }
}
