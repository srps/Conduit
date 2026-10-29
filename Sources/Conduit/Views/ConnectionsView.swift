// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ProxyKernel

/// The Connections section: every active request, most recent first, capped at a display limit. The count is the snapshot's exact one;
/// the rows are read page by page while this section is shown.
struct ConnectionsView: View {
    @EnvironmentObject private var runtime: RuntimePresentationAdapter

    private static let rowLimit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(runtime.activeConnectionCount) active")
                    .font(.headline)
                    .monospacedDigit()
                let tunnels = runtime.activeConnections.filter(\.tunnel).count
                if tunnels > 0 {
                    Text("· \(tunnels) tunnel\(tunnels == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let note = rowsNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            if runtime.activeConnections.isEmpty {
                if rowsNote == nil {
                    Text("No active requests right now.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(runtime.activeConnections.prefix(Self.rowLimit)) { connection in
                            HStack(spacing: 8) {
                                Text(connection.tunnel ? "TLS" : connection.method)
                                    .font(.caption.weight(.semibold).monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .leading)
                                Text(connection.destination)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(connection.upstream)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "\(connection.tunnel ? "TLS" : connection.method) request to \(connection.destination) via \(connection.upstream)"
                            )
                        }
                    }
                }
            }
        }
        .onAppear { runtime.showing(.activeConnections, true) }
        .onDisappear { runtime.showing(.activeConnections, false) }
    }

    /// Why the rows below are not the current list, when they are not. A list the runtime cannot capture whole is unavailable, and its
    /// connections are still served.
    private var rowsNote: String? {
        switch runtime.rows(.activeConnections) {
        case .current: nil
        case .notRead: runtime.activeConnectionCount > 0 ? "Reading the list…" : nil
        case .stale: "Updating the list…"
        case .unavailable: "The list is too large to show; all \(runtime.activeConnectionCount) connections are still being served."
        }
    }
}
