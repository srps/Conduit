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

    // MARK: - Native directive table (#49)
    //
    // Pins what `CFNetworkExecuteProxyAutoConfigurationScript` hands the
    // adapter on this macOS, so a change in the mapping fails here instead of
    // silently changing routing. Each row runs the real CFNetwork evaluator.

    private struct NativeRow {
        let returns: String
        let http: [String]
        let https: [String]
    }

    func testNativeDirectiveTableMatchesCFNetwork() throws {
        let rows: [NativeRow] = [
            // `kCFProxyTypeHTTP` for http, `kCFProxyTypeHTTPS` for https: both
            // are a plain proxy (sent CONNECT for https), so both are PROXY.
            NativeRow(returns: "PROXY p.example:8080", http: ["PROXY p.example:8080"], https: ["PROXY p.example:8080"]),
            // A missing port becomes 80.
            NativeRow(returns: "PROXY p.example", http: ["PROXY p.example:80"], https: ["PROXY p.example:80"]),
            // CFNetwork does not range-check ports; the adapter passes the
            // entry on and the kernel rejects it (see the classification test).
            NativeRow(returns: "PROXY p.example:99999", http: ["PROXY p.example:99999"], https: ["PROXY p.example:99999"]),
            NativeRow(returns: "SOCKS s.example:1080", http: ["SOCKS s.example:1080"], https: ["SOCKS s.example:1080"]),
            // Dropped by CFNetwork before the adapter sees them.
            NativeRow(returns: "HTTPS p.example:8443", http: [], https: []),
            NativeRow(returns: "HTTP p.example:8080", http: [], https: []),
            NativeRow(returns: "SOCKS5 s.example:1080", http: [], https: []),
            NativeRow(returns: "QUIC q.example:443", http: [], https: []),
            NativeRow(returns: "BOGUS x.example:1", http: [], https: []),
            NativeRow(returns: "", http: [], https: []),
            // A dropped entry shifts the chain; nothing reports it.
            NativeRow(returns: "HTTPS p.example:8443; PROXY q.example:8080; DIRECT",
                      http: ["PROXY q.example:8080", "DIRECT"], https: ["PROXY q.example:8080", "DIRECT"]),
            NativeRow(returns: "DIRECT", http: ["DIRECT"], https: ["DIRECT"]),
            NativeRow(returns: "SOCKS s.example:1080; DIRECT", http: ["SOCKS s.example:1080", "DIRECT"],
                      https: ["SOCKS s.example:1080", "DIRECT"]),
        ]
        for row in rows {
            let evaluator = try makeEvaluator("function FindProxyForURL(url, host) { return \"\(row.returns)\"; }")
            XCTAssertEqual(try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!), row.http,
                           "http: \(row.returns)")
            XCTAssertEqual(try evaluator.resolveProxyChain(for: URL(string: "https://example.com/")!), row.https,
                           "https: \(row.returns)")
        }
    }

    /// The adapter never synthesizes DIRECT: an answer CFNetwork emptied is
    /// routed as "no usable answer", not as a bypass (#50).
    func testNativeUnusableAnswersAreNoUsableAnswerNotDirect() throws {
        let resolver = CFPACEvaluator()
        let cases: [(returns: String, decision: PACDecision)] = [
            ("", .noUsableAnswer(.empty, rejected: [])),
            ("HTTPS p.example:8443", .noUsableAnswer(.empty, rejected: [])),
            ("SOCKS5 s.example:1080; QUIC q.example:443", .noUsableAnswer(.empty, rejected: [])),
            ("SOCKS s.example:1080", .noUsableAnswer(
                .unsupported, rejected: [PACRejectedEntry(type: "SOCKS", reason: .unsupported)])),
            ("PROXY p.example:99999", .noUsableAnswer(
                .invalid, rejected: [PACRejectedEntry(type: "PROXY", reason: .invalid)])),
            ("PROXY p.example:0; SOCKS s.example:1080", .noUsableAnswer(
                .unsupported, rejected: [
                    PACRejectedEntry(type: "PROXY", reason: .invalid),
                    PACRejectedEntry(type: "SOCKS", reason: .unsupported),
                ])),
        ]
        for testCase in cases {
            let evaluator = try makeEvaluator("function FindProxyForURL(url, host) { return \"\(testCase.returns)\"; }")
            for url in ["http://example.com/", "https://example.com/"] {
                let raw = try evaluator.resolveProxyChain(for: URL(string: url)!)
                XCTAssertFalse(raw.contains("DIRECT"), "\(testCase.returns) for \(url) produced DIRECT: \(raw)")
                XCTAssertEqual(PACDecision(chain: resolver.routeChain(for: raw)), testCase.decision,
                               "\(testCase.returns) for \(url)")
            }
        }
    }

    func testNativeMixedChainKeepsOrderAndReportsRejections() throws {
        let resolver = CFPACEvaluator()
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            return "PROXY bad.example:99999; SOCKS s.example:1080; PROXY good.example:8080; DIRECT";
        }
        """)
        let chain = resolver.routeChain(for: try evaluator.resolveProxyChain(for: URL(string: "https://example.com/")!))
        XCTAssertEqual(chain.routes, [.proxy(host: "good.example", port: 8080), .direct])
        XCTAssertEqual(chain.rejected, [
            PACRejectedEntry(type: "PROXY", reason: .invalid),
            PACRejectedEntry(type: "SOCKS", reason: .unsupported),
        ])
        XCTAssertFalse(chain.leadingDirectPromoted)
    }

    /// A DIRECT that follows only rejected entries is promoted, not explicit.
    func testNativeDirectAfterRejectedProxyIsPromoted() throws {
        let resolver = CFPACEvaluator()
        let promoted = try makeEvaluator("function FindProxyForURL(url, host) { return \"SOCKS s.example:1080; DIRECT\"; }")
        let chain = resolver.routeChain(for: try promoted.resolveProxyChain(for: URL(string: "http://example.com/")!))
        XCTAssertEqual(chain.routes, [.direct])
        XCTAssertTrue(chain.leadingDirectPromoted)

        let explicit = try makeEvaluator("function FindProxyForURL(url, host) { return \"DIRECT; SOCKS s.example:1080\"; }")
        let explicitChain = resolver.routeChain(for: try explicit.resolveProxyChain(for: URL(string: "http://example.com/")!))
        XCTAssertEqual(explicitChain.routes, [.direct])
        XCTAssertFalse(explicitChain.leadingDirectPromoted)
    }

    /// `42`, `null` and `throw` are CFError 308: an evaluation error, never a route.
    func testNativeNonStringResultsAreEvaluationErrors() throws {
        for body in ["return 42;", "return null;", "throw new Error(\"boom\");"] {
            let evaluator = try makeEvaluator("function FindProxyForURL(url, host) { \(body) }")
            XCTAssertThrowsError(try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!), body) { error in
                guard case PACResolverError.evaluationFailed = error else {
                    return XCTFail("\(body): expected evaluationFailed, got \(error)")
                }
            }
        }
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

    // MARK: - parseRoute / routeChain (the forms the adapter produces)

    func testParseRouteAcceptsOnlyAdapterForms() {
        let evaluator = CFPACEvaluator()
        XCTAssertEqual(evaluator.parseRoute("DIRECT"), .direct)
        XCTAssertEqual(evaluator.parseRoute("PROXY corp.example.com:3128"), .proxy(host: "corp.example.com", port: 3128))
        XCTAssertEqual(evaluator.parseRoute("SOCKS tunnel.example.com:1080"), .socks(host: "tunnel.example.com", port: 1080))
        XCTAssertEqual(evaluator.parseRoute("PROXY p.example.com:1"), .proxy(host: "p.example.com", port: 1))
        XCTAssertEqual(evaluator.parseRoute("PROXY p.example.com:65535"), .proxy(host: "p.example.com", port: 65535))
    }

    /// Chrome-style keywords are not the adapter's forms; mapping them to a
    /// plain proxy or SOCKS would change what the script asked for (#49).
    func testParseRouteRejectsChromeStyleKeywords() {
        let evaluator = CFPACEvaluator()
        for entry in ["HTTP fast.example.com:80", "HTTPS secure.example.com:443",
                      "SOCKS4 tunnel.example.com:1080", "SOCKS5 tunnel.example.com:1080"] {
            XCTAssertNil(evaluator.parseRoute(entry), entry)
        }
    }

    func testParseRouteRejectsBadEndpoints() {
        let evaluator = CFPACEvaluator()
        for entry in ["PROXY p.example.com:0", "PROXY p.example.com:65536", "PROXY p.example.com:99999",
                      "PROXY p.example.com:-1", "PROXY :8080", "PROXY p.example.com", "PROXY p.example.com:",
                      "PROXY", "SOCKS s.example.com:0", "PROXY a:1 extra", "DIRECT now", ""] {
            XCTAssertNil(evaluator.parseRoute(entry), entry)
        }
    }

    func testRouteChainReportsEveryRejectedEntryInOrder() {
        let chain = CFPACEvaluator().routeChain(for: [
            "VENDOR_SPECIFIC something",
            "PROXY",
            "PROXY missing-port-host",
            "HTTPS secure.example.com:443",
            "SOCKS tunnel.example.com:1080",
            "PROXY good.example.com:8080",
            "DIRECT",
        ])
        XCTAssertEqual(chain.routes, [.proxy(host: "good.example.com", port: 8080), .direct])
        XCTAssertEqual(chain.rejected, [
            PACRejectedEntry(type: "VENDOR_SPECIFIC", reason: .unsupported),
            PACRejectedEntry(type: "PROXY", reason: .invalid),
            PACRejectedEntry(type: "PROXY", reason: .invalid),
            PACRejectedEntry(type: "HTTPS", reason: .unsupported),
            PACRejectedEntry(type: "SOCKS", reason: .unsupported),
        ])
        XCTAssertFalse(chain.leadingDirectPromoted)
    }

    /// A PAC answer of thousands of unusable entries, through the real
    /// CFNetwork evaluator, keeps a bounded rejected list and exact counts.
    func testThousandsOfRejectedEntriesStayBounded() throws {
        let evaluator = try makeEvaluator("""
        function FindProxyForURL(url, host) {
            var entries = [];
            for (var i = 0; i < 3000; i++) { entries.push("SOCKS s" + i + ".example:1080"); }
            entries.push("PROXY bad.example:99999");
            return entries.join("; ");
        }
        """)
        let raw = try evaluator.resolveProxyChain(for: URL(string: "http://example.com/")!)
        XCTAssertEqual(raw.count, 3001)
        let chain = CFPACEvaluator().routeChain(for: raw)
        XCTAssertEqual(chain.routes, [])
        XCTAssertEqual(chain.rejected.count, PACRejections.retainedLimit)
        XCTAssertEqual(chain.rejected.total, 3001)
        XCTAssertEqual(chain.rejected.unsupported, 3000)
        XCTAssertTrue(chain.rejected.truncated)
        guard case .noUsableAnswer(.unsupported, let rejected) = PACDecision(chain: chain) else {
            return XCTFail("expected an unsupported no-usable answer")
        }
        XCTAssertEqual(rejected.count, PACRejections.retainedLimit)
    }

    func testRejectedEntryTypeNeverCarriesHostOrURL() {
        let chain = CFPACEvaluator().routeChain(for: ["https://secret.example.com/path?token=x 1", "very-long-directive-keyword-here x"])
        XCTAssertEqual(chain.rejected.map(\.type), ["OTHER", "OTHER"])
        XCTAssertTrue(chain.rejected.allSatisfy { $0.type.count <= 16 })
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
                           "Iteration \(i) (url=\(url)) returned an empty chain; the script always returns an entry.")
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
