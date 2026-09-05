// SPDX-License-Identifier: Apache-2.0
import ProxyKernel
import SwiftUI

/// Auth mode and NTLM credentials, with what actually happened on the wire
/// shown above them.
struct AuthenticationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    var body: some View {
        ConfigureSection {
            LiveStatusStrip(
                runState: nil,
                title: "Last handshake",
                chips: outcomeChips
            )
        } content: {
            Section {
                Picker("Mode", selection: $appState.config.authMode) {
                    ForEach(AuthenticationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityLabel("Authentication mode")

                if appState.config.authMode == .systemNegotiated {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kerberos / SPNEGO")
                                .font(.subheadline.weight(.medium))
                            Text("Uses your system Kerberos ticket (from kinit or macOS SSO). No password storage needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }

            Section {
                credentialFields
            } header: {
                Text(appState.config.authMode == .systemNegotiated ? "NTLMv2 Fallback Credentials" : "NTLMv2 Credentials")
            } footer: {
                if appState.config.authMode == .systemNegotiated {
                    SettingsNote("Used only when Kerberos fails. The Keychain is read at that moment, never eagerly.")
                } else {
                    SettingsNote("The password is stored as an NTLMv2 hash in the Keychain. Set it with Run Setup.")
                }
            }

            Section {
                HStack(spacing: 8) {
                    Button("Run Setup…") {
                        appState.isShowingOnboarding = true
                    }
                    .help("Set or replace the stored password and pick up VPN DNS servers.")

                    if appState.config.authMode == .ntlmv2 || appState.credentialManager.hasSavedCredentials(for: appState.config) {
                        Button("Clear Saved Credentials") {
                            appState.clearCredentials()
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("Credentials")
            } footer: {
                SettingsNote(appState.credentialManager.hasSavedCredentials(for: appState.config)
                    ? "Credentials for this profile are saved in the Keychain."
                    : "No credentials are saved for this profile.")
            }
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        TextField("Username", text: $appState.config.username)
            .accessibilityLabel("Username")
        TextField("Domain", text: $appState.config.domain)
            .accessibilityLabel("Domain")
        TextField("Workstation", text: $appState.config.workstation)
            .accessibilityLabel("Workstation")
    }

    private var outcomeChips: [(label: String, value: String)] {
        switch runtime.lastAuthOutcome {
        case .kerberos:
            return [("Kerberos (SPNEGO)", ""), ("at", timeLabel)]
        case .ntlmFallback:
            let reason = runtime.lastAuthFallbackReason.map { " (\($0))" } ?? ""
            return [("Kerberos → NTLMv2 fallback\(reason)", ""), ("at", timeLabel)]
        case .ntlmDirect:
            return [("NTLMv2", ""), ("at", timeLabel)]
        case .none:
            return [("no handshake observed yet", "")]
        }
    }

    private var timeLabel: String {
        runtime.lastAuthOutcomeAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "-"
    }
}
