// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
import PlatformMac
import ProxyKernel

/// The shared host builds its launch recovery in its `@RuntimeActor` initialiser, and
/// the two `restoreIfNeeded` calls it starts block on a 2 s DNS probe and on several
/// `networksetup` subprocesses per network service. These pin the two halves of
/// the seam that keeps that off the owner without losing its ordering, and
/// the worker it runs on.
final class LaunchRecoveryTests: XCTestCase {
    private static let workLabel = "io.github.srps.Conduit.launch-recovery-tests.platform-work"
    private let work = PlatformWork(label: LaunchRecoveryTests.workLabel)

    /// The freeze. Run inline from the host's initialiser, launch-time
    /// recovery is seconds of an app that is on screen nowhere and answering
    /// nothing.
    @RuntimeActor
    func testRecoveryDoesNotRunOnTheMainThread() async {
        let ranOnMainThread = NIOLockedValueBox(true)

        let recovery = LaunchRecovery(on: work) {
            ranOnMainThread.withLockedValue { $0 = Thread.isMainThread }
        }
        await recovery.join()

        XCTAssertFalse(
            ranOnMainThread.withLockedValue { $0 },
            "launch recovery blocks on networksetup subprocesses and a 2 s DNS probe; "
                + "on the main thread that is the app frozen before its UI exists"
        )
    }

    /// Nor on the concurrency pool, where seconds of blocking take a thread from every task and actor: it runs on the worker it is
    /// given, which for the host is its one platform queue.
    @RuntimeActor
    func testRecoveryRunsOnTheGivenWorkerAndNotOnThePool() async {
        let label = NIOLockedValueBox("")

        let recovery = LaunchRecovery(on: work) {
            label.withLockedValue { $0 = HeldCall.currentQueueLabel() }
        }
        await recovery.join()

        let ranOn = label.withLockedValue { $0 }
        XCTAssertEqual(ranOn, Self.workLabel)
        XCTAssertFalse(HeldCall.isCooperativePool(ranOn), "launch recovery ran on \(ranOn)")
    }

    /// The other half. Recovery restores the *previous* session's settings, so
    /// a `startProxy` that overtook it would have its own settings restored
    /// away — moving the work off the owner may not also make it unordered.
    @RuntimeActor
    func testJoinReturnsOnlyAfterRecoveryHasFinished() async {
        let finished = NIOLockedValueBox(false)

        let recovery = LaunchRecovery(on: work) {
            Thread.sleep(forTimeInterval: 0.1)
            finished.withLockedValue { $0 = true }
        }
        await recovery.join()

        XCTAssertTrue(
            finished.withLockedValue { $0 },
            "join() is what every platform-surface caller relies on to be second"
        )
    }

    /// `awaitLaunchRecovery()` sits at the head of the host's Start, Stop,
    /// reload and readiness paths, so it is called on every lifecycle
    /// transition for the life of the process, not once.
    @RuntimeActor
    func testJoinIsIdempotentAndRunsTheWorkOnce() async {
        let runs = NIOLockedValueBox(0)

        let recovery = LaunchRecovery(on: work) {
            runs.withLockedValue { $0 += 1 }
        }
        await recovery.join()
        await recovery.join()
        await recovery.join()

        XCTAssertEqual(runs.withLockedValue { $0 }, 1)
    }
}
