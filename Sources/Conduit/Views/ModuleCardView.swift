// SPDX-License-Identifier: Apache-2.0
import ProxyKernel
import SwiftUI

struct ModuleCardView: View {
    let title: String
    let icon: String
    let runState: ModuleRunState
    let address: String
    let primaryMetric: String
    let secondaryMetric: String
    var errorMessage: String? = nil
    var badge: (text: String, color: Color, help: String?)? = nil
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                if let badge {
                    let badgeView = Text(badge.text)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.12), in: Capsule())
                    if let help = badge.help {
                        badgeView.help(help)
                    } else {
                        badgeView
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                .accessibilityLabel(runState.title)
            }

            Text(address)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(runState == .running || runState == .warning ? .primary : .secondary)

            if runState == .failed, let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .textSelection(.enabled)
                    .frame(maxHeight: 60, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryMetric)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(secondaryMetric)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if runState == .warning, let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .lineLimit(2)
                    }
                }
                .frame(minHeight: 30, alignment: .top)
            }

            Button(action: action) {
                Text(buttonTitle)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(runState == .running || runState == .warning ? .red : .accentColor)
            .controlSize(.small)
            .disabled(runState == .starting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusColor: Color {
        switch runState {
        case .running: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .starting: Color(nsColor: .systemBlue)
        case .failed: Color(nsColor: .systemRed)
        case .stopped: Color(nsColor: .systemGray)
        }
    }

    private var buttonTitle: String {
        switch runState {
        case .running, .warning: "Stop"
        case .starting: "Starting..."
        case .failed, .stopped: "Start"
        }
    }
}
