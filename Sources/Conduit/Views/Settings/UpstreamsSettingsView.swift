// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI
import UniformTypeIdentifiers

/// Where traffic goes: the upstream PAC, the ordered upstream list with its
/// live health per row, and the bypass rules the proxy handler and PAC
/// emitter use for routing.
struct UpstreamsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @State private var draggedUpstreamID: UUID?

    private var problems: ConfigFieldProblems { ConfigFieldProblems(config: appState.config) }

    var body: some View {
        ConfigureSection {
            liveStrip
        } content: {
            let problems = problems

            Section {
                TextField("Upstream PAC URL", text: $appState.config.pacURL, prompt: Text("https://…"))
                    .configProblem(problems.message(for: "routing.pacURL"))
                    .accessibilityLabel("Upstream PAC URL")
                Toggle("Use upstream PAC for Conduit routing", isOn: $appState.config.pacRoutingEnabled)
                    .disabled(pacURLIsEmpty)
                HStack {
                    Button("Preview PAC") { appState.refreshPACResolutionPreview() }
                        .disabled(pacURLIsEmpty)
                        .help("Evaluate the upstream PAC for the browser test URL and log the resulting proxy chain under Events.")
                    Spacer()
                }
            } header: {
                Text("Upstream PAC Routing")
            } footer: {
                if pacURLIsEmpty {
                    SettingsNote("Add an upstream PAC URL to enable PAC-based routing decisions. Without one, enabled upstream proxies are tried by priority.")
                } else {
                    SettingsNote("This PAC is fetched by Conduit and evaluated per request. It decides DIRECT vs proxy chains such as PROXY A; PROXY B; DIRECT. It is separate from the adaptive local PAC served to macOS.")
                }
            }

            Section {
                upstreamList
            } header: {
                Text("Upstream Proxies & Failover")
            } footer: {
                SettingsNote("Enabled upstreams are health-ranked and tried in this order when upstream PAC routing is disabled or when the PAC returns a matching configured proxy. PAC-only proxies can still be tried for a request, but adding them here gives Conduit health status, credentials, and normal failover visibility. Drag the handle to reorder.")
            }

            Section {
                LabeledContent("NO_PROXY entries") {
                    HostListEditor(
                        entries: $appState.config.noProxyHosts,
                        placeholder: "localhost",
                        accessibilityName: "NO_PROXY",
                        problems: indexedProblems(prefix: "routing.noProxyHosts", problems: problems)
                    )
                }
                LabeledContent("Force-proxy hosts") {
                    HostListEditor(
                        entries: $appState.config.forceProxyHosts,
                        placeholder: "internal.example.com",
                        accessibilityName: "Force proxy host",
                        problems: indexedProblems(prefix: "routing.forceProxyHosts", problems: problems)
                    )
                }
            } header: {
                Text("Bypass Rules")
            } footer: {
                SettingsNote("NO_PROXY hosts always go direct; force-proxy hosts always go through the upstream. Both feed the local PAC and the shell NO_PROXY variable.")
            }
        }
    }

    // MARK: - Live strip

    @ViewBuilder
    private var liveStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveStatusStrip(
                runState: nil,
                title: routeText,
                chips: healthChips
            )
            if !runtime.upstreamStatuses.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(runtime.upstreamStatuses) { status in
                        UpstreamStatusRow(status: status)
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// The health summary, unless it is what the title already says (direct
    /// mode reports its cause as the summary).
    private var healthChips: [(label: String, value: String)] {
        let summary = runtime.runtimeStatus.lastHealthSummary
        guard !summary.isEmpty, summary != routeText, !runtime.directMode else { return [] }
        return [("health", summary)]
    }

    private var routeText: String {
        switch runtime.runtimeStatus.state {
        case .stopped: return "Proxy stopped"
        case .starting: return "Starting…"
        case .failed: return "Proxy failed"
        case .running, .degraded, .recovering:
            if runtime.directMode {
                return runtime.directModeCause.healthSummary
            }
            return MenuBarPresentation.displayName(
                forActiveUpstream: runtime.runtimeStatus.activeUpstream,
                statuses: runtime.upstreamStatuses
            ).map { "Proxied via \($0)" } ?? "Proxied"
        }
    }

    // MARK: - Upstream list

    private var upstreamList: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("").frame(width: 24)
                Text("").frame(width: 12)
                Text("Order").frame(width: 40).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("On").frame(width: 44).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Name").frame(minWidth: 80, alignment: .leading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Host").frame(minWidth: 160, alignment: .leading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Port").frame(width: 64).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Latency").frame(width: 60, alignment: .trailing).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .accessibilityHidden(true)

            ForEach(Array(orderedUpstreamIDs.enumerated()), id: \.element) { offset, id in
                if let upstream = upstreamBinding(id: id) {
                    upstreamRow(upstream, order: offset + 1)
                        .onDrop(
                            of: [UTType.text],
                            delegate: UpstreamDropDelegate(
                                targetID: id,
                                draggedID: $draggedUpstreamID,
                                move: moveUpstream
                            )
                        )
                }
            }

            if !appState.config.upstreams.isEmpty {
                Text("Drop here to move to the end")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onDrop(
                        of: [UTType.text],
                        delegate: UpstreamDropDelegate(
                            targetID: nil,
                            draggedID: $draggedUpstreamID,
                            move: moveUpstream
                        )
                    )
            }

            HStack(spacing: 8) {
                Button("Add Proxy") {
                    appState.config.upstreams.append(
                        UpstreamProxy(name: "", host: "", port: 8080, priority: appState.config.upstreams.count)
                    )
                    normalizeUpstreamPriorities()
                }
                if !appState.config.upstreams.isEmpty {
                    Button("Remove Last") { removeLastUpstream() }
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func upstreamRow(_ upstream: Binding<UpstreamProxy>, order: Int) -> some View {
        let live = liveStatus(for: upstream.wrappedValue)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
                .contentShape(Rectangle())
                .onDrag {
                    draggedUpstreamID = upstream.wrappedValue.id
                    return NSItemProvider(object: upstream.wrappedValue.id.uuidString as NSString)
                }
                .accessibilityLabel("Drag upstream")
            Circle()
                .fill(live.map { circuitColor(for: $0.circuitState) } ?? Color(nsColor: .systemGray).opacity(0.4))
                .frame(width: 8, height: 8)
                .frame(width: 12)
                .help(live.map { "\($0.circuitState.rawValue) circuit" } ?? "No runtime data")
                .accessibilityLabel(live.map { "Circuit \($0.circuitState.rawValue)" } ?? "No runtime data")
            Text("\(order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40)
            Toggle("", isOn: upstream.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 44)
                .accessibilityLabel(accessibilityUpstreamLabel(for: upstream.wrappedValue))
            // Inside a grouped `Form` a text field's title renders as a
            // leading label, which misaligns a table row; the column header
            // above already names the field, so titles stay for VoiceOver
            // only and prompts carry the placeholder.
            TextField("Name", text: upstream.name, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(minWidth: 80)
                .accessibilityLabel("Upstream name")
            TextField("Host", text: upstream.host, prompt: Text("proxy.example.com"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(minWidth: 160)
                .accessibilityLabel("Upstream host")
            TextField("Port", value: upstream.port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 64)
                .accessibilityLabel("Upstream port")
            Text(live?.ewmaLatencyMS.map { "\(Int($0.rounded())) ms" } ?? "-")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(upstream.wrappedValue.id == draggedUpstreamID ? 0.06 : 0.025),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The runtime row for a configured upstream. `ConnectionPool` keys the
    /// status by the upstream's own id, so two rows with the same name or
    /// endpoint still get their own traffic light.
    private func liveStatus(for upstream: UpstreamProxy) -> UpstreamRuntimeStatus? {
        runtime.upstreamStatuses.first { $0.id == upstream.id }
    }

    private func circuitColor(for state: UpstreamCircuitState) -> Color {
        switch state {
        case .closed: return Color(nsColor: .systemGreen)
        case .open: return Color(nsColor: .systemRed)
        case .halfOpen: return Color(nsColor: .systemOrange)
        }
    }

    // MARK: - Bindings

    private var pacURLIsEmpty: Bool {
        appState.config.pacURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var orderedUpstreamIDs: [UUID] {
        UpstreamOrdering.orderedIDs(for: appState.config.upstreams)
    }

    private func moveUpstream(_ draggedID: UUID, before targetID: UUID?) {
        appState.config.upstreams = UpstreamOrdering.moving(appState.config.upstreams, id: draggedID, before: targetID)
    }

    private func removeLastUpstream() {
        guard let id = orderedUpstreamIDs.last,
              let index = appState.config.upstreams.firstIndex(where: { $0.id == id })
        else { return }
        appState.config.upstreams.remove(at: index)
        normalizeUpstreamPriorities()
    }

    private func normalizeUpstreamPriorities() {
        appState.config.upstreams = UpstreamOrdering.normalized(appState.config.upstreams)
    }

    private func upstreamBinding(id: UUID) -> Binding<UpstreamProxy>? {
        guard let index = appState.config.upstreams.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $appState.config.upstreams[index]
    }

    private func accessibilityUpstreamLabel(for upstream: UpstreamProxy) -> String {
        let name = upstream.name.isEmpty ? upstream.host : upstream.name
        return upstream.enabled ? "Disable upstream \(name)" : "Enable upstream \(name)"
    }

    /// `routing.noProxyHosts[3]` → `[3: message]`.
    private func indexedProblems(prefix: String, problems: ConfigFieldProblems) -> [Int: String] {
        var result: [Int: String] = [:]
        let count = prefix.hasSuffix("noProxyHosts") ? appState.config.noProxyHosts.count : appState.config.forceProxyHosts.count
        for index in 0..<count {
            if let message = problems.message(for: "\(prefix)[\(index)]") {
                result[index] = message
            }
        }
        return result
    }
}
