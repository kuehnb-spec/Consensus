import SwiftUI

/// Shows the transcript produced by the pipeline. Phase 1b renders the
/// standard-pass output (Engine A + SpeakerKit): speaker turns in time
/// order, with Source Serif body text and JetBrains Mono timestamps.
///
/// Phase 1c layers on the speaker-naming result, verbatim/clean toggle,
/// and inline LLM-surfaced uncertainty popovers. Phase 1d adds the
/// summary pane and export sheet.
struct DeepReadReviewView: View {
    let viewModel: DeepReadViewModel

    var body: some View {
        HStack(spacing: 0) {
            transcriptColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ConsensusTheme.Colors.background)
    }

    // MARK: - Transcript column

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            transcriptHeader
                .padding(.horizontal, ConsensusTheme.Spacing.xl)
                .padding(.vertical, ConsensusTheme.Spacing.md)
                .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.6))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ConsensusTheme.Colors.borderSubtle)
                        .frame(height: 1)
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                    if let pass = viewModel.activePassContent {
                        if pass.segments.isEmpty {
                            emptyPassMessage
                        } else {
                            ForEach(Array(pass.segments.enumerated()), id: \.offset) { _, segment in
                                turnRow(segment: segment)
                            }
                        }
                    } else {
                        ProgressView("Loading transcript…")
                            .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            .padding(ConsensusTheme.Spacing.xxl)
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.xxl)
                .padding(.vertical, ConsensusTheme.Spacing.xl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Header

    private var transcriptHeader: some View {
        HStack(spacing: ConsensusTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.project?.title ?? "Untitled")
                    .font(ConsensusType.displayHeading)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    if let duration = viewModel.project?.audio.durationSeconds {
                        Text(formattedDuration(duration))
                            .font(ConsensusType.monoMetric)
                    }
                    if let pass = viewModel.activePassContent {
                        Text("·")
                            .foregroundStyle(ConsensusTheme.Colors.textMuted)
                        Text("\(pass.segments.count) turn\(pass.segments.count == 1 ? "" : "s")")
                            .font(ConsensusType.displayCaption)
                        if !pass.engineAttribution.primaryEngine.isEmpty {
                            Text("·")
                                .foregroundStyle(ConsensusTheme.Colors.textMuted)
                            Text(pass.engineAttribution.primaryEngine)
                                .font(ConsensusType.displayCaption)
                        }
                    }
                }
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            }

            Spacer()

            if let diarizationConfidence = viewModel.activePassContent?.quality.diarizationConfidence {
                confidenceBadge(value: diarizationConfidence)
            }
        }
    }

    private func confidenceBadge(value: Double) -> some View {
        let tier = ConsensusTheme.Colors.confidenceTier(Float(value))
        return HStack(spacing: ConsensusTheme.Spacing.xs) {
            Circle()
                .fill(tier)
                .frame(width: 6, height: 6)
            Text(String(format: "%.0f%%", value * 100))
                .font(ConsensusType.monoMetric)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            Text("diarization")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay(Capsule(style: .continuous).stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1))
        )
    }

    // MARK: - Empty state

    private var emptyPassMessage: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text("No speech detected")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text("The pipeline ran, but the audio didn't produce any transcribable segments. Check the source recording and try again.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(ConsensusTheme.Spacing.xxl)
    }

    // MARK: - Turn row

    private func turnRow(segment: TranscriptionSegment) -> some View {
        let speaker = viewModel.project?.speakers.first { $0.id == segment.speakerID }
        let palette = ConsensusTheme.Colors.speakerPalette
        let colorIndex = speaker?.paletteIndex ?? 0
        let color = palette[colorIndex % palette.count]
        let displayName = speaker?.displayName ?? segment.speakerID

        return VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)

                Text(displayName)
                    .font(ConsensusType.transcriptSpeaker)
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                Text(formattedTimestamp(segment.start))
                    .font(ConsensusType.monoTimestamp)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            }

            Text(segment.text)
                .font(ConsensusType.transcriptBody)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatters

    private func formattedDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func formattedTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
