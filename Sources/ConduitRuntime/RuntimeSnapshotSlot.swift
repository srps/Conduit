// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// Why the slot did not retain an owner snapshot. Each reason names one broken invariant or one exhausted counter. None of
/// them is a capacity refusal of the caller's request, so the service maps each one to a closed fault or a terminal end.
enum RuntimeSnapshotRefusal: Equatable {
    /// The snapshot names another incarnation than the service's.
    case incarnation
    /// The snapshot could not be encoded, so it cannot be measured or retained.
    case notEncodable
    /// The encoded snapshot is larger than the slot's declared bound. The owner's projection is bounded by construction, so this is a broken invariant.
    case overBound
    /// The owner reported a different body under the presentation revision the slot already holds.
    case conflict
    /// The owner reported a presentation revision older than the one the slot holds.
    case regressed
    /// The private delivery generation cannot advance. The slot is then sticky: subscribers resync, and nothing newer is shown.
    case exhausted
}

/// The outcome of offering one owner snapshot to the slot.
enum RuntimeSnapshotOffer: Equatable {
    /// The owner's snapshot equals the held one. No generation advanced.
    case unchanged
    /// The held snapshot was replaced under a new private generation.
    case replaced
    /// The offer was not retained. Nothing in the slot changed.
    case refused(RuntimeSnapshotRefusal)
}

/// The one latest safe snapshot, coalesced for every subscriber, with its encoded size and a private delivery generation. A
/// subscriber that has seen the generation needs no frame, and one that has not receives the latest snapshot, never one per change.
///
/// The generation names a delivery. It is not the owner's freshness, so it does not replace the owner's presentation, configuration
/// or lifecycle stamp, which are kept verbatim in the snapshot. An offer that equals the held snapshot advances nothing. The slot
/// measures an offer before it retains it, so a refused offer never replaces the held snapshot.
struct RuntimeSnapshotSlot {
    let incarnation: ControlHostIncarnation
    /// The encoded bytes one retained snapshot may hold. An offer over it is refused.
    let byteCapacity: Int
    private(set) var latest: ControlRuntimeSnapshot?
    /// The encoded size of `latest`, measured when it was offered.
    private(set) var latestBytes = 0
    /// The generation of `latest`. It starts at zero, which means nothing was retained, and it advances once per replacement.
    private(set) var generation: Int
    /// Set when the generation cannot advance. The slot never replaces `latest` again, and every subscriber ends with a resync.
    private(set) var exhausted = false

    /// `generationSeed` starts the counter at a given value. It exists for tests of exhaustion, and it is clamped to the
    /// representable range.
    init(incarnation: ControlHostIncarnation, byteCapacity: Int, generationSeed: Int = 0) {
        self.incarnation = incarnation
        self.byteCapacity = byteCapacity
        generation = min(max(generationSeed, 0), Int.max)
    }

    /// Offers one owner snapshot with its measured size, or nil when it could not be encoded. The checks run before any
    /// state changes, so a refusal leaves `latest` and `generation` as they were.
    mutating func offer(_ snapshot: ControlRuntimeSnapshot, encodedBytes: Int?) -> RuntimeSnapshotOffer {
        // Exhaustion is sticky and is decided first, whatever the owner reports. An owner that returns the held value cannot recover
        // the slot, because a read and an open must not answer from a state the service stopped being able to show.
        guard !exhausted else { return .refused(.exhausted) }
        guard snapshot.stamp.incarnation == incarnation else { return .refused(.incarnation) }
        guard let encodedBytes else { return .refused(.notEncodable) }
        guard encodedBytes <= byteCapacity else { return .refused(.overBound) }
        if let held = latest {
            if snapshot == held { return .unchanged }
            let revision = snapshot.stamp.presentationRevision
            let heldRevision = held.stamp.presentationRevision
            if revision < heldRevision { return .refused(.regressed) }
            if revision == heldRevision { return .refused(.conflict) }
        }
        guard let next = RuntimeCounter.successor(generation) else {
            exhausted = true
            return .refused(.exhausted)
        }
        generation = next
        latest = snapshot
        latestBytes = encodedBytes
        return .replaced
    }
}
