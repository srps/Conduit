// SPDX-License-Identifier: Apache-2.0
// Kernel-side value types for PAC (Proxy Auto-Configuration) resolution.
//
// Kept separate so concrete PAC evaluators can live in `ProxyPAC` while
// the error and route enums stay Foundation-only and Kernel-visible.
// `PACRoutingEngine` in the Kernel consumes both types; consumers outside the
// Kernel (HTTPProxyHandler, SOCKS5Server, LocalProxyServer) branch on
// `PACRoute`.

import Foundation

package enum PACResolverError: Error, LocalizedError {
    case invalidURL
    case invalidPAC
    case evaluationFailed(String)
    /// The evaluator stopped waiting for the script (CFNetwork's own deadline).
    case evaluationTimedOut(String)
    case fetchFailed(String)

    package var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The PAC URL is invalid."
        case .invalidPAC:
            return "The PAC file could not be evaluated."
        case .evaluationFailed(let message):
            return "The PAC file evaluation failed: \(message)"
        case .evaluationTimedOut(let message):
            return "The PAC file evaluation timed out: \(message)"
        case .fetchFailed(let message):
            return "The PAC file could not be fetched: \(message)"
        }
    }
}

package enum PACRoute: Equatable, Sendable {
    case direct
    case proxy(host: String, port: Int)
    /// A `SOCKS` directive. The kernel has no SOCKS upstream dialer, so
    /// `PACChain.classify` reports it as an unsupported entry; it never
    /// reaches a routing decision (#49, #50).
    case socks(host: String, port: Int)
}

/// A PAC directive the adapter could not use. Rejected entries are removed
/// from the chain without reordering the rest, and reported, never dropped
/// silently (#49).
package struct PACRejectedEntry: Equatable, Sendable {
    package enum Reason: String, Sendable {
        /// A directive type the kernel cannot route through (`SOCKS`,
        /// `HTTPS`, `SOCKS5`, an unknown CFNetwork proxy type, ...).
        case unsupported
        /// A supported type with a missing host or a port outside 1–65535.
        case invalid
    }

    /// The directive keyword, upper-cased: `A-Z0-9_`, at most 16 characters,
    /// or `OTHER` for anything else. Safe for events: never a host or URL.
    package let type: String
    package let reason: Reason

    package init(type: String, reason: Reason) {
        self.type = type
        self.reason = reason
    }
}

/// The entries a chain rejected: the first `retainedLimit` in script order,
/// plus counts over all of them. A PAC answer is untrusted input and a chain
/// is cached per URL, so what is kept is bounded however long the answer
/// was; the counts keep classification and the event correct.
package struct PACRejections: Equatable, Sendable, RandomAccessCollection, ExpressibleByArrayLiteral {
    /// Entries kept per chain. Matches the event's cap on rejected types.
    package static let retainedLimit = 8

    /// The first `retainedLimit` rejected entries, in script order.
    package private(set) var entries: [PACRejectedEntry] = []
    /// Every rejected entry, including those not retained.
    package private(set) var total = 0
    /// Rejected entries of an unsupported type, including those not retained.
    package private(set) var unsupported = 0

    package init() {}

    package init(arrayLiteral elements: PACRejectedEntry...) {
        for element in elements { append(element) }
    }

    package mutating func append(_ entry: PACRejectedEntry) {
        total += 1
        if entry.reason == .unsupported { unsupported += 1 }
        if entries.count < Self.retainedLimit { entries.append(entry) }
    }

    /// Some rejected entries were counted but not retained.
    package var truncated: Bool { total > entries.count }

    package var startIndex: Int { entries.startIndex }
    package var endIndex: Int { entries.endIndex }
    package subscript(position: Int) -> PACRejectedEntry { entries[position] }
}

/// One evaluation's answer as the script wrote it, minus what could not be used.
package struct PACChain: Equatable, Sendable {
    /// Usable routes in script order: only `.direct` and `.proxy`.
    package var routes: [PACRoute]
    /// Entries removed from the chain, in script order (bounded; see `PACRejections`).
    package var rejected: PACRejections
    /// The first usable route is `DIRECT` only because rejected entries were
    /// removed ahead of it. Such a `DIRECT` is a fallback, not the script's
    /// explicit choice: it is used only where direct fallback is allowed.
    package var leadingDirectPromoted: Bool

    package init(routes: [PACRoute], rejected: PACRejections = [], leadingDirectPromoted: Bool = false) {
        self.routes = routes
        self.rejected = rejected
        self.leadingDirectPromoted = leadingDirectPromoted
    }

    /// Directive keywords the adapter produces. A known keyword that fails to
    /// parse is `invalid`; any other keyword is `unsupported`.
    private static let knownKeywords: Set<String> = ["DIRECT", "PROXY", "SOCKS"]
    private static let maxTypeLength = 16

    /// Split raw directives into usable routes and rejected entries.
    /// `parse` is the adapter's strict single-entry parser.
    package static func classify(_ entries: [String], parse: (String) -> PACRoute?) -> PACChain {
        var chain = PACChain(routes: [])
        for entry in entries {
            switch parse(entry) {
            case .direct:
                if chain.routes.isEmpty, !chain.rejected.isEmpty {
                    chain.leadingDirectPromoted = true
                }
                chain.routes.append(.direct)
            case .proxy(let host, let port):
                chain.routes.append(.proxy(host: host, port: port))
            case .socks:
                chain.rejected.append(PACRejectedEntry(type: "SOCKS", reason: .unsupported))
            case nil:
                let keyword = entryType(entry)
                chain.rejected.append(PACRejectedEntry(
                    type: keyword,
                    reason: knownKeywords.contains(keyword) ? .invalid : .unsupported
                ))
            }
        }
        return chain
    }

    private static func entryType(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return "EMPTY" }
        let keyword = first.uppercased()
        // Anything that does not look like a keyword (a URL, a host, a long
        // token) is reported as OTHER, so no part of it reaches an event.
        let isKeyword = keyword.count <= maxTypeLength && keyword.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
        return isKeyword ? keyword : "OTHER"
    }
}

/// Why a PAC evaluation gave no usable answer. The raw values are the
/// `reason=` of the `pac.no_usable_route` event.
package enum PACNoUsableReason: String, Sendable, CaseIterable {
    /// The script (or CFNetwork, after dropping directives it does not
    /// support) returned no entries.
    case empty
    /// Every entry was rejected, at least one for an unsupported type.
    case unsupported
    /// Every entry was rejected, all for a bad host or port.
    case invalid
    case evaluationFailed = "evaluation_failed"
    case timeout
    /// PAC routing is on but no script has loaded yet.
    case notLoaded = "not_loaded"
    /// The evaluation queue was full (`pac.evaluation_refused`).
    case refused
    /// The answer came from a PAC the configuration no longer names.
    case superseded

    /// The reason for a chain left without usable routes. Uses the counts, so
    /// an unsupported entry past the retained ones still counts.
    package static func forRejected(_ rejected: PACRejections) -> PACNoUsableReason {
        if rejected.total == 0 { return .empty }
        return rejected.unsupported > 0 ? .unsupported : .invalid
    }
}

/// The routing engine's answer for one request.
package enum PACDecision: Equatable, Sendable {
    /// PAC routing is off in the configuration; PAC has no say.
    case notConsulted
    /// A chain with at least one usable route.
    case routes(PACChain)
    /// PAC routing is on but produced nothing to route by. Routing proceeds
    /// through the configured upstreams only: no DIRECT, no reachability
    /// shortcut and no PAC direct fallback (#50).
    case noUsableAnswer(PACNoUsableReason, rejected: PACRejections)

    /// The decision a parsed chain stands for.
    package init(chain: PACChain) {
        if chain.routes.isEmpty {
            self = .noUsableAnswer(PACNoUsableReason.forRejected(chain.rejected), rejected: chain.rejected)
        } else {
            self = .routes(chain)
        }
    }

    /// Usable routes, or none.
    package var routes: [PACRoute] {
        if case .routes(let chain) = self { return chain.routes }
        return []
    }
}
