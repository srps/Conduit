// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PlatformMac
import ProxyKernel

/// The production path adapter over the real `NWPathMonitor`, read-only: it observes the machine's path and changes nothing. A host
/// starts its observers with a module and stops them when none is left, on one adapter for its whole life, so a Start after a Stop
/// must report again (#260). `NWPathMonitor` reports the current path once after it starts, which is what each start waits for; the
/// debounce is zero so that report is delivered as it comes.
///
/// Each lifetime reports to a callback of its own, set after the stop that ended the one before. A report the first lifetime's
/// callback had already claimed when it was stopped can only land in the first log, so the second log hears from the restart alone.
final class NetworkMonitorTests: XCTestCase {
    /// Waits, bounded, until `reports` holds an entry.
    private func waitForReport(in reports: LockedLog<NetworkPathState>) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while reports.values.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !reports.values.isEmpty
    }

    func testARestartedMonitorReportsAgain() async {
        let monitor = NetworkMonitor(debounceInterval: 0)
        let first = LockedLog<NetworkPathState>()
        monitor.setOnChange { first.append($0) }
        defer { monitor.stop() }

        monitor.start()
        let reported = await waitForReport(in: first)
        XCTAssertTrue(reported, "the first start reports the current path")
        monitor.stop()

        let second = LockedLog<NetworkPathState>()
        monitor.setOnChange { second.append($0) }
        monitor.start()
        let again = await waitForReport(in: second)
        XCTAssertTrue(again, "a start after a stop reports the current path again")
    }

    /// A stop while stopped changes nothing: the next restart still reports. It does not show that a start while observing is a no-op;
    /// two live monitors would pass it too.
    func testAStartWhileActiveAndAStopWhileStoppedChangeNothing() async {
        let monitor = NetworkMonitor(debounceInterval: 0)
        let first = LockedLog<NetworkPathState>()
        monitor.setOnChange { first.append($0) }
        defer { monitor.stop() }

        monitor.start()
        monitor.start()
        let reported = await waitForReport(in: first)
        XCTAssertTrue(reported, "the first start reports the current path")
        monitor.stop()
        monitor.stop()

        let second = LockedLog<NetworkPathState>()
        monitor.setOnChange { second.append($0) }
        monitor.start()
        let again = await waitForReport(in: second)
        XCTAssertTrue(again, "the restart after a repeated start and stop reports again")
    }
}
