// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
import ConduitShared
@testable import Conduit
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The legacy app scenarios the migration checklist marked write-first (`docs/planning-appstate-test-migration.md`), now driven through
/// the actual host the app opens and its framed clients. Each asserts on the fake machine, the journal, the files or the host's own
/// diagnostics, never on a runtime object.
@MainActor
final class AppStateActivationParityTests: XCTestCase {
    private var harness: AppStateHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func makeConfig(_ configure: (inout ProxyConfig) -> Void = { _ in }) -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        configure(&config)
        return config
    }

    private func ready(
        platform: PlatformIntegrationConfig = PlatformIntegrationConfig(),
        configure: (inout ProxyConfig) -> Void = { _ in },
        prepare: (AppStateHarness) -> Void = { _ in }
    ) async throws -> (AppStateHarness, AppState) {
        let harness = try AppStateHarness(config: makeConfig(configure), platformConfig: platform)
        self.harness = harness
        prepare(harness)
        return (harness, await harness.ready())
    }

    private func startProxy(_ state: AppState, _ harness: AppStateHarness) async {
        state.toggleProxy()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
    }

    /// The host starts its location, path and VPN observers together, in one turn, when a Start brings a module up (`startObservers`),
    /// after the listener binds and the split-DNS apply; a report before then is not observed. The VPN fake's pending delivery says that
    /// turn has run. The location fake's does not: the host also starts its location observer when it is built, so it is live from launch.
    /// Probing only the location observer let a VPN report be emitted between the snapshot's `running` and that turn, before the VPN fake
    /// was started, and the fake drops a report emitted before `start()`: the cause of `testEntryFilesFollowTheVPN`'s earlier failures.
    private func observersRun(_ harness: AppStateHarness) async {
        await harness.settle("the host's observers run") {
            harness.vpn.pendingDelivery(.connected) != nil && harness.locationObserver.pendingSettingsDelivery() != nil
        }
    }

    private func stopProxy(_ state: AppState, _ harness: AppStateHarness) async {
        state.toggleProxy()
        await harness.settle("the proxy stopped") { state.runtime.runtimeStatus.state == .stopped }
    }

    // MARK: Credentials and listeners

    /// #98: the saved password is read once when the proxy comes up through the app's saved Start.
    func testAProxyStartReadsASavedPasswordOnce() async throws {
        let (harness, state) = try await ready()
        try state.credentialManager.saveHash(SecretBytes(Array(repeating: UInt8(7), count: 16)), for: state.config)
        await startProxy(state, harness)
        await harness.settle("the start's warm read") { harness.secrets.loads == 1 }
        XCTAssertEqual(harness.secrets.loads, 1)
        // The running proxy answers from the cached read: nothing reads the store again while it runs.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.secrets.loads, 1, "the warm read is cached")
    }

    func testAProxyStartReadsNothingWithoutASavedPassword() async throws {
        let (harness, state) = try await ready()
        await startProxy(state, harness)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.secrets.loads, 0)
    }

    func testLocalhostIsPinnedInListenersAndAdvertisedClientSettings() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true),
            configure: { $0.localHost = "localhost" }
        )
        await startProxy(state, harness)
        await harness.settle("the Start's surfaces applied") { harness.machine.launchdEnvironment["HTTPS_PROXY"] != nil }
        XCTAssertEqual(state.runtime.bindings.proxyHost, "127.0.0.1")
        let wifi = harness.machine.service("Wi-Fi")
        XCTAssertEqual(wifi.webProxy.host, "127.0.0.1")
        XCTAssertEqual(wifi.secureWebProxy.host, "127.0.0.1")
        XCTAssertEqual(URL(string: harness.machine.launchdEnvironment["HTTP_PROXY"] ?? "")?.host, "127.0.0.1")
        XCTAssertEqual(URL(string: harness.machine.launchdEnvironment["HTTPS_PROXY"] ?? "")?.host, "127.0.0.1")
    }

    // MARK: Observers during a module Stop

    /// A VPN report or a settings notification that arrives while the proxy's own Stop is held cannot put back what the Stop clears, and a
    /// flood of settings notifications is coalesced.
    func testANotificationDuringAProxyStopCannotRepinTheStoppedSurfaces() async throws {
        for notify in ["vpn", "settings"] {
            let locations = NetworkLocationFixture.store()
            let original = try locations.snapshot()
            let (harness, state) = try await ready(
                platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true),
                prepare: { $0.locationStore = locations }
            )
            await startProxy(state, harness)
            await observersRun(harness)
            await harness.settle("the Start's surfaces applied") { harness.machine.launchdEnvironment["HTTP_PROXY"] != nil }
            harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
                name == "/bin/launchctl" && arguments.first == "unsetenv"
            }
            state.toggleProxy()
            await harness.hold.waitUntilReached()
            XCTAssertFalse(harness.hold.reachedOnMainThread)
            if notify == "vpn" {
                harness.vpn.emit(.connected)
            } else {
                for _ in 0..<1_000 { harness.locationObserver.emitSettingsChange() }
            }
            try await Task.sleep(for: .milliseconds(50))
            harness.hold.release()
            await harness.settle("the proxy stopped") { state.runtime.runtimeStatus.state == .stopped }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try locations.snapshot().services, original.services, notify)
            XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy), notify)
            if notify == "settings" {
                // The Stop that leaves every module down stops the observers before its teardown, so the flood finds none, and none
                // of it passes; at most one pass and one pending could otherwise run.
                let observed = harness.hostEventsText.components(separatedBy: "platform.settings_observed").count - 1
                XCTAssertLessThanOrEqual(observed, 2, "one pass and one pending, whatever the flood")
            }
            await harness.tearDown()
            self.harness = nil
        }
    }

    func testALocationNotificationDuringADNSStopCannotRepinTheStoppedListener() async throws {
        let locations = NetworkLocationFixture.store()
        let original = try locations.snapshot()
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemDNS: true), prepare: { $0.locationStore = locations }
        )
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }
        state.toggleDNS()
        await harness.hold.waitUntilReached()
        locations.edit { $0.activeLocationID = NetworkLocationFixture.office }
        harness.locationObserver.emit(NetworkLocationFixture.office)
        try await Task.sleep(for: .milliseconds(50))
        harness.hold.release()
        await harness.settle("DNS stopped") { state.runtime.dnsRunState == .stopped }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try locations.snapshot().services, original.services)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertFalse(harness.journal.hasRecords(for: .systemDNS))
    }

    // MARK: Held helper effects

    /// The resolver writes of a Start and a Stop wait on the helper off the main actor, and land in order once released. The VPN is
    /// unknown at the Start, which keeps entry files wanted (`SplitDNSVPNGate`).
    func testHeldResolverWritesWaitOffTheMainActor() async throws {
        let (harness, state) = try await ready(platform: PlatformIntegrationConfig(manageDNSResolvers: true))
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.applyDNS.rawValue }
        state.toggleProxy()
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread, "the helper round trip runs off the main actor")
        state.config.profileName = "main actor is free"
        harness.hold.release()
        await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        await harness.settle("the entry file was written") { harness.machine.resolverFile(for: "corp.example") != nil }

        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.removeDNS.rawValue }
        state.toggleProxy()
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        harness.hold.release()
        await harness.settle("the proxy stopped") { state.runtime.runtimeStatus.state == .stopped }
        await harness.settle("the entry file was removed") { harness.machine.resolverFile(for: "corp.example") == nil }
    }

    // MARK: Drift

    /// The periodic tick repairs a wipe no notification reports, to the input the host applied, never to a draft the app holds; with the
    /// proxy stopped it leaves the environment alone.
    func testTheDriftTickRepairsToTheAppliedInputAndLeavesAStoppedProxyAlone() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageEnvironmentVariables: true),
            prepare: { $0.hostSchedules.environmentDriftInterval = .milliseconds(100) }
        )
        await startProxy(state, harness)
        await harness.settle("the Start's environment applied") { harness.machine.launchdEnvironment["HTTP_PROXY"] != nil }
        let port = try XCTUnwrap(state.runtime.bindings.proxyPort)
        let applied = try XCTUnwrap(harness.machine.launchdEnvironment["HTTP_PROXY"])
        state.config.localPort = 1
        XCTAssertTrue(state.hasUnsavedEdit, "the draft is held, not saved")
        harness.machine.launchdEnvironment = [:]
        await harness.settle("the tick repaired the wipe") { harness.machine.launchdEnvironment["HTTP_PROXY"] != nil }
        XCTAssertEqual(harness.machine.launchdEnvironment["HTTP_PROXY"], applied, "the repair restores the applied input")
        XCTAssertNotEqual(URL(string: applied)?.port, 1, "the held draft's port never reaches the machine")
        _ = port

        // The switch turned off while the proxy runs clears the environment, and the tick does not put it back.
        state.config.localPort = 0
        state.platformConfig.manageEnvironmentVariables = false
        state.saveConfig()
        await state.awaitPendingSave()
        await harness.settle("the switch-off cleared the environment") { harness.machine.launchdEnvironment["HTTP_PROXY"] == nil }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"], "a switched-off environment is not repaired")
        XCTAssertEqual(state.runtime.runtimeStatus.state, .running)

        await stopProxy(state, harness)
        harness.machine.launchdEnvironment = [:]
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"], "a stopped proxy's environment is not repaired")
    }

    // MARK: Split DNS and VPN

    /// The host's own `events.ndjson` lines naming `event`, as written so far. A disk read: the host's event writer appends on its own
    /// queue after the event is recorded, so a read meant to cover everything the host did follows `quitJoiningHostDiagnostics`.
    private func hostEvents(_ harness: AppStateHarness, _ event: String) -> [String] {
        harness.hostEventsText.split(separator: "\n").map(String.init).filter { $0.contains("\"\(event)\"") }
    }

    /// Quits through the app's own Quit and returns whether it settled completed. The host settles it only after its quit's bounded
    /// diagnostic flush attempt has been joined. That is logical quiescence, not a claim that every diagnostic writer confirmed its
    /// records: a drain that timed out, or a record the writer dropped or failed, leaves the file short, and the file assertions read after
    /// this catch it. Runtime, listener and machine assertions belong before it, since the Quit tears the modules down.
    private func quitJoiningHostDiagnostics(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        XCTAssertTrue(state.beginQuit(), "the test's Quit is the first", file: file, line: line)
        guard case .settled(.completed)? = await state.finishQuit()?.quit else {
            XCTFail("the Quit completed", file: file, line: line)
            return false
        }
        return true
    }

    private static let refusing = HelperToolPrivilegeClient.Status.callerNotAccepted(message: "caller identity is not the pinned one")

    /// Starts the proxy with the VPN up and the entry file written, the observers running.
    private func startWithTheTunnelUp(_ state: AppState, _ harness: AppStateHarness) async {
        await startProxy(state, harness)
        await observersRun(harness)
        harness.vpn.emit(.connected)
        await harness.settle("the entry file is written") { harness.machine.resolverFile(for: "corp.example") != nil }
    }

    /// #165, as reported: the helper refuses this build, so the removal on a VPN drop fails and the entry file stays with the tunnel down.
    /// Reinstalling the helper from the app tells the host it was replaced, and the host's preflight finds it available and removes the
    /// file, with no other VPN report and without restarting the proxy.
    func testAFailedRemovalIsRetriedWhenAnInstallMakesTheHelperAvailable() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: true), prepare: { $0.helper.status = Self.refusing }
        )
        await harness.settle("the refusing helper is seen") { state.helperStatus != .installed }
        await startWithTheTunnelUp(state, harness)
        let port = state.runtime.bindings.proxyPort
        harness.machine.privilege.failingDomains = ["corp.example"]
        harness.vpn.emit(.disconnected(reason: .networkLost))
        await harness.settle("the removal was refused") { self.hostEvents(harness, "platform.split_dns_failed").count == 1 }
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"))

        harness.machine.privilege.failingDomains = []
        state.installHelper()
        await harness.settle("the reinstalled helper removes the entry file") { harness.machine.resolverFile(for: "corp.example") == nil }
        await harness.settle("the retry is recorded") { !self.hostEvents(harness, "platform.split_dns_repaired").isEmpty }
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_retry").contains { $0.contains("operation=remove trigger=helper_available managed=true attempt=2") })
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_repaired").contains { $0.contains("operation=remove by=retry failed=remove attempts=1") })
        XCTAssertEqual(state.runtime.runtimeStatus.state, .running, "repaired without restarting the proxy")
        XCTAssertEqual(state.runtime.bindings.proxyPort, port)
    }

    /// The other direction: the Start's write is refused with the tunnel up, and the first preflight that finds the helper available
    /// writes it.
    func testAFailedStartWriteIsRetriedWhenThePreflightFindsTheHelperAvailable() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: true), prepare: { $0.helper.status = Self.refusing }
        )
        await harness.settle("the refusing helper is seen") { state.helperStatus != .installed }
        harness.machine.privilege.failingDomains = ["corp.example"]
        await startProxy(state, harness)
        await harness.settle("the Start's write was refused") { !self.hostEvents(harness, "platform.split_dns_failed").isEmpty }
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"))
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_failed").first?.contains("operation=apply source=start attempt=1") == true)

        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        state.refreshPreflight()
        await harness.settle("the entry file is written") { harness.machine.resolverFile(for: "corp.example") == "nameserver 10.0.0.53" }
        await harness.settle("the repair is recorded") { !self.hostEvents(harness, "platform.split_dns_repaired").isEmpty }
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_repaired").contains { $0.contains("operation=apply by=retry failed=apply attempts=1") })
    }

    /// A switch-on refused while the helper refuses, then written by a retry once it is available: turning the switch off again through a
    /// Settings save still tears the retried entry down.
    func testARetriedSwitchOnIsTornDownWhenTheSwitchTurnsOffAgain() async throws {
        let (harness, state) = try await ready(platform: PlatformIntegrationConfig(manageDNSResolvers: false))
        await startProxy(state, harness)
        await observersRun(harness)
        harness.vpn.emit(.connected)
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"))
        harness.helper.status = Self.refusing
        state.refreshPreflight()
        await harness.settle("the refusing helper is seen") { state.helperStatus != .installed }
        harness.machine.privilege.failingDomains = ["corp.example"]
        state.platformConfig.manageDNSResolvers = true
        state.saveConfig()
        await state.awaitPendingSave()
        await harness.settle("the switch-on's write was refused") {
            self.hostEvents(harness, "platform.split_dns_failed").contains { $0.contains("operation=apply source=switch_on attempt=1") }
        }
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"))

        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        state.refreshPreflight()
        await harness.settle("the retry writes the entry") { harness.machine.resolverFile(for: "corp.example") != nil }
        state.platformConfig.manageDNSResolvers = false
        state.saveConfig()
        await state.awaitPendingSave()
        await harness.settle("switching off tears the retried entry down") { harness.machine.resolverFile(for: "corp.example") == nil }
    }

    /// Switch-on failed for both the entry and the intercept files. The retry writes the entry; the intercept refresh fails again and is
    /// reported, and the entry is still torn down when the switch turns off.
    func testAnInterceptRefreshThatStillFailsDoesNotStrandARetriedEntry() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: false),
            configure: { $0.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.1", enabled: false)] }
        )
        await startProxy(state, harness)
        await observersRun(harness)
        harness.vpn.emit(.connected)
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        harness.helper.status = Self.refusing
        state.refreshPreflight()
        await harness.settle("the refusing helper is seen") { state.helperStatus != .installed }
        harness.machine.privilege.failingDomains = ["corp.example", "intercept.test"]
        state.platformConfig.manageDNSResolvers = true
        state.saveConfig()
        await state.awaitPendingSave()
        await harness.settle("the switch-on was refused") { !self.hostEvents(harness, "platform.split_dns_failed").isEmpty }
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"))

        harness.machine.privilege.failingDomains = ["intercept.test"]
        harness.helper.status = .installed
        state.refreshPreflight()
        await harness.settle("the retry writes the entry") { harness.machine.resolverFile(for: "corp.example") != nil }
        await harness.settle("the intercept refresh failure is reported") {
            self.hostEvents(harness, "platform.split_dns_intercept_refresh_failed").count == 1
        }
        harness.machine.privilege.failingDomains = []
        state.platformConfig.manageDNSResolvers = false
        state.saveConfig()
        await state.awaitPendingSave()
        await harness.settle("switching off tears the retried entry down") { harness.machine.resolverFile(for: "corp.example") == nil }
    }

    /// A busy reading keeps the held verdict on display (#210), but is no evidence the helper takes writes: no retry until the busy recheck
    /// reads it answering.
    func testABusyHelperReadingDoesNotRetryUntilTheRecheckFindsItAnswering() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: true), prepare: { $0.timing.helperBusyRecheckDelay = .milliseconds(20) }
        )
        await harness.settle("the launch preflight found the helper") { state.helperStatus == .installed }
        await startWithTheTunnelUp(state, harness)
        // Busy from here: every preflight from now on, the app's own after each command included, reads busy. A reading of the helper
        // answering would be a legitimate retry trigger, so it must not land between the failure and the busy reading.
        harness.helper.status = .busy
        harness.machine.privilege.failingDomains = ["corp.example"]
        harness.vpn.emit(.disconnected(reason: .networkLost))
        await harness.settle("the removal was refused") { !self.hostEvents(harness, "platform.split_dns_failed").isEmpty }
        let retriesBefore = hostEvents(harness, "platform.split_dns_retry").count

        harness.machine.privilege.failingDomains = []
        state.refreshPreflight()
        await harness.settle("the busy reading is noted") { state.helperCheckingAgain }
        XCTAssertEqual(state.helperStatus, .installed, "the held verdict")
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"), "no retry on a busy reading")
        XCTAssertEqual(hostEvents(harness, "platform.split_dns_retry").count, retriesBefore)

        harness.helper.status = .installed
        await harness.settle("the recheck reads the helper answering and the retry removes the file") {
            harness.machine.resolverFile(for: "corp.example") == nil
        }
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_retry").last?.contains("trigger=helper_available") == true)
    }

    /// A check left sleeping on a long back-off from an earlier episode does not delay a new one: after a VPN flip settles the repair, a
    /// new failure while the helper refuses gets a check at the first interval, which finds the helper once it answers.
    func testANewFailureGetsAFreshHelperCheckRatherThanAnEarlierBackOff() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: true),
            prepare: { $0.hostSchedules.splitDNSHelperCheckInterval = .seconds(1) }
        )
        await harness.settle("the launch preflight found the helper") { state.helperStatus == .installed }
        await startWithTheTunnelUp(state, harness)
        harness.machine.privilege.failingDomains = ["corp.example"]
        harness.vpn.emit(.disconnected(reason: .networkLost))
        await harness.settle("the drop's removal was refused") { !self.hostEvents(harness, "platform.split_dns_failed").isEmpty }
        for _ in 0..<5 {
            let before = hostEvents(harness, "platform.split_dns_failed").count
            state.refreshPreflight()
            await harness.settle("a retry failed") { self.hostEvents(harness, "platform.split_dns_failed").count > before }
        }
        XCTAssertGreaterThanOrEqual(hostEvents(harness, "platform.split_dns_failed").count, 6, "the back-off is at its limit")
        try await Task.sleep(for: .milliseconds(1_500))

        harness.machine.privilege.failingDomains = []
        harness.vpn.emit(.connected)
        await harness.settle("the reconnect settles the repair") {
            self.hostEvents(harness, "platform.split_dns_repaired").last?.contains("by=vpn_transition") == true
        }
        harness.helper.status = Self.refusing
        state.refreshPreflight()
        await harness.settle("the refusing helper is seen") { state.helperStatus != .installed }
        harness.machine.privilege.failingDomains = ["corp.example"]
        let failuresBefore = hostEvents(harness, "platform.split_dns_failed").count
        harness.vpn.emit(.disconnected(reason: .userInitiated))
        await harness.settle("the new removal was refused") { self.hostEvents(harness, "platform.split_dns_failed").count > failuresBefore }
        XCTAssertNotNil(harness.machine.resolverFile(for: "corp.example"))
        harness.machine.privilege.failingDomains = []
        harness.helper.status = .installed
        await harness.settle("a fresh check finds the helper within a few intervals") {
            harness.machine.resolverFile(for: "corp.example") == nil
        }
        XCTAssertTrue(hostEvents(harness, "platform.split_dns_retry").last?.contains("trigger=helper_check") == true)
    }

    /// A PAC application the location store refused while the helper was outdated is repaired once a preflight finds the helper installed,
    /// without restarting the proxy.
    func testHelperBecomingAvailableRepairsFailedPACApplicationWithoutRestartingProxy() async throws {
        let locations = NetworkLocationFixture.store()
        locations.refuseWrites(true)
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac),
            configure: {
                $0.localPACEnabled = true
                $0.localPACPort = 0
            },
            prepare: {
                $0.locationStore = locations
                $0.helper.status = .outdated
            }
        )
        await harness.settle("old helper status received") { state.helperStatus == .outdated }
        await startProxy(state, harness)
        // The host reports the proxy running once it binds, before the Start applies PAC; the refusal is what is repaired.
        await harness.settle("the Start's PAC application was refused") { !self.hostEvents(harness, "platform.location_failed").isEmpty }
        let bindings = state.runtime.bindings
        let pacPort = try XCTUnwrap(bindings.localPACPort)
        func appliedPACURL() -> String? {
            guard case .text(let url)? = try? locations.snapshot().services[0].proxies["ProxyAutoConfigURLString"] else { return nil }
            return url
        }
        XCTAssertFalse(appliedPACURL()?.contains(":\(pacPort)") ?? false, "the refused write left no PAC URL of this run")
        locations.refuseWrites(false)
        harness.helper.status = .installed
        state.refreshPreflight()
        await harness.settle("the installed helper repairs PAC") { appliedPACURL()?.contains(":\(pacPort)") == true }
        XCTAssertEqual(state.runtime.bindings, bindings, "nothing restarted")
        XCTAssertFalse(hostEvents(harness, "platform.location_reconcile").isEmpty)
    }

    /// A listen-host commit while the proxy and DNS run replaces the HTTP listener and leaves the DNS forwarder where the resolver files and
    /// the relay point: on loopback, on its port, not restarted.
    func testCommittingAListenHostLeavesTheDNSForwarderOnLoopback() async throws {
        let (harness, state) = try await ready()
        await startProxy(state, harness)
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        let dnsPort = try XCTUnwrap(state.runtime.bindings.dnsPort)
        state.config.localHost = "::1"
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        await harness.settle("the listener moved") { state.runtime.bindings.proxyHost == "::1" }
        XCTAssertEqual(state.runtime.dnsRunState, .running)
        XCTAssertEqual(state.runtime.bindings.dnsHost, "127.0.0.1")
        XCTAssertEqual(state.runtime.bindings.dnsPort, dnsPort)
        guard await quitJoiningHostDiagnostics(state) else { return }
        XCTAssertEqual(hostEvents(harness, "config.proxy_restart").count, 1)
        XCTAssertTrue(hostEvents(harness, "config.dns_restart").isEmpty)
    }

    // MARK: Saves while modules run, and the causal chain

    /// A pause save while the proxy runs applies to it: a bypass edit reaches the advertised environment without a Start.
    func testAPauseSaveWhileTheProxyRunsReachesTheRuntime() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageEnvironmentVariables: true),
            prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) }
        )
        await startProxy(state, harness)
        await harness.settle("the Start's environment applied") { harness.machine.launchdEnvironment["NO_PROXY"] != nil }
        let port = state.runtime.bindings.proxyPort
        state.config.noProxyHosts.append("bypass-witness.example.test")
        await harness.settle("the saved bypass reached the environment") {
            harness.machine.launchdEnvironment["NO_PROXY"]?.contains("bypass-witness.example.test") == true
        }
        XCTAssertEqual(state.runtime.bindings.proxyPort, port, "a bypass edit rebinds nothing")
        await harness.settle("its own receipt cleaned the draft") { !state.hasUnsavedEdit }
        // The shell profile's block is the other advertised surface in manual mode.
        let zshrc = harness.homeDirectory.appendingPathComponent(".zshrc")
        await harness.settle("the shell profile carries the bypass") {
            ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains("bypass-witness.example.test")
        }
    }

    /// Entry files live and die with the tunnel once a Start brought the proxy up. The required DNS parity witness. Its earlier failures
    /// (runs YVyq4j, sapsLa, vrcafp: no host log line for the first two reports) were the fixture's readiness probe, not the host: see
    /// `observersRun`.
    func testEntryFilesFollowTheVPN() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageDNSResolvers: true), configure: { $0.upstreams = [] }
        )
        await startProxy(state, harness)
        await observersRun(harness)
        harness.vpn.emit(.connected)
        await harness.settle("the entry file follows the tunnel up") { harness.machine.resolverFile(for: "corp.example") != nil }
        harness.vpn.emit(.disconnected(reason: .userInitiated))
        await harness.settle("the entry file follows the tunnel down") { harness.machine.resolverFile(for: "corp.example") == nil }
        harness.vpn.emit(.connected)
        await harness.settle("the entry file is back") { harness.machine.resolverFile(for: "corp.example") != nil }
        // A burst follows its last report, whichever way it ends.
        for last in [VPNObservedState.disconnected(reason: .userInitiated), .connected] {
            for report in [VPNObservedState.connected, .disconnected(reason: .networkLost), .connected, .disconnected(reason: .userInitiated), last] {
                harness.vpn.emit(report)
            }
            let wanted = last == .connected
            await harness.settle("the entry file follows the burst's last report") {
                (harness.machine.resolverFile(for: "corp.example") != nil) == wanted
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(harness.machine.resolverFile(for: "corp.example") != nil, wanted, "no earlier report of the burst lands after it")
        }
    }

    /// DNS on, then off, through the app's saved commands, then a Settings save submitted as soon as the file shows the Stop's disable,
    /// typically before the Stop's settlement reaches the app. The save meets the Stop's write as a `baselineMismatch`; the ledger holds
    /// it while that own Stop is out, the Stop's chained write explains it, and the same draft goes again under the new baseline. So the
    /// save persists with no reload, and the forwarder was never restarted by a save.
    func testTheDNSCommandsOwnWritesChainSoTheNextSaveNeedsNoReload() async throws {
        let (harness, state) = try await ready()
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        await harness.settle("the saved intent is on") { (try? harness.savedConfig.dnsForwarderEnabled) == true }
        state.toggleDNS()
        await harness.settle("the saved intent is off") { (try? harness.savedConfig.dnsForwarderEnabled) == false }
        state.config.health.checkInterval = 43
        state.saveConfig()
        await harness.settle("the save persisted") { (try? harness.savedConfig.health.checkInterval) == 43 }
        await harness.settle("its own receipt cleaned the draft") { !state.hasUnsavedEdit }
        let editor = try XCTUnwrap(state.editor)
        await harness.settle("the Stop ended") { editor.ledger.ownCommands.isEmpty }
        XCTAssertFalse(state.configurationNeedsReload)
        XCTAssertTrue(editor.ledger.filesNeedingReload.isEmpty)
        XCTAssertTrue(editor.ledger.heldMismatches.isEmpty)
        XCTAssertFalse(try harness.savedConfig.dnsForwarderEnabled, "the save carried the Stop's disable, not the stale draft bit")
        XCTAssertFalse(editor.ledger.saved.config.dnsForwarderEnabled)
        XCTAssertEqual(state.runtime.dnsRunState, .stopped)
        guard await quitJoiningHostDiagnostics(state) else { return }
        XCTAssertFalse(harness.hostEventsText.contains("config.dns_restart"))
    }

    /// A module's Stop has a lane of its own: duplicate proxy Stops while one is held are coalesced into one wanted Stop, and they cannot
    /// take the room a DNS Stop needs. Both modules end stopped once the hold is released. DNS is started first: a saved DNS Start that
    /// commits while a proxy Start is still finishing replaces that Start's input, which supersedes it (`input_replaced`).
    func testDuplicateProxyStopsCannotCrowdOutADNSStop() async throws {
        let (harness, state) = try await ready(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true))
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        await harness.settle("the DNS Start's own write was chained") { state.editor?.ledger.ownCommands.isEmpty == true }
        await startProxy(state, harness)
        await harness.settle("the Start's environment applied") { harness.machine.launchdEnvironment["HTTP_PROXY"] != nil }
        await harness.settle("the proxy Start ended") { state.editor?.ledger.ownCommands.isEmpty == true }
        XCTAssertEqual(state.runtime.runtimeStatus.state, .running)
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/bin/launchctl" && arguments.first == "unsetenv"
        }
        // One turn: every toggle sees the proxy running, so one Stop goes and the rest are one wanted Stop on its lane.
        for _ in 0..<(AppState.maximumCommandsInFlight + ControlModule.allCases.count + 4) { state.toggleProxy() }
        state.toggleDNS()
        let held = await harness.hold.waitUntilReached(within: .seconds(5))
        harness.hold.release()
        guard held else { return XCTFail("the proxy Stop never reached its environment teardown") }
        await harness.settle("the proxy stopped") { state.runtime.runtimeStatus.state == .stopped }
        await harness.settle("the DNS Stop reached the host and ran") { state.runtime.dnsRunState == .stopped }
        XCTAssertFalse(state.logStore.exportDiagnosticLog().contains("stop dropped"), "no Stop was dropped by the ordinary cap")
        XCTAssertFalse(try harness.savedConfig.dnsForwarderEnabled, "the DNS Stop saved its disable")
    }

    /// An edit another writer made to the file refuses the next save (decision 0027): nothing is overwritten and a reload is offered. The
    /// explicit reload rebuilds clean drafts from the file, and the next save persists (decision 0032).
    func testAnExternalEditRefusesTheSaveAndAnExplicitReloadRecovers() async throws {
        let (harness, state) = try await ready()
        var external = try harness.savedConfig
        external.profileName = "edited outside"
        try ProxyConfigPersistence.save(external, in: harness.environment)
        let externalBytes = try Data(contentsOf: harness.environment.configFile)
        state.config.health.checkInterval = 41
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertTrue(state.configurationNeedsReload)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), externalBytes, "the external edit was not overwritten")

        state.reloadConfigurationFromDisk()
        await harness.settle("the reload rebuilt the drafts") { !state.configurationNeedsReload }
        XCTAssertEqual(state.config.profileName, "edited outside")
        XCTAssertFalse(state.hasUnsavedEdit)
        state.config.health.checkInterval = 42
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.health.checkInterval, 42)
        XCTAssertEqual(try harness.savedConfig.profileName, "edited outside")
    }

    /// A platform toggle beside an already-saved runtime value that blocks a start still saves on its pause.
    func testAnInvalidSavedConfigDoesNotHoldBackAPlatformEdit() async throws {
        let (harness, state) = try await ready(prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) })
        state.config.proxy.port = 70_000
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(try harness.savedConfig.proxy.port, 70_000)
        state.platformConfig.manageEnvironmentVariables = true
        await harness.settle("the platform edit saved on its pause") { (try? harness.savedPlatform.manageEnvironmentVariables) == true }
    }

    /// Preferences save on their own pause, through their own receipt.
    func testAPreferencesEditSavesOnItsPause() async throws {
        let (harness, state) = try await ready(prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) })
        state.appPreferences.floatingWindowEnabled.toggle()
        let expected = state.appPreferences.floatingWindowEnabled
        await harness.settle("the preferences saved") {
            (try? AppPreferencesPersistence.load(in: harness.environment).floatingWindowEnabled) == expected
        }
        await harness.settle("its receipt cleaned the draft") { !state.hasUnsavedEdit }
    }

    // MARK: Failed Start and queued work at Quit

    /// A Start whose listener cannot bind applies no surface and leaves nothing recorded; no success is reported.
    func testAStartThatCannotBindAppliesNothingAndRecordsNothing() async throws {
        let occupied = try OccupiedLoopbackPort()
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true),
            configure: { $0.localPort = occupied.port }
        )
        state.toggleProxy()
        await harness.settle("the Start settled") { [.failed, .stopped].contains(state.runtime.runtimeStatus.state) && state.runtime.isLive }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(state.runtime.runtimeStatus.state, .running)
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy))
        XCTAssertFalse(harness.journal.hasRecords(for: .launchdEnvironment))
    }

    /// A Start whose listener cannot bind owns the proxy's surfaces and clears what it finds pointing at a listener that is not there,
    /// recorded or not: here what a killed run leaves, a proxied service, a published launchd variable and a resolver file, none of it in
    /// the journal, all planted after launch recovery ran.
    func testAStartThatCannotBindRevertsTheLeftoversItFindsUnrecorded() async throws {
        let occupied = try OccupiedLoopbackPort()
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageDNSResolvers: true),
            configure: { $0.localPort = occupied.port }
        )
        harness.machine.describe("Wi-Fi") { service in
            service.webProxy = FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: "47113")
            service.secureWebProxy = service.webProxy
        }
        harness.machine.launchdEnvironment = ["HTTP_PROXY": "http://127.0.0.1:47113", "https_proxy": "http://127.0.0.1:47113"]
        try harness.machine.strandResolverFile(for: "corp.example", contents: "nameserver 10.0.0.53")
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy), "the residue is unrecorded")
        state.toggleProxy()
        await harness.settle("the failed Start cleared the leftovers") {
            !harness.machine.service("Wi-Fi").routesThroughAProxy && harness.machine.launchdEnvironment["HTTP_PROXY"] == nil
                && harness.machine.resolverFile(for: "corp.example") == nil
        }
        XCTAssertNotEqual(state.runtime.runtimeStatus.state, .running)
        XCTAssertNil(harness.machine.launchdEnvironment["https_proxy"])
    }

    /// A problem that does not block a start does not hold the pause save back: an unrelated edit beside an intercept IP the runtime
    /// refuses but the file can hold saves as typed, with no `config.autosave_held`.
    func testAPauseOnANonBlockingProblemStillSaves() async throws {
        let (harness, state) = try await ready(
            configure: { $0.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3")] },
            prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) }
        )
        XCTAssertFalse(state.config.validate().isEmpty)
        XCTAssertTrue(state.config.startBlockingProblems.isEmpty, "the problem does not block a start")
        state.config.health.checkInterval = 45
        await harness.settle("the pause saved the edit") { !state.hasUnsavedEdit }
        let saved = try harness.savedConfig
        XCTAssertEqual(saved.health.checkInterval, 45)
        XCTAssertEqual(saved.dnsInterceptRules.first?.interceptIP, "127.44.3", "the representable IP is kept as typed")
        XCTAssertFalse(state.eventLog.events.contains { $0.event == "config.autosave_held" })
    }

    /// Typing a port and then back to the committed one leaves nothing to commit: the draft's edit versions moved, but its value is the
    /// saved one, so its pause saves it like any edit and the host rebinds nothing. The same after the menu's DNS Start and Stop, whose own
    /// writes move the host-owned forwarder bit: the draft follows it, so neither reads as a DNS section change that holds every later
    /// pause save as a listener edit (review N1).
    func testTypingBackToTheCommittedPortRebindsNothingAndADNSToggleHoldsNoLaterPause() async throws {
        let (harness, state) = try await ready(prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) })
        await startProxy(state, harness)
        let port = try XCTUnwrap(state.runtime.bindings.proxyPort)
        let committed = state.config.localPort
        state.config.localPort = try reserveLoopbackPort()
        XCTAssertTrue(state.listenerEditAwaitingCommit)
        state.config.localPort = committed
        XCTAssertFalse(state.listenerEditAwaitingCommit)
        await harness.settle("the pause saved the typed-back draft") { !state.hasUnsavedEdit }
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()

        for (turn, enabled) in [("on", true), ("off", false)] {
            state.toggleDNS()
            await harness.settle("DNS \(turn)") { state.runtime.dnsRunState == (enabled ? .running : .stopped) }
            await harness.settle("the DNS command ended") { state.editor?.ledger.ownCommands.isEmpty == true }
            XCTAssertEqual(state.config.dnsForwarderEnabled, enabled, "the draft follows the host-owned bit")
            XCTAssertFalse(state.hasUnsavedEdit, "following it is not an edit")
            state.config.health.checkInterval += 1
            let wanted = state.config.health.checkInterval
            XCTAssertFalse(state.listenerEditAwaitingCommit, "after DNS \(turn), an unrelated edit is no listener edit")
            await harness.settle("the pause after DNS \(turn) saved") { (try? harness.savedConfig.health.checkInterval) == wanted }
            await harness.settle("its own receipt cleaned the draft") { !state.hasUnsavedEdit }
        }
        XCTAssertFalse(state.eventLog.events.contains { $0.event == "config.autosave_held" }, "no pause was held")
        XCTAssertEqual(state.runtime.bindings.proxyPort, port)
        // Each save's receipt followed its runtime apply, where a rebind records its event, so the drain covers any rebind.
        guard await quitJoiningHostDiagnostics(state) else { return }
        XCTAssertTrue(hostEvents(harness, "config.proxy_restart").isEmpty, "nothing rebound")
    }

    /// A persisted duration the runtime cannot hold (written past the save's refusal, as an older build or a hand edit could) opens, and
    /// the saved Starts refuse it at admission, before any effect: no listener, no system proxy, no tunnel, and the value is in no host
    /// diagnostic.
    func testAPersistedUnholdableDurationOpensAndEveryStartRefusesItBeforeAnyEffect() async throws {
        let harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        self.harness = harness
        var persisted = makeConfig()
        persisted.health.upstreamResponseTimeout = 1e10
        persisted.tunnelDefinitions = [TunnelDefinition(localPort: 0, remoteHost: "db.example.test", remotePort: 5432, enabled: true)]
        try CanonicalJSON.encoder(prettyPrinted: true).encode(persisted).write(to: harness.environment.configFile)
        let state = await harness.ready()
        XCTAssertFalse(state.config.startBlockingProblems.isEmpty, "the draft shows the problem")
        state.toggleProxy()
        await harness.settle("the proxy Start ended") { state.editor?.ledger.ownCommands.isEmpty == true }
        state.toggleTunnels()
        await harness.settle("the tunnels Start ended") { state.editor?.ledger.ownCommands.isEmpty == true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(state.runtime.runtimeStatus.state, .running)
        XCTAssertNotEqual(state.runtime.tunnelsRunState, .running)
        XCTAssertNil(state.runtime.bindings.proxyPort)
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy)
        guard await quitJoiningHostDiagnostics(state) else { return }
        XCTAssertFalse(harness.hostEventsText.contains("10000000000"), "the value is in no host event")
    }

    /// Decision 0037's strict capture, reached from the app (disclosed: the old app's DNS toggle never stopped a proxy Start). A DNS Start
    /// whose commit saves the forwarder on while the proxy Start is applying its surfaces (held at its resolver write) replaces the input
    /// that Start captured: the host holds the Start (`config.workflow.held reason=input_replaced`) and clears what it brought up. Nothing
    /// retries it, no login-item repair follows it, the app says why, DNS runs, and the next explicit Start comes up on the saved pair.
    func testADNSStartCommittedWhileAProxyStartAppliesHoldsThatStartAndSaysWhy() async throws {
        let (harness, state) = try await ready(platform: PlatformIntegrationConfig(manageEnvironmentVariables: true, manageDNSResolvers: true))
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.applyDNS.rawValue }
        state.toggleProxy()
        let held = await harness.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(held, "the proxy Start is applying its surfaces")
        await harness.settle("the app sees the proxy bound") { state.runtime.runtimeStatus.state == .running }
        state.toggleDNS()
        await harness.settle("the DNS Start committed the forwarder on") { (try? harness.savedConfig.dnsForwarderEnabled) == true }
        harness.hold.release()
        await harness.settle("the held proxy Start tore down what it brought up") {
            state.runtime.runtimeStatus.state == .stopped
                && self.hostEvents(harness, "config.workflow.held").contains { $0.contains("input_replaced") }
        }
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        await harness.settle("the app said why") { state.lastErrorMessage == AppState.startInterrupted }
        await harness.settle("the held Start's surfaces are cleared") {
            harness.machine.resolverFile(for: "corp.example") == nil && harness.machine.launchdEnvironment["HTTP_PROXY"] == nil
        }
        let applied = harness.machine.privilege.commands(matching: .applyDNS).count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.runtime.runtimeStatus.state, .stopped, "nothing retried the held Start")
        XCTAssertEqual(harness.machine.privilege.commands(matching: .applyDNS).count, applied)
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
        XCTAssertFalse(harness.journal.hasRecords(for: .launchdEnvironment))
        XCTAssertTrue(harness.loginItems.registrations.isEmpty, "an overtaken Start repairs no login item")
        await startProxy(state, harness)
        await harness.settle("the next Start applied its surfaces") { harness.machine.resolverFile(for: "corp.example") != nil }
    }

    /// A save held in the store when the quit begins does not keep the surfaces applied: the quit clears them within its total.
    func testAQuitWithASaveStillHeldClearsTheSurface() async throws {
        let held = HeldStateFileRead()
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageSystemProxy: true), prepare: { $0.stateFiles = held }
        )
        await startProxy(state, harness)
        await harness.settle("the Start's system proxy applied") { harness.journal.hasRecords(for: .systemProxy) }
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, _ in name == "read" }
        state.config.health.checkInterval = 59
        state.commitPendingEdit(trigger: .submit)
        await held.hold.waitUntilReached()
        XCTAssertTrue(state.beginQuit())
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            held.hold.release()
        }
        let finished = await state.finishQuit()
        guard case .settled(.completed)? = finished?.quit else { return XCTFail("the quit completed: \(String(describing: finished))") }
        XCTAssertFalse(harness.journal.hasRecords(for: .systemProxy), "the quit cleared what the Start applied")
        XCTAssertFalse(harness.machine.service("Wi-Fi").webProxy.enabled)
    }

    /// A quit while the opening's launch-option save is held, after the clients exist, fences the host through them at once: it does not
    /// wait for the opening, which never becomes ready.
    func testAQuitWhileTheOpeningsOverrideSaveIsHeldFencesTheHostThroughTheClients() async throws {
        let harness = try AppStateHarness(config: makeConfig(), platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        self.harness = harness
        let held = HeldStateFileRead()
        harness.stateFiles = held
        harness.overrides = AppLaunchOverrides(disableSystemProxy: true)
        let platformReads = LockedLog<String>()
        held.hold.arm(onQueueLabeled: ".configuration-store") { name, values in
            guard name == "read", values.first?.hasSuffix("platform.json") == true else { return false }
            platformReads.append(values[0])
            // The open's own read is the first; the launch option's save reads the file again.
            return platformReads.values.count > 1
        }
        let state = harness.launch()
        await held.hold.waitUntilReached()
        XCTAssertEqual(state.phase, .opening)
        XCTAssertNotNil(state.editor, "the clients and the editor exist; only the override's save is held")
        XCTAssertTrue(state.beginQuit())
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            held.hold.release()
        }
        let finished = await state.finishQuit()
        guard case .settled(.completed)? = finished?.quit else { return XCTFail("the quit completed: \(String(describing: finished))") }
        await state.opening?.value
        XCTAssertEqual(state.phase, .quitting, "the opening never finished ready")
        XCTAssertFalse(state.controlsEnabled)
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty, "nothing started")
    }

    /// The preferences final save is the quit's own, independent of the configuration's: beside a runtime draft the quit discards, the
    /// preferences edit is written and settles with its own verified receipt (decisions 0018 and 0025).
    func testQuitSavesAPreferencesEditIndependentlyOfTheConfiguration() async throws {
        let (harness, state) = try await ready()
        state.appPreferences.floatingWindowEnabled.toggle()
        let expected = state.appPreferences.floatingWindowEnabled
        state.config.proxy.port = 70_000
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.preferencesSettled(let receipt)) = result.preferences else {
            return XCTFail("the preferences final save settled: \(result.preferences)")
        }
        XCTAssertTrue(receipt.preferences.write.isVerified)
        XCTAssertEqual(try AppPreferencesPersistence.load(in: harness.environment).floatingWindowEnabled, expected)
        XCTAssertNotEqual(try harness.savedConfig.proxy.port, 70_000, "the start-blocking runtime draft was not the next launch's")
    }

    /// A quit while a Start's helper write is held fences the host at once; once the Start quiesces, the quit's cleanup clears what it
    /// applied, within the quit's total, and the journal keeps nothing.
    func testAQuitWhileAStartIsHeldClearsWhatItAppliedOnceItQuiesces() async throws {
        let (harness, state) = try await ready(
            platform: PlatformIntegrationConfig(manageEnvironmentVariables: true, manageDNSResolvers: true)
        )
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.applyDNS.rawValue }
        state.toggleProxy()
        let held = await harness.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(held, "the Start reached its resolver write")
        XCTAssertTrue(state.beginQuit())
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            harness.hold.release()
        }
        let finished = await state.finishQuit()
        guard case .settled(.completed)? = finished?.quit else { return XCTFail("the quit completed: \(String(describing: finished))") }
        XCTAssertNil(harness.machine.resolverFile(for: "corp.example"), "the quit cleared the entry file the held Start wrote")
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertFalse(harness.journal.hasRecords(for: .resolverFile))
        XCTAssertFalse(harness.journal.hasRecords(for: .launchdEnvironment))
    }

    /// While the proxy runs, a pause leaves a listener edit unsaved and the listener bound where it was; the commit saves it and the host
    /// rebinds once.
    func testAListenerEditWhileRunningWaitsForItsCommitAndRebindsOnce() async throws {
        let (harness, state) = try await ready(prepare: { $0.timing.settingsSaveDebounce = .milliseconds(10) })
        await startProxy(state, harness)
        let port = try XCTUnwrap(state.runtime.bindings.proxyPort)
        let next = try reserveLoopbackPort()
        state.config.localPort = next
        await harness.settle("the pause held the listener edit") {
            state.eventLog.events.contains { $0.event == "config.autosave_held" && ($0.detail ?? "").contains("listener_change") }
        }
        XCTAssertEqual(state.runtime.bindings.proxyPort, port, "the pause rebinds nothing")
        XCTAssertTrue(state.hasUnsavedEdit)
        state.commitPendingEdit(trigger: .submit)
        await harness.settle("the commit rebound the listener") { state.runtime.bindings.proxyPort == next }
        await harness.settle("its own receipt cleaned the draft") { !state.hasUnsavedEdit }
        XCTAssertEqual(try harness.savedConfig.localPort, next)
        guard await quitJoiningHostDiagnostics(state) else { return }
        XCTAssertEqual(hostEvents(harness, "config.proxy_restart").count, 1, "one rebind")
    }

    // MARK: Redaction on the update path

    /// A URL credential in a saved draft reaches none of the host's diagnostics: its events and its snapshot file.
    func testAnUpdatesCredentialReachesNoHostDiagnostic() async throws {
        let (harness, state) = try await ready()
        state.config.routing.pacURL = "https://user:TOKEN-HOST-7@pac.example.test/p.pac"
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertTrue(try String(contentsOf: harness.environment.configFile, encoding: .utf8).contains("pac.example.test"),
                      "the value was saved, so the absence is not vacuous")
        guard await quitJoiningHostDiagnostics(state) else { return }
        // A required read: a missing snapshot throws, so its absence is never read as a clean one.
        let snapshot = try String(contentsOf: harness.environment.snapshotFile, encoding: .utf8)
        XCTAssertFalse(snapshot.contains("TOKEN-HOST-7"))
        XCTAssertTrue(harness.hostEventsText.contains("config.workflow"), "the host recorded the save, so the absence is not vacuous")
        XCTAssertFalse(harness.hostEventsText.contains("TOKEN-HOST-7"))
    }
}

/// Saved commands racing each other through the actual framed client over the actual host, where the assertion needs the host itself.
@MainActor
final class RuntimeHostInteractiveRestartParityTests: XCTestCase {
    private var harness: InteractiveHostHarness?
    private var control: (any RuntimeClient)?
    private var stream: RuntimeSubscription?
    /// Settlements read from the stream for an operation not asked for yet, so the order in which two finish does not matter.
    private var finished: [ControlOperationID: ControlOperationOutcome] = [:]

    override func tearDown() async throws {
        stream?.cancel()
        stream = nil
        control = nil
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// The host over `platform`, its framed client under test limits, and one live stream past its baseline.
    private func connect(platform: PlatformIntegrationConfig, prepare: (InteractiveHostHarness) -> Void = { _ in }) async throws -> RuntimeHost {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        config.dnsForwarderEnabled = false
        let harness = try InteractiveHostHarness(config: config, platform: platform)
        self.harness = harness
        prepare(harness)
        let host = try await harness.makeHost()
        let control = try host.makeInMemoryControlClient(
            limits: try RuntimeServiceFixtures.hostLimits(subscribers: 3),
            clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        ).control
        self.control = control
        let stream = try await control.subscribe(.live, deadline: deadline())
        self.stream = stream
        _ = try await stream.next(deadline())
        return host
    }

    private func deadline() -> RuntimeDeadline { .after(.seconds(30), from: .now) }

    private func snapshot() async throws -> ControlRuntimeSnapshot {
        try await XCTUnwrap(control).readSnapshot(deadline: deadline())
    }

    private func submit(_ command: ControlRuntimeCommand) async throws -> ControlOperationID? {
        let admission = try await XCTUnwrap(control).submit(
            command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: try await snapshot().stamp.incarnation,
            deadline: deadline()
        )
        guard case .accepted(let operation) = admission else { return nil }
        return operation
    }

    private func outcome(of operation: ControlOperationID) async throws -> ControlOperationOutcome? {
        if let known = finished.removeValue(forKey: operation) { return known }
        let stream = try XCTUnwrap(stream)
        for _ in 0..<256 {
            guard case .operationFinished(let done) = try await stream.next(deadline()) else { continue }
            if done.operationID == operation { return done.outcome }
            finished[done.operationID] = done.outcome
        }
        return nil
    }

    /// A DNS Stop admitted while the explicit DNS Start's system-DNS apply is held fences it: the apply already started completes, the Stop's
    /// restore lands after it and gives the interfaces back the user's servers, the overtaken Start reports no started DNS and arms no health
    /// timer, and the saved intent is the Stop's disable.
    func testADNSStopWhileItsStartAppliesRestoresSystemDNSAndArmsNoHealthTimer() async throws {
        let host = try await connect(platform: PlatformIntegrationConfig(manageSystemDNS: true)) { harness in
            harness.machine.describe("Wi-Fi") { $0.dnsServers = ["192.0.2.53"] }
        }
        let harness = try XCTUnwrap(self.harness)
        // The relay start inside the system-DNS apply, after the capture and the forwarder's bind.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.startDNSRelay.rawValue }
        let observed = try await snapshot().stamp.modules
        let modules = try XCTUnwrap(observed)
        let admittedStart = try await submit(.start(.dns, ifModuleRevision: modules.dns))
        let start = try XCTUnwrap(admittedStart)
        let reached = await harness.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached, "the Start reached its system-DNS apply")
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        let admittedStop = try await submit(.stop(.dns))
        let stop = try XCTUnwrap(admittedStop, "the Stop is admitted, and fences, while the Start's apply is held")
        harness.hold.release()
        let started = try await outcome(of: start)
        _ = try await outcome(of: stop)

        if case .configurationSettled(let receipt)? = started {
            XCTAssertFalse(receipt.modules.contains(ControlModuleReceipt(module: .dns, result: .started)),
                           "an overtaken Start reports no started DNS: \(receipt.modules)")
        }
        XCTAssertFalse(harness.machine.dnsRelayRunning, "the Stop's restore landed after the Start's apply")
        XCTAssertEqual(harness.machine.service("Wi-Fi").dnsServers, ["192.0.2.53"], "the interfaces have the user's servers back")
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertNil(host.dnsHealthTimer, "the fenced Start armed no health timer")
        XCTAssertEqual(harness.savedDNSEnabled, false, "the saved intent is the Stop's disable")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(host.dnsHealthTimer, "and nothing armed one after the Stop settled")
        XCTAssertFalse(harness.machine.dnsRelayRunning)
    }

    /// Repeated DNS Stops while the first is held at its relay stop run one teardown: the relay is stopped once, and every Stop settles.
    func testRepeatedDNSStopsWhileTheFirstIsHeldStopTheRelayOnce() async throws {
        let host = try await connect(platform: PlatformIntegrationConfig(manageSystemDNS: true))
        let harness = try XCTUnwrap(self.harness)
        let observed = try await snapshot().stamp.modules
        let modules = try XCTUnwrap(observed)
        let admittedStart = try await submit(.start(.dns, ifModuleRevision: modules.dns))
        _ = try await outcome(of: try XCTUnwrap(admittedStart))
        XCTAssertTrue(harness.machine.dnsRelayRunning, "DNS runs with its relay")
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.stopDNSRelay.rawValue }
        let first = try await submit(.stop(.dns))
        let reached = await harness.hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached, "the first Stop reached its relay stop")
        var later: [ControlOperationID] = []
        for _ in 0..<3 {
            if let operation = try await submit(.stop(.dns)) { later.append(operation) }
        }
        harness.hold.release()
        _ = try await outcome(of: try XCTUnwrap(first))
        for operation in later { _ = try await outcome(of: operation) }
        XCTAssertEqual(harness.machine.privilege.commands(matching: .stopDNSRelay).count, 1, "one relay teardown")
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
    }

    func testARestartOvertakenByAStopReportsNoStartedProxy() async throws {
        let host = try await connect(platform: PlatformIntegrationConfig(manageSystemProxy: true))
        let harness = try XCTUnwrap(self.harness)
        let observed = try await snapshot().stamp.modules
        let modules = try XCTUnwrap(observed)
        let admittedStart = try await submit(.start(.proxy, ifModuleRevision: modules.proxy))
        let start = try XCTUnwrap(admittedStart)
        _ = try await outcome(of: start)

        harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.setWebProxyEndpoint.rawValue }
        let lifecycle = try await snapshot().stamp.lifecycleRevision
        let admittedRestart = try await submit(.restart(.proxy, ifLifecycleRevision: lifecycle))
        let restart = try XCTUnwrap(admittedRestart)
        await harness.hold.waitUntilReached()
        let admittedStop = try await submit(.stop(.proxy))
        let stop = try XCTUnwrap(admittedStop)
        harness.hold.release()
        let restarted = try await outcome(of: restart)
        _ = try await outcome(of: stop)
        if case .configurationSettled(let receipt)? = restarted {
            XCTAssertFalse(receipt.modules.contains(ControlModuleReceipt(module: .proxy, result: .started)),
                           "an overtaken Restart reports no started proxy: \(receipt.modules)")
        }
        XCTAssertNil(host.status().bindings.proxyPort, "the Stop leaves no listener")
        XCTAssertFalse(harness.machine.service("Wi-Fi").webProxy.enabled, "the Stop's clear landed after the held apply")
    }
}

/// A loopback TCP port held open with a listener for the test's lifetime, so a Start configured on it cannot bind.
final class OccupiedLoopbackPort {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var chosen = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &chosen) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard bound == 0, named == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: chosen.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}
