// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
import ProxyControlBridge
import ConduitShared

/// The kernel-to-wire projection: every presentation scalar, exhaustive mappings,
/// derived values, explicit unknowns, secret-free output, and bounded pages.
final class RuntimeSnapshotProjectionTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private func stamp(presentation: Int = 9) -> ControlRuntimeStamp {
        ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: uuid(1)),
            presentationRevision: ControlPresentationRevision(rawValue: presentation)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        )
    }

    private var limits16KiB: ControlFrameLimits {
        // The v1 bound, used here as the caller's chosen limit. It is not a v2 default.
        try! ControlFrameLimits(maxFrameBytes: ControlSocket.maxFrameBytes)
    }

    private let correlation = ControlRequestID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)

    /// A frame of a subscription, for a fixture that carries one value.
    private func frameMessage(_ frame: ControlRuntimeFrame) -> ControlRuntimeMessage {
        ControlRuntimeMessage(correlation: correlation, body: .frame(frame))
    }

    private func fullKernelSnapshot() -> ProxyOrchestratorSnapshot {
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
            id: uuid(40),
            label: "db",
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "db.corp.example.test",
            remotePort: 5432,
            proxied: true,
            healthy: false
        )
        return ProxyOrchestratorSnapshot(
            runtimeStatus: ProxyRuntimeStatus(
                state: .degraded,
                activeUpstream: "corp-1",
                lastHealthSummary: "Upstreams unreachable",
                metrics: metrics
            ),
            activeConnections: ActiveConnectionStore([
                ActiveConnectionInfo(
                    id: uuid(20),
                    destination: "files.corp.example.test:443",
                    upstream: "corp-1",
                    method: "CONNECT",
                    startedAt: Date(timeIntervalSince1970: 1_699_999_000),
                    lastActivityAt: Date(timeIntervalSince1970: 1_699_999_500),
                    bytesSent: 1_024,
                    bytesReceived: 4_096,
                    tunnel: false,
                    authMethod: "Negotiate"
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
                    name: "corp-1",
                    endpoint: "proxy1.corp.example.test:8080",
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
            vpnInterfaceName: "utun4",
            proxyError: "bind failed",
            dnsError: "resolver stale",
            dnsRunState: .warning,
            dnsQueryCount: 100,
            dnsDoHFallbackCount: 2,
            dnsCacheHitCount: 30,
            tunnelsRunState: .running,
            tunnelsError: nil,
            tunnelActiveCount: 1,
            tunnelSessionCount: 3,
            tunnelDNSOverrideStatus: .partial(
                succeeded: ["db.corp.example.test"],
                failed: ["api.corp.example.test"]
            ),
            bindings: ProxyOrchestratorBindings(
                proxyHost: "127.0.0.1",
                proxyPort: 3128,
                socksHost: "127.0.0.1",
                socksPort: 1080,
                localPACHost: "127.0.0.1",
                localPACPort: 8787,
                dnsHost: "127.44.3.1",
                dnsPort: 5353,
                transparentProxyHost: "127.44.3.0",
                transparentProxyPort: 8443,
                tunnels: [tunnel]
            ),
            lastAuthOutcome: .ntlmFallback,
            lastAuthOutcomeAt: observedAt,
            lastAuthFallbackReason: "bad_mech"
        )
    }

    private func project(
        _ snapshot: ProxyOrchestratorSnapshot,
        revisions: ControlCollectionRevisions = ControlCollectionRevisions()
    ) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            snapshot,
            stamp: stamp(),
            profileName: "Work",
            collectionRevisions: revisions
        )
    }

    /// The rows one bounded projection keeps for a kind, through the production projection. The fixture bounds are large enough for
    /// these snapshots, so a test that needs a refusal passes its own bound.
    private func projectedRows(
        _ kernel: ProxyOrchestratorSnapshot,
        _ kind: ControlCollectionKind,
        maxRows: Int = 300,
        maxBytes: Int = 1 << 20
    ) throws -> ControlProjectedRows {
        switch RuntimeSnapshotControlProjection.projectRows(kind, from: kernel, within: ControlRowBudget(maxRows: maxRows, maxBytes: maxBytes)) {
        case .rows(let rows, _): return rows
        case .overBudget: throw ProjectionRefusal.overBudget
        case .internalFailure: throw ProjectionRefusal.internalFailure
        }
    }

    private enum ProjectionRefusal: Error {
        case overBudget
        case internalFailure
    }

    /// One page of projected rows from `offset`, packed the way the host packs a reply.
    private func packPage(
        _ rows: ControlProjectedRows,
        offset: Int = 0,
        revision: ControlCollectionRevision = ControlCollectionRevision(rawValue: 1)!,
        limits: ControlFrameLimits
    ) throws -> ControlRuntimeMessage {
        switch rows {
        case .activeConnections(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: stamp().incarnation, revision: revision, correlation: correlation, limits: limits,
                wrap: ControlPageReply.activeConnections
            )
        case .upstreamHealth(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: stamp().incarnation, revision: revision, correlation: correlation, limits: limits,
                wrap: ControlPageReply.upstreamHealth
            )
        case .tunnelBindings(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: stamp().incarnation, revision: revision, correlation: correlation, limits: limits,
                wrap: ControlPageReply.tunnelBindings
            )
        case .tunnelDNSHosts(let list):
            return try ControlPagePacker.page(
                of: list, offset: offset, incarnation: stamp().incarnation, revision: revision, correlation: correlation, limits: limits,
                wrap: ControlPageReply.tunnelDNSHosts
            )
        }
    }

    // MARK: - Every scalar

    func testScalarProjectionCarriesEveryPresentationScalar() throws {
        let projected = try project(fullKernelSnapshot())

        XCTAssertEqual(projected.stamp, stamp())
        XCTAssertEqual(projected.profileName, "Work")
        XCTAssertEqual(projected.proxyState, .degraded)
        XCTAssertEqual(projected.activeUpstream, "corp-1")
        XCTAssertEqual(projected.healthSummary, "Upstreams unreachable")
        XCTAssertEqual(projected.proxyError, "bind failed")
        XCTAssertEqual(projected.dnsRunState, .warning)
        XCTAssertEqual(projected.dnsError, "resolver stale")
        XCTAssertEqual(projected.tunnelsRunState, .running)
        XCTAssertNil(projected.tunnelsError)
        XCTAssertEqual(projected.directModeCause, .upstreamsUnreachable)
        XCTAssertTrue(projected.isDirectMode)
        XCTAssertEqual(projected.vpnState, .disconnected(.networkLost))
        XCTAssertEqual(projected.vpnInterfaceName, "utun4")

        XCTAssertEqual(projected.bindings.proxy, ControlEndpoint(host: "127.0.0.1", port: try ControlPort(3128)))
        XCTAssertEqual(projected.bindings.socks, ControlEndpoint(host: "127.0.0.1", port: try ControlPort(1080)))
        XCTAssertEqual(projected.bindings.localPAC, ControlEndpoint(host: "127.0.0.1", port: try ControlPort(8787)))
        XCTAssertEqual(projected.bindings.dns, ControlEndpoint(host: "127.44.3.1", port: try ControlPort(5353)))
        XCTAssertEqual(projected.bindings.transparentProxy, ControlEndpoint(host: "127.44.3.0", port: try ControlPort(8443)))
        XCTAssertTrue(projected.bindings.dnsInterceptReady)

        XCTAssertEqual(projected.lastAuthOutcome, .ntlmFallback)
        XCTAssertEqual(projected.lastAuthOutcomeAt?.rawValue, 1_700_000_000)
        XCTAssertEqual(projected.lastAuthFallbackReason, "bad_mech")

        XCTAssertEqual(projected.metrics.requestsHandled.rawValue, 42)
        XCTAssertEqual(projected.metrics.failedRequests.rawValue, 5)
        XCTAssertEqual(projected.metrics.successfulRecoveries.rawValue, 3)
        XCTAssertEqual(projected.metrics.openConnections.rawValue, 2)
        XCTAssertEqual(projected.metrics.inboundConnections.rawValue, 7)
        XCTAssertEqual(projected.metrics.uptimeStartedAt?.rawValue, 1_699_990_000)
        XCTAssertEqual(projected.metrics.lastFailure?.rawValue, 1_699_999_000)

        XCTAssertEqual(projected.dnsQueryCount.rawValue, 100)
        XCTAssertEqual(projected.dnsDoHFallbackCount.rawValue, 2)
        XCTAssertEqual(projected.dnsCacheHitCount.rawValue, 30)
        XCTAssertEqual(projected.tunnelActiveCount.rawValue, 1)
        XCTAssertEqual(projected.tunnelSessionCount.rawValue, 3)

        XCTAssertEqual(projected.vpnFlap.count.rawValue, 4)
        XCTAssertEqual(projected.vpnFlap.totalDurationSeconds.rawValue, 12.5)
        XCTAssertEqual(projected.vpnFlap.lastFlapAt?.rawValue, 1_699_995_000)
        XCTAssertEqual(projected.vpnFlap.streamsPreserved.rawValue, 6)

        XCTAssertEqual(projected.tunnelDNSOverride.kind, .partial)
        XCTAssertNil(projected.tunnelDNSOverride.unavailableReason)
        XCTAssertEqual(projected.tunnelDNSOverride.hosts.totalCount.rawValue, 2)

        XCTAssertEqual(projected.appliedState, .unavailable(.pendingAppliedStateSlice))
    }

    func testListsAreReferencedByExactCountAndUnknownRevisionNotInlined() throws {
        let projected = try project(fullKernelSnapshot())
        XCTAssertEqual(projected.collections.activeConnections.totalCount.rawValue, 2)
        XCTAssertEqual(projected.collections.upstreamHealth.totalCount.rawValue, 2)
        XCTAssertEqual(projected.collections.tunnelBindings.totalCount.rawValue, 1)
        XCTAssertEqual(projected.collections.tunnelDNSHosts.totalCount.rawValue, 2)
        XCTAssertEqual(projected.collections.activeConnections.state, .unavailable(.notCaptured))

        let captured = try project(fullKernelSnapshot(), revisions: ControlCollectionRevisions(
            activeConnections: ControlCollectionRevision(rawValue: 7)
        ))
        XCTAssertEqual(captured.collections.activeConnections.state, .available(ControlCollectionRevision(rawValue: 7)!))
        XCTAssertEqual(captured.collections.upstreamHealth.state, .unavailable(.notCaptured))
    }

    // MARK: - Derived values and exhaustive mappings

    func testDirectModeIsDerivedFromTheCauseAndNeverSentBesideIt() throws {
        let text = try ControlRuntimeCodec.makeEncoder().encode(try project(fullKernelSnapshot()))
        let json = String(decoding: text, as: UTF8.self)
        XCTAssertFalse(json.contains("directMode\""), "the derived mode is not a wire key")
        XCTAssertTrue(json.contains(#""directModeCause":"upstreamsUnreachable""#))
        XCTAssertFalse(json.contains("isDirectMode"))
        XCTAssertFalse(json.contains("isDirect"))
    }

    func testEveryDirectModeCauseAgreesWithTheKernelsOwnPredicate() throws {
        let causes: [DirectModeCause] = [
            .none, .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured, .upstreamsUnreachable,
        ]
        for cause in causes {
            var kernel = fullKernelSnapshot()
            kernel.directModeCause = cause
            let projected = try project(kernel)
            XCTAssertEqual(projected.directModeCause.rawValue, cause.rawValue)
            XCTAssertEqual(projected.isDirectMode, cause.isDirect, "\(cause)")
        }
    }

    func testEveryVPNAndAuthAndTunnelDNSCaseMapsToItsOwnWireValue() throws {
        let vpnStates: [(VPNObservedState, ControlVPNState)] = [
            (.unknown, .unknown),
            (.connected, .connected),
            (.reasserting, .reasserting),
            (.disconnected(reason: .userInitiated), .disconnected(.userInitiated)),
            (.disconnected(reason: .networkLost), .disconnected(.networkLost)),
            (.disconnected(reason: .unknown), .disconnected(.unknown)),
        ]
        for (kernel, wire) in vpnStates {
            var snapshot = fullKernelSnapshot()
            snapshot.vpnState = kernel
            XCTAssertEqual(try project(snapshot).vpnState, wire)
        }

        let outcomes: [(RuntimeAuthOutcome, ControlAuthOutcome)] = [
            (.kerberos, .kerberos), (.ntlmFallback, .ntlmFallback), (.ntlmDirect, .ntlmDirect),
        ]
        for (kernel, wire) in outcomes {
            var snapshot = fullKernelSnapshot()
            snapshot.lastAuthOutcome = kernel
            XCTAssertEqual(try project(snapshot).lastAuthOutcome, wire)
        }

        var notNeeded = fullKernelSnapshot()
        notNeeded.tunnelDNSOverrideStatus = .notNeeded
        XCTAssertEqual(try project(notNeeded).tunnelDNSOverride.kind, .notNeeded)

        var unavailable = fullKernelSnapshot()
        unavailable.tunnelDNSOverrideStatus = .unavailable(reason: "no resolver for corp.example.test")
        let projectedUnavailable = try project(unavailable)
        XCTAssertEqual(projectedUnavailable.tunnelDNSOverride.kind, .unavailable)
        XCTAssertEqual(projectedUnavailable.tunnelDNSOverride.unavailableReason, "no resolver for corp.example.test")
        XCTAssertEqual(projectedUnavailable.tunnelDNSOverride.hosts.totalCount.rawValue, 0)
    }

    func testAnUnboundSurfaceIsAbsentAndAPartlyBoundOneKeepsItsPart() throws {
        var kernel = fullKernelSnapshot()
        kernel.bindings = ProxyOrchestratorBindings(proxyHost: nil, proxyPort: nil, dnsHost: "127.44.3.1")
        let projected = try project(kernel)
        XCTAssertNil(projected.bindings.proxy)
        XCTAssertEqual(projected.bindings.dns, ControlEndpoint(host: "127.44.3.1", port: nil))
        XCTAssertFalse(projected.bindings.dnsInterceptReady)
    }

    func testAnUnusableBindingPortIsAnExplicitErrorNotASilentlyDroppedBinding() {
        var kernel = fullKernelSnapshot()
        kernel.bindings = ProxyOrchestratorBindings(proxyHost: "127.0.0.1", proxyPort: 70_000)
        XCTAssertThrowsError(try project(kernel))
    }

    // MARK: - Secret-free output

    func testSecretBearingValuesAreAbsentFromEveryEncodedProjection() throws {
        var kernel = fullKernelSnapshot()
        kernel.runtimeStatus.lastHealthSummary = "Probe http://monitor:ARTIFICIAL-USER-9c1e@health.example.test/ok"
        kernel.runtimeStatus.activeUpstream = "https://api.example.test/v1?token=ARTIFICIAL-QUERY-7f3a"
        kernel.lastAuthFallbackReason = "Proxy-Authorization: Basic ARTIFICIALBASIC-44aa"
        kernel.upstreamStatuses[0].endpoint = "http://user:ARTIFICIAL-ENDPOINT-3d0e@proxy1.corp.example.test:8080/"
        kernel.activeConnections = ActiveConnectionStore([
            ActiveConnectionInfo(
                id: uuid(50),
                destination: "http://files.example.test/a?token=ARTIFICIAL-DEST-6b9f",
                upstream: "corp-1",
                method: "GET"
            ),
        ])

        let snapshot = try project(kernel)
        let connections = try packPage(try projectedRows(kernel, .activeConnections), limits: limits16KiB)
        let upstreams = try packPage(try projectedRows(kernel, .upstreamHealth), limits: limits16KiB)
        let encoder = ControlRuntimeCodec.makeEncoder()
        let encoded = [
            String(decoding: try encoder.encode(snapshot), as: UTF8.self),
            String(decoding: try ControlRuntimeCodec.encodeBoundedPayload(frameMessage(.snapshot(snapshot)), limits: limits16KiB), as: UTF8.self),
            String(decoding: try ControlRuntimeCodec.encodeBoundedPayload(connections, limits: limits16KiB), as: UTF8.self),
            String(decoding: try ControlRuntimeCodec.encodeBoundedPayload(upstreams, limits: limits16KiB), as: UTF8.self),
        ]
        for text in encoded {
            XCTAssertFalse(text.contains("ARTIFICIAL"), "a secret-bearing token reached the wire")
            XCTAssertFalse(text.contains("?token="))
        }
        XCTAssertTrue(encoded[0].contains("files.example.test") || encoded[2].contains("files.example.test"))
    }

    // MARK: - Rows, ordering and bounded pages

    func testConnectionRowsAreNewestFirstWithAStableIDTieBreak() throws {
        let sameStart = Date(timeIntervalSince1970: 1_699_999_000)
        let connections = [
            ActiveConnectionInfo(id: uuid(3), destination: "a:443", upstream: "u", method: "CONNECT", startedAt: sameStart),
            ActiveConnectionInfo(id: uuid(2), destination: "b:443", upstream: "u", method: "CONNECT", startedAt: sameStart),
            ActiveConnectionInfo(id: uuid(1), destination: "c:443", upstream: "u", method: "CONNECT",
                                 startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        var kernel = fullKernelSnapshot()
        kernel.activeConnections = ActiveConnectionStore(connections)
        guard case .activeConnections(let rows) = try projectedRows(kernel, .activeConnections) else {
            return XCTFail("the connections project as their own kind")
        }
        XCTAssertEqual(rows.map { $0.id.rawValue }, [uuid(1), uuid(2), uuid(3)])
    }

    func testConnectionPagesCoverEveryConnectionOnceWithinTheFrame() throws {
        let connections = (0..<300).map { index in
            ActiveConnectionInfo(
                id: uuid(1_000 + index),
                destination: "files\(index).corp.example.test:443",
                upstream: "corp-\(index % 3)",
                method: "CONNECT",
                startedAt: Date(timeIntervalSince1970: 1_699_000_000 + Double(index)),
                lastActivityAt: Date(timeIntervalSince1970: 1_699_000_000 + Double(index)),
                bytesSent: index * 17,
                bytesReceived: index * 31,
                tunnel: index.isMultiple(of: 5),
                authMethod: index.isMultiple(of: 2) ? "Negotiate" : nil
            )
        }
        let revision = ControlCollectionRevision(rawValue: 11)!
        var collected: [ControlConnectionRow] = []
        var offset = 0
        var pages: [Int] = []

        var kernel = fullKernelSnapshot()
        kernel.activeConnections = ActiveConnectionStore(connections)
        let projected = try projectedRows(kernel, .activeConnections, maxRows: connections.count)
        guard case .activeConnections(let all) = projected else { return XCTFail("the connections project as their own kind") }
        while true {
            let message = try packPage(projected, offset: offset, revision: revision, limits: limits16KiB)
            let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits16KiB)
            XCTAssertLessThanOrEqual(frame.count, ControlSocket.maxFrameBytes)
            guard case .response(.page(.activeConnections(let page))) = message.body else {
                return XCTFail("the page is a different collection")
            }
            XCTAssertEqual(page.totalCount.rawValue, 300)
            collected += page.rows
            pages.append(page.rows.count)
            guard let next = page.nextCursor else { break }
            offset = next.offset.rawValue
        }

        XCTAssertEqual(collected.count, 300)
        XCTAssertEqual(Set(collected.map(\.id)).count, 300)
        XCTAssertEqual(collected, all)
        print("RUNTIME_MEASURE connection_pages_16KiB rows_per_page=\(pages) total=\(pages.reduce(0, +))")
    }

    // MARK: - The shared bounded projection, from kernel snapshots

    private func connection(_ value: Int, startedAt: TimeInterval = 1_700_000_000) -> ActiveConnectionInfo {
        ActiveConnectionInfo(
            id: uuid(value),
            destination: "host\(value).example:443",
            upstream: "corp-1",
            method: "CONNECT",
            startedAt: Date(timeIntervalSince1970: startedAt),
            lastActivityAt: Date(timeIntervalSince1970: startedAt + 1)
        )
    }

    private func kernel(connections: [ActiveConnectionInfo]) -> ProxyOrchestratorSnapshot {
        var snapshot = fullKernelSnapshot()
        snapshot.activeConnections = ActiveConnectionStore(connections)
        return snapshot
    }

    /// The encoded bytes of one projection that fits every bound, so a test can state exact bounds from the codec.
    private func projectedBytes(_ connections: [ActiveConnectionInfo]) throws -> Int {
        guard case .rows(_, let encodedBytes) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: kernel(connections: connections), within: ControlRowBudget(maxRows: 10, maxBytes: 1 << 20)
        ) else {
            throw ProjectionRefusal.overBudget
        }
        return encodedBytes
    }

    func testAnOverCountCollectionIsRefusedWholeBeforeAnyRowIsKept() {
        let snapshot = kernel(connections: (1...3).map { connection($0) })
        guard case .overBudget = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: snapshot, within: ControlRowBudget(maxRows: 2, maxBytes: 1 << 20)
        ) else {
            return XCTFail("three connections are refused whole against a two-row bound")
        }
    }

    func testAByteBoundRefusesTheWholeCollectionAndAnExactFitKeepsEveryRow() throws {
        let first = connection(1)
        let second = connection(2)
        let firstBytes = try projectedBytes([first])
        let secondBytes = try projectedBytes([second])
        let both = kernel(connections: [first, second])
        guard case .overBudget = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: both, within: ControlRowBudget(maxRows: 10, maxBytes: firstBytes)
        ) else {
            return XCTFail("the second row past the byte bound refuses the whole collection, not its first row")
        }
        guard case .rows(let rows, let encodedBytes) = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: both, within: ControlRowBudget(maxRows: 10, maxBytes: firstBytes + secondBytes)
        ) else {
            return XCTFail("an exact fit keeps every row")
        }
        XCTAssertEqual(rows.rowCount, 2)
        XCTAssertEqual(encodedBytes, firstBytes + secondBytes, "the bytes are the rows' own encodings, summed")
    }

    func testTheDNSProjectionKeepsSucceededThenFailedAndCountsEveryHost() throws {
        var snapshot = fullKernelSnapshot()
        snapshot.tunnelDNSOverrideStatus = .partial(succeeded: ["a.example", "b.example"], failed: ["c.example"])
        XCTAssertEqual(try RuntimeSnapshotControlProjection.tunnelDNSHostCount(snapshot.tunnelDNSOverrideStatus), 3)
        guard case .rows(.tunnelDNSHosts(let rows), _) = RuntimeSnapshotControlProjection.projectRows(
            .tunnelDNSHosts, from: snapshot, within: ControlRowBudget(maxRows: 3, maxBytes: 1 << 20)
        ) else {
            return XCTFail("three hosts fit a three-row bound")
        }
        XCTAssertEqual(rows.map(\.hostname), ["a.example", "b.example", "c.example"])
        XCTAssertEqual(rows.map(\.outcome), [.succeeded, .succeeded, .failed])
        guard case .overBudget = RuntimeSnapshotControlProjection.projectRows(
            .tunnelDNSHosts, from: snapshot, within: ControlRowBudget(maxRows: 2, maxBytes: 1 << 20)
        ) else {
            return XCTFail("a two-row bound refuses three hosts whole")
        }
    }

    /// A row the bridge cannot map is a closed internal failure. It is not reported as a capacity refusal, and no row is kept.
    func testAnUnmappableRowIsAnInternalFailureNotACapacityRefusal() {
        let snapshot = kernel(connections: [connection(1, startedAt: .nan)])
        guard case .internalFailure = RuntimeSnapshotControlProjection.projectRows(
            .activeConnections, from: snapshot, within: ControlRowBudget(maxRows: 10, maxBytes: 1 << 20)
        ) else {
            return XCTFail("a timestamp that cannot be mapped is an internal failure")
        }
    }

    func testAScalarSnapshotThatCannotFitTheFrameIsRefusedNotTruncated() throws {
        // Text over the input limit is omitted (decision 0029), so the snapshot still fits the 16 KiB frame. A frame smaller than the
        // snapshot still refuses it whole, and nothing is cut to make it fit.
        var kernel = fullKernelSnapshot()
        kernel.runtimeStatus.lastHealthSummary = String(repeating: "h", count: 20_000)
        let projected = try project(kernel)
        XCTAssertEqual(projected.healthSummary, ControlDisplayText.omittedValue)
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeFrame(frameMessage(.snapshot(projected)), limits: limits16KiB))
        let tiny = try ControlFrameLimits(maxFrameBytes: 512)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(frameMessage(.snapshot(projected)), limits: tiny)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    // MARK: - Snapshot read: bootstrap without a subscription

    func testASnapshotReadRoundTripsWithItsStampAndItsRequestCarriesNoPayload() throws {
        // A bootstrap learns the incarnation from the snapshot stamp. The request that asks for
        // it has no payload, so it takes no subscription slot.
        let message = ControlRuntimeMessage(correlation: correlation, body: .response(.snapshot(try project(fullKernelSnapshot()))))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits16KiB)
        let decoded = try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits16KiB)
        XCTAssertEqual(decoded, message)
        guard case .response(.snapshot(let snapshot)) = decoded.body else {
            return XCTFail("the reply is a snapshot")
        }
        XCTAssertEqual(snapshot.stamp.incarnation, stamp().incarnation)

        let request = ControlRuntimeMessage(
            correlation: correlation,
            body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(1), call: .readSnapshot))
        )
        let requestBytes = try ControlRuntimeCodec.encodeBoundedPayload(request, limits: limits16KiB)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(requestBytes, limits: limits16KiB), request)
        XCTAssertFalse(String(decoding: requestBytes, as: UTF8.self).contains("expectedIncarnation"))

        // A snapshot answer is measured like every other response, so an oversize one is refused.
        var widest = fullKernelSnapshot()
        widest.runtimeStatus.lastHealthSummary = String(repeating: "h", count: 20_000)
        let oversize = ControlRuntimeMessage(correlation: correlation, body: .response(.snapshot(try project(widest))))
        let tiny = try ControlFrameLimits(maxFrameBytes: 512)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(oversize, limits: tiny)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    // MARK: - Round trips and fail-closed values

    func testSnapshotFrameRoundTripsAndUnknownValuesFailClosed() throws {
        let snapshot = try project(fullKernelSnapshot())
        let message = frameMessage(.snapshot(snapshot))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits16KiB)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits16KiB), message)

        let text = String(decoding: try ControlRuntimeCodec.encodeBoundedPayload(message, limits: limits16KiB), as: UTF8.self)
        let tampered = text.replacingOccurrences(of: #""proxyState":"degraded""#, with: #""proxyState":"hibernating""#)
        XCTAssertNotEqual(tampered, text, "the fixture must contain the value it changes")
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(Data(tampered.utf8), limits: limits16KiB)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage)
        }
    }

    func testBaselineFrameRoundTripsWithItsExplicitReplayGap() throws {
        let baseline = try ControlBaseline(
            incarnation: stamp().incarnation,
            snapshot: try project(fullKernelSnapshot()),
            highWater: try XCTUnwrap(ControlEventCursor(rawValue: 10)),
            replay: .unavailable(.expiredHistory)
        )
        let message = frameMessage(.baseline(baseline))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits16KiB)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(Data(frame.dropLast()), limits: limits16KiB), message)
    }

    func testALiveBootstrapTakesItsIncarnationFromTheBaselineAlone() throws {
        // A live subscription sends no mutation. Its baseline is the only source of the
        // incarnation a later mutation names, so the baseline must carry it exactly.
        let baseline = try ControlBaseline(
            incarnation: stamp().incarnation,
            snapshot: try project(fullKernelSnapshot()),
            highWater: try XCTUnwrap(ControlEventCursor(rawValue: 0)),
            replay: .live
        )
        XCTAssertEqual(baseline.incarnation, stamp().incarnation)
        XCTAssertEqual(baseline.snapshot.stamp.incarnation, baseline.incarnation)
    }

    func testBaselineMustComeFromItsOwnIncarnationAndReplayMustEndAtItsHighWater() throws {
        let snapshot = try project(fullKernelSnapshot())
        let other = ControlHostIncarnation(rawValue: uuid(99))
        let high = ControlEventCursor(rawValue: 10)!
        XCTAssertThrowsError(try ControlBaseline(incarnation: other, snapshot: snapshot, highWater: high, replay: .live))
        XCTAssertThrowsError(try ControlBaseline(
            incarnation: stamp().incarnation, snapshot: snapshot, highWater: high,
            replay: .replay(from: ControlEventCursor(rawValue: 4)!, through: ControlEventCursor(rawValue: 9)!)
        ))
        XCTAssertNoThrow(try ControlBaseline(
            incarnation: stamp().incarnation, snapshot: snapshot, highWater: high,
            replay: .replay(from: ControlEventCursor(rawValue: 4)!, through: high)
        ))
    }

    func testAnUnavailablePreflightReadingCarriesNoItemsToMistakeForStopped() throws {
        let unavailable = ControlPreflightObservation(
            stamp: stamp(), observedAt: try ControlTimestamp(1_700_000_000), reading: .unavailable(.notObserved)
        )
        let text = String(decoding: try JSONEncoder().encode(unavailable), as: UTF8.self)
        XCTAssertFalse(text.contains("systemProxy"))
        XCTAssertEqual(try JSONDecoder().decode(ControlPreflightObservation.self, from: Data(text.utf8)), unavailable)

        let items = ControlPreflightItems(
            systemProxy: ControlIntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .requiresAdmin),
            environmentVariables: .init(enabled: false, alreadyApplied: false, privilegeLevel: .none),
            splitDNS: ControlIntegrationStatus(enabled: true, alreadyApplied: true, privilegeLevel: .requiresAdmin),
            helper: .installed
        )
        XCTAssertTrue(items.requiresAdmin)
        XCTAssertTrue(items.systemProxy.willPromptAdmin)
        XCTAssertFalse(items.splitDNS.willPromptAdmin)
    }

    // MARK: - Measurement (printed, not asserted against any cap)

    func testScalarSnapshotSizesAreReportedForReview() throws {
        // Measured with an explicit limit large enough to publish, so the figure is the
        // projection's size and not a refusal. No frame limit is chosen here.
        let roomy = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let empty = try RuntimeSnapshotControlProjection.snapshot(
            ProxyOrchestratorSnapshot(), stamp: stamp(), profileName: "", collectionRevisions: ControlCollectionRevisions()
        )
        let emptyBytes = try ControlRuntimeCodec.encodeBoundedPayload(frameMessage(.snapshot(empty)), limits: roomy).count

        var widest = fullKernelSnapshot()
        let long = String(repeating: "x", count: 253)
        let error = String(repeating: "e", count: 512)
        widest.runtimeStatus.activeUpstream = long
        widest.runtimeStatus.lastHealthSummary = error
        widest.proxyError = error
        widest.dnsError = error
        widest.tunnelsError = error
        widest.lastAuthFallbackReason = error
        let widestBytes = try ControlRuntimeCodec.encodeBoundedPayload(frameMessage(.snapshot(project(widest))), limits: roomy).count

        print("RUNTIME_MEASURE scalar_snapshot_empty_payload_bytes=\(emptyBytes)")
        print("RUNTIME_MEASURE scalar_snapshot_widest_strings_payload_bytes=\(widestBytes)")
    }
}
