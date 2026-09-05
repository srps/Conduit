// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

/// The status item image. Template-rendered, so the shape carries the state;
/// see `MenuBarPresentation.menuBarSymbol`.
struct MenuBarLabel: View {
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    var body: some View {
        Image(systemName: MenuBarPresentation.menuBarSymbol(
            state: runtime.runtimeStatus.state,
            directModeCause: runtime.directModeCause
        ))
        .accessibilityLabel("Conduit: \(stateLine)")
    }

    private var stateLine: String {
        MenuBarPresentation.stateLine(
            state: runtime.runtimeStatus.state,
            directModeCause: runtime.directModeCause,
            activeUpstream: runtime.runtimeStatus.activeUpstream,
            proxyError: runtime.proxyError
        )
    }
}

/// The popover. One job: status and switches in one click, no scrolling.
/// Everything that needs reading or configuring lives in the app window.
struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @Environment(\.openWindow) private var openWindow

    private static let width: CGFloat = 320
    private static let recentEventLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            moduleRow(
                title: "DNS forwarder",
                detail: dnsEndpoint,
                state: runtime.dnsRunState,
                toggle: { appState.toggleDNS() }
            )
            moduleRow(
                title: "Tunnels",
                detail: tunnelsDetail,
                state: runtime.tunnelsRunState,
                toggle: { appState.toggleTunnels() }
            )
            if !runtime.upstreamStatuses.isEmpty {
                Divider()
                upstreams
            }
            Divider()
            Text(activityLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityLabel("Activity: \(activityLine)")
            Divider()
            RecentEventsSection(logStore: appState.logStore, limit: Self.recentEventLimit)
            Divider()
            commands
        }
        .frame(width: Self.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stateLine)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !stateDetail.isEmpty {
                    Text(stateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("Proxy", isOn: proxySwitch)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!MenuBarPresentation.proxySwitchIsEnabled(for: runtime.runtimeStatus.state))
                .accessibilityLabel("Proxy")
                .accessibilityValue(stateLine)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var proxySwitch: Binding<Bool> {
        Binding(
            get: { MenuBarPresentation.proxySwitchIsOn(for: runtime.runtimeStatus.state) },
            set: { _ in appState.toggleProxy() }
        )
    }

    // MARK: - Module rows

    private func moduleRow(
        title: String,
        detail: String,
        state: ModuleRunState,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 0)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Toggle(title, isOn: Binding(
                get: { MenuBarPresentation.moduleSwitchIsOn(for: state) },
                set: { _ in toggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!MenuBarPresentation.moduleSwitchIsEnabled(for: state))
            .accessibilityLabel(title)
            .accessibilityValue(state.title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Upstreams

    private var upstreams: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Upstreams")
            if let active = activeUpstreamStatus {
                upstreamButton {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: active.circuitState))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(active.name.isEmpty ? active.endpoint : active.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(upstreamDetail(for: active))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Active upstream \(active.name), \(active.circuitState.rawValue), \(upstreamDetail(for: active))")
            }
            if let summary = upstreamSummary {
                upstreamButton {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 8)
                            .accessibilityHidden(true)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityLabel(summary)
            }
        }
        .padding(.vertical, 4)
    }

    private func upstreamButton<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button {
            openApp(on: .upstreams)
        } label: {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Upstreams & Routing")
    }

    /// The upstream carrying traffic, matched by endpoint. Nil in direct mode
    /// and whenever the runtime has not picked one.
    private var activeUpstreamStatus: UpstreamRuntimeStatus? {
        guard !runtime.directMode, let endpoint = runtime.runtimeStatus.activeUpstream else { return nil }
        return runtime.upstreamStatuses.first { $0.endpoint == endpoint }
    }

    private var upstreamSummary: String? {
        let others = runtime.upstreamStatuses.filter { $0.id != activeUpstreamStatus?.id }
        return MenuBarPresentation.upstreamSummaryLine(
            closed: others.filter { $0.circuitState == .closed }.count,
            halfOpen: others.filter { $0.circuitState == .halfOpen }.count,
            open: others.filter { $0.circuitState == .open }.count,
            activeShown: activeUpstreamStatus != nil
        )
    }

    private func upstreamDetail(for status: UpstreamRuntimeStatus) -> String {
        switch status.circuitState {
        case .open:
            if let openUntil = status.openUntil {
                let remaining = max(0, Int(openUntil.timeIntervalSinceNow.rounded(.up)))
                return remaining > 0 ? "open · retry \(remaining) s" : "open"
            }
            return "open"
        case .halfOpen:
            return "probing"
        case .closed:
            return status.ewmaLatencyMS.map { "\(Int($0.rounded())) ms" } ?? "-"
        }
    }

    // MARK: - Commands

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandRow("Open Conduit…", shortcut: "⌘0") { openApp(on: .overview) }
            commandRow("Restart Proxy") { appState.restartProxy() }
                .disabled(!MenuBarPresentation.canRestartProxy(for: runtime.runtimeStatus.state))
            commandRow("Copy Diagnostics") { copyDiagnostics() }
            commandRow("Quit Conduit", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 4)
    }

    private func commandRow(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Derived state

    private var stateLine: String {
        MenuBarPresentation.stateLine(
            state: runtime.runtimeStatus.state,
            directModeCause: runtime.directModeCause,
            activeUpstream: MenuBarPresentation.displayName(
                forActiveUpstream: runtime.runtimeStatus.activeUpstream,
                statuses: runtime.upstreamStatuses
            ),
            proxyError: runtime.proxyError
        )
    }

    private var stateDetail: String {
        MenuBarPresentation.stateDetail(
            lastError: appState.lastErrorMessage,
            healthSummary: runtime.runtimeStatus.state == .stopped ? "" : runtime.runtimeStatus.lastHealthSummary,
            vpnLabel: VPNStatusFormatter.label(for: runtime.vpnState),
            uptime: MenuBarPresentation.uptime(since: runtime.uptimeStartedAt)
        )
    }

    private var activityLine: String {
        MenuBarPresentation.activityLine(
            requests: runtime.requestsHandled,
            errors: runtime.failedRequests,
            active: runtime.activeConnections.count
        )
    }

    private var dnsEndpoint: String {
        guard runtime.dnsRunState != .stopped else { return "off" }
        return MenuBarPresentation.endpoint(host: runtime.bindings.dnsHost, port: runtime.bindings.dnsPort)
    }

    private var tunnelsDetail: String {
        guard runtime.tunnelsRunState != .stopped else { return "off" }
        let count = runtime.tunnelActiveCount
        return "\(count) active"
    }

    private func color(for state: UpstreamCircuitState) -> Color {
        switch state {
        case .closed: return .green
        case .halfOpen: return .orange
        case .open: return .red
        }
    }

    // MARK: - Actions

    private func openApp(on section: AppSection) {
        appState.selectedSection = section
        AppWindowPresentation.prepareForAppWindow()
        openWindow(id: ConduitApp.mainWindowID)
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
}

/// Observes `logStore` directly: `AppLogStore` is a nested ObservableObject,
/// so its `entries` changes don't republish `appState` — without direct
/// observation this section only refreshed when the 1 Hz runtime adapter
/// happened to publish, and went stale entirely while the proxy was stopped.
private struct RecentEventsSection: View {
    @ObservedObject var logStore: AppLogStore
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)

            let entries = Array(logStore.entries.suffix(limit)).reversed()
            if entries.isEmpty {
                Text("No recent events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            } else {
                ForEach(Array(entries), id: \.id) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(color(for: entry.level))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(entry.message)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .accessibilityLabel("\(entry.level.label): \(entry.message)")
                }
            }
        }
        .padding(.bottom, 4)
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
