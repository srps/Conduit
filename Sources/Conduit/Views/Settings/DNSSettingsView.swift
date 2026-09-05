// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import PlatformMac
import ProxyKernel
import SwiftUI

/// Split DNS, the forwarder, DoH providers, and DNS intercept, with the
/// forwarder's live counters and Test DNS above them.
struct DNSSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    private var problems: ConfigFieldProblems { ConfigFieldProblems(config: appState.config) }

    var body: some View {
        ConfigureSection {
            VStack(alignment: .leading, spacing: 8) {
                LiveStatusStrip(
                    runState: runtime.dnsRunState,
                    title: "DNS forwarder",
                    chips: liveChips
                ) {
                    Button("Test DNS") { appState.testDNS() }
                        .controlSize(.small)
                        .disabled(runtime.dnsRunState != .running)
                }
                if appState.helperStatus != .installed {
                    HelperHintBanner()
                }
            }
        } content: {
            let problems = problems

            Section {
                Toggle(isOn: $appState.platformConfig.manageDNSResolvers) {
                    HStack(spacing: 4) {
                        Text("Manage /etc/resolver split DNS")
                        Text(HelperStatusPresentation.privilegeHint(for: appState.helperStatus))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(appState.config.dnsEntries) { entryValue in
                    if let entry = dnsEntryBinding(id: entryValue.id) {
                        dnsEntryEditor(entry, id: entryValue.id)
                    }
                }

                HStack(spacing: 8) {
                    Button("Add DNS Entry") {
                        appState.config.dnsEntries.append(DomainDNSEntry(domain: "", servers: []))
                    }
                    Button("Auto-detect from VPN") {
                        let detected = VPNDNSDetector.detect()
                        let existingDomains = Set(appState.config.dnsEntries.map(\.domain))
                        for config in detected {
                            for entry in config.toDNSEntries() where !existingDomains.contains(entry.domain) {
                                appState.config.dnsEntries.append(entry)
                            }
                        }
                    }
                    .help("Detect corporate DNS servers pushed by your VPN connection and add them as split-DNS entries.")
                    Spacer()
                }
            } header: {
                Text("Split DNS")
            }

            Section {
                Toggle(isOn: $appState.platformConfig.manageSystemDNS) {
                    HStack(spacing: 4) {
                        Text("Manage system DNS")
                        Text(HelperStatusPresentation.privilegeHint(for: appState.helperStatus))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Listen Port", value: $appState.config.dnsForwarderPort, format: .number.grouping(.never))
                    .frame(maxWidth: 220)
                    .configProblem(problems.message(for: "dns.forwarderPort"))
                    .accessibilityLabel("DNS forwarder port")
                if appState.platformConfig.manageSystemDNS {
                    SettingsNote("Port 53 relay runs in the privileged helper. The forwarder listens on the port above.")
                }
            } header: {
                Text("DNS Forwarder")
            } footer: {
                SettingsNote("The forwarder resolves external domains via DNS-over-HTTPS when internal DNS returns NXDOMAIN. Managing system DNS points macOS at the local forwarder (port 53) so all apps use DoH for external domains; the original settings are restored on stop or crash recovery.")
            }

            Section {
                LabeledContent("Providers") {
                    HostListEditor(
                        entries: $appState.config.dohProviders,
                        placeholder: "https://dns.example.com/dns-query",
                        accessibilityName: "DoH provider"
                    )
                    .help("Tried top to bottom; the first reachable provider answers the query.")
                }
                CopyableValueRow(label: "Test with", value: "dig @127.0.0.1 -p \(appState.config.dnsForwarderPort) www.google.com")
                CopyableValueRow(label: "Standalone CLI", value: "pm-dns --port \(appState.config.dnsForwarderPort) --verbose")
            } header: {
                Text("DoH Providers")
            } footer: {
                SettingsNote("DNS-over-HTTPS providers tried in order for external domains. Each must support the JSON API (?name=&type= with Accept: application/dns-json).")
            }

            Section {
                Toggle("Enable transparent proxy", isOn: $appState.config.transparentProxyEnabled)

                if appState.config.transparentProxyEnabled {
                    let ipProblem = Self.transparentProxyIPProblem(appState.config)
                    TextField("Intercept IP", text: $appState.config.transparentProxyIP)
                        .frame(maxWidth: 260)
                        .configProblem(ipProblem)
                        .accessibilityLabel("Transparent proxy intercept IP")
                    SettingsNote("Dedicated loopback IP for intercepted traffic. Default 127.44.3.0 avoids conflicts with dev servers on 127.0.0.1.")
                    TextField("Listen Port", value: $appState.config.transparentProxyPort, format: .number.grouping(.never))
                        .frame(maxWidth: 220)
                        .configProblem(problems.message(for: "dns.transparentProxyPort"))
                        .accessibilityLabel("Transparent proxy listen port")
                }

                // The rule list is shown whenever there are rules, not only while
                // the feature is on. `ProxyConfig.validate()` checks every rule
                // regardless of the toggle — it has to, the teardown path derives
                // its file set from all of them — so a rule that is refused while
                // the feature is off still puts "Configuration problem" in the
                // banner. Hiding the list then left that banner pointing at a
                // field the user could not see, let alone fix.
                if Self.interceptRulesAreShown(in: appState.config) {
                    interceptRules
                }
            } header: {
                Text("DNS Intercept + Transparent Proxy")
            } footer: {
                if Self.interceptRulesAreShown(in: appState.config) {
                    if appState.config.transparentProxyEnabled {
                        SettingsNote("Intercepts DNS queries for matched domains and routes their traffic through the corporate proxy transparently, for apps that bypass HTTP_PROXY (e.g. Cursor's http2.connect). Requires the DNS forwarder and system DNS management; the helper is required for the port 443 relay.")
                    } else {
                        SettingsNote("Transparent proxy is off. These rules are kept so their resolver files can be cleaned up, and are still checked on save.")
                    }
                } else {
                    SettingsNote("Intercept DNS queries for matched domains and route their traffic through the corporate proxy transparently. Solves apps like Cursor that bypass HTTP_PROXY (http2.connect).")
                }
            }

            ConflictList(conflicts: problems.conflicts(mentioning: ["dns.", "DNS forwarder port", "transparent proxy port"]))
        }
    }

    // MARK: - Live chips

    private var liveChips: [(label: String, value: String)] {
        guard runtime.dnsRunState == .running || runtime.dnsQueryCount > 0 else {
            return [("", runtime.dnsRunState.title)]
        }
        return [
            ("queries", MenuBarPresentation.compactCount(runtime.dnsQueryCount)),
            ("cache hits", MenuBarPresentation.compactCount(runtime.dnsCacheHitCount)),
            ("hit rate", cacheHitRateText),
            ("DoH fallbacks", MenuBarPresentation.compactCount(runtime.dnsDoHFallbackCount)),
        ]
    }

    private var cacheHitRateText: String {
        guard runtime.dnsQueryCount > 0 else { return "—" }
        let hitRate = (Double(runtime.dnsCacheHitCount) / Double(runtime.dnsQueryCount)) * 100
        return "\(Int(hitRate.rounded()))%"
    }

    // MARK: - Split DNS entries

    private func dnsEntryEditor(_ entry: Binding<DomainDNSEntry>, id: UUID) -> some View {
        let name = entry.wrappedValue.domain.isEmpty ? "DNS entry" : entry.wrappedValue.domain
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Enable \(name)", isOn: entry.enabled)
                    .accessibilityLabel("Enable \(name)")
                Spacer()
                Button(role: .destructive) {
                    appState.config.dnsEntries.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete DNS entry \(name)")
                .help("Delete this DNS entry")
            }
            LabeledContent("Domain") {
                TextField("Domain", text: entry.domain, prompt: Text("corp.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("DNS domain")
            }
            LabeledContent("DNS Servers") {
                TextField("DNS Servers", text: dnsBinding(for: entry), prompt: Text("Comma separated"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("DNS servers")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    // MARK: - Intercept rules

    private var interceptRules: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        interceptRuleRow($rule)
                    }
                }
            }
        }
    }

    /// One intercept rule, with its own validation state.
    ///
    /// A pattern that derives to an unusable domain is caught at the config
    /// boundary (#68), but a rejection the user only meets as "Configuration
    /// problem: …" in the banner does not tell them which of several rows to
    /// fix. The validators called here are the same ones the boundary uses.
    @ViewBuilder
    private func interceptRuleRow(_ rule: Binding<DNSInterceptRule>) -> some View {
        let patternProblem = Self.interceptPatternProblem(rule.wrappedValue)
        // IPv4 only, same as the config boundary, and for the same reason:
        // `DNSWireFormat.synthesizeDirectResponse` builds an A record and
        // nothing else, so an IPv6 target is answered SERVFAIL and the domain
        // resolves in neither family.
        let ipIsValid = IPAddressSyntax.isIPv4(rule.wrappedValue.interceptIP)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Toggle("", isOn: rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                TextField("Pattern", text: rule.pattern, prompt: Text("*.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 160)
                    .modifier(InvalidFieldHighlight(isInvalid: patternProblem != nil))
                    .accessibilityLabel("Intercept pattern")
                Text("→")
                    .foregroundStyle(.tertiary)
                TextField("IP", text: rule.interceptIP, prompt: Text("127.44.3.0"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 120)
                    .modifier(InvalidFieldHighlight(isInvalid: !ipIsValid))
                    .accessibilityLabel("Intercept IP address")
                Button {
                    let id = rule.wrappedValue.id
                    appState.config.dnsInterceptRules.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove intercept rule")
            }

            if let patternProblem {
                FieldProblem(message: patternProblem.localizedDescription)
            }
            if !ipIsValid {
                FieldProblem(
                    message: "'\(rule.wrappedValue.interceptIP)' is not a usable intercept target. "
                        + "Intercept answers are synthesized as A records, so this has to be an "
                        + "IPv4 literal such as 127.44.3.0."
                )
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

    // MARK: - Validators (shared with the config boundary)

    /// Whether the intercept-rule editor is rendered. It is the set of configs
    /// in which `ProxyConfig.validate()` can report a rule problem — every
    /// config with rules — plus the on-state, where the "Add" menu has to live
    /// even before the first rule exists.
    static func interceptRulesAreShown(in config: ProxyConfig) -> Bool {
        config.transparentProxyEnabled || !config.dnsInterceptRules.isEmpty
    }

    /// The field new rules are pre-seeded from. Same check as the boundary,
    /// and `nil` whenever the boundary is silent — which includes the feature
    /// being off, when the field is not rendered at all.
    static func transparentProxyIPProblem(_ config: ProxyConfig) -> String? {
        guard config.transparentProxyEnabled,
              !IPAddressSyntax.isIPv4(config.transparentProxyIP) else { return nil }
        return "'\(config.transparentProxyIP)' is not a usable intercept target. "
            + "New rules copy this address, and intercept answers are synthesized as "
            + "A records, so this has to be an IPv4 literal such as 127.44.3.0."
    }

    /// The pattern is validated through its **derived** resolver domain, the
    /// same string `ProxyConfig.validate()` checks and the same one that
    /// becomes `/etc/resolver/<domain>` — so the leading `*.` a user is
    /// supposed to type never reads as an error.
    ///
    /// An empty field reports nothing: a row the user has only just added is
    /// not yet a mistake, and flagging it while they are still typing the
    /// first character is noise. `ProxyConfig.validate()` skips an empty
    /// pattern for the same reason, so a clean row here is also a clean save.
    /// A non-empty pattern deriving to an empty domain (`*`) is flagged by
    /// both.
    static func interceptPatternProblem(_ rule: DNSInterceptRule) -> DomainNameError? {
        guard !rule.pattern.isEmpty else { return nil }
        do {
            try DomainNameSyntax.validate(rule.resolverDomain)
            return nil
        } catch {
            return error
        }
    }
}
