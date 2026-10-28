// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// One queued unit of owner work. It runs on `RuntimeActor`, in a later turn than the call that queued it.
typealias RuntimeOwnerHop = @RuntimeActor @Sendable () -> Void

/// Queues owner hops for the service, the transport and the ingress. It is the one seam for owner dispatch, separate
/// from the clock. The scheduler keeps no count: each caller bounds what it queues through its own reservation, so a
/// hop never waits without a reserved slot behind it. It is callable from any thread.
protocol RuntimeOwnerScheduling: Sendable {
    func hop(_ work: @escaping RuntimeOwnerHop)
}

/// The production scheduler: each hop is one owner task.
struct TaskOwnerScheduling: RuntimeOwnerScheduling {
    func hop(_ work: @escaping RuntimeOwnerHop) {
        Task { @RuntimeActor in work() }
    }
}
