// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The sidebar of the single app window. Overview stands alone at the top;
/// Monitor holds the live views; Configure holds one section per subsystem,
/// each pairing that subsystem's live state with its knobs.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case connections
    case events
    case proxy
    case upstreams
    case authentication
    case dns
    case tunnels
    case shellEnvironment
    case general
    case advanced

    var id: String { rawValue }

    /// The first Configure section — what ⌘, lands on.
    static let firstConfigureSection: AppSection = .proxy

    static let monitorSections: [AppSection] = [.connections, .events]
    static let configureSections: [AppSection] = [
        .proxy, .upstreams, .authentication, .dns, .tunnels, .shellEnvironment, .general, .advanced,
    ]

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .connections: return "Connections"
        case .events: return "Events"
        case .proxy: return "Proxy"
        case .upstreams: return "Upstreams & Routing"
        case .authentication: return "Authentication"
        case .dns: return "DNS"
        case .tunnels: return "Tunnels"
        case .shellEnvironment: return "Shell Environment"
        case .general: return "General"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .connections: return "arrow.left.arrow.right"
        case .events: return "list.bullet.rectangle"
        case .proxy: return "network"
        case .upstreams: return "arrow.triangle.branch"
        case .authentication: return "key"
        case .dns: return "globe"
        case .tunnels: return "point.3.connected.trianglepath.dotted"
        case .shellEnvironment: return "terminal"
        case .general: return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var isConfigureSection: Bool {
        Self.configureSections.contains(self)
    }
}
