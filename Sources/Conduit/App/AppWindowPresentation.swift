// SPDX-License-Identifier: Apache-2.0
import AppKit

@MainActor
package enum AppWindowPresentation {
    package static func prepareForDetachedWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    package static func returnToMenuBarModeIfNoDetachedWindowsRemain() {
        guard NSApp.activationPolicy() == .regular else { return }
        let hasVisibleDetachedWindow = NSApp.windows.contains { window in
            window.isVisible && !isMenuBarExtraWindow(window)
        }
        if !hasVisibleDetachedWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    package static func isMenuBarExtraWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        if className.localizedCaseInsensitiveContains("MenuBarExtra") {
            return true
        }
        if className.localizedCaseInsensitiveContains("StatusItem") {
            return true
        }
        return false
    }
}
