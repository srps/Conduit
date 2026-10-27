// SPDX-License-Identifier: Apache-2.0
import Foundation

// The preconditions an editor update carries (decisions 0015, 0018 and 0027): one exact store baseline per file it
// writes, and one lifecycle intent per runtime module. They hold identifiers, versions and closed cases only, never a
// configuration value, so their reflection is not redacted. Like the values beside them, they are not `Codable`: only
// the private codec writes or reads them.

package enum PrivateBaselineNamespaceDomain: ControlIdentityDomain {}

/// The configuration store incarnation a baseline belongs to. It is a different family from `ControlHostIncarnation`: a
/// host and its store are separate authorities, and a baseline from one store incarnation never authorizes a write in
/// another.
package typealias PrivateBaselineNamespace = ControlIdentifier<PrivateBaselineNamespaceDomain>

/// The wire form of one store baseline: the store incarnation, the file and the exact version the store issued for it.
///
/// It is a precondition the caller observed, not authority. Only the store mints a baseline token. A decoded baseline is
/// compared with the store's own, and the store decides. The version is the store's full `UInt64`; it is never narrowed to
/// a control ordinal, and the wire carries it as an exact unsigned decimal.
package struct PrivateBaseline: Sendable, Hashable, CustomStringConvertible {
    package let namespace: PrivateBaselineNamespace
    package let component: ControlConfigWorkflowFile
    package let version: UInt64

    package init(namespace: PrivateBaselineNamespace, component: ControlConfigWorkflowFile, version: UInt64) {
        self.namespace = namespace
        self.component = component
        self.version = version
    }

    package var description: String {
        "PrivateBaseline(\(component.rawValue) v\(version) in \(namespace))"
    }
}

/// One value per runtime module, in a fixed shape: no array, no count rule and no duplicate module.
package struct PrivateModuleSlots<Value: Sendable>: Sendable {
    package var proxy: Value
    package var dns: Value
    package var tunnels: Value

    package init(proxy: Value, dns: Value, tunnels: Value) {
        self.proxy = proxy
        self.dns = dns
        self.tunnels = tunnels
    }

    package subscript(module: ControlModule) -> Value {
        get {
            switch module {
            case .proxy: proxy
            case .dns: dns
            case .tunnels: tunnels
            }
        }
        set {
            switch module {
            case .proxy: proxy = newValue
            case .dns: dns = newValue
            case .tunnels: tunnels = newValue
            }
        }
    }
}

extension PrivateModuleSlots: Equatable where Value: Equatable {}

/// What one update asks of one module once its values persist, under the selected per-module intent and fence policy.
/// Each case is distinct, and none is implied by another. Stop is not here: an urgent Stop stays an ordinary command,
/// with its own capacity, and never waits behind a private body.
package enum PrivateModuleIntent: Sendable, Equatable {
    /// An ordinary knob save. It persists and changes no lifecycle state: on its own it applies nothing, never clears a
    /// Stop fence and never enables a stopped module. The runtime has one applied input (decisions 0025 and 0037), so when
    /// another slot of the same request starts or applies, the one verified pair reaches every running module, this one
    /// included: its values are then applied, not only saved.
    case saveOnly
    /// It persists, then applies only while the module is still running under this lifecycle revision. It never clears a
    /// Stop fence and never enables a stopped module.
    case applyWhileRunning(ifLifecycleRevision: ControlLifecycleRevision)
    /// An explicit enable with these frozen values. It persists them, then starts the module from the verified pair. Only
    /// a Start that is still current, with its revision matching and no newer Start or Stop, may clear the module's fence.
    case start(ifLifecycleRevision: ControlLifecycleRevision)
}
