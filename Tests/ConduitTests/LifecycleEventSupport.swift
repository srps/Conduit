// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import RuntimeEvents

/// Typed views of a runtime event log for the lifecycle assertions. Harness
/// tests match these values rather than detail strings. A golden detail check
/// stays only where it pins the human line, which operators read (decision 0013).
extension Array where Element == RuntimeEvent {
    var lifecycleValues: [LifecycleEvent] {
        compactMap { event -> LifecycleEvent? in
            guard case .lifecycle(let value)? = event.typed else { return nil }
            return value
        }
    }

    var supersededValues: [LifecycleSuperseded] {
        lifecycleValues.compactMap { value -> LifecycleSuperseded? in
            guard case .superseded(let superseded) = value else { return nil }
            return superseded
        }
    }

    var coalescedValues: [LifecycleCoalesced] {
        lifecycleValues.compactMap { value -> LifecycleCoalesced? in
            guard case .coalesced(let coalesced) = value else { return nil }
            return coalesced
        }
    }
}
