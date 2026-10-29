// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// The one shipping control-service profile of the in-process app (decisions 0030, 0034 and 0038): the bounds its host's service enforces,
/// the frame cap its framed client decodes under, and the cap on the budget one request may carry.
///
/// The values are the measured engineering profile, taken as one set from the actual-client probe at `ef3e4df` (31 trials, 481 checks;
/// `docs/experiments/actual-runtime-client-profile`). The frame caps and the collection pair are owner selections; the remaining capacities,
/// ages and custody bounds were reviewed together with them. Every value is checked by `RuntimeServiceLimits.init`, which is the only judge
/// of the encoded-byte budget: the ceiling below is that initializer's own budget for these terms, so a term that grows is refused at
/// construction rather than widened silently.
///
/// The app's total Quit wait (decision 0039) is product policy, carried by the app, not a request timeout here.
package struct RuntimeServiceProfile: Sendable {
    package let limits: RuntimeServiceLimits
    /// The cap the framed client decodes replies and stream frames under: the selected ordinary reply cap.
    package let clientFrameLimits: ControlFrameLimits
    /// The largest remaining budget one ordinary request carries on the wire. A caller's own deadline still bounds every wait.
    package let wireBudgetCap: Duration

    /// The complete capture a client may assemble from pages, by count and encoded row bytes (decision 0038): the service's own bound,
    /// so a client never holds more rows of one revision than the host could capture.
    package var collectionRowBudget: ControlRowBudget {
        ControlRowBudget(maxRows: limits.collectionRowCapacity, maxBytes: limits.collectionByteCapacity)
    }

    /// Ordinary request and reply frames (decision 0030). The private frames are fixed by `PrivateConfigurationFrame` (decision 0034).
    static let maxRequestBytes = 4_096
    static let maxReplyBytes = 65_536
    /// Retained aliases, outcomes and finished-operation log entries, each for `retentionSeconds`.
    static let aliasCapacityPerPartition = 64
    static let outcomeCapacity = 64
    static let controlLogCapacity = 64
    static let retentionSeconds: Int64 = 300
    /// 64 alias records at the measured worst record (140 B), 64 outcomes at the widest measured outcome (`test-upstream`, 9,616 B) and
    /// 64 log entries at the widest measured finished frame (9,681 B). The sizing tests re-derive each product from the codec.
    static let aliasBytesPerPartition = 8_960
    static let outcomeBytes = 615_424
    static let controlLogBytes = 619_584
    /// Transport lanes in flight, one Stop per module, open subscribers and admitted ordinary operations.
    static let laneCapacity = 4
    static let stopLaneCapacityPerModule = 1
    static let subscriberLimit = 4
    static let ordinaryPendingCapacity = 8
    /// The event ring and ingress, the work one drain turn may do, the largest event, and one replay frame.
    static let ringCapacity = 256
    static let ringBytes = 262_144
    static let maxEventBytes = 8_192
    static let drainItems = 32
    static let drainBytes = 65_536
    static let replayItems = 32
    static let replayBytes = 32_768
    /// Decision 0038: 10,000 rows and 4 MiB per complete capture, 8 MiB retained across kinds; two row sets and four proofs per kind,
    /// retained for 60 s.
    static let collectionRows = 10_000
    static let collectionCaptureBytes = 4_194_304
    static let collectionRetainedBytes = 8_388_608
    static let collectionProofsPerKind = 4
    static let collectionRowRevisionsPerKind = 2
    static let collectionRowRetentionSeconds: Int64 = 60
    /// The largest snapshot a baseline frame carries beside the 64 KiB reply cap, and the stated per-subscriber charge.
    static let latestSnapshotBytes = 65_233
    static let subscriberRecordBytes = 1_024
    /// The initializer's encoded-byte budget for exactly these terms.
    static let retainedByteCeiling = 17_082_600
    /// The probe's composition cap, under which every measured flow, the widest final save included, completed.
    static let wireBudgetCapSeconds: Int64 = 30

    /// The profile the app composes its host's service with. Throws only if a term no longer fits its checked bounds, which the sizing
    /// tests pin; the composition then refuses to open its clients rather than run under a different profile.
    package static func inProcessApp() throws -> RuntimeServiceProfile {
        let limits = try RuntimeServiceLimits(
            maxRequestBytes: maxRequestBytes,
            maxReplyBytes: maxReplyBytes,
            aliasCapacityPerPartition: aliasCapacityPerPartition,
            aliasByteCapacityPerPartition: aliasBytesPerPartition,
            ordinaryPendingCapacity: ordinaryPendingCapacity,
            outcomeCapacity: outcomeCapacity,
            outcomeByteCapacity: outcomeBytes,
            retentionAge: .seconds(retentionSeconds),
            janitorBatch: 16,
            ordinaryLaneCapacity: laneCapacity,
            readLaneCapacity: laneCapacity,
            streamLaneCapacity: laneCapacity,
            stopLaneCapacityPerModule: stopLaneCapacityPerModule,
            subscriberLimit: subscriberLimit,
            ringCapacity: ringCapacity,
            ringByteCapacity: ringBytes,
            maxEventBytes: maxEventBytes,
            ingressCapacity: ringCapacity,
            ingressByteCapacity: ringBytes,
            drainItemsPerTurn: drainItems,
            drainBytesPerTurn: drainBytes,
            controlLogCapacity: controlLogCapacity,
            controlLogByteCapacity: controlLogBytes,
            replayChunkItems: replayItems,
            replayChunkBytes: replayBytes,
            collectionRowCapacity: collectionRows,
            collectionByteCapacity: collectionCaptureBytes,
            collectionProofCapacityPerKind: collectionProofsPerKind,
            collectionRowRevisionsPerKind: collectionRowRevisionsPerKind,
            collectionRetainedByteCapacity: collectionRetainedBytes,
            collectionRowRetentionAge: .seconds(collectionRowRetentionSeconds),
            latestSnapshotByteCapacity: latestSnapshotBytes,
            subscriberRecordBytes: subscriberRecordBytes,
            retainedByteCeiling: retainedByteCeiling
        )
        return RuntimeServiceProfile(
            limits: limits,
            clientFrameLimits: try ControlFrameLimits(maxFrameBytes: maxReplyBytes),
            wireBudgetCap: .seconds(wireBudgetCapSeconds)
        )
    }
}

extension RuntimeHost {
    /// The app's one framed client and private editor client over this host, under `profile` (decision 0031). The same production
    /// composition `makeInMemoryControlClient` builds; nothing concrete crosses it.
    package func makeInMemoryControlClient(profile: RuntimeServiceProfile) throws -> RuntimeInMemoryClients {
        try makeInMemoryControlClient(
            limits: profile.limits, clientFrameLimits: profile.clientFrameLimits, wireBudgetCap: profile.wireBudgetCap
        )
    }
}
