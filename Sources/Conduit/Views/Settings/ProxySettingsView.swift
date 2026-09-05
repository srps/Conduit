// SPDX-License-Identifier: Apache-2.0
import ProxyKernel
import SwiftUI

/// Listen address, SOCKS5, gateway mode, and how macOS is pointed at the
/// proxy. Upstream routing lives in `UpstreamsSettingsView`.
struct ProxySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    private var problems: ConfigFieldProblems { ConfigFieldProblems(config: appState.config) }

    var body: some View {
        ConfigureSection {
            LiveStatusStrip(
                runState: proxyRunState,
                title: "HTTP proxy",
                chips: [
                    ("listening", MenuBarPresentation.endpoint(host: runtime.bindings.proxyHost, port: runtime.bindings.proxyPort)),
                    ("SOCKS5", MenuBarPresentation.endpoint(host: runtime.bindings.socksHost, port: runtime.bindings.socksPort)),
                    ("PAC", runtime.bindings.localPACURL ?? "-"),
                ]
            )
        } content: {
            let problems = problems

            Section {
                TextField("Listen Host", text: $appState.config.localHost)
                    .configProblem(problems.message(for: "proxy.host"))
                    .accessibilityLabel("Listen host")
                TextField("Listen Port", value: $appState.config.localPort, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "proxy.port"))
                    .accessibilityLabel("Listen port")
            } header: {
                Text("Local Proxy")
            } footer: {
                SettingsNote("Applications point at this address for HTTP and HTTPS. Use 0.0.0.0 only together with gateway mode.")
            }

            Section {
                Toggle("Enable SOCKS5 server", isOn: $appState.config.socksEnabled)
                TextField("SOCKS5 Port", value: $appState.config.socksPort, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .disabled(!appState.config.socksEnabled)
                    .configProblem(problems.message(for: "proxy.socksPort"))
                    .accessibilityLabel("SOCKS5 port")
            } header: {
                Text("SOCKS5 Proxy")
            } footer: {
                if appState.config.socksEnabled {
                    SettingsNote("The SOCKS5 server starts with the HTTP proxy on 127.0.0.1:\(appState.config.socksPort). Supports TCP CONNECT tunnelling through the corporate proxy. Used by MongoDB drivers, some CLI tools, and proxychains.")
                }
            }

            Section {
                Toggle("Enable gateway mode", isOn: $appState.config.gatewayMode)
                    .help("Accept proxy connections from other machines (Docker containers, VMs, LAN devices). Requires the listen host above to be 0.0.0.0 — validation enforces that the wildcard bind and gateway mode are enabled together.")
                if appState.config.gatewayMode {
                    LabeledContent("Allowed Clients") {
                        HostListEditor(
                            entries: $appState.config.allowedClients,
                            placeholder: "192.168.64.5",
                            accessibilityName: "allowed client"
                        )
                        .help("Exact client IP addresses allowed to connect. Connections from any other address are rejected before proxying.")
                    }
                }
            } header: {
                Text("Gateway Mode (LAN / Docker / VMs)")
            } footer: {
                if appState.config.gatewayMode {
                    SettingsNote("Only the listed IP addresses may use the proxy. Cloud-metadata and loopback targets are blocked for gateway clients. Inbound client authentication is not yet implemented — until then, treat this allow-list as the only gate.")
                }
            }

            Section {
                Toggle(isOn: $appState.platformConfig.manageSystemProxy) {
                    HStack(spacing: 4) {
                        Text("Manage macOS proxy settings")
                        Text(HelperStatusPresentation.privilegeHint(for: appState.helperStatus, otherwise: "may require admin"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Use adaptive local PAC for macOS", isOn: adaptiveLocalPACBinding)
                if appState.platformConfig.systemProxyMode == .manual || !appState.config.localPACEnabled {
                    SettingsNote("Manual system proxy mode keeps macOS pinned to the local HTTP/HTTPS proxy. Use it only for clients that cannot honour PAC.", tint: .orange)
                }
                TextField("Local PAC Port", value: $appState.config.localPACPort, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .disabled(!appState.config.localPACEnabled)
                    .configProblem(problems.message(for: "routing.localPACPort"))
                    .accessibilityLabel("Local PAC port")
                if let localPACURL = runtime.bindings.localPACURL, appState.config.localPACEnabled {
                    LabeledContent("Currently serving") {
                        Text(localPACURL)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("macOS System Proxy")
            } footer: {
                SettingsNote("Recommended for browsers and system apps. macOS points at Conduit's local PAC; the PAC returns the local proxy while upstream routing is available and DIRECT when direct mode should bypass Conduit.")
            }

            ConflictList(conflicts: problems.conflicts(mentioning: ["proxy.host", "SOCKS port", "Local PAC port", "gatewayMode"]))
        }
    }

    private var proxyRunState: ModuleRunState {
        switch runtime.runtimeStatus.state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .degraded, .recovering: .warning
        case .failed: .failed
        }
    }

    private var adaptiveLocalPACBinding: Binding<Bool> {
        Binding(
            get: {
                appState.platformConfig.systemProxyMode == .pac && appState.config.localPACEnabled
            },
            set: { enabled in
                appState.platformConfig.systemProxyMode = enabled ? .pac : .manual
                appState.config.localPACEnabled = enabled
            }
        )
    }
}
