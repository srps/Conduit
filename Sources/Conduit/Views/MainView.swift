// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @State private var isShowingAdvancedDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conduit")
                        .font(.title.weight(.semibold))
                    Text("Corporate proxy and DNS management")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: overallStatusIcon)
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(overallStatusColor)
                    .padding(10)
                    .background(overallStatusColor.opacity(0.15), in: .circle)
                    .accessibilityLabel("Overall status")
            }

            HStack(spacing: 12) {
                ModuleCardView(
                    title: "HTTP Proxy",
                    icon: "network",
                    runState: proxyRunState,
                    address: proxyAddress,
                    primaryMetric: "\(MenuBarPresentation.compactCount(runtime.requestsHandled)) requests",
                    secondaryMetric: proxyDetail,
                    errorMessage: runtime.proxyError,
                    badge: authBadge,
                    action: { appState.toggleProxy() }
                )

                ModuleCardView(
                    title: "DNS Forwarder",
                    icon: "globe",
                    runState: dnsRunState,
                    address: dnsAddress,
                    primaryMetric: "\(MenuBarPresentation.compactCount(runtime.dnsQueryCount)) queries",
                    secondaryMetric: dnsSecondaryMetric,
                    errorMessage: runtime.dnsError,
                    action: { appState.toggleDNS() }
                )

                ModuleCardView(
                    title: "Protocol Tunnels",
                    icon: "point.3.connected.trianglepath.dotted",
                    runState: tunnelsRunState,
                    address: tunnelsAddress,
                    primaryMetric: "\(runtime.tunnelActiveCount) tunnels, \(runtime.tunnelSessionCount) sessions",
                    secondaryMetric: tunnelsDetail,
                    errorMessage: runtime.tunnelsError,
                    action: { appState.toggleTunnels() }
                )
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                statusRow("VPN", VPNStatusFormatter.label(for: runtime.vpnState),
                          valueColor: VPNStatusFormatter.color(for: runtime.vpnState))
                statusRow("Uptime", uptimeText)
                if proxyRunState == .running || proxyRunState == .warning {
                    statusRow("Health", runtime.runtimeStatus.lastHealthSummary)
                }
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))

            // Phase 7: telemetry strip directly under the status grid.
            // Visible whenever the proxy is running so it acts as a steady
            // status surface — zero values are an honest "nothing's wrong"
            // signal, not noise. Suppressed only when the proxy is stopped
            // (cumulative counters reset on stop, so the strip would have
            // nothing to say).
            if showsFlapTelemetryStrip {
                flapTelemetryStrip
            }

            if runtime.dnsRunState == .running {
                HStack(spacing: 8) {
                    Button("Test DNS") { appState.testDNS() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                metricCard(title: "Requests", value: MenuBarPresentation.compactCount(runtime.requestsHandled))
                metricCard(title: "Errors", value: MenuBarPresentation.compactCount(runtime.failedRequests))
                metricCard(title: "Recoveries", value: "\(runtime.successfulRecoveries)")
            }

            if hasAdvancedDiagnostics {
                DisclosureGroup(isExpanded: $isShowingAdvancedDiagnostics) {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsDNSDiagnostics {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("DNS Resolution")
                                    .font(.subheadline.weight(.semibold))
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 110), spacing: 10, alignment: .leading)],
                                    alignment: .leading,
                                    spacing: 10
                                ) {
                                    advancedMetricCard(title: "Queries", value: "\(runtime.dnsQueryCount)")
                                    advancedMetricCard(title: "Cache Hits", value: "\(runtime.dnsCacheHitCount)")
                                    advancedMetricCard(title: "Hit Rate", value: dnsCacheHitRateText)
                                    advancedMetricCard(title: "DoH Fallbacks", value: "\(runtime.dnsDoHFallbackCount)")
                                }
                            }
                        }

                        if !runtime.upstreamStatuses.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Upstream Routing")
                                        .font(.subheadline.weight(.semibold))
                                    if runtime.directMode {
                                        statusBadge(
                                            text: "DIRECT mode",
                                            color: Color(nsColor: .systemOrange)
                                        )
                                    }
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(runtime.upstreamStatuses) { status in
                                        upstreamStatusRow(status)
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 8)
                } label: {
                    Label("Advanced Diagnostics", systemImage: "waveform.path.ecg.rectangle")
                        .font(.subheadline.weight(.semibold))
                }
            }

            ConnectionsView(compact: true)

            if !appState.activationPreflight.summary.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.blue)
                        .font(.callout)
                    Text(appState.activationPreflight.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let lastError = appState.lastErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        appState.lastErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(10)
                .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Settings") { appState.isShowingSettings = true }
                Button("Logs") { appState.isShowingLogs = true }
                Button("Test URL") { appState.revealHealthTestURL() }
                Button("Restart Proxy") { appState.restartProxy() }
                    .disabled(!MenuBarPresentation.canRestartProxy(for: runtime.runtimeStatus.state))
                Spacer()
                Button("Setup Wizard") { appState.isShowingOnboarding = true }
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .background(WindowBehaviorView(enabled: appState.appPreferences.floatingWindowEnabled))
    }

    // MARK: - Computed properties

    private var proxyRunState: ModuleRunState {
        switch runtime.runtimeStatus.state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .degraded, .recovering: .warning
        case .failed: .failed
        }
    }

    private var dnsRunState: ModuleRunState {
        if runtime.dnsRunState == .running && runtime.dnsError != nil {
            return .warning
        }
        return runtime.dnsRunState
    }

    private var tunnelsRunState: ModuleRunState {
        if runtime.tunnelsRunState == .running && runtime.tunnelsError != nil {
            return .warning
        }
        return runtime.tunnelsRunState
    }

    private var proxyAddress: String {
        guard proxyRunState != .stopped else { return "Stopped" }
        let host = runtime.bindings.proxyHost ?? appState.config.localHost
        let port = runtime.bindings.proxyPort ?? appState.config.localPort
        return "\(host):\(port)"
    }

    private var proxyDetail: String {
        if proxyRunState != .running && proxyRunState != .warning { return "—" }
        if runtime.directMode {
            // Phase 2: derive label from the orchestrator-supplied cause rather
            // than re-deriving from config. The cause tells us why we're in
            // direct mode (VPN off, no upstreams, transient flap, or the bad
            // case — upstreams configured but unreachable).
            return runtime.directModeCause.healthSummary
        }
        return runtime.runtimeStatus.activeUpstream.map { "via \($0)" } ?? "—"
    }

    // MARK: - Phase 7: Active-connection counter split + flap telemetry strip

    /// Pure mapping from runtime state to the strip's first-chip text.
    /// Implementation lives in `VPNStatusFormatter` so it's unit-testable
    /// without standing up a SwiftUI view tree.
    private var activeConnectionsLabel: String {
        VPNStatusFormatter.activeConnectionsLabel(
            active: runtime.activeConnections.count,
            stalled: vpnFlapStalledTunnelCount
        )
    }

    /// Tunnels are "stalled" only when the VPN itself is in a non-connected
    /// state — that's the only moment "stalled" carries meaning. Otherwise
    /// every active tunnel is just an active tunnel.
    private var vpnFlapStalledTunnelCount: Int {
        VPNStatusFormatter.stalledTunnelCount(
            vpnState: runtime.vpnState,
            activeTunnelCount: runtime.activeConnections.filter { $0.tunnel }.count
        )
    }

    private var dnsAddress: String {
        guard runtime.dnsRunState == .running else { return "Stopped" }
        let host = runtime.bindings.dnsHost ?? appState.config.localHost
        let port = runtime.bindings.dnsPort ?? appState.config.dnsForwarderPort
        if appState.platformConfig.manageSystemDNS {
            return "\(host):53 (via :\(port))"
        }
        return "\(host):\(port)"
    }

    private var dnsSecondaryMetric: String {
        if runtime.dnsRunState == .running && appState.platformConfig.manageSystemDNS {
            return "System DNS active"
        }
        return "\(runtime.dnsDoHFallbackCount) DoH fallbacks"
    }

    private var tunnelsAddress: String {
        guard runtime.tunnelsRunState == .running else { return "Stopped" }
        let bindings = runtime.bindings.tunnels
        let count = bindings.count
        let hosts = Array(Set(bindings.map(\.localHost))).sorted()
        let hostLabel = hosts.isEmpty ? appState.config.effectiveTunnelListenHost : hosts.joined(separator: ", ")
        return "\(count) definition\(count == 1 ? "" : "s") on \(hostLabel)"
    }

    private var tunnelsDetail: String {
        guard runtime.tunnelsRunState == .running else { return "—" }
        switch runtime.tunnelDNSOverrideStatus {
        case .active(let hostnames):
            return "DNS override: \(hostnames.count) host\(hostnames.count == 1 ? "" : "s")"
        case .partial(let succeeded, let failed):
            return "DNS override: \(succeeded.count) active, \(failed.count) failed"
        case .unavailable:
            return "DNS override unavailable"
        case .notNeeded:
            let proxied = appState.config.tunnelDefinitions.filter { $0.enabled && $0.proxied }.count
            if proxied > 0 { return "\(proxied) via corporate proxy" }
            return "Direct tunnels only"
        }
    }

    private var allRunStates: [ModuleRunState] {
        [proxyRunState, dnsRunState, tunnelsRunState]
    }

    private var overallStatusIcon: String {
        if allRunStates.contains(.running) || allRunStates.contains(.warning) { return "network.badge.shield.half.filled" }
        if allRunStates.contains(.failed) { return "xmark.shield" }
        if allRunStates.contains(.starting) { return "bolt.horizontal.circle" }
        return "network.slash"
    }

    private var overallStatusColor: Color {
        if allRunStates.contains(.failed) { return Color(nsColor: .systemRed) }
        if allRunStates.contains(.warning) { return Color(nsColor: .systemOrange) }
        if allRunStates.contains(.running) { return Color(nsColor: .systemGreen) }
        if allRunStates.contains(.starting) { return Color(nsColor: .systemBlue) }
        return Color(nsColor: .systemGray)
    }

    private var uptimeText: String {
        guard let startedAt = runtime.uptimeStartedAt else {
            return "—"
        }
        return DateComponentsFormatter.proxyUptime.string(from: startedAt, to: .now) ?? "—"
    }

    private var hasAdvancedDiagnostics: Bool {
        showsDNSDiagnostics || !runtime.upstreamStatuses.isEmpty
    }

    private var showsDNSDiagnostics: Bool {
        runtime.dnsRunState == .running || runtime.dnsQueryCount > 0
    }

    private var dnsCacheHitRateText: String {
        guard runtime.dnsQueryCount > 0 else { return "—" }
        let hitRate = (Double(runtime.dnsCacheHitCount) / Double(runtime.dnsQueryCount)) * 100
        return "\(Int(hitRate.rounded()))%"
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(valueColor)
        }
    }

    // MARK: - Phase 7: Telemetry strip

    /// Visible whenever the proxy is running (or warning). The strip is a
    /// steady status surface, not an event log: zero values during normal
    /// operation are an honest "nothing's wrong" signal. Hidden only when
    /// the proxy is stopped — at which point the cumulative counters have
    /// been reset and there's nothing useful to display.
    private var showsFlapTelemetryStrip: Bool {
        proxyRunState == .running || proxyRunState == .warning
    }

    /// `probesPerMinute` mapped via the testable formatter.
    private var probesPerMinuteLabel: Int {
        VPNStatusFormatter.probesPerMinute(for: runtime.directModeCause)
    }

    /// Hover tooltip on the "Flaps" chip — surfaces `lastVpnFlapAt` and
    /// `vpnFlapTotalDuration`, which would otherwise live only in NDJSON.
    /// Returns nil in zero-state (no chip tooltip needed).
    private var flapsTooltip: String? {
        VPNStatusFormatter.flapsTooltip(
            count: runtime.vpnFlapCount,
            totalDuration: runtime.vpnFlapTotalDuration,
            lastFlapAt: runtime.lastVpnFlapAt
        )
    }

    @ViewBuilder
    private var flapTelemetryStrip: some View {
        HStack(spacing: 14) {
            telemetryChip(label: "Active", value: activeConnectionsLabel)
            telemetrySeparator
            telemetryChip(label: "Flaps", value: "\(runtime.vpnFlapCount)",
                          help: flapsTooltip)
            telemetrySeparator
            telemetryChip(label: "Preserved", value: "\(runtime.streamsPreservedAcrossFlaps)")
            telemetrySeparator
            telemetryChip(label: "Probes/min", value: "\(probesPerMinuteLabel)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "VPN flap telemetry: \(activeConnectionsLabel), " +
            "\(runtime.vpnFlapCount) flaps, " +
            "\(runtime.streamsPreservedAcrossFlaps) streams preserved, " +
            "\(probesPerMinuteLabel) probes per minute."
        )
    }

    @ViewBuilder
    private func telemetryChip(label: String, value: String, help: String? = nil) -> some View {
        let chip = HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        if let help {
            chip.help(help)
        } else {
            chip
        }
    }

    private var telemetrySeparator: some View {
        Text("·")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
    }

    private var authBadge: (text: String, color: Color, help: String?) {
        // Prefer runtime state over configured state so the chip reflects
        // what actually ran on the wire (Kerberos vs. silent NTLM fallback),
        // not just `config.authMode`. Falls back to the configured mode
        // before the first handshake completes (nothing-to-mirror case).
        switch appState.runtime.lastAuthOutcome {
        case .kerberos:
            return ("Kerberos", Color(nsColor: .systemPurple), "Last handshake used Kerberos (SPNEGO).")
        case .ntlmFallback:
            let reason = appState.runtime.lastAuthFallbackReason.map { " (\($0))" } ?? ""
            return (
                "Kerberos → NTLM",
                Color(nsColor: .systemOrange),
                "Kerberos unavailable\(reason); using NTLMv2 fallback. Keychain credentials required."
            )
        case .ntlmDirect:
            return ("NTLMv2", Color(nsColor: .systemOrange), "Configured NTLMv2 — Kerberos not attempted.")
        case .none:
            // No handshake yet — show configured intent.
            switch appState.config.authMode {
            case .systemNegotiated:
                return ("Kerberos", Color(nsColor: .systemPurple), "Configured Kerberos; no handshake observed yet.")
            case .ntlmv2:
                return ("NTLMv2", Color(nsColor: .systemOrange), "Configured NTLMv2; no handshake observed yet.")
            }
        }
    }

    @ViewBuilder
    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func advancedMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func upstreamStatusRow(_ status: UpstreamRuntimeStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(status.name)
                    .font(.subheadline.weight(.semibold))
                Text(status.endpoint)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let latency = status.ewmaLatencyMS {
                Text("\(Int(latency.rounded())) ms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if status.consecutiveFailures > 0 {
                Text("\(status.consecutiveFailures) fail\(status.consecutiveFailures == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }

            if let retryText = retryWindowText(for: status) {
                Text(retryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            statusBadge(text: circuitTitle(for: status), color: circuitColor(for: status))
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func circuitTitle(for status: UpstreamRuntimeStatus) -> String {
        switch status.circuitState {
        case .closed:
            return "Closed"
        case .open:
            return "Open"
        case .halfOpen:
            return "Half-open"
        }
    }

    private func circuitColor(for status: UpstreamRuntimeStatus) -> Color {
        switch status.circuitState {
        case .closed:
            return Color(nsColor: .systemGreen)
        case .open:
            return Color(nsColor: .systemRed)
        case .halfOpen:
            return Color(nsColor: .systemOrange)
        }
    }

    private func retryWindowText(for status: UpstreamRuntimeStatus) -> String? {
        guard status.circuitState == .open,
              let openUntil = status.openUntil else {
            return nil
        }
        let remaining = max(0, Int(openUntil.timeIntervalSinceNow.rounded(.up)))
        return remaining > 0 ? "retry in \(remaining)s" : nil
    }
}

private extension DateComponentsFormatter {
    static let proxyUptime: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
