// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The v2 frame codec. A frame is one UTF-8 JSON value followed by a line feed.
/// The same bytes serve the in-memory transport and a later socket.
///
/// Order of checks on decode: size, then the envelope version, then the envelope kind,
/// then the body's type and nested command discriminator, then the strict JSON grammar of
/// the whole payload, then the typed body. Each check runs before the next can see its input,
/// so an oversize frame is never parsed, a version this build does not speak is reported as
/// such even when its body is malformed, an unknown kind is refused before its body is read,
/// and an unknown command is never reported as a malformed payload. Each probe reads only the
/// fields its check needs. The strict walk covers unknown and ignored values too, so a malformed
/// extension refuses a known frame, while a valid unknown extension stays legal.
///
/// Bounds on encode, for a caller limit `L` (`maxFrameBytes`): the free text of a message
/// is refused above `L` bytes, and its element count above `L / 2`, both before any
/// serialization. The serializer then writes at most the escaped form of that text (a
/// control byte becomes six bytes), plus each element's key names. The result is either
/// published within `L` or refused; it is never truncated.
///
/// Bounds on decode work: each parse reads at most the `L` bytes of one payload, and at most
/// five parses run over it (version, kind, body type, submit command, then the typed decode).
/// The strict grammar walk is one more linear pass over the same bytes. It allocates only its
/// container stack, one bit per open level.
package enum ControlRuntimeCodec {
    static let lineFeed: UInt8 = 0x0A

    /// The one JSON configuration v2 peers use. Its output is deterministic, so
    /// fixtures can pin the bytes. A `Date` is written as Unix-epoch seconds, the same
    /// scale as `ControlTimestamp`, which is what an external reader of the wire expects.
    package static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    /// The decoder that pairs with `makeEncoder`. Every v2 decode uses it, so a `Date`
    /// in a frame is read on the scale it was written on.
    package static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// The JSON payload of one message, without its line feed, bounded by the caller's
    /// limit. This is the only way a message becomes bytes; there is no unbounded form.
    package static func encodeBoundedPayload(_ message: ControlRuntimeMessage, limits: ControlFrameLimits) throws -> Data {
        var budget = ControlFrameBudget(limit: limits.maxFrameBytes)
        try message.measure(into: &budget)
        let payload: Data
        do {
            payload = try makeEncoder().encode(message)
        } catch {
            // The encoder only fails when a value violates its own invariant.
            throw ControlRuntimeWireError.invalidValue
        }
        // The payload and its line feed must fit. Oversize output is refused, not cut.
        guard payload.count + 1 <= limits.maxFrameBytes else {
            throw ControlRuntimeWireError.frameTooLarge
        }
        return payload
    }

    /// One framed message: its bounded payload and a line feed.
    package static func encodeFrame(_ message: ControlRuntimeMessage, limits: ControlFrameLimits) throws -> Data {
        var frame = try encodeBoundedPayload(message, limits: limits)
        frame.append(lineFeed)
        return frame
    }

    /// One collection row as bytes, for a page's size accounting. The row's free text is
    /// counted against the frame limit before it is serialized, so an oversize row is
    /// refused without a copy. Its serialization is then bounded by its escaped text.
    package static func encodeBoundedRow<Row: ControlCollectionRow>(_ row: Row, limits: ControlFrameLimits) throws -> Data {
        var budget = ControlFrameBudget(limit: limits.maxFrameBytes)
        try row.measure(into: &budget)
        do {
            return try makeEncoder().encode(row)
        } catch {
            throw ControlRuntimeWireError.invalidValue
        }
    }

    /// Decodes one payload, without its line feed. The payload may not contain a raw
    /// line feed, because JSON strings escape it.
    package static func decodeFrame(_ payload: Data, limits: ControlFrameLimits) throws -> ControlRuntimeMessage {
        guard payload.count + 1 <= limits.maxFrameBytes else {
            throw ControlRuntimeWireError.frameTooLarge
        }
        guard !payload.contains(lineFeed) else {
            throw ControlRuntimeWireError.malformedMessage
        }
        // Version first. Nothing else in the payload is read until it is known.
        let probe: VersionProbe
        do {
            probe = try makeDecoder().decode(VersionProbe.self, from: payload)
        } catch {
            throw ControlRuntimeWireError.malformedMessage
        }
        guard probe.version == ControlRuntimeProtocol.version else {
            throw ControlRuntimeWireError.unsupportedVersion
        }
        // The kind next. An unknown kind is refused here, before its body is looked at.
        let envelope: KindProbe
        do {
            envelope = try makeDecoder().decode(KindProbe.self, from: payload)
        } catch {
            throw ControlRuntimeWireError.malformedMessage
        }
        guard let rawKind = envelope.kind else {
            throw ControlRuntimeWireError.malformedMessage
        }
        guard let kind = EnvelopeKind(rawValue: rawKind) else {
            throw ControlRuntimeWireError.unknownCommand
        }
        // The body's type, then the nested discriminators, then the typed body.
        let body: BodyProbe
        do {
            body = try makeDecoder().decode(BodyProbe.self, from: payload)
        } catch {
            throw ControlRuntimeWireError.malformedMessage
        }
        guard let type = body.body?.type else {
            throw ControlRuntimeWireError.malformedMessage
        }
        try classify(kind, type: type, payload: payload)
        // Strict grammar for the whole payload, unknown and ignored values included. Foundation defers some checks
        // on values it never reads, so it can accept a lone surrogate or a raw control character there.
        try requireStrictJSON(payload)
        do {
            return try makeDecoder().decode(ControlRuntimeMessage.self, from: payload)
        } catch {
            throw ControlRuntimeWireError.malformedMessage
        }
    }

    /// Walks the whole payload with the shared lexical cursor, without materializing any value. Every byte must
    /// follow the JSON grammar, the UTF-8 rules and the escape rules, and nothing may follow the value. The depth
    /// bound is the payload size: each open container takes at least one byte, so no valid payload is refused.
    private static func requireStrictJSON(_ payload: Data) throws {
        try payload.withUnsafeBytes { raw in
            var cursor = JSONByteCursor(raw.bindMemory(to: UInt8.self))
            do {
                try cursor.skipValue(maxDepth: payload.count)
                try cursor.expectEnd()
            } catch {
                throw ControlRuntimeWireError.malformedMessage
            }
        }
    }

    /// Decodes one complete frame: a payload and exactly one trailing line feed. The size is
    /// checked before anything is parsed. A second line feed is a concatenated or trailing frame,
    /// which is malformed rather than split, so a reader never accepts bytes past the frame it asked for.
    package static func decodeFullFrame(_ frame: Data, limits: ControlFrameLimits) throws -> ControlRuntimeMessage {
        guard frame.count <= limits.maxFrameBytes else {
            throw ControlRuntimeWireError.frameTooLarge
        }
        guard frame.last == lineFeed else {
            throw ControlRuntimeWireError.frameIncomplete
        }
        let payload = Data(frame.dropLast())
        guard !payload.contains(lineFeed) else {
            throw ControlRuntimeWireError.malformedMessage
        }
        return try decodeFrame(payload, limits: limits)
    }

    /// Refuses a request, response, or frame type that this build does not define. The
    /// nested submit command is read only once its request type is known, so an unknown
    /// request never reaches a nested body. A known type with a bad payload is left to the
    /// typed decode, which reports it as malformed.
    private static func classify(_ kind: EnvelopeKind, type: String, payload: Data) throws {
        switch kind {
        case .request:
            guard let known = ControlRuntimeRequestKind(rawValue: type) else {
                throw ControlRuntimeWireError.unknownCommand
            }
            if known == .submit {
                let submit: SubmitProbe
                do {
                    submit = try makeDecoder().decode(SubmitProbe.self, from: payload)
                } catch {
                    throw ControlRuntimeWireError.malformedMessage
                }
                if let commandType = submit.body.submit?.command?.type {
                    guard ControlRuntimeCommandKind(rawValue: commandType) != nil else {
                        throw ControlRuntimeWireError.unknownCommand
                    }
                }
            }
        case .response:
            guard ControlRuntimeResponseKind(rawValue: type) != nil else {
                throw ControlRuntimeWireError.unknownCommand
            }
        case .frame:
            guard ControlRuntimeFrameKind(rawValue: type) != nil else {
                throw ControlRuntimeWireError.unknownCommand
            }
        }
    }

    /// The envelope kinds this build defines. Each names the body family its `type` belongs to.
    private enum EnvelopeKind: String {
        case request
        case response
        case frame
    }

    /// Only the version, read without validating anything else in the payload.
    private struct VersionProbe: Decodable {
        let version: Int?

        private enum Key: String, CodingKey {
            case version
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            // A version that is not an integer is not one this build supports, so it is
            // reported as unsupported. The unsupported_version code is the diagnosis.
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
        }
    }

    /// Only the envelope kind, read without touching the body.
    private struct KindProbe: Decodable {
        let kind: String?
    }

    /// Only the body's own type, read without validating anything else in the payload.
    private struct BodyProbe: Decodable {
        let body: BodyType?

        struct BodyType: Decodable {
            let type: String?
        }
    }

    /// The nested command discriminator of a submit, read only for a submit request.
    private struct SubmitProbe: Decodable {
        let body: SubmitBody

        struct SubmitBody: Decodable {
            let submit: Submit?
        }

        struct Submit: Decodable {
            let command: Command?
        }

        struct Command: Decodable {
            let type: String?
        }
    }
}

/// Splits a byte stream into frames, one frame per call. The caller drives the loop, so
/// work and output per call are both bounded: a call reads at most `maxFrameBytes` bytes,
/// returns at most one frame, and reports exactly how many input bytes it consumed. Bytes
/// after a frame's line feed are never read by that call and are left for the next one.
/// Overflow fails the stream, releases what it held, and stays failed.
package struct ControlRuntimeLineFramer: Sendable {
    package let limits: ControlFrameLimits
    private var pending: [UInt8] = []
    private var failure: ControlRuntimeWireError?

    package init(limits: ControlFrameLimits) {
        self.limits = limits
    }

    /// Bytes held for an incomplete frame. Never more than the limit minus its line feed.
    package var retainedByteCount: Int {
        pending.count
    }

    /// Consumes bytes from the front of `input`, until one frame completes or the input
    /// ends. Returns the step and the number of input bytes consumed. A completed frame's
    /// consumed count includes its line feed.
    package mutating func consume<Chunk: Collection>(
        _ input: Chunk
    ) throws -> (step: ControlRuntimeFramerStep, consumed: Int) where Chunk.Element == UInt8 {
        if let failure { throw failure }
        // A payload byte must leave room for the line feed that ends the frame.
        let payloadCapacity = limits.maxFrameBytes - 1
        var consumed = 0
        for byte in input {
            consumed += 1
            if byte == ControlRuntimeCodec.lineFeed {
                let payload = Data(pending)
                pending.removeAll(keepingCapacity: true)
                return (.frame(payload), consumed)
            }
            // Refuse before retaining the byte, so an oversize segment is never copied in full.
            guard pending.count < payloadCapacity else {
                pending.removeAll(keepingCapacity: false)
                failure = .frameTooLarge
                throw ControlRuntimeWireError.frameTooLarge
            }
            pending.append(byte)
        }
        return (.needsInput, consumed)
    }

    /// Ends the stream. An incomplete frame at end of input is an error, not a frame.
    package mutating func finish() throws {
        if let failure { throw failure }
        if !pending.isEmpty {
            throw ControlRuntimeWireError.frameIncomplete
        }
    }
}

/// The result of one framer call: a completed frame's payload, or no frame yet.
package enum ControlRuntimeFramerStep: Sendable, Equatable {
    /// One complete payload, without its line feed.
    case frame(Data)
    /// The input ended inside a frame. The bytes consumed so far are retained.
    case needsInput
}
