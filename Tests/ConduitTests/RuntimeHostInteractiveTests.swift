// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest
import ConduitShared
import ProxyAuth
import ProxyControlBridge
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import RuntimeEvents

/// The token provider this file's hosts inject: a Kerberos handshake fails here, and the system GSS stack is never reached.
private final class RefusingGSS: GSSTokenProvider, @unchecked Sendable {
    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        throw UnplannedFakeEffect(effect: "GSS token for \(host)")
    }

    func resetContext() {}
}

/// A UDP socket the test holds on a loopback port it chose, so a DNS forwarder's bind on that port fails as a contended port does.
private final class HeldUDPPort {
    let port: Int
    private let descriptor: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
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
        guard bound == 0, named == 0 else {
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

/// A free loopback TCP port, found by binding and releasing it, for a tunnel listener whose port the configuration must name.
private func freeTCPPort() throws -> Int {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { Darwin.close(fd) }
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
    guard bound == 0, named == 0 else { throw CocoaError(.fileWriteUnknown) }
    return Int(UInt16(bigEndian: chosen.sin_port))
}

/// One scratch root, its fakes and the one host built over it. `tearDown` stops, settles and flushes the host before the root goes.
@MainActor
private final class Harness {
        let session: StateRootSession
        let environment: RuntimeEnvironment
        let machine: FakeMachine
        let hold = HeldCall()
        let vpn = FakeVPNStatusObserver()
        /// The PAC evaluator the orchestrator fetches through; a test that holds a Start before its bind names a `HeldPACFetch`.
        var pacEvaluator: any PacEvaluator = FakePacEvaluator()
        private let directory: URL
        private(set) var host: RuntimeHost?

        init(config: ProxyConfig, platform: PlatformIntegrationConfig) throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pm-interactive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true)
            let fixture = RuntimeEnvironment.isolated(stateDirectory: directory)
            try ProxyConfigPersistence.save(config, in: fixture)
            try PlatformConfigPersistence.save(platform, in: fixture)
            try AppPreferencesPersistence.save(AppPreferences(), in: fixture)
            session = try acquireScratchStateRoot(fixture)
            environment = session.environment
            machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver", isDirectory: true))
        }

        func makeHost() async throws -> RuntimeHost {
            precondition(host == nil, "one host per harness")
            let machine = self.machine
            let hold = self.hold
            let vpn = self.vpn
            let built = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: true,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: { XCTFail("the runtime host ended the process") },
                effects: RuntimeHostEffects(
                    privilege: { _ in RuntimePrivilegeAdapters(client: HoldingPrivilegeClient(base: machine, hold: hold), helperStatus: nil) },
                    credentials: InMemorySecretStore(),
                    kerberosTicketRecovery: FakeKerberosTicketRecovery(),
                    gss: .injected { RefusingGSS() },
                    pacEvaluator: pacEvaluator,
                    portHolderProbe: FakeListenerPortHolderProbe(),
                    loopbackPortProbe: FakeLoopbackPortProbe().isServed(port:),
                    commandRunner: { launchPath, arguments in
                        hold.pass(launchPath, arguments)
                        return try machine.run(launchPath, arguments)
                    },
                    dnsResponds: FakeDNSProbe().responds(onPort:),
                    networkPath: FakeNetworkPathObserver(),
                    networkLocation: FakeNetworkLocationObserver(),
                    networkLocationStoreFactory: { _ in nil },
                    vpnStatusMonitor: { _, _ in vpn },
                    homeDirectory: directory.appendingPathComponent("home", isDirectory: true),
                    resolverDirectory: machine.resolverDirectory.path,
                    stateFiles: StateFileAccess.operatingSystem()
                ),
                reapplyRetrySchedule: ConfigReapplyRetry.Schedule(delays: [.seconds(3600)]),
                splitDNSHelperCheckInterval: .seconds(3600)
            )
            await built.awaitLaunchRecovery()
            host = built
            return built
        }

        func tearDown() async {
            hold.release()
            if let host {
                await host.stopRuntime()
                let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
                let report = await host.flushEvents()
                XCTAssertEqual(settled, .settled, "the harness's host settles before its root is released")
                // As `DaemonHarness`: both record queues drained, and the snapshot write physically complete.
                let drained = report.audit == .drained && (report.events == .drained || report.eventsRetry == .drained)
                let snapshotSettled: Bool = switch report.snapshot {
                case .current: true
                case .refused, .writeFailed, .noSubmission: report.snapshotEvent == .confirmed
                case .timedOut, .busy, .skippedBudget, .cancelled, .exhausted: false
                }
                guard settled == .settled, drained, snapshotSettled else {
                    XCTFail("the harness's shutdown is unconfirmed: its host and root are kept")
                    return
                }
            }
            host = nil
            guard releaseScratchStateRoot(session) == .released else { return }
            removeScratch([directory])
        }

        var savedDNSEnabled: Bool? {
            (try? ProxyConfigPersistence.load(in: environment, allowMissing: false))?.dnsForwarderEnabled
        }

        func typedEvents() -> [RuntimeEventPayload] {
            host?.orchestrator.eventLog.events.compactMap(\.typed) ?? []
        }
}

/// Ephemeral listeners, one split-DNS entry, and the switches a test names.
@MainActor
private func makeHarness(
    platform: PlatformIntegrationConfig,
    dnsForwarderEnabled: Bool,
    dnsForwarderPort: Int = 0,
    tunnels: [TunnelDefinition] = [],
    heldPAC: HeldPACFetch? = nil
) throws -> Harness {
    var config = GenericDefaults.shared.makeConfig()
    config.localPort = 0
    config.dnsForwarderPort = dnsForwarderPort
    config.dnsForwarderEnabled = dnsForwarderEnabled
    config.localPACEnabled = false
    config.pacRoutingEnabled = heldPAC != nil
    if heldPAC != nil { config.pacURL = "http://pac.example.test/held.pac" }
    config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
    config.tunnelDefinitions = tunnels
    config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
    let harness = try Harness(config: config, platform: platform)
    if let heldPAC { harness.pacEvaluator = heldPAC }
    return harness
}

/// The operating system's state-file access, with one armed configuration read that parks until `release()`, so a test can keep the
/// store's one slot busy at a chosen point. Unarmed, it passes every call through.
private final class ParkedReadStateFiles: StateFileAccessing, @unchecked Sendable {
    private let inner = StateFileAccess.operatingSystem()
    private let condition = NSCondition()
    private var armed = false
    private var parked = false
    private var released = false

    func arm() {
        condition.withLock { armed = true }
    }

    var isParked: Bool { condition.withLock { parked } }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }

    func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
        condition.withLock {
            guard armed else { return }
            armed = false
            parked = true
            while !released { condition.wait() }
            parked = false
        }
        return inner.readConfigurationFile(file, limit: limit)
    }

    func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
        inner.replaceConfigurationFile(file, bytes: bytes)
    }

    func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
        inner.entryPresence(file)
    }
}

/// A TCP listener the test holds on a loopback port it chose, so a tunnel's bind on that port fails as a contended port does.
private final class HeldTCPListener {
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

/// The machine surfaces the module tests manage: the system proxy and environment for the proxy, the system DNS for DNS.
private let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)

/// The per-module lifecycle facade of the actual `RuntimeHost` (decisions 0031, 0035, 0036 and 0037), over a `FakeMachine` and a scratch
/// root. Each test drives the package facade the daemon and `pm-sim` use, and reads the machine, the files and the typed events.
@MainActor
final class RuntimeHostInteractiveTests: XCTestCase {
    private var harness: Harness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func launch(
        platform: PlatformIntegrationConfig,
        dnsForwarderEnabled: Bool,
        dnsForwarderPort: Int = 0,
        tunnels: [TunnelDefinition] = [],
        heldPAC: HeldPACFetch? = nil
    ) async throws -> (RuntimeHost, Harness) {
        let harness = try makeHarness(platform: platform, dnsForwarderEnabled: dnsForwarderEnabled,
                                      dnsForwarderPort: dnsForwarderPort, tunnels: tunnels, heldPAC: heldPAC)
        self.harness = harness
        return (try await harness.makeHost(), harness)
    }

    // MARK: - Scoped Stop

    /// A proxy Stop takes only the proxy's lane: the listener and its surfaces go, DNS and its system DNS stay, and so do the runtime's
    /// observers. A session DNS Stop then fences, restores system DNS and saves its disable through the runtime-only commit.
    func testAProxyStopLeavesDNSRunningAndASessionDNSStopSavesItsDisable() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        try await host.startRuntime()
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertTrue(harness.machine.dnsRelayRunning)

        let proxyStop = await host.stopProxy()
        XCTAssertEqual(proxyStop, RuntimeModuleStopOutcome(stopped: [.proxy], dnsSave: nil))
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy, "the proxy's surfaces are cleared")
        XCTAssertNil(harness.machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState, .running, "DNS keeps running")
        XCTAssertTrue(harness.machine.dnsRelayRunning, "and so does the system DNS pointed at it")
        harness.vpn.emit(.connected)
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.snapshot.vpnState, .connected, "the observers follow the module that stays up")

        let dnsStop = await host.stopDNS()
        XCTAssertEqual(dnsStop, RuntimeModuleStopOutcome(stopped: [.dns], dnsSave: .saved))
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertFalse(harness.machine.dnsRelayRunning, "system DNS is restored")
        XCTAssertEqual(harness.savedDNSEnabled, false, "the session Stop's disable is saved")
        XCTAssertTrue(harness.typedEvents().contains(.configWorkflow(.committed(ConfigurationWorkflowCommitted(
            file: .runtime, write: .persisted(reportedError: false)
        )))))
    }

    /// A tunnels Stop takes only the tunnels' lane; the proxy keeps its listener and its system proxy.
    func testATunnelsStopLeavesTheProxyRunning() async throws {
        let port = try freeTCPPort()
        let (host, harness) = try await launch(
            platform: PlatformIntegrationConfig(manageSystemProxy: true),
            dnsForwarderEnabled: false,
            tunnels: [TunnelDefinition(localPort: port, remoteHost: "127.0.0.1", remotePort: 9)]
        )
        let started = try await host.startTunnels()
        XCTAssertEqual(started.modules, PrivateModuleSlots(proxy: nil, dns: nil, tunnels: .started))
        XCTAssertFalse(host.orchestrator.snapshot.bindings.tunnels.isEmpty, "the tunnel listens")
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .stopped, "a tunnels Start starts no proxy")
        let proxy = try await host.startProxy(conditionalDNS: false)
        XCTAssertEqual(proxy.modules.proxy, .started)
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)

        let stop = await host.stopTunnels()
        XCTAssertEqual(stop.stopped, [.tunnels])
        XCTAssertTrue(host.orchestrator.snapshot.bindings.tunnels.isEmpty)
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the proxy keeps running")
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertTrue(
            host.orchestrator.eventLog.events.allSatisfy { !($0.detail ?? "").contains("operation=proxy_stop") },
            "no proxy operation was stopped"
        )
    }

    // MARK: - Conditional DNS (decision 0036)

    /// A proxy Start's companion starts DNS that is configured on and unfenced, from the Start's verified pair, without writing DNS's
    /// intent or moving its revision.
    func testAProxyStartsCompanionStartsConfiguredDNSWithoutWritingIntent() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        let before = host.moduleRevisions
        let saved = try Data(contentsOf: harness.environment.configFile)

        let outcome = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(outcome, RuntimeModuleStartOutcome(
            modules: PrivateModuleSlots(proxy: .started, dns: nil, tunnels: nil), conditionalDNS: .started
        ))
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertTrue(harness.machine.dnsRelayRunning)
        XCTAssertEqual(host.moduleRevisions.dns, before.dns, "the companion changes no DNS control")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), saved, "and writes no intent")
    }

    /// Disabled, already running and fenced DNS are each a typed no-op, and none of them activates anything.
    func testTheCompanionIsATypedNoOpForDisabledRunningOrFencedDNS() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: false)
        let disabled = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(disabled.conditionalDNS, .notConfigured)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertFalse(harness.machine.dnsRelayRunning)

        let dns = try await host.startDNS()
        XCTAssertEqual(dns.modules.dns, .started, "an explicit DNS Start enables it")
        XCTAssertEqual(harness.savedDNSEnabled, true, "and stages its enable in the shared write")
        let running = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(running.conditionalDNS, .alreadyActive)

        _ = await host.stopDNS()
        let fenced = try await host.restartProxy()
        XCTAssertEqual(fenced.modules.proxy, .started, "the restart brings the proxy back up")
        XCTAssertEqual(fenced.conditionalDNS, .fenced, "and its companion leaves the stopped DNS down")
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(harness.savedDNSEnabled, false)
    }

    /// A companion whose forwarder cannot bind reports its own failure: the proxy stays up, the system DNS it captured is restored, and
    /// DNS's configured intent and fence are left as they were, so a later explicit Start is not refused or replayed.
    func testAFailedCompanionLeavesTheProxyUpAndRestoresSystemDNS() async throws {
        let held = try HeldUDPPort()
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true, dnsForwarderPort: held.port)
        let outcome = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(outcome.modules.proxy, .started)
        XCTAssertEqual(outcome.conditionalDNS, .failed)
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the proxy stays up")
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertFalse(harness.machine.dnsRelayRunning, "no interface is left pointed at a forwarder that is not listening")
        XCTAssertEqual(host.workflow.dnsIntent.configured, true, "the failed companion keeps DNS's configured intent")
        XCTAssertEqual(host.workflow.dnsIntent.fenced, false, "and sets no fence")
        XCTAssertEqual(harness.savedDNSEnabled, true)
        withExtendedLifetime(held) {}
    }

    /// A DNS Stop admitted while the proxy Start applies its surfaces fences DNS at once; its own platform work queues behind the
    /// proxy's, so its disable lands after the proxy Start has completed from its verified pair. The completed proxy reports its fact,
    /// and the companion then finds the fence and starts nothing.
    func testADNSStopWhileTheProxyStartAppliesFencesOnlyItsCompanion() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startProxy(conditionalDNS: true) }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)

        let stop = Task { await host.stopDNS() }
        for _ in 0..<5_000 where host.pendingAdmissions < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.workflow.dnsIntent.fenced, true, "the Stop fences before anything it awaits")
        harness.hold.release()
        let outcome = try await start.value
        let stopped = await stop.value
        XCTAssertEqual(outcome.modules.proxy, .started, "an unrelated Stop leaves the proxy Start's progress")
        XCTAssertEqual(outcome.conditionalDNS, .fenced)
        XCTAssertEqual(stopped.dnsSave, .saved)
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertEqual(harness.savedDNSEnabled, false)
    }

    /// Decision 0037's strict capture: a DNS Stop whose disable save lands while an authorized proxy Start is still before its bind
    /// replaces the runtime baseline the Start's receipt names, so the Start's remaining effects hold. It reports its typed supersession,
    /// leaves no listener and no surface, and the saved disable stays a fact.
    func testADNSDisableSavedBeforeTheProxyBindsHoldsTheProxyStart() async throws {
        let fetch = HeldPACFetch()
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true, heldPAC: fetch)
        let start = Task { try await host.startProxy(conditionalDNS: true) }
        for _ in 0..<5_000 where !fetch.isHeld {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(fetch.isHeld, "the proxy Start is held on its PAC fetch, after its authorization and before its bind")

        let stop = await host.stopDNS()
        XCTAssertEqual(stop.dnsSave, .saved, "nothing holds the DNS Stop's own work")
        fetch.release()
        do {
            _ = try await start.value
            XCTFail("the replaced input holds the proxy Start")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .superseded)
        }
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the held Start tore down the proxy it brought up")
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertEqual(harness.savedDNSEnabled, false, "the completed save is kept")
        XCTAssertTrue(harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .inputReplaced
        )))))
        // The next explicit Start captures the saved disable.
        let next = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(next.modules.proxy, .started)
        XCTAssertEqual(next.conditionalDNS, .fenced)
    }

    /// A proxy Stop that takes the proxy lane while the whole-host Start is held on its PAC fetch, after authorization, makes the proxy
    /// start throw. That exit ends the authority of every member not yet settled under the Start's own ticket: DNS and tunnels, which it
    /// never brought up, keep no grant from the aborted group, their prior permission and fence come back, and nothing listens.
    func testAStartThatThrowsAfterAuthorizationLeavesNoGrantForItsUnsettledMembers() async throws {
        let fetch = HeldPACFetch()
        let (host, harness) = try await launch(
            platform: proxyAndDNS, dnsForwarderEnabled: true,
            tunnels: [TunnelDefinition(localPort: try freeTCPPort(), remoteHost: "127.0.0.1", remotePort: 9)],
            heldPAC: fetch
        )
        let start = Task { try await host.startRuntime() }
        for _ in 0..<5_000 where !fetch.isHeld {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(fetch.isHeld, "the Start is held on its PAC fetch")
        let ticket = try XCTUnwrap(host.laneEffects.proxy?.ticket, "the Start holds the lanes")
        XCTAssertTrue(ControlModule.allCases.allSatisfy { host.workflow.holds($0, for: ticket) }, "every member was authorized")

        let stop = Task { await host.stopProxy() }
        for _ in 0..<5_000 where host.pendingAdmissions < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        fetch.release()
        let stopped = await stop.value
        do {
            try await start.value
            XCTFail("the Start whose proxy lane was taken does not report success")
        } catch {
            XCTAssertNotNil(error as? RuntimeStartRefusal, "it reports its typed refusal, got \(error)")
        }
        XCTAssertEqual(stopped.stopped, [.proxy])
        for module in ControlModule.allCases {
            XCTAssertFalse(host.workflow.holds(module, for: ticket), "\(module) keeps no grant from the aborted group")
        }
        XCTAssertFalse(host.workflow.dnsIntent.fenced, "DNS's prior fence, none, is restored")
        XCTAssertTrue(host.workflow.dnsIntent.configured, "and its configured intent is kept")
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertTrue(host.orchestrator.snapshot.bindings.tunnels.isEmpty)
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        // No grant is left for a companion: a later proxy-only Start finds DNS unstarted and configured, and starts it itself.
        let next = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(next.conditionalDNS, .started)
    }

    /// The same whole-combined rule when the proxy Stop arrives while the whole-host Start's proxy surfaces are out on the platform queue:
    /// the Start is held whole, DNS and tunnels are never started and keep no grant, and the Stop's clears land after the apply.
    func testAProxyStopWhileTheWholeHostStartAppliesHoldsItWhole() async throws {
        let (host, harness) = try await launch(
            platform: proxyAndDNS, dnsForwarderEnabled: true,
            tunnels: [TunnelDefinition(localPort: try freeTCPPort(), remoteHost: "127.0.0.1", remotePort: 9)]
        )
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startRuntime() }
        await harness.hold.waitUntilReached()
        let ticket = try XCTUnwrap(host.laneEffects.proxy?.ticket, "the Start holds the lanes")
        let stop = Task { await host.stopProxy() }
        for _ in 0..<5_000 where host.pendingAdmissions < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        harness.hold.release()
        let stopped = await stop.value
        do {
            try await start.value
            XCTFail("the Start one of whose members was stopped does not report success")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .superseded)
        }
        XCTAssertEqual(stopped.stopped, [.proxy])
        for module in ControlModule.allCases {
            XCTAssertFalse(host.workflow.holds(module, for: ticket), "\(module) keeps no grant from the held group")
        }
        XCTAssertFalse(host.workflow.dnsIntent.fenced)
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running, "DNS was never started")
        XCTAssertTrue(host.orchestrator.snapshot.bindings.tunnels.isEmpty, "and neither were tunnels")
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy, "the Stop's clear landed after the apply")
        XCTAssertFalse(harness.machine.dnsRelayRunning)
    }

    // MARK: - Tunnels results

    /// A tunnels Start whose saved input names no enabled tunnel starts nothing and says so, and one whose every bind fails reports its
    /// failure and restores its prior fence: after a whole-host Stop every module stays fenced, so a reload still holds.
    func testATunnelsStartReportsNothingConfiguredApartFromAFailedBind() async throws {
        let held = try HeldTCPListener()
        let (host, harness) = try await launch(
            platform: PlatformIntegrationConfig(manageSystemProxy: true),
            dnsForwarderEnabled: false,
            tunnels: [TunnelDefinition(localPort: held.port, remoteHost: "127.0.0.1", remotePort: 9, enabled: false)]
        )
        let nothing = try await host.startTunnels()
        XCTAssertEqual(nothing.modules, PrivateModuleSlots(proxy: nil, dns: nil, tunnels: .notConfigured))
        XCTAssertTrue(host.orchestrator.snapshot.bindings.tunnels.isEmpty)

        var config = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
        config.tunnelDefinitions = [TunnelDefinition(localPort: held.port, remoteHost: "127.0.0.1", remotePort: 9)]
        try ProxyConfigPersistence.save(config, in: harness.environment)
        await host.reloadConfiguration()
        await host.stopRuntime()
        XCTAssertTrue(host.workflow.stopFenced)

        let failed = try await host.startTunnels()
        XCTAssertEqual(failed.modules.tunnels, .failed, "every bind failed, so the Start does not claim success")
        XCTAssertTrue(host.orchestrator.snapshot.bindings.tunnels.isEmpty)
        XCTAssertTrue(host.workflow.stopFenced, "the failed member's prior fence is restored")
        withExtendedLifetime(held) {}
    }

    /// Decision 0037 for the companion: it acts on its parent's verified pair. A reload that adopts B while the companion, after the proxy
    /// completed, is out capturing the prior DNS servers replaces that pair, so the companion holds before its next machine effect and
    /// tears down what it started: the completed proxy stays up, no system DNS points anywhere, and nothing is rebound to B. The next
    /// explicit Restart captures B.
    func testAReloadThatReplacesThePairHoldsTheCompanionAndKeepsTheCompletedProxy() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        // The companion's first read of the machine's DNS servers, once the proxy is up.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-getdnsservers"
        }
        let start = Task { try await host.startProxy(conditionalDNS: true) }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(harness.hold.reachedOnMainThread)
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "the proxy completed before its companion")

        var edited = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
        edited.profileName = "B"
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        let reload = Task { await host.reloadConfiguration() }
        for _ in 0..<5_000 where host.status().profileName != "B" || host.passesWaitingForLifecycle == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(host.status().profileName, "B", "the reload adopted B")
        XCTAssertGreaterThan(host.passesWaitingForLifecycle, 0, "and its apply waits for the lanes")
        harness.hold.release()

        let outcome = try await start.value
        await reload.value
        XCTAssertEqual(outcome.modules.proxy, .started, "the completed proxy is a fact")
        XCTAssertEqual(outcome.conditionalDNS, .superseded, "the companion holds on the replaced pair")
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "and the proxy stays up")
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running, "no forwarder was bound from A")
        XCTAssertFalse(harness.machine.dnsRelayRunning, "no system DNS points at one")
        XCTAssertTrue(harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .inputReplaced
        )))))
        XCTAssertFalse(host.workflow.dnsIntent.fenced, "DNS's intent and fence are as they were")
        // No stale effect happened and was then cleaned up: the held companion never started the relay or pointed an interface at it.
        let privilege = harness.machine.privilege
        XCTAssertTrue(privilege.commands(matching: .startDNSRelay).isEmpty, "the held companion started no relay")
        XCTAssertFalse(
            privilege.commands(matching: .setDNSServers).contains { $0.contains { $0.hasPrefix("127.0.0.1") } },
            "and pointed no interface at the loopback forwarder"
        )

        let restart = try await host.restartProxy()
        XCTAssertEqual(restart.modules.proxy, .started)
        XCTAssertEqual(restart.conditionalDNS, .started, "a new explicit Restart's companion starts DNS from its own pair")
        XCTAssertEqual(host.heldRuntimeConfig.profileName, "B", "which captured B")
        XCTAssertTrue(harness.machine.dnsRelayRunning)
    }

    // MARK: - Whole-request revisions (decision 0035)

    /// A request that names a revision a newer Stop moved is refused whole, in its admission turn: nothing is written, no intent changes,
    /// nothing starts, and the typed hold names the stale revision.
    func testAStaleRevisionRefusesTheWholeRequestBeforeAnyWrite() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        let observed = host.moduleRevisions
        _ = await host.stopDNS()
        let afterStop = host.moduleRevisions
        let saved = try Data(contentsOf: harness.environment.configFile)

        do {
            _ = try await host.startProxy(
                conditionalDNS: true,
                expecting: PrivateModuleSlots(proxy: observed.proxy, dns: observed.dns, tunnels: nil)
            )
            XCTFail("a stale DNS revision refuses the combined request")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .stale(.dns))
        }
        XCTAssertEqual(host.moduleRevisions, afterStop, "the refusal changes no revision")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), saved, "and writes nothing")
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running, "and starts nothing")
        XCTAssertFalse(harness.machine.service("Wi-Fi").routesThroughAProxy)
        XCTAssertTrue(harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .staleRevision
        )))))

        // The fresh revisions are admitted.
        let fresh = try await host.startProxy(
            conditionalDNS: true,
            expecting: PrivateModuleSlots(proxy: afterStop.proxy, dns: afterStop.dns, tunnels: nil)
        )
        XCTAssertEqual(fresh.modules.proxy, .started)
        XCTAssertEqual(fresh.conditionalDNS, .fenced, "the session Stop's fence still holds the companion")
    }

    // MARK: - Held Start leaves no authority (decisions 0035 and 0037)

    /// A reload that replaces an explicit DNS Start's captured pair while it applies holds it: DNS is torn down, its prior fence comes back,
    /// and no later companion can activate it.
    func testAHeldExplicitDNSStartLeavesNoPermissionForALaterCompanion() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: false)
        _ = await host.stopDNS()
        XCTAssertEqual(host.workflow.dnsIntent.fenced, true)
        // The DNS start's first platform block: the capture of the prior DNS servers.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let start = Task { try await host.startDNS() }
        await harness.hold.waitUntilReached()

        var edited = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
        edited.profileName = "Edited while the DNS Start applies"
        try ProxyConfigPersistence.save(edited, in: harness.environment)
        let reload = Task { await host.reloadConfiguration() }
        for _ in 0..<5_000 where host.status().profileName != edited.profileName {
            try await Task.sleep(for: .milliseconds(1))
        }
        harness.hold.release()
        do {
            _ = try await start.value
            XCTFail("the replaced input holds the DNS Start")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .superseded)
        }
        await reload.value
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running, "the held Start left no forwarder")
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertEqual(host.workflow.dnsIntent.fenced, true, "its prior fence is back")
        XCTAssertTrue(harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .inputReplaced
        )))))

        let proxy = try await host.startProxy(conditionalDNS: true)
        XCTAssertEqual(proxy.modules.proxy, .started)
        XCTAssertEqual(proxy.conditionalDNS, .fenced, "the held Start left no permission a companion could act on")
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
    }

    // MARK: - Owed disable fulfilled by a later write (decision 0015)

    /// A session DNS Stop whose own save did not run owes its disable. A proxy Start admitted after it stages that same false in the
    /// shared write; once the write verifies the obligation ends and the fence stays. Through the actual workflow and store.
    func testAVerifiedSharedWriteOfTheOwedDisableEndsTheObligationAndKeepsTheFence() async throws {
        let harness = try makeHarness(platform: proxyAndDNS, dnsForwarderEnabled: true)
        self.harness = harness
        let store = ConfigurationStore(session: harness.session, access: StateFileAccess.operatingSystem(),
                                       work: PlatformWork(label: "test.owed-disable"))
        let workflow = RuntimeConfigurationWorkflow(store: store, startupAllowsMissing: true)
        _ = try await workflow.open()
        workflow.admitStop([.dns], reason: .session)

        let ticket = try workflow.admitStart(PrivateModuleSlots(proxy: .start, dns: .none, tunnels: .none)).get()
        guard case .ready(let prepared) = await workflow.prepareStart(ticket).preparation else {
            return XCTFail("the proxy Start prepares")
        }
        XCTAssertFalse(prepared.input.runtime.dnsForwarderEnabled, "the shared write stages the owed disable")
        XCTAssertEqual(harness.savedDNSEnabled, false)
        let save = await workflow.saveOwedDNSStop()
        XCTAssertEqual(save.save, .notOwed, "the verified shared write ended the obligation")
        XCTAssertTrue(workflow.dnsIntent.fenced, "and the fence stays")
        workflow.retire(prepared.ticket)
    }

    /// A session DNS Stop whose disable save finds the store's one slot taken writes nothing, reports the typed Stop hold, keeps its
    /// fence and stays owed; nothing retries it, and the next save once the slot is free verifies it. Through the actual workflow and store.
    func testABusyStoreHoldsTheOwedDisableWithItsTypedStopCauseAndKeepsTheFence() async throws {
        let harness = try makeHarness(platform: proxyAndDNS, dnsForwarderEnabled: true)
        self.harness = harness
        let files = ParkedReadStateFiles()
        let store = ConfigurationStore(session: harness.session, access: files, work: PlatformWork(label: "test.busy-disable"))
        let workflow = RuntimeConfigurationWorkflow(store: store, startupAllowsMissing: true)
        _ = try await workflow.open()
        let saved = try Data(contentsOf: harness.environment.configFile)
        workflow.admitStop([.dns], reason: .session)

        // An unchanged reload parks in the store, so its one slot is busy.
        files.arm()
        let reload = Task { await workflow.reload(capturedAt: workflow.generation) }
        for _ in 0..<5_000 where !files.isParked {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(files.isParked, "the reload holds the store's slot")
        let busy = await workflow.saveOwedDNSStop()
        XCTAssertEqual(busy.save, .owed)
        XCTAssertEqual(busy.events, [.held(ConfigurationWorkflowHeld(phase: .stop, input: .runtime, reason: .storeBusy))])
        XCTAssertEqual(ControlConfigWorkflowEvent(busy.events[0]).detail, "phase=stop component=runtime reason=store_busy")
        XCTAssertTrue(workflow.dnsIntent.fenced, "the fence stays")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), saved, "nothing was written")
        files.release()
        _ = await reload.value

        let later = await workflow.saveOwedDNSStop()
        XCTAssertEqual(later.save, .saved, "the obligation was kept owed for the next attempt")
        XCTAssertEqual(harness.savedDNSEnabled, false)
        XCTAssertTrue(workflow.dnsIntent.fenced)
    }

    /// Through the actual workflow and store: a proxy request with its companion, prepared while another request's explicit DNS Start is
    /// still pending, commits the durable false, not that Start's unverified true. Once the DNS Start is retired, the proxy request is
    /// authorized and its companion is not allowed to activate anything.
    func testAProxyRequestPreparedBesideAPendingDNSStartPersistsNoEnable() async throws {
        let harness = try makeHarness(platform: proxyAndDNS, dnsForwarderEnabled: false)
        self.harness = harness
        let store = ConfigurationStore(session: harness.session, access: StateFileAccess.operatingSystem(),
                                       work: PlatformWork(label: "test.pending-dns-scope"))
        let workflow = RuntimeConfigurationWorkflow(store: store, startupAllowsMissing: true)
        _ = try await workflow.open()
        let dnsStart = try workflow.admitStart(PrivateModuleSlots(proxy: .none, dns: .start, tunnels: .none)).get()
        let proxy = try workflow.admitStart(PrivateModuleSlots(proxy: .start, dns: .conditionalActivation, tunnels: .none)).get()

        guard case .ready(let prepared) = await workflow.prepareStart(proxy).preparation else {
            return XCTFail("the proxy request prepares")
        }
        XCTAssertFalse(prepared.input.runtime.dnsForwarderEnabled, "its input keeps DNS's durable false")
        XCTAssertEqual(harness.savedDNSEnabled, false, "and so does the file")
        workflow.retire(dnsStart)
        XCTAssertTrue(workflow.authorize(prepared))
        XCTAssertFalse(workflow.conditionalActivationAllowed(prepared.ticket), "its companion has no enable to act on")
        XCTAssertFalse(workflow.dnsIntent.configured, "and the retired DNS Start left none persisted")
        workflow.finishStart(prepared.ticket, succeeded: true)
    }

    /// The intent-revision guard: a write an older group staged before the Stop cannot end the newer Stop's obligation or overturn its
    /// disable; a group admitted after the Stop stages false, and its verified write does end it.
    func testALateOlderWriteCannotEndANewerStopsObligation() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let proxyOnly = RuntimeLifecycleRequest(actions: PrivateModuleSlots(proxy: .start, dns: .none, tunnels: .none))
        let olderTicket = try intents.admit(proxyOnly).get()
        let older = try XCTUnwrap(intents.capture(olderTicket, observedDNS: true))
        XCTAssertEqual(older.dnsStaged, true)
        let stop = intents.stop([.dns], reason: .session)
        intents.recordVerifiedDNSWrite(true, for: older)
        XCTAssertTrue(intents.stopSaveIsCurrent(revision: stop), "a late older write leaves the newer Stop's disable owed")
        XCTAssertFalse(intents.dnsConfigured, "and does not overturn it")

        let newerTicket = try intents.admit(proxyOnly).get()
        let newer = try XCTUnwrap(intents.capture(newerTicket, observedDNS: true))
        XCTAssertEqual(newer.dnsStaged, false, "a group admitted after the Stop stages its disable")
        intents.recordVerifiedDNSWrite(false, for: newer)
        XCTAssertFalse(intents.stopSaveIsCurrent(revision: stop), "whose verified write ends the obligation")
        XCTAssertTrue(intents.modules.dns.fenced, "the fence stays")
    }

    // MARK: - Quit (decision 0015)

    /// The process quit latches before it awaits anything, persists no disable, keeps a disable an earlier session Stop still owes, and
    /// returns only once every lane and every store operation it found has ended.
    func testQuitLatchesFirstKeepsAPredatingOwedSaveAndJoinsEveryLane() async throws {
        let (host, harness) = try await launch(platform: proxyAndDNS, dnsForwarderEnabled: true)
        try await host.startRuntime()
        let saved = try Data(contentsOf: harness.environment.configFile)
        // An owed disable: the session Stop is admitted, and its save has not run yet when the quit latches.
        host.workflow.admitStop([.dns], reason: .session)

        // The quit's teardown is held on its first system-proxy read, so the test sees it latched and its lanes taken mid-way.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let quit = Task { await host.shutdown() }
        for _ in 0..<5_000 where !host.workflow.isTerminal {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(host.workflow.isTerminal, "the quit latches before it awaits")
        do {
            _ = try await host.startProxy(conditionalDNS: true)
            XCTFail("no Start runs once the quit latched")
        } catch let refusal as RuntimeStartRefusal {
            XCTAssertEqual(refusal, .terminated)
        }
        await harness.hold.waitUntilReached()
        XCTAssertFalse(host.lanesIdle, "the quit holds the lanes while its teardown is out")
        harness.hold.release()
        await quit.value

        XCTAssertTrue(host.lanesIdle, "every lane ended before the quit returned")
        XCTAssertTrue(host.workflow.isIdle, "and every store operation")
        XCTAssertNotEqual(host.orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertNotEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertFalse(harness.machine.dnsRelayRunning)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), saved, "the quit persists no disable")
        let owed = await host.workflow.saveOwedDNSStop()
        XCTAssertEqual(owed.save, .saved, "the predating session Stop's disable was kept owed, not dropped")
        XCTAssertEqual(harness.savedDNSEnabled, false)
    }
}

/// A bounded model of the proxy and DNS module facade, run against the actual host, store and fake machine. The reference is written
/// from the selected rules alone (decisions 0015, 0035 and 0036): what an explicit Start or session Stop of each module, a proxy Start's
/// companion and a menu Restart may do to the run state, the saved DNS intent and DNS's fence. It never calls the host's intent value
/// or reads its transitions. Two families are explored: every sequential history of up to three commands, and every Start held at its
/// first platform step with a Stop admitted during it. Each history runs on its own scratch root and host.
@MainActor
final class RuntimeModuleLifecycleModelTests: XCTestCase {
    private enum Command: String, CaseIterable {
        case proxyStart, restart, dnsStart, proxyStop, dnsStop, tunnelsStart, tunnelsStop
    }

    private static let proxyAndDNSCommands: [Command] = [.proxyStart, .restart, .dnsStart, .proxyStop, .dnsStop]

    /// The reference state: what runs, what the runtime file says about DNS, and whether a Stop fence holds DNS.
    private struct Reference {
        var proxyUp = false
        var dnsUp = false
        var tunnelsUp = false
        var dnsSaved: Bool
        var dnsFenced = false

        /// The companion's result under the rule of decision 0036: running DNS, a fence and a disabled intent are no-ops in that order of
        /// precedence; otherwise it starts DNS without touching the intent.
        mutating func companion() -> RuntimeConditionalDNSResult {
            if dnsUp { return .alreadyActive }
            if dnsFenced { return .fenced }
            guard dnsSaved else { return .notConfigured }
            dnsUp = true
            return .started
        }

        /// The facade result each command must report, and the state it leaves.
        mutating func apply(_ command: Command) -> Expected {
            switch command {
            case .proxyStart, .restart:
                proxyUp = true
                return .started(RuntimeModuleStartOutcome(modules: PrivateModuleSlots(proxy: .started, dns: nil, tunnels: nil),
                                                          conditionalDNS: companion()))
            case .dnsStart:
                // An explicit enable: it saves the enable, clears the fence and starts DNS.
                dnsUp = true
                dnsSaved = true
                dnsFenced = false
                return .started(RuntimeModuleStartOutcome(modules: PrivateModuleSlots(proxy: nil, dns: .started, tunnels: nil),
                                                          conditionalDNS: nil))
            case .proxyStop:
                proxyUp = false
                return .stopped(RuntimeModuleStopOutcome(stopped: [.proxy], dnsSave: nil))
            case .dnsStop:
                // A session Stop: fenced, physically restored, and its disable saved.
                dnsUp = false
                dnsSaved = false
                dnsFenced = true
                return .stopped(RuntimeModuleStopOutcome(stopped: [.dns], dnsSave: .saved))
            case .tunnelsStart:
                // The configured tunnel listens; no other module moves.
                tunnelsUp = true
                return .started(RuntimeModuleStartOutcome(modules: PrivateModuleSlots(proxy: nil, dns: nil, tunnels: .started),
                                                          conditionalDNS: nil))
            case .tunnelsStop:
                tunnelsUp = false
                return .stopped(RuntimeModuleStopOutcome(stopped: [.tunnels], dnsSave: nil))
            }
        }
    }

    private enum Expected: Equatable {
        case started(RuntimeModuleStartOutcome)
        case stopped(RuntimeModuleStopOutcome)
        case superseded
    }

    private func run(_ command: Command, on host: RuntimeHost) async -> Expected {
        do {
            switch command {
            case .proxyStart: return .started(try await host.startProxy(conditionalDNS: true))
            case .restart: return .started(try await host.restartProxy())
            case .dnsStart: return .started(try await host.startDNS())
            case .proxyStop: return .stopped(await host.stopProxy())
            case .dnsStop: return .stopped(await host.stopDNS())
            case .tunnelsStart: return .started(try await host.startTunnels())
            case .tunnelsStop: return .stopped(await host.stopTunnels())
            }
        } catch let refusal as RuntimeStartRefusal where refusal == .superseded {
            return .superseded
        } catch {
            XCTFail("\(command) threw \(error)")
            return .superseded
        }
    }

    /// The machine, the run state and the saved file agree with the reference.
    private func compare(_ reference: Reference, _ host: RuntimeHost, _ harness: Harness, _ trace: String) {
        XCTAssertEqual(host.orchestrator.snapshot.runtimeStatus.state == .running, reference.proxyUp, "\(trace): proxy run state")
        XCTAssertEqual(harness.machine.service("Wi-Fi").routesThroughAProxy, reference.proxyUp, "\(trace): system proxy")
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState == .running, reference.dnsUp, "\(trace): DNS run state")
        XCTAssertEqual(harness.machine.dnsRelayRunning, reference.dnsUp, "\(trace): system DNS")
        XCTAssertEqual(harness.savedDNSEnabled, reference.dnsSaved, "\(trace): saved DNS intent")
        XCTAssertEqual(host.workflow.dnsIntent.fenced, reference.dnsFenced, "\(trace): DNS fence")
        XCTAssertEqual(!host.orchestrator.snapshot.bindings.tunnels.isEmpty, reference.tunnelsUp, "\(trace): tunnel listeners")
    }

    private static func histories(over commands: [Command], upTo length: Int) -> [[Command]] {
        var result: [[Command]] = []
        var frontier: [[Command]] = [[]]
        for _ in 0..<length {
            frontier = frontier.flatMap { prefix in commands.map { prefix + [$0] } }
            result += frontier
        }
        return result
    }

    /// Runs each history on its own root and host, comparing every result and the machine after every command. Returns the counts.
    private func explore(_ histories: [[Command]], dnsSaved: Bool, withTunnel: Bool) async throws -> (histories: Int, transitions: Int) {
        var transitions = 0
        for history in histories {
            let tunnels = withTunnel ? [TunnelDefinition(localPort: try freeTCPPort(), remoteHost: "127.0.0.1", remotePort: 9)] : []
            let harness = try makeHarness(platform: proxyAndDNS, dnsForwarderEnabled: dnsSaved, tunnels: tunnels)
            let host = try await harness.makeHost()
            var reference = Reference(dnsSaved: dnsSaved)
            var trace = "saved=\(dnsSaved) tunnel=\(withTunnel)"
            for command in history {
                trace += " \(command.rawValue)"
                let expected = reference.apply(command)
                let actual = await run(command, on: host)
                XCTAssertEqual(actual, expected, trace)
                compare(reference, host, harness, trace)
                transitions += 1
            }
            await harness.tearDown()
        }
        return (histories.count, transitions)
    }

    /// The third lane against the same host: every history of up to two of the seven commands, with one loopback tunnel configured, so a
    /// tunnels Start or Stop moves only the tunnel and a proxy or DNS command moves no tunnel.
    func testTunnelHistoriesStayIsolatedFromTheOtherModules() async throws {
        let counts = try await explore(Self.histories(over: Command.allCases, upTo: 2), dnsSaved: true, withTunnel: true)
        XCTAssertEqual(counts.histories, 7 + 49)
        XCTAssertEqual(counts.transitions, 7 + 98)
    }

    func testSequentialModuleHistoriesAgreeWithTheReference() async throws {
        // DNS saved on: every history up to three commands. Saved off: up to two.
        let on = try await explore(Self.histories(over: Self.proxyAndDNSCommands, upTo: 3), dnsSaved: true, withTunnel: false)
        let off = try await explore(Self.histories(over: Self.proxyAndDNSCommands, upTo: 2), dnsSaved: false, withTunnel: false)
        XCTAssertEqual(on.histories + off.histories, 155 + 30)
        XCTAssertEqual(on.transitions + off.transitions, (5 + 50 + 375) + (5 + 50))
    }

    /// A Start held at its first platform step, a Stop admitted during the hold, then the release. The expectation of each pair is the
    /// selected rule written out: a Stop of the Start's own module takes its lane, so the Start is superseded and leaves nothing; a Stop
    /// of the other module leaves the Start's progress, its platform work queues behind the Start's, and a DNS Stop's fence only denies
    /// the companion.
    func testAStopAdmittedWhileAStartAppliesAgreesWithTheReference() async throws {
        struct Case {
            let start: Command
            let stop: Command
            let startResult: (inout Reference) -> Expected
        }
        let cases: [Case] = [
            Case(start: .proxyStart, stop: .dnsStop) { reference in
                // The fence lands first; the proxy completes before the DNS Stop's work, then the companion finds the fence.
                reference.dnsUp = false
                reference.dnsSaved = false
                reference.dnsFenced = true
                reference.proxyUp = true
                return .started(RuntimeModuleStartOutcome(modules: PrivateModuleSlots(proxy: .started, dns: nil, tunnels: nil),
                                                          conditionalDNS: .fenced))
            },
            Case(start: .proxyStart, stop: .proxyStop) { reference in
                reference.proxyUp = false
                return .superseded
            },
            Case(start: .dnsStart, stop: .proxyStop) { reference in
                reference.proxyUp = false
                reference.dnsUp = true
                reference.dnsSaved = true
                reference.dnsFenced = false
                return .started(RuntimeModuleStartOutcome(modules: PrivateModuleSlots(proxy: nil, dns: .started, tunnels: nil),
                                                          conditionalDNS: nil))
            },
            Case(start: .dnsStart, stop: .dnsStop) { reference in
                reference.dnsUp = false
                reference.dnsSaved = false
                reference.dnsFenced = true
                return .superseded
            },
        ]
        var explored = 0
        for dnsSaved in [false, true] {
            for item in cases {
                let trace = "saved=\(dnsSaved) \(item.start.rawValue) held, \(item.stop.rawValue)"
                let harness = try makeHarness(platform: proxyAndDNS, dnsForwarderEnabled: dnsSaved)
                let host = try await harness.makeHost()
                harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
                    name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
                }
                let command = item.start
                let start = Task { await self.run(command, on: host) }
                await harness.hold.waitUntilReached()
                let stopCommand = item.stop
                let stop = Task { await self.run(stopCommand, on: host) }
                for _ in 0..<5_000 where host.pendingAdmissions < 2 {
                    try await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertEqual(host.pendingAdmissions, 2, "\(trace): the Stop is admitted during the hold")
                harness.hold.release()
                var reference = Reference(dnsSaved: dnsSaved)
                let expectedStart = item.startResult(&reference)
                let actualStart = await start.value
                let actualStop = await stop.value
                XCTAssertEqual(actualStart, expectedStart, trace)
                let stopped: Set<ControlModule> = item.stop == .proxyStop ? [.proxy] : [.dns]
                XCTAssertEqual(actualStop, .stopped(RuntimeModuleStopOutcome(
                    stopped: stopped, dnsSave: item.stop == .dnsStop ? .saved : nil
                )), trace)
                compare(reference, host, harness, trace)
                await harness.tearDown()
                explored += 1
            }
        }
        XCTAssertEqual(explored, 8)
    }
}
