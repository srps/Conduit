// SPDX-License-Identifier: Apache-2.0
import AppKit

@MainActor
final class ConduitAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?

    func configure(with appState: AppState) {
        self.appState = appState
        installShortcutMonitors()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-first mode: keep the app resident without presenting the
        // main dashboard at launch. Users can open Settings / Logs /
        // Connections / Dashboard explicitly from the MenuBarExtra. Set this
        // before SwiftUI creates the menu-bar extra's focus chain.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Conduit must keep the local proxy and menu bar controller resident.")
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppWindowPresentation.returnToMenuBarModeIfNoDetachedWindowsRemain()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.performTerminationCleanup()
        removeShortcutMonitors()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
    }

    func installShortcutMonitors() {
        removeShortcutMonitors()
        guard appState?.appPreferences.globalShortcutEnabled == true else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.matchesToggleShortcut(event) == true else { return event }
            Task { @MainActor in
                self?.appState?.toggleProxy()
            }
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.matchesToggleShortcut(event) == true else { return }
            Task { @MainActor in
                self?.appState?.toggleProxy()
            }
        }
    }

    private func removeShortcutMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
            && event.charactersIgnoringModifiers?.lowercased() == "p"
    }
}
