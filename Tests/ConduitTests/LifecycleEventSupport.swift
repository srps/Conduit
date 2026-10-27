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

    var settledValues: [LifecycleModuleSettled] {
        lifecycleValues.compactMap { value -> LifecycleModuleSettled? in
            guard case .moduleSettled(let settled) = value else { return nil }
            return settled
        }
    }
}

extension LifecycleModuleSettlement {
    /// Every settlement the closed sets can spell, valid or not: each module with each member result, and each companion result.
    static let everySpelling: [LifecycleModuleSettlement] =
        LifecycleModule.allCases.flatMap { module in LifecycleModuleStartResult.allCases.map { .explicit(module, $0) } }
        + LifecycleConditionalDNSResult.allCases.map { .conditionalDNS($0) }
}
