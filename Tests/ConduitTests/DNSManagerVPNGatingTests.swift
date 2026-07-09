// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

// MARK: - Test Double

private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { _commands.append((operation, values)) }
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
}

// MARK: - Intercept-file readiness

/// Both hosts gate `applyInterceptFiles` on `dnsInterceptReady`. The predicate
/// encodes the promise an intercept resolver file makes: the domain resolves
/// at the forwarder, and the forwarder's answer (the intercept IP) is a
/// listener that accepts. Half a promise is a blackhole that outlives us.
final class DNSInterceptReadinessTests: XCTestCase {

    func testReadyOnlyWhenBothListenersAreBound() {
        XCTAssertTrue(
            ProxyOrchestratorBindings(dnsPort: 5053, transparentProxyPort: 10443).dnsInterceptReady
        )
    }

    func testNotReadyWhenForwarderIsDown() {
        // The shipped failure: resolver files pointed at 127.0.0.1:5053 with
        // nothing bound there, so every intercepted lookup was ENOTFOUND.
        XCTAssertFalse(
            ProxyOrchestratorBindings(dnsPort: nil, transparentProxyPort: 10443).dnsInterceptReady
        )
    }

    func testNotReadyWhenTransparentProxyFailedToBind() {
        // The forwarder would answer with the intercept IP, but nothing
        // accepts there — connection refused mid-TLS rather than ENOTFOUND.
        XCTAssertFalse(
            ProxyOrchestratorBindings(dnsPort: 5053, transparentProxyPort: nil).dnsInterceptReady
        )
    }

    func testNotReadyByDefault() {
        XCTAssertFalse(ProxyOrchestratorBindings().dnsInterceptReady)
    }

    /// The snapshot file is written by the daemon and read by the GUI; an
    /// older snapshot must decode to "not ready" rather than fail.
    func testLegacySnapshotWithoutTransparentProxyKeysDecodesAsNotReady() throws {
        let legacy = #"{"dnsHost":"127.0.0.1","dnsPort":5053,"tunnels":[]}"#
        let decoded = try JSONDecoder().decode(ProxyOrchestratorBindings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.dnsPort, 5053)
        XCTAssertNil(decoded.transparentProxyPort)
        XCTAssertFalse(decoded.dnsInterceptReady)
    }
}
