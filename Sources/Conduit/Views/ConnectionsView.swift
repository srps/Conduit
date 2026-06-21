// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import ProxyKernel

struct ConnectionsView: View {
    @EnvironmentObject private var runtime: RuntimePresentationAdapter
    let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        if compact {
            compactSummary
        } else {
            fullList
        }
    }

    // MARK: - Compact summary (no scroll)

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            let connections = runtime.activeConnections
            Text("Active Connections (\(connections.count))")
                .font(.headline)

            if connections.isEmpty {
                Text("No active requests right now.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("\(connections.filter(\.tunnel).count) tunnel\(connections.filter(\.tunnel).count == 1 ? "" : "s") active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Full scrollable list

    private var fullList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Connections")
                .font(.headline)

            if runtime.activeConnections.isEmpty {
                Text("No active requests right now.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(runtime.activeConnections.prefix(50)) { connection in
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
    }
}
