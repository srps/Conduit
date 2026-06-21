// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PlatformMac
import ProxyKernel

struct SetupWizardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var dnsServers = ""
    @State private var detectedDNS: [DetectedDNSConfig] = []
    @State private var useDetectedDNS = true

    private var passwordsMatch: Bool {
        !password.isEmpty && password == confirmPassword
    }

    private var isKerberosMode: Bool {
        appState.config.authMode == .systemNegotiated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Conduit")
                .font(.largeTitle.weight(.semibold))

            settingsRow("Auth Mode") {
                Picker("", selection: $appState.config.authMode) {
                    ForEach(AuthenticationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            if isKerberosMode {
                kerberosSection
            } else {
                ntlmSection
            }

            Divider().opacity(0.3)

            dnsSection

            Spacer()

            HStack {
                Button("Skip for now") {
                    appState.isShowingOnboarding = false
                    dismiss()
                }
                Spacer()
                Button("Save and Continue") {
                    saveDNS()
                    if !isKerberosMode && passwordsMatch {
                        appState.savePassword(password)
                    }
                    appState.saveConfig()
                    appState.isShowingOnboarding = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isKerberosMode && !passwordsMatch)
            }
        }
        .padding(24)
        .onAppear {
            detectedDNS = VPNDNSDetector.detect()
        }
    }

    // MARK: - Kerberos

    @ViewBuilder
    private var kerberosSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kerberos / SPNEGO")
                    .font(.headline)
                Text("Uses your system Kerberos ticket. No password required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        DisclosureGroup("Optional: Set up NTLMv2 fallback credentials") {
            VStack(alignment: .leading, spacing: 8) {
                Text("If your Kerberos ticket expires, these credentials provide a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirmPassword)
                if !password.isEmpty && !passwordsMatch {
                    Label("Passwords do not match.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                if passwordsMatch {
                    Button("Save NTLMv2 Credentials") {
                        appState.savePassword(password)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    // MARK: - NTLM

    @ViewBuilder
    private var ntlmSection: some View {
        Text("Set your password so the app can generate and store the NTLMv2 hash in Keychain.")
            .foregroundStyle(.secondary)

        SecureField("Password", text: $password)
        SecureField("Confirm password", text: $confirmPassword)

        if !password.isEmpty && !passwordsMatch {
            Label("Passwords do not match.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }

    // MARK: - DNS

    @ViewBuilder
    private var dnsSection: some View {
        if !detectedDNS.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("VPN DNS servers detected", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.medium))

                ForEach(detectedDNS, id: \.searchDomain) { config in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.searchDomain)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text(config.nameservers.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(config.interfaceName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Toggle("Use detected DNS servers", isOn: $useDetectedDNS)
                    .font(.subheadline)
            }
            .padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        TextField("Additional DNS servers (comma separated)", text: $dnsServers)
    }

    // MARK: - Helpers

    private func saveDNS() {
        if useDetectedDNS && !detectedDNS.isEmpty {
            let newEntries = detectedDNS.flatMap { $0.toDNSEntries() }
            let existingDomains = Set(appState.config.dnsEntries.map(\.domain))
            for entry in newEntries where !existingDomains.contains(entry.domain) {
                appState.config.dnsEntries.append(entry)
            }
        }

        if !dnsServers.isEmpty {
            let servers = dnsServers
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for index in appState.config.dnsEntries.indices {
                if appState.config.dnsEntries[index].servers.isEmpty {
                    appState.config.dnsEntries[index].servers = servers
                }
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
