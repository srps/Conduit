// SPDX-License-Identifier: Apache-2.0
import ProxyKernel
import SwiftUI

/// Timers, limits, the circuit breaker, direct-connect caching, VPN flap
/// resilience, and strict mode. Everything here has a sane default.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var problems: ConfigFieldProblems { ConfigFieldProblems(config: appState.config) }

    var body: some View {
        ConfigureSection {
            let problems = problems

            Section {
                numberField("Health Check Interval (s)", value: $appState.config.healthCheckIntervalSeconds,
                            field: "health.checkInterval", problems: problems,
                            accessibility: "Health check interval seconds")
                numberField("Stalled Timeout (s)", value: $appState.config.stalledConnectionTimeoutSeconds,
                            field: "proxy.stalledConnectionTimeout", problems: problems,
                            accessibility: "Stalled timeout seconds")
                numberField("Max Connections", value: $appState.config.maxConnections,
                            field: "proxy.maxConnections", problems: problems,
                            accessibility: "Maximum connections")
                numberField("Connection Warn Threshold", value: $appState.config.inboundConnectionWarnThreshold,
                            field: nil, problems: problems,
                            accessibility: "Inbound connection warn threshold")
                numberField("Connection Max Limit", value: $appState.config.inboundConnectionMaxLimit,
                            field: "proxy.inboundConnectionMaxLimit", problems: problems,
                            accessibility: "Inbound connection max limit")
                TextField("Max Buffered Body (MB)", value: megabytesBinding($appState.config.maxBufferedBodyBytes),
                          format: .number.precision(.fractionLength(0)))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "proxy.maxBufferedBodyBytes"))
                    .accessibilityLabel("Max buffered request body megabytes")
                    .help("Request bodies larger than this are not fully buffered. If proxy auth replay is needed, oversized requests will fail.")
                TextField("Max Spooled Body (MB)", value: megabytesBinding($appState.config.maxSpooledBodyBytes),
                          format: .number.precision(.fractionLength(0)))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "proxy.maxSpooledBodyBytes"))
                    .accessibilityLabel("Max spooled request body megabytes")
                    .help("Bodies above the buffered limit spill to a bounded temp file up to this size; larger requests are rejected with 413.")
                numberField("Pending Auth (global)", value: $appState.config.pendingAuthHandshakeGlobalLimit,
                            field: "auth.pendingHandshakeGlobalLimit", problems: problems,
                            accessibility: "Pending auth handshakes global limit")
                    .help("Maximum upstream 407 handshakes in flight at once — the auth-storm bound. New handshakes beyond it are rejected with a structured event.")
                numberField("Pending Auth (per source)", value: $appState.config.pendingAuthHandshakesPerSource,
                            field: "auth.pendingHandshakesPerSource", problems: problems,
                            accessibility: "Pending auth handshakes per source limit")
                    .help("Per-client-IP slice of the pending-handshake bound, so one misbehaving client cannot starve the rest.")
            } header: {
                Text("Timers & Limits")
            }

            Section {
                numberField("Upstream Response (s)", value: $appState.config.upstreamResponseTimeoutSeconds,
                            field: "health.upstreamResponseTimeout", problems: problems,
                            accessibility: "Upstream response timeout seconds")
                    .help("How long to wait for an upstream proxy's response before counting the attempt as failed.")
                numberField("Failure Window (s)", value: $appState.config.circuitBreakerWindowSeconds,
                            field: nil, problems: problems,
                            accessibility: "Circuit breaker window seconds")
                    .help("Sliding window over which upstream failures are counted toward tripping the circuit breaker.")
                numberField("Failure Threshold", value: $appState.config.circuitFailureThreshold,
                            field: "health.circuitFailureThreshold", problems: problems,
                            accessibility: "Circuit breaker failure threshold")
                    .help("Failures within the window before the upstream's circuit opens and traffic fails over.")
            } header: {
                Text("Failover & Circuit Breaker")
            }

            Section {
                numberField("Connect Timeout (ms)", value: $appState.config.connectionCheckTimeoutMS,
                            field: "health.connectionCheckTimeout", problems: problems,
                            accessibility: "Direct connect timeout milliseconds")
                numberField("Cache TTL (min)", value: $appState.config.directConnectTTLMinutes,
                            field: "health.directConnectTTL", problems: problems,
                            accessibility: "Direct connect cache TTL minutes")
            } header: {
                Text("Direct Connect")
            }

            // Two sliders for the two-stage debounce that absorbs transient
            // utun jitter (docs/design-vpn-flap-resilience.md, Phase 7):
            //
            //   1. min-visible: how long an inactive Link must persist before
            //      we even tell the rest of the app a flap is happening. Sub-
            //      window blips never reach the orchestrator.
            //   2. grace: once the flap IS visible, how long we hold the
            //      reasserting state before declaring a real disconnect.
            //
            // Active streams ride the whole window via TCP keepalive — these
            // values control control-plane reaction speed, never user-data
            // teardown timing.
            Section {
                LabeledContent("Min Visible Flap") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $appState.config.vpnFlapMinVisibleSeconds, in: 0...5, step: 0.25)
                            .frame(maxWidth: 280)
                            .accessibilityLabel("Minimum visible flap seconds")
                            .help("How long an utun interface must remain inactive before the orchestrator treats the dropout as a user-visible flap. Sub-window blips stay silent: no event, no UI flicker, no routing change.")
                        // The only slider that can hit zero; that disables the
                        // debounce entirely (every utun blip is a "real" flap).
                        Text(Self.formattedSeconds(appState.config.vpnFlapMinVisibleSeconds, zeroLabel: "off"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Flap Grace Window") {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $appState.config.vpnFlapGraceSeconds, in: 1...30, step: 1)
                            .frame(maxWidth: 280)
                            .accessibilityLabel("VPN flap grace window seconds")
                            .help("How long after a VPN drop the orchestrator waits before declaring a real disconnect. Within this window the state is \"Reconnecting…\" and active streams are preserved by kernel keepalive — no new routing decisions are made.")
                        Text(Self.formattedSeconds(appState.config.vpnFlapGraceSeconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("VPN Flap Resilience")
            } footer: {
                SettingsNote("Brief VPN dropouts shorter than the min-visible window are silent. Longer ones show as \"Reconnecting…\" until the grace window expires; active streams are preserved for the full window.")
            }

            Section {
                Toggle("Strict mode", isOn: $appState.config.strictMode)
                    .help("Never route proxied traffic DIRECT as a fallback when upstreams fail (PAC DIRECT fallback and protocol-upgrade direct relay are refused unless the network state itself is unconditionally direct). Will also gate inbound gateway auth once that feature is implemented.")
            } header: {
                Text("Security")
            }

            ConflictList(conflicts: problems.conflicts(mentioning: ["health.", "circuit"]))
        }
    }

    // MARK: - Fields

    private func numberField(
        _ title: String,
        value: Binding<Int>,
        field: String?,
        problems: ConfigFieldProblems,
        accessibility: String
    ) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .frame(maxWidth: 220)
            .configProblem(field.flatMap { problems.message(for: $0) })
            .accessibilityLabel(accessibility)
    }

    private func numberField(
        _ title: String,
        value: Binding<Double>,
        field: String?,
        problems: ConfigFieldProblems,
        accessibility: String
    ) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .frame(maxWidth: 220)
            .configProblem(field.flatMap { problems.message(for: $0) })
            .accessibilityLabel(accessibility)
    }

    private func megabytesBinding(_ bytes: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(bytes.wrappedValue) / 1_048_576.0 },
            set: { bytes.wrappedValue = max(1_048_576, Int($0 * 1_048_576.0)) }
        )
    }

    /// `zeroLabel` only applies to sliders whose range includes 0. Callers whose
    /// range starts above zero (the grace slider) omit it.
    static func formattedSeconds(_ value: TimeInterval, zeroLabel: String? = nil) -> String {
        if value <= 0, let zeroLabel { return zeroLabel }
        if value < 1 {
            return String(format: "%.2fs", value)
        }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))s"
        }
        return String(format: "%.2fs", value)
    }
}
