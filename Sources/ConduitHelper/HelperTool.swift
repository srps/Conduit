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
            guard arguments.values.count >= 1 else {
                throw HelperToolError.invalidInput("setProxyBypass requires service name")
            }
            let service = arguments.values[0]
            try validateService(service)
            let domains = Array(arguments.values.dropFirst())
            _ = try run("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + domains)

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
