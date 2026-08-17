// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Issue #70: a thrown `reconcile` must not skip the intercept refresh.
///
/// `DNSManager.reconcile` completes the config migration even when part of the
/// stale-file sweep failed, then rethrows the aggregate at the end — so a throw
/// can arrive *after* a successful apply. With both calls inside one `do` block
/// (which is what both hosts had), that throw skipped
/// `refreshInterceptFiles`, leaving `/etc/resolver/<intercept>` pointing at a
/// forwarder port the config change may have just moved.
final class DNSResolverReconciliationTests: XCTestCase {

    private struct SweepFailed: Error, LocalizedError {
        var errorDescription: String? { "the stale-file sweep left 2 files behind" }
    }

    private struct RefreshFailed: Error, LocalizedError {
        var errorDescription: String? { "the helper refused to write the intercept file" }
    }

    func testInterceptRefreshRunsAfterAThrowingReconcile() {
        let logger = RecordingLogSink(minLevel: .debug)
        var refreshed = false

        DNSResolverReconciliation.run(
            after: "config change",
            logger: logger,
            reconcile: { throw SweepFailed() },
            refreshInterceptFiles: { refreshed = true }
        )

        XCTAssertTrue(
            refreshed,
            "the intercept files must be re-pointed even when the reconcile reported a failure"
        )
    }

    func testInterceptRefreshRunsAfterASucceedingReconcile() {
        let logger = RecordingLogSink(minLevel: .debug)
        var refreshed = false

        DNSResolverReconciliation.run(
            after: "config change",
            logger: logger,
            reconcile: {},
            refreshInterceptFiles: { refreshed = true }
        )

        XCTAssertTrue(refreshed)
        XCTAssertTrue(logger.entries(at: .warning).isEmpty, "a clean pass must not warn")
    }

    /// The two failures answer different questions — "the edit did not fully
    /// take" versus "some domains may now resolve nowhere" — so neither may be
    /// swallowed by the other.
    func testBothFailuresAreReportedSeparately() {
        let logger = RecordingLogSink(minLevel: .debug)

        DNSResolverReconciliation.run(
            after: "config reload",
            logger: logger,
            reconcile: { throw SweepFailed() },
            refreshInterceptFiles: { throw RefreshFailed() }
        )

        XCTAssertTrue(
            logger.containsMessage("the stale-file sweep left 2 files behind", at: .warning),
            "the reconcile failure must survive the refresh failure"
        )
        XCTAssertTrue(
            logger.containsMessage("the helper refused to write the intercept file", at: .warning),
            "the refresh failure must survive the reconcile failure"
        )
        XCTAssertTrue(
            logger.containsMessage("no longer served", at: .warning),
            "the refresh failure has to say what it costs, not just that it happened"
        )
        XCTAssertEqual(logger.entries(at: .warning).count, 2)
    }

    /// A refresh failure alone still reports, and does not invent a reconcile
    /// failure that did not happen.
    func testRefreshFailureAloneIsReported() {
        let logger = RecordingLogSink(minLevel: .debug)

        DNSResolverReconciliation.run(
            after: "config change",
            logger: logger,
            reconcile: {},
            refreshInterceptFiles: { throw RefreshFailed() }
        )

        XCTAssertEqual(logger.entries(at: .warning).count, 1)
        XCTAssertTrue(logger.containsMessage("Could not refresh intercept resolver files", at: .warning))
    }
}
