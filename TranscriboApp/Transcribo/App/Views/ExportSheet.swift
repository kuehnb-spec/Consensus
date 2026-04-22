import SwiftUI

/// Structured export dialog. Lets the user choose a format, decide whether
/// to bundle in the summary + to-dos, and either copy to clipboard or save
/// to a file. Replaces the menu-driven "Save as X…" flow in Studio and
/// anywhere a more deliberate export is wanted.
///
/// The quick-access Copy and Save menus on the toolbar still exist for
/// one-shot flows (⇧⌘C / ⌘E); this sheet is the canonical path that
/// surfaces every option at once.
struct ExportSheet: View {
    @Bindable var viewModel: DeepReadViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: DeepReadViewModel.ExportFormat = .markdown
    @State private var includeSummary: Bool = true
    @State private var lastAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            header

            formatSection

            includeSection

            Spacer(minLength: ConsensusTheme.Spacing.md)

            footer
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(width: 520)
        .background(ConsensusTheme.Colors.background)
        .onAppear {
            includeSummary = !viewModel.summary.summary.isEmpty ||
                             !viewModel.summary.todos.isEmpty
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("Export transcript")
                .font(ConsensusType.display(size: 22, weight: .semibold))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            if let title = viewModel.project?.title {
                Text(title)
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("FORMAT")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            VStack(spacing: ConsensusTheme.Spacing.xs) {
                ForEach(DeepReadViewModel.ExportFormat.allCases) { candidate in
                    formatRow(candidate: candidate)
                }
            }
        }
    }

    private func formatRow(candidate: DeepReadViewModel.ExportFormat) -> some View {
        let isSelected = format == candidate
        return Button {
            format = candidate
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(ConsensusType.displayBody.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(Self.description(for: candidate))
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .fill(
                        isSelected
                        ? ConsensusTheme.Colors.accentSubtle
                        : ConsensusTheme.Colors.surfaceSecondary.opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                            .stroke(
                                isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.borderSubtle,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private static func description(for format: DeepReadViewModel.ExportFormat) -> String {
        switch format {
        case .plainText:        return "Unstyled text, one paragraph per turn."
        case .markdown:         return "Headers, bold speakers, inline timestamps."
        case .obsidianMarkdown: return "Markdown with YAML frontmatter for Obsidian."
        }
    }

    // MARK: - Include

    private var includeSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("INCLUDE")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            Toggle(isOn: $includeSummary) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summary & to-dos")
                        .font(ConsensusType.displayBody)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text(includeHint)
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .tint(ConsensusTheme.Colors.accent)
            .disabled(!hasSummaryContent)
            .opacity(hasSummaryContent ? 1 : 0.6)
        }
    }

    private var hasSummaryContent: Bool {
        !viewModel.summary.summary.isEmpty || !viewModel.summary.todos.isEmpty
    }

    private var includeHint: String {
        hasSummaryContent
            ? "Prepends the summary block above the transcript."
            : "No summary generated yet — open the pane and click Generate to enable."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            if let message = lastAction {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.success)
                    .transition(.opacity)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button {
                copyAction()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .padding(.horizontal, ConsensusTheme.Spacing.xs)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: [.command])

            Button {
                saveAction()
            } label: {
                Label("Save…", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, ConsensusTheme.Spacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConsensusTheme.Colors.accent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func copyAction() {
        // Render with the include-summary choice, push to pasteboard.
        let rendered = viewModel.renderExport(format: format, includeSummary: includeSummary)
        guard let text = rendered else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            lastAction = "Copied to clipboard"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }

    private func saveAction() {
        let url = viewModel.exportToFile(format: format, includeSummary: includeSummary)
        if url != nil {
            dismiss()
        }
    }
}
