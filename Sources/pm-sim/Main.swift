// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

@main
enum PMSim {
    static func main() async {
        defer { ConsoleLogSink().flush() }
        let args = CommandLine.arguments
        let verbose = args.contains("--verbose")
        let perfBaseline = args.contains("--perf-baseline")

        if args.contains("--help") || args.contains("-h") {
            print("""
            pm-sim - end-to-end simulator for Conduit CONNECT tunnel behavior

            USAGE: pm-sim [SCENARIO] [OPTIONS]

            SCENARIOS:
              all                     Run every scenario (default)
              baseline                Single bursty stream, sanity check
              silent-then-burst       Server silent for 8s then 128KB burst
              multi                   30 concurrent bursty streams for 10s
              multi-small             10 concurrent bursty streams for 10s
              high-throughput         Single stream, 1ms / 64KB chunks for 5s
              multi-100               100 concurrent bursty streams for 10s
              bounded-writers         Slow storage, bounded queues and append amplification
              pac-fetch-bounds        Bounded PAC downloads and last-good retention
              shared-inbound-budget   Mixed HTTP/SOCKS admission and handshake deadlines
              connection-flood        Saturate inbound connection cap, then verify recovery
              auth-storm              Saturate pending auth handshakes, verify bounded rejection
              long-silent             Single stream, 30s of silence then 256KB burst
              keepalive               Verify OS accepts TCP keepalive socket options
              health-check            5 health checks through the pool (orchestrator behavior)
              failover                Stop upstream1, verify switchToNextUpstream recovers via upstream2
              flood-slow-drain        AE5F6815 repro: fast origin flood + slow client, verify no truncation
              forced-proxy-precedence Routing: force rules override PAC DIRECT across proxy protocols
              direct-mode-silence     Phase 2: prove expected-direct causes log .info, not .error
              vpn-flap-idle           idle CONNECT tunnel survives a brief VPN flap
              vpn-flap-stream         streaming HTTP response survives a brief VPN flap
              vpn-flap-long-outage    long outage transitions to .vpnDisconnected, recovers on reconnect
              vpn-user-disconnect     user-initiated disconnect is fast-path (no probe cycle)
              vpn-rapid-flap-burst    6 flaps in 1.5s emit one event pair (coalesce)
              transparent-direct      intercepted SNI client relays direct on VPN-down, upstream otherwise
              network-transition      Wi-Fi → VPN → captive portal → resume; recovery <5s, DoH recycled
              upstream-flap           upstream up/down/up; assert breaker opens, half-opens, closes
              websocket-upgrade       101 upgrade relayed, frames flow both ways
              connect-early-direct    CONNECT with early bytes through a direct tunnel
              connect-early-upstream  CONNECT with early bytes through an authenticated upstream
              server-first-connect    CONNECT: upstream greeting coalesced with the 200 reaches the client
              server-first-socks5     SOCKS5: upstream greeting coalesced with the 200 reaches the client
              audit-hop-response      Audit: proxied HTTP response hop-by-hop header leak
              audit-socks5-rsv        Audit: SOCKS5 CONNECT non-zero RSV handling
              audit-expect-trailers   Audit: Expect: 100-continue answered, trailers passed through
              dns-doh-blocked         DNS: internal server dead + DoH answering 404 still answers the client
              dns-ephemeral-pair-rebind  DNS: a taken TCP twin moves the port-0 UDP+TCP pair to a fresh port
              observable-target-redaction  Query/fragment privacy across observations
              security-boundaries     Auth destinations, config rejection, and loopback listeners
              kerberos-service-ticket A TGT without a service ticket is unreachable, not a missing credential

            OPTIONS:
              --verbose               Stream per-handler debug logs to stderr
              --perf-baseline         Default to multi-100 and emit process CPU/RSS baseline NDJSON
              --self-test-outcomes     Test-only fixtures: pass, fail, throw, missing, empty, mixed, timeout, cleanup
              --inject-failed-assertion  Test-only: fail the first real scenario assertion
              --help, -h              Show this help

            Pipeline under test:
              FakeClient → LocalProxyServer → FakeUpstreamProxy → FakeOrigin
            """)
            return
        }

        let scenario = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? (perfBaseline ? "multi-100" : "all")
        let usageStart = ProcessResourceUsage.capture()
        let wallStart = Date()

        let names: [String]
        if args.contains("--self-test-outcomes") {
            // Deliberate isolated reporting fixtures, never selected by "all".
            switch scenario {
            case "mixed": names = ["fixture-pass", "fixture-fail", "fixture-throw", "fixture-pass"]
            case "cleanup": names = ["fixture-setup-throw", "fixture-cleanup-witness"]
            default: names = ["fixture-" + scenario]
            }
        } else {
            guard scenario == "all" || scenarioNames.contains(scenario) else {
                printResults([.failure(name: scenario, error: ScenarioExecutionError(message: "unknown scenario"))])
                exit(2)
            }
            names = scenario == "all" ? scenarioNames : [scenario]
        }
        let failed = await execute(names, args: args, verbose: verbose)
        if perfBaseline {
            let usage = ProcessResourceUsage.capture().delta(from: usageStart, wallSeconds: Date().timeIntervalSince(wallStart))
            printResults([], processUsage: usage)
        }
        ConsoleLogSink().flush()
        if failed { exit(1) }
    }

    private static func execute(_ names: [String], args: [String], verbose: Bool) async -> Bool {
        var failed = false
        for name in names {
            // A hung scenario or cleanup must fail CI, not wait forever. The
            // longest intentional silence is 30 s; allow 120 s for the entire
            // scenario including teardown, independently of the main actor.
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            let deadlineSeconds = args.contains("--self-test-outcomes") && name == "fixture-timeout" ? 0.05 : 120.0
            watchdog.schedule(deadline: .now() + deadlineSeconds)
            watchdog.setEventHandler { @Sendable in
                printResults([.failure(name: name, error: ScenarioExecutionError(message: "scenario/cleanup deadline exceeded"))])
                ConsoleLogSink().flush()
                exit(1)
            }
            watchdog.resume()
            var results = await Task { @MainActor in
                let cleanup = ScenarioCleanup()
                let results: [ScenarioResult]
                do {
                    results = try await ScenarioCleanup.$current.withValue(cleanup) {
                        try await runScenario(name, verbose: verbose)
                    }
                } catch {
                    results = [.failure(name: name, error: error)]
                }
                await cleanup.drain()
                return results
            }.value
            watchdog.cancel()
            if results.isEmpty {
                results = [.failure(name: name, error: ScenarioExecutionError(message: "scenario produced no results"))]
            }
            if args.contains("--inject-failed-assertion") {
                results = results.map { $0.injectingFailedAssertion() }
            }
            // Emit immediately: a later throw must not erase earlier diagnostics.
            printResults(results)
            fflush(nil)
            failed = failed || results.contains { !$0.passed }
        }
        return failed
    }

    // Single list drives the complete suite; each entry is dispatched below.
    static let scenarioNames = [
        "baseline",
        "silent-then-burst",
        "multi",
        "multi-small",
        "high-throughput",
        "multi-100",
        "bounded-writers",
        "pac-fetch-bounds",
        "shared-inbound-budget",
        "connection-flood",
        "auth-storm",
        "long-silent",
        "keepalive",
        "health-check",
        "failover",
        "flood-slow-drain",
        "forced-proxy-precedence",
        "direct-mode-silence",
        "vpn-flap-idle",
        "vpn-flap-stream",
        "vpn-flap-long-outage",
        "vpn-user-disconnect",
        "vpn-rapid-flap-burst",
        "transparent-direct",
        "network-transition",
        "upstream-flap",
        "websocket-upgrade",
        "connect-early-direct",
        "connect-early-upstream",
        "server-first-connect",
        "server-first-socks5",
        "audit-hop-response",
        "audit-socks5-rsv",
        "audit-expect-trailers",
        "dns-doh-blocked",
        "dns-ephemeral-pair-rebind",
        "observable-target-redaction",
        "security-boundaries",
        "kerberos-service-ticket",
        "helper-caller-identity",
    ]

    @MainActor private static var setupCleanupCompleted = false

    @MainActor
    static func runScenario(_ name: String, verbose: Bool) async throws -> [ScenarioResult] {
        switch name {
        case "baseline":
            return [try await Scenarios.baselineBurst(verbose: verbose)]
        case "silent-then-burst":
            return [try await Scenarios.silentThenBurst(silentForMs: 8_000, burstBytes: 131_072, verbose: verbose)]
        case "multi":
            return [try await Scenarios.multiConcurrent(clientCount: 30, durationSeconds: 10, verbose: verbose)]
        case "multi-small":
            return [try await Scenarios.multiConcurrent(clientCount: 10, durationSeconds: 10, verbose: verbose)]
        case "high-throughput":
            return [try await Scenarios.highThroughput(durationSeconds: 5, verbose: verbose)]
        case "multi-100":
            return [try await Scenarios.multiConcurrent(clientCount: 100, durationSeconds: 10, verbose: verbose)]
        case "bounded-writers":
            return [try await BoundedWriterScenarios.slowStorage()]
        case "pac-fetch-bounds":
            return [try await PACFetchScenarios.bounds()]
        case "helper-caller-identity":
            return [try HelperCallerIdentityScenarios.run()]
        case "shared-inbound-budget":
            return [try await AdmissionScenarios.sharedBudget(verbose: verbose)]
        case "connection-flood":
            return [try await Scenarios.connectionFlood(verbose: verbose)]
        case "auth-storm":
            return [try await Scenarios.authStorm(verbose: verbose)]
        case "long-silent":
            return [try await Scenarios.silentThenBurst(silentForMs: 30_000, burstBytes: 262_144, verbose: verbose)]
        case "keepalive":
            return [try await OrchestratorScenarios.keepaliveReadback(verbose: verbose)]
        case "health-check":
            return [try await OrchestratorScenarios.healthCheck(verbose: verbose)]
        case "failover":
            return [try await OrchestratorScenarios.upstreamFailover(verbose: verbose)]
        case "flood-slow-drain":
            return [try await Scenarios.floodSlowDrain(verbose: verbose)]
        case "forced-proxy-precedence":
            return [try await ForcedRoutingScenarios.forcedProxyPrecedence(verbose: verbose)]
        case "direct-mode-silence":
            return [try await OrchestratorScenarios.directModeSilence(verbose: verbose)]
        case "vpn-flap-idle":
            return [try await VPNFlapScenarios.vpnFlapShortIdleTunnel(verbose: verbose)]
        case "vpn-flap-stream":
            return [try await VPNFlapScenarios.vpnFlapShortActiveStream(verbose: verbose)]
        case "vpn-flap-long-outage":
            return [try await VPNFlapScenarios.vpnFlapLongOutage(verbose: verbose)]
        case "vpn-user-disconnect":
            return [try await VPNFlapScenarios.vpnUserDisconnectFastPath(verbose: verbose)]
        case "vpn-rapid-flap-burst":
            return [try await VPNFlapScenarios.vpnRapidFlapBurst(verbose: verbose)]
        case "transparent-direct":
            return [try await TransparentProxyScenarios.transparentDirectRouting(verbose: verbose)]
        case "network-transition":
            return [try await NetworkTransitionScenarios.networkTransition(verbose: verbose)]
        case "upstream-flap":
            return [try await UpstreamFlapScenarios.upstreamFlap(verbose: verbose)]
        case "websocket-upgrade":
            return [try await UpgradeScenarios.websocketUpgrade(verbose: verbose)]
        case "connect-early-direct":
            return [try await UpgradeScenarios.connectEarlyData(direct: true, verbose: verbose)]
        case "connect-early-upstream":
            return [try await UpgradeScenarios.connectEarlyData(direct: false, verbose: verbose)]
        case "server-first-connect":
            return [try await ServerFirstScenarios.run(.httpConnect, verbose: verbose)]
        case "server-first-socks5":
            return [try await ServerFirstScenarios.run(.socks5, verbose: verbose)]
        case "audit-hop-response":
            return [try await AuditScenarios.proxiedResponseHopByHop(verbose: verbose)]
        case "audit-socks5-rsv":
            return [try await AuditScenarios.socks5NonZeroRSV(verbose: verbose)]
        case "audit-expect-trailers":
            return [try await AuditScenarios.expectContinueAndTrailers(verbose: verbose)]
        case "dns-doh-blocked":
            return [try await DNSResolverScenarios.dohBlockedStillAnswers(verbose: verbose)]
        case "dns-ephemeral-pair-rebind":
            return [try await DNSResolverScenarios.ephemeralPairRebind(verbose: verbose)]
        case "observable-target-redaction":
            return [try await ObservableTargetScenarios.redaction()]
        case "security-boundaries":
            return [try await SecurityScenarios.boundaries(verbose: verbose)]
        case "kerberos-service-ticket":
            return [try await KerberosScenarios.serviceTicketUnavailable(verbose: verbose)]
        case "fixture-pass", "fixture-fail", "fixture-missing":
            return [.reportingFixture(name: name)]
        case "fixture-throw":
            throw ScenarioExecutionError(message: "intentional fixture error")
        case "fixture-empty":
            return []
        case "fixture-setup-throw":
            setupCleanupCompleted = false
            ScenarioCleanup.register { setupCleanupCompleted = true }
            throw ScenarioExecutionError(message: "intentional partial setup failure")
        case "fixture-cleanup-witness":
            var result = ScenarioResult.reportingFixture(name: name)
            result.assertions = [.init("partial setup cleaned before next scenario", setupCleanupCompleted)]
            return [result]
        case "fixture-timeout":
            ScenarioCleanup.register { try? await Task.sleep(for: .seconds(10)) }
            return [.reportingFixture(name: "fixture-pass")]
        default:
            throw ScenarioExecutionError(message: "unknown scenario: \(name)")
        }
    }

    private static func printResults(_ results: [ScenarioResult], processUsage: ProcessResourceUsage.Delta? = nil) {
        print("")
        print("═══════════════ pm-sim results ═══════════════")
        for r in results {
            print("")
            print("▌ \(r.name)")
            print("  clients         : opened=\(r.clientsOpened)/\(r.clientCount) firstByte=\(r.clientsWithFirstByte) earlyClose=\(r.clientsClosedEarly)")
            print("  outcome         : \(r.passed ? "PASS" : "FAIL")")
            for assertion in r.assertions {
                print("  [\(assertion.passed ? "pass" : "FAIL")] \(assertion.name)")
            }
            let totalKB = Double(r.totalBytes) / 1024
            print("  bytes (total)   : \(String(format: "%.1f", totalKB)) KB")
            print("  bytes/stream    : min=\(r.minBytes) median=\(r.medianBytes) max=\(r.maxBytes)")
            print("  wall time       : \(String(format: "%.2f", r.durationSeconds)) s")
            print("  aggregate MB/s  : \(String(format: "%.2f", r.aggregateMBps))")
            if let e = r.earliestClose, let l = r.latestClose {
                print("  close span      : earliest=\(String(format: "%.2f", e))s latest=\(String(format: "%.2f", l))s")
            }
            if !r.notes.isEmpty {
                print("  notes           : \(r.notes.joined(separator: ", "))")
            }
        }
        if let processUsage {
            print("")
            print("▌ process resource baseline")
            print("  cpu time        : user=\(String(format: "%.3f", processUsage.userCPUSeconds))s system=\(String(format: "%.3f", processUsage.systemCPUSeconds))s")
            print("  cpu percent     : \(String(format: "%.1f", processUsage.cpuPercent))%")
            print("  max RSS         : \(String(format: "%.1f", Double(processUsage.maxResidentSetSizeBytes) / 1_048_576.0)) MB")
        }
        print("")
        print("══════════════════════════════════════════════")

        // NDJSON line per scenario for later aggregation/analysis.
        for r in results {
            let dict: [String: Any] = [
                "scenario": r.name,
                "passed": r.passed,
                "status": r.passed ? "passed" : "failed",
                "assertions": r.assertions.map { ["name": $0.name, "passed": $0.passed] as [String: Any] },
                "clients": r.clientCount,
                "opened": r.clientsOpened,
                "firstByte": r.clientsWithFirstByte,
                "earlyClose": r.clientsClosedEarly,
                "totalBytes": r.totalBytes,
                "durationSeconds": r.durationSeconds,
                "aggregateMBps": r.aggregateMBps,
                "minBytes": r.minBytes,
                "medianBytes": r.medianBytes,
                "maxBytes": r.maxBytes,
                "earliestCloseSeconds": r.earliestClose ?? NSNull(),
                "latestCloseSeconds": r.latestClose ?? NSNull(),
                "notes": r.notes
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print("SIM_NDJSON \(json)")
            }
        }
        if let processUsage {
            let dict: [String: Any] = [
                "kind": "process-resource-baseline",
                "wallSeconds": processUsage.wallSeconds,
                "userCPUSeconds": processUsage.userCPUSeconds,
                "systemCPUSeconds": processUsage.systemCPUSeconds,
                "cpuPercent": processUsage.cpuPercent,
                "maxResidentSetSizeBytes": processUsage.maxResidentSetSizeBytes
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print("PERF_NDJSON \(json)")
            }
        }
    }
}

private struct ProcessResourceUsage {
    struct Delta {
        let wallSeconds: Double
        let userCPUSeconds: Double
        let systemCPUSeconds: Double
        let cpuPercent: Double
        let maxResidentSetSizeBytes: Int64
    }

    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let maxResidentSetSizeBytes: Int64

    static func capture() -> ProcessResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return ProcessResourceUsage(
            userCPUSeconds: seconds(from: usage.ru_utime),
            systemCPUSeconds: seconds(from: usage.ru_stime),
            maxResidentSetSizeBytes: Int64(usage.ru_maxrss)
        )
    }

    func delta(from start: ProcessResourceUsage, wallSeconds: Double) -> Delta {
        let user = max(0, userCPUSeconds - start.userCPUSeconds)
        let system = max(0, systemCPUSeconds - start.systemCPUSeconds)
        let wall = max(wallSeconds, 0.001)
        return Delta(
            wallSeconds: wallSeconds,
            userCPUSeconds: user,
            systemCPUSeconds: system,
            cpuPercent: ((user + system) / wall) * 100,
            maxResidentSetSizeBytes: maxResidentSetSizeBytes
        )
    }

    private static func seconds(from value: timeval) -> Double {
        Double(value.tv_sec) + (Double(value.tv_usec) / 1_000_000.0)
    }
}
