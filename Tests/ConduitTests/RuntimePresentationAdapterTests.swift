// SPDX-License-Identifier: Apache-2.0
import Combine
import XCTest
@testable import Conduit
@testable import ProxyKernel

final class RuntimePresentationAdapterTests: XCTestCase {

    // MARK: - Immediate vs coalesced split

    @MainActor func testImmediateFieldsUpdateSynchronously() {
        let adapter = RuntimePresentationAdapter()

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.state = .running
        snapshot.runtimeStatus.activeUpstream = "proxy.example.com:8080"
        snapshot.proxyError = nil
        snapshot.dnsRunState = .running
        snapshot.bindings.proxyPort = 3128

        adapter.apply(snapshot: snapshot)

        XCTAssertEqual(adapter.runtimeStatus.state, .running)
        XCTAssertEqual(adapter.runtimeStatus.activeUpstream, "proxy.example.com:8080")
        XCTAssertEqual(adapter.dnsRunState, .running)
        XCTAssertEqual(adapter.bindings.proxyPort, 3128)
    }

    @MainActor func testMetricsDoNotUpdateSynchronously() {
        let adapter = RuntimePresentationAdapter(coalesceInterval: 0.001)

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.metrics.requestsHandled = 42
        snapshot.runtimeStatus.metrics.failedRequests = 3
        snapshot.dnsQueryCount = 100

        adapter.apply(snapshot: snapshot)

        XCTAssertEqual(adapter.requestsHandled, 0, "Metrics must not update synchronously — they belong in the coalesced tier")
        XCTAssertEqual(adapter.failedRequests, 0)
        XCTAssertEqual(adapter.dnsQueryCount, 0)
    }

    @MainActor func testMetricsUpdateAfterCoalesceInterval() async {
        let adapter = RuntimePresentationAdapter(coalesceInterval: 0.001)

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.metrics.requestsHandled = 42
        snapshot.runtimeStatus.metrics.failedRequests = 3
        snapshot.runtimeStatus.metrics.successfulRecoveries = 1
        snapshot.dnsQueryCount = 100
        snapshot.dnsCacheHitCount = 50
        snapshot.tunnelSessionCount = 7

        adapter.apply(snapshot: snapshot)

        // Wait for the coalesce window to flush. The adapter schedules via
        // `DispatchQueue.main.asyncAfter` + `MainActor.assumeIsolated`, which
        // fires synchronously on the main queue when the dispatch timer elapses.
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(adapter.requestsHandled, 42)
        XCTAssertEqual(adapter.failedRequests, 3)
        XCTAssertEqual(adapter.successfulRecoveries, 1)
        XCTAssertEqual(adapter.dnsQueryCount, 100)
        XCTAssertEqual(adapter.dnsCacheHitCount, 50)
        XCTAssertEqual(adapter.tunnelSessionCount, 7)

        adapter.stop()
    }

    // MARK: - Equality guards prevent spurious publishes

    @MainActor func testNoPublishWhenSnapshotUnchanged() {
        let adapter = RuntimePresentationAdapter()

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.state = .running
        snapshot.runtimeStatus.activeUpstream = "proxy:8080"
        snapshot.proxyError = nil

        adapter.apply(snapshot: snapshot)

        var publishCount = 0
        let cancellable = adapter.objectWillChange.sink { _ in
            publishCount += 1
        }

        adapter.apply(snapshot: snapshot)

        XCTAssertEqual(publishCount, 0, "Applying an identical snapshot should not fire objectWillChange")

        _ = cancellable
    }

    // MARK: - DNS health override survives next snapshot

    @MainActor func testDNSHealthOverrideSurvivesMatchingSnapshot() {
        let adapter = RuntimePresentationAdapter()

        var baseSnapshot = ProxyOrchestratorSnapshot()
        baseSnapshot.dnsRunState = .running
        baseSnapshot.dnsError = nil
        adapter.apply(snapshot: baseSnapshot)

        adapter.applyDNSHealthOverride(runState: nil, error: "DNS pipeline unresponsive")
        XCTAssertEqual(adapter.dnsError, "DNS pipeline unresponsive")

        adapter.apply(snapshot: baseSnapshot)

        XCTAssertEqual(adapter.dnsError, nil,
            "Orchestrator snapshot should be able to clear the override when it emits a fresh snapshot with dnsError = nil")
        XCTAssertEqual(adapter.dnsRunState, .running)
    }

    @MainActor func testDNSHealthRecoveryOverride() {
        let adapter = RuntimePresentationAdapter()

        var failedSnapshot = ProxyOrchestratorSnapshot()
        failedSnapshot.dnsRunState = .failed
        adapter.apply(snapshot: failedSnapshot)
        XCTAssertEqual(adapter.dnsRunState, .failed)

        adapter.applyDNSHealthOverride(runState: .running, error: nil)
        XCTAssertEqual(adapter.dnsRunState, .running)
        XCTAssertNil(adapter.dnsError)
    }

    // MARK: - Phase 7 — VPN flap telemetry mirroring

    /// The four flap-telemetry counters must mirror their `ProxyMetrics`
    /// counterparts after the coalesce window. They live in the coalesced
    /// tier (counter-grade), not the immediate tier — same as the existing
    /// requestsHandled / failedRequests fields.
    @MainActor func testVpnFlapTelemetryMirrorsMetricsAfterCoalesce() async {
        let adapter = RuntimePresentationAdapter(coalesceInterval: 0.001)

        // Pre-condition: defaults are zero / nil.
        XCTAssertEqual(adapter.vpnFlapCount, 0)
        XCTAssertEqual(adapter.vpnFlapTotalDuration, 0)
        XCTAssertNil(adapter.lastVpnFlapAt)
        XCTAssertEqual(adapter.streamsPreservedAcrossFlaps, 0)

        let flapAt = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.metrics.vpnFlapCount = 3
        snapshot.runtimeStatus.metrics.vpnFlapTotalDuration = 1.234
        snapshot.runtimeStatus.metrics.lastVpnFlapAt = flapAt
        snapshot.runtimeStatus.metrics.streamsPreservedAcrossFlaps = 5

        adapter.apply(snapshot: snapshot)

        // Synchronous read should still see defaults — these are coalesced.
        XCTAssertEqual(adapter.vpnFlapCount, 0,
                       "VPN flap counters must be coalesced, not immediate (matches requestsHandled tier)")

        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(adapter.vpnFlapCount, 3)
        XCTAssertEqual(adapter.vpnFlapTotalDuration, 1.234, accuracy: 1e-9)
        XCTAssertEqual(adapter.lastVpnFlapAt, flapAt)
        XCTAssertEqual(adapter.streamsPreservedAcrossFlaps, 5)

        adapter.stop()
    }
}

// MARK: - Phase 7 — ProxyMetrics Codable backward compatibility

/// `ProxyMetrics` decoded from a JSON payload that pre-dates the Phase 7
/// additions must still decode successfully — the new fields default to zero.
/// Verifies the `decodeIfPresent ?? default` decoder we added so older
/// pm-proxy NDJSON snapshots and on-disk state files keep working without
/// a schema migration.
final class RuntimeCounterResetTests: XCTestCase {

    @MainActor func testResetZeroesDisplayedCountersAndDeltasResume() async {
        let adapter = RuntimePresentationAdapter(coalesceInterval: 0.001)

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.metrics.requestsHandled = 100
        snapshot.runtimeStatus.metrics.failedRequests = 40
        adapter.apply(snapshot: snapshot)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(adapter.requestsHandled, 100)
        XCTAssertEqual(adapter.failedRequests, 40)

        adapter.resetActivityCounters()
        XCTAssertEqual(adapter.requestsHandled, 0)
        XCTAssertEqual(adapter.failedRequests, 0)

        snapshot.runtimeStatus.metrics.requestsHandled = 130
        snapshot.runtimeStatus.metrics.failedRequests = 41
        adapter.apply(snapshot: snapshot)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(adapter.requestsHandled, 30, "post-reset display shows the delta since reset")
        XCTAssertEqual(adapter.failedRequests, 1)
    }

    @MainActor func testBaselineSelfClearsWhenRawCounterRestarts() async {
        let adapter = RuntimePresentationAdapter(coalesceInterval: 0.001)

        var snapshot = ProxyOrchestratorSnapshot()
        snapshot.runtimeStatus.metrics.requestsHandled = 500
        snapshot.runtimeStatus.metrics.failedRequests = 50
        adapter.apply(snapshot: snapshot)
        try? await Task.sleep(for: .milliseconds(20))
        adapter.resetActivityCounters()

        // Orchestrator restart: raw counters start over from zero. The
        // baseline must self-clear instead of pinning the display to 0.
        snapshot.runtimeStatus.metrics.requestsHandled = 10
        snapshot.runtimeStatus.metrics.failedRequests = 2
        adapter.apply(snapshot: snapshot)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(adapter.requestsHandled, 10)
        XCTAssertEqual(adapter.failedRequests, 2)
    }
}

final class ProxyMetricsCodableBackcompatTests: XCTestCase {

    func testLegacyPayloadDecodesWithZeroFlapMetrics() throws {
        // Payload as it would appear in an NDJSON line emitted by a pre-Phase-7
        // pm-proxy: only the original seven fields, no VPN flap keys.
        let legacyJSON = """
        {
            "requestsHandled": 100,
            "successfulRecoveries": 2,
            "failedRequests": 5,
            "openConnections": 3,
            "inboundConnections": 7,
            "uptimeStartedAt": null,
            "lastFailure": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyMetrics.self, from: legacyJSON)
        XCTAssertEqual(decoded.requestsHandled, 100)
        XCTAssertEqual(decoded.failedRequests, 5)
        XCTAssertEqual(decoded.openConnections, 3)
        XCTAssertEqual(decoded.vpnFlapCount, 0,
                       "Missing vpnFlapCount must default to 0 (decodeIfPresent ?? 0)")
        XCTAssertEqual(decoded.vpnFlapTotalDuration, 0)
        XCTAssertNil(decoded.lastVpnFlapAt)
        XCTAssertEqual(decoded.streamsPreservedAcrossFlaps, 0)
    }

    func testRoundTripPreservesPhase7Fields() throws {
        // Encode a populated ProxyMetrics and decode it back; the new fields
        // must round-trip cleanly so pm-proxy NDJSON consumers see them.
        let original = ProxyMetrics(
            requestsHandled: 10,
            successfulRecoveries: 1,
            failedRequests: 2,
            openConnections: 0,
            inboundConnections: 0,
            uptimeStartedAt: nil,
            lastFailure: nil,
            vpnFlapCount: 7,
            vpnFlapTotalDuration: 4.5,
            lastVpnFlapAt: Date(timeIntervalSince1970: 1_700_000_000),
            streamsPreservedAcrossFlaps: 12
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyMetrics.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyEqualsZeroDefaults() {
        // `.empty` must continue to mean "all counters zero" so existing
        // tests that compare against it for "no activity yet" stay valid.
        let empty = ProxyMetrics.empty
        XCTAssertEqual(empty.requestsHandled, 0)
        XCTAssertEqual(empty.vpnFlapCount, 0)
        XCTAssertEqual(empty.vpnFlapTotalDuration, 0)
        XCTAssertNil(empty.lastVpnFlapAt)
        XCTAssertEqual(empty.streamsPreservedAcrossFlaps, 0)
    }
}
