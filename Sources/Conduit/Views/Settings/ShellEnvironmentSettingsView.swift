// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The shell variables Conduit manages. The bypass lists those variables
/// carry are routing configuration and live under Upstreams & Routing.
struct ShellEnvironmentSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ConfigureSection {
            Section {
                Toggle("Manage shell proxy environment variables", isOn: $appState.platformConfig.manageEnvironmentVariables)
                LabeledContent("Managed files") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("~/.zshrc")
                        Text("~/.zprofile")
                        Text("~/.config/environment.d/proxy-manager.conf")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                HStack {
                    Button("Bypass Rules…") { appState.selectedSection = .upstreams }
                        .buttonStyle(.link)
                    Spacer()
                }
            } header: {
                Text("Environment Variables")
            } footer: {
                SettingsNote("For CLI tools, shell environments are static per process. Keeping HTTP_PROXY and HTTPS_PROXY pointed at Conduit lets it act as the adaptive router: proxy on VPN, DIRECT off VPN, with NO_PROXY keeping localhost callbacks out of the proxy path. The NO_PROXY and force-proxy lists are edited under Upstreams & Routing.")
            }
        }
    }
}
