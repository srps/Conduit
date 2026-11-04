// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct SystemDNSRecoveryNotice: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppState.systemDNSRecoveryDeclinedTitle)
                        .font(.callout.weight(.semibold))
                    Text(AppState.systemDNSRecoveryDeclinedBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Start DNS") { appState.startDNSAfterDeclinedRecovery() }
                    .help("Start the DNS forwarder and point the relay at it.")
                Button("Restore DNS Settings") { appState.restoreSystemDNSByStoppingDNS() }
                    .help("Put back the DNS servers recorded before Conduit changed them, and stop the relay.")
            }
            .controlSize(.small)
            .disabled(!appState.controlsEnabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
