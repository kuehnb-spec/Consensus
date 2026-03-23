import SwiftUI

struct PolishView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        HSplitView {
            // Left: Controls
            ScrollView {
                VStack(spacing: ConsensusTheme.Spacing.xl) {
                    header
                    modelSelection
                    taskSelection
                    actionButton

                    Spacer()
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
            .frame(minWidth: 380, idealWidth: 420)

            // Right: Result
            resultPanel
                .frame(minWidth: 350, idealWidth: 500)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44))
                .foregroundStyle(ConsensusTheme.Colors.accent)

            Text("Polish Transcript")
                .font(ConsensusTheme.Fonts.title)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Text("Use a local AI model to clean up errors and generate a summary")
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
                ModelOptionRow(
                    model: model,
                    isSelected: viewModel.selectedCleanupModel == model,
                    onSelect: { viewModel.selectedCleanupModel = model }
                )
            }

            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                Text("Models download on first use (no signup required). Runs entirely on your Mac.")
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
        }
        .consensusCard(label: "AI Model", icon: "cpu")
        .padding(.horizontal)
    }

    // MARK: - Task Selection

    private var taskSelection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
            Label("Task", systemImage: "checklist")
                .font(.headline)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)

            Picker("", selection: $vm.cleanupTask) {
                Text("Clean Up + Summarize").tag(TranscriptCleanupService.CleanupTask.cleanupAndSummarize)
                Text("Clean Up Only").tag(TranscriptCleanupService.CleanupTask.cleanup)
                Text("Summarize Only").tag(TranscriptCleanupService.CleanupTask.summarize)
            }
            .pickerStyle(.segmented)

            Text(taskDescription)
                .font(ConsensusTheme.Fonts.caption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
        }
        .consensusCard(label: "Task", icon: "checklist")
        .padding(.horizontal)
    }

    private var taskDescription: String {
        switch viewModel.cleanupTask {
        case .cleanup:
            return "Fix obvious transcription errors like misheard words, repeated words, and missing punctuation. The original meaning is preserved exactly."
        case .summarize:
            return "Generate a concise summary of the conversation including key points, decisions, and action items."
        case .cleanupAndSummarize:
            return "Clean up the transcript first, then append a summary of key points, decisions, and action items."
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            if viewModel.isCleanupRunning {
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(ConsensusTheme.Colors.accent)

                    Text(viewModel.cleanupProgress)
                        .font(ConsensusTheme.Fonts.subheadline)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
            } else {
                Button {
                    Task { await viewModel.runCleanup() }
                } label: {
                    Label("Run Polish", systemImage: "wand.and.stars")
                        .frame(maxWidth: 300)
                }
                .buttonStyle(ConsensusPrimaryButtonStyle())
                .controlSize(.large)
                .disabled(!viewModel.hasResult)
            }

            if let error = viewModel.cleanupError {
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
                Label("Result", systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)

                Spacer()

                if viewModel.cleanupResult != nil {
                    Button {
                        if let text = viewModel.cleanupResult {
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

            if let result = viewModel.cleanupResult {
                ScrollView {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .padding(ConsensusTheme.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if viewModel.isCleanupRunning {
                VStack(spacing: ConsensusTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(ConsensusTheme.Fonts.caption)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: ConsensusTheme.Spacing.md) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 48))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary.opacity(0.5))

                    Text("Run Polish to clean up your transcript")
                        .font(ConsensusTheme.Fonts.subtitle)
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary)
    }
}

// MARK: - Model Option Row

private struct ModelOptionRow: View {
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
