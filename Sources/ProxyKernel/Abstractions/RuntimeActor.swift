// SPDX-License-Identifier: Apache-2.0

/// The isolation of the runtime control cluster: the orchestrator, its lifecycles, the reconciler and lanes, and the host with its store,
/// workflow and control service (decision 0031). UI and AppKit stay on the main actor, NIO state on its event loops, and blocking work on
/// `PlatformWork` and the bounded writer queues.
///
/// It is an isolation domain only. It holds no state, is not a dedicated thread or executor, and grants no authority: each host keeps its
/// own resources and tokens, and the state root's lease is what makes one process the writer.
@globalActor
package actor RuntimeActor {
    package static let shared = RuntimeActor()

    private init() {}
}
