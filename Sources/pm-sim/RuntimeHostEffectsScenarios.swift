// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ConduitRuntime
import ConduitShared
import NIOConcurrencyHelpers
import NIOPosix
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import RuntimeEvents

/// `runtime-host-effects` (decision 0033): the actual shared `RuntimeHost`, run over explicit fakes and owned scratch state.
///
/// The host is built through its one `effects` input, with each machine effect named here: the `FakeMachine` for the
/// privilege client, `networksetup` and `launchctl`, an in-memory Keychain, a PAC evaluator, a port-holder probe and a
/// loopback listener probe that never fetch, look up or connect to anything, a Kerberos stack that refuses every token,
/// no-op path and network observers, and a wake source only the wake exercise fires.
/// The state root is taken through the production bootstrap over a scratch directory, and the listener is a loopback
/// port this scenario holds. Nothing reads the machine's proxy, resolver directory, home or Keychain, and no installed
/// app or helper is reached.
///
/// It checks a failed start on a held port, a restart on the same host, and a stop, against the fakes; then the configuration workflow;
/// then a stop admitted before a held start binds, and the next start; then the connection audit of one served loopback request and of
/// a burst of connections under mixed-priority owner load; and, last,
/// a reload's flag action held on the platform queue while a Stop is admitted.
/// Every path after
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
            // The source host runs over the same root only after the lifecycle host has shut down, with its own shutdown.
            var source = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced {
                source = await exerciseSourceChanged(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += source.assertions
                notes += source.notes
            }
            var respelling = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced {
                respelling = await exerciseRespelledPACReload(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += respelling.assertions
                notes += respelling.notes
            }
            var captured = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced {
                captured = await exerciseReloadAfterCapture(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += captured.assertions
                notes += captured.notes
            }
            var modules = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced
                && captured.quiesced {
                modules = await exerciseModuleLifecycle(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += modules.assertions
                notes += modules.notes
            }
            var woken = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced
                && captured.quiesced && modules.quiesced {
                woken = await exerciseWake(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += woken.assertions
                notes += woken.notes
            }
            var audited = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced
                && captured.quiesced && modules.quiesced && woken.quiesced {
                audited = await exerciseConnectionAudit(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += audited.assertions
                notes += audited.notes
            }
            var flagged = Shutdown(quiesced: false, assertions: [], notes: [], pinnedHost: nil)
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced
                && captured.quiesced && modules.quiesced && woken.quiesced && audited.quiesced {
                flagged = await exerciseHeldFlagAction(session: session!, environment: environment, fakes: fakes, home: home)
                assertions += flagged.assertions
                notes += flagged.notes
            }
            if shutdown.quiesced && workflow.quiesced && lifecycle.quiesced && source.quiesced && respelling.quiesced
                && captured.quiesced && modules.quiesced && woken.quiesced && audited.quiesced && flagged.quiesced {
                releaseRoot(&session, environment: environment, scratch: scratch, releaseFailures: releaseFailures,
                            assertions: &assertions, notes: &notes)
            } else {
                // The host keeps its session, so the root stays claimed for the rest of the process. The slot is the
                // only reference this scenario keeps, and the scratch directory stays on disk for inspection.
                // The latest exercise's host first, as each one runs only after the one before it quiesced.
                let exercises = [flagged, audited, woken, modules, captured, respelling, source, lifecycle, workflow, shutdown]
                unconfirmedHost = exercises.lazy.compactMap(\.pinnedHost).first
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
    /// explicit assembly over fakes and the owned scratch root. `pac` replaces the refusing PAC fake for a run that fetches one. Each host
    /// gets its own wake fake; only the wake exercise keeps and fires its own.
    private static func effects(
        _ fakes: Fakes, home: URL, pac: (any PacEvaluator)? = nil, wake: FakeSystemWakeObserver = FakeSystemWakeObserver(),
        hold: HeldSetenv? = nil, vpn: FakeVPNStatusObserver = FakeVPNStatusObserver(),
        path: FakeNetworkPathObserver = FakeNetworkPathObserver()
    ) -> RuntimeHostEffects {
        let machine = fakes.machine
        return RuntimeHostEffects(
            privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: fakes.helper) },
            credentials: fakes.secrets,
            kerberosTicketRecovery: FakeKerberosTicketRecovery(),
            gss: .injected { fakes.gss },
            pacEvaluator: pac ?? fakes.pac,
            portHolderProbe: fakes.probe,
            loopbackPortProbe: fakes.loopback.isServed(port:),
            commandRunner: { launchPath, arguments in
                hold?.pass(launchPath, arguments)
                return try machine.run(launchPath, arguments)
            },
            dnsResponds: fakes.dns.responds(onPort:),
            networkPath: path,
            networkLocation: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in nil },
            vpnStatusMonitor: { _, _ in vpn },
            wake: wake,
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
        let logger = HeldFileLogger(directory: home.appendingPathComponent("held-logger", isDirectory: true))
        do {
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: logger,
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

        // The host's own logger drain, held at its file's open. The flush awaits it to the existing bounded wait and records the typed
        // fact, apart from the artifacts. A flush whose cap has already passed gives the logger no fresh wait at all.
        logger.holdNextOpen()
        logger.log(.notice, "held logger witness")
        check("the logger's file open is held", logger.joinHeld())
        let held = await host.flushEvents()
        check("a held logger drain ends at its bounded wait", held.logger == .timedOut)
        check("the held logger leaves the artifact confirmation alone", held.allConfirmed)
        let capStarted = ContinuousClock.now
        let capped = await host.flushEvents(loggerUntil: capStarted)
        check("a passed cap skips the logger drain without waiting",
              capped.logger == .skippedBudget && capStarted.duration(to: .now) < DiagnosticFlushPhase.writerWait)
        logger.release()
        let report = await host.flushEvents()
        check("released, the logger drains", report.logger == .drained)
        check("the workflow host's observability flush is confirmed", report.allConfirmed)
        do {
            let typed = try typedEvents(in: environment.eventsFile)
            check("both unconfirmed logger drains are typed host facts in the owned events file",
                  typed.contains(.lifecycle(.logFlushUnconfirmed(LifecycleLogFlushUnconfirmed(source: .host, outcome: .timedOut))))
                      && typed.contains(.lifecycle(.logFlushUnconfirmed(LifecycleLogFlushUnconfirmed(source: .host, outcome: .skippedBudget)))))
            notes.append("held logger: drain timed_out at its bounded wait, passed cap skipped_budget, released drain drained; both facts persisted")
        } catch {
            notes.append("the owned events file did not decode: \(error.localizedDescription)")
            check("the owned events file decodes", false)
        }
        // The typed events are read back from the owned file after the flush, so the checks see what was written.
        do {
            let typed = try typedEvents(in: environment.eventsFile)
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
            var overtaken: RuntimeStartRefusal?
            do {
                try await start.value
            } catch {
                overtaken = error as? RuntimeStartRefusal
                notes.append("overtaken start: \(error.localizedDescription)")
            }
            let stopped = host.status()
            check("the overtaken start reports its typed supersession, not success", overtaken == .superseded)
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
            check("the lifecycle exercise completed without error", false)
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

    /// A reload that adopts an edit after a Start captured its saved input (decision 0037). The Start is held on its PAC fetch, after its
    /// capture and commit; the reload's observation replaces the pair, so the Start's remaining effects hold and are not rebound to the edit.
    /// Its teardown clears the modules it owned, and the reload's pass, admitted under it, applies nothing. The next explicit Start then
    /// captures the edit.
    @MainActor
    private static func exerciseReloadAfterCapture(
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
        config.pacURL = "http://pac.example.test/captured.pac"
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let host: RuntimeHost
        do {
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
            notes.append("capture host did not open: \(error.localizedDescription)")
            check("the capture host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        var heldStart: Task<Void, Error>?
        do {
            let start = Task { @MainActor in try await host.startRuntime() }
            heldStart = start
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !fetch.isHeld, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            check("the captured start is held on its PAC fetch", fetch.isHeld)

            var edited = config
            edited.profileName = "Edited after the capture"
            try ProxyConfigPersistence.save(edited, in: environment)
            // The reload's pass waits for the held Start's lane, so the reload runs beside it; its adoption is seen in the host view.
            let reload = Task { @MainActor in await host.reloadConfiguration() }
            while host.status().profileName != edited.profileName, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            check("the reload adopted the edit while the start was held", host.status().profileName == edited.profileName)
            fetch.release()
            var held: RuntimeStartRefusal?
            do {
                try await start.value
            } catch {
                held = error as? RuntimeStartRefusal
                notes.append("captured start: \(error.localizedDescription)")
            }
            _ = await reload.value
            check("the start whose capture was replaced reports its typed supersession", held == .superseded)
            check("the held start leaves no listener", host.status().bindings.proxyPort == nil)
            check("the held start leaves no system proxy", machine.service("Wi-Fi").webProxy.enabled == false)

            try await host.startRuntime()
            check("the next start captures the edit", host.status().profileName == edited.profileName)
            check("the next start binds its listener", host.status().bindings.proxyPort == config.localPort)

            await host.stopRuntime()
            check("the capture host's final stop clears the system proxy", machine.service("Wi-Fi").webProxy.enabled == false)
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the capture host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the capture host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed
        } catch {
            check("the capture exercise completed without error", false)
            notes.append("capture exercise error: \(error.localizedDescription)")
            fetch.release()
            if let heldStart, case .failure(let failure) = await heldStart.result {
                notes.append("held start on the error path: \(failure.localizedDescription)")
            }
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the capture error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// The per-module lifecycle facade of the actual host (decisions 0031, 0035, 0036 and 0037), over the run's fakes and an ephemeral DNS
    /// port. A proxy Start's companion starts configured DNS; a proxy Stop leaves DNS running; a session DNS Stop restores system DNS and
    /// saves its disable; a menu Restart's companion then finds the fence; a request naming a moved revision is refused whole; the menu's
    /// saved DNS Start through the framed client enables DNS again with its causal receipt, and a saved tunnels Start binds the loopback
    /// tunnel without rewriting the pair; a preflight refresh reads the fake helper and a credentials notice completes, through the same
    /// client; an explicit reload through it refuses a malformed file whole and adopts an external edit, writing neither (decision 0032);
    /// and the process quit latches, tears every module down and returns with every lane idle.
    @MainActor
    private static func exerciseModuleLifecycle(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        // One loopback tunnel on an ephemeral port, for the saved tunnels Start through the framed client.
        config.tunnelDefinitions = [TunnelDefinition(localPort: 0, remoteHost: "127.0.0.1", remotePort: 9)]
        let host: RuntimeHost
        // The earlier hosts' events share the owned file, so only the events after this count are this host's.
        let earlier: Int
        do {
            earlier = try typedEvents(in: environment.eventsFile).count
            try ProxyConfigPersistence.save(config, in: environment)
            try PlatformConfigPersistence.save(
                PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true), in: environment
            )
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home)
            )
        } catch {
            notes.append("module host did not open: \(error.localizedDescription)")
            check("the module host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }
        func savedDNS() -> Bool? {
            (try? ProxyConfigPersistence.load(in: environment, allowMissing: false))?.dnsForwarderEnabled
        }

        var quiesced = false
        // Owned here, so the error path ends and joins it before the root is released.
        var witness: Task<StreamWitness, Never>?
        do {
            let proxy = try await host.startProxy(conditionalDNS: true)
            check("a proxy Start reports its proxy started", proxy.modules.proxy == .started)
            check("its companion starts the configured DNS", proxy.conditionalDNS == .started)
            check("the companion points system DNS at the forwarder", machine.dnsRelayRunning)

            let proxyStop = await host.stopProxy()
            check("a proxy Stop stops only the proxy", proxyStop.stopped == [.proxy])
            check("a proxy Stop clears the system proxy", !machine.service("Wi-Fi").routesThroughAProxy)
            check("a proxy Stop leaves DNS running", host.status().dnsRunState == "running" && machine.dnsRelayRunning)

            let dnsStop = await host.stopDNS()
            check("a session DNS Stop saves its disable", dnsStop.dnsSave == .saved && savedDNS() == false)
            check("a session DNS Stop restores system DNS", !machine.dnsRelayRunning)

            let observed = host.moduleRevisions
            let restart = try await host.restartProxy()
            check("a menu Restart brings the proxy up", restart.modules.proxy == .started && machine.service("Wi-Fi").routesThroughAProxy)
            check("its companion finds the DNS fence and starts nothing", restart.conditionalDNS == .fenced && !machine.dnsRelayRunning)

            // The same Stop through the actual composition: host, service, in-memory transport and framed client. The client and its
            // stream end inside the helper, so their release hops run during the awaits below, before the root is released.
            let clients = try host.makeInMemoryControlClient(
                limits: try controlProfile(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            // A witness stream read beside every step below until it ends, so it sees the host's own events as they are published.
            let witnessStream = try await clients.control.subscribe(.live, deadline: RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now))
            witness = Task { @MainActor in await readUntilEnd(witnessStream) }
            let viaClient = try await stopProxyThroughClient(clients.control)
            check("the client's snapshot shows the restarted proxy", viaClient.proxyShown)
            check("a proxy Stop through the framed client completes", viaClient.completed)
            check("the client's Stop clears the system proxy", !machine.service("Wi-Fi").routesThroughAProxy)
            var refusal: RuntimeStartRefusal?
            do {
                _ = try await host.startDNS(expecting: PrivateModuleSlots(proxy: nil, dns: observed.dns - 1, tunnels: nil))
            } catch let refused as RuntimeStartRefusal {
                refusal = refused
            }
            check("a request naming a moved revision is refused whole", refusal == .stale(.dns))
            check("the refused request starts nothing and writes nothing", !machine.dnsRelayRunning && savedDNS() == false)

            // The menu's saved DNS Start through the framed client: no configuration value, the client's own observed DNS revision, and
            // a causal receipt naming the runtime baseline its enable was conditional on and the one it wrote.
            let dns = try await savedStartThroughClient(clients.control, .dns)
            check("a saved DNS Start through the framed client enables DNS again",
                  dns.receipt?.modules == [ControlModuleReceipt(module: .dns, result: .started)]
                      && dns.receipt?.committedDNSForwarderEnabled == true && savedDNS() == true && machine.dnsRelayRunning)
            check("its receipt names the baseline its enable was conditional on and the newer one it wrote", dns.receipt.map { receipt in
                guard receipt.runtime.write == .persisted(reportedError: false), let prior = receipt.prior?.runtime,
                      let written = receipt.runtime.baseline else { return false }
                return written.version > prior.version
            } ?? false)
            check("the same Start at the revision it moved is refused whole", dns.staleRefused && savedDNS() == true)
            let tunnels = try await savedStartThroughClient(clients.control, .tunnels)
            check("a saved tunnels Start through the framed client binds the configured tunnel",
                  tunnels.receipt?.modules == [ControlModuleReceipt(module: .tunnels, result: .started)]
                      && tunnels.after.tunnelsRunState == .running && tunnels.after.dnsRunState == .running)
            check("its unchanged saved pair verifies without a rewrite", tunnels.receipt.map { receipt in
                receipt.runtime.write == .unchanged && receipt.prior?.runtime == receipt.runtime.baseline
                    && receipt.committedDNSForwarderEnabled == true
            } ?? false)
            // The app's preflight and its credentials notice, through the same client: the fake helper answers installed.
            let preflight = try await settleThroughClient(clients.control, .refreshPreflight(helperReplaced: true))
            check("a preflight refresh through the framed client reads the installed helper", {
                guard case .completed(let completion)? = preflight, case .preflight(let observation) = completion.result,
                      case .observed(let items) = observation.reading else { return false }
                return items.helper == .installed && !items.helperReadBusy
            }())
            let credentials = try await settleThroughClient(clients.control, .credentialsChanged)
            check("a credentials notice through the framed client completes", {
                guard case .completed(let completion)? = credentials else { return false }
                return completion.command == .credentialsChanged && completion.result == .settled
            }())

            let valid = try Data(contentsOf: environment.configFile)
            let malformed = Data("{".utf8)
            try malformed.write(to: environment.configFile)
            let refused = reloadResult(try await settleThroughClient(clients.control, .reload))
            check("a malformed file reloaded through the framed client is refused whole and left as it is",
                  refused == .refused(.invalidContent) && (try? Data(contentsOf: environment.configFile)) == malformed)
            try valid.write(to: environment.configFile)
            var external = try ProxyConfigPersistence.load(in: environment, allowMissing: false)
            external.profileName = "Reloaded through the client"
            try ProxyConfigPersistence.save(external, in: environment)
            let edited = try Data(contentsOf: environment.configFile)
            let adopted = reloadResult(try await settleThroughClient(clients.control, .reload))
            check("an external edit reloaded through the framed client is adopted and its reconcile attempted under its admission",
                  adopted == .adopted(.reconcileAttempted(currentAtEnd: true)) && host.status().profileName == external.profileName)
            check("the reload writes nothing", (try? Data(contentsOf: environment.configFile)) == edited)

            let quit = try await quitThroughClient(clients)
            let stored = try AppPreferencesPersistence.load(in: environment)
            check("a preferences save through the editor client writes the preferences file", quit.preferencesSaved && stored.automaticUpdateChecks)
            check("a framed Quit latches, admits its reserved preferences flush and completes", quit.completed)
            check("the reserved flush wrote the quit-time preferences",
                  quit.flushed && stored.preferredBrowserTestURL == "https://quit-flush.example.test/")
            check("the quit leaves every module down", host.status().state == "stopped" && host.status().dnsRunState != "running"
                && host.status().tunnelsRunState != "running")
            check("the quit restores system DNS", !machine.dnsRelayRunning)
            check("the quit persists no disable", savedDNS() == true)
            var afterQuit: RuntimeStartRefusal?
            do {
                _ = try await host.startProxy(conditionalDNS: true)
            } catch let refused as RuntimeStartRefusal {
                afterQuit = refused
            }
            check("no Start runs after the quit", afterQuit == .terminated)
            let seen = await witness?.value ?? StreamWitness()
            witness = nil
            check("the host's own typed events reach the actual stream", seen.dnsStartedEvent)
            check("the witness stream receives the Quit's settlement before its end", seen.quitFinished)
            check("the stream ends with hostShutdown after the quit's physical work", seen.ended == .streamClosed(.hostShutdown))

            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the module host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the module host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed

            // Each companion writes its own record beside its proxy member's; the refused Starts settle nothing.
            let written = settlements(Array(try typedEvents(in: environment.eventsFile).dropFirst(earlier))).map(\.settlement)
            check("each member and each companion records its own settlement once", written == [
                .explicit(.proxy, .started), .conditionalDNS(.started),
                .explicit(.proxy, .started), .conditionalDNS(.fenced),
                .explicit(.dns, .started), .explicit(.tunnels, .started),
            ])
        } catch {
            check("the module exercise completed without error", false)
            notes.append("module exercise error: \(error.localizedDescription)")
            await host.shutdown()
            // The quit's end ends the witness; a cancel covers a stream that never got one. Joined either way.
            witness?.cancel()
            _ = await witness?.value
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the module error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// What the witness stream saw: whether the saved DNS Start's typed settlement and the Quit's settlement reached it, and what ended it.
    /// Flags only, so reading holds nothing that grows with the stream.
    private struct StreamWitness {
        var dnsStartedEvent = false
        var quitFinished = false
        var ended: RuntimeClientError?
    }

    /// Reads one stream until it ends, bounded in frames and in each wait, so a stream that never ends fails a check instead of hanging.
    @MainActor
    private static func readUntilEnd(_ stream: RuntimeSubscription) async -> StreamWitness {
        var witness = StreamWitness()
        defer { stream.cancel() }
        for _ in 0..<4_096 {
            do {
                switch try await stream.next(RuntimeDeadline.after(.seconds(10), from: ContinuousClock.now)) {
                case .events(let batch):
                    for case .known(let event) in batch.events {
                        if case .lifecycle(.moduleSettled(let settlement, _))? = event.typed, settlement == .explicit(.dns, .started) {
                            witness.dnsStartedEvent = true
                        }
                    }
                case .operationFinished(let finished):
                    if case .completed(let completion) = finished.outcome, completion.command == .quit {
                        witness.quitFinished = true
                    }
                case .baseline, .snapshot, .replayCaughtUp, .end:
                    continue
                }
            } catch let error as RuntimeClientError {
                witness.ended = error
                return witness
            } catch {
                witness.ended = .unexpectedReply
                return witness
            }
        }
        return witness
    }

    /// A proxy Stop through the host's in-memory control client. Its stream ends when this returns; the stream's cancel queues the one hop
    /// that releases its subscriber.
    @MainActor
    private static func stopProxyThroughClient(_ client: any RuntimeClient) async throws -> (proxyShown: Bool, completed: Bool) {
        let deadline = RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now)
        let snapshot = try await client.readSnapshot(deadline: deadline)
        let stream = try await client.subscribe(.live, deadline: deadline)
        defer { stream.cancel() }
        _ = try await stream.next(deadline)
        let admission = try await client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: snapshot.stamp.incarnation, deadline: deadline
        )
        let proxyShown = snapshot.proxyState == .running
        guard case .accepted(let operation) = admission else { return (proxyShown, false) }
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline), finished.operationID == operation {
                let completed = if case .completed(let completion) = finished.outcome { completion.command == .stop } else { false }
                return (proxyShown, completed)
            }
        }
        return (proxyShown, false)
    }

    /// One saved Start of `module` through the host's framed client (decision 0037): it names the module revision the client's own snapshot
    /// stamp reads and carries no configuration value, and its settlement is the receipt the client reads. The same request is then sent
    /// again at that revision, which the Start moved, and the host must refuse it whole. `after` is the client's next snapshot.
    @MainActor
    private static func savedStartThroughClient(
        _ client: any RuntimeClient,
        _ module: ControlModule
    ) async throws -> (receipt: ControlConfigurationReceipt?, staleRefused: Bool, after: ControlRuntimeSnapshot) {
        let deadline = RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now)
        let snapshot = try await client.readSnapshot(deadline: deadline)
        guard let modules = snapshot.stamp.modules else { return (nil, false, snapshot) }
        let observed = switch module {
        case .proxy: modules.proxy
        case .dns: modules.dns
        case .tunnels: modules.tunnels
        }
        let stream = try await client.subscribe(.live, deadline: deadline)
        defer { stream.cancel() }
        _ = try await stream.next(deadline)
        func submit() async throws -> ControlAdmission {
            try await client.submit(
                .start(module, ifModuleRevision: observed), requestID: ControlRequestID(rawValue: UUID()),
                expectedIncarnation: snapshot.stamp.incarnation, deadline: deadline
            )
        }
        var receipt: ControlConfigurationReceipt?
        if case .accepted(let operation) = try await submit() {
            for _ in 0..<64 {
                if case .operationFinished(let finished) = try await stream.next(deadline), finished.operationID == operation {
                    if case .configurationSettled(let settled) = finished.outcome { receipt = settled }
                    break
                }
            }
        }
        let staleRefused = try await submit() == .rejected(.staleRevision)
        return (receipt, staleRefused, try await client.readSnapshot(deadline: deadline))
    }

    /// One command through the host's framed client, and its settlement, nil when it was not admitted or never settled within the bound.
    @MainActor
    private static func settleThroughClient(_ client: any RuntimeClient, _ command: ControlRuntimeCommand) async throws -> ControlOperationOutcome? {
        let deadline = RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now)
        let incarnation = try await client.readSnapshot(deadline: deadline).stamp.incarnation
        let stream = try await client.subscribe(.live, deadline: deadline)
        defer { stream.cancel() }
        _ = try await stream.next(deadline)
        let admission = try await client.submit(
            command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: deadline
        )
        guard case .accepted(let operation) = admission else { return nil }
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline), finished.operationID == operation {
                return finished.outcome
            }
        }
        return nil
    }

    /// The reload answer a settlement carries, nil for any other outcome.
    private static func reloadResult(_ outcome: ControlOperationOutcome?) -> ControlReloadResult? {
        guard case .completed(let completion)? = outcome, case .reload(let result) = completion.result else { return nil }
        return result
    }

    /// A preferences save through the editor client, then the process quit through the framed client with its reserved preferences flush,
    /// all over the one composition. Each answer is the client's own; files are read only after their operation settled.
    @MainActor
    private static func quitThroughClient(_ clients: RuntimeInMemoryClients) async throws -> (preferencesSaved: Bool, completed: Bool, flushed: Bool) {
        let deadline = RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now)
        let incarnation = try await clients.control.readSnapshot(deadline: deadline).stamp.incarnation
        let stream = try await clients.control.subscribe(.live, deadline: deadline)
        defer { stream.cancel() }
        _ = try await stream.next(deadline)
        func settled(_ admission: ControlAdmission) async throws -> ControlOperationOutcome? {
            guard case .accepted(let operation) = admission else { return nil }
            for _ in 0..<64 {
                if case .operationFinished(let finished) = try await stream.next(deadline), finished.operationID == operation {
                    return finished.outcome
                }
            }
            return nil
        }
        func preferences(
            _ requestID: ControlRequestID = ControlRequestID(rawValue: UUID()),
            _ edit: (inout AppPreferences) -> Void
        ) async throws -> ControlOperationOutcome? {
            let answer = try await clients.editor.read(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                budget: try ControlWireBudget(1_000), deadline: deadline
            )
            guard case .observation(let observed) = answer, let baseline = observed.components.preferences.baseline else { return nil }
            var values = try PrivateConfigurationBridge.makeValues(from: observed).preferences
            edit(&values)
            let request = try PrivateConfigurationBridge.makePreferencesRequest(
                preferences: values, requestID: requestID, incarnation: incarnation,
                budget: try ControlWireBudget(1_000), preferencesBaseline: baseline
            )
            return try await settled(try await clients.editor.submitPreferences(requestID: requestID, deadline: deadline) { request })
        }
        func written(_ outcome: ControlOperationOutcome?) -> Bool {
            guard case .preferencesSettled(let receipt)? = outcome else { return false }
            return receipt.preferences.write == .persisted(reportedError: false)
        }
        let earlier = ControlRequestID(rawValue: UUID())
        let saved = written(try await preferences(earlier) { $0.automaticUpdateChecks = true })
        let answer = try await clients.editor.read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
            budget: try ControlWireBudget(1_000), deadline: deadline
        )
        guard case .observation(let observed) = answer, let baseline = observed.components.preferences.baseline else {
            return (saved, false, false)
        }
        var final = try PrivateConfigurationBridge.makeValues(from: observed).preferences
        final.preferredBrowserTestURL = "https://quit-flush.example.test/"
        // The bounded client quit: the framed Quit fences first and names the final save's ID, minted inside it, so only that save may
        // spend the reservation; the save waits for the earlier update's settlement before it takes the one frozen-input slot.
        let result = await RuntimeClientQuit.quit(
            control: clients.control, editor: clients.editor, incarnation: incarnation, total: .seconds(10), priorUpdate: earlier,
            preferences: { [final] requestID, _ in
                try PrivateConfigurationBridge.makePreferencesRequest(
                    preferences: final, requestID: requestID, incarnation: incarnation,
                    budget: try ControlWireBudget(1_000), preferencesBaseline: baseline
                )
            }
        )
        let flushed = if case .settled(let outcome) = result.preferences { written(outcome) } else { false }
        let completed = if case .settled(.completed(let completion)) = result.quit { completion.command == .quit } else { false }
        return (saved, completed, flushed)
    }

    /// This scenario's own control-service profile. Every value is explicit and scenario-only, sized for one client and a handful of
    /// operations; none is a shipping default. The event ring and the ingress carry the host's own events, so they are sized for a
    /// Start's or a quit's burst, and one more subscriber holds the witness stream beside each step's own.
    private static func controlProfile() throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: 4096, maxReplyBytes: 64 * 1024,
            aliasCapacityPerPartition: 8, aliasByteCapacityPerPartition: 1 << 20,
            ordinaryPendingCapacity: 2, outcomeCapacity: 8, outcomeByteCapacity: 1 << 20,
            retentionAge: .seconds(60), janitorBatch: 4,
            ordinaryLaneCapacity: 2, readLaneCapacity: 2, streamLaneCapacity: 2, stopLaneCapacityPerModule: 1, subscriberLimit: 3,
            ringCapacity: 256, ringByteCapacity: 1 << 18, maxEventBytes: 4096,
            ingressCapacity: 256, ingressByteCapacity: 1 << 18, drainItemsPerTurn: 32, drainBytesPerTurn: 1 << 16,
            controlLogCapacity: 8, controlLogByteCapacity: 1 << 14, replayChunkItems: 32, replayChunkBytes: 1 << 14,
            collectionRowCapacity: 16, collectionByteCapacity: 1 << 14, collectionProofCapacityPerKind: 4,
            collectionRowRevisionsPerKind: 2, collectionRetainedByteCapacity: 1 << 14, collectionRowRetentionAge: .seconds(60),
            latestSnapshotByteCapacity: 1 << 14, subscriberRecordBytes: 256, retainedByteCeiling: 1 << 24
        )
    }

    /// An external edit that only respells the PAC URL (#246), reloaded into a running actual host. Precomposed `é` and `e` with a
    /// combining accent differ in UTF-8 only; the user's bytes are the intent (decisions 0023, 0027), so the reload must fetch the PAC
    /// from the new bytes rather than keep the script from the old ones. The check is the URL bytes the PAC fake was asked for.
    @MainActor
    private static func exerciseRespelledPACReload(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let pac = LastFetchPAC()
        let composed = "http://pac.example.test/caf\u{E9}.pac"
        let decomposed = "http://pac.example.test/cafe\u{301}.pac"
        check("the fixture's two spellings differ in UTF-8", !composed.utf8.elementsEqual(decomposed.utf8))
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = true
        config.pacURL = composed
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let host: RuntimeHost
        do {
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
                effects: effects(fakes, home: home, pac: pac)
            )
        } catch {
            notes.append("respelling host did not open: \(error.localizedDescription)")
            check("the respelling host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        do {
            try await host.startRuntime()
            check("the start fetches the PAC from the saved bytes",
                  pac.fetchCount == 1 && pac.lastFetchedUTF8 == Array(composed.utf8))

            var respelled = config
            respelled.pacURL = decomposed
            try ProxyConfigPersistence.save(respelled, in: environment)
            await host.reloadConfiguration()
            notes.append("PAC fetches after the respelling reload: \(pac.fetchCount)")
            check("a reload that only respells the PAC URL fetches it again", pac.fetchCount == 2)
            check("the reload's fetch uses the respelled bytes", pac.lastFetchedUTF8 == Array(decomposed.utf8))

            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the respelling host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the respelling host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed
        } catch {
            check("the respelling exercise completed without error", false)
            // The error path joins the host's work before anything is released: stop, settle, then flush, then judge.
            notes.append("respelling exercise error: \(error.localizedDescription)")
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the respelling error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// A Start beside a missing platform sidecar, after an outside editor added a legacy platform value to the owned runtime file, through
    /// the actual host over the run's fakes. The platform's first write checks the runtime bytes the host opened with, so it holds and
    /// creates no sidecar over the edited value. The runtime write is held behind it, and the next Start finds both files latched.
    @MainActor
    private static func exerciseSourceChanged(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let host: RuntimeHost
        // The earlier hosts' events share the owned file, so only the events after this count are this host's.
        let earlier: Int
        do {
            earlier = try typedEvents(in: environment.eventsFile).count
            try ProxyConfigPersistence.save(config, in: environment)
            try FileManager.default.removeItem(at: environment.platformConfigFile)
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home)
            )
        } catch {
            notes.append("source host did not open: \(error.localizedDescription)")
            check("the source host opened beside a missing platform sidecar", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        do {
            // The outside editor adds a legacy platform value to the owned scratch runtime file after the open.
            let saved = try Data(contentsOf: environment.configFile)
            guard var object = try JSONSerialization.jsonObject(with: saved) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object["manageSystemProxy"] = true
            let edited = try JSONSerialization.data(withJSONObject: object)
            try edited.write(to: environment.configFile)

            // The refusal's type is internal to the host; the typed events below name why each start held.
            var started = 0
            for _ in 0..<2 {
                do {
                    try await host.startRuntime()
                    started += 1
                } catch {
                    notes.append("source start refused: \(error.localizedDescription)")
                }
            }
            check("both starts are refused", started == 0)
            check("no platform sidecar is created over the edited runtime file",
                  !FileManager.default.fileExists(atPath: environment.platformConfigFile.path))
            check("the edited runtime file is kept", (try? Data(contentsOf: environment.configFile)) == edited)
            check("a held start applies no system proxy", machine.service("Wi-Fi").webProxy.enabled == false)

            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the source host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the source host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed

            let typed = Array(try typedEvents(in: environment.eventsFile).dropFirst(earlier))
            check("the platform's first write is held for its changed source",
                  typed.contains(.configWorkflow(.committed(ConfigurationWorkflowCommitted(file: .platform, write: .notAttempted(.sourceChanged))))))
            check("the runtime write is held behind the platform",
                  typed.contains(.configWorkflow(.committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.heldBehindPlatform))))))
            check("the start holds on the platform commit",
                  typed.contains(.configWorkflow(.held(ConfigurationWorkflowHeld(phase: .start, input: .platform, reason: .commitFailed)))))
            check("the next start finds the platform latched",
                  typed.contains(.configWorkflow(.committed(ConfigurationWorkflowCommitted(file: .platform, write: .notAttempted(.noBaseline))))))
            check("the next start finds the runtime latched",
                  typed.contains(.configWorkflow(.committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.noBaseline))))))
        } catch {
            check("the source exercise completed without error", false)
            // The error path joins the host's work before anything is released: stop, settle, then flush, then judge.
            notes.append("source exercise error: \(error.localizedDescription)")
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the source error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// System wake through the actual host, the twin of `AppState.handleSystemWake`, over the run's fakes and its own wake fake. The host
    /// observes wake from open; a wake while stopped runs only the kernel's wake path; a wake while the forwarder runs re-pins the interface
    /// a simulated VPN client rewrote; a module Stop keeps observing; the quit ends observation in its admission, and a wake already in
    /// flight then does nothing. The kernel's wake path is read back from the owned events file after a confirmed flush.
    @MainActor
    private static func exerciseWake(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        let wake = FakeSystemWakeObserver()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let host: RuntimeHost
        // The earlier hosts' events share the owned file, so only the records after this count are this host's.
        let earlier: Int
        do {
            earlier = try recordedEvents(in: environment.eventsFile).count
            try ProxyConfigPersistence.save(config, in: environment)
            try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemDNS: true), in: environment)
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home, wake: wake)
            )
        } catch {
            notes.append("wake host did not open: \(error.localizedDescription)")
            check("the wake host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }
        func dnsServers() throws -> String {
            try machine.run("/usr/sbin/networksetup", ["-getdnsservers", "Wi-Fi"]).standardOutput
        }
        func kernelWakes() throws -> Int {
            try recordedEvents(in: environment.eventsFile).dropFirst(earlier)
                .filter { $0.event == "dns.transports_reset" && $0.detail == "source=system_wake" }.count
        }
        /// Settles the stopped host's deliveries and confirms a flush, so the file holds what they recorded.
        func settledAndFlushed() async -> Bool {
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            return settled == .settled && flush.allConfirmed
        }

        var quiesced = false
        do {
            check("the host observes wake from open", wake.isObserving && wake.startCount == 1)

            let writesBefore = machine.privilege.commands(matching: .setDNSServers).count
            wake.emitWake()
            check("a wake while stopped settles and flushes", await settledAndFlushed())
            check("a wake while stopped runs the kernel's wake path", try kernelWakes() == 1)
            check("a wake while stopped writes no DNS", machine.privilege.commands(matching: .setDNSServers).count == writesBefore)

            try await host.startRuntime()
            check("the start pins the interface to the forwarder", try dnsServers() == "127.0.0.1")
            // A VPN client re-asserts its own resolvers over sleep, through the machine's own DNS write.
            try machine.execute(.setDNSServers, values: ["Wi-Fi", "10.9.9.9"])
            wake.emitWake()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while try dnsServers() != "127.0.0.1", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            check("a wake while the forwarder runs re-pins the rewritten interface", try dnsServers() == "127.0.0.1")

            await host.stopRuntime()
            check("a Stop that leaves every module down keeps observing wake", wake.isObserving && wake.stopCount == 0)

            let inFlight = wake.pendingWake()
            await host.shutdown()
            check("the quit ends wake observation once", !wake.isObserving && wake.stopCount == 1)
            let writesAtQuit = machine.privilege.commands(matching: .setDNSServers).count
            inFlight?()
            wake.emitWake()
            quiesced = await settledAndFlushed()
            check("the wake host settles and its observability flush is confirmed", quiesced)
            check("the kernel's wake path ran once while stopped and once while running, and not after the quit", try kernelWakes() == 2)
            check("a wake in flight at the quit writes no DNS", machine.privilege.commands(matching: .setDNSServers).count == writesAtQuit)
        } catch {
            check("the wake exercise completed without error", false)
            // The error path joins the host's work before anything is released: quit, settle, then flush, then judge.
            notes.append("wake exercise error: \(error.localizedDescription)")
            await host.shutdown()
            quiesced = await settledAndFlushed()
            assertions.append(.init("the wake error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// The connection audit through the actual host, as the app composes it (#222). Audit is on at the root's default path. One loopback
    /// request, its query carrying a value no row may hold, goes through the host's listener; the default no-proxy list routes it DIRECT
    /// to an origin this exercise owns, so no upstream or Kerberos token is involved. After the stop and a confirmed flush, the owned
    /// `audit.ndjson` holds that request's one row, its query redacted, and one row for each connection of the mixed-priority burst.
    @MainActor
    private static func exerciseConnectionAudit(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let secret = "audit-secret-6f2c"
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.logging.auditLogEnabled = true
        let auditFile = environment.configDirectory.appendingPathComponent("audit.ndjson")
        let path = FakeNetworkPathObserver()
        let host: RuntimeHost
        do {
            try ProxyConfigPersistence.save(config, in: environment)
            try PlatformConfigPersistence.save(
                PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true), in: environment
            )
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home, path: path)
            )
        } catch {
            notes.append("audit host did not open: \(error.localizedDescription)")
            check("the audit host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        // The origin: without auth, the fake upstream answers any plain GET with a complete 200. Every path stops it after the host.
        let origin = FakeUpstreamProxy(
            group: MultiThreadedEventLoopGroup.singleton, originHost: "127.0.0.1", originPort: 9, requireAuth: false
        )
        do {
            try await origin.start()
            let originPort = origin.port
            try await host.startRuntime()
            guard let proxyPort = host.status().bindings.proxyPort else {
                throw ScenarioExecutionError(message: "the audit host bound no listener")
            }
            let response = try await RawHTTPAuditClient.request(
                group: MultiThreadedEventLoopGroup.singleton, host: "127.0.0.1", port: proxyPort,
                request: "GET http://127.0.0.1:\(originPort)/v1/resource?token=\(secret) HTTP/1.1\r\n"
                    + "Host: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
            )
            check("the host serves the loopback request", response.hasPrefix("HTTP/1.1 200"))
            // The orchestrator hands the row to its sink in the main-actor step that closes the connection, queued after the request's
            // completion; both counts mean the row was handed over.
            var closed = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !closed, ContinuousClock.now < deadline {
                let metrics = host.status().metrics
                closed = metrics.requestsHandled >= 1 && metrics.openConnections == 0
                if !closed { try await Task.sleep(for: .milliseconds(1)) }
            }
            check("the served request's connection closes", closed)

            // A burst of connections from clients at every task priority, with owner jobs at every priority queued beside the
            // connection callbacks' hops. A close whose hop ran before its open's would leave a connection counted open and its row
            // unwritten, so the counts and the rows below witness the order.
            let burst = 16
            let priorities: [TaskPriority] = [.background, .utility, .medium, .userInitiated, .high]
            let load = (0..<128).map { index in
                Task(priority: priorities[index % priorities.count]) { @MainActor in _ = host.status() }
            }
            let requests = (0..<burst).map { index in
                Task.detached(priority: priorities[index % priorities.count]) { () -> Bool in
                    let response = try? await RawHTTPAuditClient.request(
                        group: MultiThreadedEventLoopGroup.singleton, host: "127.0.0.1", port: proxyPort,
                        request: "GET http://127.0.0.1:\(originPort)/v1/item/\(index) HTTP/1.1\r\n"
                            + "Host: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
                    )
                    return response?.hasPrefix("HTTP/1.1 200") == true
                }
            }
            var servedBurst = 0
            for request in requests {
                if await request.value { servedBurst += 1 }
            }
            for job in load { await job.value }
            check("every request of the mixed-priority burst is served", servedBurst == burst)
            var burstClosed = false
            let burstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !burstClosed, ContinuousClock.now < burstDeadline {
                let metrics = host.status().metrics
                burstClosed = metrics.requestsHandled >= 1 + burst && metrics.openConnections == 0
                if !burstClosed { try await Task.sleep(for: .milliseconds(1)) }
            }
            check("the mixed-priority burst leaves no connection open", burstClosed)

            // The path observer follows the modules (#260): a Stop that leaves none up stops it, the next Start observes again, and a
            // report delivered after that restart reaches the host's path handling. The real adapter's restart is `NetworkMonitorTests`.
            check("the path observer runs while the proxy runs", path.isObserving)
            await host.stopRuntime()
            check("a Stop that leaves every module down stops the path observer", !path.isObserving)
            try await host.startRuntime()
            check("a Start after that Stop observes the path again", path.isObserving)
            path.emit(NetworkPathState(
                status: .satisfied, interfaces: [.init(name: "en0", type: "wifi")], gateways: ["192.0.2.1"],
                supportsIPv4: true, supportsIPv6: false, supportsDNS: true
            ))
            var pathHandled = false
            let pathDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !pathHandled, ContinuousClock.now < pathDeadline {
                _ = await host.flushEvents()
                pathHandled = try recordedEvents(in: environment.eventsFile).contains { $0.event == "network.path_changed" }
                if !pathHandled { try await Task.sleep(for: .milliseconds(10)) }
            }
            check("a path report after the restart reaches the host's path handling", pathHandled)

            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the audit host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the audit host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed

            let text = try String(contentsOf: auditFile, encoding: .utf8)
            let decoder = ConnectionAuditRecord.canonicalDecoder
            let rows = try text.split(separator: "\n").map { try decoder.decode(ConnectionAuditRecord.self, from: Data($0.utf8)) }
            notes.append("audit rows: \(rows.count)")
            let served = rows.filter { $0.target.hasPrefix("http://127.0.0.1:\(originPort)/v1/resource") }
            check("the owned audit file holds the served request's one row", served.count == 1)
            check("the row keeps the target's authority and path and redacts its query",
                  served.first?.target == "http://127.0.0.1:\(originPort)/v1/resource?<redacted>")
            check("the row records the DIRECT route", served.first?.chosenUpstream == "DIRECT")
            check("no row carries the query value", !text.contains(secret))
            let burstRows = rows.filter { $0.target.hasPrefix("http://127.0.0.1:\(originPort)/v1/item/") }
            check("each connection of the mixed-priority burst has its one row",
                  burstRows.count == burst && Set(burstRows.map(\.id)).count == burst && rows.count == 1 + burst)
        } catch {
            check("the audit exercise completed without error", false)
            // The error path joins the host's work before anything is released: stop, settle, then flush, then judge.
            notes.append("audit exercise error: \(error.localizedDescription)")
            await host.stopRuntime()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the audit error path settled the host and confirmed its flush", quiesced))
        }
        await origin.stop()
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// A reload's flag action held on the host's platform queue, through the actual host and its framed client (#47). The saved platform
    /// file turns the environment switch on while the proxy runs, so the reload's pass applies it; the apply's first `launchctl setenv` is
    /// parked. While it is out, the client's snapshot answers and a proxy Stop is admitted, and the listener is still bound: the Stop's
    /// teardown waits for the action already running. A VPN drop taken meanwhile queues its entry-file removal behind the parked work
    /// rather than running it on the owner. Released, the Stop's clears land after the apply, so no variable is left, no entry file
    /// outlives the tunnel, and the reload reports its pass not current.
    @MainActor
    private static func exerciseHeldFlagAction(
        session: StateRootSession,
        environment: RuntimeEnvironment,
        fakes: Fakes,
        home: URL
    ) async -> Shutdown {
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let machine = fakes.machine
        let held = HeldSetenv()
        let vpn = FakeVPNStatusObserver()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        let host: RuntimeHost
        // The earlier hosts' events share the owned file, so only the events after this count are this host's.
        let earlier: Int
        do {
            earlier = try recordedEvents(in: environment.eventsFile).count
            try ProxyConfigPersistence.save(config, in: environment)
            try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemProxy: true, manageDNSResolvers: true), in: environment)
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: false,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: {},
                effects: effects(fakes, home: home, hold: held, vpn: vpn)
            )
        } catch {
            notes.append("flag host did not open: \(error.localizedDescription)")
            check("the flag host opened over the saved configuration", false)
            return Shutdown(quiesced: true, assertions: assertions, notes: notes, pinnedHost: nil)
        }

        var quiesced = false
        do {
            try await host.startRuntime()
            check("the flag host starts with the system proxy, the entry file and no environment",
                  machine.service("Wi-Fi").routesThroughAProxy && machine.launchdEnvironment.isEmpty
                      && machine.resolverFile(for: "corp.example") != nil)
            try PlatformConfigPersistence.save(
                PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageDNSResolvers: true),
                in: environment
            )
            let clients = try host.makeInMemoryControlClient(
                limits: try controlProfile(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            held.arm()
            let seen = try await reloadAndStopWhileHeld(clients.control, host: host, held: held, vpn: vpn, machine: machine)
            notes.append("environment writes by the held apply: \(held.writes); hold timed out: \(held.timedOut)")
            check("the flag action's write reaches the platform queue, not the main thread", seen.reached && !held.reachedOnMainThread)
            check("the framed snapshot answers while the flag action is held", seen.snapshotAnswered)
            check("a proxy Stop is admitted while the flag action is held", seen.stopAdmitted)
            check("the listener stays bound after the Stop's admission while the action is held", seen.listenerBoundWhileHeld)
            check("a VPN drop taken while the action is held queues its removal behind it", seen.dropQueuedBehindHeldWork)
            check("the held apply wrote the environment", held.writes > 0 && !held.timedOut)
            check("the Stop completes once the action is released", seen.stopCompleted)
            check("once released, the drop's removal lands before the Stop's system proxy restore", seen.dropLandedBeforeStopRestore)
            check("the Stop's clears land after the apply: no variable is left", machine.launchdEnvironment.isEmpty)
            check("the Stop clears the system proxy", !machine.service("Wi-Fi").routesThroughAProxy)
            check("no entry file outlives the tunnel or the Stop", machine.resolverFile(for: "corp.example") == nil)
            check("the reload reports its pass not current", seen.reload == .adopted(.reconcileAttempted(currentAtEnd: false)))

            // The process quit ends the composed service before the root is released.
            await host.shutdown()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            check("the flag host settles before its root is released", settled == .settled)
            let flush = await host.flushEvents()
            check("the flag host's observability flush is confirmed", flush.allConfirmed)
            quiesced = settled == .settled && flush.allConfirmed
            let decisions = try recordedEvents(in: environment.eventsFile).dropFirst(earlier)
                .filter { $0.event == "config.platform_integration" }.compactMap(\.detail)
            check("the reload decided one environment apply, before its effect", decisions == ["applyEnvironment"])
        } catch {
            check("the flag exercise completed without error", false)
            // The error path joins the host's work before anything is released: release the hold, stop, settle, then flush, then judge.
            notes.append("flag exercise error: \(error.localizedDescription)")
            held.release()
            await host.shutdown()
            let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
            let flush = await host.flushEvents()
            quiesced = settled == .settled && flush.allConfirmed
            assertions.append(.init("the flag error path settled the host and confirmed its flush", quiesced))
        }
        return Shutdown(quiesced: quiesced, assertions: assertions, notes: notes, pinnedHost: quiesced ? nil : host)
    }

    /// What the client saw around the held flag action.
    private struct HeldFlagWitness {
        var reached = false
        var snapshotAnswered = false
        var stopAdmitted = false
        var listenerBoundWhileHeld = false
        var dropQueuedBehindHeldWork = false
        var dropLandedBeforeStopRestore = false
        var stopCompleted = false
        var reload: ControlReloadResult?
    }

    /// A reload through the framed client whose flag action `held` parks, then a VPN drop and a proxy Stop while it is parked, then the
    /// release and both settlements. Every wait is bounded, and the hold is released on every path.
    @MainActor
    private static func reloadAndStopWhileHeld(
        _ client: any RuntimeClient, host: RuntimeHost, held: HeldSetenv, vpn: FakeVPNStatusObserver, machine: FakeMachine
    ) async throws -> HeldFlagWitness {
        defer { held.release() }
        var witness = HeldFlagWitness()
        let deadline = RuntimeDeadline.after(.seconds(30), from: ContinuousClock.now)
        let incarnation = try await client.readSnapshot(deadline: deadline).stamp.incarnation
        let stream = try await client.subscribe(.live, deadline: deadline)
        defer { stream.cancel() }
        _ = try await stream.next(deadline)
        func submit(_ command: ControlRuntimeCommand) async throws -> ControlOperationID? {
            let admission = try await client.submit(
                command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: deadline
            )
            guard case .accepted(let operation) = admission else { return nil }
            return operation
        }
        guard let reload = try await submit(.reload) else { return witness }
        let reachedBy = ContinuousClock.now.advanced(by: .seconds(5))
        while !held.isHeld, ContinuousClock.now < reachedBy {
            try await Task.sleep(for: .milliseconds(1))
        }
        witness.reached = held.isHeld
        guard witness.reached else { return witness }
        // The drop's delivery is queued on the main actor before the snapshot's round trip, so it has run by the time the snapshot
        // answers: an inline removal would be on the machine by then.
        let removalsBefore = machine.privilege.commands(matching: .removeDNS).count
        let commandsBefore = machine.privilege.commands.count
        vpn.emit(.disconnected(reason: .userInitiated))
        witness.snapshotAnswered = try await client.readSnapshot(deadline: deadline).proxyState == .running
        let stop = try await submit(.stop(.proxy))
        witness.stopAdmitted = stop != nil
        witness.listenerBoundWhileHeld = stop != nil && host.status().bindings.proxyPort != nil
        witness.dropQueuedBehindHeldWork = machine.privilege.commands(matching: .removeDNS).count == removalsBefore
            && machine.resolverFile(for: "corp.example") != nil
        held.release()
        var outcomes: [ControlOperationID: ControlOperationOutcome] = [:]
        for _ in 0..<128 where outcomes[reload] == nil || stop.map({ outcomes[$0] == nil }) == true {
            if case .operationFinished(let finished) = try await stream.next(deadline) {
                outcomes[finished.operationID] = finished.outcome
            }
        }
        witness.reload = reloadResult(outcomes[reload])
        if let stop, case .completed(let completion)? = outcomes[stop] { witness.stopCompleted = completion.command == .stop }
        // The drop's removal ran, and it ran before the Stop's system proxy restore, which was queued after it: the check above holds
        // only while the work is parked, and alone it would also pass for a drop that never queued anything. The restore is a batch of
        // setters, recorded one by one; nothing else here writes the system proxy after the drop.
        let systemProxyWrites: Set<PrivilegedOperation> = [
            .applySystemProxy, .clearSystemProxy, .setProxyBypass, .setAutoproxyURL, .disableAutoproxy, .setWebProxyEndpoint, .setAutoproxy,
        ]
        let landed = machine.privilege.commands.dropFirst(commandsBefore)
        let removal = landed.firstIndex { $0.command == .removeDNS && $0.values.first == "corp.example" }
        let restore = landed.firstIndex { systemProxyWrites.contains($0.command) }
        if let removal, let restore { witness.dropLandedBeforeStopRestore = removal < restore }
        return witness
    }

    /// Every record in the owned events file, typed or legacy, decoded through the canonical decoder. A line that does not decode is an
    /// error, not a skipped record, so the caller reports it.
    private static func recordedEvents(in file: URL) throws -> [RuntimeEvent] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let decoder = CanonicalJSON.decoder()
        return try text.split(separator: "\n").map { line in
            try decoder.decode(RuntimeEvent.self, from: Data(line.utf8))
        }
    }

    /// The typed payloads in the owned events file, decoded through the canonical decoder (decision 0033). A line that does not decode
    /// is an error, not a skipped record, so the caller reports it.
    private static func typedEvents(in file: URL) throws -> [RuntimeEventPayload] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let decoder = CanonicalJSON.decoder()
        return try text.split(separator: "\n").compactMap { line in
            try decoder.decode(RuntimeEvent.self, from: Data(line.utf8)).typed
        }
    }

    /// The `lifecycle.module_settled` values among `typed`, in file order.
    private static func settlements(_ typed: [RuntimeEventPayload]) -> [LifecycleModuleSettled] {
        typed.compactMap { payload -> LifecycleModuleSettled? in
            guard case .lifecycle(.moduleSettled(let settled)) = payload else { return nil }
            return settled
        }
    }

    /// A host logger over the kernel's own app-log file writer, in the run's scratch home. Until `holdNextOpen()` it keeps no file; after
    /// it, a fresh writer's open waits in its destination guard until `release()`, as a stalled volume would, so the host's drain of it is
    /// held. Lines are formatted once, as the app's store does.
    private final class HeldFileLogger: LogSink, RecordFileDestinationGuarding, @unchecked Sendable {
        private let directory: URL
        private let events = RuntimeEventLog(capacity: 16)
        private let file = NIOLockedValueBox<(any RotatingByteWriter)?>(nil)
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        init(directory: URL) { self.directory = directory }

        var minLevel: LogLevel { .debug }

        func holdNextOpen() {
            let writer = rotatingLogFile(
                url: directory.appendingPathComponent("proxy.log"), destinationGuard: self,
                gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: DiscardingLogSink()),
                eventLog: events, logger: DiscardingLogSink()
            )
            file.withLockedValue { $0 = writer }
        }

        /// Whether the open was reached, bounded.
        func joinHeld() -> Bool { entered.wait(timeout: .now() + 10) == .success }

        func release() { released.signal() }

        func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
            let line = Data((LogEntry(level: level, category: category, message: message).formatted() + "\n").utf8)
            file.withLockedValue { $0?.write(line) }
        }

        func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
            guard let writer = file.withLockedValue({ $0 }) else { return .drained }
            return await writer.drain(until: deadline)
        }

        func admit(destination: URL) throws {
            entered.signal()
            _ = released.wait(timeout: .now() + 10)
        }

        func admit(openedDescriptor descriptor: Int32, destination: URL) throws {}
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
        let terminalExits = NIOLockedValueBox(0)

        let host: RuntimeHost
        do {
            host = try await RuntimeHost.open(
                stateSession: session,
                logger: DiscardingLogSink(),
                startupAllowsMissing: true,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                terminalExit: { terminalExits.withLockedValue { $0 += 1 } },
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
            // The written settlements: the held port is the proxy member's own typed failure, the members it left unfinished are
            // superseded rather than failed, and the restart's members settle once each under its newer group.
            let written = settlements(try typedEvents(in: environment.eventsFile))
            notes.append("settlements: \(written.map { "\($0.settlement.module.rawValue)=\($0.settlement.outcome)@\($0.group)" })")
            check("the failed bind is the proxy member's typed failure, and its unfinished members are superseded",
                  written.prefix(3).map(\.settlement) == [.explicit(.proxy, .failed), .explicit(.dns, .superseded), .explicit(.tunnels, .superseded)])
            check("the restart's members each settle once",
                  written.dropFirst(3).map(\.settlement) == [.explicit(.proxy, .started), .explicit(.dns, .notConfigured), .explicit(.tunnels, .notConfigured)])
            check("each Start's settlements share its group, and the restart's is newer",
                  Set(written.prefix(3).map(\.group)).count == 1 && Set(written.dropFirst(3).map(\.group)).count == 1
                    && (written.first?.group ?? .max) < (written.last?.group ?? .min))
            check("a non-terminal stop does not call the terminal exit", terminalExits.withLockedValue { $0 } == 0)

            // The fake refuses a command the scenario did not plan, and the refusal is a failure, not a success.
            let refusal = try machine.run("/usr/bin/security", ["find-generic-password"])
            check("the fake machine refuses an unplanned command", refusal.exitCode != 0)
            quiesced = settled == .settled && flush.allConfirmed
            notes.append("joined: startRuntime and stopRuntime returned; settle=\(settled); flushEvents allConfirmed=\(flush.allConfirmed)")
            notes.append("not joined: the environment drift timer (weak self; it ends at its next tick, after the host is gone)")
        } catch {
            check("the start, restart and stop exercise completed without error", false)
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

/// Parks the first `launchctl setenv` after `arm()` until `release()`, so the flag exercise can act while that write is out. A call on the
/// main thread is never parked, as a host running the write inline would make it: it is recorded instead. The park is bounded, so a
/// release the exercise never reaches fails its checks instead of hanging the run. Counts the writes it saw.
private final class HeldSetenv: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = false
    private var reached = false
    private var onMainThread = false
    private var released = false
    private var setenvCount = 0
    private var parkTimedOut = false

    var isHeld: Bool { lock.withLock { reached } }
    var reachedOnMainThread: Bool { lock.withLock { onMainThread } }
    var writes: Int { lock.withLock { setenvCount } }
    var timedOut: Bool { lock.withLock { parkTimedOut } }

    func arm() {
        lock.withLock { armed = true }
    }

    func pass(_ launchPath: String, _ arguments: [String]) {
        guard launchPath == "/bin/launchctl", arguments.first == "setenv" else { return }
        let isMain = Thread.isMainThread
        let park = lock.withLock { () -> Bool in
            setenvCount += 1
            guard armed else { return false }
            armed = false
            reached = true
            onMainThread = isMain
            return !isMain
        }
        guard park, gate.wait(timeout: .now() + 10) == .timedOut else { return }
        lock.withLock { parkTimedOut = true }
    }

    /// Lets the parked write go on. Idempotent.
    func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { gate.signal() }
    }
}

/// Keeps only the count and latest URL of the PAC fetches made by the respelling scenario.
private final class LastFetchPAC: PacEvaluator, @unchecked Sendable {
    private struct DirectOnly: PacScriptEvaluating {
        func resolveProxyChain(for url: URL) throws -> [String] { ["DIRECT"] }
    }

    private let lock = NSLock()
    private var count = 0
    private var last: [UInt8]?

    var fetchCount: Int { lock.withLock { count } }
    var lastFetchedUTF8: [UInt8]? { lock.withLock { last } }

    func fetchPAC(from urlString: String) async throws -> String {
        lock.withLock {
            count += 1
            last = Array(urlString.utf8)
        }
        return #"function FindProxyForURL(url, host) { return "DIRECT"; }"#
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { DirectOnly() }

    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { _ in nil }
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
