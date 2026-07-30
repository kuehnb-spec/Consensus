import SwiftUI

/// Cheat sheet for every keyboard shortcut in the rewritten UI. Opened
/// from ⌘/ or the Help menu. Grouped by context so users can scan for
/// the one they need.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(height: 1)
                }

            ScrollView {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xl) {
                    ForEach(Self.groups, id: \.title) { group in
                        section(group: group)
                    }
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
        }
        .frame(width: 520, height: 520)
        .background(ConsensusTheme.Colors.background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard shortcuts")
                    .font(ConsensusType.display(size: 20, weight: .semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                Text("Press ⌘/ any time to bring this up.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func section(group: Group) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text(group.title.uppercased())
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            VStack(spacing: 0) {
                ForEach(Array(group.shortcuts.enumerated()), id: \.offset) { idx, shortcut in
                    row(shortcut: shortcut)
                    if idx < group.shortcuts.count - 1 {
                        Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                    )
            )
        }
    }

    private func row(shortcut: Shortcut) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            Text(shortcut.description)
                .font(ConsensusType.displayBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Spacer()
            Text(shortcut.keys)
                .font(ConsensusType.monoMetric)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ConsensusTheme.Colors.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                        )
                )
        }
        .padding(.vertical, ConsensusTheme.Spacing.sm)
    }

    // MARK: - Shortcut catalog

    private struct Group {
        let title: String
        let shortcuts: [Shortcut]
    }

    private struct Shortcut {
        let description: String
        let keys: String
    }

    private static let groups: [Group] = [
        Group(title: "Global", shortcuts: [
            Shortcut(description: "Project Library",            keys: "⌘L"),
            Shortcut(description: "Open Audio File…",           keys: "⌘O"),
            Shortcut(description: "Keyboard shortcuts",         keys: "⌘/"),
        ]),
        Group(title: "Setup", shortcuts: [
            Shortcut(description: "Start transcription",        keys: "⌘↩"),
        ]),
        Group(title: "Speaker naming", shortcuts: [
            Shortcut(description: "Next field",                 keys: "↩"),
            Shortcut(description: "Confirm all speakers",       keys: "⌘↩"),
        ]),
        Group(title: "Review", shortcuts: [
            Shortcut(description: "Next uncertain turn",        keys: "⌘J"),
            Shortcut(description: "Previous uncertain turn",    keys: "⌘K"),
            Shortcut(description: "Close open popover",         keys: "⌘."),
            Shortcut(description: "Play / stop audio context",  keys: "⌘P"),
            Shortcut(description: "Mark turn resolved",         keys: "⌘R"),
            Shortcut(description: "Apply alternative A",        keys: "⌘1"),
            Shortcut(description: "Apply alternative B",        keys: "⌘2"),
        ]),
        Group(title: "Export", shortcuts: [
            Shortcut(description: "Copy as Markdown",           keys: "⇧⌘C"),
            Shortcut(description: "Save as Markdown…",          keys: "⌘E"),
            Shortcut(description: "Export with options…",       keys: "⇧⌘E"),
        ]),
    ]
}
