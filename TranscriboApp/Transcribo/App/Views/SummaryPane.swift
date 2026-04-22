import SwiftUI

/// Right-side pane in the review view. Shows the editable summary +
/// to-dos produced by `SummaryRunner`. Per-section Copy and Regenerate
/// buttons. When no summary exists, an empty-state card offers a single
/// "Generate summary" action.
///
/// Visibility is governed by `DeepReadViewModel.showSummaryPane`; the
/// toggle lives in the review view's header.
struct SummaryPane: View {
    @Bindable var viewModel: DeepReadViewModel

    @State private var editingSummary: String = ""
    @FocusState private var summaryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, ConsensusTheme.Spacing.lg)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(height: 1)
                }

            ScrollView {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                    switch viewModel.summaryState {
                    case .running(let fraction, let label):
                        generatingCard(fraction: fraction, label: label)
                    case .error(let message):
                        errorCard(message: message)
                    case .idle:
                        if viewModel.summary.summary.isEmpty && viewModel.summary.todos.isEmpty {
                            emptyCard
                        } else {
                            summarySection
                            todosSection
                        }
                    }
                }
                .padding(ConsensusTheme.Spacing.lg)
            }
        }
        .frame(width: 340)
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.5))
        .overlay(alignment: .leading) {
            Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(width: 1)
        }
        .onAppear {
            editingSummary = viewModel.summary.summary
        }
        .onChange(of: viewModel.summary.summary) { _, newValue in
            if !summaryFocused { editingSummary = newValue }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            Text("SUMMARY & TO-DOS")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)
            Spacer()
            Button {
                viewModel.toggleSummaryPane()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Hide summary pane")
        }
    }

    // MARK: - States

    private var emptyCard: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.accent)

            Text("No summary yet")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Text("Generate a structured summary of the transcript with the local LLM, with to-dos attributed to each speaker.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.regenerateSummary() }
            } label: {
                Label("Generate summary", systemImage: "sparkles")
                    .font(ConsensusType.displayBody.weight(.medium))
                    .padding(.horizontal, ConsensusTheme.Spacing.sm)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConsensusTheme.Colors.accent)
            .padding(.top, ConsensusTheme.Spacing.xs)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    private func generatingCard(fraction: Double, label: String) -> some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(ConsensusTheme.Colors.accent)

            Text(label)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", fraction * 100))
                .font(ConsensusType.monoMetric)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(ConsensusTheme.Colors.warning)
            Text("Summary generation failed")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text(message)
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await viewModel.regenerateSummary() }
            }
            .buttonStyle(.bordered)
        }
        .padding(ConsensusTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    // MARK: - Filled sections

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            sectionHeader(
                "Summary",
                actions: AnyView(
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Button {
                            viewModel.copySummary()
                        } label: {
                            Image(systemName: viewModel.copyConfirmationVisible ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .help("Copy summary to clipboard")

                        Button {
                            Task { await viewModel.regenerateSummary() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .help("Regenerate from the transcript (overwrites edits)")
                    }
                )
            )

            TextEditor(text: $editingSummary)
                .font(ConsensusType.transcriptBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($summaryFocused)
                .frame(minHeight: 180)
                .onChange(of: editingSummary) { _, newValue in
                    // Debounced persistence: save on each change but cheap
                    // because our "save" just writes JSON to disk.
                    if newValue != viewModel.summary.summary {
                        viewModel.saveSummaryEdit(newValue)
                    }
                }
                .padding(ConsensusTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                        .fill(ConsensusTheme.Colors.surfaceSecondary)
                        .overlay(
                            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                                .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                        )
                )

            if let ts = viewModel.summary.summaryRegeneratedAt {
                Text("Regenerated \(Self.relativeTime(ts))")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
        }
    }

    private var todosSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            sectionHeader(
                "To-dos",
                actions: AnyView(
                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                        Button {
                            viewModel.copyTodos()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .help("Copy to-dos as Markdown checklist")
                    }
                )
            )

            if viewModel.summary.todos.isEmpty {
                Text("No action items detected in the transcript.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .padding(.vertical, ConsensusTheme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
                    ForEach(viewModel.summary.todos) { todo in
                        todoRow(todo)
                    }
                }
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: ConsensusTheme.Spacing.sm) {
            Button {
                viewModel.toggleTodoDone(todo.id)
            } label: {
                Image(systemName: todo.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        todo.isDone ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textSecondary
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text)
                    .font(ConsensusType.displayBody)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .strikethrough(todo.isDone, color: ConsensusTheme.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let ownerID = todo.ownerSpeakerID,
                   let speaker = viewModel.project?.speakers.first(where: { $0.id == ownerID }) {
                    Text(speaker.displayName)
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, actions: AnyView) -> some View {
        HStack {
            Text(title.uppercased())
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(0.8)
            Spacer()
            actions
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
            .fill(ConsensusTheme.Colors.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md, style: .continuous)
                    .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
