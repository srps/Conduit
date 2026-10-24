// SPDX-License-Identifier: Apache-2.0
// Opaque byte
// container for in-memory credentials (NTLM hashes today; the base64'd
// Keychain envelopes that wrap them; future bearer tokens / cookies).
//
// What this type defends against — and what it doesn't.
//
// DEFENDS:
//
//   - Accidental `print(secret)` / `dump(secret)` / String interpolation.
//     `Custom(Debug)StringConvertible` + `CustomReflectable` return the
//     redacted form `"SecretBytes(<redacted, N bytes>)"` so there's no
//     way for Mirror-based reflection or the default describable paths
//     to expose the raw bytes.
//
//   - `Codable` accidents. SecretBytes deliberately does NOT conform to
//     `Encodable` / `Decodable`. If a future diagnostic bundle type adds
//     a `SecretBytes?` field, the compiler refuses to synthesise Codable
//     for the enclosing type — the leak is caught at compile time, not
//     after shipping.
//
//   - Post-use persistence in memory. The internal `_Storage` class's
//     `deinit` calls `memset_s` (C11 standard, guaranteed not-optimised-
//     away — the compiler MUST preserve writes through this function
//     even when the memory is about to be freed) on the backing buffer
//     before releasing it. Once the last value-type handle drops, the
//     bytes are scrubbed. Shrinks the window where a process core dump
//     or post-release heap inspection could expose the bytes.
//
// DOES NOT DEFEND:
//
//   - Live-process memory inspection (lldb ptrace, authorised memory
//     read, kernel extensions). While the buffer is held, the bytes are
//     readable by any code in this address space. That threat model is
//     outside a user-space HTTP proxy's scope — if the attacker has
//     code execution in our process, they have the Keychain handles too.
//
//   - Codable round-trip through the Keychain envelope. Our
//     `ProxyCredentials.keychainData()` must produce a JSON blob for the
//     Security framework to store at rest; that path decodes the bytes
//     back into a short-lived `Data` that the JSONDecoder produces. The
//     SecretBytes re-wrap happens immediately at the ingress / egress of
//     that boundary. The Keychain itself encrypts at rest.
//
//   - A language-level guarantee that compilers won't leave stale copies
//     in registers / stack spills during evaluation. Swift offers no such
//     guarantee for any type.
//
// Shape: `struct` API with internal class storage. Copies share the same
// backing — cheap to pass around — and the backing's class `deinit` owns
// the zero-on-release semantics. Mirrors the `ProxyConfigBox` /
// `AuthProviderHolder` pattern: for any shared
// mutable state whose value type is non-trivial, prefer a class-backed
// holder over a value-only wrapper so lifetime is explicit.

import Darwin
import Foundation

package struct SecretBytes: Sendable {
    private let backing: _Storage

    // MARK: - Initialisers

    /// Construct from a `Collection<UInt8>`. The bytes are copied once
    /// into the scrubbed backing buffer; there is no intermediate
    /// materialisation, no Array growth re-allocations, and no frames
    /// outside the single `_Storage` copy.
    ///
    /// `Sequence<UInt8>` is deliberately NOT accepted. `Array(seq)`
    /// may reallocate many times as it grows and the discarded buffers
    /// are released to the allocator without scrubbing — which silently
    /// breaks this type's "no unscrubbed copy outlives construction"
    /// contract. Callers that hold a bare `Sequence` must materialise
    /// it themselves so the caller can reason about the lifetime of
    /// the intermediate; we refuse to pretend we can scrub it here.
    /// Empty input is valid (produces an empty SecretBytes whose
    /// `withUnsafeBytes` yields a zero-count buffer).
    package init(_ bytes: some Collection<UInt8>) {
        self.backing = _Storage(copying: bytes)
    }

    /// Convenience for the frequent `Data` case. Copies directly from the
    /// Data's existing storage into scrubbed backing memory.
    package init(_ data: Data) {
        self.backing = data.withUnsafeBytes { buf in
            _Storage(copying: buf.bindMemory(to: UInt8.self))
        }
    }

    /// Build from a String's UTF-8 encoding. The `String` itself is the
    /// caller's concern: if the string came from a `SecureField`, the
    /// caller should scope its lifetime tightly and let ARC release it
    /// before the SecretBytes outlives anything.
    package init(utf8 string: String) {
        self.backing = _Storage(copying: string.utf8)
    }

    /// Convenience factory: `N` copies of a single byte. Useful in tests
    /// and as a placeholder (e.g. `SecretBytes.repeating(0, count: 16)`
    /// for a zero key).
    package static func repeating(_ byte: UInt8, count: Int) -> SecretBytes {
        SecretBytes(backing: _Storage(repeating: byte, count: count))
    }

    // MARK: - Size

    /// Byte count. Leaks only the length — intentional for the redacted
    /// descriptions and length-sensitive callers that don't need content.
    package var count: Int { backing.count }

    /// `true` when the buffer has zero bytes. Distinct from "not set";
    /// `SecretBytes([])` is a valid empty-but-present value.
    package var isEmpty: Bool { backing.count == 0 }

    // MARK: - Unsafe byte access

    /// Read-only access to the backing buffer for the duration of
    /// `body`'s execution. The pointer is valid only inside the closure —
    /// callers MUST NOT escape it. Throwing closures rethrow through.
    /// `body` returns an arbitrary result which is forwarded.
    ///
    /// Use for:
    ///   - Passing to C APIs that take `const uint8_t *, size_t`
    ///     (CommonCrypto, Keychain's `kSecValueData`, libc digests).
    ///   - Constant-time equality comparisons (see `==` below).
    ///   - Materialising a short-lived `Data` for Codable JSON encoding
    ///     (the keychainData() round-trip).
    ///
    /// Use NEVER for:
    ///   - Stashing the pointer outside the closure.
    ///   - Mutating through the buffer. The return type is immutable
    ///     (`UnsafeBufferPointer`, not `UnsafeMutable…`).
    package func withUnsafeBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        try backing.withUnsafeBytes(body)
    }

    /// Explicit redaction-tagged formatter. Exists for callers who want
    /// the redacted form without going through `String(describing:)` —
    /// e.g. structured-logging code that knows it's printing a secret
    /// and wants the call site to read that way.
    package func redactedDescription() -> String {
        "SecretBytes(<redacted, \(count) bytes>)"
    }

    private init(backing: _Storage) {
        self.backing = backing
    }
}

// MARK: - Redacted reflection + printing

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Default `print(secret)` / `"\(secret)"` output. Always redacted.
    package var description: String { redactedDescription() }

    /// Debugger / `dump()` / `po secret` output. Also always redacted.
    package var debugDescription: String { redactedDescription() }

    /// Mirror-based reflection (used by `dump()` and Xcode's debugger
    /// variable pane). Returns a zero-children `Mirror` with the redacted
    /// description, so no stored property is exposed. Without this,
    /// Swift's default Mirror synthesis would surface the backing
    /// storage through `dump()`.
    package var customMirror: Mirror {
        Mirror(
            self,
            children: [("description", redactedDescription())],
            displayStyle: .struct
        )
    }
}

// MARK: - Equatable (constant-time)

extension SecretBytes: Equatable {
    /// Constant-time byte comparison. Free side-channel defense: the
    /// single-threaded per-profile NTLM path has no meaningful timing
    /// attack surface in our user-space proxy threat model, but
    /// constant-time is ~5 LOC and costs nothing on modern CPUs.
    ///
    /// Short-circuits on length mismatch (length is not a secret —
    /// already exposed through `count`) and otherwise fans over every
    /// byte with a cumulative XOR.
    package static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        lhs.withUnsafeBytes { l in
            rhs.withUnsafeBytes { r in
                guard l.count == r.count else { return false }
                var diff: UInt8 = 0
                for i in 0..<l.count {
                    diff |= l[i] ^ r[i]
                }
                return diff == 0
            }
        }
    }
}

// MARK: - Class-backed storage (zero-on-deinit)

/// Owns the byte buffer. `final class` so `deinit` can fire
/// deterministically when the last `SecretBytes` struct holder releases
/// it. `@unchecked Sendable` because the buffer is written once at init
/// and never mutated afterward; concurrent reads through
/// `withUnsafeBytes` are safe without synchronisation.
///
/// Separate file-private name so `SecretBytes.backing` is opaque to
/// outside code — no way to leak the underlying class reference.
private final class _Storage: @unchecked Sendable {
    /// Heap-allocated buffer. `count` is trusted from the init.
    private let buffer: UnsafeMutableBufferPointer<UInt8>

    /// Externally-visible length.
    let count: Int

    init(copying bytes: some Collection<UInt8>) {
        self.count = bytes.count
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        self.buffer = buf

        guard bytes.count > 0 else { return }

        // Fast path: the collection exposes contiguous storage (Array,
        // ArraySlice, Data-backed UInt8 view, native-UTF8
        // String.UTF8View, UnsafeBufferPointer, etc.). One `memcpy`
        // into initialised memory; no iterator frames, no per-byte
        // loop. `withContiguousStorageIfAvailable` returns non-nil iff
        // the copy ran.
        let copied: Void? = bytes.withContiguousStorageIfAvailable { source in
            guard let srcBase = source.baseAddress,
                  let dstBase = buf.baseAddress,
                  source.count > 0 else { return }
            dstBase.initialize(from: srcBase, count: source.count)
        }
        if copied != nil { return }

        // Slow path: non-contiguous Collection (e.g. a bridged-NSString
        // UTF-16-backed UTF8View, or a custom Collection that hasn't
        // overridden `withContiguousStorageIfAvailable`). Stdlib's
        // `initialize(from:)` walks the iterator but writes directly
        // into `buf`'s uninitialised memory — no intermediate buffer,
        // no growth re-allocation.
        _ = buf.initialize(from: bytes)
    }

    init(copying bytes: UnsafeBufferPointer<UInt8>) {
        self.count = bytes.count
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        if let source = bytes.baseAddress, let destination = buf.baseAddress, bytes.count > 0 {
            destination.initialize(from: source, count: bytes.count)
        }
        self.buffer = buf
    }

    init(repeating byte: UInt8, count: Int) {
        self.count = count
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: count)
        if let base = buf.baseAddress, count > 0 {
            base.initialize(repeating: byte, count: count)
        }
        self.buffer = buf
    }

    deinit {
        // `memset_s` is the C11 standard "guaranteed-not-optimised-away"
        // zeroisation primitive: the compiler MUST preserve writes
        // through it even when the memory is freed immediately after
        // (unlike plain `memset` / `assign 0` which the optimiser can
        // and does elide as dead stores). Shrinks the window where a
        // post-release process core dump exposes the bytes.
        //
        // Only called on the final refcount drop: class semantics
        // guarantee exactly one `deinit` per allocation. The return
        // value (errno_t, non-zero on constraint violation) is ignored;
        // we wrote a compile-time-known smax and n so the constraints
        // cannot fail.
        Self.zero(buffer)
        buffer.deallocate()
    }

    func withUnsafeBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        try body(UnsafeBufferPointer(start: buffer.baseAddress, count: count))
    }

    static func zero(_ buffer: UnsafeMutableBufferPointer<UInt8>) {
        if let base = buffer.baseAddress, buffer.count > 0 {
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}
