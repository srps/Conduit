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

    func testApplyWithVPNConnectedWritesEntryAndInterceptFiles() throws {
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: true)
        XCTAssertEqual(
            appliedDomains(),
            ["corp.example", "internal.example", "intercepted.example"],
            "VPN up: both static entries and intercept files are written"
        )
    }

    func testApplyWithVPNDisconnectedDefersEntryFiles() throws {
        try manager.apply(config: makeConfig(), logger: nil, vpnConnected: false)
        XCTAssertEqual(
            appliedDomains(),
            ["intercepted.example"],
            "VPN down: intercept files (loopback forwarder) are still written, tunnel-internal entries are not"
        )
    }

    func testReconcileWithVPNDisconnectedRemovesEntryFiles() throws {
        // Same config on both sides: the only delta is the VPN going down,
        // which must strip the entry files while keeping the intercepts.
        let config = makeConfig()
        try manager.reconcile(old: config, new: config, logger: nil, vpnConnected: false)
        XCTAssertEqual(removedDomains(), ["corp.example", "internal.example"])
        XCTAssertEqual(appliedDomains(), ["intercepted.example"])
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
