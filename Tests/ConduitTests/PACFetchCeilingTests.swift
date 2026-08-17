// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import Conduit

/// The PAC fetch states its own output ceiling (`AppState.pacMaxOutputBytes`)
/// rather than inheriting `CommandRunner.defaultMaxOutputBytes`. Before that
/// constant existed the call site's comment claimed it did, and
/// `defaultMaxOutputBytes`'s own comment named this call site as its example of
/// a caller that states its own — two comments corroborating each other while
/// both were false.
///
/// `file://` URLs are the seam: `curlPACFetcher` shells out to `/usr/bin/curl`,
/// which reads them without a server, so the ceiling can be exercised for real
/// instead of against a mock of the thing under test.
final class PACFetchCeilingTests: XCTestCase {

    private func writePAC(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-pac-\(UUID().uuidString).pac")
        // Valid-enough PAC prologue padded to size with a comment; the fetch
        // never parses it, and the point of the case is the byte count.
        let prologue = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n//"
        let padding = String(repeating: "x", count: max(0, bytes - prologue.utf8.count))
        try Data((prologue + padding).utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPACUnderTheCeilingIsFetched() async throws {
        let url = try writePAC(bytes: AppState.pacMaxOutputBytes - 1_024)
        let script = try await AppState.curlPACFetcher(url)
        XCTAssertTrue(script.hasPrefix("function FindProxyForURL"))
    }

    /// A PAC past the ceiling fails the fetch. Truncating instead would hand
    /// the routing engine a half-read script, which routes traffic wrongly
    /// rather than visibly breaking.
    func testPACBeyondTheCeilingFailsTheFetch() async throws {
        let url = try writePAC(bytes: AppState.pacMaxOutputBytes + 1_024)
        do {
            _ = try await AppState.curlPACFetcher(url)
            XCTFail("a PAC past \(AppState.pacMaxOutputBytes) bytes must fail the fetch")
        } catch let error as PACResolverError {
            // Wrapped, so the caller sees one error type on this path.
            guard case .fetchFailed(let message) = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("\(AppState.pacMaxOutputBytes)"),
                "the failure should name the ceiling it hit, got: \(message)"
            )
        }
    }

    /// The ceiling is the PAC's own, not the shared default — which is what
    /// makes the case above a test of *this* constant rather than of
    /// `CommandRunner`. Wire `defaultMaxOutputBytes` back in and a 257 KiB
    /// document sails through.
    func testTheCeilingIsNotTheSharedDefault() {
        XCTAssertLessThan(AppState.pacMaxOutputBytes, CommandRunner.defaultMaxOutputBytes)
    }
}
