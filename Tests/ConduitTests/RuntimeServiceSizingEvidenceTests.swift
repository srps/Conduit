// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel
import ProxyControlBridge

/// Sizing evidence for a later owner choice. It prints the encoded sizes of a snapshot and of a baseline frame, measured with the
/// codec, for a few samples. It states no threshold and chooses no profile. Each sample is an encoded size of one projected snapshot,
/// and the samples are not the maximum: the projection's own text bounds are not exercised here.
@MainActor
final class RuntimeServiceSizingEvidenceTests: XCTestCase {
    func testMeasuredSnapshotAndBaselineFramesArePrintedForEachSample() throws {
        let limits = try RuntimeServiceFixtures.limits()
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let samples: [(label: String, profile: String)] = [
            ("empty-profile", ""),
            ("plain-profile", "Corp"),
            ("quote-backslash-profile", String(repeating: "\"\\", count: 64)),
        ]
        print("RUNTIME-SIZING schema=ControlRuntimeSnapshot encoder=ControlRuntimeCodec.makeEncoder fixture=observationSnapshot(default projection) baselineFrameOverheadBytes=\(limits.baselineFrameOverheadBytes) subscriberRecordBytes=\(limits.subscriberRecordBytes)")
        for sample in samples {
            let snapshot = try observationSnapshot(presentation: 9, profile: sample.profile)
            let payload = try RuntimeWireSize.bytes(of: snapshot)
            let snapshotFrame = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: .frame(.snapshot(snapshot))),
                limits: frameLimits
            ).count
            let baseline = try ControlBaseline(
                incarnation: snapshot.stamp.incarnation,
                snapshot: snapshot,
                highWater: try XCTUnwrap(ControlEventCursor(rawValue: 0)),
                replay: .live
            )
            let baselineFrame = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: .frame(.baseline(baseline))),
                limits: frameLimits
            ).count
            print("RUNTIME-SIZING sample=\(sample.label) profileUTF8Bytes=\(sample.profile.utf8.count) snapshotPayloadBytes=\(payload) snapshotFrameBytes=\(snapshotFrame) baselineFrameBytes=\(baselineFrame)")
            XCTAssertGreaterThan(snapshotFrame, payload)
            XCTAssertGreaterThan(baselineFrame, payload)
        }
    }

    /// A kernel snapshot whose every free-text field holds `text`, and whose counters are the largest value the wire accepts. The Bridge
    /// sanitizes text and does not cap it, so the length is the caller's, and the sample states it.
    private func populatedKernel(_ text: String) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded)
        kernel.runtimeStatus.activeUpstream = text
        kernel.runtimeStatus.lastHealthSummary = text
        kernel.proxyError = text
        kernel.dnsError = text
        kernel.tunnelsError = text
        kernel.vpnInterfaceName = text
        kernel.lastAuthFallbackReason = text
        kernel.lastAuthOutcomeAt = Date(timeIntervalSince1970: 1_900_000_000)
        kernel.dnsQueryCount = Int.max
        kernel.dnsDoHFallbackCount = Int.max
        kernel.dnsCacheHitCount = Int.max
        kernel.tunnelActiveCount = Int.max
        kernel.tunnelSessionCount = Int.max
        return kernel
    }

    /// One text field at the approved display bound (1,024 bytes) and at two sizes beside it, plain and quote/NUL. Only the profile name
    /// changes, so the payload delta is the cost of that field. No cap is chosen here: the numbers feed the owner's text decision.
    func testATextFieldAtItsBoundsIsMeasuredPlainAndEscaped() throws {
        let stamp = ControlRuntimeStamp(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: 9)),
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 2)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 5))
        )
        for length in [64, 256, 512, 1024] {
            let samples = [
                ("plain", String(repeating: "a", count: length)),
                ("quote-nul", String(repeating: "\"\u{0}", count: length / 2)),
                ("all-nul", String(repeating: "\u{0}", count: length)),
            ]
            for (label, text) in samples {
                let snapshot = try RuntimeSnapshotControlProjection.snapshot(
                    ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded),
                    stamp: stamp,
                    profileName: text,
                    collectionRevisions: ControlCollectionRevisions()
                )
                print("RUNTIME-SIZING-TEXT field=profileName rawBytes=\(text.utf8.count) sample=\(label) payloadBytes=\(try RuntimeWireSize.bytes(of: snapshot))")
            }
        }
    }

    /// Eight scalar text fields, each 513 raw bytes, through the Bridge: the escape-heavy sample and its plain twin have the same raw
    /// length, so their difference is the encoding of quote, backslash, NUL and the multi-byte characters. This is not a full maximum: the
    /// collection rows, the tunnel DNS reason and the bindings are absent. Both samples go through the codec.
    func testEightScalarTextFieldsAreMeasuredEscapedAndPlainThroughTheBridge() throws {
        let escaped = String(repeating: "\"\\\u{0}é😀", count: 57)
        let plain = String(repeating: "abcdefghi", count: 57)
        XCTAssertEqual(escaped.utf8.count, 513)
        XCTAssertEqual(plain.utf8.count, 513)
        let frameLimits = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let stamp = ControlRuntimeStamp(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: Int.max)),
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: Int.max)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: Int.max))
        )
        var payloads: [String: Int] = [:]
        for (label, text) in [("escaped", escaped), ("plain", plain)] {
            let snapshot = try RuntimeSnapshotControlProjection.snapshot(
                populatedKernel(text),
                stamp: stamp,
                profileName: text,
                collectionRevisions: ControlCollectionRevisions()
            )
            let payload = try RuntimeWireSize.bytes(of: snapshot)
            let snapshotFrame = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: .frame(.snapshot(snapshot))),
                limits: frameLimits
            ).count
            let baseline = try ControlBaseline(
                incarnation: snapshot.stamp.incarnation,
                snapshot: snapshot,
                highWater: try XCTUnwrap(ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition)),
                replay: .replay(
                    from: try XCTUnwrap(ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition)),
                    through: try XCTUnwrap(ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition))
                )
            )
            let baselineFrame = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: .frame(.baseline(baseline))),
                limits: frameLimits
            ).count
            payloads[label] = payload
            print("RUNTIME-SIZING-SCALAR-TEXT sample=\(label) rawTextBytesPerField=513 scalarTextFields=8 rowsAbsent=true counters=Int.max revisions=Int.max"
                + " snapshotPayloadBytes=\(payload) snapshotFrameBytes=\(snapshotFrame) worstBaselineFrameBytes=\(baselineFrame)")
        }
        XCTAssertGreaterThan(payloads["escaped"] ?? 0, payloads["plain"] ?? 0, "escaping makes the encoded text larger than the raw text")
    }
}
