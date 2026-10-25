// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// The owner's synchronous answer to one command. The owner records its own fence here, and it starts no
/// effect. Every newly received Stop reaches the owner, including one that would coalesce, because the owner
/// alone decides whether the candidate stop is still the current session fence.
enum ControlOwnerFenceResult: Sendable, Equatable {
    /// The owner fenced the offered operation as the current one. The pending candidate of the same module, if any,
    /// is settled as superseded by it. A queued candidate is dropped unstarted, and a running one keeps its slot
    /// until it quiesces, so the new operation launches only after that.
    case admitted
    /// The owner keeps the pending candidate as the current operation. The service joins the request to it.
    case joinedCandidate
    case rejected(ControlRejectionCode)
}

/// The projected rows of one collection, from the owner's current turn. The count and encoded bytes are
/// bounded by the service, which refuses an over-budget capture instead of truncating it.
enum ControlProjectedRows: Sendable {
    case activeConnections([ControlConnectionRow])
    case upstreamHealth([ControlUpstreamRow])
    case tunnelBindings([ControlTunnelBindingRow])
    case tunnelDNSHosts([ControlTunnelDNSHostRow])

    var kind: ControlCollectionKind {
        switch self {
        case .activeConnections: .activeConnections
        case .upstreamHealth: .upstreamHealth
        case .tunnelBindings: .tunnelBindings
        case .tunnelDNSHosts: .tunnelDNSHosts
        }
    }
}

/// The owner's two reports for one launched effect. `settled` is the logical outcome. `quiesced` is the physical fact
/// that the owner has no work left for the operation. Both are idempotent, and the first settlement is the one that
/// counts. `quiesced` may arrive without `settled`, and the service then closes the operation as an internal failure.
/// A report may only be used after its effect was launched, and it changes nothing once the operation has closed.
@MainActor
struct ControlEffectReport {
    let settled: @MainActor (ControlOperationOutcome) -> Void
    let quiesced: @MainActor () -> Void
}

/// A closed fault the service reports to the owner, which is the canonical producer of diagnostics. Each case names the site
/// that failed. A fault carries no command body, no payload and no error text, so it cannot leak what the service held.
enum ControlServiceFault: Sendable, Equatable {
    /// A command that the service was given could not be encoded. Nothing was recorded, and nothing reached the fence.
    case submitCommandNotEncodable
    /// An operation outcome could not be encoded. The measured internal failure stands in for it in the lookup and the control log.
    case outcomeNotEncodable
}

/// The one owner of intent and lifecycle, seen from the service. The actual runtime host adopts this
/// later, and it must fix Stop-before-recovery admission before it does. A fake owner in tests proves
/// the service's contract, not the host's fence.
@MainActor
protocol ControlCommandOwner: AnyObject {
    var incarnation: ControlHostIncarnation { get }

    /// The current safe projected state. It is captured in the same owner turn as the caller's registration.
    func snapshot() -> ControlRuntimeSnapshot

    /// The projected rows of one collection, in the same owner turn as the snapshot that names its revision.
    func projectedRows(for kind: ControlCollectionKind) -> ControlProjectedRows

    /// Synchronous admission and fence. `candidate` is the pending stop of the same module, when one exists.
    /// It starts no effect and calls no report.
    func fence(
        _ command: ControlRuntimeCommand,
        operation: ControlOperationID,
        candidate: ControlOperationID?
    ) -> ControlOwnerFenceResult

    /// A closed fault the service detected. The owner decides how it is diagnosed. The service never waits on the answer.
    func serviceFault(_ fault: ControlServiceFault)

    /// Launches the effect of one admitted operation. The service calls it once per launch, in a later owner turn, and
    /// the operation's record is final before the call. The command is handed over here, and the service releases its own
    /// copy at this launch. A queued operation holds its command only until it launches or is dropped, and that is bounded
    /// by the queue capacities. The owner reports through `report`.
    func startEffect(
        _ command: ControlRuntimeCommand,
        operation: ControlOperationID,
        report: ControlEffectReport
    )
}
