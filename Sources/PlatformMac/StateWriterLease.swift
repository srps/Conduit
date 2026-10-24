// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation

/// Exclusive writer authority over one canonical state root (decisions 0017 and
/// 0020). The authority is an OS advisory lock on a fixed file in the root. It
/// is not a PID file or a content hash: the lock file holds no bytes and is
/// never unlinked or replaced while the root is in use, so it keeps its inode
/// when the data files beside it are replaced atomically.
///
/// Acquisition never waits. The OS adapter makes blocking `open`, `flock`,
/// `fstat` and `close` calls, so callers run it off the MainActor, on
/// `PlatformWork` or another worker. Nothing here is a RuntimeEvent: callers
/// decide the event from the typed outcome.
package protocol StateWriterLeasing: Sendable {
    /// `onReleaseFailure` receives a close that could not be confirmed when a
    /// lease is dropped without an explicit `release()`. It is the only place
    /// that failure can go, so the destructor never swallows it.
    func acquire(
        root: CanonicalStateRoot,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void
    ) -> StateWriterAcquisition
}

package enum StateWriterAcquisition: Sendable {
    case acquired(StateWriterLease)
    /// Another holder has the root. The caller must not migrate, reconcile or
    /// write anything under it.
    case busy
    case failed(StateWriterFailure)
}

/// An acquisition that did not produce a lease. Each case names the step that
/// failed; `closeFailed` also covers a close that failed after a busy or failed
/// attempt, so that failure is never hidden behind the attempt's own outcome.
package enum StateWriterFailure: Error, Equatable, Sendable {
    case lockOpenFailed(errno: Int32)
    case lockFailed(errno: Int32)
    case lockNotRegularFile
    /// The path no longer names the inode that was locked.
    case lockReplaced
    case statFailed(errno: Int32)
    /// The descriptor of a refused attempt could not be closed. Its lock state
    /// is unknown, and close(2) is not retried.
    case closeFailed(errno: Int32)
}

package enum StateWriterRelease: Sendable, Equatable {
    /// close(2) returned 0 for the lease's descriptor.
    case released
    /// close(2) reported an error or was interrupted. That is not proof the
    /// lock is gone, and close is not retried: the descriptor number may
    /// already be reused. Every later release of the same lease returns this
    /// same outcome.
    case releaseUnknown(errno: Int32)
    /// A later release after a confirmed `.released`. A release that followed
    /// an unconfirmed close never returns this.
    case alreadyReleased
}

package struct StateWriterReleaseFailure: Error, Equatable, Sendable {
    package let root: CanonicalStateRoot
    package let errno: Int32
}

/// One held lease. The descriptor is closed exactly once: by `release()`, or
/// by the destructor when the holder drops a lease it has not released.
///
/// Close is synchronous. `release()` runs it on the calling thread, so call it
/// from a worker, never the MainActor, as with `acquire`. A call made while
/// another release is in flight waits for that close and returns its outcome;
/// no call retries the close. The close runs outside the lock and must not call
/// back into this lease.
///
/// Holding a lease is not proof that writes have quiesced. Keeping it until
/// queued and started writes finish is an obligation of the future store.
package final class StateWriterLease: @unchecked Sendable {
    package let root: CanonicalStateRoot
    private let lock = NSLock()
    /// Entered when the one close starts and left once its outcome is recorded,
    /// so a concurrent release waits for that outcome instead of inventing one.
    private let closeInFlight = DispatchGroup()
    private var phase: Phase
    private let onReleaseFailure: @Sendable (StateWriterReleaseFailure) -> Void

    private enum Phase {
        case open(@Sendable () -> StateWriterRelease)
        case closing
        case settled(StateWriterRelease)
    }

    init(
        root: CanonicalStateRoot,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void,
        close: @escaping @Sendable () -> StateWriterRelease
    ) {
        self.root = root
        self.onReleaseFailure = onReleaseFailure
        phase = .open(close)
    }

    /// The first call closes the lease. A later call returns the same unconfirmed
    /// failure, or `.alreadyReleased` after a confirmed close, and touches nothing.
    package func release() -> StateWriterRelease {
        if let close = beginClose() {
            return finish(close())
        }
        closeInFlight.wait()
        return lock.withLock { Self.repeatOutcome(phase) }
    }

    /// Moves `open` to `closing` and hands back its close. Returns nil when the
    /// lease is already closing or settled, so exactly one caller closes it.
    private func beginClose() -> (@Sendable () -> StateWriterRelease)? {
        lock.withLock { () -> (@Sendable () -> StateWriterRelease)? in
            guard case .open(let close) = phase else { return nil }
            phase = .closing
            closeInFlight.enter()
            return close
        }
    }

    /// Records the one outcome, then wakes the callers waiting on it.
    private func finish(_ outcome: StateWriterRelease) -> StateWriterRelease {
        lock.withLock { phase = .settled(outcome) }
        closeInFlight.leave()
        return outcome
    }

    /// What a call after the close started returns. A confirmed close stays
    /// `alreadyReleased`. An unconfirmed one is returned again, never as released.
    private static func repeatOutcome(_ phase: Phase) -> StateWriterRelease {
        if case .settled(.releaseUnknown(let errno)) = phase { return .releaseUnknown(errno: errno) }
        return .alreadyReleased
    }

    deinit {
        // Only a lease nobody released is closed here. An explicit release has
        // already returned its unconfirmed outcome to the caller, so it is not
        // reported a second time.
        guard let close = beginClose() else { return }
        if case .releaseUnknown(let errno) = finish(close()) {
            onReleaseFailure(StateWriterReleaseFailure(root: root, errno: errno))
        }
    }
}
