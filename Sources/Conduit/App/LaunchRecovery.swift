// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Launch-time crash recovery for the platform surfaces a `SIGKILL` can strand,
/// run off the calling actor and joined before anything else touches them.
///
/// Two properties, and the type exists because they pull in opposite directions.
///
/// **It must not run inline.** `SystemDNSManager.restoreIfNeeded` waits up to
/// two seconds for a resolver to answer on `127.0.0.1:53` and then reads
/// `networksetup -getdnsservers` for every service;
/// `SystemProxyManager.restoreIfNeeded` spawns roughly four `networksetup`
/// subprocesses per service before it decides anything. Its caller is
/// `AppState.init`, which is `@MainActor` and runs before the menu bar exists —
/// so run inline that work is several seconds during which the app is on screen
/// nowhere and answering nothing. None of it needs the main actor: both
/// managers are `Sendable` and talk only to subprocesses, sockets and the
/// journal file.
///
/// **It must still happen first.** Recovery restores the *previous* session's
/// settings, so it cannot be left to land whenever. A `clear()` arriving after
/// a `startProxy()` apply puts the crashed session's settings back over the
/// ones the user just asked for; an `apply()` arriving first makes recovery's
/// own probe find our new listener and conclude nothing is orphaned, so the
/// crash it exists to repair goes unrepaired. `join()` is how the ordering the
/// inline version got for free survives the move: every path that touches a
/// platform surface awaits it before doing so.
@MainActor
final class LaunchRecovery {
    /// Dropped once joined, so the second and later `join()`s cost nothing and
    /// the closure's captures do not outlive the recovery.
    private var task: Task<Void, Never>?

    /// Starts `work` immediately on a detached background task.
    ///
    /// Detached rather than `Task { }`: a plain `Task` created in a `@MainActor`
    /// context inherits that isolation and would run the whole thing back on the
    /// main actor, which is the freeze this type exists to remove.
    init(work: @escaping @Sendable () -> Void) {
        task = Task.detached(priority: .utility, operation: work)
    }

    /// Waits for recovery to finish. Returns immediately once it has.
    func join() async {
        guard let task else { return }
        await task.value
        self.task = nil
    }
}
