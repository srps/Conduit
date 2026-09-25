// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The platform managers each take an operation lock (#47), because the
/// hosts' start and stop surface work runs on their `PlatformWork` queue
/// while the reconciler and the VPN gate still call in from the main actor.
/// Every operation reads the journal or the machine and then acts on what it
/// read; a second operation landing in between leaves the machine and the
/// journal disagreeing, and the journal is the only copy of what to restore.
///
/// Each scenario holds an `apply` after it has recorded and before it has
/// written, runs a `clear` from another thread, and then lets the apply go.
/// With the lock the clear waits, lands last, and the surface ends released.
final class PlatformOperationLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("platform-operation-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeJournal() -> PlatformStateJournal {
        PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
    }

    /// Runs `first` on a thread of its own until `hold` stops it, starts
    /// `second` on another, then lets the first go and waits for both.
    /// Returns whether `second` finished while the first was still held.
    ///
    /// With the lock that never happens, so the bounded wait below always
    /// runs out and the scenario's outcome does not depend on it. The bound
    /// only limits how long a missing lock is given to show itself.
    private func interleave(
        hold: HeldCall,
        first: @escaping @Sendable () throws -> Void,
        second: @escaping @Sendable () throws -> Void
    ) -> Bool {
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { Self.run(first, "first"); firstDone.signal() }
        hold.blockUntilReached()
        XCTAssertFalse(hold.reachedOnMainThread)
        DispatchQueue.global().async { Self.run(second, "second"); secondDone.signal() }
        let finishedWhileHeld = secondDone.wait(timeout: .now() + .milliseconds(250)) == .success
        hold.release()
        firstDone.wait()
        if !finishedWhileHeld { secondDone.wait() }
        return finishedWhileHeld
    }

    private static func run(_ operation: () throws -> Void, _ name: String) {
        do {
            try operation()
        } catch {
            XCTFail("the \(name) operation threw: \(error)")
        }
    }

    /// Without the lock the clear restored Wi-Fi and released the surface
    /// while the apply was between its capture and its writes; the apply
    /// then pointed Wi-Fi at the proxy with nothing recorded to undo it.
    func testASystemProxyClearWaitsForTheApplyInProgress() throws {
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let hold = HeldCall()
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: machine,
            journal: journal,
            commandRunner: { launchPath, arguments in
                hold.pass(launchPath, arguments)
                return try machine.run(launchPath, arguments)
            },
            portProbe: { _ in false }
        )
        var config = ProxyConfig.testFixture()
        config.localPort = 3128
        // The apply's write script: the capture and the journal records are done.
        hold.arm { name, _ in name == "/bin/sh" }

        let finishedWhileHeld = interleave(
            hold: hold,
            first: { [config] in try manager.apply(config: config, mode: .manual, logger: nil) },
            second: { try manager.clear(logger: nil) }
        )

        XCTAssertFalse(finishedWhileHeld, "the clear waited for the apply")
        XCTAssertFalse(machine.service("Wi-Fi").routesThroughAProxy, "the clear landed last")
        XCTAssertTrue(journal.knowsSurfaceIsIdle(.systemProxy), "and released the surface it restored")
    }

    /// Without the lock the clear removed a file that was not there yet and
    /// forgot the domain; the apply then wrote the file, and nothing named
    /// it for the next teardown.
    func testAResolverClearWaitsForTheApplyInProgress() throws {
        let resolverDirectory = directory.appendingPathComponent("resolver")
        let machine = FakeMachine(resolverDirectory: resolverDirectory)
        let hold = HeldCall()
        let journal = makeJournal()
        let manager = DNSManager(
            privilegeClient: HoldingPrivilegeClient(base: machine, hold: hold),
            resolverDirectory: resolverDirectory.path,
            journal: journal
        )
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        // The write, after the domain is recorded as ours.
        hold.arm { name, _ in name == PrivilegedOperation.applyDNS.rawValue }

        let finishedWhileHeld = interleave(
            hold: hold,
            first: { [config] in try manager.apply(config: config, logger: nil, vpnConnected: true) },
            second: { [config] in try manager.clear(config: config, logger: nil) }
        )

        XCTAssertFalse(finishedWhileHeld, "the clear waited for the apply")
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "the clear landed last")
        XCTAssertFalse(journal.hasRecords(for: .resolverFile))
    }

    /// Without the lock the clear restored the launchd domain and released
    /// it while the apply was between its capture and its `setenv`s; the
    /// apply then published the proxy with nothing recorded to undo it.
    func testAnEnvironmentClearWaitsForTheApplyInProgress() throws {
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let hold = HeldCall()
        let journal = makeJournal()
        let home = directory.appendingPathComponent("home")
        let manager = EnvironmentManager(
            journal: journal,
            homeDirectory: home,
            commandRunner: { launchPath, arguments in
                hold.pass(launchPath, arguments)
                return try machine.run(launchPath, arguments)
            }
        )
        var config = ProxyConfig.testFixture()
        config.localPort = 3128
        hold.arm { name, arguments in name == "/bin/launchctl" && arguments.first == "setenv" }

        let finishedWhileHeld = interleave(
            hold: hold,
            first: { [config] in try manager.apply(config: config, logger: nil) },
            second: { try manager.clear(logger: nil) }
        )

        XCTAssertFalse(finishedWhileHeld, "the clear waited for the apply")
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"], "the clear landed last")
        XCTAssertTrue(journal.knowsSurfaceIsIdle(.launchdEnvironment))
        XCTAssertFalse(manager.hasManagedState())
    }
}
