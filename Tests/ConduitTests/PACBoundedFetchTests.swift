// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACBoundedFetchTests: XCTestCase {
    func testHTTPSAcceptsExactCeilingAndRejectsUnknownLengthOverflow() async throws {
        let evaluator = makeEvaluator()
        let script = try await evaluator.fetchPAC(from: "https://pac.test/exact")
        XCTAssertEqual(script.utf8.count, PACFetchLimits.maxScriptBytes)
        await assertFetchFails(evaluator, path: "overflow")
    }

    func testHTTPSRejectsAdvertisedOverflowBeforeBodyArrives() async {
        // This fixture never sends a body or EOF. Waiting for the body would
        // time out rather than produce the ceiling failure asserted here.
        await assertFetchFails(makeEvaluator(), path: "length")
    }

    func testHTTPSRedirectPolicy() async throws {
        let evaluator = makeEvaluator()
        let redirected = try await evaluator.fetchPAC(from: "https://pac.test/redirect")
        XCTAssertEqual(redirected.utf8.count, PACFetchLimits.maxScriptBytes)
        await assertFetchFails(evaluator, path: "downgrade", containing: "302")
        await assertFetchFails(evaluator, path: "credentials", containing: "302")
    }

    func testHTTPSRejectsHTTPErrorWithoutEvaluatingBody() async {
        await assertFetchFails(makeEvaluator(), path: "status", containing: "503")
    }

    func testCancellationStopsAnInFlightHTTPSBody() async throws {
        let started = expectation(description: "response delivered")
        let stopped = expectation(description: "transfer cancelled")
        PACFetchProtocol.callbacks.withLockedValue { $0 = (started, stopped) }
        defer { PACFetchProtocol.callbacks.withLockedValue { $0 = nil } }
        let evaluator = makeEvaluator()
        let fetch = Task { try await evaluator.fetchPAC(from: "https://pac.test/stall") }
        await fulfillment(of: [started], timeout: 2)
        fetch.cancel()
        do {
            _ = try await fetch.value
            XCTFail("cancelled fetch must fail")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testFilesAcceptExactCeilingAndRejectOverflow() async throws {
        let file = try temporaryPAC(Data(repeating: 120, count: PACFetchLimits.maxScriptBytes))
        let evaluator = CFPACEvaluator()
        let script = try await evaluator.fetchPAC(from: file.absoluteString)
        XCTAssertEqual(script.utf8.count, PACFetchLimits.maxScriptBytes)
        try Data(repeating: 120, count: PACFetchLimits.maxScriptBytes + 1).write(to: file)
        do {
            _ = try await evaluator.fetchPAC(from: file.absoluteString)
            XCTFail("oversized file must fail")
        } catch { assertLimit(error) }
    }

    func testCancelledFileFetchFailsBeforeReading() async throws {
        let file = try temporaryPAC(Data("function FindProxyForURL() { return 'DIRECT'; }".utf8))
        let fetch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CFPACEvaluator().fetchPAC(from: file.absoluteString)
        }
        do {
            _ = try await fetch.value
            XCTFail("cancelled file fetch must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOversizedRefreshKeepsPreviouslyWorkingRoutes() async throws {
        let file = try temporaryPAC(Data("function FindProxyForURL() { return 'PROXY good.test:8080'; }".utf8))
        var config = ProxyConfig.testFixture()
        config.pacRoutingEnabled = true
        config.pacURL = file.absoluteString
        let engine = PACRoutingEngine(configProvider: { config }, resolver: CFPACEvaluator())
        try await engine.refresh(force: true)
        try Data(repeating: 120, count: PACFetchLimits.maxScriptBytes + 1).write(to: file)
        do {
            try await engine.refresh(force: true)
            XCTFail("oversized refresh must fail")
        } catch { assertLimit(error) }
        XCTAssertEqual(engine.routeChain(for: "https://new.test/", host: "new.test"), [.proxy(host: "good.test", port: 8080)])
    }

    func testMalformedRefreshKeepsPreviouslyWorkingRoutes() async throws {
        let file = try temporaryPAC(Data("function FindProxyForURL() { return 'PROXY good.test:8080'; }".utf8))
        var config = ProxyConfig.testFixture()
        config.pacRoutingEnabled = true
        config.pacURL = file.absoluteString
        let engine = PACRoutingEngine(configProvider: { config }, resolver: CFPACEvaluator())
        try await engine.refresh(force: true)
        for invalid in ["<html>upstream error</html>", "function FindProxyForURL( {", "var missingFunction = true;"] {
            try Data(invalid.utf8).write(to: file)
            do {
                try await engine.refresh(force: true)
                XCTFail("invalid script must fail refresh")
            } catch {
                guard case PACResolverError.evaluationFailed = error else {
                    return XCTFail("expected evaluation failure, got \(error)")
                }
            }
            XCTAssertEqual(engine.routeChain(for: "https://new.test/", host: "new.test"), [.proxy(host: "good.test", port: 8080)])
        }
    }

    private func makeEvaluator() -> CFPACEvaluator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PACFetchProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return CFPACEvaluator(session: session)
    }

    private func temporaryPAC(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pac-bounds-\(UUID()).pac")
        try data.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertFetchFails(_ evaluator: CFPACEvaluator, path: String, containing: String? = nil) async {
        do {
            _ = try await evaluator.fetchPAC(from: "https://pac.test/\(path)")
            XCTFail("fixture \(path) must fail")
        } catch {
            if let containing {
                XCTAssertTrue(error.localizedDescription.contains(containing))
            } else { assertLimit(error) }
        }
    }

    private func assertLimit(_ error: Error) {
        guard case PACResolverError.fetchFailed(let message) = error else {
            return XCTFail("expected PAC size failure, got \(error)")
        }
        XCTAssertTrue(message.contains("\(PACFetchLimits.maxScriptBytes)"))
    }
}

/// Per-request fixture data is bounded to 256 KiB + one byte. The single
/// callback slot belongs only to the stalled-transfer cancellation case.
private final class PACFetchProtocol: URLProtocol, @unchecked Sendable {
    static let callbacks = NIOLockedValueBox<(XCTestExpectation, XCTestExpectation)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pac.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.lastPathComponent
        if ["redirect", "downgrade", "credentials"].contains(path) {
            let target = path == "downgrade" ? "http://pac.fixture/exact"
                : path == "credentials" ? "https://user:password@pac.fixture/exact"
                : request.url!.deletingLastPathComponent().appendingPathComponent("exact").absoluteString
            let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target, "Content-Type": "application/x-ns-proxy-autoconfig"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: redirect)
            // Refused redirects never finish: policy rejection must terminate
            // the fetch without waiting for the original response body.
            if path != "redirect" { return }
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Without a MIME type CFNetwork waits for body bytes to sniff it;
        // these fixtures intentionally test admission before any body arrives.
        var headers = ["Content-Type": "application/x-ns-proxy-autoconfig"]
        if path == "length" { headers["Content-Length"] = "\(PACFetchLimits.maxScriptBytes + 1)" }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "status" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "stall" {
            Self.callbacks.withLockedValue { $0?.0 }?.fulfill()
            return
        }
        if path == "length" || path == "status" { return }
        let size = PACFetchLimits.maxScriptBytes + (path == "overflow" ? 1 : 0)
        for offset in stride(from: 0, to: size, by: 4096) {
            client?.urlProtocol(self, didLoad: Data(repeating: 120, count: min(4096, size - offset)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.lastPathComponent == "stall" {
            Self.callbacks.withLockedValue { $0?.1 }?.fulfill()
        }
    }
}
