// SPDX-License-Identifier: Apache-2.0
// Test corpus for the CFNetwork PAC evaluator. Asserts that
// `CFPACEvaluator` / `CFPacScriptEvaluator` cover the standard PAC features
// the codebase exercises today: DIRECT, PROXY, multi-step chains,
// dnsResolve, dnsDomainIs, shExpMatch, isResolvable, isInNet.
//
// These tests cover the routing decisions Conduit actually depends on,
// including CFNetwork-specific normalisation and failure behaviour.

import Foundation
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class CFPACEvaluatorTests: XCTestCase {

    // MARK: - fetchPAC

    func testFetchPACUsesInsecureFetcherForHTTPURLs() async throws {
        let expected = "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
        let evaluator = CFPACEvaluator(
            insecureFetcher: { url in
                XCTAssertEqual(url.absoluteString, "http://example.test/proxy.pac")
                return expected
            }
        )

        let script = try await evaluator.fetchPAC(from: "http://example.test/proxy.pac")
        XCTAssertEqual(script, expected)
    }

    func testFetchPACReadsFileURLs() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pac")
        let expected = "function FindProxyForURL(url, host) { return \"PROXY corp.example.com:8080\"; }"
        try expected.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let script = try await CFPACEvaluator().fetchPAC(from: fileURL.absoluteString)
        XCTAssertEqual(script, expected)
    }

    // MARK: - Basic FindProxyForURL returns

    func testFindProxyForURLReturnsDirect() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) { return "DIRECT"; }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testFindProxyForURLReturnsProxy() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) { return "PROXY corp.example.com:3128"; }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["PROXY corp.example.com:3128"])
    }

    func testFindProxyForURLReturnsChainOfProxies() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return "PROXY a.example.com:8080; PROXY b.example.com:8081; DIRECT";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, [
            "PROXY a.example.com:8080",
            "PROXY b.example.com:8081",
            "DIRECT"
        ])
    }

    // MARK: - PAC helpers (JS-engine-agnostic, but verify CFNetwork wires them)

    func testDnsDomainIsRoutesInternalToDirect() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            if (dnsDomainIs(host, ".example.com")) return "DIRECT";
            return "PROXY upstream:8080";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://sub.example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testShExpMatchRoutesLocalToDirect() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.local")) return "DIRECT";
            return "PROXY upstream:8080";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://myhost.local/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testIsPlainHostNameDifferentiatesShortAndFQDN() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return isPlainHostName(host) ? "DIRECT" : "PROXY upstream:8080";
        }
        """)
        let plain = try evaluator.resolveProxyChain(for: URL(string: "http://intranet/")!)
        let fqdn = try evaluator.resolveProxyChain(for: URL(string: "http://www.example.com/")!)
        XCTAssertEqual(plain, ["DIRECT"])
        XCTAssertEqual(fqdn, ["PROXY upstream:8080"])
    }

    // MARK: - dnsResolve / isResolvable / isInNet

    func testDnsResolveLocalhost() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return dnsResolve("localhost") === "127.0.0.1" ? "DIRECT" : "PROXY fail:1";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testIsResolvableReturnsTrueForLocalhost() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return isResolvable("localhost") ? "DIRECT" : "PROXY fail:1";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testIsResolvableReturnsFalseForGarbage() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return isResolvable("this-host-definitely-does-not-exist-7f3a.invalid") ? "PROXY fail:1" : "DIRECT";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testIsInNetWithIPLiteral() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            if (isInNet("10.0.0.5", "10.0.0.0", "255.255.255.0")) {
                return "DIRECT";
            }
            return "PROXY upstream:8080";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    func testIsInNetWithLocalhostResolution() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            if (isInNet(dnsResolve("localhost"), "127.0.0.0", "255.0.0.0")) {
                return "DIRECT";
            }
            return "PROXY upstream:8080";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    // MARK: - myIpAddress

    /// CFNetwork's PAC engine validates `FindProxyForURL` return strings
    /// against the PAC directive grammar (PROXY / SOCKS / DIRECT). A bare
    /// IP literal isn't a valid directive, so CFNetwork would normalise it
    /// to DIRECT — that's a CFNetwork↔JSC behavioural difference (JSC
    /// passes strings through verbatim). To verify `myIpAddress()` is wired
    /// without hitting that, we use it inside the script and route based
    /// on whether it's non-empty.
    func testMyIpAddressIsCallableAndReturnsNonEmpty() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            var ip = myIpAddress();
            return (ip && ip.length > 0) ? "PROXY ok.example.com:1" : "PROXY fail.example.com:1";
        }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["PROXY ok.example.com:1"],
                       "myIpAddress() should be callable inside CFNetwork PAC; " +
                       "non-empty result indicates the helper is wired.")
    }

    // MARK: - Empty / fallback / error paths

    func testEmptyFindProxyReturnsDirect() throws {
        // CFNetwork normalizes empty / whitespace-only PAC results into the
        // `kCFProxyTypeNone` entry, which our parser maps to "DIRECT".
        // Empty or whitespace-only decisions must still produce a usable
        // route chain.
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) { return ""; }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"])
    }

    /// Regression guard: when CFNetwork
    /// returns a non-empty proxy list whose entries all fail extraction
    /// (unknown type, missing host/port keys, port out of range), the
    /// pre-fix `parseProxyList` returned `[]` — `PACRoutingEngine` then
    /// produced an empty `[PACRoute]`, `HTTPProxyHandler.route` was `nil`,
    /// and the request was routed through the configured upstream rather
    /// than going DIRECT (the OPPOSITE of what an unparsable PAC decision
    /// should do).
    ///
    /// `PROXY foo:99999` exercises the all-filtered path: port 99999 is a
    /// valid CFNumber but `extractHostPort` rejects it (out of 1..65535).
    /// Either CFNetwork accepts the script and produces a CFDictionary
    /// that fails extraction (count > 0, all filtered → fallback fires)
    /// OR CFNetwork rejects at parse time and the result is empty
    /// (count == 0 → same fallback). Both paths must end at "DIRECT".
    func testEvaluationFallsBackToDirectWhenAllProxyEntriesAreUnusable() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) { return "PROXY foo.example.com:99999"; }
        """)
        let result = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(result, ["DIRECT"],
                       "All-filtered CFNetwork proxy list must default to DIRECT, not empty " +
                       "— empty chains route through the configured upstream instead of safely going direct.")
    }

    func testInvalidScriptThrowsEvaluationFailed() {
        // A script missing FindProxyForURL is a runtime error CFNetwork
        // surfaces via the callback's CFError → our `evaluationFailed`.
        let evaluator: CFPacScriptEvaluator
        do {
            evaluator = try CFPacScriptEvaluator(pacScript: "var x = 1;  // no FindProxyForURL")
        } catch {
            XCTFail("Construction shouldn't throw — invalid scripts surface on first eval, not init: \(error)")
            return
        }
        XCTAssertThrowsError(
            try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        ) { error in
            guard case PACResolverError.evaluationFailed = error else {
                XCTFail("Expected evaluationFailed, got: \(error)")
                return
            }
        }
    }

    // MARK: - routeChain (PacEvaluator protocol method, parses raw entries)

    func testRouteChainParsesProxyAndDirect() {
        let evaluator = CFPACEvaluator()
        let routes = evaluator.routeChain(for: ["PROXY corp.example.com:3128", "DIRECT"])
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0], .proxy(host: "corp.example.com", port: 3128))
        XCTAssertEqual(routes[1], .direct)
    }

    func testRouteChainHandlesSocksAndHTTP() {
        let evaluator = CFPACEvaluator()
        let routes = evaluator.routeChain(for: [
            "HTTP fast.example.com:80",
            "HTTPS secure.example.com:443",
            "SOCKS5 tunnel.example.com:1080",
            "DIRECT"
        ])
        XCTAssertEqual(routes.count, 4)
        XCTAssertEqual(routes[0], .proxy(host: "fast.example.com", port: 80))
        XCTAssertEqual(routes[1], .proxy(host: "secure.example.com", port: 443))
        XCTAssertEqual(routes[2], .socks(host: "tunnel.example.com", port: 1080))
        XCTAssertEqual(routes[3], .direct)
    }

    func testRouteChainSilentlySkipsUnparsableEntries() {
        // Unknown directive types and malformed entries are dropped rather
        // than failing the chain.
        // (Note: `parseRoute` accepts port 0 as a valid Int; rejecting
        // unusual ports is `extractHostPort`'s job — that path runs only
        // when CFNetwork constructs the proxy dictionary, not in the
        // string-parsing path tested here.)
        let evaluator = CFPACEvaluator()
        let routes = evaluator.routeChain(for: [
            "VENDOR_SPECIFIC something",     // unknown kind → dropped
            "PROXY",                          // missing endpoint → dropped
            "PROXY missing-port-host",        // no colon → dropped
            "PROXY good.example.com:8080",    // valid
        ])
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0], .proxy(host: "good.example.com", port: 8080))
    }

    // MARK: - Resource lifetime

    /// Defensive smoke test for the resource-management refactor that
    /// added `CFRunLoopSourceInvalidate`, CFStreamClientContext
    /// retain/release callbacks, and `autoreleasepool` wrapping.
    ///
    /// Pre-fix, the C callback's context info pointer was
    /// `passUnretained(resultBox)` — the box's lifetime ended at function
    /// return, so any delayed callback (CFNetwork machinery still in
    /// flight after timeout) would dereference freed memory. CFRunLoop
    /// sources also leaked because they were never invalidated.
    ///
    /// 200 evaluations is small but enough to surface use-after-free as a
    /// crash and to surface ObjC autorelease growth as a Mach memory
    /// pressure event under leaks/Instruments. The test passes by
    /// completing without crashing or timing out.
    func testHighFrequencyEvaluationsDoNotCrashOrLeak() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.example.com")) return "DIRECT";
            return "PROXY upstream.corp:8080";
        }
        """)
        let urls = [
            URL(string: "http://www.example.com/")!,
            URL(string: "http://api.corp.local/data")!,
            URL(string: "https://images.cdn.example.org/asset.png")!,
        ]
        for i in 0..<200 {
            let url = urls[i % urls.count]
            let result = try evaluator.resolveProxyChain(for: url)
            XCTAssertFalse(result.isEmpty,
                           "Iteration \(i) (url=\(url)) returned empty chain — fallback to DIRECT should always produce at least one entry.")
        }
    }

    // MARK: - Convenience: PacEvaluator extension's resolveProxyChain(for:pacScript:)

    func testProtocolExtensionResolveCombinesMakeAndResolve() throws {
        let evaluator = CFPACEvaluator()
        let script = """
        function FindProxyForURL(url, host) { return "PROXY conv:1234"; }
        """
        let result = try evaluator.resolveProxyChain(
            for: URL(string: "http://example.com/")!,
            pacScript: script
        )
        XCTAssertEqual(result, ["PROXY conv:1234"])
    }

    // MARK: - Helper

    private func makeEvaluator(_ pacScript: String) throws -> CFPacScriptEvaluator {
        try CFPacScriptEvaluator(pacScript: pacScript)
    }
}
