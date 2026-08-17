// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import Conduit

/// `AppState.init` is `@MainActor` and runs before the menu bar exists, and the
/// two `restoreIfNeeded` calls it starts block on a 2 s DNS probe and on several
/// `networksetup` subprocesses per network service. These pin the two halves of
/// the seam that keeps that off the main actor without losing its ordering.
final class LaunchRecoveryTests: XCTestCase {

    /// The freeze. Run inline from a `@MainActor` initialiser, launch-time
    /// recovery is seconds of an app that is on screen nowhere and answering
    /// nothing.
    @MainActor
    func testRecoveryDoesNotRunOnTheMainThread() async {
        let ranOnMainThread = NIOLockedValueBox(true)

        let recovery = LaunchRecovery {
            ranOnMainThread.withLockedValue { $0 = Thread.isMainThread }
        }
        await recovery.join()

        XCTAssertFalse(
            ranOnMainThread.withLockedValue { $0 },
            "launch recovery blocks on networksetup subprocesses and a 2 s DNS probe; "
                + "on the main thread that is the app frozen before its UI exists"
        )
    }

    /// The other half. Recovery restores the *previous* session's settings, so
    /// a `startProxy` that overtook it would have its own settings restored
    /// away — moving the work off the main actor may not also make it unordered.
    @MainActor
    func testJoinReturnsOnlyAfterRecoveryHasFinished() async {
        let finished = NIOLockedValueBox(false)

        let recovery = LaunchRecovery {
            Thread.sleep(forTimeInterval: 0.1)
            finished.withLockedValue { $0 = true }
        }
        await recovery.join()

        XCTAssertTrue(
            finished.withLockedValue { $0 },
            "join() is what every platform-surface caller relies on to be second"
        )
    }

    /// `awaitLaunchRecovery()` sits at the head of `startProxy`, `stopProxy`,
    /// `startDNS` and `stopDNS`, so it is called on every lifecycle transition
    /// for the life of the process, not once.
    @MainActor
    func testJoinIsIdempotentAndRunsTheWorkOnce() async {
        let runs = NIOLockedValueBox(0)

        let recovery = LaunchRecovery {
            runs.withLockedValue { $0 += 1 }
        }
        await recovery.join()
        await recovery.join()
        await recovery.join()

        XCTAssertEqual(runs.withLockedValue { $0 }, 1)
    }
}
