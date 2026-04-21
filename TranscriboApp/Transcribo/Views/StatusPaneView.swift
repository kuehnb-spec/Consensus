import SwiftUI

/// Unified status pane shown on the right side of the Advanced Mode layout.
/// Displays all processing status, progress, and logs in one place.
/// Not interactive — all interaction happens in the main work area.
struct StatusPaneView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("STATUS")
                    .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .tracking(1)

                Spacer()

                // Phase indicator
                Text(phaseLabel)
                    .font(ConsensusTheme.Fonts.mono(.caption2))
                    .foregroundStyle(ConsensusTheme.Colors.accent)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.vertical, ConsensusTheme.Spacing.sm)
            .background(ConsensusTheme.Colors.surfaceSecondary)

            Divider().overlay(ConsensusTheme.Colors.border)

            // Top section: status info (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.md) {
                    overallProgressSection

                    if viewModel.isAnyProcessRunning {
                        currentOperationSection
                    }

                    if viewModel.qualitySummary != nil {
                        qualitySection
                    }

                    if viewModel.currentPhase.isDeepReview || !viewModel.deepReviewCompletedSteps.isEmpty {
                        deepReviewProgressSection
                    }

                    processLogSection
                }
                .padding(ConsensusTheme.Spacing.md)
            }

            // Bottom section: live output (always visible when there's output)
            if !viewModel.processLog.outputText.isEmpty {
                liveOutputSection
            }
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        .background(ConsensusTheme.Colors.surfacePrimary)
        .overlay(alignment: .leading) {
            Divider().overlay(ConsensusTheme.Colors.border)
        }
    }

    // MARK: - Phase Label

    private var phaseLabel: String {
        switch viewModel.currentPhase {
        case .setup: return "Setup"
        case .review: return "Review"
        case .export: return "Export"
        case .deepTranscription: return "Deep Review 1/4"
        case .deepDiarization: return "Deep Review 2/4"
        case .deepSpeakerConfirm: return "Deep Review 3/4"
        case .deepReviewCompare: return "Deep Review 4/4"
        case .help: return "Help"
        case .summary: return "Summary"
        case .polish: return "Polish"
        case .comparePasses: return "Compare"
        }
    }

    // MARK: - Overall Progress

    private var overallProgressSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Label("Progress", systemImage: "chart.bar.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            // Workflow steps
            VStack(alignment: .leading, spacing: 4) {
                statusRow(label: "Transcription", state: viewModel.hasResult ? .complete : (viewModel.pipeline.isRunning ? .active : .pending))
                statusRow(label: "Speaker Labels", state: viewModel.hasSpeakerRenames ? .complete : .pending)

                if !viewModel.deepReviewCompletedSteps.isEmpty || viewModel.currentPhase.isDeepReview {
                    Divider().overlay(ConsensusTheme.Colors.borderSubtle).padding(.vertical, 2)
                    statusRow(label: "Deep Transcription", state: stepState("transcription"))
                    statusRow(label: "Deep Diarization", state: stepState("diarization"))
                    statusRow(label: "Speaker Confirm", state: stepState("speakerConfirm"))
                    statusRow(label: "Verified Export", state: viewModel.hasConsensusPass ? .complete : .pending)
                }
            }
        }
        .padding(ConsensusTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
        }
    }

    private enum StepState { case pending, active, complete }

    private func stepState(_ key: String) -> StepState {
        if viewModel.deepReviewCompletedSteps.contains(key) { return .complete }
        switch key {
        case "transcription" where viewModel.currentPhase == .deepTranscription && viewModel.pipeline.isRunning: return .active
        case "diarization" where viewModel.currentPhase == .deepDiarization && viewModel.isCleanupRunning: return .active
        default: return .pending
        }
    }

    private func statusRow(label: String, state: StepState) -> some View {
        HStack(spacing: ConsensusTheme.Spacing.xs) {
            switch state {
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(ConsensusTheme.Colors.confidenceGreen)
            case .active:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            case .pending:
                Circle()
                    .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                    .frame(width: 10, height: 10)
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(state == .complete ? ConsensusTheme.Colors.textSecondary : ConsensusTheme.Colors.textTertiary)

            Spacer()
        }
    }

    // MARK: - Current Operation

    private var currentOperationSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Label("Current Operation", systemImage: "gearshape.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)

            Text(viewModel.globalStatusText)
                .font(.system(size: 11))
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .lineLimit(3)

            if viewModel.globalProgress > 0 {
                ProgressView(value: viewModel.globalProgress)
                    .tint(ConsensusTheme.Colors.accent)

                Text("\(Int(viewModel.globalProgress * 100))%")
                    .font(ConsensusTheme.Fonts.mono(size: 10))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }

            if !viewModel.cleanupProgress.isEmpty {
                Text(viewModel.cleanupProgress)
                    .font(.system(size: 10))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(ConsensusTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(ConsensusTheme.Colors.confidenceAmber.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                        .stroke(ConsensusTheme.Colors.confidenceAmber.opacity(0.15), lineWidth: 1)
                }
        }
    }

    // MARK: - Quality Metrics

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Label("Quality", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            if let summary = viewModel.qualitySummary {
                HStack(spacing: ConsensusTheme.Spacing.md) {
                    if let wc = summary.averageWordConfidence {
                        miniMetric(label: "Words", value: "\(Int(wc * 100))%", color: ConsensusTheme.Colors.confidenceTier(wc))
                    }
                    if let dc = summary.averageDiarizationQuality {
                        miniMetric(label: "Diarize", value: "\(Int(dc * 100))%", color: ConsensusTheme.Colors.confidenceTier(dc))
                    }
                }

                if summary.riskySegments.count > 0 {
                    Text("\(summary.riskySegments.count) flagged segments")
                        .font(.system(size: 10))
                        .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                }
            }
        }
        .padding(ConsensusTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.5))
        }
    }

    private func miniMetric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(ConsensusTheme.Fonts.mono(size: 12, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }

    // MARK: - Deep Review Progress

    private var deepReviewProgressSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Label("Deep Review", systemImage: "sparkles.rectangle.stack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.accent)

            let completed = viewModel.deepReviewCompletedSteps.count
            let total = 4
            ProgressView(value: Double(completed), total: Double(total))
                .tint(ConsensusTheme.Colors.accent)

            Text("\(completed) of \(total) steps complete")
                .font(.system(size: 10))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .padding(ConsensusTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(ConsensusTheme.Colors.accent.opacity(0.05))
        }
    }

    // MARK: - Process Log

    private var processLogSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Label("Log", systemImage: "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            if viewModel.processLog.entries.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 10))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.processLog.entries.suffix(15)) { entry in
                        HStack(alignment: .top, spacing: 4) {
                            Circle()
                                .fill(logColor(for: entry.level))
                                .frame(width: 5, height: 5)
                                .padding(.top, 4)

                            Text(entry.message)
                                .font(.system(size: 10))
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }

        }
        .padding(ConsensusTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm)
                .fill(ConsensusTheme.Colors.surfaceSecondary.opacity(0.3))
        }
    }

    // MARK: - Live Output (Bottom)

    private var liveOutputSection: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Divider().overlay(ConsensusTheme.Colors.border)

            HStack {
                HStack(spacing: ConsensusTheme.Spacing.xs) {
                    if viewModel.isAnyProcessRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text("LIVE OUTPUT")
                        .font(ConsensusTheme.Fonts.mono(size: 9, weight: .bold))
                        .foregroundStyle(ConsensusTheme.Colors.accent)
                        .tracking(0.5)
                }

                Spacer()

                Text(viewModel.processLog.outputLabel)
                    .font(ConsensusTheme.Fonts.mono(size: 9))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }
            .padding(.horizontal, ConsensusTheme.Spacing.md)
            .padding(.top, ConsensusTheme.Spacing.xs)

            ScrollView {
                Text(viewModel.processLog.outputText)
                    .font(ConsensusTheme.Fonts.mono(size: 10))
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ConsensusTheme.Spacing.md)
            }
            .frame(minHeight: 100, maxHeight: 200)
            .background(ConsensusTheme.Colors.background)
        }
    }

    private func logColor(for level: ProcessLogEntry.Level) -> Color {
        switch level {
        case .info: return ConsensusTheme.Colors.textTertiary
        case .progress: return ConsensusTheme.Colors.accent
        case .success: return ConsensusTheme.Colors.confidenceGreen
        case .warning: return ConsensusTheme.Colors.confidenceAmber
        case .error: return ConsensusTheme.Colors.confidenceRed
        case .aiThinking: return ConsensusTheme.Colors.accent
        }
    }
}
