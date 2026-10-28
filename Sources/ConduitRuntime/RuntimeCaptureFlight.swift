// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// A frozen, pure projection of one collection: the owner takes its input in the owner turn whose snapshot named the revision and total,
/// and the job touches no owner state, so it runs off the owner. It is async so a test owner can suspend inside it without holding a
/// thread; production does synchronous CPU work inside it.
typealias RuntimeRowSource = @Sendable (ControlRowBudget) async -> ControlProjection

/// What a page parked on the capture flight is answered with once the flight ends.
enum RuntimeCaptureResolution: Sendable {
    /// The flight committed this page's own kind: the page is answered as a request for that capture's revision.
    case revision(ControlCollectionRevision)
    /// The flight ended with a closed refusal for this page's own kind, answered once.
    case refused(ControlCollectionUnavailableReason, knownTotal: ControlCount?)
    /// The flight ended with a closed internal failure for this page's own kind, answered once.
    case failed
    /// Another kind's flight ended, or capture closed at shutdown: the page reads again from the start.
    case retry
}

/// One page parked on the capture flight. Each belongs to one read-lane round, so the waits a flight holds are bounded by the read lane.
@RuntimeActor
final class RuntimeCaptureWait {
    let token = RuntimeWaiterToken()
    let kind: ControlCollectionKind
    fileprivate(set) var resolution: RuntimeCaptureResolution?
    /// The parked gate's wake, set when the round parks, in the same owner turn that created this wait.
    fileprivate var wake: (@Sendable () -> Void)?

    init(kind: ControlCollectionKind) {
        self.kind = kind
    }
}

/// The service's one capture in progress, across all kinds: the input its start turn froze, and the pages waiting for it to end. One flight
/// keeps at most one capture's rows outside the ledger at a time, which is the one capture staging term `RuntimeServiceLimits` charges
/// beside the retained rows. Commits follow start order, so the ledger's captures stay ordered by their start instants. Its identity is
/// the object's own.
@RuntimeActor
final class RuntimeCaptureFlight {
    let kind: ControlCollectionKind
    let revision: ControlCollectionRevision
    let total: ControlCount
    /// The start turn's instant. The capture's age is measured from it, not from the commit.
    let startedAt: ContinuousClock.Instant
    private(set) var waits: [RuntimeCaptureWait] = []

    init(kind: ControlCollectionKind, revision: ControlCollectionRevision, total: ControlCount, startedAt: ContinuousClock.Instant) {
        self.kind = kind
        self.revision = revision
        self.total = total
        self.startedAt = startedAt
    }

    func add(_ wait: RuntimeCaptureWait) {
        waits.append(wait)
    }

    func contains(_ wait: RuntimeCaptureWait) -> Bool {
        waits.contains { $0 === wait }
    }

    /// Sets the parked gate's wake on a wait this flight holds. False when the flight no longer holds it.
    func park(_ wait: RuntimeCaptureWait, wake: @escaping @Sendable () -> Void) -> Bool {
        guard contains(wait), wait.resolution == nil else { return false }
        wait.wake = wake
        return true
    }

    /// Removes the wait named by `token`, if this flight holds it. A token of another flight changes nothing.
    func release(_ token: RuntimeWaiterToken) {
        waits.removeAll { $0.token == token }
    }

    /// Resolves every wait, its own kind with `own` and every other kind with `retry`, and takes the wakes out. The flight holds no wait
    /// after this, and the caller wakes them once its own state is complete.
    func end(own: RuntimeCaptureResolution) -> [@Sendable () -> Void] {
        var wakes: [@Sendable () -> Void] = []
        for wait in waits {
            wait.resolution = wait.kind == kind ? own : .retry
            if let wake = wait.wake { wakes.append(wake) }
            wait.wake = nil
        }
        waits = []
        return wakes
    }
}
