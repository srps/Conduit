// SPDX-License-Identifier: Apache-2.0
import ProxyKernel
import SwiftUI

/// Protocol tunnels: presets, definitions, and session limits, with live
/// session counts and the DNS override status above them.
struct TunnelsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    private var problems: ConfigFieldProblems { ConfigFieldProblems(config: appState.config) }

    var body: some View {
        ConfigureSection {
            VStack(alignment: .leading, spacing: 8) {
                LiveStatusStrip(
                    runState: runtime.tunnelsRunState,
                    title: "Tunnels",
                    chips: liveChips
                )
                if appState.helperStatus != .installed {
                    HelperHintBanner()
                }
            }
        } content: {
            let problems = problems

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(TunnelPreset.allCases.filter { $0 != .custom }) { preset in
                        Button {
                            appState.config.tunnelDefinitions.append(preset.makeDefinition())
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: preset.icon)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.displayName)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(":\(preset.defaultRemotePort)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(preset.helpText)
                    }
                }
            } header: {
                Text("Quick Add from Preset")
            } footer: {
                SettingsNote("Protocol tunnels route non-HTTP traffic (MongoDB, PostgreSQL, Redis, etc.) through your corporate proxy using HTTP CONNECT. Point your client at the local port instead of the remote server.")
            }

            Section {
                if appState.config.tunnelDefinitions.isEmpty {
                    Text("No tunnels configured. Add one from the presets above or use the button below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(appState.config.tunnelDefinitions.enumerated()), id: \.element.id) { index, def in
                        if let binding = tunnelBinding(id: def.id) {
                            tunnelEditor(binding, index: index, problems: problems)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Add Custom Tunnel") {
                        appState.config.tunnelDefinitions.append(
                            TunnelDefinition(localPort: 0, remoteHost: "", remotePort: 0, proxied: true, label: "")
                        )
                    }
                    if !appState.config.tunnelDefinitions.isEmpty {
                        Button("Remove Last") {
                            appState.config.tunnelDefinitions.removeLast()
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("Tunnel Definitions")
            }

            Section {
                TextField("Global Max Sessions", value: $appState.config.maxTunnelSessions, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "tunnels.maxSessions"))
                    .accessibilityLabel("Maximum total tunnel sessions")
                TextField("Per-Tunnel Max", value: $appState.config.maxSessionsPerTunnel, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "tunnels.maxSessionsPerTunnel"))
                    .accessibilityLabel("Maximum sessions per tunnel")
            } header: {
                Text("Session Limits")
            } footer: {
                SettingsNote("Tunnel sessions are long-lived dedicated TCP connections. These limits are separate from the HTTP proxy connection pool.")
            }

            ConflictList(conflicts: problems.conflicts(mentioning: ["tunnel"]))
        }
    }

    // MARK: - Live chips

    private var liveChips: [(label: String, value: String)] {
        guard runtime.tunnelsRunState != .stopped else {
            let count = appState.config.tunnelDefinitions.filter(\.enabled).count
            return [("", "Stopped"), ("enabled definition\(count == 1 ? "" : "s")", "\(count)")]
        }
        var chips: [(label: String, value: String)] = [
            ("active", "\(runtime.tunnelActiveCount)"),
            ("session\(runtime.tunnelSessionCount == 1 ? "" : "s")", "\(runtime.tunnelSessionCount)"),
        ]
        switch runtime.tunnelDNSOverrideStatus {
        case .active(let hostnames):
            chips.append(("DNS override host\(hostnames.count == 1 ? "" : "s")", "\(hostnames.count)"))
        case .partial(let succeeded, let failed):
            chips.append(("DNS override", "\(succeeded.count) active, \(failed.count) failed"))
        case .unavailable:
            chips.append(("DNS override", "unavailable"))
        case .notNeeded:
            break
        }
        return chips
    }

    // MARK: - Definitions

    private func tunnelEditor(_ binding: Binding<TunnelDefinition>, index: Int, problems: ConfigFieldProblems) -> some View {
        let label = binding.wrappedValue.effectiveLabel
        let localProblem = problems.message(for: "tunnels.definitions[\(index)](\(label)).localPort")
        let remoteProblem = problems.message(for: "tunnels.definitions[\(index)](\(label)).remotePort")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: binding.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Enable tunnel \(label)")

                TextField("Label", text: binding.label, prompt: Text("Label"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(minWidth: 100)
                    .accessibilityLabel("Tunnel label")

                Spacer()

                Toggle("Proxied", isOn: binding.proxied)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                Button(role: .destructive) {
                    appState.config.tunnelDefinitions.removeAll { $0.id == binding.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete tunnel \(label)")
            }

            HStack(spacing: 8) {
                Text("Local")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                TextField("Local port", value: binding.localPort, format: .number.grouping(.never), prompt: Text("Port"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .modifier(InvalidFieldHighlight(isInvalid: localProblem != nil))
                    .accessibilityLabel("Local port")

                Text("→")
                    .foregroundStyle(.tertiary)

                TextField(
                    "Remote host",
                    text: binding.remoteHost,
                    prompt: Text(binding.wrappedValue.preset?.hostPlaceholder ?? "Remote host")
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Remote host")

                Text(":")
                    .foregroundStyle(.tertiary)

                TextField("Remote port", value: binding.remotePort, format: .number.grouping(.never), prompt: Text("Port"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 70)
                    .modifier(InvalidFieldHighlight(isInvalid: remoteProblem != nil))
                    .accessibilityLabel("Remote port")
            }
            .font(.system(size: 12, design: .monospaced))

            if let localProblem {
                FieldProblem(message: localProblem)
            }
            if let remoteProblem {
                FieldProblem(message: remoteProblem)
            }

            if binding.wrappedValue.proxied && !binding.wrappedValue.remoteHost.isEmpty {
                connectionGuidance(for: binding.wrappedValue)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func connectionGuidance(for def: TunnelDefinition) -> some View {
        let dnsStatus = runtime.tunnelDNSOverrideStatus
        let isActive: Bool = {
            switch dnsStatus {
            case .active(let hosts): return hosts.contains(def.remoteHost.lowercased())
            case .partial(let succeeded, _): return succeeded.contains(def.remoteHost.lowercased())
            default: return false
            }
        }()
        let portsMatch = def.localPort == def.remotePort

        Divider().opacity(0.2)

        if runtime.tunnelsRunState == .running && isActive && portsMatch {
            Label("DNS override active — use your normal connection string.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        } else if runtime.tunnelsRunState == .running && isActive && !portsMatch {
            VStack(alignment: .leading, spacing: 6) {
                Label("DNS override active — connect to \(def.remoteHost):\(def.localPort) (tunnel listen port).", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                CopyableValueRow(label: "Connection host:port", value: "\(def.remoteHost):\(def.localPort)")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if runtime.tunnelsRunState == .running {
                    Label("DNS override unavailable — use one of the options below.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if def.preset == .mongoDBAtlas || def.preset == .cosmosDBMongo {
                    CopyableValueRow(
                        label: "SOCKS5 (recommended for MongoDB)",
                        value: "mongosh \"mongodb://\(def.remoteHost):\(def.remotePort)/\" --tls --proxyHost 127.0.0.1 --proxyPort \(appState.config.socksPort)"
                    )
                }

                CopyableValueRow(label: "/etc/hosts (requires sudo)", value: "127.0.0.1  \(def.remoteHost)")
            }
        }
    }

    private func tunnelBinding(id: UUID) -> Binding<TunnelDefinition>? {
        guard let index = appState.config.tunnelDefinitions.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $appState.config.tunnelDefinitions[index]
    }
}
