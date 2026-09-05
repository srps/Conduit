// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI

/// Activation-policy bookkeeping for a menu bar app with one real window.
///
/// The app runs as an accessory (no Dock icon) until the app window is
/// shown, and returns to accessory when it closes. The window is recognised
/// by registration, not by sniffing `NSWindow` class names: the window's
/// content registers itself through `AppWindowTracker` when it is attached,
/// so the check is "is one of our windows visible", which survives macOS
/// renaming its private MenuBarExtra window classes.
@MainActor
package enum AppWindowPresentation {
    private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Switch to a regular app (Dock icon, menu bar, key window) before a
    /// window is shown so the window can become key on first display.
    package static func prepareForAppWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when the app window's content lands in an `NSWindow` — both for
    /// windows opened through `openWindow` and for the one SwiftUI presents at
    /// launch for first-run setup, which never passes through
    /// `prepareForAppWindow`.
    package static func track(_ window: NSWindow) {
        guard !trackedWindows.contains(window) else { return }
        trackedWindows.add(window)
        prepareForAppWindow()
    }

    package static func returnToMenuBarModeIfNoAppWindowRemains() {
        guard NSApp.activationPolicy() == .regular else { return }
        if !hasVisibleAppWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    package static var hasVisibleAppWindow: Bool {
        trackedWindows.allObjects.contains { $0.isVisible }
    }

    /// Pure decision behind `returnToMenuBarModeIfNoAppWindowRemains`, kept
    /// separate so the policy is testable without an `NSApp`.
    nonisolated package static func shouldReturnToMenuBarMode(isRegular: Bool, visibleAppWindows: Int) -> Bool {
        isRegular && visibleAppWindows == 0
    }
}

/// Registers the hosting window with `AppWindowPresentation` as soon as the
/// view is attached. Zero-size; attach it as a `.background`.
struct AppWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppWindowPresentation.track(window)
        }
    }
}
