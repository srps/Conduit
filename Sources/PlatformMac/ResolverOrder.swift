// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolver #1 of the system's unscoped DNS configuration.
package struct FirstResolver: Equatable, Sendable {
    package var nameserver: String?
    package var port: Int?

    package init(nameserver: String?, port: Int?) {
        self.nameserver = nameserver
        self.port = port
    }
}

package protocol ResolverOrderReading: Sendable {
    /// Nil when the configuration could not be read.
    func firstResolver() -> FirstResolver?
}

/// Reads `scutil --dns`, which prints the order mDNSResponder uses.
package struct ScutilResolverOrder: ResolverOrderReading {
    package let run: @Sendable (String, [String]) throws -> CommandResult

    package init(run: @escaping @Sendable (String, [String]) throws -> CommandResult) {
        self.run = run
    }

    package func firstResolver() -> FirstResolver? {
        let result: CommandResult
        do {
            result = try run("/usr/sbin/scutil", ["--dns"])
        } catch {
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        return Self.parse(result.standardOutput)
    }

    package static func parse(_ output: String) -> FirstResolver? {
        var inFirst = false
        var nameserver: String?
        var port: Int?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                if inFirst { break }
                inFirst = line == "resolver #1"
                continue
            }
            if line.hasPrefix("DNS configuration"), inFirst { break }
            guard inFirst else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "nameserver[0]" { nameserver = parts[1] }
            if parts[0] == "port" { port = Int(parts[1]) }
        }
        return inFirst ? FirstResolver(nameserver: nameserver, port: port) : nil
    }

    /// The scutil text for a configuration whose resolver #1 is `first`; fakes answer with it.
    package static func render(first: FirstResolver) -> String {
        var lines = ["DNS configuration", "", "resolver #1"]
        if let nameserver = first.nameserver { lines.append("  nameserver[0] : \(nameserver)") }
        if let port = first.port { lines.append("  port     : \(port)") }
        lines += ["  flags    : Request A records", "  order    : 1", ""]
        return lines.joined(separator: "\n")
    }
}
