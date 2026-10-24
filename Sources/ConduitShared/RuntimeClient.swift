// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A local, absolute, monotonic deadline. A caller creates one per workflow, and
/// its nested waits take what remains of it instead of a fresh full budget. The
/// instant never leaves the process: the wire carries a remaining budget, and the
/// peer turns that into its own local deadline.
package struct RuntimeDeadline: Sendable, Equatable {
    package let instant: ContinuousClock.Instant

    package init(instant: ContinuousClock.Instant) {
        self.instant = instant
    }

    /// The deadline `budget` after `now`.
    package static func after(_ budget: Duration, from now: ContinuousClock.Instant) -> RuntimeDeadline {
        RuntimeDeadline(instant: now.advanced(by: budget))
    }

    /// The time left at `now`. Negative once the deadline has passed.
    package func remaining(at now: ContinuousClock.Instant) -> Duration {
        now.duration(to: instant)
    }

    /// The budget to send at `now`: the time remaining, capped at `cap` and rounded
    /// down to whole milliseconds. Zero once the deadline has passed. It is also zero when
    /// the time left or the cap is under one millisecond, because of that rounding. Zero is
    /// a valid wire value, and a caller that must not send it refuses it itself. A negative
    /// cap is refused before any arithmetic, so the seconds-to-milliseconds product below only
    /// ever sees a non-negative seconds value clamped to `Int32.max`.
    package func wireBudget(at now: ContinuousClock.Instant, cappedAt cap: Duration) throws -> ControlWireBudget {
        guard cap >= .zero else { throw ControlRuntimeWireError.invalidValue }
        let remaining = remaining(at: now)
        guard remaining > .zero else { return try ControlWireBudget(0) }
        let components = min(remaining, cap).components
        // Clamp seconds first so the multiplication cannot overflow.
        let seconds = min(components.seconds, Int64(Int32.max))
        let milliseconds = min(
            seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000,
            Int64(Int32.max)
        )
        return try ControlWireBudget(Int(milliseconds))
    }
}

/// Why a caller stopped waiting for a reply.
///
/// The reason does not decide the outcome alone: a reason is reported as `notSent` only
/// when the request never reached the transport, and as `admissionUnknown` once it may
/// have. A caller that sees `disconnected` after a possible send must not resend a mutation.
package enum RuntimeWaitEnd: Sendable, Equatable, Error {
    case deadlineExpired
    case cancelled
    /// The transport closed while the caller waited. Before a send, nothing was admitted;
    /// after one, admission is unknown, and the lookup path is the only recovery.
    case disconnected
    /// A reply arrived but did not decode, or did not belong to this request.
    case invalidReply
}

/// A pull handle on one open subscription. It buffers nothing itself: each `next`
/// waits within the caller's deadline for the next frame the implementation has
/// ready, and `cancel` releases the implementation's registration. Neither method
/// creates a task per event.
///
/// Single pull: at most one `next` is in flight on a handle. A second one is refused
/// locally as `readInProgress` and consumes nothing. A `next` that ends on its deadline
/// or on a cancel consumes no frame, so the frame is still there for the next call.
/// `cancel` is idempotent and never stops the host.
package struct RuntimeSubscription: Sendable {
    package let next: @Sendable (RuntimeDeadline) async throws -> ControlRuntimeFrame
    package let cancel: @Sendable () -> Void

    package init(
        next: @escaping @Sendable (RuntimeDeadline) async throws -> ControlRuntimeFrame,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.next = next
        self.cancel = cancel
    }
}

/// Failures a client reports to its caller. Each case says what is known: nothing
/// was admitted, admission is unknown, or the host answered with a failure.
package enum RuntimeClientError: Error, Sendable, Equatable {
    /// The request was never sent, so no work was admitted. The caller may decide again.
    case notSent(RuntimeWaitEnd)
    /// The request may have reached the host, and no admission was read back. Its
    /// state is unknown: the caller must not resend a mutation, and may query by
    /// request ID or resubscribe to learn more. A disconnect or an invalid reply after
    /// a send lands here, never in `notSent`.
    case admissionUnknown(ControlRequestID, RuntimeWaitEnd)
    /// The host answered with a stable wire-level failure, with the correlation of the request.
    /// The host saw the request. A refusal made locally, before any send, is `localRefusal`
    /// and never this case.
    case wire(ControlRuntimeErrorCode)
    /// The host answered with a message that does not belong to this request.
    case unexpectedReply
    /// The stream ended with a typed reason. The runtime itself keeps running.
    case streamClosed(ControlStreamEndReason)
    /// The client refused the request before any send: it could not be encoded within the
    /// caller's frame limit. The host never saw it. This says nothing about admission, so it
    /// is not `admissionUnknown`, and it is not a host answer, so it is not `wire`.
    case localRefusal(ControlRuntimeErrorCode)
    /// A read, or a stream wait, ended after a request may have been sent. Reads are idempotent,
    /// so the caller may repeat them within its own deadline. A stream wait that ends on its
    /// deadline or a cancel consumed no frame.
    case readAborted(RuntimeWaitEnd)
    /// A second `next` was called while one was in flight on the same subscription. Nothing was
    /// consumed. This is a local rejection, not a host failure.
    case readInProgress
}

/// The async, typed client the app and the daemon use. This file defines only the
/// contract; transports and hosts implement it later.
///
/// Mutations are never retried automatically. After a possible send, a timeout or
/// disconnect is `admissionUnknown`, not a rejection. The recovery path is a lookup,
/// not a resend: `lookupAdmission` names the admission recorded for the request, and
/// `outcome` reads the operation it named. Both are scoped to the expected incarnation,
/// so a restarted host answers `changedIncarnation` instead of another run's result.
/// Lookups and page reads are idempotent, so a caller may repeat them within its own
/// deadline.
///
/// The expected incarnation comes from a snapshot stamp or a baseline. `readSnapshot`
/// reads it without a subscription slot, so a new client can learn it even when every
/// observer slot is full. A live subscription bootstraps it the same way, without a mutation.
package protocol RuntimeClient: Sendable {
    /// Admits one command under a caller-chosen request ID, from the incarnation the
    /// caller read its preconditions in.
    func submit(
        _ command: ControlRuntimeCommand,
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlAdmission

    /// Reads the admission the host recorded for one request. `unknown` means the host
    /// cannot say, which is not proof that nothing ran.
    func lookupAdmission(
        of requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlRequestLookup

    /// Reads one admitted operation's state. An operation that is not pending or
    /// finished is `unknown`, with the reason.
    func outcome(
        of operation: ControlOperationID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlOperationLookup

    /// Opens a subscription. Its first frame is the baseline.
    func subscribe(_ request: ControlSubscriptionRequest, deadline: RuntimeDeadline) async throws -> RuntimeSubscription

    /// Reads one page of one collection.
    func readPage(_ request: ControlPageRequest, deadline: RuntimeDeadline) async throws -> ControlPageReply

    /// Reads the scalar snapshot for bootstrap or status. It opens no subscription, so
    /// it does not compete with observers for slots. Its stamp names the incarnation.
    func readSnapshot(deadline: RuntimeDeadline) async throws -> ControlRuntimeSnapshot
}
