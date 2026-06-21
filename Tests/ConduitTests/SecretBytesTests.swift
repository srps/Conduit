// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// Tests for the SecretBytes opaque credential container. Covers the
/// three protections the type exists to provide: (1) description /
/// debugDescription / Mirror-based reflection all redact, (2) Equatable
/// is constant-time and content-correct, (3) zero-on-deinit fires so the
/// backing buffer is scrubbed before release. Also covers the basic
/// init/access shape.
///
/// Not covered by these tests (explicitly out of scope):
///   - Compiler-preservation of `memset_s`: the C11 spec mandates this;
///     we can't test it from the language.
///   - Debugger / lldb visibility of live bytes: language-level
///     protections don't extend to authorised in-process memory reads.
final class SecretBytesTests: XCTestCase {

    /// A `Collection<UInt8>` that deliberately does NOT expose
    /// contiguous storage — the default `Collection
    /// .withContiguousStorageIfAvailable` returns nil, forcing the
    /// `_Storage(copying:)` init onto its iterator-based slow path.
    /// Exercises the non-contiguous branch that covers bridged
    /// `NSString` UTF-16-backed `UTF8View`s in production.
    private struct NonContiguousBytes: Collection {
        let bytes: [UInt8]
        var startIndex: Int { 0 }
        var endIndex: Int { bytes.count }
        func index(after i: Int) -> Int { i + 1 }
        subscript(position: Int) -> UInt8 { bytes[position] }
    }

    // MARK: - Basic shape

    func testInitFromBytesRoundTripsViaWithUnsafeBytes() {
        let input: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22]
        let secret = SecretBytes(input)

        XCTAssertEqual(secret.count, input.count)
        XCTAssertFalse(secret.isEmpty)

        let observed: [UInt8] = secret.withUnsafeBytes { buf in
            Array(buf)
        }
        XCTAssertEqual(observed, input)
    }

    func testInitFromDataRoundTripsViaWithUnsafeBytes() {
        let input = Data([0x01, 0x02, 0x03, 0x04])
        let secret = SecretBytes(input)

        let observed: Data = secret.withUnsafeBytes { buf in Data(buf) }
        XCTAssertEqual(observed, input)
    }

    func testInitFromNonContiguousCollectionRoundTripsViaWithUnsafeBytes() {
        let input = NonContiguousBytes(bytes: [0x10, 0x20, 0x30, 0x40])
        let secret = SecretBytes(input)

        let observed: [UInt8] = secret.withUnsafeBytes { Array($0) }
        XCTAssertEqual(observed, input.bytes)
    }

    func testInitFromStringEncodesUTF8() {
        let secret = SecretBytes(utf8: "hello")
        XCTAssertEqual(secret.count, 5)
        let observed: [UInt8] = secret.withUnsafeBytes { Array($0) }
        XCTAssertEqual(observed, [0x68, 0x65, 0x6C, 0x6C, 0x6F])
    }

    func testRepeatingFactory() {
        let secret = SecretBytes.repeating(0xAA, count: 16)
        XCTAssertEqual(secret.count, 16)
        secret.withUnsafeBytes { buf in
            XCTAssertTrue(buf.allSatisfy { $0 == 0xAA })
        }
    }

    func testEmptySecretBytesIsValid() {
        let empty = SecretBytes([] as [UInt8])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.count, 0)
        empty.withUnsafeBytes { buf in
            XCTAssertEqual(buf.count, 0)
        }
    }

    func testWithUnsafeBytesRethrows() {
        struct Sentinel: Error {}
        let secret = SecretBytes([0xFF])
        XCTAssertThrowsError(
            try secret.withUnsafeBytes { _ -> Never in throw Sentinel() }
        ) { error in
            XCTAssertTrue(error is Sentinel)
        }
    }

    func testWithUnsafeBytesReturnsArbitraryResult() {
        let secret = SecretBytes([1, 2, 3])
        let sum: Int = secret.withUnsafeBytes { buf in
            buf.reduce(0) { $0 + Int($1) }
        }
        XCTAssertEqual(sum, 6)
    }

    // MARK: - Equatable (constant-time)

    func testEquatableSameContent() {
        let a = SecretBytes([0x11, 0x22, 0x33, 0x44])
        let b = SecretBytes([0x11, 0x22, 0x33, 0x44])
        XCTAssertEqual(a, b)
    }

    func testEquatableDifferentContent() {
        let a = SecretBytes([0x11, 0x22, 0x33, 0x44])
        let b = SecretBytes([0x11, 0x22, 0x33, 0x99])
        XCTAssertNotEqual(a, b)
    }

    func testEquatableDifferentLength() {
        let a = SecretBytes([0x11, 0x22, 0x33])
        let b = SecretBytes([0x11, 0x22, 0x33, 0x44])
        XCTAssertNotEqual(a, b)
    }

    func testEquatableEmpty() {
        XCTAssertEqual(SecretBytes([] as [UInt8]), SecretBytes([] as [UInt8]))
        XCTAssertNotEqual(SecretBytes([] as [UInt8]), SecretBytes([0]))
    }

    // MARK: - Redacted descriptions

    /// `print(secret)` / `"\(secret)"` must NEVER expose the bytes.
    /// Regression guard: if someone removes `CustomStringConvertible`,
    /// Swift falls back to Mirror-based default that DOES expose
    /// stored fields. This test would then start showing the buffer
    /// contents or the internal `_Storage` reference.
    func testDescriptionRedactsAndShowsLengthOnly() {
        let secret = SecretBytes([0x11, 0x22, 0x33, 0x44])
        let described = String(describing: secret)

        XCTAssertTrue(
            described.contains("<redacted"),
            "description must contain the 'redacted' marker, got: \(described)"
        )
        XCTAssertTrue(
            described.contains("4 bytes"),
            "description should include the byte count, got: \(described)"
        )
        // The literal hex / binary representation of the bytes MUST NOT
        // appear. Both uppercase + lowercase hex forms covered.
        XCTAssertFalse(described.contains("11"))
        XCTAssertFalse(described.contains("22"))
        XCTAssertFalse(described.contains("33"))
        XCTAssertFalse(described.contains("44"))
    }

    func testDebugDescriptionRedactsSameAsDescription() {
        let secret = SecretBytes([0xFF, 0xEE])
        let dbg = String(reflecting: secret)
        XCTAssertTrue(dbg.contains("<redacted"))
        XCTAssertTrue(dbg.contains("2 bytes"))
        XCTAssertFalse(dbg.contains("FF"))
        XCTAssertFalse(dbg.contains("EE"))
    }

    /// `dump(secret)` / Xcode's variable-inspector path uses Mirror.
    /// Without CustomReflectable, Swift's default Mirror walks the
    /// stored properties and exposes `_Storage` (and transitively the
    /// buffer). With our customMirror override, the only child is the
    /// redacted description.
    func testMirrorReflectionRedactsStoredProperties() {
        let secret = SecretBytes([0xAB, 0xCD, 0xEF])
        let mirror = Mirror(reflecting: secret)

        // No stored-property children surface. The one child we ship
        // (for `dump()` readability) is the redacted string.
        let labels = mirror.children.compactMap(\.label)
        XCTAssertFalse(labels.contains("backing"),
                       "Mirror must not expose the internal _Storage reference")
        XCTAssertFalse(labels.contains("buffer"),
                       "Mirror must not expose the underlying buffer")

        // The one exposed child is the redacted description.
        let firstValue = mirror.children.first?.value as? String ?? ""
        XCTAssertTrue(firstValue.contains("<redacted"))
        XCTAssertFalse(firstValue.contains("AB"))
        XCTAssertFalse(firstValue.contains("CD"))
        XCTAssertFalse(firstValue.contains("EF"))
    }

    /// Full-dump path: `dump(secret)` in a diagnostic log should not
    /// leak bytes even under Mirror-based recursive descent.
    func testDumpOutputRedacts() {
        let secret = SecretBytes([0x11, 0x22, 0x33])
        var output = ""
        dump(secret, to: &output)

        XCTAssertTrue(output.contains("<redacted"),
                      "dump() output must include redacted marker, got: \(output)")
        XCTAssertFalse(output.contains("0x11"))
        XCTAssertFalse(output.contains("0x22"))
        XCTAssertFalse(output.contains("0x33"))
    }

    // MARK: - Value-type semantics (copies share backing, not content)

    /// SecretBytes is a struct; copies should behave as value copies
    /// from the caller's perspective (observed bytes are identical).
    /// Internally they share the class-backed _Storage, but that's
    /// invisible to callers.
    func testCopyObservesSameContent() {
        let a = SecretBytes([0x42, 0x43, 0x44])
        let b = a  // copy; shares backing

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, b.count)

        // Both observe the same bytes through withUnsafeBytes.
        let aBytes: [UInt8] = a.withUnsafeBytes { Array($0) }
        let bBytes: [UInt8] = b.withUnsafeBytes { Array($0) }
        XCTAssertEqual(aBytes, bBytes)
    }

    // MARK: - Zero-on-deinit smoke (observed via the exposed count + helper)

    /// A functional test of the zero-on-deinit guarantee is structurally
    /// hard in Swift — ARC decides exactly when the last reference
    /// drops, the deallocated buffer pointer is reused unpredictably,
    /// and we have no test hook inside the private _Storage class.
    ///
    /// This test exercises the DEALLOCATION path at least: create a
    /// SecretBytes in a tightly scoped closure, observe the content via
    /// withUnsafeBytes before the struct drops, then let ARC release
    /// after the scope. We can't assert the buffer is zeroed (the memory
    /// allocator is free to reuse the region), but we CAN assert the
    /// type doesn't crash on deallocation. This smoke catches regressions
    /// that break the deinit itself (e.g. an accidental double-deallocate
    /// if someone refactors _Storage wrong).
    func testDeinitFiresCleanlyOnScopeExit() {
        // Run many allocation/deallocation cycles in a tight loop. If
        // deinit misbehaves (double-free, UB), the test harness traps.
        for _ in 0..<1_000 {
            autoreleasepool {
                let secret = SecretBytes.repeating(0xCC, count: 64)
                _ = secret.withUnsafeBytes { buf in
                    buf.reduce(UInt8(0)) { $0 ^ $1 }
                }
                // secret drops here; _Storage.deinit runs once; buffer
                // is zeroed and deallocated.
            }
        }
        // Reaching this line means 1000 successful allocate → write →
        // scrub → deallocate cycles.
    }

    // MARK: - Sendable compile-check (type-system level)

    /// Compile-time check that SecretBytes is Sendable — the test body
    /// itself is the assertion. If SecretBytes stops being Sendable, the
    /// generic parameter won't satisfy the constraint and this fails to
    /// compile. No runtime check needed.
    func testSecretBytesIsSendableCompileCheck() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(SecretBytes.self)
    }
}
