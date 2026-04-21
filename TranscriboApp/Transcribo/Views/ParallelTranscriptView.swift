import SwiftUI

/// Side-by-side comparison of two transcript passes, time-aligned like an interlinear text.
/// Highlights speaker label differences and text differences between passes.
struct ParallelTranscriptView: View {
    @Environment(TranscriptionViewModel.self) private var viewModel
    @State private var leftPassIndex: Int = 0
    @State private var rightPassIndex: Int = 1

    private var passes: [TranscriptionPass] {
        viewModel.currentProject?.passes ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ConsensusTheme.Colors.border)

            if passes.count < 2 {
                emptyState
            } else {
                comparisonContent
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: ConsensusTheme.Spacing.lg) {
            Text("COMPARE PASSES")
                .font(ConsensusTheme.Fonts.mono(size: 10, weight: .bold))
                .foregroundStyle(ConsensusTheme.Colors.accent)
                .tracking(1)

            Spacer()

            // Left pass picker
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Circle().fill(ConsensusTheme.Colors.accent).frame(width: 8, height: 8)
                Picker("Left", selection: $leftPassIndex) {
                    ForEach(Array(passes.enumerated()), id: \.element.id) { index, pass in
                        Text(passLabel(pass, index: index)).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }

            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)

            // Right pass picker
            HStack(spacing: ConsensusTheme.Spacing.xs) {
                Circle().fill(ConsensusTheme.Colors.confidenceAmber).frame(width: 8, height: 8)
                Picker("Right", selection: $rightPassIndex) {
                    ForEach(Array(passes.enumerated()), id: \.element.id) { index, pass in
                        Text(passLabel(pass, index: index)).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }

            Button {
                viewModel.currentPhase = .review
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(.caption)
            }
            .buttonStyle(ConsensusGhostButtonStyle())
        }
        .padding(.horizontal, ConsensusTheme.Spacing.lg)
        .padding(.vertical, ConsensusTheme.Spacing.sm)
        .background(ConsensusTheme.Colors.surfacePrimary)
    }

    // MARK: - Comparison Content

    private var comparisonContent: some View {
        let leftPass = passes.indices.contains(leftPassIndex) ? passes[leftPassIndex] : nil
        let rightPass = passes.indices.contains(rightPassIndex) ? passes[rightPassIndex] : nil

        return GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left column
                passColumn(
                    pass: leftPass,
                    otherPass: rightPass,
                    accentColor: ConsensusTheme.Colors.accent,
                    width: geometry.size.width / 2
                )

                Divider().overlay(ConsensusTheme.Colors.border)

                // Right column
                passColumn(
                    pass: rightPass,
                    otherPass: leftPass,
                    accentColor: ConsensusTheme.Colors.confidenceAmber,
                    width: geometry.size.width / 2
                )
            }
        }
    }

    private func passColumn(
        pass: TranscriptionPass?,
        otherPass: TranscriptionPass?,
        accentColor: Color,
        width: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            // Column header
            if let pass {
                HStack(spacing: ConsensusTheme.Spacing.sm) {
                    Text(pass.kind.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(accentColor)
                    Text(pass.engineName)
                        .font(ConsensusTheme.Fonts.mono(.caption2))
                        .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    Spacer()
                    if let conf = pass.qualitySummary.averageWordConfidence {
                        Text("\(Int(conf * 100))%")
                            .font(ConsensusTheme.Fonts.mono(.caption2))
                            .foregroundStyle(ConsensusTheme.Colors.confidenceTier(conf))
                    }
                }
                .padding(.horizontal, ConsensusTheme.Spacing.md)
                .padding(.vertical, ConsensusTheme.Spacing.sm)
                .background(accentColor.opacity(0.05))

                Divider().overlay(ConsensusTheme.Colors.borderSubtle)
            }

            // Segments
            ScrollView {
                if let pass {
                    let otherSegments = otherPass?.result.segments ?? []
                    let speakers = pass.result.detectedSpeakers

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pass.result.segments.enumerated()), id: \.element.id) { index, segment in
                            let isNewSpeaker = index == 0 || segment.speakerID != pass.result.segments[max(0, index - 1)].speakerID
                            let speakerDiffers = doesSpeakerDiffer(segment: segment, in: otherSegments)

                            VStack(alignment: .leading, spacing: 2) {
                                if isNewSpeaker {
                                    HStack(spacing: ConsensusTheme.Spacing.xs) {
                                        Text(viewModel.speakerMapping.displayName(for: segment.speakerID).uppercased())
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(SpeakerBadge.color(for: segment.speakerID, in: speakers))

                                        Text(TimeFormatting.timestamp(segment.start))
                                            .font(ConsensusTheme.Fonts.mono(size: 9))
                                            .foregroundStyle(ConsensusTheme.Colors.textTertiary)

                                        if speakerDiffers {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(ConsensusTheme.Colors.confidenceAmber)
                                                .help("Speaker differs between passes at this timestamp")
                                        }
                                    }
                                    .padding(.top, index == 0 ? ConsensusTheme.Spacing.sm : ConsensusTheme.Spacing.md)
                                }

                                Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 12))
                                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                                    .background(
                                        speakerDiffers
                                            ? ConsensusTheme.Colors.confidenceAmber.opacity(0.06)
                                            : Color.clear
                                    )
                            }
                            .padding(.horizontal, ConsensusTheme.Spacing.md)
                        }
                    }
                    .padding(.bottom, ConsensusTheme.Spacing.xl)
                }
            }
        }
        .frame(width: width)
        .background(ConsensusTheme.Colors.background)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: ConsensusTheme.Spacing.lg) {
            Spacer()
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary.opacity(0.4))
            Text("Run at least two transcription passes to compare them side by side.")
                .font(.subheadline)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func passLabel(_ pass: TranscriptionPass, index: Int) -> String {
        "Pass \(index + 1): \(pass.kind.displayName) (\(pass.engineName))"
    }

    /// Check if the speaker at this segment's timestamp differs in the other pass.
    private func doesSpeakerDiffer(segment: TranscriptionSegment, in otherSegments: [TranscriptionSegment]) -> Bool {
        let midpoint = (segment.start + segment.end) / 2
        guard let match = otherSegments.first(where: { $0.start <= midpoint && $0.end >= midpoint }) else {
            return false
        }
        return match.speakerID != segment.speakerID
    }
}
