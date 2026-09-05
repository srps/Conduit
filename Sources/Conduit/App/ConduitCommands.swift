// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Menu bar (the system one) commands for the single app window. ⌘0 opens it
/// on Overview; ⌘, opens it on the first Configure section so the standard
/// Settings shortcut keeps working even though Settings is a sidebar group
/// rather than a separate window.
struct ConduitCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Open Conduit") {
                open(.overview)
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("Settings…") {
                open(AppSection.firstConfigureSection)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(replacing: .appTermination) {
            Button("Quit Conduit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func open(_ section: AppSection) {
        appState.selectedSection = section
        AppWindowPresentation.prepareForAppWindow()
        openWindow(id: ConduitApp.mainWindowID)
    }
}
