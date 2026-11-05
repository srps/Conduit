// SPDX-License-Identifier: Apache-2.0
import NIOHTTP1
import XCTest
@testable import ProxyKernel

final class UpstreamSilencesTests: XCTestCase {
    private func origin(_ hostPort: String) -> ExchangeOrigin { .authority(hostPort, defaultPort: 80) }

    func testTheSecondSilenceInARowAsksTheProbe() {
        var silences = UpstreamSilences()
        XCTAssertEqual(silences.recordUnanswered(origin: origin("a:80"), source: .exchange), .init(consecutive: 1, origins: 1, asksProbe: false))
        XCTAssertEqual(silences.recordUnanswered(origin: origin("a:80"), source: .exchange), .init(consecutive: 2, origins: 1, asksProbe: true))
        XCTAssertFalse(silences.recordUnanswered(origin: origin("a:80"), source: .exchange).acrossOrigins, "one slow origin never spans two")
    }

    func testAHealthCheckAsksTheProbeAtItsFirstSilence() {
        var silences = UpstreamSilences()
        XCTAssertEqual(silences.recordUnanswered(origin: origin("check:80"), source: .healthCheck), .init(consecutive: 1, origins: 1, asksProbe: true))
    }

    func testOriginsAreDistinctAndCappedAtTheVerdict() {
        var silences = UpstreamSilences()
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        XCTAssertTrue(silences.recordUnanswered(origin: origin("b:443"), source: .exchange).acrossOrigins)
        XCTAssertTrue(silences.recordUnanswered(origin: origin("c:80"), source: .exchange).acrossOrigins)
        XCTAssertEqual(silences.origins, [origin("a:80"), origin("b:443")], "bounded by decisiveOrigins")
    }

    func testAStandingFailureMakesTheFirstSilenceAskAndKeepsTheOrigins() {
        var silences = UpstreamSilences()
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        silences.recordFailure()
        XCTAssertEqual(silences.recordUnanswered(origin: origin("b:80"), source: .exchange), .init(consecutive: 1, origins: 2, asksProbe: true))
    }

    func testTheProxysOwnAnswerResetsTheProbeTriggerButNotTheOrigins() {
        var silences = UpstreamSilences()
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        silences.recordProbeAnswer()
        XCTAssertEqual(silences.recordUnanswered(origin: origin("b:80"), source: .exchange), .init(consecutive: 1, origins: 2, asksProbe: false))
    }

    func testAnAnsweredExchangeClearsEverything() {
        var silences = UpstreamSilences()
        silences.recordFailure()
        _ = silences.recordUnanswered(origin: origin("a:80"), source: .exchange)
        silences.recordAnswer()
        XCTAssertEqual(silences, UpstreamSilences())
        XCTAssertEqual(silences.recordUnanswered(origin: origin("b:80"), source: .exchange), .init(consecutive: 1, origins: 1, asksProbe: false))
    }

    func testAnOriginIsTheTargetsHostAndPort() {
        func head(_ method: HTTPMethod, _ uri: String, host: String? = nil) -> HTTPRequestHead {
            var head = HTTPRequestHead(version: .http1_1, method: method, uri: uri)
            if let host { head.headers.add(name: "Host", value: host) }
            return head
        }
        XCTAssertEqual(ExchangeOrigin(head(.GET, "http://Example.COM/a")).hostPort, "example.com:80")
        XCTAssertEqual(ExchangeOrigin(head(.GET, "https://example.com/a")).hostPort, "example.com:443")
        XCTAssertEqual(ExchangeOrigin(head(.GET, "http://example.com:8080/a")).hostPort, "example.com:8080")
        XCTAssertEqual(ExchangeOrigin(head(.GET, "/a", host: "Example.com")).hostPort, "example.com:80")
        XCTAssertEqual(ExchangeOrigin(head(.CONNECT, "example.com:8443")).hostPort, "example.com:8443")
        XCTAssertEqual(ExchangeOrigin.connect("example.com").hostPort, "example.com:443")
        XCTAssertEqual(ExchangeOrigin.connect("[::1]").hostPort, "[::1]:443")
    }
}
