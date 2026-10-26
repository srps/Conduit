// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// #246: the engine keys its loaded script by the URL's bytes. A respelled URL (see `Respelled`) is a different URL to fetch.
final class PACRoutingEngineByteExactTests: XCTestCase {

    private static func pacURL(_ word: String) -> String { "https://pac.example.test/\(word).pac" }

    private func makeEngine(url: NIOLockedValueBox<String>, pac: any PacEvaluator) -> PACRoutingEngine {
        PACRoutingEngine(
            configProvider: {
                var config = ProxyConfig.testFixture()
                config.pacRoutingEnabled = true
                config.pacURL = url.withLockedValue { $0 }
                return config
            },
            resolver: pac,
            refreshInterval: 300
        )
    }

    /// A refresh inside the interval is fresh only for the URL the script came from.
    func testARefreshAfterTheURLIsRespelledFetchesTheNewBytes() async throws {
        Respelled.assertRespelling(Self.pacURL(Respelled.composed), Self.pacURL(Respelled.decomposed))
        let url = NIOLockedValueBox(Self.pacURL(Respelled.composed))
        let pac = LastFetchPACEvaluator()
        let engine = makeEngine(url: url, pac: pac)
        try await engine.refresh()
        XCTAssertEqual(pac.fetchCount, 1)

        url.withLockedValue { $0 = Self.pacURL(Respelled.decomposed) }
        try await engine.refresh()

        XCTAssertEqual(pac.fetchCount, 2, "a respelled URL is not the one the script was fetched from")
        XCTAssertEqual(pac.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
    }

    /// The URL is respelled while its fetch runs. The script is from the old bytes, so the refresh fetches the new ones before it
    /// installs anything.
    func testARespellingDuringTheFetchIsFetchedBeforeTheRefreshEnds() async throws {
        let url = NIOLockedValueBox(Self.pacURL(Respelled.composed))
        let pac = RespellingDuringFetch(url: url, to: Self.pacURL(Respelled.decomposed))
        let engine = makeEngine(url: url, pac: pac)
        try await engine.refresh()

        XCTAssertEqual(pac.base.fetchCount, 2, "the fetch of the old bytes is followed by one of the new")
        XCTAssertEqual(pac.base.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
    }

    /// The failure backoff is per attempted URL. After the old bytes fail, the same bytes back off, and the respelled URL is a
    /// changed URL: fetched at once, as any other new URL is.
    func testARespellingAfterAFailedFetchIsFetchedDespiteTheBackoff() async throws {
        let url = NIOLockedValueBox(Self.pacURL(Respelled.composed))
        let pac = FailingFirstFetch()
        let engine = makeEngine(url: url, pac: pac)
        do {
            try await engine.refresh()
            XCTFail("the first fetch fails")
        } catch {}
        try await engine.refresh(honorBackoff: true)
        XCTAssertEqual(pac.base.fetchCount, 1, "control: the failed bytes back off")

        url.withLockedValue { $0 = Self.pacURL(Respelled.decomposed) }
        try await engine.refresh(honorBackoff: true)

        XCTAssertEqual(pac.base.fetchCount, 2, "the respelled URL is not held by the old URL's backoff")
        XCTAssertEqual(pac.base.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
    }

    /// The same through a routing decision, which starts the background refresh under the backoff.
    func testARoutingDecisionAfterAFailedFetchStartsAFetchOfTheRespelledURL() async throws {
        let url = NIOLockedValueBox(Self.pacURL(Respelled.composed))
        let pac = FailingFirstFetch()
        let engine = makeEngine(url: url, pac: pac)
        do {
            try await engine.refresh()
            XCTFail("the first fetch fails")
        } catch {}

        url.withLockedValue { $0 = Self.pacURL(Respelled.decomposed) }
        _ = engine.route(for: "https://example.test/", host: "example.test")
        for _ in 0..<500 where pac.base.fetchCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(pac.base.fetchCount, 2, "the decision starts a fetch of the respelled URL despite the backoff")
        XCTAssertEqual(pac.base.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
        // Joins the refresh the decision started; once it has ended, the respelled script is fresh and nothing is fetched.
        try await engine.refresh(honorBackoff: true)
        XCTAssertEqual(pac.base.fetchCount, 2, "joining fetches nothing more")
    }

    /// A script loaded from the old bytes stops routing at the first decision after the respelling, before its replacement loads, and
    /// that decision starts the fetch of the new bytes. The replacement fails here, and the old script does not come back.
    func testARoutingDecisionAfterTheURLIsRespelledStopsRoutingByTheOldScriptAndFetchesTheNewBytes() async throws {
        Respelled.assertRespelling(Self.pacURL(Respelled.composed), Self.pacURL(Respelled.decomposed))
        let url = NIOLockedValueBox(Self.pacURL(Respelled.composed))
        let pac = AnsweringFirstFetchOnly()
        let engine = makeEngine(url: url, pac: pac)
        try await engine.refresh()
        XCTAssertEqual(engine.routeChain(for: "https://example.test/", host: "example.test"), [.direct])
        XCTAssertEqual(engine.routeChain(for: "https://example.test/", host: "example.test"), [.direct])
        XCTAssertEqual(pac.base.fetchCount, 1, "control: the loaded script is fresh, so a decision fetches nothing")

        url.withLockedValue { $0 = Self.pacURL(Respelled.decomposed) }
        XCTAssertEqual(engine.routeChain(for: "https://example.test/", host: "example.test"), [],
                       "the script from the old bytes no longer routes")
        for _ in 0..<500 where pac.base.fetchCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(pac.base.fetchCount, 2, "the decision starts a fetch of the respelled URL")
        XCTAssertEqual(pac.base.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))

        // Joins the refresh the decision started, which fails as the fake does; once it has ended, the same bytes back off.
        do {
            try await engine.refresh(honorBackoff: true)
        } catch is UnreachablePAC {}
        XCTAssertEqual(pac.base.fetchCount, 2, "joining fetches nothing more")
        XCTAssertEqual(engine.routeChain(for: "https://example.test/", host: "example.test"), [],
                       "the old script does not come back when its replacement fails")
        XCTAssertEqual(pac.base.fetchCount, 2, "the failed bytes back off")
    }
}

private struct UnreachablePAC: Error {}

/// Fails the first fetch, as an unreachable PAC server does, and answers every later one.
private final class FailingFirstFetch: PacEvaluator, @unchecked Sendable {
    let base = LastFetchPACEvaluator()

    func fetchPAC(from urlString: String) async throws -> String {
        let script = try await base.fetchPAC(from: urlString)
        guard base.fetchCount > 1 else { throw UnreachablePAC() }
        return script
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        try base.makeEvaluator(pacScript: pacScript)
    }

    func routeChain(for entries: [String]) -> PACChain {
        base.routeChain(for: entries)
    }
}

/// Answers the first fetch and fails every later one, as a PAC server that goes away after the first load. Its chain parses the
/// script's `DIRECT`, so a decision by the loaded script is a visible route.
private final class AnsweringFirstFetchOnly: PacEvaluator, @unchecked Sendable {
    let base = LastFetchPACEvaluator()

    func fetchPAC(from urlString: String) async throws -> String {
        let script = try await base.fetchPAC(from: urlString)
        guard base.fetchCount == 1 else { throw UnreachablePAC() }
        return script
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        try base.makeEvaluator(pacScript: pacScript)
    }

    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { $0 == "DIRECT" ? .direct : nil }
    }
}

/// Respells the configured URL inside the first fetch, as an edit landing while the fetch is out would.
private final class RespellingDuringFetch: PacEvaluator, @unchecked Sendable {
    let base = LastFetchPACEvaluator()
    private let url: NIOLockedValueBox<String>
    private let respelling: String

    init(url: NIOLockedValueBox<String>, to respelling: String) {
        self.url = url
        self.respelling = respelling
    }

    func fetchPAC(from urlString: String) async throws -> String {
        let script = try await base.fetchPAC(from: urlString)
        if base.fetchCount == 1 {
            url.withLockedValue { $0 = respelling }
        }
        return script
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        try base.makeEvaluator(pacScript: pacScript)
    }

    func routeChain(for entries: [String]) -> PACChain {
        base.routeChain(for: entries)
    }
}
