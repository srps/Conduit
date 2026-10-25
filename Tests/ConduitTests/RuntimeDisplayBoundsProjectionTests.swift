import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel
import ProxyControlBridge
import ConduitShared

/// Fixtures shared by the display-bound tests. The text is the real kernel input the actual projection reads, so the codec and the projection
/// tests exercise the Bridge's output and not a copy of it. The fixture is not a policy: every cap comes from `ControlDisplayField`.
///
/// The kernel masks an active connection's destination when it is built (`ActiveConnectionInfo` applies `SensitiveValueSanitizer`), so a
/// fixture text that is one long base64-like run would reach the projection as `<redacted-token>`. The row fixtures therefore use text with
/// separators, and the expectations are stated against the text the test chose.
enum DisplayBoundsFixture {
    /// The unit that costs the most to encode: a NUL is six encoded bytes, a quote or backslash two, a multibyte scalar its own width, and a
    /// combining mark or a ZWJ sequence stays inside one Character, so a cut lands on its boundary.
    static let wideUnit = "\u{0}\"\\é\u{301}\u{20AC}👨\u{200D}👩\u{200D}👧"

    static func text(atLeast bytes: Int, unit: String = wideUnit) -> String {
        var value = ""
        while value.utf8.count < bytes { value += unit }
        return value
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    static func stamp() -> ControlRuntimeStamp {
        ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: uuid(1)),
            presentationRevision: ControlPresentationRevision(rawValue: 9)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        )
    }

    /// A kernel snapshot in which every displayed kernel text carries `value`: the scalars, the bindings' hosts, the upstream and tunnel rows,
    /// one connection and the DNS override. Each optional field is present, so no field is absent by accident.
    static func kernel(text value: String) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.activeUpstream = value
        kernel.runtimeStatus.lastHealthSummary = value
        kernel.proxyError = value
        kernel.dnsError = value
        kernel.tunnelsError = value
        kernel.vpnInterfaceName = value
        kernel.lastAuthFallbackReason = value
        kernel.tunnelDNSOverrideStatus = .unavailable(reason: value)
        var bindings = ProxyOrchestratorBindings(proxyHost: nil, proxyPort: 8080, dnsHost: nil)
        bindings.proxyHost = value
        bindings.socksHost = value
        bindings.localPACHost = value
        bindings.dnsHost = value
        bindings.transparentProxyHost = value
        bindings.tunnels = [
            TunnelBindingInfo(
                id: uuid(40), label: value, localHost: value, localPort: 15432,
                remoteHost: value, remotePort: 5432, proxied: true, healthy: false
            ),
        ]
        kernel.bindings = bindings
        kernel.upstreamStatuses = [
            UpstreamRuntimeStatus(
                id: uuid(30), name: value, endpoint: value, circuitState: .open,
                ewmaLatencyMS: 18.25, consecutiveFailures: 3, openUntil: Date(timeIntervalSince1970: 1_700_000_100)
            ),
        ]
        kernel.activeConnections = ActiveConnectionStore([
            ActiveConnectionInfo(
                id: uuid(20), destination: value, upstream: value, method: value,
                startedAt: Date(timeIntervalSince1970: 1_699_999_000), lastActivityAt: Date(timeIntervalSince1970: 1_699_999_500),
                bytesSent: 1, bytesReceived: 2, tunnel: true, authMethod: value
            ),
        ])
        return kernel
    }

    /// The worst display shape this suite measures. Every free-text field is all NUL, one unit past its cap, so each is cut to its cap and
    /// each byte escapes to six. The enum, timestamp, count and metrics branches are the ones the full kernel fixture of the snapshot tests uses.
    static func worstKernel() -> ProxyOrchestratorSnapshot {
        let nul = String(repeating: "\u{0}", count: 1_025)
        let metrics = ProxyMetrics(
            requestsHandled: 42,
            successfulRecoveries: 3,
            failedRequests: 5,
            openConnections: 2,
            inboundConnections: 7,
            uptimeStartedAt: Date(timeIntervalSince1970: 1_699_990_000),
            lastFailure: Date(timeIntervalSince1970: 1_699_999_000),
            vpnFlapCount: 4,
            vpnFlapTotalDuration: 12.5,
            lastVpnFlapAt: Date(timeIntervalSince1970: 1_699_995_000),
            streamsPreservedAcrossFlaps: 6
        )
        let tunnel = TunnelBindingInfo(
            id: uuid(40), label: nul, localHost: nul, localPort: 15432, remoteHost: nul, remotePort: 5432, proxied: true, healthy: false
        )
        return ProxyOrchestratorSnapshot(
            runtimeStatus: ProxyRuntimeStatus(
                state: .degraded,
                activeUpstream: nul,
                lastHealthSummary: nul,
                metrics: metrics
            ),
            activeConnections: ActiveConnectionStore([
                ActiveConnectionInfo(
                    id: uuid(20),
                    destination: nul,
                    upstream: nul,
                    method: nul,
                    startedAt: Date(timeIntervalSince1970: 1_699_999_000),
                    lastActivityAt: Date(timeIntervalSince1970: 1_699_999_500),
                    bytesSent: 1_024,
                    bytesReceived: 4_096,
                    tunnel: false,
                    authMethod: nul
                ),
                ActiveConnectionInfo(
                    id: uuid(21),
                    destination: "wiki.corp.example.test:443",
                    upstream: "corp-2",
                    method: "CONNECT",
                    startedAt: Date(timeIntervalSince1970: 1_699_998_000),
                    lastActivityAt: Date(timeIntervalSince1970: 1_699_998_100),
                    bytesSent: 10,
                    bytesReceived: 20,
                    tunnel: true,
                    authMethod: nil
                ),
            ]),
            upstreamStatuses: [
                UpstreamRuntimeStatus(
                    id: uuid(30),
                    name: nul,
                    endpoint: nul,
                    circuitState: .halfOpen,
                    ewmaLatencyMS: 18.25,
                    consecutiveFailures: 2,
                    openUntil: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                UpstreamRuntimeStatus(
                    id: uuid(31),
                    name: "corp-2",
                    endpoint: "proxy2.corp.example.test:8080",
                    circuitState: .closed
                ),
            ],
            directModeCause: .upstreamsUnreachable,
            vpnState: .disconnected(reason: .networkLost),
            vpnInterfaceName: nul,
            proxyError: nul,
            dnsError: nul,
            dnsRunState: .warning,
            dnsQueryCount: 100,
            dnsDoHFallbackCount: 2,
            dnsCacheHitCount: 30,
            tunnelsRunState: .running,
            tunnelsError: nul,
            tunnelActiveCount: 1,
            tunnelSessionCount: 3,
            tunnelDNSOverrideStatus: .unavailable(reason: nul),
            bindings: ProxyOrchestratorBindings(
                proxyHost: nul,
                proxyPort: 3128,
                socksHost: nul,
                socksPort: 1080,
                localPACHost: nul,
                localPACPort: 8787,
                dnsHost: nul,
                dnsPort: 5353,
                transparentProxyHost: nul,
                transparentProxyPort: 8443,
                tunnels: [tunnel]
            ),
            lastAuthOutcome: .ntlmFallback,
            lastAuthOutcomeAt: Date(timeIntervalSince1970: 1_700_000_200),
            lastAuthFallbackReason: nul
        )
    }

    static func project(_ kernel: ProxyOrchestratorSnapshot, profileName: String) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            kernel, stamp: stamp(), profileName: profileName, collectionRevisions: ControlCollectionRevisions()
        )
    }
}

final class RuntimeDisplayBoundsProjectionTests: XCTestCase {
    private let budget = ControlRowBudget(maxRows: 10, maxBytes: 1 << 20)

    // MARK: - Caps and notices

    func testEverySnapshotFieldIsCutAtItsOwnCapAndNoticedOnlyWhenCut() throws {
        // At the cap nothing changes and there is no notice. One byte over, each diagnostic field is cut to 512, and the name to 1,024.
        let atCap = try DisplayBoundsFixture.project(
            DisplayBoundsFixture.kernel(text: String(repeating: "a", count: 512)),
            profileName: String(repeating: "p", count: 1_024)
        )
        XCTAssertEqual(atCap.displayNotices, [])
        XCTAssertEqual(atCap.profileName.utf8.count, 1_024)
        XCTAssertEqual(atCap.proxyError?.utf8.count, 512)

        let over = try DisplayBoundsFixture.project(
            DisplayBoundsFixture.kernel(text: String(repeating: "a", count: 513)),
            profileName: String(repeating: "p", count: 1_025)
        )
        let diagnosticFields: [ControlDisplayField] = [
            .activeUpstream, .healthSummary, .proxyError, .dnsError, .tunnelsError, .vpnInterfaceName,
            .lastAuthFallbackReason, .tunnelDNSUnavailableReason, .proxyHost, .socksHost, .localPACHost, .dnsHost,
            .transparentProxyHost,
        ]
        let expected = [ControlDisplayNotice(field: .profileName, treatment: .shortened)]
            + diagnosticFields.map { ControlDisplayNotice(field: $0, treatment: .shortened) }
        XCTAssertEqual(over.displayNotices, expected)
        XCTAssertEqual(over.profileName, String(repeating: "p", count: 1_024))
        XCTAssertEqual(over.healthSummary, String(repeating: "a", count: 512))
        XCTAssertEqual(over.bindings.socks?.host, String(repeating: "a", count: 512))
        XCTAssertEqual(over.tunnelDNSOverride.unavailableReason, String(repeating: "a", count: 512))
    }

    func testAnInputOverTheInputLimitIsOmittedWholeAndNeverPrefixCut() throws {
        // 16,384 bytes is still an input: it is cut. One byte more is omitted whole, so no prefix of it survives.
        var kernel = DisplayBoundsFixture.kernel(text: "x")
        kernel.runtimeStatus.lastHealthSummary = String(repeating: "a", count: 16_384)
        let cut = try DisplayBoundsFixture.project(kernel, profileName: "Work")
        XCTAssertEqual(cut.healthSummary, String(repeating: "a", count: 512))
        XCTAssertTrue(cut.displayNotices.contains(ControlDisplayNotice(field: .healthSummary, treatment: .shortened)))

        kernel.runtimeStatus.lastHealthSummary = String(repeating: "a", count: 16_384) + "Basic OMITTEDCREDENTIAL1"
        let omitted = try DisplayBoundsFixture.project(kernel, profileName: "Work")
        XCTAssertEqual(omitted.healthSummary, ControlDisplayText.omittedValue)
        XCTAssertTrue(omitted.displayNotices.contains(ControlDisplayNotice(field: .healthSummary, treatment: .omitted)))
        XCTAssertFalse(omitted.healthSummary.contains("aaaa"), "no prefix of an omitted input survives")
    }

    func testEveryProjectedDisplayFieldIsWithinItsCapOnTheWidestUnit() throws {
        // The widest unit, past every cap, cut at a character boundary. Each projected field must be within its own cap.
        let projected = try DisplayBoundsFixture.project(
            DisplayBoundsFixture.kernel(text: DisplayBoundsFixture.text(atLeast: 2_000)),
            profileName: DisplayBoundsFixture.text(atLeast: 2_000)
        )
        XCTAssertLessThanOrEqual(projected.profileName.utf8.count, 1_024)
        for text in [projected.activeUpstream, projected.healthSummary, projected.proxyError, projected.dnsError,
                     projected.tunnelsError, projected.vpnInterfaceName, projected.lastAuthFallbackReason,
                     projected.tunnelDNSOverride.unavailableReason, projected.bindings.proxy?.host,
                     projected.bindings.socks?.host, projected.bindings.localPAC?.host, projected.bindings.dns?.host,
                     projected.bindings.transparentProxy?.host] {
            let value = try XCTUnwrap(text)
            XCTAssertLessThanOrEqual(value.utf8.count, 512)
        }
        XCTAssertEqual(projected.displayNotices.count, ControlDisplayOwner.snapshot.maxNotices)
    }

    // MARK: - Rows and probes

    func testRowsCarryTheirOwnNoticesInCanonicalOrder() throws {
        // Two-byte separators keep the text out of the kernel's base64-like masking. The 514-byte text exceeds diagnostics caps but fits name caps.
        let separated = String(repeating: "r ", count: 257)
        let kernel = DisplayBoundsFixture.kernel(text: separated)
        guard case .rows(.activeConnections(let connections), _) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel, within: budget
        ) else { return XCTFail("the connection projects as its own kind") }
        XCTAssertEqual(connections.first?.displayNotices.map(\.field), [
            .connectionDestination, .connectionUpstream, .connectionMethod, .connectionAuthMethod,
        ])

        guard case .rows(.upstreamHealth(let upstreams), _) = RuntimeSnapshotControlProjection.projectRows(
            .upstreamHealth, from: kernel, within: budget
        ) else { return XCTFail("the upstream projects as its own kind") }
        // A name has the 1,024-byte cap, so only the 512-byte endpoint is cut here.
        XCTAssertEqual(upstreams.first?.displayNotices.map(\.field), [.upstreamEndpoint])
        XCTAssertEqual(upstreams.first?.name, separated)

        guard case .rows(.tunnelBindings(let tunnels), _) = RuntimeSnapshotControlProjection.projectRows(
            .tunnelBindings, from: kernel, within: budget
        ) else { return XCTFail("the tunnel projects as its own kind") }
        XCTAssertEqual(tunnels.first?.displayNotices.map(\.field), [.tunnelLocalHost, .tunnelRemoteHost])
    }

    func testAnOmittedRowFieldIsNoticedOnItsOwnRow() throws {
        var kernel = DisplayBoundsFixture.kernel(text: "short")
        kernel.activeConnections = ActiveConnectionStore([
            ActiveConnectionInfo(id: DisplayBoundsFixture.uuid(20), destination: String(repeating: ".", count: 16_385),
                                 upstream: "corp-1", method: "CONNECT"),
        ])
        guard case .rows(.activeConnections(let rows), _) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel, within: budget
        ) else { return XCTFail("the connection projects") }
        XCTAssertEqual(rows.first?.destination, ControlDisplayText.omittedValue)
        XCTAssertEqual(rows.first?.displayNotices, [ControlDisplayNotice(field: .connectionDestination, treatment: .omitted)])
    }

    func testAPublishedDNSHostIsCutNoticedAndBudgetedAsItsOwnRow() throws {
        // A host of 600 bytes is cut to its 512-byte cap. The short host keeps no notice. The rows' byte count is the sum of their own encodings.
        var kernel = ProxyOrchestratorSnapshot()
        let long = String(repeating: "h.", count: 300)
        kernel.tunnelDNSOverrideStatus = .active(hostnames: [long, "short.example"])
        guard case .rows(.tunnelDNSHosts(let rows), let bytes) = RuntimeSnapshotControlProjection.projectRows(
            .tunnelDNSHosts, from: kernel, within: budget
        ) else { return XCTFail("the published hosts project as their own kind") }
        XCTAssertEqual(rows.map { $0.hostname.utf8.count }, [512, 13])
        XCTAssertEqual(rows.map(\.displayNotices), [[ControlDisplayNotice(field: .dnsHostname, treatment: .shortened)], []])
        let encoded = try rows.map { try ControlRuntimeCodec.makeEncoder().encode($0).count }
        XCTAssertEqual(bytes, encoded.reduce(0, +))
        print("RUNTIME_DISPLAY_MEASURE actual published_dns_host_row_bytes=\(encoded[0]) short_row_bytes=\(encoded[1])")
    }

    func testTheProbeIsCutOnItsOwnFieldsAndCarriesItsNotices() throws {
        let long = String(repeating: "n", count: 1_025)
        let probe = try RuntimeProbeControlProjection.upstreamProbe(ProbeResult(
            proxy: UpstreamProxy(name: long, host: String(repeating: "h", count: 513), port: 8_080, priority: 0),
            latencyMS: 12,
            reachable: true
        ))
        XCTAssertEqual(probe.name.utf8.count, 1_024)
        XCTAssertEqual(probe.endpoint.utf8.count, 512)
        XCTAssertEqual(probe.displayNotices, [
            ControlDisplayNotice(field: .probeName, treatment: .shortened),
            ControlDisplayNotice(field: .probeEndpoint, treatment: .shortened),
        ])
        XCTAssertEqual(probe.latencyMilliseconds.rawValue, 12)
        XCTAssertTrue(probe.reachable)
    }

    // MARK: - Stable facts

    func testStableFactsAreUnchangedByTheDisplayPolicy() throws {
        let kernel = DisplayBoundsFixture.kernel(text: String(repeating: "s ", count: 2_000))
        let projected = try DisplayBoundsFixture.project(kernel, profileName: String(repeating: "P", count: 4_000))
        XCTAssertEqual(projected.stamp, DisplayBoundsFixture.stamp())
        XCTAssertEqual(projected.tunnelDNSOverride.kind, .unavailable)
        XCTAssertEqual(projected.bindings.proxy?.port?.rawValue, 8_080)
        XCTAssertNil(projected.bindings.socks?.port)
        XCTAssertEqual(projected.collections.activeConnections.totalCount.rawValue, 1)
        guard case .rows(.activeConnections(let rows), _) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel, within: budget
        ) else { return XCTFail("the connection projects") }
        XCTAssertEqual(rows.first?.id.rawValue, DisplayBoundsFixture.uuid(20))
        XCTAssertEqual(rows.first?.bytesSent.rawValue, 1)
        XCTAssertEqual(rows.first?.tunnel, true)
    }

    // MARK: - Secret cut points

    func testASecretCrossingEveryCutPointIsAbsentFromTheProjection() throws {
        // Each credential sits across the 512-byte cut at every offset around it. Redaction runs before the cut, so no part of it survives.
        // The Basic and userinfo forms are the sanitizer's own grammar: the Basic token is eight or more token bytes, and URL userinfo is
        // redacted once its scheme has a word boundary.
        let basic = "dXNlcjpzZWNyZXRwYXNz"
        let url = "https://svc-user:HunterSecretPassword@proxy.example.test/path?token=QUERYSECRETVALUE"
        for offset in 500...520 {
            var kernel = DisplayBoundsFixture.kernel(text: "x")
            kernel.runtimeStatus.lastHealthSummary = String(repeating: "a", count: offset) + " Basic " + basic + " tail"
            kernel.proxyError = String(repeating: "a", count: offset) + " " + url
            let projected = try DisplayBoundsFixture.project(kernel, profileName: "Work")
            let health = projected.healthSummary
            let proxyError = projected.proxyError ?? ""
            XCTAssertFalse(health.contains(basic.prefix(8)), "offset \(offset): a Basic credential prefix survives")
            XCTAssertFalse(proxyError.contains("HunterSe"), "offset \(offset): URL userinfo survives")
            XCTAssertFalse(proxyError.contains("QUERYSEC"), "offset \(offset): URL query survives")
        }
    }

    // MARK: - Measured sizes (actual bytes, reported apart from every computed bound)

    /// The maximum-TEXT sample. Every free-text field is at its cap in its widest escaping, but the metadata is small: the baseline is at
    /// high-water zero with a live replay, and the stamp, counts and timestamps are the fixture's small values. It measures the text
    /// contribution only. The widest whole frame, with widened metadata, is measured in the next test.
    func testTheMaximumTextRecordsAreMeasuredThroughTheBridgeAndTheCodec() throws {
        let roomy = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let correlation = ControlRequestID(rawValue: DisplayBoundsFixture.uuid(7))
        let nul = String(repeating: "\u{0}", count: 1_025)
        let kernel = DisplayBoundsFixture.worstKernel()
        let snapshot = try RuntimeSnapshotControlProjection.snapshot(
            kernel, stamp: DisplayBoundsFixture.stamp(), profileName: nul, collectionRevisions: ControlCollectionRevisions()
        )
        // Every field is cut to its own cap, so the record carries fourteen notices and each cut field is exactly its cap.
        XCTAssertEqual(snapshot.displayNotices.count, ControlDisplayOwner.snapshot.maxNotices)
        XCTAssertEqual(snapshot.profileName.utf8.count, 1_024)
        XCTAssertEqual(snapshot.healthSummary.utf8.count, 512)

        let snapshotMessage = ControlRuntimeMessage(correlation: correlation, body: .frame(.snapshot(snapshot)))
        let snapshotPayload = try ControlRuntimeCodec.encodeBoundedPayload(snapshotMessage, limits: roomy)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(snapshotPayload, limits: roomy), snapshotMessage)

        let baseline = try ControlBaseline(
            incarnation: DisplayBoundsFixture.stamp().incarnation,
            snapshot: snapshot,
            highWater: try XCTUnwrap(ControlEventCursor(rawValue: 0)),
            replay: .live
        )
        let baselineMessage = ControlRuntimeMessage(correlation: correlation, body: .frame(.baseline(baseline)))
        let baselinePayload = try ControlRuntimeCodec.encodeBoundedPayload(baselineMessage, limits: roomy)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(baselinePayload, limits: roomy), baselineMessage)

        // The notices are counted in the bytes: the record without them differs by exactly the encoded notice array, less the two bytes of `[]`.
        var bare = snapshot
        bare.displayNotices = []
        let barePayload = try ControlRuntimeCodec.encodeBoundedPayload(
            ControlRuntimeMessage(correlation: correlation, body: .frame(.snapshot(bare))), limits: roomy
        )
        let noticeArray = try ControlRuntimeCodec.makeEncoder().encode(snapshot.displayNotices).count
        XCTAssertEqual(snapshotPayload.count - barePayload.count, noticeArray - 2)

        guard case .rows(.activeConnections(let connections), _) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel, within: budget
        ), let connection = connections.first else { return XCTFail("the connection projects") }
        guard case .rows(.upstreamHealth(let upstreams), _) = RuntimeSnapshotControlProjection.projectRows(
            .upstreamHealth, from: kernel, within: budget
        ), let upstream = upstreams.first else { return XCTFail("the upstream projects") }
        guard case .rows(.tunnelBindings(let tunnels), _) = RuntimeSnapshotControlProjection.projectRows(
            .tunnelBindings, from: kernel, within: budget
        ), let tunnel = tunnels.first else { return XCTFail("the tunnel projects") }
        var dnsKernel = ProxyOrchestratorSnapshot()
        dnsKernel.tunnelDNSOverrideStatus = .active(hostnames: [nul])
        guard case .rows(.tunnelDNSHosts(let hosts), _) = RuntimeSnapshotControlProjection.projectRows(
            .tunnelDNSHosts, from: dnsKernel, within: budget
        ), let host = hosts.first else { return XCTFail("the DNS host projects") }
        let probe = try RuntimeProbeControlProjection.upstreamProbe(ProbeResult(
            proxy: UpstreamProxy(name: nul, host: nul, port: 8_080, priority: 0), latencyMS: 12, reachable: true
        ))

        let encoder = ControlRuntimeCodec.makeEncoder()
        let rowBytes = [
            ("connection", try encoder.encode(connection).count),
            ("upstream", try encoder.encode(upstream).count),
            ("tunnel", try encoder.encode(tunnel).count),
            ("dns_host", try encoder.encode(host).count),
            ("probe", try encoder.encode(probe).count),
        ]
        print("RUNTIME_DISPLAY_MEASURE actual max_text_snapshot_frame_payload_bytes=\(snapshotPayload.count) notices=\(snapshot.displayNotices.count) units=JSON_bytes_without_LF")
        print("RUNTIME_DISPLAY_MEASURE actual max_text_baseline_payload_bytes=\(baselinePayload.count) units=JSON_bytes_without_LF highWater=0 replay=live")
        for (name, bytes) in rowBytes {
            print("RUNTIME_DISPLAY_MEASURE actual max_text_\(name)_record_bytes=\(bytes) units=JSON_bytes_without_LF")
        }
        print("RUNTIME_DISPLAY_MEASURE actual notice_array_bytes=\(noticeArray)")

        // The computed text contribution is six bytes per raw byte at each cap, and two for the quotes. It is not a claim about the record,
        // whose structure is added on top. A record can only be at least its text contribution.
        func textContribution(_ caps: [Int]) -> Int {
            caps.reduce(0) { $0 + 6 * $1 + 2 }
        }
        let computed = [
            ("snapshot", textContribution([1_024] + Array(repeating: 512, count: 13))),
            ("connection", textContribution(Array(repeating: 512, count: 4))),
            ("upstream", textContribution([1_024, 512])),
            ("tunnel", textContribution([1_024, 512, 512])),
            ("dns_host", textContribution([512])),
            ("probe", textContribution([1_024, 512])),
        ]
        for (name, bound) in computed {
            print("RUNTIME_DISPLAY_BOUND computed_text_contribution \(name)=\(bound)")
        }
        XCTAssertGreaterThanOrEqual(snapshotPayload.count, computed[0].1)
        XCTAssertGreaterThanOrEqual(rowBytes[0].1, computed[1].1)
        XCTAssertGreaterThanOrEqual(rowBytes[1].1, computed[2].1)
        XCTAssertGreaterThanOrEqual(rowBytes[2].1, computed[3].1)
        XCTAssertGreaterThanOrEqual(rowBytes[3].1, computed[4].1)
        XCTAssertGreaterThanOrEqual(rowBytes[4].1, computed[5].1)
    }

    /// The widest metadata on the worst text, as a whole baseline frame. Each numeric scalar the rules admit is widened on the already
    /// projected snapshot, which is the only way to reach these values without a second producer. The stamp revisions, the high-water and
    /// the replay ends are Int.max. Every count and every collection total is Int.max, the five ports are 65,535, and each finite
    /// non-negative number and timestamp is the largest finite Double. Every optional field is present. The frame goes through the real
    /// codec, and the widened envelope is checked against `RuntimeServiceLimits`' measured baseline overhead.
    ///
    /// This is a measured point at the rules' ranges. It makes no claim about every value those rules admit, and the largest finite Double is
    /// the largest the rule accepts, not a bound on any text it prints as.
    func testAWidenedMetadataBaselineIsEncodedAtTheWidestScalarsTheRulesAllow() throws {
        let roomy = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let widest = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let largestFinite = Double.greatestFiniteMagnitude
        let maxCount = try ControlCount(Int.max)
        let nul = String(repeating: "\u{0}", count: 1_025)
        var snapshot = try RuntimeSnapshotControlProjection.snapshot(
            DisplayBoundsFixture.worstKernel(),
            stamp: DisplayBoundsFixture.stamp(),
            profileName: nul,
            collectionRevisions: ControlCollectionRevisions(
                activeConnections: ControlCollectionRevision(rawValue: Int.max),
                upstreamHealth: ControlCollectionRevision(rawValue: Int.max),
                tunnelBindings: ControlCollectionRevision(rawValue: Int.max),
                tunnelDNSHosts: ControlCollectionRevision(rawValue: Int.max)
            )
        )

        // Every optional field is present before the widening, so the frame carries the full set of optional values.
        XCTAssertNotNil(snapshot.activeUpstream)
        XCTAssertNotNil(snapshot.proxyError)
        XCTAssertNotNil(snapshot.dnsError)
        XCTAssertNotNil(snapshot.tunnelsError)
        XCTAssertNotNil(snapshot.vpnInterfaceName)
        XCTAssertNotNil(snapshot.lastAuthFallbackReason)
        XCTAssertNotNil(snapshot.lastAuthOutcome)
        XCTAssertNotNil(snapshot.lastAuthOutcomeAt)
        XCTAssertNotNil(snapshot.metrics.uptimeStartedAt)
        XCTAssertNotNil(snapshot.metrics.lastFailure)
        XCTAssertNotNil(snapshot.vpnFlap.lastFlapAt)
        XCTAssertNotNil(snapshot.tunnelDNSOverride.unavailableReason)
        XCTAssertNotNil(snapshot.bindings.transparentProxy?.port)

        snapshot.stamp = ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: widest),
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: Int.max)),
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: Int.max)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: Int.max))
        )
        snapshot.dnsQueryCount = maxCount
        snapshot.dnsDoHFallbackCount = maxCount
        snapshot.dnsCacheHitCount = maxCount
        snapshot.tunnelActiveCount = maxCount
        snapshot.tunnelSessionCount = maxCount
        snapshot.metrics.requestsHandled = maxCount
        snapshot.metrics.failedRequests = maxCount
        snapshot.metrics.successfulRecoveries = maxCount
        snapshot.metrics.openConnections = maxCount
        snapshot.metrics.inboundConnections = maxCount
        snapshot.metrics.uptimeStartedAt = try ControlTimestamp(largestFinite)
        snapshot.metrics.lastFailure = try ControlTimestamp(-largestFinite)
        snapshot.vpnFlap = ControlVPNFlapMetrics(
            count: maxCount,
            totalDurationSeconds: try ControlNonNegativeNumber(largestFinite),
            lastFlapAt: try ControlTimestamp(largestFinite),
            streamsPreserved: maxCount
        )
        snapshot.lastAuthOutcomeAt = try ControlTimestamp(largestFinite)
        let port = try ControlPort(65_535)
        snapshot.bindings.proxy?.port = port
        snapshot.bindings.socks?.port = port
        snapshot.bindings.localPAC?.port = port
        snapshot.bindings.dns?.port = port
        snapshot.bindings.transparentProxy?.port = port
        snapshot.collections.activeConnections.totalCount = maxCount
        snapshot.collections.upstreamHealth.totalCount = maxCount
        snapshot.collections.tunnelBindings.totalCount = maxCount
        snapshot.collections.tunnelDNSHosts.totalCount = maxCount
        snapshot.tunnelDNSOverride.hosts.totalCount = maxCount

        let baseline = try ControlBaseline(
            incarnation: ControlHostIncarnation(rawValue: widest),
            snapshot: snapshot,
            highWater: try XCTUnwrap(ControlEventCursor(rawValue: Int.max)),
            replay: .replay(
                from: try XCTUnwrap(ControlEventCursor(rawValue: Int.max - 1)),
                through: try XCTUnwrap(ControlEventCursor(rawValue: Int.max))
            )
        )
        let message = ControlRuntimeMessage(correlation: ControlRequestID(rawValue: widest), body: .frame(.baseline(baseline)))
        let payload = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: roomy)
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: roomy)
        XCTAssertEqual(frame.count, payload.count + 1, "a frame is its JSON payload plus one line feed")
        XCTAssertEqual(try ControlRuntimeCodec.decodeFullFrame(frame, limits: roomy), message)
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: frame.count)))
        let shortLimit = try ControlFrameLimits(maxFrameBytes: frame.count - 1)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(message, limits: shortLimit)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }

        // The bare payloads, with no envelope and no line feed, are measured apart from the frames.
        let encoder = ControlRuntimeCodec.makeEncoder()
        let bareSnapshot = try encoder.encode(snapshot).count
        let snapshotFrame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(correlation: ControlRequestID(rawValue: widest), body: .frame(.snapshot(snapshot))),
            limits: roomy
        ).count
        let projectedRows = RuntimeSnapshotControlProjection.projectRows(
            .upstreamHealth, from: DisplayBoundsFixture.worstKernel(), within: budget
        )
        guard case .rows(.upstreamHealth(var upstreams), _) = projectedRows, !upstreams.isEmpty else {
            return XCTFail("the upstream projects")
        }
        upstreams[0].ewmaLatencyMilliseconds = try ControlNonNegativeNumber(largestFinite)
        upstreams[0].consecutiveFailures = maxCount
        upstreams[0].openUntil = try ControlTimestamp(largestFinite)
        let bareWidenedRow = try encoder.encode(upstreams[0]).count

        // The reference: RuntimeServiceLimits measures a baseline frame, with its line feed, minus the bare snapshot JSON, at the largest cursor.
        // The widened baseline has the same digit widths, so the two must agree exactly.
        let referenceOverhead = try RuntimeServiceFixtures.limits().baselineFrameOverheadBytes
        let widenedOverhead = frame.count - bareSnapshot
        XCTAssertEqual(widenedOverhead, referenceOverhead, "the widened envelope matches the measured reference")

        print("RUNTIME_DISPLAY_MEASURE widened units=bytes type=baseline_frame framing=JSON_payload_plus_one_LF payload_bytes=\(payload.count) frame_bytes_with_LF=\(frame.count)")
        print("RUNTIME_DISPLAY_MEASURE widened units=bytes type=bare_snapshot_json framing=no_envelope_no_LF bytes=\(bareSnapshot)")
        print("RUNTIME_DISPLAY_MEASURE widened units=bytes type=snapshot_frame framing=JSON_payload_plus_one_LF frame_bytes_with_LF=\(snapshotFrame)")
        print("RUNTIME_DISPLAY_MEASURE widened units=bytes type=upstream_row framing=no_envelope_no_LF bytes=\(bareWidenedRow)")
        print("RUNTIME_DISPLAY_REFERENCE RuntimeServiceLimits.measuredBaselineFrameOverhead units=bytes framing=baseline_frame_with_LF_minus_bare_snapshot value=\(referenceOverhead)")
        print("RUNTIME_DISPLAY_MEASURE widened baseline_overhead_recomputed units=bytes value=\(widenedOverhead)")
        print("RUNTIME_DISPLAY_MEASURE widened largest_finite_double_description=\(largestFinite) chars=\(String(largestFinite).count)")
    }
}
