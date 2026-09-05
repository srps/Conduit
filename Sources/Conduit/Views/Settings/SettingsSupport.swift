// SPDX-License-Identifier: Apache-2.0
import AppKit
import PlatformMac
import ProxyKernel
import SwiftUI

// Shared pieces of the Configure sections: the live status strip that sits
// above a subsystem's knobs, the inline validation treatment, the host list
// editor, the upstream drag-reorder delegate, and the privileged-helper
// wording. Each section is a plain grouped `Form`; these keep them thin.

// MARK: - Live status strip

/// A subsystem's live state, shown above its configuration so the person who
/// sees "corp-backup: open, 3 fails" is one scroll away from the knob.
struct LiveStatusStrip<Trailing: View>: View {
    let runState: ModuleRunState?
    let title: String
    let chips: [(label: String, value: String)]
    @ViewBuilder let trailing: () -> Trailing

    init(
        runState: ModuleRunState?,
        title: String,
        chips: [(label: String, value: String)],
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.runState = runState
        self.title = title
        self.chips = chips
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            if let runState {
                Circle()
                    .fill(color(for: runState))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 4) {
                    Text(chip.value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(chip.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func color(for state: ModuleRunState) -> Color {
        switch state {
        case .running: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .starting: Color(nsColor: .systemBlue)
        case .failed: Color(nsColor: .systemRed)
        case .stopped: Color(nsColor: .systemGray)
        }
    }
}

/// A Configure section's frame: optional live strip on top, grouped form
/// below. The form is what scrolls.
struct ConfigureSection<Strip: View, Content: View>: View {
    @ViewBuilder let strip: () -> Strip
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder strip: @escaping () -> Strip = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.strip = strip
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            strip()
                .padding(.horizontal, 20)
                .padding(.top, 14)
            Form {
                content()
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Inline validation

/// Invalid-state treatment for a text field: a thin warning-coloured border
/// drawn over the control's own.
///
/// Deliberately minimal. AppKit has no invalid-field style to adopt, so the
/// affordance stays a border plus a reason underneath rather than inventing
/// a widget. The colour matches the `.orange` the sections already use for
/// "this will not work" notes, and it is never the only signal: the reason
/// is always spelled out in text below, which is what a user with a
/// colour-vision difference (or a screen reader) actually reads.
struct InvalidFieldHighlight: ViewModifier {
    let isInvalid: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isInvalid {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 1.5)
            }
        }
    }
}

/// The reason a field is refused, under the field. Same validators as the
/// config boundary; the view introduces no grammar of its own.
struct FieldProblem: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Problem: \(message)")
    }
}

extension View {
    /// Highlight a field and put the boundary's reason under it.
    func configProblem(_ message: String?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            modifier(InvalidFieldHighlight(isInvalid: message != nil))
            if let message {
                FieldProblem(message: message)
            }
        }
    }
}

/// Cross-field conflicts a section owns, listed under its last group.
struct ConflictList: View {
    let conflicts: [String]

    var body: some View {
        if !conflicts.isEmpty {
            Section {
                ForEach(conflicts, id: \.self) { conflict in
                    FieldProblem(message: conflict)
                }
            } header: {
                Text("Conflicts")
            }
        }
    }
}

/// Caption copy under a control.
struct SettingsNote: View {
    let text: String
    var tint: Color? = nil

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint ?? Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Host list editor

struct HostListEditor: View {
    @Binding var entries: [String]
    let placeholder: String
    let accessibilityName: String
    /// Boundary problems by row index, from `ConfigFieldProblems`.
    var problems: [Int: String] = [:]
    @FocusState private var focusedRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        TextField(accessibilityName, text: entryBinding(at: index), prompt: Text(placeholder))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.system(size: 12, design: .monospaced))
                            .focused($focusedRow, equals: index)
                            .onSubmit { cleanupEntries() }
                            .modifier(InvalidFieldHighlight(isInvalid: problems[index] != nil))
                            .accessibilityLabel("\(accessibilityName) entry \(index + 1)")

                        Button(role: .destructive) {
                            removeEntry(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(accessibilityName) entry \(index + 1)")
                        .help("Remove entry")
                    }
                    if let problem = problems[index] {
                        FieldProblem(message: problem)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    appendEntry()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(accessibilityName) entry")

                Text("Paste comma or newline separated values into any row.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
        }
        .onChange(of: focusedRow) { _, newValue in
            cleanupEntries(keeping: newValue)
        }
        .onDisappear {
            cleanupEntries()
        }
    }

    private func entryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard entries.indices.contains(index) else { return "" }
                return entries[index]
            },
            set: { value in
                setEntry(at: index, to: value)
            }
        )
    }

    private func setEntry(at index: Int, to value: String) {
        guard entries.indices.contains(index) else { return }

        let parsedEntries = parsedListEntries(from: value)
        if parsedEntries.count > 1 || value.contains(",") || value.contains("\n") || value.contains("\r") {
            if parsedEntries.isEmpty {
                entries[index] = ""
            } else {
                entries.replaceSubrange(index...index, with: parsedEntries)
                focusedRow = index + parsedEntries.count - 1
            }
            cleanupEntries(keeping: focusedRow)
            return
        }

        entries[index] = normalizedEntry(value)
    }

    private func appendEntry() {
        cleanupEntries()
        entries.append("")
        focusedRow = entries.count - 1
    }

    private func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        cleanupEntries()
        focusedRow = nil
    }

    private func cleanupEntries(keeping focusedIndex: Int? = nil) {
        var cleanedEntries: [String] = []
        var cleanedFocus: Int?

        for (index, entry) in entries.enumerated() {
            let normalized = normalizedEntry(entry)
            if normalized.isEmpty {
                if index == focusedIndex {
                    cleanedFocus = cleanedEntries.count
                    cleanedEntries.append("")
                }
            } else {
                if index == focusedIndex {
                    cleanedFocus = cleanedEntries.count
                }
                cleanedEntries.append(normalized)
            }
        }

        entries = cleanedEntries
        if focusedRow != cleanedFocus {
            focusedRow = cleanedFocus
        }
    }

    private func parsedListEntries(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map(normalizedEntry)
            .filter { !$0.isEmpty }
    }

    private func normalizedEntry(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Upstream drag reorder

struct UpstreamDropDelegate: DropDelegate {
    let targetID: UUID?
    @Binding var draggedID: UUID?
    let move: (UUID, UUID?) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Privileged helper wording

enum HelperStatusPresentation {
    static func label(for status: HelperToolPrivilegeClient.Status) -> String {
        switch status {
        case .installed: return "Installed and running"
        case .outdated: return "Outdated, reinstall required"
        case .notInstalled: return "Not installed"
        case .notResponding: return "Installed but not responding"
        case .waitingForConsoleUser: return "Installed, waiting for a login session"
        case .unauthorized: return "Installed, but refusing this user"
        }
    }

    static func color(for status: HelperToolPrivilegeClient.Status) -> Color {
        switch status {
        case .installed: return Color(nsColor: .systemGreen)
        case .outdated: return Color(nsColor: .systemOrange)
        case .notInstalled: return Color(nsColor: .systemGray)
        case .notResponding: return Color(nsColor: .systemRed)
        case .waitingForConsoleUser: return Color(nsColor: .systemYellow)
        case .unauthorized: return Color(nsColor: .systemOrange)
        }
    }

    static func primaryActionTitle(for status: HelperToolPrivilegeClient.Status) -> String {
        switch status {
        case .installed: return "Reinstall Helper"
        case .outdated: return "Update Helper"
        case .notInstalled: return "Install Helper"
        case .notResponding: return "Repair Helper"
        case .waitingForConsoleUser, .unauthorized:
            // Reinstalling changes nothing about who is at the console.
            return "Reinstall Helper"
        }
    }

    /// "(via helper)" or "(requires admin)" after a toggle that needs root.
    static func privilegeHint(for status: HelperToolPrivilegeClient.Status, otherwise: String = "requires admin") -> String {
        status == .installed ? "(via helper)" : "(\(otherwise))"
    }
}

/// Shown at the top of DNS and Tunnels when the helper is not installed.
struct HelperHintBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text("Install the privileged helper to avoid admin prompts for DNS and tunnel operations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("General…") { appState.selectedSection = .general }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Copyable command line

struct CopyableValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
                .accessibilityLabel("Copy \(label)")
            }
        }
    }
}
