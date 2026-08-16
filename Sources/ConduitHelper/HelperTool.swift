// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared

enum HelperToolError: Error, LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        }
    }
}

enum HelperTool {
    static func run(arguments: HelperArguments) throws {
        switch arguments.command {
        case .ping, .startDNSRelay, .stopDNSRelay, .startTCPRelay, .stopTCPRelay:
            return

        case .applyDNS:
            guard arguments.values.count >= 2 else {
                throw HelperToolError.invalidInput("applyDNS requires domain and servers")
            }
            let domain = arguments.values[0]
            let servers = arguments.values[1].split(separator: ",").map { String($0) }
            guard HelperInputValidator.validateDomain(domain) else {
                throw HelperToolError.invalidInput("invalid domain: \(domain)")
            }
            for server in servers {
                guard HelperInputValidator.validateIPAddress(server) else {
                    throw HelperToolError.invalidInput("invalid DNS server: \(server)")
                }
            }
            var content = servers.map { "nameserver \($0)" }.joined(separator: "\n")
            if arguments.values.count >= 3, let port = Int(arguments.values[2]), port >= 1, port <= 65535 {
                content += "\nport \(port)"
            }
            try FileManager.default.createDirectory(atPath: "/etc/resolver", withIntermediateDirectories: true, attributes: nil)
            try content.write(toFile: "/etc/resolver/\(domain)", atomically: true, encoding: .utf8)

        case .removeDNS:
            guard let domain = arguments.values.first else { return }
            guard HelperInputValidator.validateDomain(domain) else {
                throw HelperToolError.invalidInput("invalid domain: \(domain)")
            }
            try? FileManager.default.removeItem(atPath: "/etc/resolver/\(domain)")

        case .applySystemProxy:
            guard arguments.values.count >= 3 else {
                throw HelperToolError.invalidInput("applySystemProxy requires service, host, port")
            }
            let service = arguments.values[0]
            let host = arguments.values[1]
            let port = arguments.values[2]
            try validateServiceHostPort(service: service, host: host, port: port)
            _ = try run("/usr/sbin/networksetup", ["-setwebproxy", service, host, port])
            _ = try run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, port])
            _ = try run("/usr/sbin/networksetup", ["-setwebproxystate", service, "on"])
            _ = try run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "on"])

        case .clearSystemProxy:
            guard let service = arguments.values.first else { return }
            try validateService(service)
            _ = try run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
            _ = try run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            _ = try run("/usr/sbin/networksetup", ["-setautoproxystate", service, "off"])

        case .setProxyBypass:
            guard arguments.values.count >= 2 else {
                // Zero domains used to be accepted and forwarded as a bare
                // `-setproxybypassdomains <service>`, whose behaviour is
                // undocumented. Clearing the list has a spelling —  `Empty` —
                // and requiring it makes "clear" indistinguishable from a
                // caller that lost its arguments.
                throw HelperToolError.invalidInput(
                    "setProxyBypass requires a service and at least one domain or '\(HelperInputValidator.emptyListSentinel)'"
                )
            }
            let service = arguments.values[0]
            try validateService(service)
            let domains = Array(arguments.values.dropFirst())
            if domains.contains(where: HelperInputValidator.isEmptyListSentinel) {
                guard domains.count == 1 else {
                    throw HelperToolError.invalidInput(
                        "'\(HelperInputValidator.emptyListSentinel)' must be the only value when clearing bypass domains"
                    )
                }
            } else {
                // The one helper argument that used to reach `networksetup`
                // unvalidated. Bypass entries are not domains — `*.local` and
                // `169.254/16` are both real — so they need their own rule
                // rather than an exemption from the trust boundary.
                for domain in domains {
                    guard HelperInputValidator.validateProxyBypassEntry(domain) else {
                        throw HelperToolError.invalidInput("invalid bypass domain: \(domain)")
                    }
                }
            }
            _ = try run("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + domains)

        case .setWebProxyEndpoint:
            guard arguments.values.count >= 5 else {
                throw HelperToolError.invalidInput("setWebProxyEndpoint requires service, kind, host, port, state")
            }
            let service = arguments.values[0]
            let kind = arguments.values[1]
            let host = arguments.values[2]
            let port = arguments.values[3]
            let state = arguments.values[4]
            try validateService(service)
            guard HelperInputValidator.validateWebProxyKind(kind) else {
                throw HelperToolError.invalidInput("invalid web proxy kind: \(kind)")
            }
            guard HelperInputValidator.validateOptionalEndpoint(host: host, port: port) else {
                throw HelperToolError.invalidInput("invalid web proxy endpoint: \(host):\(port)")
            }
            guard HelperInputValidator.validateProxyState(state) else {
                throw HelperToolError.invalidInput("invalid proxy state: \(state)")
            }
            let setter = kind == "web" ? "-setwebproxy" : "-setsecurewebproxy"
            let stateSetter = kind == "web" ? "-setwebproxystate" : "-setsecurewebproxystate"
            if HelperInputValidator.isEmptyListSentinel(host) {
                // An empty host with port 0 is how `networksetup` blanks an
                // address. Needed because a service that had no manual proxy
                // before us must not be left holding ours in its disabled
                // `Server` field, where re-enabling by hand would hand the user
                // a dead local address.
                _ = try run("/usr/sbin/networksetup", [setter, service, "", "0"])
            } else if !host.isEmpty {
                _ = try run("/usr/sbin/networksetup", [setter, service, host, port])
            }
            // State last: see `HelperCommand.setWebProxyEndpoint`. `-setwebproxy`
            // switches the proxy on as a side effect just as `-setautoproxyurl`
            // does — including when clearing — so writing the state first would
            // leave a restored-but-disabled endpoint switched on.
            _ = try run("/usr/sbin/networksetup", [stateSetter, service, state])

        case .setAutoproxy:
            guard arguments.values.count >= 3 else {
                throw HelperToolError.invalidInput("setAutoproxy requires service, url, state")
            }
            let service = arguments.values[0]
            let url = arguments.values[1]
            let state = arguments.values[2]
            try validateService(service)
            if !url.isEmpty {
                try validateAutoproxyURL(url)
            }
            guard HelperInputValidator.validateProxyState(state) else {
                throw HelperToolError.invalidInput("invalid proxy state: \(state)")
            }
            if !url.isEmpty {
                _ = try run("/usr/sbin/networksetup", ["-setautoproxyurl", service, url])
            }
            // State last, and this one is not stylistic: `-setautoproxyurl`
            // leaves autoproxy reporting `Enabled: Yes` whatever it was before.
            _ = try run("/usr/sbin/networksetup", ["-setautoproxystate", service, state])

        case .setAutoproxyURL:
            guard arguments.values.count >= 2 else {
                throw HelperToolError.invalidInput("setAutoproxyURL requires service and URL")
            }
            let service = arguments.values[0]
            let url = arguments.values[1]
            try validateService(service)
            try validateAutoproxyURL(url)
            _ = try run("/usr/sbin/networksetup", ["-setautoproxyurl", service, url])
            _ = try run("/usr/sbin/networksetup", ["-setautoproxystate", service, "on"])

        case .disableAutoproxy:
            guard let service = arguments.values.first else { return }
            try validateService(service)
            _ = try run("/usr/sbin/networksetup", ["-setautoproxystate", service, "off"])

        case .setDNSServers:
            guard arguments.values.count >= 2 else {
                throw HelperToolError.invalidInput("setDNSServers requires service and at least one server or 'empty'")
            }
            let service = arguments.values[0]
            try validateService(service)
            let servers = Array(arguments.values.dropFirst())
            let hasEmpty = servers.contains { $0.lowercased() == "empty" }
            if hasEmpty {
                guard servers.count == 1 else {
                    throw HelperToolError.invalidInput("'empty' must be the only value when clearing DNS servers")
                }
            } else {
                for server in servers {
                    guard HelperInputValidator.validateIPAddress(server) else {
                        throw HelperToolError.invalidInput("invalid DNS server: \(server)")
                    }
                }
            }
            _ = try run("/usr/sbin/networksetup", ["-setdnsservers", service] + servers)
        }
    }

    private static func validateService(_ service: String) throws {
        guard HelperInputValidator.validateServiceName(service) else {
            throw HelperToolError.invalidInput("invalid service name: \(service)")
        }
    }

    private static func validateAutoproxyURL(_ url: String) throws {
        guard HelperInputValidator.validateAutoproxyURL(url) else {
            throw HelperToolError.invalidInput("autoproxy URL must be a valid http:// or https:// URL")
        }
    }

    private static func validateServiceHostPort(service: String, host: String, port: String) throws {
        try validateService(service)
        guard HelperInputValidator.validateIPAddress(host) || HelperInputValidator.validateDomain(host) else {
            throw HelperToolError.invalidInput("invalid host: \(host)")
        }
        guard HelperInputValidator.validatePort(port) else {
            throw HelperToolError.invalidInput("invalid port: \(port)")
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
