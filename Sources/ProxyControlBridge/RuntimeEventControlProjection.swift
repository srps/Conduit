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
        case .configWorkflow(let event):
            self = .configWorkflow(ControlConfigWorkflowEvent(event))
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
        case .tunnelsStart: self = .tunnelsStart
        case .tunnelsStop: self = .tunnelsStop
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

extension ControlConfigWorkflowEvent {
    package init(_ event: ConfigurationWorkflowEvent) {
        switch event {
        case .observed(let observed):
            self = .observed(
                phase: ControlConfigWorkflowObservationPhase(observed.phase),
                observation: ControlConfigWorkflowObservation(observed.observation)
            )
        case .committed(let committed):
            self = .committed(file: ControlConfigWorkflowFile(committed.file), write: ControlConfigWorkflowWrite(committed.write))
        case .held(let held):
            self = .held(
                phase: ControlConfigWorkflowIntentPhase(held.phase),
                input: ControlConfigWorkflowHeldInput(held.input),
                reason: ControlConfigWorkflowHoldReason(held.reason)
            )
        case .superseded(let superseded):
            self = .superseded(
                phase: ControlConfigWorkflowIntentPhase(superseded.phase),
                generation: superseded.generation,
                current: superseded.current
            )
        }
    }
}

extension ControlConfigWorkflowFile {
    package init(_ file: ConfigurationWorkflowFile) {
        switch file {
        case .runtime: self = .runtime
        case .platform: self = .platform
        case .preferences: self = .preferences
        }
    }
}

extension ControlConfigWorkflowHeldInput {
    package init(_ input: ConfigurationWorkflowHeldInput) {
        switch input {
        case .unit: self = .unit
        case .runtime: self = .runtime
        case .platform: self = .platform
        }
    }
}

extension ControlConfigWorkflowObservationPhase {
    package init(_ phase: ConfigurationWorkflowObservationPhase) {
        switch phase {
        case .startup: self = .startup
        case .reload: self = .reload
        }
    }
}

extension ControlConfigWorkflowIntentPhase {
    package init(_ phase: ConfigurationWorkflowIntentPhase) {
        switch phase {
        case .start: self = .start
        case .reload: self = .reload
        case .stop: self = .stop
        }
    }
}

extension ControlConfigWorkflowObservation {
    package init(_ observation: ConfigurationWorkflowObservation) {
        switch observation {
        case .adopted: self = .adopted
        case .refused(let refusal): self = .refused(ControlConfigWorkflowRefusal(refusal))
        }
    }
}

extension ControlConfigWorkflowRefusal {
    package init(_ refusal: ConfigurationWorkflowRefusal) {
        switch refusal {
        case .unreadable(let file): self = .unreadable(ControlConfigWorkflowFile(file))
        case .versionExhausted(let file): self = .versionExhausted(ControlConfigWorkflowFile(file))
        case .invalidContent: self = .invalidContent
        case .journalPresenceUnknown: self = .journalPresenceUnknown
        case .unexpected: self = .unexpected
        case .busy: self = .busy
        }
    }
}

extension ControlConfigWorkflowWrite {
    package init(_ write: ConfigurationWorkflowWrite) {
        switch write {
        case .persisted(let reportedError): self = .persisted(reportedError: reportedError)
        case .unchanged: self = .unchanged
        case .notPersisted: self = .notPersisted
        case .unknown(let cause, let reportedError):
            self = .unknown(ControlConfigWorkflowUnknownCause(cause), reportedError: reportedError)
        case .conflict: self = .conflict
        case .notAttempted(let cause): self = .notAttempted(ControlConfigWorkflowNotAttemptedCause(cause))
        }
    }
}

extension ControlConfigWorkflowUnknownCause {
    package init(_ cause: ConfigurationWorkflowUnknownCause) {
        switch cause {
        case .readbackDiffers: self = .readbackDiffers
        case .readbackMissing: self = .readbackMissing
        case .readbackFailed: self = .readbackFailed
        }
    }
}

extension ControlConfigWorkflowNotAttemptedCause {
    package init(_ cause: ConfigurationWorkflowNotAttemptedCause) {
        switch cause {
        case .noBaseline: self = .noBaseline
        case .baselineMismatch: self = .baselineMismatch
        case .stagingRefused: self = .stagingRefused
        case .preReadFailed: self = .preReadFailed
        case .replacementRefused: self = .replacementRefused
        case .heldBehindPlatform: self = .heldBehindPlatform
        case .heldBehindRuntime: self = .heldBehindRuntime
        case .preservationHeld: self = .preservationHeld
        case .sourceChanged: self = .sourceChanged
        case .sourceUnreadable: self = .sourceUnreadable
        case .versionExhausted: self = .versionExhausted
        case .superseded: self = .superseded
        }
    }
}

extension ControlConfigWorkflowHoldReason {
    package init(_ reason: ConfigurationWorkflowHoldReason) {
        switch reason {
        case .startBlocking: self = .startBlocking
        case .uncommitted: self = .uncommitted
        case .stopFenced: self = .stopFenced
        case .commitFailed: self = .commitFailed
        case .heldBehind: self = .heldBehind
        case .intentExhausted: self = .intentExhausted
        case .terminating: self = .terminating
        case .inputReplaced: self = .inputReplaced
        case .stopSaveOwed: self = .stopSaveOwed
        case .storeBusy: self = .storeBusy
        case .staleRevision: self = .staleRevision
        }
    }
}
