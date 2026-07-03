// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

@main
enum PMSim {
    static func main() async {
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
              connection-flood        Saturate inbound connection cap, then verify recovery
              auth-storm              Saturate pending auth handshakes, verify bounded rejection
              long-silent             Single stream, 30s of silence then 256KB burst
              keepalive               Verify OS accepts TCP keepalive socket options
              health-check            5 health checks through the pool (orchestrator behavior)
              failover                Stop upstream1, verify switchToNextUpstream recovers via upstream2
              flood-slow-drain        AE5F6815 repro: fast origin flood + slow client, verify no truncation
              direct-mode-silence     Phase 2: prove expected-direct causes log .info, not .error
              vpn-flap-idle           idle CONNECT tunnel survives a brief VPN flap
              vpn-flap-stream         streaming HTTP response survives a brief VPN flap
              vpn-flap-long-outage    long outage transitions to .vpnDisconnected, recovers on reconnect
              vpn-user-disconnect     user-initiated disconnect is fast-path (no probe cycle)
              vpn-rapid-flap-burst    6 flaps in 1.5s emit one event pair (coalesce)
              network-transition      Wi-Fi → VPN → captive portal → resume; recovery <5s, DoH recycled
              upstream-flap           upstream up/down/up; assert breaker opens, half-opens, closes
              websocket-upgrade       101 upgrade relayed, frames flow both ways
              audit-hop-response      Audit: proxied HTTP response hop-by-hop header leak
              audit-socks5-rsv        Audit: SOCKS5 CONNECT non-zero RSV handling
              audit-expect-trailers   Audit: Expect: 100-continue answered, trailers passed through

            OPTIONS:
              --verbose               Stream per-handler debug logs to stderr
              --perf-baseline         Default to multi-100 and emit process CPU/RSS baseline NDJSON
              --help, -h              Show this help

            Pipeline under test:
              FakeClient → LocalProxyServer → FakeUpstreamProxy → FakeOrigin
            """)
            return
        }

        let scenario = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? (perfBaseline ? "multi-100" : "all")
        let usageStart = ProcessResourceUsage.capture()
        let wallStart = Date()

        do {
            let results = try await Task { @MainActor in
                try await runScenario(scenario, verbose: verbose)
            }.value
            let processUsage = ProcessResourceUsage.capture().delta(from: usageStart, wallSeconds: Date().timeIntervalSince(wallStart))
            printResults(results, processUsage: perfBaseline ? processUsage : nil)
        } catch {
            FileHandle.standardError.write(Data("pm-sim failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func runScenario(_ name: String, verbose: Bool) async throws -> [ScenarioResult] {
        switch name {
        case "all":
            return try await Scenarios.runAll(verbose: verbose)
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
        case "network-transition":
            return [try await NetworkTransitionScenarios.networkTransition(verbose: verbose)]
        case "upstream-flap":
            return [try await UpstreamFlapScenarios.upstreamFlap(verbose: verbose)]
        case "websocket-upgrade":
            return [try await UpgradeScenarios.websocketUpgrade(verbose: verbose)]
        case "audit-hop-response":
            return [try await AuditScenarios.proxiedResponseHopByHop(verbose: verbose)]
        case "audit-socks5-rsv":
            return [try await AuditScenarios.socks5NonZeroRSV(verbose: verbose)]
        case "audit-expect-trailers":
            return [try await AuditScenarios.expectContinueAndTrailers(verbose: verbose)]
        default:
            FileHandle.standardError.write(Data("unknown scenario: \(name)\n".utf8))
            exit(2)
        }
    }

    private static func printResults(_ results: [ScenarioResult], processUsage: ProcessResourceUsage.Delta? = nil) {
        print("")
        print("═══════════════ pm-sim results ═══════════════")
        for r in results {
            print("")
            print("▌ \(r.name)")
            print("  clients         : opened=\(r.clientsOpened)/\(r.clientCount) firstByte=\(r.clientsWithFirstByte) earlyClose=\(r.clientsClosedEarly)")
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
