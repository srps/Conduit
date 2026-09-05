// SPDX-License-Identifier: Apache-2.0
import Darwin
import SwiftUI

@main
struct ConduitApp: App {
    static let mainWindowID = "main"

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

        // The menu bar is the product: the glyph answers "is it working" with
        // zero clicks and the popover answers "can I flip it" with one. The
        // label is its own view so it re-renders when the runtime mirror
        // publishes; the `App` body itself does not observe nested objects.
        MenuBarExtra {
            StatusBarView()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
                .onChange(of: appState.appPreferences.globalShortcutEnabled) { _, _ in
                    appDelegate.configure(with: appState)
                }
        } label: {
            MenuBarLabel()
                .environmentObject(appState.runtime)
        }
        .menuBarExtraStyle(.window)

        // One window, single instance. It replaces the dashboard, Settings,
        // Logs, Connections, and Setup scenes. First-run setup is a sheet on
        // it, so the window is presented at launch exactly when that sheet
        // has something to ask; otherwise the app stays in the menu bar.
        Window("Conduit", id: Self.mainWindowID) {
            AppWindow()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
        }
        .defaultSize(width: 920, height: 640)
        .defaultLaunchBehavior(appState.isShowingOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            ConduitCommands(appState: appState)
        }
    }
}
