// SPDX-License-Identifier: Apache-2.0
import Foundation

// The client side of the private editor channel (decisions 0018, 0021 and 0034). One private exchange is reserved before the
// client maps or encodes anything, and its reservation is held until the reply is decoded and every buffer released, so a
// busy channel refuses before an eight-MiB body exists. The reservation belongs to the transport's composition, shared by
// every transport and connection it serves; it is not this client's.

/// What a private exchange reserves. A read reserves the one transfer. An update also reserves the one admitted frozen-input
/// slot, which an accepted update keeps until its operation has physically quiesced.
package enum PrivateExchangePurpose: Sendable, Equatable {
    case read
    case update
}

/// One reserved private exchange. `send` carries one complete request frame and returns the one complete reply frame. It
/// throws `ControlRuntimeTransportFailure.notSent` only when no byte left the client.
package struct PrivateExchange: Sendable {
    package let send: @Sendable (SecretBytes, RuntimeDeadline) async throws -> SecretBytes

    package init(send: @escaping @Sendable (SecretBytes, RuntimeDeadline) async throws -> SecretBytes) {
        self.send = send
    }
}

/// A byte transport for the private frames. The reservation is scoped: `body` runs inside it, and the transfer is released
/// only after `body` has returned or thrown, so the reply's decode and the release of its buffer are inside the reservation.
/// A refused reservation throws `ControlRuntimeTransportFailure.notSent(.transportBusy)` before `body` runs.
package protocol PrivateEditorTransport: Sendable {
    func withPrivateExchange<T: Sendable>(
        _ purpose: PrivateExchangePurpose,
        _ body: (PrivateExchange) async throws -> T
    ) async throws -> T
}

extension PrivateConfigurationFrame {
    /// The one body of a complete frame of `kind` held in `bytes`, through the bounded frame reader. Bytes after the frame,
    /// or a frame that does not complete, are refused.
    package static func body(of bytes: SecretBytes, expecting kind: Kind) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader(expecting: kind)
        return try bytes.withUnsafeBytes { raw -> PrivateConfigurationFrameBody in
            var offset = 0
            while offset < raw.count {
                let (step, consumed) = try reader.consume(UnsafeBufferPointer(rebasing: raw[offset...]))
                offset += consumed
                if case .frame(let body) = step {
                    guard offset == raw.count else { throw PrivateConfigurationWireError.malformedBody }
                    return body
                }
                guard consumed > 0 else { throw PrivateConfigurationWireError.malformedBody }
            }
            try reader.finish()
            throw PrivateConfigurationWireError.malformedBody
        }
    }
}

/// The private editor operations over one transport. Each call reserves first, then builds and encodes its frame, sends it
/// once, and decodes and matches the correlated reply inside the reservation. Nothing is retried: a lost update reply is
/// `admissionUnknown`, recovered by request lookup, never by sending the values again.
package struct PrivateEditorClient: Sendable {
    private let transport: any PrivateEditorTransport

    package init(transport: any PrivateEditorTransport) {
        self.transport = transport
    }

    /// One memory observation: `observation` with its values, or the host's `refused` code. A read is idempotent, so a wait
    /// that ended after a possible send is `readAborted` and may be repeated.
    package func read(
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        budget: ControlWireBudget,
        deadline: RuntimeDeadline
    ) async throws -> PrivateEditorAnswer {
        let request = PrivateEditorReadRequest(requestID: requestID, incarnation: expectedIncarnation, budget: budget)
        do {
            return try await transport.withPrivateExchange(.read) { exchange in
                let frame = try Self.encodeLocally { try PrivateConfigurationEncoder.encode(request) }
                let reply = try await exchange.send(frame, deadline)
                let decoded = try PrivateConfigurationDecoder.decodeReply(
                    try PrivateConfigurationFrame.body(of: reply, expecting: .editorReply)
                )
                return try decoded.answer(answering: request)
            }
        } catch let failure as ControlRuntimeTransportFailure {
            switch failure {
            case .notSent(let end): throw RuntimeClientError.notSent(end)
            case .sent(let end): throw RuntimeClientError.readAborted(end)
            }
        } catch is PrivateEditorReplyMismatch {
            throw RuntimeClientError.unexpectedReply
        } catch is PrivateConfigurationWireError {
            // The reply arrived and did not decode, so the read is aborted, never not sent.
            throw RuntimeClientError.readAborted(.invalidReply)
        }
    }

    /// One frozen update. `makeRequest` maps the caller's frozen draft into the request; it is called once, inside the reserved exchange,
    /// so a busy channel refuses before a second full request exists, and the mapped request lives only for this exchange. `requestID` is
    /// the one the request must carry, known before mapping so every failure names it. The answer is the admission only; settlement and the
    /// causal receipt are read through the ordinary operation lookup. A wait that ended after a possible send is `admissionUnknown`.
    package func submit(
        requestID: ControlRequestID,
        deadline: RuntimeDeadline,
        request makeRequest: @Sendable () throws -> PrivateConfigurationRequest
    ) async throws -> ControlAdmission {
        do {
            return try await transport.withPrivateExchange(.update) { exchange in
                let request = try Self.mapLocally(requestID: requestID, makeRequest)
                let frame = try Self.encodeLocally { try PrivateConfigurationEncoder.encode(request) }
                let reply = try await exchange.send(frame, deadline)
                let decoded = try PrivateConfigurationDecoder.decodeReply(
                    try PrivateConfigurationFrame.body(of: reply, expecting: .editorReply)
                )
                return try decoded.admission(answering: request)
            }
        } catch let failure as ControlRuntimeTransportFailure {
            switch failure {
            case .notSent(let end): throw RuntimeClientError.notSent(end)
            case .sent(let end): throw RuntimeClientError.admissionUnknown(requestID, end)
            }
        } catch is PrivateEditorReplyMismatch {
            throw RuntimeClientError.admissionUnknown(requestID, .invalidReply)
        } catch is PrivateConfigurationWireError {
            throw RuntimeClientError.admissionUnknown(requestID, .invalidReply)
        }
    }

    /// The request the caller's producer maps, before any send. A mapping refusal, or a request under another ID, is the client's own.
    private static func mapLocally(
        requestID: ControlRequestID,
        _ makeRequest: () throws -> PrivateConfigurationRequest
    ) throws -> PrivateConfigurationRequest {
        let request: PrivateConfigurationRequest
        do {
            request = try makeRequest()
        } catch PrivateConfigurationWireError.frameTooLarge {
            throw RuntimeClientError.localRefusal(.frameTooLarge)
        } catch {
            throw RuntimeClientError.localRefusal(.invalidValue)
        }
        guard request.requestID == requestID else { throw RuntimeClientError.localRefusal(.invalidValue) }
        return request
    }

    /// The frame for a request, encoded before any send. A refusal is the client's own: nothing left it.
    private static func encodeLocally(_ encode: () throws -> SecretBytes) throws -> SecretBytes {
        do {
            return try encode()
        } catch let error as PrivateConfigurationWireError {
            throw RuntimeClientError.localRefusal(error == .frameTooLarge ? .frameTooLarge : .invalidValue)
        }
    }
}
