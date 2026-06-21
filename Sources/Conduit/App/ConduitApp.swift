// SPDX-License-Identifier: Apache-2.0
import Darwin
import SwiftUI

@main
struct ConduitApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(ConduitAppDelegate.self) private var appDelegate

    init() {
        // Ignore SIGPIPE process-wide. NIO sets `SO_NOSIGPIPE` per-socket on
        // Darwin, so writes against a closed peer on a NIO channel surface as
        // `EPIPE` rather than the signal — but `Pipe()`-based `Process()`
        // plumbing in `PlatformMac/CommandRunner.swift` is *not* covered by
        // that, and a child that exits between `process.run()` and the parent
        // writing to its stdin pipe would otherwise terminate the GUI silently
        // (default disposition for SIGPIPE is terminate, no crash report).
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        let _ = appDelegate.configure(with: appState)
        MenuBarExtra("Conduit", systemImage: "network") {
            StatusBarView()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
                .onChange(of: appState.appPreferences.globalShortcutEnabled) { _, _ in
                    appDelegate.configure(with: appState)
                }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Conduit", id: "dashboard") {
            MainView()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
                .sheet(isPresented: $appState.isShowingSettings) {
                    SettingsView()
                        .environmentObject(appState)
                        .environmentObject(appState.runtime)
                }
                .sheet(isPresented: $appState.isShowingLogs) {
                    LogView(logStore: appState.logStore)
                        .frame(width: 780, height: 540)
                }
                .sheet(isPresented: $appState.isShowingOnboarding) {
                    SetupWizardView()
                        .environmentObject(appState)
                        .frame(width: 520, height: 420)
                }
        }
        .defaultSize(width: 420, height: 540)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            ConduitCommands()
        }

        WindowGroup("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
        }
        .defaultSize(width: 720, height: 620)

        WindowGroup("Logs", id: "logs") {
            LogView(logStore: appState.logStore)
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 780, height: 540)

        WindowGroup("Connections", id: "connections") {
            ConnectionsView(compact: false)
                .environmentObject(appState.runtime)
                .padding(20)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 560, height: 420)

        WindowGroup("Setup Wizard", id: "setup") {
            SetupWizardView()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultSize(width: 520, height: 420)
    }
}
