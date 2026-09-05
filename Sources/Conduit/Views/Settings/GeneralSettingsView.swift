// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI
import UniformTypeIdentifiers

/// The app itself: profile, launch and window behaviour, the global
/// shortcut, diagnostics URLs, logging, import/export, and the privileged
/// helper.
struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ConfigureSection {
            Section {
                TextField("Profile Name", text: $appState.config.profileName)
                    .accessibilityLabel("Profile name")
            } header: {
                Text("Profile")
            } footer: {
                SettingsNote("Names the configuration and the Keychain item its credentials are stored under.")
            }

            Section {
                Toggle("Launch at login", isOn: $appState.platformConfig.launchAtLogin)
                Toggle("Keep window on top", isOn: $appState.appPreferences.floatingWindowEnabled)
                    .help("Float the Conduit window above other windows, for demos and screen sharing.")
                Toggle(isOn: $appState.appPreferences.globalShortcutEnabled) {
                    HStack(spacing: 6) {
                        Text("Toggle proxy from any app")
                        Text(ConduitAppDelegate.toggleShortcutDescription)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .help("A global shortcut that starts or stops the proxy from any application. Off by default because it claims its chord everywhere.")
            } header: {
                Text("App")
            }

            Section {
                TextField("Health Check URL", text: $appState.config.healthCheckURL)
                    .accessibilityLabel("Health check URL")
                TextField("Browser Test URL", text: $appState.appPreferences.preferredBrowserTestURL)
                    .accessibilityLabel("Browser test URL")
                HStack(spacing: 8) {
                    Button("Open Test URL") { appState.revealHealthTestURL() }
                    Spacer()
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                SettingsNote("The health check URL is probed through each upstream to rank them. The browser test URL is what Open Test URL and Preview PAC use.")
            }

            Section {
                Toggle("Verbose logging", isOn: $appState.config.verboseLogging)
                    .help("When enabled, debug and info messages are included in stderr and the in-app event list.")
                Toggle("File logging", isOn: Binding(
                    get: { appState.appPreferences.fileLoggingEnabled },
                    set: { enabled in
                        appState.appPreferences.fileLoggingEnabled = enabled
                        appState.logStore.logFileURL = enabled ? AppLogStore.defaultLogFileURL : nil
                    }
                ))
                // Not "all log entries": the file gets what passes the sink's
                // level, which is notice-and-up unless verbose logging is on.
                .help("Append notice-and-up entries (everything, with verbose logging) to ~/Library/Logs/Conduit/proxy.log, rolled at 5 MB with 3 archives kept. On by default.")
                if let url = appState.logStore.logFileURL {
                    LabeledContent("Log file") {
                        Text(url.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Logging")
            }

            Section {
                HStack(spacing: 8) {
                    Button("Import Config…") { importConfiguration() }
                    Button("Export Config…") { exportConfiguration() }
                    Spacer()
                }
            } header: {
                Text("Configuration")
            } footer: {
                SettingsNote("Export writes the runtime configuration as JSON. Credentials stay in the Keychain and are not exported.")
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(HelperStatusPresentation.color(for: appState.helperStatus))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(HelperStatusPresentation.label(for: appState.helperStatus))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Privileged helper status: \(HelperStatusPresentation.label(for: appState.helperStatus))")
                }
                HStack(spacing: 8) {
                    Button(HelperStatusPresentation.primaryActionTitle(for: appState.helperStatus)) {
                        appState.installHelper()
                    }
                    .help("Install or update the privileged helper.")

                    if appState.helperStatus != .notInstalled {
                        Button("Uninstall Helper") {
                            appState.uninstallHelper()
                        }
                        .help("Remove the privileged helper and fall back to macOS admin prompts.")
                    }
                    Spacer()
                }
            } header: {
                Text("Privileged Helper")
            } footer: {
                SettingsNote("Install the helper once to manage system proxy and split DNS without repeated admin prompts. Reinstall after helper protocol changes or when the status is outdated.")
            }
        }
    }

    // MARK: - Import/Export

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try appState.importConfiguration(from: url)
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Conduit-config.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try appState.exportConfiguration(to: url)
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
