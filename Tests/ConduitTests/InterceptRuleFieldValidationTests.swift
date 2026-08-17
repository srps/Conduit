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

    func testIPFieldUsesTheSameValidatorAsTheBoundary() {
        for ip in ["127.44.3.0", "::1", "::::::", "ffff", "999.1.1.1", ""] {
            let rule = DNSInterceptRule(pattern: "*.a.example", interceptIP: ip)
            XCTAssertEqual(
                !IPAddressSyntax.isValid(ip), boundaryRejects(rule),
                "the field and the boundary disagree on '\(ip)'"
            )
        }
    }
}
