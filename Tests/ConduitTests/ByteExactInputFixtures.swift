// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// One word in two Unicode spellings (#246): precomposed `é` (U+00E9) and `e` followed by a combining acute (U+0065 U+0301). Their
/// UTF-8 differs, and what acts on the value (a fetch URL, a request line, a Keychain account, an NTLM message) sends the bytes. The
/// persisted value is the user's intent byte for byte (decisions 0023, 0027), so the runtime must hold those bytes too.
enum Respelled {
    static let composed = "caf\u{E9}"
    static let decomposed = "cafe\u{301}"

    /// Fails unless `a` and `b` differ in UTF-8, so a witness built on them cannot pass vacuously.
    static func assertRespelling(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(Array(a.utf8), Array(b.utf8), "the two spellings must differ in UTF-8", file: file, line: line)
    }
}

/// Compares UTF-8, not `String` equality, which would accept the other spelling.
func assertSameUTF8(
    _ actual: String?, _ expected: String, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.map { Array($0.utf8) }, Array(expected.utf8), message(), file: file, line: line)
}

/// A PAC evaluator that keeps the fetch count and the UTF-8 of the last URL fetched, and nothing else, so it stays bounded however
/// often the engine fetches. Every fetch answers a DIRECT-only script, evaluated without a PAC engine.
final class LastFetchPACEvaluator: PacEvaluator, @unchecked Sendable {
    private struct DirectOnly: PacScriptEvaluating {
        func resolveProxyChain(for url: URL) throws -> [String] { ["DIRECT"] }
    }

    private let lock = NSLock()
    private var count = 0
    private var last: [UInt8]?

    var fetchCount: Int { lock.withLock { count } }
    var lastFetchedUTF8: [UInt8]? { lock.withLock { last } }

    func fetchPAC(from urlString: String) async throws -> String {
        lock.withLock {
            count += 1
            last = Array(urlString.utf8)
        }
        return #"function FindProxyForURL(url, host) { return "DIRECT"; }"#
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { DirectOnly() }

    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { _ in nil }
    }
}
