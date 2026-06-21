// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

struct LogView: View {
    @ObservedObject var logStore: AppLogStore

    @State private var searchText = ""
    @State private var selectedCategories: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var minimumLevel: LogLevel = .debug
    @State private var copiedFeedback = false

    // Cached filter result. Filtering 2000 ring-buffer entries 3× per body
    // refresh (header counter + Copy Filtered button + List) was the dominant
    // cost when LogView was open during burst log activity. We recompute only
    // when an input changes:
    //   - filter inputs: searchText, selectedCategories, minimumLevel
    //   - source: logStore.entries.count (a proxy for "new entry appended")
    //
    // Caveat: if the ring buffer rolls over (entries.count stays at maxEntries
    // but contents change), the cache stays one render stale until the next
    // input change. Acceptable for a logs UI: the visible diff is at most one
    // entry per render after rollover, and the next user filter interaction
    // recomputes. Tracked by `LogViewFilterCacheTests`.
    @State private var filteredEntries: [LogEntry] = []

    private func recomputeFilter() {
        filteredEntries = LogView.filter(
            entries: logStore.entries,
            categories: selectedCategories,
            minimumLevel: minimumLevel,
            search: searchText
        )
    }

    /// Pure filter helper. Extracted from `recomputeFilter` so the filter
    /// rules (level / category / case-insensitive substring) are testable
    /// without standing up a SwiftUI view tree. Reverses the input so the
    /// most-recent entries appear at the top of the list (matches the
    /// existing display contract).
    static func filter(
        entries: [LogEntry],
        categories: Set<LogCategory>,
        minimumLevel: LogLevel,
        search: String
    ) -> [LogEntry] {
        let query = search.isEmpty ? nil : search.lowercased()
        return entries.reversed().filter { entry in
            guard categories.contains(entry.category) else { return false }
            guard entry.level >= minimumLevel else { return false }
            if let query {
                return entry.message.lowercased().contains(query)
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            logList
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear { recomputeFilter() }
        .onChange(of: searchText) { _, _ in recomputeFilter() }
        .onChange(of: selectedCategories) { _, _ in recomputeFilter() }
        .onChange(of: minimumLevel) { _, _ in recomputeFilter() }
        .onChange(of: logStore.entries.count) { _, _ in recomputeFilter() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Logs")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(filteredEntries.count) / \(logStore.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter messages...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                categoryChips
                Spacer()
                levelPicker
            }

            HStack(spacing: 8) {
                copyButton(title: "Copy Filtered", entries: filteredEntries)
                copyButton(title: "Copy All", entries: logStore.entries.reversed())
                Button("Copy Diagnostic") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logStore.exportDiagnosticLog(), forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy the full diagnostic log buffer for sharing")
                Spacer()
                Button("Clear") {
                    logStore.clearEntries()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var categoryChips: some View {
        HStack(spacing: 4) {
            ForEach(LogCategory.allCases) { cat in
                let isSelected = selectedCategories.contains(cat)
                Button {
                    if isSelected {
                        selectedCategories.remove(cat)
                    } else {
                        selectedCategories.insert(cat)
                    }
                } label: {
                    Text(cat.label)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? chipColor(for: cat).opacity(0.2) : Color.clear, in: Capsule())
                        .foregroundStyle(isSelected ? chipColor(for: cat) : .secondary)
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? chipColor(for: cat).opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(cat.label) \(isSelected ? "enabled" : "disabled")")
            }
        }
    }

    private var levelPicker: some View {
        Picker("Min Level", selection: $minimumLevel) {
            ForEach(LogLevel.allCases) { level in
                Text(level.label).tag(level)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 120)
        .controlSize(.small)
    }

    // MARK: - Log List

    private var logList: some View {
        List(filteredEntries) { entry in
            logRow(entry)
        }
        .listStyle(.plain)
    }

    private func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(levelColor(for: entry.level))
                Text(entry.category.label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(chipColor(for: entry.category).opacity(0.12), in: Capsule())
                    .foregroundStyle(chipColor(for: entry.category))
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    copyToClipboard(entry.formatted())
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy this log line")
            }
            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.level.label) \(entry.category.label) at \(entry.timestamp.formatted(date: .omitted, time: .standard)): \(entry.message)")
    }

    // MARK: - Actions

    private func copyButton(title: String, entries: [LogEntry]) -> some View {
        Button {
            let text = entries.map { $0.formatted() }.joined(separator: "\n")
            copyToClipboard(text)
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(entries.isEmpty)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            copiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                copiedFeedback = false
            }
        }
    }

    // MARK: - Colors

    private func levelColor(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return Color(nsColor: .systemBlue)
        case .notice: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        }
    }

    private func chipColor(for category: LogCategory) -> Color {
        switch category {
        case .general: return .secondary
        case .proxy: return Color(nsColor: .systemBlue)
        case .pac: return Color(nsColor: .systemPurple)
        case .auth: return Color(nsColor: .systemOrange)
        case .network: return Color(nsColor: .systemTeal)
        case .system: return Color(nsColor: .systemGreen)
        case .tunnel: return Color(nsColor: .systemIndigo)
        }
    }
}

