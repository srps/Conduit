// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel
import ProxyControlBridge

/// The candidate runtime service profile, as TEST-ONLY evidence for the owner's selection. Nothing here is a shipping default: no admission,
/// config acceptance or product value changes. The candidate is built through the actual `RuntimeServiceLimits` initializer, which is the only
/// judge of its bounds. A refusal is reported, never clamped.
enum RuntimeServiceProfileCandidate {
    /// The candidate values the owner's review listed. `subscriberRecordBytes` defaults to the measured layout of the record, read through
    /// `@testable` access, so no product access is widened. `retainedByteCeiling` is a parameter only for the negative controls.
    static func limits(
        retainedByteCeiling: Int = 33_554_432,
        subscriberRecordBytes: Int = MemoryLayout<RuntimeSubscriberRecord>.size
    ) throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: 4_096,
            maxReplyBytes: 65_536,
            aliasCapacityPerPartition: 64,
            aliasByteCapacityPerPartition: 16_384,
            ordinaryPendingCapacity: 8,
            outcomeCapacity: 128,
            outcomeByteCapacity: 262_144,
            retentionAge: .seconds(60),
            janitorBatch: 16,
            ordinaryLaneCapacity: 8,
            readLaneCapacity: 8,
            streamLaneCapacity: 8,
            stopLaneCapacityPerModule: 2,
            subscriberLimit: 8,
            ringCapacity: 512,
            ringByteCapacity: 1_048_576,
            maxEventBytes: 8_192,
            ingressCapacity: 64,
            ingressByteCapacity: 262_144,
            drainItemsPerTurn: 16,
            drainBytesPerTurn: 65_536,
            controlLogCapacity: 128,
            controlLogByteCapacity: 262_144,
            replayChunkItems: 32,
            replayChunkBytes: 32_768,
            collectionRowCapacity: 10_000,
            collectionByteCapacity: 8_388_608,
            collectionProofCapacityPerKind: 8,
            collectionRowRevisionsPerKind: 2,
            collectionRetainedByteCapacity: 16_777_216,
            collectionRowRetentionAge: .seconds(60),
            latestSnapshotByteCapacity: 57_344,
            subscriberRecordBytes: subscriberRecordBytes,
            retainedByteCeiling: retainedByteCeiling
        )
    }

    /// Frame limits for one cap, as the codec takes them.
    static func frameLimits(_ bytes: Int) throws -> ControlFrameLimits {
        try ControlFrameLimits(maxFrameBytes: bytes)
    }
}

enum RuntimeServiceProfileError: Error {
    case overBudget
    case internalFailure
    case wrongCollection
    case unexpectedPage
    case resourceSampleFailed
}

/// One page run, summed: how the packer split the rows, and the largest encoded frame it produced.
struct RuntimeServiceProfilePackSummary {
    let pages: Int
    let firstPageRows: Int
    let packedRows: Int
    let maxFrameBytes: Int
}

/// Encoded row sizes of one projection: the mean, the 95th percentile and the maximum, all integer bytes, and the exact total.
struct RuntimeServiceProfileRowStats {
    let count: Int
    let total: Int
    let mean: Int
    let p95: Int
    let max: Int
}

/// Kernel fixtures for the connection rows. Both shapes go through the actual kernel type and the actual Bridge projection.
enum RuntimeServiceProfileKernels {
    /// Typical connections: ASCII endpoints of 20 to 60 bytes, with separators, so the kernel's destination sanitizer does not mask them.
    static func typical(connections count: Int) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
        kernel.activeConnections = ActiveConnectionStore((0..<count).map { n in
            ActiveConnectionInfo(
                id: RuntimeServiceFixtures.uuid(n + 1),
                destination: "host\(n).corp.example.test:443",
                upstream: "proxy\(n % 4).corp.example.test:8080",
                method: "CONNECT",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
                lastActivityAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(n)),
                bytesSent: n * 1_024,
                bytesReceived: n * 4_096,
                tunnel: n % 2 == 0,
                authMethod: n % 3 == 0 ? nil : "Negotiate"
            )
        })
        return kernel
    }

    /// MIXED ESCAPE TEXT, not the encoded maximum. Four different bodies, each over the 512-byte diagnostic cap (1,025 bytes), rotated across the four
    /// fields so every row holds one of each. Rows share bodies by value. Per-row bytes are counted, and that count is not physical memory.
    static let mixedBodies: [String] = [
        String(repeating: "\u{0}", count: 1_025),
        String(repeating: "\"", count: 1_025),
        String(repeating: "\\", count: 1_025),
        DisplayBoundsFixture.text(atLeast: 1_025),
    ]

    /// Mixed-escape connections, labelled as such: each row carries one body per field, rotated. This is not the encoded maximum.
    static func mixedEscape(connections count: Int) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
        let bodies = mixedBodies
        kernel.activeConnections = ActiveConnectionStore((0..<count).map { n in
            ActiveConnectionInfo(
                id: RuntimeServiceFixtures.uuid(n + 1),
                destination: bodies[n % 4],
                upstream: bodies[(n + 1) % 4],
                method: bodies[(n + 2) % 4],
                startedAt: Date(timeIntervalSince1970: 1_699_999_000),
                lastActivityAt: Date(timeIntervalSince1970: 1_699_999_500),
                bytesSent: 1_024,
                bytesReceived: 4_096,
                tunnel: false,
                authMethod: bodies[(n + 3) % 4]
            )
        })
        return kernel
    }

    /// The strongest string-field candidate measured for one connection row, not a universal maximum. All four displayed text fields are one 1,025-byte NUL run, more than twice each
    /// 512-byte cap, so each field is cut to its cap and each byte escapes to six. The counts are `Int.max`, the widest integers this row carries. One
    /// body is shared by every row and field, so the kernel holds one body. Per-row bytes are counted, not physical memory.
    static func allNUL(connections count: Int) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
        let body = String(repeating: "\u{0}", count: 1_025)
        kernel.activeConnections = ActiveConnectionStore((0..<count).map { n in
            ActiveConnectionInfo(
                id: RuntimeServiceFixtures.uuid(n + 1),
                destination: body,
                upstream: body,
                method: body,
                startedAt: Date(timeIntervalSince1970: 1_699_999_000),
                lastActivityAt: Date(timeIntervalSince1970: 1_699_999_500),
                bytesSent: Int.max,
                bytesReceived: Int.max,
                tunnel: false,
                authMethod: body
            )
        })
        return kernel
    }

    /// The Bridge's one bounded projection of the connection rows, returned as the closed answer.
    static func projection(_ kernel: ProxyOrchestratorSnapshot, maxRows: Int, maxBytes: Int) -> ControlProjection {
        RuntimeSnapshotControlProjection.projectRows(
            .activeConnections,
            from: kernel,
            within: ControlRowBudget(maxRows: maxRows, maxBytes: maxBytes)
        )
    }

    /// The complete connection rows and their exact encoded total. An over-budget or failed projection throws, so a test cannot read a partial answer.
    static func connectionRows(
        _ kernel: ProxyOrchestratorSnapshot,
        maxRows: Int,
        maxBytes: Int
    ) throws -> (rows: [ControlConnectionRow], encodedBytes: Int) {
        switch projection(kernel, maxRows: maxRows, maxBytes: maxBytes) {
        case .rows(.activeConnections(let rows), encodedBytes: let bytes):
            return (rows, bytes)
        case .rows:
            throw RuntimeServiceProfileError.wrongCollection
        case .overBudget:
            throw RuntimeServiceProfileError.overBudget
        case .internalFailure:
            throw RuntimeServiceProfileError.internalFailure
        }
    }

    /// Each row's encoded size, as the codec writes it, with the mean, the 95th percentile and the maximum. The total is the sum of those sizes.
    static func rowStats(_ rows: [ControlConnectionRow]) throws -> RuntimeServiceProfileRowStats {
        var sizes: [Int] = []
        sizes.reserveCapacity(rows.count)
        for row in rows {
            sizes.append(try RuntimeWireSize.bytes(of: row))
        }
        let total = sizes.reduce(0, +)
        let sorted = sizes.sorted()
        let p95Index = sorted.isEmpty ? 0 : min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return RuntimeServiceProfileRowStats(
            count: sizes.count,
            total: total,
            mean: sizes.isEmpty ? 0 : total / sizes.count,
            p95: sorted.isEmpty ? 0 : sorted[max(0, p95Index)],
            max: sorted.last ?? 0
        )
    }

    /// Packs every row through the actual `ControlPagePacker`, page by page, and checks each page's frame through the codec. Every row must land
    /// in exactly one page, which the caller checks through `packedRows`.
    static func pack(_ rows: [ControlConnectionRow], limits: ControlFrameLimits) throws -> RuntimeServiceProfilePackSummary {
        let incarnation = RuntimeServiceFixtures.incarnation(1)
        guard let revision = ControlCollectionRevision(rawValue: 1) else { throw RuntimeServiceProfileError.internalFailure }
        let correlation = RuntimeServiceFixtures.requestID(7)
        var offset = 0
        var pages = 0
        var firstPageRows = 0
        var maxFrameBytes = 0
        while offset < rows.count {
            let message = try ControlPagePacker.page(
                of: rows,
                offset: offset,
                incarnation: incarnation,
                revision: revision,
                correlation: correlation,
                limits: limits
            ) { ControlPageReply.activeConnections($0) }
            guard case .response(.page(.activeConnections(let page))) = message.body, !page.rows.isEmpty else {
                throw RuntimeServiceProfileError.unexpectedPage
            }
            maxFrameBytes = max(maxFrameBytes, try ControlRuntimeCodec.encodeFrame(message, limits: limits).count)
            if pages == 0 { firstPageRows = page.rows.count }
            offset += page.rows.count
            pages += 1
        }
        return RuntimeServiceProfilePackSummary(pages: pages, firstPageRows: firstPageRows, packedRows: offset, maxFrameBytes: maxFrameBytes)
    }
}

/// Phase A: the candidate constructs, every current call frames under the request cap, and the page packer's 64 KiB pages carry real rows.
@MainActor
final class RuntimeServiceProfileEvidenceTests: XCTestCase {
    func testCandidateConstructsThroughTheActualInitializerAndPrintsDerivedSizes() throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        print(
            "RUNTIME-SERVICE-PROFILE candidate constructed=true subscriberRecordBytes=\(limits.subscriberRecordBytes)"
                + " retainedByteBudget=\(limits.retainedByteBudget) retainedByteCeiling=\(limits.retainedByteCeiling)"
                + " headroom=\(limits.retainedByteCeiling - limits.retainedByteBudget)"
        )
        print(
            "RUNTIME-SERVICE-PROFILE derived admissionWorstBytes=\(limits.admissionWorstBytes) requestIDWorstBytes=\(limits.requestIDWorstBytes)"
                + " fingerprintBytes=\(limits.fingerprintBytes) aliasRecordWorstBytes=\(limits.aliasRecordWorstBytes)"
                + " internalFailureOutcomeBytes=\(limits.internalFailureOutcomeBytes) internalFailureFinishedBytes=\(limits.internalFailureFinishedBytes)"
                + " operationCapacity=\(limits.operationCapacity) operationRecordBytes=\(limits.operationRecordBytes)"
        )
        print(
            "RUNTIME-SERVICE-PROFILE derived laneCount=\(limits.laneCount) laneRetainedBytes=\(limits.laneRetainedBytes)"
                + " firstFrameRetainedBytes=\(limits.firstFrameRetainedBytes) snapshotRetainedBytes=\(limits.snapshotRetainedBytes)"
                + " subscriberRecordRetainedBytes=\(limits.subscriberRecordRetainedBytes) collectionProofBytes=\(limits.collectionProofBytes)"
                + " baselineFrameOverheadBytes=\(limits.baselineFrameOverheadBytes) maxEventBytes=\(limits.maxEventBytes)"
        )
        print(
            "RUNTIME-SERVICE-PROFILE structural aliasPartitions=\(RuntimePartition.all.count)"
                + " quitPartitionOperations=\(RuntimeServiceLimits.quitPartitionOperations) quitLane=\(RuntimeServiceLimits.quitLaneCapacity)"
                + " privateTransfer=\(RuntimeServiceLimits.privateTransferCapacity) privateInput=\(RuntimeServiceLimits.privateInputCapacity)"
                + " privateTransferRetainedBytes=\(limits.privateTransferRetainedBytes) privateInputRetainedBytes=\(limits.privateInputRetainedBytes)"
                + " (encoded bytes outside retainedByteBudget; not an RSS bound)"
        )
        XCTAssertLessThanOrEqual(limits.retainedByteBudget, limits.retainedByteCeiling)
    }

    /// The budget is the binding check: the candidate constructs at exactly its own budget, and one byte less is refused by the constructor.
    /// The budget does not depend on the ceiling, so the two constructions measure the same value.
    func testTheConstructorRefusesOneByteBelowTheCandidateBudgetAndAcceptsExactlyIt() throws {
        let budget = try RuntimeServiceProfileCandidate.limits().retainedByteBudget
        XCTAssertNoThrow(try RuntimeServiceProfileCandidate.limits(retainedByteCeiling: budget))
        XCTAssertThrowsError(try RuntimeServiceProfileCandidate.limits(retainedByteCeiling: budget - 1)) { error in
            XCTAssertTrue(error is ControlRuntimeWireError, "the constructor refuses with its typed wire error")
        }
    }

    /// The subscriber charge must hold the measured record. A charge one byte under the layout is refused, so the table cannot be
    /// under-charged by a configuration.
    func testTheConstructorRefusesASubscriberChargeBelowTheMeasuredRecord() throws {
        let measured = MemoryLayout<RuntimeSubscriberRecord>.size
        XCTAssertThrowsError(try RuntimeServiceProfileCandidate.limits(subscriberRecordBytes: measured - 1))
    }

    /// Every current call, at its widest legal identifiers, cursors and budgets, encodes as one request frame within the server's request cap.
    /// The encode is the check: a frame above the cap throws, and the test fails with that error. Future Start and private workflow payloads are
    /// not defined on this wire and are not measured here.
    func testEveryCurrentCallFramesWithinTheServerRequestCapAtItsWidestLegalForm() throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let serverCap = try RuntimeServiceProfileCandidate.frameLimits(limits.maxRequestBytes)
        // The widest budget the wire carries, which is the protocol's own range rather than a candidate value.
        let budget = try ControlWireBudget(Int(Int32.max))
        let requestID = ControlRequestID(rawValue: RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF))
        for (label, call) in try RuntimeServiceProfileEvidenceTests.widestCalls() {
            let message = ControlRuntimeMessage(
                correlation: requestID,
                body: .request(ControlRuntimeRequest(budget: budget, call: call))
            )
            let bytes = try ControlRuntimeCodec.encodeFrame(message, limits: serverCap).count
            print("RUNTIME-SERVICE-PROFILE request call=\(label) frameBytes=\(bytes) serverRequestCap=\(limits.maxRequestBytes)")
            XCTAssertLessThanOrEqual(bytes, limits.maxRequestBytes)
        }
    }

    /// The Quit's wire form is strict. The widest legal Quit round-trips; from its own encoding, both final saves naming one request, a
    /// negative or out-of-range total, and a missing total or flush are each refused on decode. Building a flush that names one request
    /// twice is refused too.
    func testTheWidestQuitRoundTripsAndItsMalformedFormsAreRefused() throws {
        let widest = try XCTUnwrap(try Self.widestCalls().first { $0.label == "submit-quit-both-flushes" })
        guard case .submit(let request) = widest.call, case .quit(_, let flush) = request.command else {
            return XCTFail("the widest Quit is a submitted quit")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(request.command), as: UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(ControlRuntimeCommand.self, from: Data(text.utf8)), request.command)

        let configuration = try XCTUnwrap(flush.configuration)
        let preferences = try XCTUnwrap(flush.preferences)
        func quoted(_ id: ControlRequestID) throws -> String { String(decoding: try encoder.encode(id), as: UTF8.self) }
        let total = "\"totalMilliseconds\":\(Int32.max)"
        XCTAssertTrue(text.contains(total), text)
        let flushText = String(decoding: try encoder.encode(flush), as: UTF8.self)
        let refused = [
            text.replacingOccurrences(of: try quoted(preferences), with: try quoted(configuration)),
            text.replacingOccurrences(of: total, with: "\"totalMilliseconds\":-1"),
            text.replacingOccurrences(of: total, with: "\"totalMilliseconds\":\(Int(Int32.max) + 1)"),
            text.replacingOccurrences(of: total + ",", with: ""),
            text.replacingOccurrences(of: "\"flush\":" + flushText + ",", with: ""),
        ]
        for mutated in refused {
            XCTAssertNotEqual(mutated, text, "the mutation applies")
            XCTAssertThrowsError(try JSONDecoder().decode(ControlRuntimeCommand.self, from: Data(mutated.utf8)), mutated)
        }
        XCTAssertThrowsError(try ControlQuitFlush(configuration: configuration, preferences: configuration))
    }

    /// Each current call at its widest legal form. Every identifier is the widest UUID value, every revision and count is `Int.max`, and every
    /// module and collection kind is the one with the longest name or the largest response.
    static func widestCalls() throws -> [(label: String, call: ControlRuntimeCall)] {
        let id = RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF)
        let incarnation = ControlHostIncarnation(rawValue: id)
        let requestID = ControlRequestID(rawValue: id)
        let operation = ControlOperationID(rawValue: id)
        guard let config = ControlConfigRevision(rawValue: Int.max),
              let lifecycle = ControlLifecycleRevision(rawValue: Int.max),
              let revision = ControlCollectionRevision(rawValue: Int.max),
              let cursorEvent = ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition)
        else {
            throw RuntimeServiceProfileError.internalFailure
        }
        let upstream = ControlUpstreamReference(configRevision: config, upstreamID: ControlUpstreamID(rawValue: id))
        // The widest platform baseline: the widest namespace and the full UInt64 version, which the wire carries as an exact number.
        let platformBaseline = PrivateBaseline(namespace: PrivateBaselineNamespace(rawValue: id), component: .platform, version: .max)
        // The widest Quit: the protocol's largest total budget, and both final saves named, each by a widest UUID. The two must differ.
        let flush = try ControlQuitFlush(
            configuration: ControlRequestID(rawValue: id),
            preferences: ControlRequestID(rawValue: RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFE))
        )
        let commands: [(label: String, command: ControlRuntimeCommand)] = [
            ("submit-stop", .stop(.tunnels)),
            ("submit-restart", .restart(.tunnels, ifLifecycleRevision: lifecycle)),
            // Only a proxy Restart may name the companion's DNS revision, so this is the widest Restart now (decision 0036).
            ("submit-restart-companion", .restart(.proxy, ifLifecycleRevision: lifecycle, conditionalDNSRevision: lifecycle)),
            ("submit-test-dns", .testDNS),
            ("submit-test-upstream", .testUpstream(upstream)),
            ("submit-refresh-preflight", .refreshPreflight),
            ("submit-set-launch-at-login", .setLaunchAtLogin(false, ifPlatformBaseline: platformBaseline)),
            ("submit-quit-both-flushes", .quit(total: try ControlWireBudget(Int(Int32.max)), flush: flush)),
        ]
        var calls: [(label: String, call: ControlRuntimeCall)] = []
        for entry in commands {
            let request = ControlOperationRequest(requestID: requestID, expectedIncarnation: incarnation, command: entry.command)
            calls.append((label: entry.label, call: ControlRuntimeCall.submit(request)))
        }
        let query = ControlOperationQuery(expectedIncarnation: incarnation, operationID: operation)
        calls.append((label: "outcome", call: ControlRuntimeCall.outcome(query)))
        let lookup = ControlRequestQuery(expectedIncarnation: incarnation, requestID: requestID)
        calls.append((label: "request-lookup", call: ControlRuntimeCall.requestLookup(lookup)))
        calls.append((label: "subscribe-live", call: ControlRuntimeCall.subscribe(.live)))
        let resume = ControlSubscriptionRequest.resume(incarnation: incarnation, from: cursorEvent)
        calls.append((label: "subscribe-resume", call: ControlRuntimeCall.subscribe(resume)))
        let maxOffset = try ControlCount(Int.max)
        for kind in ControlCollectionKind.allCases {
            let cursor = ControlPageCursor(revision: revision, offset: maxOffset)
            let page = ControlPageRequest(expectedIncarnation: incarnation, collection: kind, cursor: cursor)
            calls.append((label: "read-page-\(kind.rawValue)", call: ControlRuntimeCall.readPage(page)))
        }
        calls.append((label: "read-snapshot", call: ControlRuntimeCall.readSnapshot))
        return calls
    }

    /// Every settled outcome kind at its widest legal form, measured as the service retains it (`RuntimeServiceCore.measureRetained`) and as the
    /// codec frames its lookup reply and its stream settlement. The candidate's outcome store, control log and reply cap each hold the widest.
    /// The configuration receipt is measured both with the conditional DNS companion and with all three members, and a DNS Stop completion with
    /// its causal disable write. Each closed field is the case with the longest encoding, chosen by encoding every case; numbers are at their
    /// maximum and baselines at the full `UInt64` version. Nothing is promoted to a default: the candidate is the test's own profile.
    func testTheWidestOutcomeOfEveryKindFitsTheCandidateOutcomeLogAndReplyBounds() throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let replyLimits = try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
        let id = RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF)
        let operation = ControlOperationID(rawValue: id)
        let correlation = ControlRequestID(rawValue: id)
        var widestOutcome = 0
        for (label, outcome) in try Self.widestOutcomes() {
            let sizes = try RuntimeServiceCore.measureRetained(outcome, operation)
            let lookup = ControlRuntimeMessage(correlation: correlation, body: .response(.lookup(.finished(outcome))))
            let lookupFrame = try ControlRuntimeCodec.encodeFrame(lookup, limits: replyLimits)
            XCTAssertEqual(try ControlRuntimeCodec.decodeFullFrame(lookupFrame, limits: replyLimits), lookup, label)
            let settled = ControlRuntimeMessage(
                correlation: correlation, body: .frame(.operationFinished(ControlOperationFinished(operationID: operation, outcome: outcome)))
            )
            let streamFrame = try ControlRuntimeCodec.encodeFrame(settled, limits: replyLimits)
            print(
                "RUNTIME-SERVICE-PROFILE outcome kind=\(label) outcomeBytes=\(sizes.outcome) finishedBytes=\(sizes.finished)"
                    + " lookupReplyFrameBytes=\(lookupFrame.count) streamFrameBytes=\(streamFrame.count)"
                    + " outcomeByteCapacity=\(limits.outcomeByteCapacity) controlLogByteCapacity=\(limits.controlLogByteCapacity)"
                    + " maxReplyBytes=\(limits.maxReplyBytes) maxEventBytes=\(limits.maxEventBytes)"
            )
            XCTAssertLessThanOrEqual(sizes.outcome, limits.outcomeByteCapacity, label)
            XCTAssertLessThanOrEqual(sizes.finished, limits.controlLogByteCapacity, label)
            XCTAssertLessThanOrEqual(lookupFrame.count, limits.maxReplyBytes, label)
            XCTAssertLessThanOrEqual(streamFrame.count, limits.maxReplyBytes, label)
            widestOutcome = max(widestOutcome, sizes.outcome)
        }
        print("RUNTIME-SERVICE-PROFILE outcome widestOutcomeBytes=\(widestOutcome) internalFailureOutcomeBytes=\(limits.internalFailureOutcomeBytes)")
    }

    /// The candidate with the longest encoding. Every candidate is encoded; a tie keeps the first.
    static func widest<Value: Encodable>(_ candidates: [Value]) throws -> Value {
        var best: (value: Value, bytes: Int)?
        for candidate in candidates {
            let bytes = try RuntimeWireSize.bytes(of: candidate)
            if bytes > (best?.bytes ?? -1) { best = (candidate, bytes) }
        }
        guard let best else { throw RuntimeServiceProfileError.internalFailure }
        return best.value
    }

    /// Every write one file can report, each with its full-version baseline exactly when it verified.
    static func componentWrites(_ component: ControlConfigWorkflowFile, namespace: PrivateBaselineNamespace) throws -> [ControlComponentWrite] {
        let baseline = PrivateBaseline(namespace: namespace, component: component, version: .max)
        var writes: [ControlConfigWorkflowWrite] = [.persisted(reportedError: false), .persisted(reportedError: true), .unchanged, .notPersisted, .conflict]
        for cause in ControlConfigWorkflowUnknownCause.allCases {
            writes += [.unknown(cause, reportedError: false), .unknown(cause, reportedError: true)]
        }
        writes += ControlConfigWorkflowNotAttemptedCause.allCases.map { .notAttempted($0) }
        return try writes.map { try ControlComponentWrite(write: $0, baseline: $0.isVerified ? baseline : nil) }
    }

    /// Each settled outcome kind at its widest legal form, labelled.
    static func widestOutcomes() throws -> [(label: String, outcome: ControlOperationOutcome)] {
        let id = RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF)
        let namespace = PrivateBaselineNamespace(rawValue: id)
        let requestID = ControlRequestID(rawValue: id)
        let incarnation = ControlHostIncarnation(rawValue: id)
        guard let revision = ControlPresentationRevision(rawValue: Int.max),
              let config = ControlConfigRevision(rawValue: Int.max),
              let lifecycle = ControlLifecycleRevision(rawValue: Int.max)
        else {
            throw RuntimeServiceProfileError.internalFailure
        }
        func completed(_ command: ControlRuntimeCommandKind, _ result: ControlCommandResult) throws -> ControlOperationOutcome {
            .completed(try ControlCompletion(command: command, presentationRevision: revision, result: result))
        }

        let runtimeWrites = try componentWrites(.runtime, namespace: namespace)
        let platform = try widest(try componentWrites(.platform, namespace: namespace))
        let member = try widest(ControlLifecycleModuleResult.allCases)
        let companion = try widest(ControlLifecycleConditionalDNSResult.allCases)
        func receipts(_ modules: [ControlModule], conditionalDNS: ControlLifecycleConditionalDNSResult?) throws -> ControlConfigurationReceipt {
            try widest(try runtimeWrites.map { runtime in
                try ControlConfigurationReceipt(
                    requestID: requestID, incarnation: incarnation, runtime: runtime, platform: platform,
                    committedDNSForwarderEnabled: runtime.write.isVerified ? false : nil,
                    modules: modules.map { ControlModuleReceipt(module: $0, result: member) },
                    applied: false, conditionalDNS: conditionalDNS
                )
            })
        }
        let disable = try widest(try runtimeWrites.map {
            try ControlDNSDisableWrite(prior: PrivateBaseline(namespace: namespace, component: .runtime, version: .max), runtime: $0)
        })

        // The probe through the actual Bridge projection: both texts past their caps in NUL, which escapes widest, and the widest numbers.
        let nul = String(repeating: "\u{0}", count: 2_049)
        let probe = try RuntimeProbeControlProjection.upstreamProbe(ProbeResult(
            proxy: UpstreamProxy(name: nul, host: nul, port: 65_535, priority: 0), latencyMS: Int.max, reachable: false
        ))

        let status = ControlIntegrationStatus(enabled: false, alreadyApplied: false, privilegeLevel: try widest(ControlPrivilegeLevel.allCases))
        let items = ControlPreflightItems(
            systemProxy: status, environmentVariables: status, splitDNS: status, helper: try widest(ControlHelperStatus.allCases)
        )
        let reading = try widest([ControlPreflightReading.observed(items)] + ControlPreflightUnavailableReason.allCases.map { .unavailable($0) })
        let observedAt = try widest([
            try ControlTimestamp(-Double.greatestFiniteMagnitude), try ControlTimestamp(-2.2250738585072014e-308),
            try ControlTimestamp(-1.2345678901234567e-300),
        ])
        let preflight = ControlPreflightObservation(
            stamp: ControlRuntimeStamp(
                incarnation: incarnation, presentationRevision: revision, configRevision: config, lifecycleRevision: lifecycle,
                modules: ControlModuleRevisions(proxy: lifecycle, dns: lifecycle, tunnels: lifecycle)
            ),
            observedAt: observedAt, reading: reading
        )

        let moduleResult = try widest([ControlModuleResult.succeeded, .cleanupPending] + ControlFailureCode.allCases.map { .failed($0) })
        let partial = try ControlModuleOutcomes(ControlModule.allCases.map { ControlModuleOutcome(module: $0, result: moduleResult) })
        let preferences = try ControlPreferencesReceipt(
            requestID: requestID, incarnation: incarnation, preferences: try widest(try componentWrites(.preferences, namespace: namespace))
        )
        return [
            ("configuration-receipt-conditional-dns", .configurationSettled(try receipts([.proxy, .tunnels], conditionalDNS: companion))),
            ("configuration-receipt-three-members", .configurationSettled(try receipts(ControlModule.allCases, conditionalDNS: nil))),
            ("preferences-receipt", .preferencesSettled(preferences)),
            ("stop-dns-disable", try completed(.stop, .dnsDisable(disable))),
            ("stop-settled", try completed(.stop, .settled)),
            ("restart-settled", try completed(.restart, .settled)),
            ("quit-settled", try completed(.quit, .settled)),
            ("test-dns", try completed(.testDNS, .dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(65_535), answered: false)))),
            ("test-upstream", try completed(.testUpstream, .upstreamProbe(probe))),
            ("refresh-preflight", try completed(.refreshPreflight, .preflight(preflight))),
            ("set-launch-at-login", try completed(.setLaunchAtLogin, .platformWrite(platform))),
            ("partially-completed", .partiallyCompleted(partial)),
            ("failed", .failed(try widest(ControlFailureCode.allCases))),
            ("superseded", .superseded(by: ControlOperationID(rawValue: id))),
        ]
    }

    /// 64 KiB pages through the actual `ControlPagePacker` and codec, for typical rows, mixed-escape rows and all-NUL rows. Each row lands in
    /// exactly one page, and every page's frame is at most the cap. The rows come from the actual Bridge projection, not a parallel packer.
    func testSixtyFourKiBPagesCarryTypicalMixedAndAllNULConnectionRowsThroughThePacker() throws {
        let limits = try RuntimeServiceProfileCandidate.limits()
        let frame = try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
        let typical = try RuntimeServiceProfileKernels.connectionRows(
            RuntimeServiceProfileKernels.typical(connections: 1_000),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        let mixed = try RuntimeServiceProfileKernels.connectionRows(
            RuntimeServiceProfileKernels.mixedEscape(connections: 64),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        let allNUL = try RuntimeServiceProfileKernels.connectionRows(
            RuntimeServiceProfileKernels.allNUL(connections: 64),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        for (label, rows) in [("typical", typical.rows), ("mixed-escape", mixed.rows), ("all-nul", allNUL.rows)] {
            let summary = try RuntimeServiceProfileKernels.pack(rows, limits: frame)
            print(
                "RUNTIME-SERVICE-PROFILE page sample=\(label) rows=\(rows.count) pages=\(summary.pages)"
                    + " firstPageRows=\(summary.firstPageRows) maxFrameBytes=\(summary.maxFrameBytes) replyCap=\(limits.maxReplyBytes)"
            )
            XCTAssertEqual(summary.packedRows, rows.count, "every row lands in exactly one page")
            XCTAssertLessThanOrEqual(summary.maxFrameBytes, limits.maxReplyBytes)
            XCTAssertGreaterThan(summary.firstPageRows, 0)
        }
    }
}
