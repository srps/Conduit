// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

/// The old dashboard minus the duplication: three module rows with switches,
/// a route card, a telemetry line, the richer upstream rows, and the
/// diagnostics actions as ordinary secondary buttons.
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modules
                routeCard
                if showsTelemetry {
                    telemetryCard
                }
                if !runtime.upstreamStatuses.isEmpty {
                    upstreamsCard
                }
                if !appState.activationPreflight.summary.isEmpty {
                    preflightBanner
                }
                if let lastError = appState.lastErrorMessage {
                    errorBanner(lastError)
                }
                actions
            }
            .padding(20)
        }
    }

    // MARK: - Modules

    private var modules: some View {
        card {
            ModuleRowView(
                title: "HTTP proxy",
                detail: proxyDetail,
                runState: proxyRunState,
                errorMessage: runtime.proxyError,
                badge: authBadge,
                toggle: { appState.toggleProxy() }
            )
            Divider()
            ModuleRowView(
                title: "DNS forwarder",
                detail: dnsDetail,
                runState: dnsRunState,
                errorMessage: runtime.dnsError,
                toggle: { appState.toggleDNS() }
            )
            Divider()
            ModuleRowView(
                title: "Tunnels",
                detail: tunnelsDetail,
                runState: tunnelsRunState,
                errorMessage: runtime.tunnelsError,
                toggle: { appState.toggleTunnels() }
            )
        }
    }

    // MARK: - Route

    private var routeCard: some View {
        card {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                keyValue("Route", routeText)
                keyValue("VPN", VPNStatusFormatter.label(for: runtime.vpnState),
                         valueColor: VPNStatusFormatter.color(for: runtime.vpnState))
                keyValue("Uptime", MenuBarPresentation.uptime(since: runtime.uptimeStartedAt) ?? "—")
                if proxyRunState == .running || proxyRunState == .warning,
                   !runtime.runtimeStatus.lastHealthSummary.isEmpty {
                    keyValue("Health", runtime.runtimeStatus.lastHealthSummary)
                }
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder
    private func keyValue(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
    }

    // MARK: - Telemetry

    /// Visible whenever the proxy is running (or warning). The line is a
    /// steady status surface, not an event log: zero values during normal
    /// operation are an honest "nothing's wrong" signal. Hidden only when
    /// the proxy is stopped — at which point the cumulative counters have
    /// been reset and there's nothing useful to display.
    private var showsTelemetry: Bool {
        proxyRunState == .running || proxyRunState == .warning
    }

    private var telemetryCard: some View {
        card {
            HStack(spacing: 14) {
                telemetryChip(value: MenuBarPresentation.compactCount(runtime.requestsHandled), label: "requests")
                telemetryChip(value: MenuBarPresentation.compactCount(runtime.failedRequests), label: "errors")
                telemetryChip(value: activeConnectionsLabel, label: "active")
                telemetryChip(value: "\(runtime.successfulRecoveries)", label: "recoveries")
                telemetryChip(value: "\(runtime.vpnFlapCount)", label: "VPN flaps", help: flapsTooltip)
                telemetryChip(value: "\(runtime.streamsPreservedAcrossFlaps)", label: "streams preserved")
                telemetryChip(value: "\(probesPerMinute)", label: "probes/min")
                Spacer(minLength: 0)
                Button("Reset") { runtime.resetActivityCounters() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .help("Zero the requests and errors counters from now on. Affects only this display — the daemon's cumulative metrics and events are untouched.")
                    .accessibilityLabel("Reset activity counters")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(runtime.requestsHandled) requests, \(runtime.failedRequests) errors, "
                    + "\(activeConnectionsLabel) active, \(runtime.successfulRecoveries) recoveries, "
                    + "\(runtime.vpnFlapCount) VPN flaps, \(runtime.streamsPreservedAcrossFlaps) streams preserved, "
                    + "\(probesPerMinute) probes per minute."
            )
        }
    }

    @ViewBuilder
    private func telemetryChip(value: String, label: String, help: String? = nil) -> some View {
        let chip = HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
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

    /// Pure mapping from runtime state to the first chip's text.
    /// Implementation lives in `VPNStatusFormatter` so it's unit-testable
    /// without standing up a SwiftUI view tree.
    private var activeConnectionsLabel: String {
        VPNStatusFormatter.activeConnectionsLabel(
            active: runtime.activeConnections.count,
            stalled: VPNStatusFormatter.stalledTunnelCount(
                vpnState: runtime.vpnState,
                activeTunnelCount: runtime.activeConnections.filter { $0.tunnel }.count
            )
        )
    }

    private var probesPerMinute: Int {
        VPNStatusFormatter.probesPerMinute(for: runtime.directModeCause)
    }

    /// Hover tooltip on the flaps chip — surfaces `lastVpnFlapAt` and
    /// `vpnFlapTotalDuration`, which would otherwise live only in NDJSON.
    private var flapsTooltip: String? {
        VPNStatusFormatter.flapsTooltip(
            count: runtime.vpnFlapCount,
            totalDuration: runtime.vpnFlapTotalDuration,
            lastFlapAt: runtime.lastVpnFlapAt
        )
    }

    // MARK: - Upstreams

    private var upstreamsCard: some View {
        card {
            HStack {
                Text("Upstreams")
                    .font(.subheadline.weight(.semibold))
                if runtime.directMode {
                    StatusPill(text: "DIRECT mode", color: Color(nsColor: .systemOrange))
                }
                Spacer()
                Button("Configure…") { appState.selectedSection = .upstreams }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
            }
            ForEach(runtime.upstreamStatuses) { status in
                UpstreamStatusRow(status: status)
            }
        }
    }

    // MARK: - Banners

    private var preflightBanner: some View {
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

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.callout)
            Text(message)
                .font(.callout)
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

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Restart Proxy") { appState.restartProxy() }
                .disabled(!MenuBarPresentation.canRestartProxy(for: runtime.runtimeStatus.state))
                .help("Stop and start the proxy runtime to clear accumulated connections and errors.")
            Button("Test DNS") { appState.testDNS() }
                .disabled(runtime.dnsRunState != .running)
            Button("Open Test URL") { appState.revealHealthTestURL() }
            Button("Copy Diagnostics") { copyDiagnostics() }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func copyDiagnostics() {
        let summary = MenuBarPresentation.statusSummary(
            state: runtime.runtimeStatus.state,
            activeUpstream: runtime.runtimeStatus.activeUpstream,
            healthSummary: runtime.runtimeStatus.lastHealthSummary,
            proxyEndpoint: MenuBarPresentation.endpoint(host: runtime.bindings.proxyHost, port: runtime.bindings.proxyPort),
            dnsEndpoint: MenuBarPresentation.endpoint(host: runtime.bindings.dnsHost, port: runtime.bindings.dnsPort),
            socksEndpoint: MenuBarPresentation.endpoint(host: runtime.bindings.socksHost, port: runtime.bindings.socksPort),
            requestsHandled: runtime.requestsHandled,
            failedRequests: runtime.failedRequests,
            activeConnectionCount: runtime.activeConnections.count,
            directModeCause: runtime.directModeCause,
            vpnLabel: VPNStatusFormatter.label(for: runtime.vpnState)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    // MARK: - Derived state

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

    private var proxyDetail: String {
        guard proxyRunState != .stopped else { return "Stopped" }
        let host = runtime.bindings.proxyHost ?? appState.config.localHost
        let port = runtime.bindings.proxyPort ?? appState.config.localPort
        var parts = ["\(host):\(port)"]
        if let socksHost = runtime.bindings.socksHost, let socksPort = runtime.bindings.socksPort {
            parts.append("SOCKS \(socksHost):\(socksPort)")
        }
        return parts.joined(separator: " · ")
    }

    private var routeText: String {
        guard proxyRunState == .running || proxyRunState == .warning else { return "—" }
        if runtime.directMode {
            // Derive the label from the orchestrator-supplied cause rather
            // than re-deriving from config: it says why we're direct (VPN
            // off, no upstreams, transient flap, or the bad case — upstreams
            // configured but unreachable).
            return runtime.directModeCause.healthSummary
        }
        return MenuBarPresentation.displayName(
            forActiveUpstream: runtime.runtimeStatus.activeUpstream,
            statuses: runtime.upstreamStatuses
        ).map { "Proxied via \($0)" } ?? "Proxied"
    }

    private var dnsDetail: String {
        guard runtime.dnsRunState != .stopped else { return "Stopped" }
        let host = runtime.bindings.dnsHost ?? appState.config.localHost
        let port = runtime.bindings.dnsPort ?? appState.config.dnsForwarderPort
        if appState.platformConfig.manageSystemDNS {
            return "\(host):53 via :\(port) · system DNS active"
        }
        return "\(host):\(port) · \(MenuBarPresentation.compactCount(runtime.dnsQueryCount)) queries"
    }

    private var tunnelsDetail: String {
        guard runtime.tunnelsRunState != .stopped else { return "Stopped" }
        let count = runtime.bindings.tunnels.count
        var parts = ["\(count) definition\(count == 1 ? "" : "s")", "\(runtime.tunnelSessionCount) session\(runtime.tunnelSessionCount == 1 ? "" : "s")"]
        switch runtime.tunnelDNSOverrideStatus {
        case .active(let hostnames):
            parts.append("DNS override \(hostnames.count) host\(hostnames.count == 1 ? "" : "s")")
        case .partial(let succeeded, let failed):
            parts.append("DNS override \(succeeded.count) active, \(failed.count) failed")
        case .unavailable:
            parts.append("DNS override unavailable")
        case .notNeeded:
            break
        }
        return parts.joined(separator: " · ")
    }

    private var authBadge: (text: String, color: Color, help: String) {
        // Prefer runtime state over configured state so the chip reflects
        // what actually ran on the wire (Kerberos vs. silent NTLM fallback),
        // not just `config.authMode`. Falls back to the configured mode
        // before the first handshake completes (nothing-to-mirror case).
        switch runtime.lastAuthOutcome {
        case .kerberos:
            return ("Kerberos", Color(nsColor: .systemPurple), "Last handshake used Kerberos (SPNEGO).")
        case .ntlmFallback:
            let reason = runtime.lastAuthFallbackReason.map { " (\($0))" } ?? ""
            return (
                "Kerberos → NTLM",
                Color(nsColor: .systemOrange),
                "Kerberos unavailable\(reason); using NTLMv2 fallback. Keychain credentials required."
            )
        case .ntlmDirect:
            return ("NTLMv2", Color(nsColor: .systemOrange), "Configured NTLMv2 — Kerberos not attempted.")
        case .none:
            switch appState.config.authMode {
            case .systemNegotiated:
                return ("Kerberos", Color(nsColor: .systemPurple), "Configured Kerberos; no handshake observed yet.")
            case .ntlmv2:
                return ("NTLMv2", Color(nsColor: .systemOrange), "Configured NTLMv2; no handshake observed yet.")
            }
        }
    }

    // MARK: - Chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One subsystem: name and binding on the left, a status pill and a switch on
/// the right. The switch shows the state and is the control.
struct ModuleRowView: View {
    let title: String
    let detail: String
    let runState: ModuleRunState
    var errorMessage: String? = nil
    var badge: (text: String, color: Color, help: String)? = nil
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if let badge {
                            StatusPill(text: badge.text, color: badge.color)
                                .help(badge.help)
                        }
                    }
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(runState == .running || runState == .warning ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                StatusPill(text: runState.title, color: statusColor)
                Toggle(title, isOn: Binding(
                    get: { MenuBarPresentation.moduleSwitchIsOn(for: runState) },
                    set: { _ in toggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!MenuBarPresentation.moduleSwitchIsEnabled(for: runState))
                .accessibilityLabel(title)
                .accessibilityValue(runState.title)
            }
            if let errorMessage, runState == .failed || runState == .warning {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(runState == .failed ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch runState {
        case .running: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .starting: Color(nsColor: .systemBlue)
        case .failed: Color(nsColor: .systemRed)
        case .stopped: Color(nsColor: .systemGray)
        }
    }
}

/// The richer upstream row from the old dashboard: name, endpoint, latency,
/// consecutive failures, retry window, circuit state. Shared by Overview and
/// the live strip at the top of Upstreams & Routing.
struct UpstreamStatusRow: View {
    let status: UpstreamRuntimeStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(circuitColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name.isEmpty ? status.endpoint : status.name)
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
                    .monospacedDigit()
            }

            if status.consecutiveFailures > 0 {
                Text("\(status.consecutiveFailures) fail\(status.consecutiveFailures == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }

            if let retryText {
                Text(retryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            StatusPill(text: circuitTitle, color: circuitColor)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var circuitTitle: String {
        switch status.circuitState {
        case .closed: return "Closed"
        case .open: return "Open"
        case .halfOpen: return "Half-open"
        }
    }

    private var circuitColor: Color {
        switch status.circuitState {
        case .closed: return Color(nsColor: .systemGreen)
        case .open: return Color(nsColor: .systemRed)
        case .halfOpen: return Color(nsColor: .systemOrange)
        }
    }

    private var retryText: String? {
        guard status.circuitState == .open, let openUntil = status.openUntil else { return nil }
        let remaining = max(0, Int(openUntil.timeIntervalSinceNow.rounded(.up)))
        return remaining > 0 ? "retry in \(remaining)s" : nil
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
