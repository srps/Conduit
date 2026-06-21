// SPDX-License-Identifier: Apache-2.0
// Logging value types: kernel-clean (Foundation only). Extracted from
// `Sources/ProxyKernel/Support/Logging.swift` so the file no longer
// mixes value types with the Combine/SwiftUI/MainActor `AppLogStore` ring
// buffer (which moved to `Sources/Conduit/App/AppLogStore.swift`).
// The `LogSink` protocol that consumes these types
// lives in `Sources/ProxyKernel/Abstractions/LogSink.swift`.

import Foundation

package enum LogLevel: String, CaseIterable, Codable, Identifiable, Comparable {
    case debug
    case info
    case notice
    case warning
    case error

    package var id: String { rawValue }

    package var label: String {
        rawValue.uppercased()
    }

    private var sortOrder: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        }
    }

    package static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

package enum LogCategory: String, CaseIterable, Codable, Identifiable {
    case general
    case proxy
    case pac
    case auth
    case network
    case system
    case tunnel

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .general: return "General"
        case .proxy: return "Proxy"
        case .pac: return "PAC"
        case .auth: return "Auth"
        case .network: return "Network"
        case .system: return "System"
        case .tunnel: return "Tunnel"
        }
    }
}

package struct LogEntry: Identifiable, Hashable, Codable {
    package var id: UUID
    package var timestamp: Date
    package var level: LogLevel
    package var category: LogCategory
    package var message: String

    package init(id: UUID = UUID(), timestamp: Date = .now, level: LogLevel, category: LogCategory = .general, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }

    package func formatted() -> String {
        "[\(Self.formatter.string(from: timestamp))] [\(level.label)] [\(category.label)] \(message)"
    }

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
