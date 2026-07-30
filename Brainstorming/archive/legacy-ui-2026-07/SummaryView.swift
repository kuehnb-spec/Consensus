import SwiftUI

/// Always-available summarization tool. Generates a concise summary of the current
/// transcript with action items and key points, ready for copy-paste sharing.
struct SummaryView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        HSplitView {
            // Left: Controls
            ScrollView {
                VStack(spacing: ConsensusTheme.Spacing.xl) {
                    header
                    modelSelection
                    actionButton

                    Spacer()
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
            .frame(minWidth: 340, idealWidth: 380)

            // Right: Result
            resultPanel
                .frame(minWidth: 350, idealWidth: 500)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "text.badge.star")
                .font(.system(size: 44))
                .foregroundStyle(ConsensusTheme.Colors.accent)

            Text("Summary")
                .font(ConsensusTheme.Fonts.title)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Text("Generate a summary with action items, deliverables, and key points attributed to each speaker.")
                .font(ConsensusTheme.Fonts.subtitle)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, ConsensusTheme.Spacing.lg)
    }

    // MARK: - Model Selection

    private var modelSelection: some View {
        @Bindable var vm = viewModel
        let available = CleanupModel.available()

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            Label("Model", systemImage: "cpu")
                .font(.headline)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            ForEach(available) { model in
                SummaryModelRow(
                    model: model,
                    isSelected: viewModel.selectedCleanupModel == model,
                    onSelect: { viewModel.selectedCleanupModel = model }
                )
            }

            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                Text("Runs entirely on your Mac. No cloud services or signups required.")
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
        }
        .consensusCard(label: "AI Model", icon: "cpu")
        .padding(.horizontal)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            if viewModel.isSummaryRunning {
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(ConsensusTheme.Colors.accent)

                    Text(viewModel.summaryProgress)
                        .font(ConsensusTheme.Fonts.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            } else {
                Button {
                    Task { await viewModel.runSummary() }
                } label: {
                    Label("Generate Summary", systemImage: "text.badge.star")
                        .frame(maxWidth: 300)
                }
                .buttonStyle(ConsensusPrimaryButtonStyle())
                .controlSize(.large)
                .disabled(!viewModel.hasResult)
            }

            if let error = viewModel.summaryError {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ConsensusTheme.Colors.danger)
                    Text(error)
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.danger)
                }
            }
        }
    }

    // MARK: - Result Panel

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Summary", systemImage: "text.badge.star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)

                Spacer()

                if viewModel.summaryResult != nil {
                    Button {
                        if let text = viewModel.summaryResult {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(ConsensusGhostButtonStyle())
                }
            }
            .padding(.horizontal, ConsensusTheme.Spacing.lg)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(ConsensusTheme.Colors.surfacePrimary)

            Divider()
                .overlay(ConsensusTheme.Colors.border)

            if let result = viewModel.summaryResult {
                ScrollView {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .padding(ConsensusTheme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if viewModel.isSummaryRunning {
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating...")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: ConsensusTheme.Spacing.md) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 48))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary.opacity(0.5))

                    Text("Generate a summary to share with your team")
                        .font(ConsensusTheme.Fonts.subtitle)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                    Text("Includes action items attributed to each speaker, key decisions, and important details.")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary)
    }
}

// MARK: - Model Row

private struct SummaryModelRow: View {
    let model: CleanupModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ConsensusTheme.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textTertiary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                    HStack(spacing: ConsensusTheme.Spacing.sm) {
                        Text(model.description)
                            .font(ConsensusTheme.Fonts.caption)
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        Text(model.approximateSize)
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    }
                }

                Spacer()

                if model == CleanupModel.recommended() {
                    Text("Recommended")
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.accent)
                        .padding(.horizontal, ConsensusTheme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(ConsensusTheme.Colors.accentSubtle)
                        }
                }
            }
            .padding(ConsensusTheme.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                    .fill(isSelected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsensusTheme.Radius.md)
                            .stroke(isSelected ? ConsensusTheme.Colors.borderAccent : ConsensusTheme.Colors.border, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}
