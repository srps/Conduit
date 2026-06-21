// SPDX-License-Identifier: Apache-2.0
import AppKit
import PlatformMac
import ProxyKernel
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case proxy, auth, network, tunnels, dns, env, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxy: return "Proxy"
        case .auth: return "Auth"
        case .network: return "Network"
        case .tunnels: return "Tunnels"
        case .dns: return "DNS"
        case .env: return "Env"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .proxy: "network"
        case .auth: "key"
        case .network: "bolt.horizontal"
        case .tunnels: "point.3.connected.trianglepath.dotted"
        case .dns: "globe"
        case .env: "terminal"
        case .advanced: "gearshape"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .proxy
    @State private var draggedUpstreamID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.3)
            tabContent
        }
        .frame(width: 680, height: 560)
        .background(.ultraThinMaterial)
        .controlSize(.regular)
        .onDisappear { appState.saveConfig() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Close") {
                appState.saveConfig()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .background(
                            selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear,
                            in: .capsule
                        )
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedTab {
                case .proxy: proxyTab
                case .auth: authTab
                case .network: networkTab
                case .tunnels: tunnelsTab
                case .dns: dnsTab
                case .env: envTab
                case .advanced: advancedTab
                }
            }
            .padding(24)
        }
    }

    // MARK: - Proxy Tab

    private var proxyTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Local Proxy", systemImage: "network") {
                settingsRow("Profile Name") {
                    TextField("", text: $appState.config.profileName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Profile name")
                }
                settingsRow("Local Host") {
                    TextField("", text: $appState.config.localHost)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Local host")
                }
                settingsRow("Local Port") {
                    TextField("", value: $appState.config.localPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .accessibilityLabel("Local port")
                }
                Toggle("Show menu bar icon", isOn: $appState.appPreferences.showMenuBarIcon)
                Toggle("Enable floating window mode", isOn: $appState.appPreferences.floatingWindowEnabled)
            }

            settingsGroup("macOS System Proxy", systemImage: "macwindow") {
                Toggle(isOn: $appState.platformConfig.manageSystemProxy) {
                    HStack(spacing: 4) {
                        Text("Manage macOS proxy settings")
                        Text(appState.helperStatus == .installed ? "(via helper)" : "(may require admin)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: adaptiveLocalPACBinding) {
                    Text("Use adaptive local PAC for macOS")
                }
                Text("Recommended for browsers and system apps. macOS points at Conduit's local PAC; the PAC returns the local proxy while upstream routing is available and DIRECT when direct mode should bypass Conduit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.platformConfig.systemProxyMode == .manual || !appState.config.localPACEnabled {
                    Text("Manual system proxy mode keeps macOS pinned to the local HTTP/HTTPS proxy. Use it only for clients that cannot honor PAC.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingsRow("Local PAC Port") {
                    TextField("", value: $appState.config.localPACPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(!appState.config.localPACEnabled)
                        .accessibilityLabel("Local PAC port")
                }
                if let localPACURL = appState.runtime.bindings.localPACURL, appState.config.localPACEnabled {
                    Text("Currently serving: \(localPACURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            settingsGroup("Upstream PAC Routing", systemImage: "doc.text.magnifyingglass") {
                settingsRow("Upstream PAC URL") {
                    TextField("https://...", text: $appState.config.pacURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Upstream PAC URL")
                }
                Toggle("Use upstream PAC for Conduit routing", isOn: $appState.config.pacRoutingEnabled)
                    .disabled(appState.config.pacURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("This PAC is fetched by Conduit and evaluated per request. It decides DIRECT vs proxy chains such as PROXY A; PROXY B; DIRECT. It is separate from the adaptive local PAC served to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.config.pacURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add an upstream PAC URL to enable PAC-based routing decisions. Without one, enabled upstream proxies are tried by priority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsGroup("Upstream Proxies & Failover", systemImage: "arrow.triangle.branch") {
                Text("Enabled upstreams are health-ranked and tried by priority when upstream PAC routing is disabled or when the PAC returns a matching configured proxy. PAC-only proxies can still be tried for that request, but adding them here gives Conduit health status, credentials, and normal failover visibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                upstreamProxyList
            }

            settingsGroup("SOCKS5 Proxy", systemImage: "arrow.left.arrow.right.circle") {
                Toggle("Enable SOCKS5 server", isOn: $appState.config.socksEnabled)
                settingsRow("SOCKS5 Port") {
                    TextField("", value: $appState.config.socksPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(!appState.config.socksEnabled)
                        .accessibilityLabel("SOCKS5 port")
                }
                if appState.config.socksEnabled {
                    Text("SOCKS5 server starts with the HTTP proxy on 127.0.0.1:\(appState.config.socksPort). Supports TCP CONNECT tunneling through the corporate proxy. Used by MongoDB drivers, some CLI tools, and proxychains.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsGroup("Gateway Mode (LAN / Docker / VMs)", systemImage: "server.rack") {
                Toggle("Enable gateway mode", isOn: $appState.config.gatewayMode)
                    .help("Accept proxy connections from other machines (Docker containers, VMs, LAN devices). Requires the Listen Host above to be 0.0.0.0 — validation enforces that the wildcard bind and gateway mode are enabled together.")

                if appState.config.gatewayMode {
                    settingsRow("Allowed Clients") {
                        HostListEditor(
                            entries: $appState.config.allowedClients,
                            placeholder: "192.168.64.5",
                            accessibilityName: "allowed client"
                        )
                        .help("Exact client IP addresses allowed to connect. Connections from any other address are rejected before proxying.")
                    }
                    Text("Only the listed IP addresses may use the proxy. Cloud-metadata and loopback targets are blocked for gateway clients. Inbound client authentication is not yet implemented — until then, treat this allow-list as the only gate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var upstreamProxyList: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("").frame(width: 24)
                Text("Order").frame(width: 44).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Enabled").frame(width: 56).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Name").frame(minWidth: 80, alignment: .leading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Host").frame(minWidth: 160, alignment: .leading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Port").frame(width: 64).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            ForEach(Array(orderedUpstreamIDs.enumerated()), id: \.element) { offset, id in
                if let upstream = upstreamBinding(id: id) {
                    upstreamRow(upstream, order: offset + 1)
                        .onDrop(
                            of: [UTType.text],
                            delegate: UpstreamDropDelegate(
                                targetID: id,
                                draggedID: $draggedUpstreamID,
                                move: moveUpstream
                            )
                        )
                }
            }

            if !appState.config.upstreams.isEmpty {
                Text("Drop here to move to the end")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onDrop(
                        of: [UTType.text],
                        delegate: UpstreamDropDelegate(
                            targetID: nil,
                            draggedID: $draggedUpstreamID,
                            move: moveUpstream
                        )
                    )
            }

            HStack(spacing: 8) {
                Button("Add Proxy") {
                    appState.config.upstreams.append(
                        UpstreamProxy(name: "", host: "", port: 8080, priority: appState.config.upstreams.count)
                    )
                    normalizeUpstreamPriorities()
                }
                .buttonStyle(.bordered)

                if !appState.config.upstreams.isEmpty {
                    Button("Remove Last") {
                        removeLastUpstream()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func upstreamRow(_ upstream: Binding<UpstreamProxy>, order: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
                .contentShape(Rectangle())
                .onDrag {
                    draggedUpstreamID = upstream.wrappedValue.id
                    return NSItemProvider(object: upstream.wrappedValue.id.uuidString as NSString)
                }
                .accessibilityLabel("Drag upstream")
            Text("\(order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44)
            Toggle("", isOn: upstream.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 56)
                .accessibilityLabel(accessibilityUpstreamLabel(for: upstream.wrappedValue))
            TextField("Name", text: upstream.name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 80)
                .accessibilityLabel("Upstream name")
            TextField("Host", text: upstream.host)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .accessibilityLabel("Upstream host")
            TextField("", value: upstream.port, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel("Upstream port")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(upstream.wrappedValue.id == draggedUpstreamID ? 0.06 : 0.025),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Auth Tab

    private var authTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Authentication")

            settingsRow("Mode") {
                Picker("", selection: $appState.config.authMode) {
                    ForEach(AuthenticationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel("Authentication mode")
            }

            if appState.config.authMode == .systemNegotiated {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kerberos / SPNEGO")
                            .font(.subheadline.weight(.medium))
                        Text("Uses your system Kerberos ticket (from kinit or macOS SSO). No password storage needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                DisclosureGroup("NTLMv2 Fallback Credentials") {
                    ntlmCredentialFields
                }
                .font(.subheadline)
            } else {
                ntlmCredentialFields
            }

            Divider().opacity(0.3)

            HStack(spacing: 8) {
                Button("Open Setup Wizard") {
                    appState.isShowingOnboarding = true
                }
                .buttonStyle(.borderedProminent)

                if appState.config.authMode == .ntlmv2 || appState.credentialManager.hasSavedCredentials(for: appState.config) {
                    Button("Clear Saved Credentials") {
                        appState.clearCredentials()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var ntlmCredentialFields: some View {
        settingsRow("Username") {
            TextField("", text: $appState.config.username)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Username")
        }
        settingsRow("Domain") {
            TextField("", text: $appState.config.domain)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Domain")
        }
        settingsRow("Workstation") {
            TextField("", text: $appState.config.workstation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Workstation")
        }
    }

    // MARK: - Network Tab

    private var networkTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("App Behavior")

            Toggle("Launch at login", isOn: $appState.platformConfig.launchAtLogin)
            Toggle("Enable global shortcut (Cmd+Shift+P)", isOn: $appState.appPreferences.globalShortcutEnabled)
            // Note: the legacy "Enable automatically when VPN is detected" /
            // "Disable automatically when VPN disconnects" toggles were retired
            // in Phase 3 of docs/design-vpn-flap-resilience.md. Direct mode is
            // now silent and fast off-VPN, so the nuclear toggle is unneeded.

            Divider().opacity(0.3)
            sectionHeader("Health & Diagnostics")

            settingsRow("Health Check URL") {
                TextField("", text: $appState.config.healthCheckURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Health check URL")
            }
            settingsRow("Browser Test URL") {
                TextField("", text: $appState.appPreferences.preferredBrowserTestURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Browser test URL")
            }

            HStack(spacing: 8) {
                Button("Preview PAC") {
                    appState.refreshPACResolutionPreview()
                }
                .buttonStyle(.bordered)

                Button("Open Test URL") {
                    appState.revealHealthTestURL()
                }
                .buttonStyle(.bordered)
            }

            Divider().opacity(0.3)
            sectionHeader("VPN Flap Resilience")

            // Phase 7 (design-vpn-flap-resilience.md). Two sliders for the
            // two-stage debounce that absorbs transient utun jitter:
            //
            //   1. min-visible: how long an inactive Link must persist before
            //      we even tell the rest of the app a flap is happening. Sub-
            //      window blips never reach the orchestrator.
            //   2. grace: once the flap IS visible, how long we hold the
            //      reasserting state before declaring a real disconnect.
            //
            // Active streams ride the whole window via TCP keepalive — these
            // values control control-plane reaction speed, never user-data
            // teardown timing.
            settingsRow("Min Visible Flap (s)") {
                vpnFlapMinVisibleSlider
            }
            settingsRow("Flap Grace Window (s)") {
                vpnFlapGraceSlider
            }
            Text("Brief VPN dropouts shorter than the min-visible window are silent. " +
                 "Longer ones show as \"Reconnecting…\" until the grace window expires; " +
                 "active streams are preserved for the full window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - VPN Flap Sliders (Phase 7)

    private var vpnFlapMinVisibleSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(
                value: $appState.config.vpnFlapMinVisibleSeconds,
                in: 0...5,
                step: 0.25
            )
            .frame(maxWidth: 280)
            .accessibilityLabel("Minimum visible flap seconds")
            .help("How long an utun interface must remain inactive before the orchestrator " +
                  "treats the dropout as a user-visible flap. Sub-window blips stay silent: " +
                  "no event, no UI flicker, no routing change.")
            // The min-visible slider is the only one that can hit zero; that
            // disables the debounce entirely (every utun blip is a "real" flap).
            Text(formattedSeconds(appState.config.vpnFlapMinVisibleSeconds, zeroLabel: "off"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vpnFlapGraceSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(
                value: $appState.config.vpnFlapGraceSeconds,
                in: 1...30,
                step: 1
            )
            .frame(maxWidth: 280)
            .accessibilityLabel("VPN flap grace window seconds")
            .help("How long after a VPN drop the orchestrator waits before declaring a real " +
                  "disconnect. Within this window the state is \"Reconnecting…\" and active " +
                  "streams are preserved by kernel keepalive — no new routing decisions are made.")
            // Slider range is 1...30, so the zero branch in `formattedSeconds`
            // never triggers here — no `zeroLabel:` argument is meaningful.
            Text(formattedSeconds(appState.config.vpnFlapGraceSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `zeroLabel` only applies to sliders whose range includes 0. Callers whose
    /// range starts above zero (e.g. the grace slider) should omit it.
    private func formattedSeconds(_ value: TimeInterval, zeroLabel: String? = nil) -> String {
        if value <= 0, let zeroLabel { return zeroLabel }
        if value < 1 {
            return String(format: "%.2fs", value)
        }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))s"
        }
        return String(format: "%.2fs", value)
    }

    // MARK: - DNS Tab

    private var dnsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if appState.helperStatus != .installed {
                helperHintBanner
            }

            sectionHeader("Split DNS")

            Toggle(isOn: $appState.platformConfig.manageDNSResolvers) {
                HStack(spacing: 4) {
                    Text("Manage /etc/resolver split DNS")
                    Text(appState.helperStatus == .installed ? "(via helper)" : "(requires admin)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(appState.config.dnsEntries) { entryValue in
                if let entry = dnsEntryBinding(id: entryValue.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(
                                "Enable \(entry.wrappedValue.domain.isEmpty ? "DNS entry" : entry.wrappedValue.domain)",
                                isOn: entry.enabled
                            )
                            .accessibilityLabel("Enable \(entry.wrappedValue.domain.isEmpty ? "DNS entry" : entry.wrappedValue.domain)")

                            Spacer()

                            Button(role: .destructive) {
                                appState.config.dnsEntries.removeAll { $0.id == entryValue.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete DNS entry \(entry.wrappedValue.domain.isEmpty ? "" : entry.wrappedValue.domain)")
                            .help("Delete this DNS entry")
                        }
                        settingsRow("Domain") {
                            TextField("", text: entry.domain)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("DNS domain")
                        }
                        settingsRow("DNS Servers") {
                            TextField("Comma separated", text: dnsBinding(for: entry))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("DNS servers")
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            HStack(spacing: 8) {
                Button("Add DNS Entry") {
                    appState.config.dnsEntries.append(DomainDNSEntry(domain: "", servers: []))
                }
                .buttonStyle(.bordered)

                Button("Auto-detect from VPN") {
                    let detected = VPNDNSDetector.detect()
                    let existingDomains = Set(appState.config.dnsEntries.map(\.domain))
                    for config in detected {
                        for entry in config.toDNSEntries() where !existingDomains.contains(entry.domain) {
                            appState.config.dnsEntries.append(entry)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .help("Detect corporate DNS servers pushed by your VPN connection and add them as split-DNS entries.")
            }

            Divider().opacity(0.3)
            sectionHeader("DNS Forwarder")

            Text("The DNS forwarder resolves external domains via DNS-over-HTTPS when internal DNS returns NXDOMAIN. Start and stop it from the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.platformConfig.manageSystemDNS) {
                HStack(spacing: 4) {
                    Text("Manage system DNS")
                    Text(appState.helperStatus == .installed ? "(via helper)" : "(requires admin)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Sets macOS DNS to the local forwarder (port 53) so all apps use DoH for external domains. Original DNS settings are restored on stop or crash recovery.")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsRow("Listen Port") {
                TextField("", value: $appState.config.dnsForwarderPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityLabel("DNS forwarder port")
            }
            if appState.platformConfig.manageSystemDNS {
                Text("Port 53 relay runs in the privileged helper. The forwarder listens on the port above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.3)
            sectionHeader("DoH Providers")

            Text("DNS-over-HTTPS providers tried in order for external domains. Each must support the JSON API (?name=&type= with Accept: application/dns-json).")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsRow("Providers") {
                HostListEditor(
                    entries: $appState.config.dohProviders,
                    placeholder: "https://dns.example.com/dns-query",
                    accessibilityName: "DoH provider"
                )
                .help("Tried top to bottom; the first reachable provider answers the query.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Test with:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("dig @127.0.0.1 -p \(appState.config.dnsForwarderPort) www.google.com")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Standalone CLI:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("pm-dns --port \(appState.config.dnsForwarderPort) --verbose")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider().opacity(0.3)
            sectionHeader("DNS Intercept + Transparent Proxy")

            Text("Intercept DNS queries for matched domains and route their traffic through the corporate proxy transparently. Solves apps like Cursor that bypass HTTP_PROXY (http2.connect).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $appState.config.transparentProxyEnabled) {
                Text("Enable transparent proxy")
            }

            if appState.config.transparentProxyEnabled {
                settingsRow("Intercept IP") {
                    TextField("", text: $appState.config.transparentProxyIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityLabel("Transparent proxy intercept IP")
                }
                Text("Dedicated loopback IP for intercepted traffic. Default 127.44.3.0 avoids conflicts with dev servers on 127.0.0.1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                settingsRow("Listen Port") {
                    TextField("", value: $appState.config.transparentProxyPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Transparent proxy listen port")
                }

                Divider().opacity(0.2)

                HStack {
                    Text("Intercept Rules")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("Cursor (*.cursor.sh, *.cursorapi.com)") {
                            addCursorPresetRules()
                        }
                        Divider()
                        Button("Add Custom Rule") {
                            appState.config.dnsInterceptRules.append(
                                DNSInterceptRule(pattern: "*.example.com", interceptIP: appState.config.transparentProxyIP)
                            )
                        }
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                            .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if appState.config.dnsInterceptRules.isEmpty {
                    Text("No intercept rules. Add a preset or custom rule above.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach($appState.config.dnsInterceptRules) { $rule in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $rule.enabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                TextField("Pattern", text: $rule.pattern)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(minWidth: 160)
                                Text("→")
                                    .foregroundStyle(.tertiary)
                                TextField("IP", text: $rule.interceptIP)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 120)
                                Button {
                                    appState.config.dnsInterceptRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text("Requires DNS forwarder + system DNS management enabled. Helper required for port 443 relay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addCursorPresetRules() {
        let ip = appState.config.transparentProxyIP
        let existing = Set(appState.config.dnsInterceptRules.map { $0.pattern.lowercased() })
        let presets = ["*.cursor.sh", "*.cursorapi.com"]
        for pattern in presets where !existing.contains(pattern) {
            appState.config.dnsInterceptRules.append(
                DNSInterceptRule(pattern: pattern, interceptIP: ip)
            )
        }
    }

    // MARK: - Tunnels Tab

    private var tunnelsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if appState.helperStatus != .installed {
                helperHintBanner
            }

            sectionHeader("How It Works")
            Text("Protocol tunnels route non-HTTP traffic (MongoDB, PostgreSQL, Redis, etc.) through your corporate proxy using HTTP CONNECT. Point your client at the local port instead of the remote server.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().opacity(0.3)
            sectionHeader("Quick Add from Preset")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(TunnelPreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        appState.config.tunnelDefinitions.append(preset.makeDefinition())
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.displayName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(":\(preset.defaultRemotePort)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(preset.helpText)
                }
            }

            Divider().opacity(0.3)
            sectionHeader("Tunnel Definitions")

            if appState.config.tunnelDefinitions.isEmpty {
                Text("No tunnels configured. Add one from the presets above or use the button below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                tunnelDefinitionsList
            }

            HStack(spacing: 8) {
                Button("Add Custom Tunnel") {
                    appState.config.tunnelDefinitions.append(
                        TunnelDefinition(localPort: 0, remoteHost: "", remotePort: 0, proxied: true, label: "")
                    )
                }
                .buttonStyle(.bordered)

                if !appState.config.tunnelDefinitions.isEmpty {
                    Button("Remove Last") {
                        appState.config.tunnelDefinitions.removeLast()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            Divider().opacity(0.3)
            sectionHeader("Session Limits")

            settingsRow("Global Max Sessions") {
                TextField("", value: $appState.config.maxTunnelSessions, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityLabel("Maximum total tunnel sessions")
            }
            settingsRow("Per-Tunnel Max") {
                TextField("", value: $appState.config.maxSessionsPerTunnel, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityLabel("Maximum sessions per tunnel")
            }
            Text("Tunnel sessions are long-lived dedicated TCP connections. These limits are separate from the HTTP proxy connection pool.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tunnelDefinitionsList: some View {
        VStack(spacing: 8) {
            ForEach(appState.config.tunnelDefinitions) { def in
                if let binding = tunnelBinding(id: def.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Toggle("", isOn: binding.enabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .accessibilityLabel("Enable tunnel \(binding.wrappedValue.effectiveLabel)")

                            TextField("Label", text: binding.label)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 100)

                            Spacer()

                            Toggle("Proxied", isOn: binding.proxied)
                                .toggleStyle(.switch)
                                .font(.caption)

                            Button(role: .destructive) {
                                appState.config.tunnelDefinitions.removeAll { $0.id == def.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete tunnel")
                        }

                        HStack(spacing: 8) {
                            Text("Local")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            TextField("Port", value: binding.localPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)

                            Text("→")
                                .foregroundStyle(.tertiary)

                            TextField(
                                binding.wrappedValue.preset?.hostPlaceholder ?? "Remote host",
                                text: binding.remoteHost
                            )
                            .textFieldStyle(.roundedBorder)

                            Text(":")
                                .foregroundStyle(.tertiary)

                            TextField("Port", value: binding.remotePort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                        .font(.system(size: 12, design: .monospaced))

                        if binding.wrappedValue.proxied && !binding.wrappedValue.remoteHost.isEmpty {
                            tunnelConnectionGuidance(for: binding.wrappedValue)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func tunnelConnectionGuidance(for def: TunnelDefinition) -> some View {
        let dnsStatus = runtime.tunnelDNSOverrideStatus
        let isActive: Bool = {
            switch dnsStatus {
            case .active(let hosts): return hosts.contains(def.remoteHost.lowercased())
            case .partial(let succeeded, _): return succeeded.contains(def.remoteHost.lowercased())
            default: return false
            }
        }()
        let portsMatch = def.localPort == def.remotePort

        Divider().opacity(0.2)

        if runtime.tunnelsRunState == .running && isActive && portsMatch {
            Label("DNS override active — use your normal connection string.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        } else if runtime.tunnelsRunState == .running && isActive && !portsMatch {
            VStack(alignment: .leading, spacing: 6) {
                Label("DNS override active — connect to \(def.remoteHost):\(def.localPort) (tunnel listen port).", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)

                tunnelCopyRow(
                    label: "Connection host:port",
                    value: "\(def.remoteHost):\(def.localPort)"
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if runtime.tunnelsRunState == .running {
                    Label("DNS override unavailable — use one of the options below.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if def.preset == .mongoDBAtlas || def.preset == .cosmosDBMongo {
                    tunnelCopyRow(
                        label: "SOCKS5 (recommended for MongoDB)",
                        value: "mongosh \"mongodb://\(def.remoteHost):\(def.remotePort)/\" --tls --proxyHost 127.0.0.1 --proxyPort \(appState.config.socksPort)"
                    )
                }

                tunnelCopyRow(
                    label: "/etc/hosts (requires sudo)",
                    value: "127.0.0.1  \(def.remoteHost)"
                )
            }
        }
    }

    private func tunnelCopyRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }

    private func tunnelBinding(id: UUID) -> Binding<TunnelDefinition>? {
        guard let index = appState.config.tunnelDefinitions.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $appState.config.tunnelDefinitions[index]
    }

    // MARK: - Env Tab

    private var envTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Environment Variables")

            Toggle("Manage shell proxy environment variables", isOn: $appState.platformConfig.manageEnvironmentVariables)
            Text("For CLI tools, shell environments are static per process. Keeping HTTP_PROXY/HTTPS_PROXY pointed at Conduit lets it act as the adaptive router: proxy on VPN, DIRECT off VPN, with NO_PROXY keeping localhost callbacks out of the proxy path.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            settingsRow("NO_PROXY entries") {
                HostListEditor(
                    entries: $appState.config.noProxyHosts,
                    placeholder: "localhost",
                    accessibilityName: "NO_PROXY"
                )
            }
            settingsRow("Force-proxy hosts") {
                HostListEditor(
                    entries: $appState.config.forceProxyHosts,
                    placeholder: "internal.example.com",
                    accessibilityName: "Force proxy host"
                )
            }

            Text("Managed files: ~/.zshrc, ~/.zprofile, ~/.config/environment.d/proxy-manager.conf")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Timers & Limits")

            settingsRow("Health Check Interval (s)") {
                TextField("", value: $appState.config.healthCheckIntervalSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Health check interval seconds")
            }
            settingsRow("Stalled Timeout (s)") {
                TextField("", value: $appState.config.stalledConnectionTimeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Stalled timeout seconds")
            }
            settingsRow("Max Connections") {
                TextField("", value: $appState.config.maxConnections, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Maximum connections")
            }
            settingsRow("Conn. Warn Threshold") {
                TextField("", value: $appState.config.inboundConnectionWarnThreshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Inbound connection warn threshold")
            }
            settingsRow("Conn. Max Limit") {
                TextField("", value: $appState.config.inboundConnectionMaxLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Inbound connection max limit")
            }
            settingsRow("Max Buffered Body (MB)") {
                TextField("", value: Binding(
                    get: { Double(appState.config.maxBufferedBodyBytes) / 1_048_576.0 },
                    set: { appState.config.maxBufferedBodyBytes = max(1_048_576, Int($0 * 1_048_576.0)) }
                ), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Max buffered request body megabytes")
                    .help("Request bodies larger than this are not fully buffered. If proxy auth replay is needed, oversized requests will fail.")
            }
            settingsRow("Max Spooled Body (MB)") {
                TextField("", value: Binding(
                    get: { Double(appState.config.maxSpooledBodyBytes) / 1_048_576.0 },
                    set: { appState.config.maxSpooledBodyBytes = max(1_048_576, Int($0 * 1_048_576.0)) }
                ), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Max spooled request body megabytes")
                    .help("Bodies above the buffered limit spill to a bounded temp file up to this size; larger requests are rejected with 413.")
            }
            settingsRow("Pending Auth (global)") {
                TextField("", value: $appState.config.pendingAuthHandshakeGlobalLimit, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Pending auth handshakes global limit")
                    .help("Maximum upstream 407 handshakes in flight at once — the auth-storm bound. New handshakes beyond it are rejected with a structured event.")
            }
            settingsRow("Pending Auth (per source)") {
                TextField("", value: $appState.config.pendingAuthHandshakesPerSource, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Pending auth handshakes per source limit")
                    .help("Per-client-IP slice of the pending-handshake bound, so one misbehaving client cannot starve the rest.")
            }

            Divider().opacity(0.3)
            sectionHeader("Failover & Circuit Breaker")

            settingsRow("Upstream Response (s)") {
                TextField("", value: $appState.config.upstreamResponseTimeoutSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Upstream response timeout seconds")
                    .help("How long to wait for an upstream proxy's response before counting the attempt as failed.")
            }
            settingsRow("Failure Window (s)") {
                TextField("", value: $appState.config.circuitBreakerWindowSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Circuit breaker window seconds")
                    .help("Sliding window over which upstream failures are counted toward tripping the circuit breaker.")
            }
            settingsRow("Failure Threshold") {
                TextField("", value: $appState.config.circuitFailureThreshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Circuit breaker failure threshold")
                    .help("Failures within the window before the upstream's circuit opens and traffic fails over.")
            }

            Divider().opacity(0.3)
            sectionHeader("Direct Connect")

            settingsRow("Connect Timeout (ms)") {
                TextField("", value: $appState.config.connectionCheckTimeoutMS, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Direct connect timeout milliseconds")
            }
            settingsRow("Cache TTL (min)") {
                TextField("", value: $appState.config.directConnectTTLMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Direct connect cache TTL minutes")
            }

            Divider().opacity(0.3)
            sectionHeader("Security & Logging")

            Toggle("Strict mode", isOn: $appState.config.strictMode)
                .help("Never route proxied traffic DIRECT as a fallback when upstreams fail (PAC DIRECT fallback and protocol-upgrade direct relay are refused unless the network state itself is unconditionally direct). Will also gate inbound gateway auth once that feature is implemented.")
            Toggle("Verbose logging", isOn: $appState.config.verboseLogging)
                .help("When enabled, debug and info messages are included in stderr and the in-app log buffer.")
            Toggle("File logging", isOn: Binding(
                get: { appState.logStore.logFileURL != nil },
                set: { enabled in
                    if enabled {
                        let dir = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Logs/Conduit")
                        appState.logStore.logFileURL = dir.appendingPathComponent("proxy.log")
                    } else {
                        appState.logStore.logFileURL = nil
                    }
                }
            ))
            .help("Write all log entries to ~/Library/Logs/Conduit/proxy.log")
            if let url = appState.logStore.logFileURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Divider().opacity(0.3)
            sectionHeader("Configuration")

            HStack(spacing: 8) {
                Button("Import Config") { importConfiguration() }
                    .buttonStyle(.bordered)
                Button("Export Config") { exportConfiguration() }
                    .buttonStyle(.bordered)
            }

            Divider().opacity(0.3)
            sectionHeader("Privileged Helper")

            settingsRow("Status") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(helperStatusColor)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(helperStatusLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Privileged helper status: \(helperStatusLabel)")
            }

            Text("Install the helper once to manage system proxy and split DNS without repeated admin prompts. Reinstall after helper protocol changes or when the status is outdated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(helperPrimaryActionTitle) {
                    appState.installHelper()
                }
                .buttonStyle(.borderedProminent)
                .help("Install or update the privileged helper.")

                if appState.helperStatus != .notInstalled {
                    Button("Uninstall Helper") {
                        appState.uninstallHelper()
                    }
                    .buttonStyle(.bordered)
                    .help("Remove the privileged helper and fall back to macOS admin prompts.")
                }
            }
        }
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .trailing)
            content()
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Bindings

    private var adaptiveLocalPACBinding: Binding<Bool> {
        Binding(
            get: {
                appState.platformConfig.systemProxyMode == .pac && appState.config.localPACEnabled
            },
            set: { enabled in
                appState.platformConfig.systemProxyMode = enabled ? .pac : .manual
                appState.config.localPACEnabled = enabled
            }
        )
    }

    private var orderedUpstreamIDs: [UUID] {
        UpstreamOrdering.orderedIDs(for: appState.config.upstreams)
    }

    private func moveUpstream(_ draggedID: UUID, before targetID: UUID?) {
        appState.config.upstreams = UpstreamOrdering.moving(appState.config.upstreams, id: draggedID, before: targetID)
    }

    private func removeLastUpstream() {
        guard let id = orderedUpstreamIDs.last,
              let index = appState.config.upstreams.firstIndex(where: { $0.id == id })
        else { return }
        appState.config.upstreams.remove(at: index)
        normalizeUpstreamPriorities()
    }

    private func normalizeUpstreamPriorities() {
        appState.config.upstreams = UpstreamOrdering.normalized(appState.config.upstreams)
    }

    private func upstreamBinding(id: UUID) -> Binding<UpstreamProxy>? {
        guard let index = appState.config.upstreams.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $appState.config.upstreams[index]
    }

    private func dnsEntryBinding(id: UUID) -> Binding<DomainDNSEntry>? {
        guard let index = appState.config.dnsEntries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return $appState.config.dnsEntries[index]
    }

    private func dnsBinding(for entry: Binding<DomainDNSEntry>) -> Binding<String> {
        Binding(
            get: { entry.wrappedValue.servers.joined(separator: ", ") },
            set: { value in
                entry.wrappedValue.servers = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var helperHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text("Install the privileged helper (Advanced tab) to avoid admin prompts for DNS and tunnel operations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var helperStatusLabel: String {
        switch appState.helperStatus {
        case .installed:
            return "Installed and running"
        case .outdated:
            return "Outdated, reinstall required"
        case .notInstalled:
            return "Not installed"
        case .notResponding:
            return "Installed but not responding"
        }
    }

    private var helperStatusColor: Color {
        switch appState.helperStatus {
        case .installed:
            return Color(nsColor: .systemGreen)
        case .outdated:
            return Color(nsColor: .systemOrange)
        case .notInstalled:
            return Color(nsColor: .systemGray)
        case .notResponding:
            return Color(nsColor: .systemRed)
        }
    }

    private var helperPrimaryActionTitle: String {
        switch appState.helperStatus {
        case .installed:
            return "Reinstall Helper"
        case .outdated:
            return "Update Helper"
        case .notInstalled:
            return "Install Helper"
        case .notResponding:
            return "Repair Helper"
        }
    }

    private func accessibilityUpstreamLabel(for upstream: UpstreamProxy) -> String {
        let name = upstream.name.isEmpty ? upstream.host : upstream.name
        return upstream.enabled ? "Disable upstream \(name)" : "Enable upstream \(name)"
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

private struct HostListEditor: View {
    @Binding var entries: [String]
    let placeholder: String
    let accessibilityName: String
    @FocusState private var focusedRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(placeholder, text: entryBinding(at: index))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focusedRow, equals: index)
                        .onSubmit { cleanupEntries() }
                        .accessibilityLabel("\(accessibilityName) entry \(index + 1)")

                    Button(role: .destructive) {
                        removeEntry(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(accessibilityName) entry \(index + 1)")
                    .help("Remove entry")
                }
            }

            HStack(spacing: 8) {
                Button {
                    appendEntry()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(accessibilityName) entry")

                Text("Paste comma or newline separated values into any row.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
        }
        .onChange(of: focusedRow) { _, newValue in
            cleanupEntries(keeping: newValue)
        }
        .onDisappear {
            cleanupEntries()
        }
    }

    private func entryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard entries.indices.contains(index) else { return "" }
                return entries[index]
            },
            set: { value in
                setEntry(at: index, to: value)
            }
        )
    }

    private func setEntry(at index: Int, to value: String) {
        guard entries.indices.contains(index) else { return }

        let parsedEntries = parsedListEntries(from: value)
        if parsedEntries.count > 1 || value.contains(",") || value.contains("\n") || value.contains("\r") {
            if parsedEntries.isEmpty {
                entries[index] = ""
            } else {
                entries.replaceSubrange(index...index, with: parsedEntries)
                focusedRow = index + parsedEntries.count - 1
            }
            cleanupEntries(keeping: focusedRow)
            return
        }

        entries[index] = normalizedEntry(value)
    }

    private func appendEntry() {
        cleanupEntries()
        entries.append("")
        focusedRow = entries.count - 1
    }

    private func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        cleanupEntries()
        focusedRow = nil
    }

    private func cleanupEntries(keeping focusedIndex: Int? = nil) {
        var cleanedEntries: [String] = []
        var cleanedFocus: Int?

        for (index, entry) in entries.enumerated() {
            let normalized = normalizedEntry(entry)
            if normalized.isEmpty {
                if index == focusedIndex {
                    cleanedFocus = cleanedEntries.count
                    cleanedEntries.append("")
                }
            } else {
                if index == focusedIndex {
                    cleanedFocus = cleanedEntries.count
                }
                cleanedEntries.append(normalized)
            }
        }

        entries = cleanedEntries
        if focusedRow != cleanedFocus {
            focusedRow = cleanedFocus
        }
    }

    private func parsedListEntries(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map(normalizedEntry)
            .filter { !$0.isEmpty }
    }

    private func normalizedEntry(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct UpstreamDropDelegate: DropDelegate {
    let targetID: UUID?
    @Binding var draggedID: UUID?
    let move: (UUID, UUID?) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
