// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import Conduit
@testable import ConduitShared

/// The Settings affordance for intercept rules must agree with the config
/// boundary — otherwise a user fixes the field until the red border clears and
/// still gets "Configuration problem: …" on save, which is worse than no
/// affordance at all.
@MainActor
final class InterceptRuleFieldValidationTests: XCTestCase {

    private func boundaryRejects(_ rule: DNSInterceptRule) -> Bool {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsInterceptRules = [rule]
        return config.validate().contains {
            switch $0 {
            case .invalidInterceptPattern, .invalidInterceptIP: return true
            default: return false
            }
        }
    }

    func testTheFieldAgreesWithTheConfigBoundary() {
        for pattern in [
            "*.cursor.sh", "example.com", "*.foo_bar.example", "_dmarc.example.com",
            "*.foo bar.example", "*.evil/path", "*", "example.com.", "-bad.example",
            // `""` is the case the list used to omit, and omitting it is what
            // let the two sides diverge: the field short-circuits an empty
            // pattern, the boundary rejected it. `*` stays right next to it —
            // both still reject that one, and the pair is the distinction.
            "",
        ] {
            let rule = DNSInterceptRule(pattern: pattern)
            let fieldRejects = SettingsView.interceptPatternProblem(rule) != nil
            XCTAssertEqual(
                fieldRejects, boundaryRejects(rule),
                "the field and the boundary disagree on '\(pattern)'"
            )
        }
    }

    /// The wildcard is the spelling users are told to type, so it must not read
    /// as an error. The field validates the derived resolver domain, same as
    /// the boundary.
    func testWildcardPatternsAreNotFlagged() {
        XCTAssertNil(SettingsView.interceptPatternProblem(DNSInterceptRule(pattern: "*.cursor.sh")))
    }

    /// A row the user has only just added is not yet a mistake.
    func testEmptyPatternIsNotFlagged() {
        XCTAssertNil(SettingsView.interceptPatternProblem(DNSInterceptRule(pattern: "")))
    }

    /// The point of a per-reason error type: the row can say which character to
    /// change rather than "invalid".
    func testTheReasonIsSpecificEnoughToShow() {
        let problem = SettingsView.interceptPatternProblem(
            DNSInterceptRule(pattern: "*.foo bar.example")
        )
        XCTAssertEqual(problem, .invalidCharacter(" ", label: "foo bar"))
        XCTAssertTrue(problem!.localizedDescription.contains("foo bar"))
    }

    /// `ProxyConfig.validate()` checks every rule whether or not the feature
    /// is on, so the editor has to be on screen whenever a rule exists —
    /// otherwise the save banner names a row the user cannot see.
    func testTheRuleEditorIsShownWheneverTheBoundaryCanComplainAboutARule() {
        var config = GenericDefaults.shared.makeConfig()
        config.transparentProxyEnabled = false
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.foo bar.example")]
        XCTAssertTrue(boundaryRejects(config.dnsInterceptRules[0]))
        XCTAssertTrue(SettingsView.interceptRulesAreShown(in: config))

        config.dnsInterceptRules = []
        XCTAssertFalse(SettingsView.interceptRulesAreShown(in: config))
        config.transparentProxyEnabled = true
        XCTAssertTrue(SettingsView.interceptRulesAreShown(in: config), "the Add menu lives here")
    }

    /// The intercept-IP field flags exactly when the boundary does, including
    /// staying silent while the feature (and the field) is off.
    func testTheTransparentProxyIPFieldAgreesWithTheConfigBoundary() {
        for enabled in [true, false] {
            for ip in ["127.44.3.0", "::1", "999.1.1.1", ""] {
                var config = GenericDefaults.shared.makeConfig()
                config.dnsInterceptRules = []
                config.transparentProxyEnabled = enabled
                config.transparentProxyIP = ip
                let boundary = config.validate().contains {
                    if case .invalidTransparentProxyIP = $0 { return true }
                    return false
                }
                XCTAssertEqual(
                    SettingsView.transparentProxyIPProblem(config) != nil, boundary,
                    "field and boundary disagree on '\(ip)' enabled=\(enabled)"
                )
            }
        }
    }

    func testIPFieldUsesTheSameValidatorAsTheBoundary() {
        for ip in ["127.44.3.0", "::1", "::::::", "ffff", "999.1.1.1", ""] {
            let rule = DNSInterceptRule(pattern: "*.a.example", interceptIP: ip)
            XCTAssertEqual(
                !IPAddressSyntax.isIPv4(ip), boundaryRejects(rule),
                "the field and the boundary disagree on '\(ip)'"
            )
        }
    }

    /// `::1` used to be asserted *valid* here, which certified a rule that
    /// blackholes its domain: `DNSWireFormat.synthesizeDirectResponse` answers
    /// AAAA with NODATA and builds A records from four octets, so an IPv6
    /// target returns nil and the forwarder replies SERVFAIL. The field has to
    /// be the place that says so, since it is where the address is typed.
    func testAnIPv6TargetIsRejectedByTheField() {
        for ip in ["::1", "fe80::1", "2001:db8::1"] {
            XCTAssertFalse(
                IPAddressSyntax.isIPv4(ip),
                "'\(ip)' is a well-formed address but not one this can answer with"
            )
        }
    }
}
