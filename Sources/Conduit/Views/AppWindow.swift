// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

/// The single app window: a sidebar of sections and one detail pane. It
/// holds everything the popover does not — the live views and one Configure
/// section per subsystem, each with its live state above its knobs.
struct AppWindow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .navigationTitle(appState.selectedSection.title)
                // Overview and the Configure sections without a live strip
                // put their scroll view against the top of the pane, so rows
                // scroll under the title bar. The default soft edge fades
                // them and leaves ghost text behind the title; the hard edge
                // is an opaque bar they disappear under.
                .scrollEdgeEffectStyle(.hard, for: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .background(AppWindowTracker())
        .background(WindowBehaviorView(enabled: appState.appPreferences.floatingWindowEnabled))
        .sheet(isPresented: $appState.isShowingOnboarding) {
            SetupWizardView()
                .environmentObject(appState)
                .frame(width: 520, height: 440)
        }
    }

    private var sidebar: some View {
        List(selection: $appState.selectedSection) {
            sidebarRow(.overview)

            Section("Monitor") {
                ForEach(AppSection.monitorSections) { section in
                    sidebarRow(section)
                }
            }

            Section("Configure") {
                ForEach(AppSection.configureSections) { section in
                    sidebarRow(section)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selectedSection {
        case .overview:
            OverviewView()
        case .connections:
            ConnectionsView()
                .padding(20)
        case .events:
            LogView(logStore: appState.logStore)
        case .proxy:
            configure { ProxySettingsView() }
        case .upstreams:
            configure { UpstreamsSettingsView() }
        case .authentication:
            configure { AuthenticationSettingsView() }
        case .dns:
            configure { DNSSettingsView() }
        case .tunnels:
            configure { TunnelsSettingsView() }
        case .shellEnvironment:
            configure { ShellEnvironmentSettingsView() }
        case .general:
            configure { GeneralSettingsView() }
        case .advanced:
            configure { AdvancedSettingsView() }
        }
    }

    /// Edits save themselves once they pause (`AppState.scheduleSave()`,
    /// #171), which also reconciles and re-validates, so there is no "OK"
    /// to press. An edit that would replace a listener waits for a commit
    /// instead, so a half-typed port is never bound: Return in any field
    /// of the section, the Apply button in the note below, or the section
    /// going away (switching sections or closing the window).
    private func configure<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            // One main-actor hop later: a formatted number field commits
            // its value, and `HostListEditor` tidies its rows, on the same
            // Return, and the commit must carry both.
            .onSubmit { Task { @MainActor in appState.commitPendingEdit(trigger: .submit) } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.listenerEditAwaitingCommit {
                    // Clicking Apply leaves the field editing, its typed
                    // text not yet in the draft: end editing, then commit.
                    PendingListenerEditNote {
                        appState.commitPendingEdit(trigger: .apply) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
                }
            }
            .onDisappear { appState.commitPendingEdit(trigger: .sectionClose) }
    }
}

/// Shown while an edit to a port, host, listener switch, the DNS section,
/// the local PAC server or a tunnel waits for its commit.
private struct PendingListenerEditNote: View {
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Listener changes apply when you press Return, click Apply, leave this section or quit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Apply", action: apply)
                .accessibilityHint("Applies the listener changes now")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}
