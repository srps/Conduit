// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitRuntime
import NIOConcurrencyHelpers
import PlatformMac
import ProxyAuth
import ProxyKernel
import RuntimeEvents

/// `runtime-host-effects` (decision 0033): the actual shared `RuntimeHost`, run over explicit fakes and owned scratch state.
///
/// The host is built through its one `effects` input, with each machine effect named here: the `FakeMachine` for the
/// privilege client, `networksetup` and `launchctl`, an in-memory Keychain, a PAC evaluator, a port-holder probe and a
/// loopback listener probe that never fetch, look up or connect to anything, a Kerberos stack that refuses every token,
/// and no-op path and network observers.
/// The state root is taken through the production bootstrap over a scratch directory, and the listener is a loopback
/// port this scenario holds. Nothing reads the machine's proxy, resolver directory, home or Keychain, and no installed
/// app or helper is reached.
///
/// It checks a failed start on a held port, a restart on the same host, and a stop, against the fakes; then the configuration workflow;
/// then a stop admitted before a held start binds, and the next start. Every path after
/// the root is taken ends in one release step: the root's reference is dropped, a fresh acquisition proves the lease
/// closed, and the scratch directory is removed only when that proof and the close-failure count both agree. A shutdown
/// whose flush is not confirmed pins the actual host in one slot until the process exits, keeps the root, and fails.
enum RuntimeHostEffectsScenario {
    /// The one host a shutdown could not confirm. Held for the rest of the process, so its writers keep the root they
    /// hold. A single slot: a second unconfirmed shutdown never needs a second one, and a run started while it is
    /// occupied fails before it allocates anything.
    @MainActor
    private static var unconfirmedHost: RuntimeHost?

    @MainActor
    static func run() async throws -> ScenarioResult {
        let began = Date()
        guard unconfirmedHost == nil else {
            return finish(began, [.init("a previous run kept its host; this run was not started", false)], [])
        }
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-runtime-host-effects-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = scratch.appendingPathComponent("state", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let environment = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)
        let releaseFailures = ReleaseFailureCounter()
        var session: StateRootSession?

        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            // The one state root this scenario owns, taken through the production bootstrap. Everything after this point
            // ends in `releaseRoot`, whatever throws.
            session = try acquireRoot(environment, releaseFailures: releaseFailures)

            // The held listener makes the host's bind on this port fail, the way a contended port does.
            let held = try HeldLoopbackListener()
            var config = GenericDefaults.shared.makeConfig()
            config.localPort = held.port
            config.dnsForwarderEnabled = false
            config.localPACEnabled = false
            config.pacRoutingEnabled = false
            config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
            try ProxyConfigPersistence.save(config, in: environment)
            try PlatformConfigPersistence.save(
                PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true), in: environment
            )

            // Every machine effect is named here. The fakes are kept so the checks can read what they saw.
            let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
            let fakes = Fakes(
                machine: machine,
                probe: FakeListenerPortHolderProbe(),
                loopback: FakeLoopbackPortProbe(),
                pac: FakePacEvaluator(),
                gss: RefusingGSSProvider(),
                helper: FakeHelperLifecycle(),
                secrets: InMemorySecretStore(),
                dns: FakeDNSProbe()
            )
            let shutdown = await exercise(
                session: session!, environment: environment, held: held, fakes: fakes, home: home
            )
            assertions += shutdown.assertions
            notes += shutdown.notes
            // The workflow host runs over the same root only after the first host has shut down, and it has its own shutdown.
            var workflow = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced {
                workflow = await exerciseWorkflow(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += workflow.assertions
                notes += workflow.notes
            }
            // The lifecycle host runs over the same root only after the workflow host has shut down, with its own shutdown.
            var lifecycle = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced {
                lifecycle = await exerciseStopBeforeBind(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += lifecycle.assertions
                notes += lifecycle.notes
            }
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced {
                releaseRoot(&session, environment: environment, scratch: scratch, releaseFailures: releaseFailures,
                            assertions: &assertions, notes: &notes)
            } else {
                // The host keeps its session, so the root stays claimed for the rest of the process. The slot is the
                // only reference this scenario keeps, and the scratch directory stays on disk for inspection.
                unconfirmedHost = lifecycle.pinnedHost ?? workflow.pinnedHost ?? shutdown.pinnedHost
                assertions.append(.init("the shutdown is confirmed", false))
                notes.append("shutdown not confirmed: host pinned until process exit; root and scratch kept at \(scratch.path)")
            }
        } catch {
            // A setup failure after the root was taken still ends in the same release step, so a failed close is seen
            // before anything is deleted. A failure before the root was taken has no lease to release.
            notes.append("setup failed: \(error.localizedDescription)")
            assertions.append(.init("the scenario's setup completed", false))
            if session != nil {
                releaseRoot(&session, environment: environment, scratch: scratch, releaseFailures: releaseFailures,
                            assertions: &assertions, notes: &notes)
            } else {
                notes.append("no root was taken; scratch kept at \(scratch.path)")
            }
        }
        return finish(began, assertions, notes)
    }

    /// Every machine effect one host run uses, from the run's fakes. Production selects its adapters in `ConduitDaemon`; this is the simulator's
    /// explicit assembly over fakes and the owned scratch root. `pac` replaces the refusing PAC fake for a run that fetches one.
    private static func effects(_ fakes: Fakes, home: URL, pac: (any PacEvaluator)? = nil) -> RuntimeHostEffects {
        let machine = fakes.machine
        return RuntimeHostEffects(
            privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: fakes.helper) },
            credentials: fakes.secrets,
            kerberosTicketRecovery: FakeKerberosTicketRecovery(),
            gss: .injected { fakes.gss },
            pacEvaluator: pac ?? fakes.pac,
            portHolderProbe: fakes.probe,
            loopbackPortProbe: fakes.loopback.isServed(port:),
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            dnsResponds: fakes.dns.responds(onPort:),
            networkPath: FakeNetworkPathObserver(),
            networkLocation: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil },
            vpnStatusMonitor: { _, _ in FakeVPNStatusObserver() },
            homeDirectory: home,
            resolverDirectory: machine.resolverDirectory.path,
            stateFiles: StateFileAccess.operatingSystem()
        )
    }

    /// The configuration workflow through the actual host, over the run's fakes and the scratch root. Reloads go through the store, so the
    /// checks read what the host did: an invalid runtime file refuses and is left unchanged, a valid edit applies and advances the
    /// generation, and a start-blocking edit is kept for editing while the applied view stays.
    @MainActor
    private static func exerciseWorkflow(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let host: RuntimeHost
        do {
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home)
            )
        } catch {
            notes.append("workflow host did not open: \(error.localizedDescription)")
            check("the workflow host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }
        let applied = host.status().profileName

        // An invalid runtime file is refused. Nothing is written, and the applied view stays where it was.
        let invalid = Data("{".utf8)
        do {
            try invalid.write(to: environment.configFile)
            await host.reloadConfiguration()
            check("an invalid runtime file leaves the applied configuration", host.status().profileName == applied)
            check("an invalid runtime file is not rewritten by the reload", (try? Data(contentsOf: environment.configFile)) == invalid)
        } catch {
            notes.append("the invalid-file step failed: \(error.localizedDescription)")
            check("the invalid-file step completed", false)
        }

        // A valid edit is adopted and applied, and the generation advances.
        var edited = GenericDefaults.shared.makeConfig()
        edited.profileName = "Workflow edit"
        do {
            try ProxyConfigPersistence.save(edited, in: environment)
            await host.reloadConfiguration()
            check("a valid edit is applied on reload", host.status().profileName == "Workflow edit")
            check("an applied reload advances the configuration generation", host.status().configGeneration == 1)
        } catch {
            notes.append("the valid-edit step failed: \(error.localizedDescription)")
            check("the valid-edit step completed", false)
        }

        // A start-blocking edit is kept for editing, and it never replaces the applied view.
        var blocking = edited
        blocking.maxConnections = 0
        do {
            try ProxyConfigPersistence.save(blocking, in: environment)
            await host.reloadConfiguration()
            check("a start-blocking edit does not replace the applied configuration", host.status().profileName == "Workflow edit")
            check("a held reload does not advance the generation", host.status().configGeneration == 1)
        } catch {
            notes.append("the blocking-edit step failed: \(error.localizedDescription)")
            check("the blocking-edit step completed", false)
        }

        // Released only when the settlement and the physical flush both confirm; otherwise the host and root stay pinned.
        let settlement = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        check("the workflow host settles before its root is released", settlement == .settled)
        let report = await host.flushEvents()
        check("the workflow host's observability flush is confirmed", report.allConfirmed)
        // The typed events are read back from the owned file after the flush, so the checks see what was written.
        do {
            let typed = try configurationEvents(in: environment.eventsFile)
            check("the invalid runtime file is a refused observation",
                  typed.contains(.configWorkflow(.observed(ConfigurationWorkflowObserved(
                      phase: .reload, observation: .refused(.invalidContent))))))
            check("a start-blocking edit is held for editing on the runtime input",
                  typed.contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
                      phase: .reload, input: .runtime, reason: .startBlocking)))))
        } catch {
            notes.append("the owned events file did not decode: \(error.localizedDescription)")
            check("the owned events file decodes", false)
        }
        let confirmed = settlement == .settled && report.allConfirmed
        return Shutdown(quiesced: confirmed, assertions: assertions, notes: notes, pinnedHost: confirmed ? nil : host)
    }

    /// A stop admitted while a start is still before its bind, then a fresh start, through the actual host over the run's fakes. The start
    /// is held on its PAC fetch, which the kernel awaits before it binds. Released after the stop, the overtaken start binds and applies
    /// nothing, and the next start comes up instead of finding a stale `running` and doing nothing. An edit the Stop fence held at reload
    /// is the next start's committed input, and that start adopts it as the host view.
    @MainActor
    private static func exerciseStopBeforeBind(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        let fetch = HeldPACFetch()
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/held.pac"
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let host: RuntimeHost
        do {
            // A fixed port, as production runs: the system proxy names the configured port, so the check below can compare against it.
            let reserved = try HeldLoopbackListener()
            config.localPort = reserved.port
            reserved.release()
            try ProxyConfigPersistence.save(config, in: environment)
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home, pac: fetch)
            )
        } catch {
            notes.append("lifecycle host did not open: \(error.localizedDescription)")
            check("the lifecycle host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        // Owned here, so the error path joins it after the release.
        var heldStart: Task<Void, Error>?
        do {
            let start = Task { @MainActor in try await host.startRuntime() }
            heldStart = start
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !fetch.isHeld, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            check("the start is held on its PAC fetch, before its bind", fetch.isHeld)

            await host.stopRuntime()
            fetch.release()
            var overtaken: String?
            do {
                try await start.value
            } catch {
                overtaken = error.localizedDescription
            }
            notes.append("overtaken start: \(overtaken ?? "returned")")
            let stopped = host.status()
            check("the overtaken start reports no failure of its own", overtaken == nil)
            check("the stop stands once the overtaken start is released", stopped.state == "stopped")
            check("the overtaken start leaves no listener", stopped.bindings.proxyPort == nil)
            check("the overtaken start applies no system proxy", machine.service("Wi-Fi").webProxy.enabled == false)

            // An edit the Stop fence holds at reload is adopted by the next start, which commits it, through the same host-view path.
            var edited = config
            edited.profileName = "Adopted by the next start"
            try ProxyConfigPersistence.save(edited, in: environment)
            await host.reloadConfiguration()
            check("a reload under the Stop fence leaves the host view",
                  host.status().profileName == config.profileName && host.status().configGeneration == 0)

            try await host.startRuntime()
            check("the next start adopts the input it committed as the host view",
                  host.status().profileName == edited.profileName && host.status().configGeneration == 1)
            check("the next start binds the configured port", host.status().bindings.proxyPort == config.localPort)
            check("the next start applies the system proxy to its listener",
                  machine.service("Wi-Fi").webProxy == FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: String(config.localPort)))

            await host.stopRuntime()
            check("a final stop leaves no listener", host.status().bindings.proxyPort == nil)
            check("a final stop clears the system proxy", machine.service("Wi-Fi").webProxy.enabled == false)

            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the lifecycle host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the lifecycle host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed
        } catch {
            // The error path joins the host's work before anything is released: release the fetch, stop, settle, then flush, then judge.
            notes.append("lifecycle exercise error: \(error.localizedDescription)")
            fetch.release()
            if let heldStart, case .failure(let failure) = await heldStart.result {
                notes.append("held start on the error path: \(failure.localizedDescription)")
            }
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the lifecycle error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// The typed payloads in the owned events file, decoded through the canonical decoder (decision 0033). A line that does not decode
    /// is an error, not a skipped record, so the caller reports it.
    private static func configurationEvents(in file: URL) throws -> [RuntimeEventPayload] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let decoder = CanonicalJSON.decoder()
        return try text.split(separator: "\n").compactMap { line in
            try decoder.decode(RuntimeEvent.self, from: Data(line.utf8)).typed
        }
    }

    /// The fakes one run names. Kept by the caller so the checks read what each one saw.
    private struct Fakes {
        let machine: FakeMachine
        let probe: FakeListenerPortHolderProbe
        let loopback: FakeLoopbackPortProbe
        let pac: FakePacEvaluator
        let gss: RefusingGSSProvider
        let helper: FakeHelperLifecycle
        let secrets: InMemorySecretStore
        let dns: FakeDNSProbe
    }

    /// What one exercise established. `quiesced` means `stopRuntime` returned and `flushEvents` reported all
    /// writers confirmed, on the success path and on the error path alike. That is the diagnostic confirmation the
    /// host exposes; it does not prove that every task the host started has ended. `pinnedHost` is set only when
    /// the shutdown is unconfirmed, and then it is the actual host, not a stand-in.
    private struct Shutdown {
        var quiesced: Bool
        var assertions: [ScenarioAssertion]
        var notes: [String]
        var pinnedHost: RuntimeHost?
    }

    /// Starts, fails and restarts, then stops and flushes one `RuntimeHost`. On success the host is dropped on return.
    /// Every path ends with a stop and a flush, so the host's own work is joined before the caller releases the root.
    @MainActor
    private static func exercise(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        held: HeldLoopbackListener,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        let probe = fakes.probe
        let pac = fakes.pac
        let gss = fakes.gss
        var terminalExits = 0

        let host: RuntimeHost
        do {
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: true,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: { terminalExits += 1 },
                effects: effects(fakes, home: home)
            )
        } catch {
            // Nothing was started, so there is no host work to join.
            notes.append("host was not built: \(error.localizedDescription)")
            return Shutdown(quiesced: true, assertions: [.init("the host was built", false)], notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        do {
            // Readiness joins launch recovery first. Nothing was applied before this host, so recovery leaves the machine alone.
            await host.markReady(mode: "runtime-host")
            check("readiness leaves the unconfigured machine untouched", machine.privilege.commands.isEmpty
                  && machine.launchdEnvironment.isEmpty && machine.service("Wi-Fi").webProxy.enabled == false)

            // A start on the held port fails. The bind asks the port-holder probe, and the failed start reverts what it touched.
            var failedStart: String?
            do {
                try await host.startRuntime()
            } catch {
                failedStart = error.localizedDescription
            }
            notes.append("failed start: \(failedStart ?? "none"); port-holder lookups: \(probe.lookupCount)")
            check("a start on a held port fails", failedStart != nil)
            check("the failed bind asks the port-holder probe for the held port",
                  probe.lookupCount >= 1 && probe.lastLookup == "127.0.0.1:\(held.port)")
            check("a failed start leaves no system proxy behind",
                  machine.service("Wi-Fi").webProxy.enabled == false && machine.service("Wi-Fi").secureWebProxy.enabled == false)
            check("a failed start leaves no launchd environment behind", machine.launchdEnvironment.isEmpty)
            check("a failed start calls no privileged operation", machine.privilege.commands.isEmpty)
            check("a failed start fetches no PAC", pac.fetchCount == 0)
            check("a failed start asks for no Kerberos token", gss.calls == 0)

            // The held port is released, and the same host starts again.
            let lookupsAfterFailure = probe.lookupCount
            held.release()
            try await host.startRuntime()
            check("a restart applies the system proxy to the actual listener",
                  machine.service("Wi-Fi").webProxy == FakeMachine.ProxyEndpoint(enabled: true, host: "127.0.0.1", port: String(held.port)))
            check("a restart sets the launchd environment", !machine.launchdEnvironment.isEmpty)
            check("a restart makes no further port-holder lookup", probe.lookupCount == lookupsAfterFailure)
            check("a restart fetches no PAC and asks for no Kerberos token", pac.fetchCount == 0 && gss.calls == 0)

            // A stop clears what the start applied, through the same fakes. Once it returns, its platform work is joined.
            await host.stopRuntime()
            check("a stop clears the system proxy", machine.service("Wi-Fi").webProxy.enabled == false)
            check("a stop clears the launchd environment", machine.launchdEnvironment.isEmpty)

            // The stopped host's captured warm-up and admitted deliveries join first. The flush after it is the final
            // diagnostic flush, and this scenario keeps the host and root until that flush is confirmed.
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the stopped host's warm-up and deliveries settle before the flush", settled == .settled)
            // The flush reports the writers' own confirmation. It is one of the proofs, not a proof that every task ended.
            let flush = await host.flushEvents()
            check("the host's final flush is confirmed", flush.allConfirmed)
            let eventsText = try String(contentsOf: environment.eventsFile, encoding: .utf8)
            check("the events file records the ready event", eventsText.contains("daemon.ready"))
            check("a non-terminal stop does not call the terminal exit", terminalExits == 0)

            // The fake refuses a command the scenario did not plan, and the refusal is a failure, not a success.
            let refusal = try machine.run("/usr/bin/security", ["find-generic-password"])
            check("the fake machine refuses an unplanned command", refusal.exitCode != 0)
            quiesced = settled == .settled && flush.allConfirmed
            notes.append("joined: startRuntime and stopRuntime returned; settle=\(settled); flushEvents allConfirmed=\(flush.allConfirmed)")
            notes.append("not joined: the environment drift timer (weak self; it ends at its next tick, after the host is gone)")
        } catch {
            // The error path joins the host's work before anything is released: stop, settle, then flush, then judge.
            notes.append("scenario error: \(error.localizedDescription)")
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the error path settled the host and confirmed its flush", quiesced))
        }
        if !machine.privilege.commands.isEmpty {
            notes.append("privileged operations recorded: \(machine.privilege.commands.count)")
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes,
                        pinnedHost: quiesced ? nil : host)
    }

    /// Drops this run's reference to the root, then proves the lease closed with a fresh acquisition. The scratch
    /// directory is removed only when that proof and the close-failure count both agree. An unknown close keeps the root
    /// and the directory, and the first close errno is reported when there was a failure.
    @MainActor
    private static func releaseRoot(
        _ session: inout StateRootSession?,
        environment: RuntimeEnvironment,
        scratch: URL,
        releaseFailures: ReleaseFailureCounter,
        assertions: inout [ScenarioAssertion],
        notes: inout [String]
    ) {
        session = nil
        let closed = leaseReacquires(environment, releaseFailures: releaseFailures)
        let failures = releaseFailures.count
        assertions.append(.init("the scratch root's lease closes (a fresh acquisition succeeds)", closed))
        assertions.append(.init("no lease close failed", failures == 0))
        if failures > 0, let code = releaseFailures.first {
            notes.append("lease close failed \(failures) time(s); first errno \(code)")
        }
        guard closed, failures == 0 else {
            notes.append("root kept at \(scratch.path): lease closure not confirmed")
            return
        }
        do {
            try FileManager.default.removeItem(at: scratch)
            assertions.append(.init("the scratch directory is removed", true))
        } catch {
            assertions.append(.init("the scratch directory is removed", false))
            notes.append("scratch cleanup failed: \(error.localizedDescription)")
        }
    }

    /// Whether a fresh acquisition of the root succeeds. The probe's session is dropped on return, so a success here
    /// proves the lease closed. A busy or refused root reports `false`.
    @MainActor
    private static func leaseReacquires(
        _ environment: RuntimeEnvironment,
        releaseFailures: ReleaseFailureCounter
    ) -> Bool {
        let outcome = StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in releaseFailures.record(failure) }
        )
        if case .success = outcome { return true }
        return false
    }

    private static func acquireRoot(
        _ environment: RuntimeEnvironment,
        releaseFailures: ReleaseFailureCounter
    ) throws -> StateRootSession {
        let outcome = StateRootBootstrap.acquire(
            environment,
            createRootIfMissing: true,
            fileSystem: OSStateRootFileSystem(),
            leasing: OSStateWriterLeasing(),
            onReleaseFailure: { failure in releaseFailures.record(failure) }
        )
        switch outcome {
        case .success(let session):
            return session
        case .failure(let failure):
            throw ScenarioExecutionError(message: "state root refused: \(failure)")
        }
    }

    private static func finish(_ began: Date, _ assertions: [ScenarioAssertion], _ notes: [String]) -> ScenarioResult {
        ScenarioResult(
            name: "runtime-host-effects", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions.isEmpty ? [.init("scenario produced assertions", false)] : assertions,
            notes: notes
        )
    }
}

/// Counts the lease close failures the root reports, and keeps the first errno. A count and one code are all a
/// shutdown check needs, so nothing grows with the failures.
private final class ReleaseFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var firstErrno: Int32?

    var count: Int { lock.withLock { failures } }

    /// The errno of the first failure, when there was one.
    var first: Int32? { lock.withLock { firstErrno } }

    func record(_ failure: StateWriterReleaseFailure) {
        lock.withLock {
            failures += 1
            if firstErrno == nil { firstErrno = failure.errno }
        }
    }
}

/// A loopback listener the scenario holds open on a port it chose. `release()` closes it, and `deinit` closes it if
/// the scenario never did.
private final class HeldLoopbackListener {
    let port: Int
    private var descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScenarioExecutionError(message: "socket failed: errno \(errno)") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw ScenarioExecutionError(message: "bind failed: errno \(errno)")
        }
        var chosen = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &chosen) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw ScenarioExecutionError(message: "listen failed: errno \(errno)")
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: chosen.sin_port))
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}

/// The Kerberos token source a simulator scenario injects. It refuses each token and counts the attempts, so a
/// handshake the scenario did not plan is visible.
private final class RefusingGSSProvider: GSSTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    /// Token requests made so far.
    var calls: Int { lock.withLock { attempts } }

    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        lock.withLock { attempts += 1 }
        throw UnplannedFakeEffect(effect: "GSS token")
    }

    func resetContext() {}
}
