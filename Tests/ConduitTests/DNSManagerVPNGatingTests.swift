// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Test Double

private struct FakePrivilegeFailure: Error, LocalizedError {
    let domain: String
    var errorDescription: String? { "helper refused \(domain)" }
}

private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []
    private var _failingDomains: Set<String> = []

    /// Domains whose privileged operation fails, so a test can put a failure in
    /// the middle of a batch and see what the rest of it did.
    var failingDomains: Set<String> {
        get { lock.withLock { _failingDomains } }
        set { lock.withLock { _failingDomains = newValue } }
    }

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        let domain = values.first
        try lock.withLock {
            _commands.append((operation, values))
            if let domain, _failingDomains.contains(domain) {
                throw FakePrivilegeFailure(domain: domain)
            }
        }
    }

    func commands(matching operation: PrivilegedOperation) -> [[String]] {
        executedCommands.filter { $0.0 == operation }.map(\.1)
    }

    func reset() {
        lock.withLock { _commands.removeAll() }
    }
}

// MARK: - Tests

/// Split-DNS entry files (`/etc/resolver/<domain>` → corporate DNS servers)
/// must exist only while the VPN that makes those servers reachable is up.
/// The override matches *everything* under the domain — including the VPN
/// gateway's own public hostname (e.g. `vpn-gw.corp.example` under a
/// `corp.example` entry) — so leaving it in place while disconnected sends the
/// gateway lookup to unreachable tunnel-internal servers and deadlocks
/// reconnection until the file is removed by hand (observed:
/// the VPN client "could not locate VPN server" on a hotspot until
/// Conduit was restarted).
final class DNSManagerVPNGatingTests: XCTestCase {

    private var recording: RecordingPrivilegeClient!
    private var manager: DNSManager!

    override func setUp() {
        super.setUp()
        recording = RecordingPrivilegeClient()
        manager = DNSManager(privilegeClient: recording)
    }

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [
            DomainDNSEntry(domain: "corp.example", servers: ["10.1.1.1", "10.2.2.2"]),
            DomainDNSEntry(domain: "internal.example", servers: ["10.1.1.1"]),
        ]
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.intercepted.example")
        ]
        config.dnsForwarderEnabled = true
        config.transparentProxyEnabled = true
        config.dnsForwarderPort = 5053
        return config
    }

    private func appliedDomains() -> Set<String> {
        Set(recording.commands(matching: .applyDNS).compactMap(\.first))
    }

    private func removedDomains() -> Set<String> {
        Set(recording.commands(matching: .removeDNS).compactMap(\.first))
    }

    /// `apply` runs at proxy start, before the DNS forwarder binds — and in
    /// the GUI host, whether or not it ever will. It must therefore write only
    /// entry files. Intercept files belong to `applyInterceptFiles`, which the
    /// hosts call once both listeners are up.
    func testApplyWritesEntryFilesButNeverInterceptFiles() throws {
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertEqual(
            appliedDomains(),
            ["corp.example", "internal.example"],
            "apply owns entry files only; it cannot promise a forwarder is listening"
        )
    }

    func testApplyWithVPNDisconnectedWritesNothing() throws {
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: false)
        XCTAssertEqual(
            appliedDomains(),
            [],
            "VPN down defers the entry files, and apply never wrote the intercepts"
        )
    }

    /// The regression that stranded `*.cursor.sh` at a dead `127.0.0.1:5053`:
    /// `dnsForwarderEnabled` persists as `true` across a quit (only `stopDNS`
    /// clears it), so a config that merely *remembers* DNS was on must not
    /// cause `apply` to install intercept resolver files at the next launch.
    func testApplyDoesNotWriteInterceptFilesForARememberedForwarder() throws {
        var config = makeConfig()
        config.dnsEntries = []
        config.dnsForwarderEnabled = true   // stale record of the last session
        config.transparentProxyEnabled = true

        try manager.apply(config: config, logger: nil, vpnConnected: true)

        XCTAssertTrue(
            appliedDomains().isEmpty,
            "a persisted enable flag is not evidence that anything is listening on 127.0.0.1:\(config.dnsForwarderPort)"
        )
    }

    func testReconcileWithVPNDisconnectedRemovesEntryFilesAndKeepsInterceptsForTheDNSPath() throws {
        // Same config on both sides: the only delta is the VPN going down,
        // which must strip the entry files. The intercept domain is neither
        // removed (it isn't stale — the rule still exists) nor written
        // (reconcile doesn't own those files); the caller's
        // `refreshInterceptFiles` decides its fate against the live bindings.
        let config = makeConfig()
        try manager.reconcile(old: config, new: config, logger: nil, vpnConnected: false)
        XCTAssertEqual(removedDomains(), ["corp.example", "internal.example"])
        XCTAssertEqual(appliedDomains(), [])
    }

    /// A rule the user turned off must still lose its resolver file, or the
    /// domain keeps resolving to an intercept IP nobody serves.
    func testReconcileRemovesDisabledInterceptRule() throws {
        let old = makeConfig()
        var new = makeConfig()
        new.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercepted.example", enabled: false)]
        try manager.reconcile(old: old, new: new, logger: nil, vpnConnected: true)
        XCTAssertTrue(removedDomains().contains("intercepted.example"))
    }

    /// Turning the transparent proxy off leaves nothing listening on the
    /// intercept IP, so its resolver files must go with it.
    func testReconcileRemovesInterceptFilesWhenTransparentProxyDisabled() throws {
        let old = makeConfig()
        var new = makeConfig()
        new.transparentProxyEnabled = false
        try manager.reconcile(old: old, new: new, logger: nil, vpnConnected: true)
        XCTAssertTrue(removedDomains().contains("intercepted.example"))
    }

    func testApplyInterceptFilesWritesTheForwarderAddress() throws {
        try manager.applyInterceptFiles(config: makeConfig(), logger: nil)
        XCTAssertEqual(appliedDomains(), ["intercepted.example"])
        let command = recording.commands(matching: .applyDNS).first { $0.first == "intercepted.example" }
        XCTAssertEqual(Array(command?.dropFirst() ?? []), ["127.0.0.1", "5053"])
    }

    /// Cleanup must not consult the enable flags: by the time it runs,
    /// `stopDNS` has already persisted `dnsForwarderEnabled = false`.
    ///
    /// This is also the start-time sweep that repairs a `SIGKILL`ed instance
    /// (an installer replacing the app), which never ran termination cleanup
    /// and so left `/etc/resolver/cursor.sh` pointing at a dead port. The
    /// sweep runs before the forwarder binds, when every flag reads "off", so
    /// gating it on them would make it a no-op precisely when it is needed.
    func testClearInterceptFilesIgnoresEnableFlags() throws {
        var config = makeConfig()
        config.dnsForwarderEnabled = false
        config.transparentProxyEnabled = false
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercepted.example", enabled: false)]
        try manager.clearInterceptFiles(config: config, logger: nil)
        XCTAssertEqual(removedDomains(), ["intercepted.example"])
    }

    /// The sweep must not take the entry files with it: the proxy is starting
    /// and, if the VPN is up, those are exactly what `apply` just wrote.
    func testClearInterceptFilesLeavesEntryFilesAlone() throws {
        try manager.clearInterceptFiles(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["intercepted.example"])
    }

    func testApplyEntryFilesWritesOnlyEnabledEntries() throws {
        var config = makeConfig()
        config.dnsEntries.append(DomainDNSEntry(domain: "disabled.example", servers: ["10.3.3.3"], enabled: false))
        try manager.applyEntryFiles(config: config, logger: nil)
        XCTAssertEqual(appliedDomains(), ["corp.example", "internal.example"])
        let servers = recording.commands(matching: .applyDNS).first { $0.first == "corp.example" }
        XCTAssertEqual(servers?.dropFirst().first, "10.1.1.1,10.2.2.2")
    }

    func testClearEntryFilesRemovesOnlyEntryFiles() throws {
        try manager.clearEntryFiles(config: makeConfig(), logger: nil)
        XCTAssertEqual(removedDomains(), ["corp.example", "internal.example"])
        XCTAssertTrue(
            recording.commands(matching: .applyDNS).isEmpty,
            "VPN-down cleanup never rewrites anything"
        )
    }

    func testClearStillRemovesEverythingRegardlessOfVPN() throws {
        try manager.clear(config: makeConfig(), logger: nil)
        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example", "intercepted.example"],
            "Full teardown (proxy stop/quit) is not VPN-gated"
        )
    }

    // MARK: - Stranded entry files

    /// A start with the VPN down must *repair* stranded entry files, not just
    /// defer writing new ones.
    ///
    /// Entry files outlive the process that wrote them — a `SIGKILL`, an
    /// installer swapping the app, or a run that ended without a clean stop all
    /// leave them on disk with no in-memory record. Nothing else sweeps them:
    /// the VPN transition handler only fires on a state *flip*, so files
    /// stranded while the VPN is already down stay stranded, sending their
    /// whole domain to servers only the tunnel can reach and blackholing those
    /// lookups for every process on the machine.
    func testApplyWithVPNDisconnectedSweepsStrandedEntryFiles() throws {
        let resolverDir = try makeTemporaryResolverDirectory()
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: resolverDir.path)

        // A previous run left one entry file behind.
        try "nameserver 10.1.1.1".write(
            to: resolverDir.appendingPathComponent("corp.example"),
            atomically: true,
            encoding: .utf8
        )

        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: false)

        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example"],
            "a start with the VPN down must sweep entry files rather than strand them"
        )
        XCTAssertTrue(appliedDomains().isEmpty, "nothing may be written while the tunnel is down")
    }

    /// The clean case must stay quiet: no stranded files means no privileged
    /// helper round-trips on every start.
    func testApplyWithVPNDisconnectedSweepsNothingWhenDiskIsClean() throws {
        let resolverDir = try makeTemporaryResolverDirectory()
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: resolverDir.path)

        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: false)

        XCTAssertTrue(removedDomains().isEmpty, "no files on disk, nothing to sweep")
        XCTAssertTrue(appliedDomains().isEmpty)
    }

    /// `isApplied` is the gate the GUI host puts in front of `apply`, so it has
    /// to answer for everything `apply` does. It reported "already applied"
    /// whenever the VPN was down — there is nothing to *write* then — which
    /// skipped the stranded-file sweep in the one host and the one state the
    /// sweep exists for. Caught in review on #54.
    func testIsAppliedReportsWorkPendingWhenEntryFilesAreStranded() throws {
        let resolverDir = try makeTemporaryResolverDirectory()
        let manager = DNSManager(privilegeClient: recording, resolverDirectory: resolverDir.path)

        XCTAssertTrue(
            manager.isApplied(config: makeConfig(), vpnConnected: false),
            "VPN down with a clean disk: nothing to write and nothing to sweep"
        )

        try "nameserver 10.1.1.1".write(
            to: resolverDir.appendingPathComponent("corp.example"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertFalse(
            manager.isApplied(config: makeConfig(), vpnConnected: false),
            "a stranded entry file is pending work, so the caller must not skip apply"
        )
    }

    // MARK: - A failed removal must not abandon the rest

    /// The sharp case. `clearEntryFiles` runs on VPN-down and nothing re-runs
    /// it, so a first failure that cancelled the rest would leave every
    /// remaining domain pointed at tunnel-internal servers that are now
    /// unreachable — blackholing them for every process on the machine, and
    /// deadlocking reconnection when the gateway's own hostname falls under one
    /// of them.
    func testClearEntryFilesRemovesTheRestAfterAFailure() {
        recording.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.clearEntryFiles(config: makeConfig(), logger: nil))
        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example"],
            "the failure is reported, but every later domain is still attempted"
        )
    }

    func testAFailedRemovalNamesTheDomainsLeftBehind() {
        recording.failingDomains = ["corp.example", "internal.example"]
        XCTAssertThrowsError(try manager.clearEntryFiles(config: makeConfig(), logger: nil)) { error in
            guard let removal = error as? DNSRemovalError else {
                return XCTFail("expected DNSRemovalError, got \(error)")
            }
            XCTAssertEqual(removal.domains, ["corp.example", "internal.example"])
            XCTAssertTrue(
                removal.errorDescription?.contains("corp.example") == true,
                "an operator reading the log needs the domain names, not a count"
            )
        }
    }

    /// A failure among the entry files must not take the intercept files with
    /// it: those point at a forwarder this teardown is stopping.
    func testClearStillRemovesInterceptFilesAfterAnEntryFailure() {
        recording.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.clear(config: makeConfig(), logger: nil))
        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example", "intercepted.example"]
        )
    }

    func testClearInterceptFilesRemovesTheRestAfterAFailure() {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.a.example"),
            DNSInterceptRule(pattern: "*.b.example"),
        ]
        recording.failingDomains = ["a.example"]
        XCTAssertThrowsError(try manager.clearInterceptFiles(config: config, logger: nil))
        XCTAssertEqual(removedDomains(), ["a.example", "b.example"])
    }

    func testReconcileStaleSweepRemovesTheRestAfterAFailure() {
        let old = makeConfig()
        var new = makeConfig()
        new.dnsEntries = []
        new.dnsInterceptRules = []
        recording.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.reconcile(old: old, new: new, logger: nil, vpnConnected: true))
        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example", "intercepted.example"]
        )
    }

    /// Validating the whole batch before removing any of it made one unusable
    /// name abort every removal — worse than the interleaved loop it replaced,
    /// and the exact failure `removeAll` exists to prevent.
    ///
    /// The bad name needs no typo to arrive. Intercept patterns are never
    /// validated when the config is parsed, and `getInterceptDomains` only
    /// strips a leading `*.`, so `*.foo_bar.example` yields `foo_bar.example`,
    /// which `domainRegex` rejects for the underscore.
    func testAnUnusableDomainDoesNotCancelTheOtherRemovals() {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.foo_bar.example"),
            DNSInterceptRule(pattern: "*.intercepted.example"),
        ]
        XCTAssertThrowsError(try manager.clear(config: config, logger: nil)) { error in
            guard let removal = error as? DNSRemovalError else {
                return XCTFail("expected DNSRemovalError, got \(error)")
            }
            XCTAssertEqual(removal.domains, ["foo_bar.example"])
        }
        XCTAssertEqual(
            removedDomains(),
            ["corp.example", "internal.example", "intercepted.example"],
            "one rejected name must not strand every other domain"
        )
    }

    /// A partly failed sweep must not also cancel the migration. The sets are
    /// disjoint — `stale` is `old - new` — so a file we could not remove is
    /// never one the apply is about to write, and skipping the apply leaves the
    /// machine half-migrated on top of the residue.
    func testReconcileStillAppliesTheNewConfigAfterAFailedSweep() {
        var old = makeConfig()
        old.dnsEntries.append(DomainDNSEntry(domain: "going.example", servers: ["10.9.9.9"]))
        let new = makeConfig()

        recording.failingDomains = ["going.example"]
        XCTAssertThrowsError(try manager.reconcile(old: old, new: new, logger: nil, vpnConnected: true))

        XCTAssertEqual(removedDomains(), ["going.example"])
        XCTAssertEqual(
            appliedDomains(),
            ["corp.example", "internal.example"],
            "the new config's entry files must still be written"
        )
    }

    /// The asymmetry is deliberate and worth pinning down. A partial *apply*
    /// reads as not-applied through `isApplied`, and the start path guards on
    /// it, so stopping early costs nothing and the next start repairs it.
    /// Continuing would instead write files for a domain set the caller was
    /// told had failed.
    func testApplyStillStopsAtTheFirstFailure() {
        recording.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.applyEntryFiles(config: makeConfig(), logger: nil))
        XCTAssertEqual(
            appliedDomains(),
            ["corp.example"],
            "removals continue past a failure; applies still stop"
        )
    }

    private func makeTemporaryResolverDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
