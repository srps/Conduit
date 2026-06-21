// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                quickActions
                upstreamsSection
                runtimeMetrics
                recentEvents
                footerActions
            }
            .padding(16)
        }
        .scrollIndicators(.visible)
        .frame(width: 380, height: 560)
        .task {
            if appState.isShowingOnboarding {
                appState.isShowingOnboarding = false
                openUtilityWindow("setup")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconCircle(systemName: "network", color: statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conduit")
                        .font(.headline.weight(.semibold))
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(text: runtime.runtimeStatus.state.title, color: statusColor)
            }

            HStack(spacing: 8) {
                endpointPill(label: "HTTP", value: proxyEndpoint)
                endpointPill(label: "DNS", value: dnsEndpoint)
                endpointPill(label: "SOCKS", value: socksEndpoint)
            }

            HStack(spacing: 8) {
                indicator(text: runtime.directMode ? "DIRECT" : "Proxy route", color: runtime.directMode ? .orange : .green)
                indicator(text: appState.config.gatewayMode ? "Gateway" : "Local only", color: appState.config.gatewayMode ? .cyan : .secondary)
                indicator(text: appState.config.routing.pacRoutingEnabled ? "PAC" : "No PAC", color: appState.config.routing.pacRoutingEnabled ? .blue : .secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                Button(proxyButtonTitle) { appState.toggleProxy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(runtime.runtimeStatus.state == .starting)

                Button("Restart") { appState.restartProxy() }
                    .buttonStyle(.bordered)
                    .disabled(!MenuBarPresentation.canRestartProxy(for: runtime.runtimeStatus.state))
                    .help("Stop and start the proxy runtime to clear accumulated connections and errors.")
            }

            HStack(spacing: 8) {
                Button(runtime.dnsRunState == .running ? "Stop DNS" : "Start DNS") { appState.toggleDNS() }
                    .buttonStyle(.bordered)
                    .disabled(runtime.dnsRunState == .starting)

                Button(runtime.tunnelsRunState == .running ? "Stop Tunnels" : "Start Tunnels") { appState.toggleTunnels() }
                    .buttonStyle(.bordered)
                    .disabled(runtime.tunnelsRunState == .starting)
            }

            HStack(spacing: 8) {
                Button("Test DNS") { appState.testDNS() }
                    .buttonStyle(.bordered)
                Button("Open Test URL") { appState.revealHealthTestURL() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var upstreamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Upstreams")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(runtime.runtimeStatus.activeUpstream ?? "none")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if runtime.upstreamStatuses.isEmpty {
                Text("No upstream runtime data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(runtime.upstreamStatuses.prefix(4)) { status in
                        upstreamRow(status)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var runtimeMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { runtime.resetActivityCounters() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .help("Zero the Requests and Errors counters from now on. Affects only this display — the daemon's cumulative metrics and events are untouched.")
                    .accessibilityLabel("Reset activity counters")
            }

            HStack(spacing: 8) {
                metricCard(title: "Requests", value: MenuBarPresentation.compactCount(runtime.requestsHandled))
                metricCard(title: "Errors", value: MenuBarPresentation.compactCount(runtime.failedRequests))
                metricCard(title: "Active", value: MenuBarPresentation.compactCount(runtime.activeConnections.count))
            }

            ConnectionsView(compact: true)
                .environmentObject(runtime)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentEvents: some View {
        // Child view observes `logStore` directly: `AppLogStore` is a nested
        // ObservableObject, so its `entries` changes don't republish
        // `appState` — without direct observation this section only
        // refreshed when the 1 Hz runtime adapter happened to publish, and
        // went stale entirely while the proxy was stopped.
        RecentEventsSection(
            logStore: appState.logStore,
            onOpenLogs: { openUtilityWindow("logs") }
        )
    }

    private var footerActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Detach") { openUtilityWindow("dashboard") }
                Button("Settings") { openUtilityWindow("settings") }
                Button("Connections") { openUtilityWindow("connections") }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button("Copy Summary") { copyStatusSummary() }
                Button("Setup") { openUtilityWindow("setup") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Rows and cards

    private func upstreamRow(_ status: UpstreamRuntimeStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: status.circuitState))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(status.endpoint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(status.circuitState.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color(for: status.circuitState))
                Text(status.ewmaLatencyMS.map { "\(Int($0)) ms" } ?? "-")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    private func indicator(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func endpointPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func iconCircle(systemName: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.15)).frame(width: 34, height: 34)
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
    }

    // MARK: - Derived state

    private var proxyButtonTitle: String {
        MenuBarPresentation.proxyButtonTitle(for: runtime.runtimeStatus.state)
    }

    private var statusSubtitle: String {
        MenuBarPresentation.statusSubtitle(
            state: runtime.runtimeStatus.state,
            proxyError: runtime.proxyError,
            lastError: appState.lastErrorMessage,
            directMode: runtime.directMode,
            directModeCause: runtime.directModeCause,
            healthSummary: runtime.runtimeStatus.lastHealthSummary
        )
    }

    private var statusColor: Color {
        switch runtime.runtimeStatus.state {
        case .running: return .green
        case .starting, .recovering: return .orange
        case .degraded: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var proxyEndpoint: String {
        endpoint(host: runtime.bindings.proxyHost, port: runtime.bindings.proxyPort)
    }

    private var dnsEndpoint: String {
        endpoint(host: runtime.bindings.dnsHost, port: runtime.bindings.dnsPort)
    }

    private var socksEndpoint: String {
        endpoint(host: runtime.bindings.socksHost, port: runtime.bindings.socksPort)
    }

    private func endpoint(host: String?, port: Int?) -> String {
        MenuBarPresentation.endpoint(host: host, port: port)
    }

    private func color(for state: UpstreamCircuitState) -> Color {
        switch state {
        case .closed: return .green
        case .halfOpen: return .orange
        case .open: return .red
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func openUtilityWindow(_ id: String) {
        AppWindowPresentation.prepareForDetachedWindow()
        openWindow(id: id)
    }

    private func copyStatusSummary() {
        let summary = MenuBarPresentation.statusSummary(
            state: runtime.runtimeStatus.state,
            activeUpstream: runtime.runtimeStatus.activeUpstream,
            healthSummary: runtime.runtimeStatus.lastHealthSummary,
            proxyEndpoint: proxyEndpoint,
            dnsEndpoint: dnsEndpoint,
            socksEndpoint: socksEndpoint,
            requestsHandled: runtime.requestsHandled,
            failedRequests: runtime.failedRequests,
            activeConnectionCount: runtime.activeConnections.count,
            directModeCause: runtime.directModeCause,
            vpnLabel: VPNStatusFormatter.label(for: runtime.vpnState)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }
}

private struct RecentEventsSection: View {
    @ObservedObject var logStore: AppLogStore
    let onOpenLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Events")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Logs", action: onOpenLogs)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
            }

            let entries = Array(logStore.entries.suffix(5)).reversed()
            if entries.isEmpty {
                Text("No recent events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries), id: \.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(color(for: entry.level))
                                .frame(width: 7, height: 7)
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
