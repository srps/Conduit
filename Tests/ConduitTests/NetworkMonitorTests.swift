// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PlatformMac
import ProxyKernel

/// The production path adapter over the real `NWPathMonitor`, read-only: it observes the machine's path and changes nothing. A host
/// starts its observers with a module and stops them when none is left, on one adapter for its whole life, so a Start after a Stop
/// must report again (#260). `NWPathMonitor` reports the current path once after it starts, which is what each start waits for; the
/// debounce is zero so that report is delivered as it comes.
final class NetworkMonitorTests: XCTestCase {
    /// Waits, bounded, until `reports` holds more than `count` entries.
    private func waitForReport(after count: Int, in reports: LockedLog<NetworkPathState>) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while reports.values.count <= count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return reports.values.count > count
    }

    func testARestartedMonitorReportsAgain() async {
        let monitor = NetworkMonitor(debounceInterval: 0)
        let reports = LockedLog<NetworkPathState>()
        monitor.setOnChange { reports.append($0) }
        defer { monitor.stop() }

        monitor.start()
        let first = await waitForReport(after: 0, in: reports)
        XCTAssertTrue(first, "the first start reports the current path")
        monitor.stop()
        let afterStop = reports.values.count

        monitor.start()
        let again = await waitForReport(after: afterStop, in: reports)
        XCTAssertTrue(again, "a start after a stop reports the current path again")
    }

    /// A start while observing and a stop while stopped change nothing: the next restart still reports.
    func testAStartWhileActiveAndAStopWhileStoppedChangeNothing() async {
        let monitor = NetworkMonitor(debounceInterval: 0)
        let reports = LockedLog<NetworkPathState>()
        monitor.setOnChange { reports.append($0) }
        defer { monitor.stop() }

        monitor.start()
        monitor.start()
        let first = await waitForReport(after: 0, in: reports)
        XCTAssertTrue(first, "the first start reports the current path")
        monitor.stop()
        monitor.stop()
        let afterStop = reports.values.count

        monitor.start()
        let again = await waitForReport(after: afterStop, in: reports)
        XCTAssertTrue(again, "the restart after a repeated start and stop reports again")
    }
}
