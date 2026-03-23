import SwiftUI

/// A thin horizontal bar representing the full audio duration, with
/// color-coded segments marking where transcription engines disagreed.
/// Lets users see "hotspots" of low confidence at a glance.
struct DisagreementHeatmapView: View {
    let disagreements: [PassDisagreement]
    let audioDuration: TimeInterval

    private func colorForKind(_ kind: PassDisagreement.Kind) -> Color {
        switch kind {
        case .text:            return ConsensusTheme.Colors.confidenceAmber
        case .speaker:         return Color(red: 0.298, green: 0.788, blue: 0.812)   // teal
        case .textAndSpeaker:  return ConsensusTheme.Colors.confidenceRed
        case .missingSegment:  return ConsensusTheme.Colors.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.sm) {
            Text("Disagreement Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)

            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ConsensusTheme.Colors.surfaceSecondary)

                    // Disagreement markers
                    ForEach(disagreements) { d in
                        let startFraction = audioDuration > 0 ? d.start / audioDuration : 0
                        let endFraction = audioDuration > 0 ? d.end / audioDuration : 0
                        let segmentWidth = max((endFraction - startFraction) * width, 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForKind(d.kind))
                            .frame(width: segmentWidth)
                            .offset(x: startFraction * width)
                    }
                }
            }
            .frame(height: 8)

            // Legend
            HStack(spacing: ConsensusTheme.Spacing.lg) {
                HeatmapLegendItem(color: ConsensusTheme.Colors.confidenceAmber, label: "Text")
                HeatmapLegendItem(color: Color(red: 0.298, green: 0.788, blue: 0.812), label: "Speaker")
                HeatmapLegendItem(color: ConsensusTheme.Colors.confidenceRed, label: "Both")
                HeatmapLegendItem(color: ConsensusTheme.Colors.danger, label: "Missing")
            }
        }
        .padding(ConsensusTheme.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.lg)
                        .stroke(ConsensusTheme.Colors.border, lineWidth: 1)
                }
        }
    }
}

private struct HeatmapLegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: ConsensusTheme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(ConsensusTheme.Fonts.mono(.caption2))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
        }
    }
}
