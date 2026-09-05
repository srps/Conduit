// SPDX-License-Identifier: Apache-2.0
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

    /// Edits apply live through `AppState.saveConfig()`, which also persists
    /// and re-validates. Every Configure section saves when it goes away —
    /// switching sections or closing the window — so there is no "OK" to
    /// press and nothing to lose.
    private func configure<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .onDisappear { appState.saveConfig() }
    }
}
