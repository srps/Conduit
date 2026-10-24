// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A byte transport under the framed client. It moves complete frames only: each request is
/// one frame with its line feed, and each reply or stream frame is one frame with its line feed.
///
/// The transport owns the waiting. Its timers and the cancellation of an in-flight wait belong
/// to it, not to the client. The client passes the caller's absolute deadline down unchanged and
/// starts no timer of its own. A transport that cannot enforce a deadline must say so; the client
/// never claims that a deadline was enforced on the wire.
///
/// The reply read limit is explicit. The transport refuses to buffer past `limits.maxFrameBytes`
/// before it hands any bytes up, as the line framer does. The client checks the size again before
/// it decodes, so a transport that forgets the check is still refused.
///
/// No production socket implements this yet. The scripted and simulated transports in the tests
/// and in `pm-sim` do.
package protocol ControlRuntimeTransport: Sendable {
    /// Sends one complete request frame and returns the one complete reply frame. Throws
    /// `ControlRuntimeTransportFailure.notSent` only when no byte left the client. Any other
    /// failure counts as a possible send.
    func exchange(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> Data

    /// Sends one complete subscribe frame and returns the stream it opened. A failure before the
    /// stream opens follows the same rule as `exchange`.
    func openStream(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> ControlRuntimeStream
}

/// One open stream. `next` waits for the next complete frame, with its line feed, within the deadline.
///
/// Allowed wait failures: `RuntimeWaitEnd.deadlineExpired`, `RuntimeWaitEnd.cancelled`, and Swift's
/// `CancellationError` (a cancelled task). Each one ends the wait with the stream still valid. No frame
/// was consumed, and a later `next` receives the frame. A transport must not consume a frame on these.
///
/// Terminal failures: any other thrown error. `RuntimeWaitEnd.disconnected`, `RuntimeWaitEnd.invalidReply`,
/// or an untyped error means the stream is gone. The client releases it and reports `readAborted` with
/// that reason, or `disconnected` for an untyped error.
///
/// `cancel` releases the stream. A transport should wake a pending wait with `.cancelled`. If a frame or
/// a terminal error reaches the wait first, the client still reports the subscription's first terminal
/// state, so a cancel that was already recorded wins over the later wait failure.
package struct ControlRuntimeStream: Sendable {
    package let next: @Sendable (RuntimeDeadline) async throws -> Data
    /// Idempotent. Releases the transport's registration for this stream and never stops the host.
    package let cancel: @Sendable () -> Void

    package init(
        next: @escaping @Sendable (RuntimeDeadline) async throws -> Data,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.next = next
        self.cancel = cancel
    }
}

/// How a transport call failed. `notSent` means no byte left the client, so nothing was admitted.
/// `sent` means bytes may have left it, including a wait that ended after the send.
package enum ControlRuntimeTransportFailure: Error, Sendable, Equatable {
    case notSent(RuntimeWaitEnd)
    case sent(RuntimeWaitEnd)
}
