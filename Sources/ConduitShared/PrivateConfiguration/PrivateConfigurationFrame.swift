// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

// The private frame (decisions 0019 and 0034). One frame is a fixed ASCII header, exactly one
// JSON body of the declared length, and a line feed:
//
//     PCV1 <kind> <decimal body length>\n<JSON body>\n
//
// The kind is `Q` for an update, `G` for a read and `R` for an editor reply.
//
// The header names the version, the kind and the body length before any body
// byte is read. A reader expects one kind. It refuses an unsupported version, any
// other kind or an oversize length while it is still in the header, with zero body
// bytes buffered. The v2 line framer cannot do that, because it finds frames by line
// feed and has no declared length, so this is a separate format. It does not change v2.
//
// Cap: the whole frame, header and terminator included, is at most its kind's cap:
// `maxRequestFrameBytes` for a request (decision 0019) and `maxEditorReplyFrameBytes`
// for an editor reply (decision 0034). Both are 8,388,608 bytes, and each is named
// separately so that neither silently follows the other.

/// Constants of the private frame. Nothing here is a per-field limit.
package enum PrivateConfigurationFrame {
    /// What one frame carries. The header names it with one ASCII letter, and each kind has its own cap.
    package enum Kind: Sendable, Equatable, CaseIterable {
        /// `Q`: one configuration update from a client.
        case update
        /// `G`: one read of the editor observation from a client.
        case read
        /// `R`: one answer from the host to an editor request.
        case editorReply

        /// The letter the header carries at `kindPosition`.
        var tag: UInt8 {
            switch self {
            case .update: UInt8(ascii: "Q")
            case .read: UInt8(ascii: "G")
            case .editorReply: UInt8(ascii: "R")
            }
        }

        /// The cap on one complete frame of this kind: header, body and terminator. Both requests share the request cap.
        package var maxFrameBytes: Int {
            switch self {
            case .update, .read: PrivateConfigurationFrame.maxRequestFrameBytes
            case .editorReply: PrivateConfigurationFrame.maxEditorReplyFrameBytes
            }
        }

        /// The fixed header prefix, `PCV1 <tag> `. Its version digit is `1`.
        var prefix: [UInt8] {
            Array("PCV1 ".utf8) + [tag, UInt8(ascii: " ")]
        }

        /// The longest decimal body length that fits this kind's cap. For an eight MiB cap that is seven
        /// digits, so the header is at most 14 bytes before its line feed.
        var maxLengthDigits: Int {
            PrivateConfigurationFrame.decimalDigits(maxFrameBytes)
        }
    }

    /// The cap on one complete request frame: header, body and terminator (decision 0019).
    package static let maxRequestFrameBytes = 8_388_608
    /// The cap on one complete editor reply frame: header, body and terminator (decision 0034).
    package static let maxEditorReplyFrameBytes = 8_388_608

    /// Bytes of every kind's fixed prefix, `PCV1 <tag> `.
    static let prefixLength = 7
    /// Position of the kind tag inside the prefix.
    static let kindPosition = 5

    /// Input bytes one `consume` call examines. A call returns early at a frame boundary.
    package static let maxInputBytesPerConsume = 16_384

    static let lineFeed: UInt8 = 0x0A

    /// The exact size of one complete frame around a body of `bodyCount` bytes: the fixed prefix,
    /// the decimal length, the header's line feed, the body and the terminator. The length is
    /// written in decimal, so its digit count follows the body count. Every kind's prefix has the
    /// same length, so the size does not depend on the kind; the cap it is checked against does.
    /// The reader and the decoder both check the cap with this function, so neither depends on the
    /// other to have done so.
    package static func frameByteCount(bodyCount: Int) -> Int {
        prefixLength + decimalDigits(bodyCount) + 1 + bodyCount + 1
    }

    /// The number of decimal digits of a non-negative value.
    static func decimalDigits(_ value: Int) -> Int {
        var digits = 1
        var rest = value / 10
        while rest > 0 {
            digits += 1
            rest /= 10
        }
        return digits
    }
}

/// Fixed-text failures of the private frame and codec. No case carries input, so a
/// rejected payload cannot echo a URL or token into an error, a log or an event.
package enum PrivateConfigurationWireError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The frame, or the value it would frame, exceeds the cap. Oversize data is refused, never cut.
    case frameTooLarge
    /// The header names a version this build does not speak.
    case unsupportedVersion
    /// The header names a kind other than the one the reader expects, or a kind this build does not define.
    /// A body handed to a decoder of another kind is refused the same way.
    case unexpectedFrameKind
    /// The header does not follow the grammar.
    case malformedHeader
    /// The body is not one valid configuration request.
    case malformedBody
    /// A value is outside its representable range, or cannot be written.
    case invalidValue
    /// The reader already delivered its frame, or it failed earlier. It accepts no more bytes.
    case invalidState
    /// A value crosses an approved resource ceiling (decision 0021). The scanner or the typed check raises
    /// it before Foundation decodes or the bridge maps anything. It names the field and the ceiling, never
    /// the value, and it is distinct from `malformedBody`, so a caller can tell a bound from a grammar error.
    case resourceLimitExceeded(DomainResourceViolation)

    package var description: String {
        switch self {
        case .frameTooLarge: "private configuration frame exceeds its size cap"
        case .unsupportedVersion: "private configuration frame version is not supported"
        case .unexpectedFrameKind: "private configuration frame kind is not the one expected"
        case .malformedHeader: "private configuration frame header is malformed"
        case .malformedBody: "private configuration body is malformed"
        case .invalidValue: "private configuration value is not representable"
        case .invalidState: "private configuration reader is not accepting input"
        case .resourceLimitExceeded: "private configuration value exceeds a resource limit"
        }
    }
}

/// The body bytes of one complete frame, with the kind its header named. They are JSON and
/// contain the URL plaintext, so the type is not `Codable` and its reflection is redacted. A
/// decoder refuses a body of another kind, so a request body cannot be read as a reply.
package struct PrivateConfigurationFrameBody: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    package let kind: PrivateConfigurationFrame.Kind
    package let bytes: SecretBytes

    package init(kind: PrivateConfigurationFrame.Kind, bytes: SecretBytes) {
        self.kind = kind
        self.bytes = bytes
    }

    package var description: String { "PrivateConfigurationFrameBody(\(kind), <redacted, \(bytes.count) bytes>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

/// What one reader call produced: nothing yet, or the one body of the frame.
package enum PrivateConfigurationFrameStep: Sendable {
    case needsInput
    case frame(PrivateConfigurationFrameBody)
}

/// A byte buffer that zeroes its storage before it releases it. Growth moves the bytes
/// into a new allocation, and the old allocation is zeroed first. The reader uses it
/// for body bytes, and the encoder uses it for the finished frame.
///
/// Memory: a buffer holds at most `ceiling` bytes. Capacity starts at the caller's
/// estimate and doubles, never past `ceiling`, so one growth copies at most `ceiling`
/// bytes and the total copy work is linear in the bytes stored.
///
/// Ownership: a buffer has one owner and is not `Sendable`. Two holders of one buffer
/// would share and scrub each other's bytes.
///
/// Caveat: the buffer scrubs only its own allocations. Copies made later, such as the
/// `Data` that `JSONDecoder` reads from or the `String`s a decoded URL becomes, are not
/// scrubbed. The records say so (0018 §2–3).
final class PrivateFrameBuffer {
    private var base: UnsafeMutablePointer<UInt8>?
    /// The most bytes this buffer may ever hold. Growth stops here.
    let ceiling: Int
    private(set) var count = 0
    private(set) var capacity = 0

    /// Starts with `initialCapacity` bytes, capped at `ceiling`. Capacity grows by doubling,
    /// and never past `ceiling`.
    init(initialCapacity: Int, ceiling: Int) {
        self.ceiling = ceiling
        self.capacity = min(max(initialCapacity, 0), ceiling)
        self.base = capacity > 0 ? UnsafeMutablePointer<UInt8>.allocate(capacity: capacity) : nil
    }

    deinit {
        release()
    }

    /// Appends one byte. The caller keeps `count` below `ceiling`. Each caller checks this
    /// before it appends, so growth never passes the ceiling.
    func append(_ byte: UInt8) {
        precondition(count < ceiling, "frame buffer appended past its ceiling")
        if count == capacity {
            grow(to: min(max(capacity * 2, 4_096), ceiling))
        }
        // The slot is uninitialized memory, so it is initialized, not assigned.
        (base! + count).initialize(to: byte)
        count += 1
    }

    /// Scoped read access to the bytes held. The pointer must not escape `body`.
    func withBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) throws -> Result) rethrows -> Result {
        guard let base else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return try body(UnsafeBufferPointer(start: base, count: count))
    }

    /// A redacted copy of the bytes. The buffer keeps its own storage until `release`.
    func makeSecretBytes() -> SecretBytes {
        withBytes { SecretBytes($0) }
    }

    /// Zeroes and frees the storage. The buffer is empty afterwards and can be reused.
    func release() {
        if let base {
            _ = memset_s(base, capacity, 0, capacity)
            base.deallocate()
        }
        base = nil
        count = 0
        capacity = 0
    }

    private func grow(to newCapacity: Int) {
        let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        if let base {
            // The replacement is uninitialized memory, so the bytes are initialized, not assigned.
            replacement.initialize(from: base, count: count)
            _ = memset_s(base, capacity, 0, capacity)
            base.deallocate()
        }
        base = replacement
        capacity = newCapacity
    }
}

/// Reads exactly one private frame of one expected kind from a byte stream, a few bytes at a time.
/// The kind fixes the header prefix and the cap, so a frame of any other kind is refused at its kind
/// byte, before its length is read.
///
/// Ownership: one owner at a time. The reader is a `final class` with mutable state and no
/// `Sendable` claim. Hand it to another task only after the owner has stopped using it. A
/// value copy would not be safe, because a copy would share the body buffer it holds.
///
/// Work: a `consume` call examines at most `maxInputBytesPerConsume` input bytes and returns how
/// many it used. It stops at the end of a frame, so later bytes are left to the caller. That bound
/// counts input examined, not all work. Two things in one call are not bounded by the 16 KiB:
///   - growing the body buffer copies the bytes it already holds (at most the frame cap);
///   - the call that completes a frame copies the whole body into `SecretBytes` and scrubs
///     the buffer (at most the frame cap).
/// Peak memory while a body is held is about two body lengths during completion, and a body
/// the decoder reads adds one more copy. The cap bounds all of it. It does not make a call
/// fast: callers that need a short main-actor stop must run the reader off the main actor.
///
/// Memory: body bytes are reserved as they arrive, never from the declared length, and the
/// header is at most 14 bytes before its line feed. An oversize declared length fails before any
/// body byte is stored.
///
/// Failure is sticky. After an error, every later call throws the same error and releases
/// what it held. After a frame is delivered, the reader accepts no more input; `reset()`
/// reuses it. `reset()` and a failure both zero and release the body buffer.
package final class PrivateConfigurationFrameReader {
    private enum Phase {
        case header
        case body
        case terminator
        case complete
        case failed(PrivateConfigurationWireError)
    }

    /// The one kind this reader accepts.
    package let kind: PrivateConfigurationFrame.Kind
    /// The kind's fixed header prefix and cap, taken once.
    private let prefix: [UInt8]
    private let maxFrameBytes: Int
    private let maxLengthDigits: Int

    private var phase: Phase = .header
    /// Header bytes accepted so far, before the line feed.
    private var headerPosition = 0
    private var lengthValue = 0
    private var lengthDigits = 0
    private var bodyRemaining = 0
    private var body: PrivateFrameBuffer?

    package init(expecting kind: PrivateConfigurationFrame.Kind) {
        self.kind = kind
        self.prefix = kind.prefix
        self.maxFrameBytes = kind.maxFrameBytes
        self.maxLengthDigits = kind.maxLengthDigits
    }

    /// Body bytes this reader currently holds. Zero until the header is accepted.
    package var retainedByteCount: Int {
        body?.count ?? 0
    }

    /// Consumes bytes from the front of `input` until one frame completes or the input ends.
    /// Returns the step and the number of input bytes used. A completed frame's count includes
    /// its line feed.
    package func consume<Chunk: Collection>(
        _ input: Chunk
    ) throws -> (step: PrivateConfigurationFrameStep, consumed: Int) where Chunk.Element == UInt8 {
        switch phase {
        case .failed(let error):
            throw error
        case .complete:
            throw PrivateConfigurationWireError.invalidState
        case .header, .body, .terminator:
            break
        }
        var consumed = 0
        for byte in input.prefix(PrivateConfigurationFrame.maxInputBytesPerConsume) {
            consumed += 1
            do {
                if let frame = try accept(byte) {
                    return (.frame(frame), consumed)
                }
            } catch {
                fail(with: error)
                throw (error as? PrivateConfigurationWireError) ?? .malformedBody
            }
        }
        return (.needsInput, consumed)
    }

    /// Ends the stream. A frame still open at end of input is an error, not a frame.
    package func finish() throws {
        switch phase {
        case .failed(let error):
            throw error
        case .complete:
            return
        case .header, .body, .terminator:
            let error = PrivateConfigurationWireError.malformedBody
            fail(with: error)
            throw error
        }
    }

    /// Returns the reader to its first state. Any buffered body bytes are zeroed and released.
    package func reset() {
        body?.release()
        body = nil
        phase = .header
        headerPosition = 0
        lengthValue = 0
        lengthDigits = 0
        bodyRemaining = 0
    }

    private func fail(with error: any Error) {
        body?.release()
        body = nil
        phase = .failed((error as? PrivateConfigurationWireError) ?? .malformedBody)
    }

    private func accept(_ byte: UInt8) throws -> PrivateConfigurationFrameBody? {
        switch phase {
        case .header:
            // A line feed ends the header only once the fixed prefix is complete. Inside the prefix it
            // is an ordinary mismatch, so `PCV\n` and `PCV1 \n` are classified by position like every
            // other bad prefix byte.
            if byte == PrivateConfigurationFrame.lineFeed, headerPosition >= prefix.count {
                try finishHeader()
            } else {
                try acceptHeaderByte(byte)
            }
            return nil
        case .body:
            body?.append(byte)
            bodyRemaining -= 1
            if bodyRemaining == 0 {
                phase = .terminator
            }
            return nil
        case .terminator:
            guard byte == PrivateConfigurationFrame.lineFeed, let body else {
                throw PrivateConfigurationWireError.malformedBody
            }
            let frame = PrivateConfigurationFrameBody(kind: kind, bytes: body.makeSecretBytes())
            body.release()
            self.body = nil
            phase = .complete
            return frame
        case .complete, .failed:
            throw PrivateConfigurationWireError.invalidState
        }
    }

    /// Checks one header byte. The prefix is checked byte by byte, so a bad version or kind is
    /// refused at its own byte, not after the line feed. The length digits are checked for
    /// the cap as they arrive.
    private func acceptHeaderByte(_ byte: UInt8) throws {
        if headerPosition < prefix.count {
            // A mismatch is classified by the first byte that differs. Every earlier byte
            // matched, because the position only advances on a match.
            guard byte == prefix[headerPosition] else {
                switch headerPosition {
                case 3:
                    // `PCV` matched and the version digit is not `1`.
                    throw PrivateConfigurationWireError.unsupportedVersion
                case PrivateConfigurationFrame.kindPosition:
                    // `PCV1 ` matched and the kind is not the one this reader expects.
                    throw PrivateConfigurationWireError.unexpectedFrameKind
                default:
                    throw PrivateConfigurationWireError.malformedHeader
                }
            }
            headerPosition += 1
            return
        }
        // The length: decimal digits only, no leading zero, no more digits than the kind's cap
        // has, and no value above the cap. The check runs per digit, so an oversize length fails here.
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
            throw PrivateConfigurationWireError.malformedHeader
        }
        guard lengthDigits > 0 || byte != UInt8(ascii: "0") else {
            throw PrivateConfigurationWireError.malformedHeader
        }
        guard lengthDigits < maxLengthDigits else {
            throw PrivateConfigurationWireError.frameTooLarge
        }
        // At most the cap's digit count before this step, so the value stays below ten times the cap
        // and cannot overflow.
        lengthValue = lengthValue * 10 + Int(byte - UInt8(ascii: "0"))
        lengthDigits += 1
        headerPosition += 1
        guard lengthValue <= maxFrameBytes else {
            throw PrivateConfigurationWireError.frameTooLarge
        }
    }

    /// Accepts the header's line feed. It checks the length against the cap, using the exact
    /// header size that this length produces, before any body byte is read.
    private func finishHeader() throws {
        guard headerPosition == prefix.count + lengthDigits, lengthDigits > 0, lengthValue > 0 else {
            throw PrivateConfigurationWireError.malformedHeader
        }
        // The exact frame size, header and terminator included. `lengthDigits` is the digit count of
        // `lengthValue`, because a leading zero was refused above.
        guard PrivateConfigurationFrame.frameByteCount(bodyCount: lengthValue) <= maxFrameBytes else {
            throw PrivateConfigurationWireError.frameTooLarge
        }
        bodyRemaining = lengthValue
        body = PrivateFrameBuffer(
            initialCapacity: min(lengthValue, PrivateConfigurationFrame.maxInputBytesPerConsume),
            ceiling: lengthValue
        )
        phase = .body
    }
}
