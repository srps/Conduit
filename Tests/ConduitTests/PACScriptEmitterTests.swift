// SPDX-License-Identifier: Apache-2.0
// Pins the PACScriptEmitter → routing-decision contract.
//
// The emitter is consumed by (eventually) `LocalPACServer`; whatever script
// it produces gets evaluated in every Chromium / Edge / Firefox / Safari tab
// for every HTTP(S) request on the machine. Bugs here are user-visible and
// silent — the browser just stops using the proxy. The tests below fall into
// three buckets:
//
//   1. **Decision parity.** The emitted `matchesAny` helper must match
//      `NoProxyMatcher.matchesAny` on a representative host/pattern corpus.
//      Runtime evaluation uses `CFPacScriptEvaluator` (the production PAC
//      engine) so any semantic drift between Swift and JS
//      surfaces here, not in the browser.
//
//   2. **Escaping.** Patterns from user config can legally contain anything
//      (the UI doesn't forbid `"` or `\`). The emitted JS must stay parseable
//      regardless.
//
//   3. **Golden bytes.** A single canonical config → exact expected script
//      bytes. Catches whitespace / comment / ordering regressions that
//      neither parity nor escaping tests would notice.
//
// Note: these are pure unit tests. There is no socket, no system proxy, no
// file I/O — just `emitter → evaluator → assert`. The `LocalPACServer`
// integration test lives in its own file.

import Foundation
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACScriptEmitterTests: XCTestCase {

    // MARK: - Script validity

    func testEmittedScriptIsValidJavaScript() throws {
        let script = PACScriptEmitter.script(for: .testFixture())
        XCTAssertNoThrow(
            try CFPacScriptEvaluator(pacScript: script),
            "Emitted PAC must parse as valid JavaScript / PAC"
        )
    }

    func testEmptyConfigEmitsValidScript() throws {
        var config = ProxyConfig.testFixture()
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.profileName = ""
        let script = PACScriptEmitter.script(for: config)
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: script))
    }

    // MARK: - Routing decisions

    func testStrictDefaultHostRoutesThroughLocalProxyWithoutDirectFallback() throws {
        let config = makeConfig(noProxy: [], forceProxy: [])
        let chain = try evaluate(config, host: "example.com")
        XCTAssertEqual(chain, ["PROXY 127.0.0.1:3128"],
                       "Strict mode must not advertise browser-side DIRECT fallback for public hosts.")
    }

    func testNonStrictDefaultHostKeepsDirectFallback() throws {
        var config = makeConfig(noProxy: [], forceProxy: [])
        config.strictMode = false
        let chain = try evaluate(config, host: "example.com")
        XCTAssertEqual(chain, ["PROXY 127.0.0.1:3128", "DIRECT"])
    }

    func testForceProxyHostRoutesThroughLocalProxyWithNoFallback() throws {
        let config = makeConfig(noProxy: [], forceProxy: ["aka.ms"])
        let chain = try evaluate(config, host: "aka.ms")
        XCTAssertEqual(chain, ["PROXY 127.0.0.1:3128"],
                       "forceProxy is 'this host MUST go through the proxy' — no DIRECT fallback.")
    }

    func testNoProxyHostReturnsDirect() throws {
        let config = makeConfig(noProxy: ["localhost"], forceProxy: [])
        let chain = try evaluate(config, host: "localhost")
        XCTAssertEqual(chain, ["DIRECT"])
    }

    func testDirectModeReturnsDirectForEveryHost() throws {
        let config = makeConfig(noProxy: ["localhost"], forceProxy: ["aka.ms"])
        let script = PACScriptEmitter.script(for: config, directRoutingAllowed: true)
        let evaluator = try CFPacScriptEvaluator(pacScript: script)

        XCTAssertTrue(script.contains("// Profile: test-fixture"))
        XCTAssertTrue(script.contains("// Proxy:   127.0.0.1:3128"))
        XCTAssertEqual(try evaluator.resolveProxyChain(for: Self.url(for: "example.com")), ["DIRECT"])
        XCTAssertEqual(try evaluator.resolveProxyChain(for: Self.url(for: "aka.ms")), ["DIRECT"])
        XCTAssertEqual(try evaluator.resolveProxyChain(for: Self.url(for: "localhost")), ["DIRECT"])
    }

    func testDefaultLoopbackBypassPatternsReturnDirect() throws {
        var config = ProxyConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 3128

        XCTAssertEqual(try evaluate(config, host: "localhost"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "127.0.0.1"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "127.0.0.42"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "::1"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "[::1]"), ["DIRECT"])
    }

    func testForceProxyOverridesNoProxyForSameHost() throws {
        // Matches NoProxyMatcher's `shouldBypass(forceProxy:)` precedence:
        // a host that matches BOTH lists goes through the proxy.
        let config = makeConfig(noProxy: ["example.com"], forceProxy: ["example.com"])
        let chain = try evaluate(config, host: "example.com")
        XCTAssertEqual(chain, ["PROXY 127.0.0.1:3128"])
    }

    // MARK: - Pattern semantics (line-for-line parity with NoProxyMatcher)

    func testExactPatternMatch() throws {
        let config = makeConfig(noProxy: ["example.com"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "www.example.com"),
                       ["PROXY 127.0.0.1:3128"],
                       "Plain exact patterns do NOT match subdomains.")
    }

    func testStarDotPrefixMatchesSubdomainsAndApex() throws {
        // NoProxyMatcher-specific quirk: `*.example.com` matches both
        // `sub.example.com` AND the apex `example.com`. If we ever mapped
        // this to raw `shExpMatch("*.example.com")`, the apex case would
        // regress silently.
        let config = makeConfig(noProxy: ["*.example.com"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "sub.example.com"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "a.b.example.com"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"],
                       "*.example.com must also match the apex — parity with NoProxyMatcher.")
        XCTAssertEqual(try evaluate(config, host: "notexample.com"),
                       ["PROXY 127.0.0.1:3128"])
    }

    func testLeadingDotPatternMatchesSubdomainsAndApex() throws {
        let config = makeConfig(noProxy: [".example.com"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "sub.example.com"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"])
    }

    func testTrailingDotStarMatchesIPPrefix() throws {
        let config = makeConfig(noProxy: ["10.*"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "10.0.0.1"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "10.255.12.9"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "192.168.1.1"),
                       ["PROXY 127.0.0.1:3128"])
    }

    func testTrailingStarMatchesArbitraryPrefix() throws {
        let config = makeConfig(noProxy: ["intranet*"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "intranet"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "intranet-dev"), ["DIRECT"])
    }

    func testMatchIsCaseInsensitiveOnHost() throws {
        let config = makeConfig(noProxy: ["example.com"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "EXAMPLE.COM"), ["DIRECT"])
    }

    func testMatchIsCaseInsensitiveOnPattern() throws {
        let config = makeConfig(noProxy: ["EXAMPLE.COM"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"])
    }

    func testWhitespaceInPatternIsTrimmed() throws {
        let config = makeConfig(noProxy: ["  example.com  "], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"])
    }

    func testEmptyPatternsAreIgnored() throws {
        // "" and whitespace-only entries must not match any host. Important
        // because the UI sometimes leaves empty entries behind when a user
        // clears a row.
        let config = makeConfig(noProxy: ["", "   ", "example.com"], forceProxy: [])
        XCTAssertEqual(try evaluate(config, host: "example.com"), ["DIRECT"])
        XCTAssertEqual(try evaluate(config, host: "random.example.org"),
                       ["PROXY 127.0.0.1:3128"])
    }

    // MARK: - Parity against NoProxyMatcher over a corpus

    func testParityWithNoProxyMatcher() throws {
        // Runs both implementations over the same host/pattern combinations
        // and asserts decisions agree. If this ever fails, the two matchers
        // have drifted and one of them has a bug.
        let patterns = [
            "localhost",
            "127.0.0.1",
            "127.0.0.*",
            "::1",
            "[::1]",
            "*.local",
            "10.*",
            "192.168.*",
            "172.16.*",
            "*.example.com",
            ".example.org",
            "EXAMPLE.NET",
            "intranet*",
            "corp.example.com",
        ]
        let hosts = [
            "localhost",
            "127.0.0.1",
            "127.0.0.42",
            "::1",
            "[::1]",
            "myhost.local",
            "deep.sub.local",
            "local",
            "10.0.0.1",
            "10.255.255.255",
            "11.0.0.1",
            "192.168.1.5",
            "172.16.10.10",
            "example.com",
            "www.example.com",
            "api.staging.example.com",
            "example.org",
            "apex.example.org",
            "example.net",
            "intranet",
            "intranet-dev",
            "dev.intranet",
            "corp.example.com",
            "evil.corp.example.com",
            "public.example.io",
            "EXAMPLE.NET",
        ]
        let config = makeConfig(noProxy: patterns, forceProxy: [])
        let script = PACScriptEmitter.script(for: config)
        let evaluator = try CFPacScriptEvaluator(pacScript: script)

        for host in hosts {
            let swiftBypass = NoProxyMatcher.matchesAny(host: host.lowercased(), patterns: patterns)
            let jsChain = try evaluator.resolveProxyChain(for: Self.url(for: host))
            let jsBypass = (jsChain == ["DIRECT"])
            XCTAssertEqual(swiftBypass, jsBypass,
                           "Parity mismatch for host=\(host): Swift says bypass=\(swiftBypass), JS chain=\(jsChain)")
        }
    }

    // MARK: - Escaping (patterns can legally contain anything)

    func testDoubleQuoteInPatternDoesNotBreakScript() throws {
        // `example".com` is not a valid DNS label, but the UI won't stop the
        // user from typing it, and the emitter must not produce invalid JS.
        let config = makeConfig(noProxy: ["example\".com"], forceProxy: [])
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: PACScriptEmitter.script(for: config)),
                         "Double-quote in pattern must be escaped, not passed through verbatim.")
    }

    func testBackslashInPatternDoesNotBreakScript() throws {
        let config = makeConfig(noProxy: ["back\\slash"], forceProxy: [])
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: PACScriptEmitter.script(for: config)),
                         "Backslash in pattern must be escaped.")
    }

    func testNewlineInPatternDoesNotBreakScript() throws {
        let config = makeConfig(noProxy: ["line1\nline2"], forceProxy: [])
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: PACScriptEmitter.script(for: config)),
                         "Literal \\n in pattern must become the escape sequence, not a raw newline.")
    }

    func testControlCharacterInPatternIsEscaped() throws {
        let config = makeConfig(noProxy: ["bell\u{0007}ring"], forceProxy: [])
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: PACScriptEmitter.script(for: config)))
    }

    func testUnicodeInPatternPassesThrough() throws {
        // JS source supports UTF-8 directly; non-ASCII in a string literal is
        // fine and doesn't need \u escapes. Include a CJK and a combining mark.
        let config = makeConfig(noProxy: ["日本.example", "café.local"], forceProxy: [])
        let script = PACScriptEmitter.script(for: config)
        XCTAssertNoThrow(try CFPacScriptEvaluator(pacScript: script))
        // Spot-check that the unicode appears literally (not as \uXXXX) — so
        // an IT admin reading the served PAC sees familiar strings.
        XCTAssertTrue(script.contains("日本.example"))
        XCTAssertTrue(script.contains("café.local"))
    }

    // MARK: - Proxy directive

    func testCustomLocalHostAndPortAppearInDirective() throws {
        var config = makeConfig(noProxy: [], forceProxy: [])
        config.localHost = "10.0.0.42"
        config.localPort = 9000
        let chain = try evaluate(config, host: "example.com")
        XCTAssertEqual(chain, ["PROXY 10.0.0.42:9000"])
    }

    func testJSStringLiteralEscapesControlCharacters() {
        // Direct unit on the escaper helper — covers the `\u00XX` branch
        // that is hard to reach through CFPacScriptEvaluator alone.
        XCTAssertEqual(PACScriptEmitter.jsStringLiteral("a\u{0001}b"), "\"a\\u0001b\"")
        XCTAssertEqual(PACScriptEmitter.jsStringLiteral("tab\there"), "\"tab\\there\"")
        XCTAssertEqual(PACScriptEmitter.jsStringLiteral("say \"hi\""), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(PACScriptEmitter.jsStringLiteral("back\\slash"), "\"back\\\\slash\"")
    }

    // MARK: - Golden output

    func testGoldenOutputMatchesExpectedScript() {
        // Pins the exact bytes the emitter produces for a canonical config.
        // If this diffs, the header / pattern-array formatting has changed
        // and the change is worth a deliberate review (other byte-sensitive
        // consumers, e.g. PAC caches keyed on ETag, might break).
        var config = ProxyConfig.testFixture()
        config.profileName = "Canonical"
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        config.noProxyHosts = ["localhost", "*.local"]
        config.forceProxyHosts = ["aka.ms"]

        let expected = """
        // Generated by Conduit. DO NOT EDIT — regenerated on every
        // config reload. Served by LocalPACServer at /proxy.pac.
        // Profile: Canonical
        // Proxy:   127.0.0.1:3128
        // forceProxyHosts: 1, noProxyHosts: 2

        function FindProxyForURL(url, host) {
          host = (host || "").toLowerCase();

          var forceProxy = ["aka.ms"];
          var noProxy = [
            "localhost",
            "*.local"
          ];

          if (matchesAny(host, forceProxy)) {
            return "PROXY 127.0.0.1:3128";
          }
          if (matchesAny(host, noProxy)) {
            return "DIRECT";
          }
          return "PROXY 127.0.0.1:3128";
        }

        // Mirrors Sources/ProxyKernel/Proxy/NoProxyMatcher.swift matchesAny.
        // Patterns are pre-normalized (trimmed + lowercased) at emit time; this
        // helper just runs the five match cases against a lowercased host.
        function matchesAny(host, patterns) {
          for (var i = 0; i < patterns.length; i++) {
            var pat = patterns[i];
            if (pat.length === 0) continue;
            if (pat === host) return true;
            if (pat.length >= 2 && pat.substring(0, 2) === "*.") {
              var suffix = pat.substring(1);
              if (host.length >= suffix.length &&
                  host.substring(host.length - suffix.length) === suffix) return true;
              if (host === pat.substring(2)) return true;
            }
            if (pat.charAt(0) === ".") {
              if (host.length >= pat.length &&
                  host.substring(host.length - pat.length) === pat) return true;
              if (host === pat.substring(1)) return true;
            }
            if (pat.length >= 2 && pat.substring(pat.length - 2) === ".*") {
              var prefix = pat.substring(0, pat.length - 1);
              if (host.substring(0, prefix.length) === prefix) return true;
            }
            if (pat.length >= 1 && pat.charAt(pat.length - 1) === "*" &&
                !(pat.length >= 2 && pat.substring(pat.length - 2) === ".*")) {
              var prefix2 = pat.substring(0, pat.length - 1);
              if (host.substring(0, prefix2.length) === prefix2) return true;
            }
          }
          return false;
        }

        """

        XCTAssertEqual(PACScriptEmitter.script(for: config), expected)
    }

    // MARK: - Helpers

    private func makeConfig(noProxy: [String], forceProxy: [String]) -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        config.noProxyHosts = noProxy
        config.forceProxyHosts = forceProxy
        return config
    }

    /// Emit `config`'s PAC, evaluate it against `host`, return the raw
    /// directive chain. `url` scheme is HTTP — the emitter is
    /// scheme-agnostic so the choice doesn't affect decisions.
    private func evaluate(_ config: ProxyConfig, host: String) throws -> [String] {
        let script = PACScriptEmitter.script(for: config)
        let evaluator = try CFPacScriptEvaluator(pacScript: script)
        return try evaluator.resolveProxyChain(for: Self.url(for: host))
    }

    private static func url(for host: String) -> URL {
        if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return URL(string: "http://[\(host)]/")!
        }
        return URL(string: "http://\(host)/")!
    }
}
