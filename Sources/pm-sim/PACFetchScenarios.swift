// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel
import ProxyPAC

/// Real bounded file transport and evaluator replacement, using scratch state.
enum PACFetchScenarios {
    private struct Failure: Error { let message: String }

    @MainActor
    static func bounds() async throws -> ScenarioResult {
        let started = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-pac-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await exercise(directory: directory)
            try await exerciseHTTPS()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        return ScenarioResult(
            name: "pac-fetch-bounds", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: PACFetchLimits.maxScriptBytes,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: HTTPS/file ceilings, HTTP status and active cancellation enforced; failed refresh retains the last working PAC route"]
        )
    }

    private static func exercise(directory: URL) async throws {
        let file = directory.appendingPathComponent("proxy.pac")
        let script = "function FindProxyForURL() { return 'PROXY fixture.test:8080'; }\n//"
        var data = Data(script.utf8)
        data.append(Data(repeating: 120, count: PACFetchLimits.maxScriptBytes - data.count))
        try data.write(to: file)
        var config = GenericDefaults.shared.makeConfig()
        config.pacRoutingEnabled = true
        config.pacURL = file.absoluteString
        let fixedConfig = config
        let evaluator = CFPACEvaluator()
        let engine = PACRoutingEngine(configProvider: { fixedConfig }, resolver: evaluator)
        try await engine.refresh(force: true)
        data.append(120)
        try data.write(to: file)
        do {
            try await engine.refresh(force: true)
            throw Failure(message: "Oversized PAC was accepted")
        } catch PACResolverError.fetchFailed(let message) {
            guard message.contains("\(PACFetchLimits.maxScriptBytes)") else {
                throw Failure(message: "PAC fetch failed without identifying its byte limit")
            }
        }
        guard engine.routeChain(for: "https://fresh.test/", host: "fresh.test") == [.proxy(host: "fixture.test", port: 8080)] else {
            throw Failure(message: "Failed refresh replaced the last working PAC")
        }
        for invalid in ["<html>upstream error</html>", "function FindProxyForURL( {", "var missingFunction = true;"] {
            try Data(invalid.utf8).write(to: file)
            do {
                try await engine.refresh(force: true)
                throw Failure(message: "Invalid PAC replaced the working evaluator")
            } catch PACResolverError.evaluationFailed {
                // Candidate validation must fail before replacing the cache.
            }
            guard engine.routeChain(for: "https://uncached.test/", host: "uncached.test") == [.proxy(host: "fixture.test", port: 8080)] else {
                throw Failure(message: "Malformed PAC refresh discarded the working route")
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await evaluator.fetchPAC(from: file.absoluteString)
        }
        do {
            _ = try await cancelled.value
            throw Failure(message: "Cancelled PAC fetch succeeded")
        } catch is CancellationError {
            // Expected rejection: cancellation must win before file loading.
        }
    }

    private static func exerciseHTTPS() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PACFixtureProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let evaluator = CFPACEvaluator(session: session)
        let exact = try await evaluator.fetchPAC(from: "https://pac.fixture/exact")
        guard exact.utf8.count == PACFetchLimits.maxScriptBytes else {
            throw Failure(message: "HTTPS exact-ceiling document was truncated")
        }
        for path in ["overflow", "length", "status", "downgrade", "credentials"] {
            do {
                _ = try await evaluator.fetchPAC(from: "https://pac.fixture/\(path)")
                throw Failure(message: "HTTPS fixture \(path) unexpectedly succeeded")
            } catch PACResolverError.fetchFailed(let message) {
                let expected = path == "status" ? "503"
                    : ["downgrade", "credentials"].contains(path) ? "302" : "\(PACFetchLimits.maxScriptBytes)"
                guard message.contains(expected) else {
                    throw Failure(message: "HTTPS fixture \(path) failed for the wrong reason")
                }
            }
        }
        let redirected = try await evaluator.fetchPAC(from: "https://pac.fixture/redirect")
        guard redirected.utf8.count == PACFetchLimits.maxScriptBytes else {
            throw Failure(message: "HTTPS redirect did not preserve bounded loading")
        }
        PACFixtureProtocol.state.withLockedValue { $0 = (false, false) }
        let fetch = Task { try await evaluator.fetchPAC(from: "https://pac.fixture/stall") }
        defer { fetch.cancel() }
        for _ in 0..<200 {
            if PACFixtureProtocol.state.withLockedValue({ $0.started }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard PACFixtureProtocol.state.withLockedValue({ $0.started }) else {
            throw Failure(message: "HTTPS cancellation fixture did not start")
        }
        fetch.cancel()
        do {
            _ = try await fetch.value
            throw Failure(message: "Cancelled HTTPS fetch succeeded")
        } catch is CancellationError {
            // Expected cancellation surfaced by the bounded reader.
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // Expected cancellation surfaced by the underlying URLSession.
        }
        for _ in 0..<200 {
            if PACFixtureProtocol.state.withLockedValue({ $0.stopped }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard PACFixtureProtocol.state.withLockedValue({ $0.stopped }) else {
            throw Failure(message: "Cancelled HTTPS fetch left its transport running")
        }
    }

}


/// Synthetic HTTPS transport exercises the production URLSession delegate reader
/// without certificates or network/system changes. Each body is at most cap+1.
private final class PACFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = NIOLockedValueBox((started: false, stopped: false))
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pac.fixture" }
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
            Self.state.withLockedValue { $0.started = true }
            return
        }
        if path == "length" || path == "status" { return }
        let count = PACFetchLimits.maxScriptBytes + (path == "overflow" ? 1 : 0)
        for offset in stride(from: 0, to: count, by: 4096) {
            client?.urlProtocol(self, didLoad: Data(repeating: 120, count: min(4096, count - offset)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.lastPathComponent == "stall" {
            Self.state.withLockedValue { $0.stopped = true }
        }
    }
}
