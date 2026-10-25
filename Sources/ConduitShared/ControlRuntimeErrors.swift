// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Stable machine-readable codes for failures at the v2 wire boundary. They are
/// independent of v1's `ControlErrorCode`, which stays unchanged.
package enum ControlRuntimeErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    case frameTooLarge = "frame_too_large"
    case frameIncomplete = "frame_incomplete"
    case unsupportedVersion = "unsupported_version"
    case unknownCommand = "unknown_command"
    case malformedMessage = "malformed_message"
    case invalidValue = "invalid_value"
    /// The host already has its maximum number of open subscriptions.
    case subscriberLimit = "subscriber_limit"
    /// The request's budget ended before the host could answer with a result. Nothing was admitted, and a read answers this.
    case deadlineExpired = "deadline_expired"
    /// The request names another host incarnation, so no answer from this host is valid for it. Nothing was read.
    case changedIncarnation = "changed_incarnation"
    /// The host could not build the answer a valid read asked for. It is a closed failure with no text and no body.
    /// Its answer is not a refusal of the request, so a caller must not treat it as a corrupt transport.
    case internalFailure = "internal_failure"
}

/// A failure while building, encoding or decoding a v2 value. Each case maps to
/// one stable code. Messages never echo the input, so payload content cannot leak.
package enum ControlRuntimeWireError: Error, Sendable, Equatable {
    /// The frame, or the value that would be framed, exceeds the caller's limit.
    /// Oversize data is refused, never truncated.
    case frameTooLarge
    /// The stream ended inside a frame.
    case frameIncomplete
    /// The envelope version is missing or is not `ControlRuntimeProtocol.version`.
    case unsupportedVersion
    /// An envelope kind, request, or command discriminator is not known to this build.
    case unknownCommand
    /// A known discriminator carries a payload that does not decode, or is not valid JSON.
    case malformedMessage
    /// A scalar or limit falls outside its declared range.
    case invalidValue

    package var code: ControlRuntimeErrorCode {
        switch self {
        case .frameTooLarge: .frameTooLarge
        case .frameIncomplete: .frameIncomplete
        case .unsupportedVersion: .unsupportedVersion
        case .unknownCommand: .unknownCommand
        case .malformedMessage: .malformedMessage
        case .invalidValue: .invalidValue
        }
    }
}

/// The largest frame a peer will accept, including its terminating line feed.
/// The limit is the caller's choice; no shipping default lives here.
package struct ControlFrameLimits: Sendable, Equatable {
    package let maxFrameBytes: Int

    package init(maxFrameBytes: Int) throws {
        // One payload byte and the line feed are the smallest frame that can exist.
        guard maxFrameBytes >= 2 else { throw ControlRuntimeWireError.invalidValue }
        self.maxFrameBytes = maxFrameBytes
    }
}
