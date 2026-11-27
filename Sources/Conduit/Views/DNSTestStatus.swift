// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// What the last Test DNS found, beside its button. The time says which press a reading belongs to.
struct DNSTestStatus: View {
    let test: DNSTest

    var body: some View {
        switch test {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Testing…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .finished(let result, let at):
            HStack(spacing: 4) {
                Image(systemName: symbol(for: result))
                    .foregroundStyle(color(for: result))
                Text(result.message)
                Text(at, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private func symbol(for result: DNSTestResult) -> String {
        switch result {
        case .answered: "checkmark.circle.fill"
        case .noAnswer: "xmark.circle.fill"
        case .noPort, .noResult: "exclamationmark.circle.fill"
        }
    }

    private func color(for result: DNSTestResult) -> Color {
        switch result {
        case .answered: Color(nsColor: .systemGreen)
        case .noAnswer: Color(nsColor: .systemRed)
        case .noPort, .noResult: Color(nsColor: .systemOrange)
        }
    }
}
