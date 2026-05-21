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

    @State private var format: ExportFormat = .legalPDF
    @State private var includeSummary: Bool = true
    @State private var legalHeader: String = "TRANSCRIPT"
    @State private var showElapsedTime: Bool = true
    @State private var showClockTime: Bool = false
    @State private var includeCoverPage: Bool = false
    @State private var lastAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                    formatSection
                    includeSection
                    if format == .legalPDF {
                        legalPDFSection
                    }
                }
            }
            .scrollIndicators(.visible)

            Spacer(minLength: ConsensusTheme.Spacing.md)

            footer
        }
        .padding(ConsensusTheme.Spacing.xxl)
        .frame(width: 620, height: 720)
        .background(ConsensusTheme.Colors.background)
        .onAppear {
            includeSummary = !viewModel.summary.summary.isEmpty ||
                             !viewModel.summary.todos.isEmpty
            legalHeader = viewModel.defaultLegalPDFHeader()
            includeCoverPage = includeSummary
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

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 250), spacing: ConsensusTheme.Spacing.sm)
                ],
                spacing: ConsensusTheme.Spacing.sm
            ) {
                ForEach(ExportFormat.allCases) { candidate in
                    formatRow(candidate: candidate)
                }
            }
        }
    }

    private func formatRow(candidate: ExportFormat) -> some View {
        let isSelected = format == candidate
        return Button {
            format = candidate
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: candidate.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.displayName) (.\(candidate.fileExtension))")
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
            .frame(minHeight: 66)
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

    private static func description(for format: ExportFormat) -> String {
        switch format {
        case .txt:              return "Plain transcript text."
        case .md:               return "Readable Markdown transcript."
        case .obsidianMarkdown: return "Markdown with YAML frontmatter."
        case .json:             return "Structured data for testing."
        case .srt:              return "Subtitle/caption file."
        case .rtf:              return "Rich text document."
        case .docx:             return "Microsoft Word document."
        case .legalPDF:         return "Court-style legal transcript PDF."
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

    private var legalPDFSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            Text("LEGAL PDF")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    Text("Header")
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    TextEditor(text: $legalHeader)
                        .font(ConsensusType.monoLog)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 70)
                        .padding(ConsensusTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                                .fill(ConsensusTheme.Colors.surfacePrimary.opacity(0.7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                                        .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                                )
                        )
                }

                Toggle("Elapsed timestamps", isOn: $showElapsedTime)
                Toggle("Clock timestamps", isOn: $showClockTime)
                Toggle("Cover page with summary & to-dos", isOn: $includeCoverPage)
                    .disabled(!hasSummaryContent)
                    .opacity(hasSummaryContent ? 1 : 0.6)
            }
            .font(ConsensusType.displayBody)
            .toggleStyle(.switch)
            .tint(ConsensusTheme.Colors.accent)
            .padding(ConsensusTheme.Spacing.md)
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
            .disabled(!viewModel.canCopyExport(format: format))

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
        guard viewModel.canCopyExport(format: format) else { return }
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
        let options = viewModel.defaultLegalPDFOptions(
            includeSummary: includeSummary,
            headerText: legalHeader,
            showElapsedTime: showElapsedTime,
            showClockTime: showClockTime,
            includeCoverPage: includeCoverPage
        )
        let url = viewModel.exportToFile(
            format: format,
            includeSummary: includeSummary,
            legalPDFOptions: options
        )
        if url != nil {
            dismiss()
        }
    }
}
