// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// The advisory `flock(2)` lease on `state-writer.lock` inside a canonical
/// root. Synchronous: call it off the MainActor.
///
/// Release is a single `close(2)` with no `LOCK_UN`. The lock belongs to the
/// open file description, so it lasts while any copy of the descriptor stays
/// open. An explicit unlock would drop it while such a copy still exists. The
/// descriptor is close-on-exec, so an exec'd child never keeps the lock.
package struct OSStateWriterLeasing: StateWriterLeasing {
    /// The fixed name of the root's lock file. It is opened with O_NOFOLLOW,
    /// never unlinked, never replaced and never written.
    package static let lockFileName = "state-writer.lock"

    package init() {}

    package func acquire(
        root: CanonicalStateRoot,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void
    ) -> StateWriterAcquisition {
        let path = root.path + "/" + Self.lockFileName
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failed(.lockOpenFailed(errno: errno)) }

        // LOCK_NB: a held lock is reported as busy, never waited for.
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            let refusal: StateWriterAcquisition = code == EWOULDBLOCK ? .busy : .failed(.lockFailed(errno: code))
            return discard(descriptor, keeping: refusal)
        }

        // The locked descriptor must still be the file the path names. A
        // replaced lock file would give two leases on two different inodes.
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            return discard(descriptor, keeping: .failed(.statFailed(errno: errno)))
        }
        guard opened.st_mode & S_IFMT == S_IFREG else {
            return discard(descriptor, keeping: .failed(.lockNotRegularFile))
        }
        var named = stat()
        guard lstat(path, &named) == 0 else {
            return discard(descriptor, keeping: .failed(.statFailed(errno: errno)))
        }
        guard named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            return discard(descriptor, keeping: .failed(.lockReplaced))
        }

        return .acquired(StateWriterLease(root: root, onReleaseFailure: onReleaseFailure) {
            Self.closeHeld(descriptor)
        })
    }

    /// Closes the descriptor of an attempt that did not produce a lease. A close
    /// failure replaces the attempt's outcome: the refusal still stands, and the
    /// descriptor's state is unknown.
    private func discard(_ descriptor: Int32, keeping refusal: StateWriterAcquisition) -> StateWriterAcquisition {
        guard Darwin.close(descriptor) == 0 else { return .failed(.closeFailed(errno: errno)) }
        return refusal
    }

    /// Called at most once per lease, so a failure is reported and never retried.
    private static func closeHeld(_ descriptor: Int32) -> StateWriterRelease {
        guard Darwin.close(descriptor) == 0 else { return .releaseUnknown(errno: errno) }
        return .released
    }
}
