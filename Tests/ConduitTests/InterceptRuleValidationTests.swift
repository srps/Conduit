// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

/// Issue #68: an intercept rule whose pattern derives to an unusable domain
/// used to be accepted into the config, and only `applyInterceptFiles` — which
/// validates the whole derived set before writing any of it — noticed. One bad
/// rule therefore silently disabled intercept files for **every** rule. The
/// fail-fast down there is correct; the defect was that the bad pattern got
/// that far.
final class InterceptRuleValidationTests: XCTestCase {

    private func makeConfig() -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsInterceptRules = []
        return config
    }

    private func interceptErrors(_ config: ProxyConfig) -> [ConfigValidationError] {
        config.validate().filter {
            switch $0 {
            case .invalidInterceptPattern, .invalidInterceptIP: return true
            default: return false
            }
        }
    }

    // MARK: - The derived domain, not the pattern

    func testValidRulesProduceNoErrors() {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
            DNSInterceptRule(pattern: "example.com"),
            DNSInterceptRule(pattern: "*.foo_bar.example"),
        ]
        XCTAssertTrue(interceptErrors(config).isEmpty)
    }

    /// The wildcard is notation; it never reaches the filesystem. Validating
    /// the raw pattern against a grammar with no wildcard in it would reject
    /// every working rule this product ships.
    func testWildcardIsStrippedBeforeValidating() {
        XCTAssertEqual(DNSInterceptRule(pattern: "*.cursor.sh").resolverDomain, "cursor.sh")
        XCTAssertEqual(DNSInterceptRule(pattern: "*cursor.sh").resolverDomain, "cursor.sh")
        XCTAssertEqual(DNSInterceptRule(pattern: "cursor.sh").resolverDomain, "cursor.sh")
    }

    func testInvalidPatternIsRejectedWithItsIndexAndReason() {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
            DNSInterceptRule(pattern: "*.foo bar.example"),
        ]
        let errors = interceptErrors(config)
        XCTAssertEqual(errors.count, 1)
        guard case .invalidInterceptPattern(let index, let pattern, let reason) = errors[0] else {
            return XCTFail("expected invalidInterceptPattern, got \(errors[0])")
        }
        XCTAssertEqual(index, 1, "the message has to point at a row the user can find")
        XCTAssertEqual(pattern, "*.foo bar.example")
        XCTAssertEqual(reason, .invalidCharacter(" ", label: "foo bar"))
    }

    /// A bare `*` derives to the empty string, which would name the
    /// `/etc/resolver` directory itself.
    func testBareWildcardIsRejected() {
        var config = makeConfig()
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*")]
        guard case .invalidInterceptPattern(_, _, let reason)? = interceptErrors(config).first else {
            return XCTFail("a bare wildcard must not be accepted")
        }
        XCTAssertEqual(reason, .empty)
    }

    // MARK: - Disabled rules

    /// The cleanup path derives its set from every rule including disabled ones
    /// (`forCleanup: true`), because by teardown time the enable flags have
    /// typically already flipped false. So an invalid *disabled* rule can still
    /// break a teardown, and skipping it here would leave exactly that hole.
    func testDisabledRulesAreValidatedToo() {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.evil/path.example", enabled: false)
        ]
        XCTAssertEqual(interceptErrors(config).count, 1)
    }

    // MARK: - Intercept IP

    /// The only IP check this package had was `^[0-9a-fA-F:]+$`, which accepts
    /// all of these. `inet_pton` does not.
    func testMalformedInterceptIPIsRejected() {
        for bad in ["::::::", "ffff", ":", "999.1.1.1", "127.0.0", "not-an-ip", ""] {
            var config = makeConfig()
            config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.a.example", interceptIP: bad)]
            XCTAssertEqual(
                interceptErrors(config).count, 1,
                "'\(bad)' is not an IP address"
            )
        }
    }

    func testWellFormedInterceptIPsAreAccepted() {
        for good in ["127.44.3.0", "10.0.0.1", "::1", "fe80::1", "2001:db8::1"] {
            var config = makeConfig()
            config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.a.example", interceptIP: good)]
            XCTAssertTrue(interceptErrors(config).isEmpty, "'\(good)' is an IP address")
        }
    }

    // MARK: - The privileged path

    /// The end the issue is about: with one bad rule the whole set used to be
    /// refused at `applyInterceptFiles`, so *no* file was written. Now the
    /// config never carries one, and a valid config writes every rule.
    func testAValidConfigWritesEveryInterceptFile() throws {
        let recording = RecordingInterceptPrivilegeClient()
        let manager = DNSManager(privilegeClient: recording)
        var config = makeConfig()
        config.transparentProxyEnabled = true
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
            DNSInterceptRule(pattern: "*.foo_bar.example"),
            DNSInterceptRule(pattern: "plain.example"),
        ]
        XCTAssertTrue(interceptErrors(config).isEmpty)

        try manager.applyInterceptFiles(config: config, logger: nil)

        XCTAssertEqual(
            recording.applied(),
            ["cursor.sh", "foo_bar.example", "plain.example"]
        )
    }

    /// And the shape that used to get through: a config carrying one unusable
    /// rule is refused by `validate()`, so it never reaches the privileged
    /// path at all.
    func testAnInvalidRuleIsCaughtBeforeThePrivilegedPath() {
        let recording = RecordingInterceptPrivilegeClient()
        let manager = DNSManager(privilegeClient: recording)
        var config = makeConfig()
        config.transparentProxyEnabled = true
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
            DNSInterceptRule(pattern: "*.foo bar.example"),
        ]

        XCTAssertFalse(
            interceptErrors(config).isEmpty,
            "the config boundary is what has to reject this"
        )

        // Demonstrating what the boundary is protecting against: run it anyway
        // and the good rule is lost along with the bad one.
        XCTAssertThrowsError(try manager.applyInterceptFiles(config: config, logger: nil))
        XCTAssertEqual(
            recording.applied(), [],
            "one bad pattern still costs every other rule down here — which is why "
                + "it must not get here"
        )
    }
}

// MARK: - Test Double

private final class RecordingInterceptPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var executed: [(PrivilegedOperation, [String])] = []

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { executed.append((operation, values)) }
    }

    func applied() -> [String] {
        lock.withLock { executed }
            .filter { $0.0 == .applyDNS }
            .compactMap(\.1.first)
    }
}
