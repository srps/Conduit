// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation

/// The system wake notification, behind a protocol so a host never names AppKit. `start` is called once, when a host opens, and `stop`
/// once, when it quits; a stop drops the callback, so no wake is delivered after it. The callback runs on whatever thread the source
/// posts on and must only hop: the host delivers it onto its own actor. Production's app composition passes
/// `WorkspaceSystemWakeObserver`; the daemon passes `InertSystemWakeObserver`, and a test or simulator `FakeSystemWakeObserver`.
package protocol SystemWakeObserving: Sendable {
    func start(onWake: @escaping @Sendable () -> Void)
    func stop()
}

/// Observes nothing. The daemon's adapter: it has no workspace session to hear a wake from.
package struct InertSystemWakeObserver: SystemWakeObserving {
    package init() {}
    package func start(onWake: @escaping @Sendable () -> Void) {}
    package func stop() {}
}

/// `NSWorkspace.didWakeNotification`, as `AppState` observes it today. One registration at a time: a second `start` keeps the first.
package final class WorkspaceSystemWakeObserver: SystemWakeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    package init() {}

    package func start(onWake: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard token == nil else { return }
            token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { _ in onWake() }
        }
    }

    package func stop() {
        let removed = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let removed { NSWorkspace.shared.notificationCenter.removeObserver(removed) }
    }
}
