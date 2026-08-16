// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

/// Which of the two manual proxy endpoints `networksetup` keeps per service.
package enum WebProxyKind: String, CaseIterable, Sendable {
    case web
    case secure

    var endpointSetter: String {
        self == .web ? "-setwebproxy" : "-setsecurewebproxy"
    }

    var stateSetter: String {
        self == .web ? "-setwebproxystate" : "-setsecurewebproxystate"
    }
}

/// Everything about one network service's proxy configuration that Conduit
/// overwrites — and therefore everything a teardown has to be able to put back.
///
/// This is the single description both restore paths render from. Before it,
/// `SystemProxyManager` held two independent implementations of "put the user's
/// settings back": a shell script for the unprivileged path and a sequence of
/// privileged operations for the fallback. They were supposed to produce the
/// same end state and provably did not — the privileged one could not express a
/// disabled endpoint, an asymmetric web/secure pair, or a bypass list, so it
/// degraded to a blanket clear. Two implementations of one platform side effect
/// is the problem the prior-state journal was introduced to remove; this keeps
/// the ordering rules and the field semantics in one place so the renderers
/// cannot drift.
package struct ProxyServiceState: Equatable, Sendable {
    package var webHost: String = ""
    package var webPort: String = ""
    package var webEnabled: Bool = false
    package var secureHost: String = ""
    package var securePort: String = ""
    package var secureEnabled: Bool = false
    package var autoURL: String = ""
    package var autoEnabled: Bool = false
    package var bypassDomains: [String] = []

    package init() {}

    package init(
        webHost: String, webPort: String, webEnabled: Bool,
        secureHost: String, securePort: String, secureEnabled: Bool,
        autoURL: String, autoEnabled: Bool,
        bypassDomains: [String]
    ) {
        self.webHost = webHost
        self.webPort = Self.normalisedPort(webPort)
        self.webEnabled = webEnabled
        self.secureHost = secureHost
        self.securePort = Self.normalisedPort(securePort)
        self.secureEnabled = secureEnabled
        self.autoURL = autoURL
        self.autoEnabled = autoEnabled
        self.bypassDomains = bypassDomains
    }

    /// `-getwebproxy` reports `Port: 0` for a service that never had a manual
    /// proxy. Carried through literally, that becomes `-setwebproxy host 0` on
    /// restore — which the privileged path rejects outright (port 0 fails
    /// validation) and the unprivileged one writes as an endpoint nothing can
    /// connect to. Zero is the absence of a port, so it is stored as one.
    private static func normalisedPort(_ port: String) -> String {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed == "0" || trimmed == "00") ? "" : trimmed
    }

    // MARK: - Journal representation

    /// Keys documented on `PlatformSurface.systemProxy`.
    package init(journalValues prior: [String: String]) {
        self.init(
            webHost: prior["webHost"] ?? "",
            webPort: prior["webPort"] ?? "",
            webEnabled: prior["webEnabled"] == "true",
            secureHost: prior["secureHost"] ?? "",
            securePort: prior["securePort"] ?? "",
            secureEnabled: prior["secureEnabled"] == "true",
            autoURL: prior["autoURL"] ?? "",
            autoEnabled: prior["autoEnabled"] == "true",
            bypassDomains: (prior["bypassDomains"] ?? "")
                .split(separator: ",")
                .map(String.init)
        )
    }

    package var journalValues: [String: String] {
        [
            "webEnabled": String(webEnabled),
            "webHost": webHost,
            "webPort": webPort,
            "secureEnabled": String(secureEnabled),
            "secureHost": secureHost,
            "securePort": securePort,
            "autoEnabled": String(autoEnabled),
            "autoURL": autoURL,
            "bypassDomains": bypassDomains.joined(separator: ","),
        ]
    }

    // MARK: - Write plan

    /// The ordered writes that make a service hold this state.
    ///
    /// Order is part of the contract, not a detail of either renderer:
    ///
    /// - The autoproxy URL is written whether or not it was enabled, and the
    ///   state line follows it. `networksetup` keeps the URL on a switched-off
    ///   autoproxy, so leaving ours there hands the user a dead local PAC
    ///   server the moment they turn automatic configuration back on — and
    ///   `-setautoproxyurl` *enables* autoproxy as a side effect (verified on
    ///   macOS 26, documented nowhere), so writing the state first would leave
    ///   a configured-but-disabled URL switched on.
    /// - Manual endpoints follow the same shape for the same reason: a disabled
    ///   proxy retains its host and port, so ours has to be overwritten even
    ///   when the endpoint stays off.
    /// - Bypass domains are last because manual mode replaces the list
    ///   wholesale, and nothing else depends on them.
    package var writeSteps: [ProxyWriteStep] {
        [
            .autoproxy(url: autoURL, enabled: autoEnabled),
            .webProxy(kind: .web, endpoint: Self.endpoint(host: webHost, port: webPort), enabled: webEnabled),
            .webProxy(kind: .secure, endpoint: Self.endpoint(host: secureHost, port: securePort), enabled: secureEnabled),
            .bypass(bypassDomains),
        ]
    }

    /// A recorded prior with no address means the service genuinely had none,
    /// so restoring it means clearing ours rather than leaving it in place.
    private static func endpoint(host: String, port: String) -> ProxyEndpoint {
        guard !host.isEmpty, !port.isEmpty else { return .cleared }
        return .address(host: host, port: port)
    }

    /// The state a service is in once every proxy on it is switched off, used
    /// when there is no recorded prior to put back.
    ///
    /// Deliberately not "clear the endpoints too": an endpoint we never
    /// recorded is not ours to erase, and switching it off is enough to stop it
    /// routing.
    package static func disabledEverything() -> [ProxyWriteStep] {
        [
            .autoproxy(url: "", enabled: false),
            .webProxy(kind: .web, endpoint: .unchanged, enabled: false),
            .webProxy(kind: .secure, endpoint: .unchanged, enabled: false),
        ]
    }
}

/// What to do with a manual proxy's address, as distinct from its on/off state.
///
/// Three cases, not two, because "the service had no endpoint" and "do not
/// touch the endpoint" are different instructions that an empty host cannot
/// express both of. Collapsing them is what left Conduit's own address
/// sitting in a user's disabled `Server` field after teardown: the prior said
/// "no endpoint", the renderer read that as "write only the state", and our
/// `127.0.0.1:<port>` stayed behind to be handed back the moment the user
/// re-enabled the proxy by hand.
package enum ProxyEndpoint: Equatable, Sendable {
    /// Leave whatever address is there. Used by the blanket clear, where an
    /// endpoint we never recorded is not ours to erase — switching the proxy
    /// off is enough to stop it routing.
    case unchanged
    /// The service had no address before us, so ours must not be left behind.
    /// `networksetup` accepts an empty host with port `0` as the clear.
    case cleared
    case address(host: String, port: String)
}

/// One `networksetup` write, expressed once and rendered two ways.
package enum ProxyWriteStep: Equatable, Sendable {
    /// An empty `url` writes only the state.
    case autoproxy(url: String, enabled: Bool)
    case webProxy(kind: WebProxyKind, endpoint: ProxyEndpoint, enabled: Bool)
    case bypass([String])

    // MARK: - Renderer: unprivileged shell

    /// Rendered without `2>/dev/null || true`. The blanket-clear path used to
    /// carry those and it hid a permissions failure behind exit code 0 — the
    /// script reported success, the privileged fallback never fired, and the
    /// records were dropped as though the restore had landed.
    package func shellCommands(service: String) -> [String] {
        let s = service.shellQuoted
        switch self {
        case .autoproxy(let url, let enabled):
            var commands: [String] = []
            if !url.isEmpty {
                commands.append("/usr/sbin/networksetup -setautoproxyurl \(s) \(url.shellQuoted)")
            }
            commands.append("/usr/sbin/networksetup -setautoproxystate \(s) \(enabled ? "on" : "off")")
            return commands
        case .webProxy(let kind, let endpoint, let enabled):
            var commands: [String] = []
            switch endpoint {
            case .unchanged:
                break
            case .cleared:
                commands.append("/usr/sbin/networksetup \(kind.endpointSetter) \(s) '' 0")
            case .address(let host, let port):
                commands.append(
                    "/usr/sbin/networksetup \(kind.endpointSetter) \(s) \(host.shellQuoted) \(port.shellQuoted)"
                )
            }
            // State last, and for the manual endpoints this is not stylistic
            // either: `-setwebproxy` switches the proxy *on* as a side effect,
            // exactly like `-setautoproxyurl`. Verified on macOS 26 — writing
            // an address to a service whose web proxy is off leaves it
            // reporting `Enabled: Yes`, and so does clearing it with `'' 0`.
            // Documented in neither `man networksetup` nor the usage string.
            commands.append("/usr/sbin/networksetup \(kind.stateSetter) \(s) \(enabled ? "on" : "off")")
            return commands
        case .bypass(let domains):
            // "Empty" is networksetup's own spelling for clearing the list.
            let argument = domains.isEmpty
                ? HelperInputValidator.emptyListSentinel
                : domains.map(\.shellQuoted).joined(separator: " ")
            return ["/usr/sbin/networksetup -setproxybypassdomains \(s) \(argument)"]
        }
    }

    // MARK: - Renderer: privileged operations

    /// The same write as a typed privileged operation.
    ///
    /// Each step maps to exactly one operation, and each operation carries its
    /// own endpoint-then-state ordering — so a caller composing these cannot
    /// get the `-setautoproxyurl` side effect wrong, and the two renderers
    /// cannot disagree about what "restore" means.
    package func privilegedStep(service: String) -> PrivilegedBatchStep {
        switch self {
        case .autoproxy(let url, let enabled):
            return PrivilegedBatchStep(.setAutoproxy, [service, url, enabled ? "on" : "off"])
        case .webProxy(let kind, let endpoint, let enabled):
            // Host carries the instruction, on the same pattern
            // `setProxyBypass` and `setDNSServers` already use: empty leaves
            // the address alone, the `Empty` sentinel clears it.
            let host: String
            let port: String
            switch endpoint {
            case .unchanged: (host, port) = ("", "")
            case .cleared: (host, port) = (HelperInputValidator.emptyListSentinel, "")
            case .address(let addressHost, let addressPort): (host, port) = (addressHost, addressPort)
            }
            return PrivilegedBatchStep(
                .setWebProxyEndpoint,
                [service, kind.rawValue, host, port, enabled ? "on" : "off"]
            )
        case .bypass(let domains):
            return PrivilegedBatchStep(
                .setProxyBypass,
                [service] + (domains.isEmpty ? [HelperInputValidator.emptyListSentinel] : domains)
            )
        }
    }
}

extension Array where Element == ProxyWriteStep {
    package func shellScript(service: String) -> String {
        flatMap { $0.shellCommands(service: service) }
            .joined(separator: "\n") + "\n"
    }

    package func privilegedBatch(service: String) -> [PrivilegedBatchStep] {
        map { $0.privilegedStep(service: service) }
    }
}
