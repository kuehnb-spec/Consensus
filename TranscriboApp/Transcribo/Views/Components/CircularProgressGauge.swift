import SwiftUI

/// A circular progress gauge with three-tier coloring (red/amber/green)
/// and a large centered value label. Used for Word Confidence, Segment
/// Confidence, and Diarization Quality in the Quality Dashboard.
struct CircularProgressGauge: View {
    let title: String
    let value: Float?
    let subtitle: String

    private var displayValue: String {
        guard let value else { return "\u{2014}" }
        return "\(Int((Double(value) * 100).rounded()))%"
    }

    private var progress: Double {
        guard let value else { return 0 }
        return Double(value)
    }

    private var tierColor: Color {
        guard let value else { return ConsensusTheme.Colors.textTertiary }
        return ConsensusTheme.Colors.confidenceTier(value)
    }

    var body: some View {
        VStack(spacing: ConsensusTheme.Spacing.md) {
            ZStack {
                // Track ring
                Circle()
                    .stroke(ConsensusTheme.Colors.border, lineWidth: 6)

                // Progress arc
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        tierColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: progress)

                // Value label
                Text(displayValue)
                    .font(ConsensusTheme.Fonts.mono(size: 22, weight: .bold))
                    .foregroundStyle(tierColor)
            }
            .frame(width: 80, height: 80)

            VStack(spacing: ConsensusTheme.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ConsensusTheme.Colors.textPrimary)

                Text(subtitle)
                    .font(ConsensusTheme.Fonts.caption)
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
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
