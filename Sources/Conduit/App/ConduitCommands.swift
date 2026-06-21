// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

struct ConduitCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Detach Full UI") {
                openDetachedWindow("dashboard")
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("Settings") {
                openDetachedWindow("settings")
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

    private func openDetachedWindow(_ id: String) {
        AppWindowPresentation.prepareForDetachedWindow()
        openWindow(id: id)
    }
}
